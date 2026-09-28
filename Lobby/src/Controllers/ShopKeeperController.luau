local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)
local ShopConfig = SharedConfig.ShopConfig

local Framework = Me.new()
local log = Log.new("ShopKeeperController")

--[[ CONSTANTS ]]

--[=[
	The four moments of the visit, in the order they happen.

	`GREETING` and `LEAVING` are gestures with an end: they play once and fall into the
	next resting state on their own. `AWAY` and `ATTENDING` are the two poses where the
	shopkeeper stands waiting for something, which is why they are the only loops.
]=]
local AWAY = "Away"
local GREETING = "Greeting"
local ATTENDING = "Attending"
local LEAVING = "Leaving"

--[=[
	The Lobby shopkeeper: rests on their own, stands up on seeing the player approach,
	serves at the counter, and says goodbye, nicely or not, depending on whether the
	player took anything.

	**Distance is measured against `ShopPartReference`, not the body.** It is the same
	center `ShopController` uses to open the shop, just with a larger radius
	(`KEEPER_APPROACH_RADIUS` against `OPEN_RADIUS`). Two concentric radii guarantee the
	scene's order: there is no reaching the counter without crossing the outer radius
	first, so the shop never opens with the shopkeeper still seated.

	Everything here is **client**. The model belongs to the server and is anchored, so
	playing the animations from here keeps them local: each player sees the shopkeeper
	serving them, instead of seeing them stand up because a stranger across the Lobby
	walked by.

	`ShopController` does not know this controller exists. The conversation is one way,
	through its `PurchaseResult`.

	See docs/lobby/shop.md.
]=]
local ShopKeeperController = {
	Controllers = {
		ShopController = {},
	},
}

--[[ INTERNAL ]]

--[=[
	The shopkeeper's model, cached until it leaves the world.

	Looked up by depth under the map for the same reason as the shop markers (see
	`ShopController:_getMapPart`): the artist groups the model, and the code only has its
	name. Leaving the world throws the tracks away too: they belong to that model's
	`Animator`, and the next map's is a different one.
]=]
function ShopKeeperController:_getModel() : Model?
	local cached = self.Model
	if cached and cached.Parent then
		return cached
	end

	if cached then
		self.Tracks = {}
		self.CurrentTrack = nil
	end

	local map = workspace:FindFirstChild(ShopConfig.REFERENCE_PARENT_NAME)
	local model = map and map:FindFirstChild(ShopConfig.KEEPER_MODEL_NAME, true)

	if model and not model:IsA("Model") then
		model = nil
	end

	if not model then
		if not self.WarnedMissing then
			self.WarnedMissing = true
			log:StudioWarn(`no {ShopConfig.KEEPER_MODEL_NAME} under Workspace.{ShopConfig.REFERENCE_PARENT_NAME}.`)
		end

		self.Model = nil
		return nil
	end

	self.Model = model
	return model
end

--[=[
	The `AnimationTrack` of one of the shopkeeper's animations, loaded the first time it is
	needed.

	There is no `Humanoid`: the `Animator` of the `AnimationController` authored on the
	model loads it. An animation that is not there warns once and returns nil, and the
	state machine moves on without the gesture instead of stopping the whole visit.
]=]
function ShopKeeperController:_getTrack(animationName : string) : AnimationTrack?
	local track = self.Tracks[animationName]
	if track then
		return track
	end

	local model = self:_getModel()
	if not model then
		return nil
	end

	local animator = model:FindFirstChildWhichIsA("Animator", true)
	local animation = model:FindFirstChild(animationName)

	if not animator or not animation or not animation:IsA("Animation") then
		if not self.WarnedTracks[animationName] then
			self.WarnedTracks[animationName] = true
			log:StudioWarn(`no {animationName} (or no Animator) under {model:GetFullName()}.`)
		end

		return nil
	end

	track = animator:LoadAnimation(animation)
	self.Tracks[animationName] = track

	return track
end

--[=[
	Swaps the playing animation for this one, with a crossfade.

	The previous track is stopped by hand: without a `Humanoid` nobody resolves priority on
	top, so two tracks playing at once would add both poses into a crooked shopkeeper.
]=]
function ShopKeeperController:_play(animationName : string, looped : boolean) : AnimationTrack?
	local track = self:_getTrack(animationName)
	if not track then
		return nil
	end

	local fade = ShopConfig.KEEPER_FADE_TIME

	if self.CurrentTrack and self.CurrentTrack ~= track then
		self.CurrentTrack:Stop(fade)
	end

	track.Looped = looped
	track:Play(fade)

	self.CurrentTrack = track
	return track
end

--[=[
	Plays a gesture once and, when it ends, enters the next resting state.

	The chaining lives in `ChainMaid`, which `_setState` clears before any change. That is
	what keeps a player who leaves in the middle of `GetUp` from seeing the shopkeeper sit
	at the counter a second after already saying goodbye: the abandoned gesture's `Stopped`
	dies with the state that asked for it.

	Without the track (animation missing on the model), the next state comes in right away:
	the shopkeeper loses the gesture, but does not stall mid-visit.
]=]
function ShopKeeperController:_playThen(animationName : string, nextState : string)
	local track = self:_play(animationName, false)

	if not track then
		self:_setState(nextState)
		return
	end

	local finished = false

	local function advance()
		if finished then
			return
		end

		finished = true
		self:_setState(nextState)
	end

	self.ChainMaid:GiveTask(track.Stopped:Connect(advance))

	--[[
		`Stopped` sets the pace; the cap only exists for the case where it never arrives,
		which is what happens with an `Animation` whose asset did not load: it does not
		play, does not stop, and the shopkeeper would stay frozen mid-gesture forever.

		The thread is not canceled, only disarmed: `task.cancel` on one that already ended
		complains, and an `advance` that does nothing costs less than the pcall around it.
	]]
	task.delay(ShopConfig.KEEPER_GESTURE_TIMEOUT, advance)

	self.ChainMaid:GiveTask(function()
		finished = true
	end)
end

--[=[
	The state machine's only entry point.
]=]
function ShopKeeperController:_setState(state : string)
	if state == self.State then
		return
	end

	self.State = state
	self.ChainMaid:DoCleaning()

	if state == AWAY then
		self:_play(ShopConfig.KEEPER_IDLE_ANIMATION, true)
	elseif state == GREETING then
		self:_playThen(ShopConfig.KEEPER_GET_UP_ANIMATION, ATTENDING)
	elseif state == ATTENDING then
		self:_play(ShopConfig.KEEPER_ATTEND_ANIMATION, true)
	elseif state == LEAVING then
		--[[
			The goodbye comes from what the visit yielded, and the visit is what happened since
			the player crossed the radius, not the whole session. Someone who bought yesterday
			and came back today just to look gets `ByeByeEvil` all the same.
		]]
		local farewell = self.Sold
			and ShopConfig.KEEPER_FAREWELL_SOLD_ANIMATION
			or ShopConfig.KEEPER_FAREWELL_EMPTY_ANIMATION

		self:_playThen(farewell, AWAY)
	end
end

--[=[
	Makes sure the resting pose is actually playing.

	`_setState` asks for the pose only once, which is the right thing for a gesture, but
	a model that has not loaded at boot would make that single attempt fall into the void,
	and the shopkeeper would stay frozen until the next radius crossing. A changed map does
	the same, throwing the old model's tracks away.

	Since both resting states are loops, "the pose is not playing" is always an error, and
	one that can fix itself on the next tick.
]=]
function ShopKeeperController:_ensureResting()
	if self.State ~= AWAY and self.State ~= ATTENDING then
		return
	end

	-- Revalidates the model before looking at the track: `_getModel` throws away the
	-- tracks of a model that left the world, and an orphaned track still answers that it is
	-- playing.
	self:_getModel()

	if self.CurrentTrack and self.CurrentTrack.IsPlaying then
		return
	end

	local resting = self.State == AWAY
		and ShopConfig.KEEPER_IDLE_ANIMATION
		or ShopConfig.KEEPER_ATTEND_ANIMATION

	self:_play(resting, true)
end

--[=[
	Entered or left the approach radius.

	Only the **crossing** acts, just like shop proximity: standing inside the radius, the
	shopkeeper stays in `IdleBench`, without repeating `GetUp` every half second.
]=]
function ShopKeeperController:_update()
	self:_ensureResting()

	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	local shop = self.Controllers.ShopController
	local position = root and shop and shop:GetReferencePosition()

	local near = false
	if position and root then
		near = (root.Position - position).Magnitude <= ShopConfig.KEEPER_APPROACH_RADIUS
	end

	if near == self.PlayerNear then
		return
	end

	self.PlayerNear = near

	if near then
		-- The visit starts from zero: the shopkeeper remembers what the player took **this**
		-- time, not the previous visit's purchase.
		self.Sold = false
		self:_setState(GREETING)
	else
		self:_setState(LEAVING)
	end
end

function ShopKeeperController:_watch()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.Clock += deltaTime

		if self.Clock < ShopConfig.PROXIMITY_INTERVAL then
			return
		end

		self.Clock = 0
		self:_update()
	end))
end

--[[ LIFECYCLE ]]

function ShopKeeperController:construct()
	--[[
		A successful purchase at any moment of the visit already earns the nice goodbye. It
		does not matter if the shop closed between the purchase and leaving: buying and
		leaving through the radius is still the same visit.
	]]
	local shop = self.Controllers.ShopController

	if shop then
		self.Maid:GiveTask(shop.Signals.PurchaseResult:Connect(function(_itemId : string, success : boolean)
			if success then
				self.Sold = true
			end
		end))
	end

	-- Resting from the first second: that is how a player who just joined
	-- finds the shopkeeper, across the plaza.
	self:_setState(AWAY)
	self:_watch()
end

function ShopKeeperController:start()
	self.Maid = Maid.new()
	self.ChainMaid = Maid.new()
	self.Maid:GiveTask(self.ChainMaid)

	self.Model = nil
	self.Tracks = {}
	self.CurrentTrack = nil

	self.WarnedMissing = false
	self.WarnedTracks = {}

	self.State = nil
	self.PlayerNear = false
	self.Sold = false
	self.Clock = 0

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return ShopKeeperController
