local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("FootstepController")
local Player = Players.LocalPlayer

--[[
	Player footsteps, entirely on the client.

	The animation keeps the beat, not a timer: the Walk and Run animations carry an
	Animation Event (KeyframeMarker) called "Step", and each firing becomes a step.
	That way the sound lands with the foot on screen at any speed, and a new
	animation joins the system just by having the marker: there is no animation list
	to maintain here.

	The marker can carry a value naming the foot ("Left" / "Right"); without a value,
	the controller alternates on its own.

	The surface does not come from Material (the game is studs, and Material means
	nothing): it comes from the `Surface` attribute of the Part the ray under the
	foot hits, also searched in its ancestors, so a whole model can be tagged at
	once. Each surface's ids live in SharedConfig.FootstepConfig.

	It lives in common/ because Me scans Controllers.Common in both places.

	See docs/common/footsteps.md.
]]

local Config = SharedConfig.FootstepConfig

local MARKER = "Step"

-- Foot names, in order of preference: R15 first, R6 next, and the torso as a
-- last resort (a custom rig with neither).
local FOOT_PARTS = {
	Left = { "LeftFoot", "LeftLowerLeg", "Left Leg", "HumanoidRootPart" },
	Right = { "RightFoot", "RightLowerLeg", "Right Leg", "HumanoidRootPart" },
}


local FootstepController = {
	Controllers = {},
}

FootstepController._maid = nil
FootstepController._character = nil :: Model?
FootstepController._humanoid = nil :: Humanoid?
FootstepController._nextFoot = "Right"
FootstepController._lastStep = 0
FootstepController._lastJump = 0
FootstepController._lastId = {} :: { [string]: string } -- last variation per surface
FootstepController._warned = {} :: { [string]: boolean }

--[[
	Ready sounds, one per (foot, id). The step itself creates nothing: it only picks
	the variation, adjusts pitch/volume, and plays. See `_buildPool`.
]]
FootstepController._pool = {} :: { [string]: { [string]: Sound } }

-- Instances that exist only to hold the assets in the client cache.
FootstepController._warmFolder = nil :: Folder?

--[[
	Tracks that already have a listener. The default Animate loads the track once and
	plays it again every time the player starts walking, and `AnimationPlayed` fires
	on every play: without this, stopping and walking again would hang another
	connection on the same track, and the marker would end up firing N times per step.
]]
FootstepController._boundTracks = setmetatable({}, { __mode = "k" }) :: any

--[[
	Who may send steps, and since when.

	Walking and running play at the same time: the default `Animate` keeps walk
	playing while MovementController's Run plays on top (it never stops walk). If both
	animations have the marker, each step becomes two, in different phases because
	the animations have different lengths, so not even the minimum interval stops it.

	The rule: the last one to start wins, among tracks that have the marker and are
	still playing. So Run takes over when running starts and walk resumes on its own
	when Run stops.
]]
FootstepController._markerTracks = setmetatable({}, { __mode = "k" }) :: any
FootstepController._trackStarted = setmetatable({}, { __mode = "k" }) :: any

--[[ WARNINGS ]]

-- One warning per surface per session: steps repeat too often to warn every time.
function FootstepController:_warnOnce(key: string, message: string)
	log:StudioWarnOnce(key, message)
end

--[[ SURFACE ]]

--[[
	Finds the requested foot on the rig. R15 has LeftFoot/RightFoot, R6 has "Left
	Leg"/"Right Leg"; if neither exists, the step still plays, but from the middle of
	the character.
]]
function FootstepController:_getFoot(character: Model, side: string): BasePart?
	for _, name in FOOT_PARTS[side] or {} do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end

	return nil
end

--[[
	Walks up the hierarchy looking for the attribute. Tagging the Part is the normal
	case, but tagging the Model/Folder that contains it covers a whole scene at once.
]]
function FootstepController:_readSurface(instance: Instance?): string?
	local current = instance

	while current and current ~= workspace do
		local value = current:GetAttribute(Config.Attribute)
		if type(value) == "string" and value ~= "" then
			return value
		end
		current = current.Parent
	end

	return nil
end

-- A short ray down from the foot, ignoring the character itself.
function FootstepController:_surfaceUnder(footPart: BasePart, character: Model): (string?, BasePart?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	-- Ground is what can be stepped on: a part without collision (preview, AOE,
	-- decoration) must not answer for the sound.
	params.RespectCanCollide = true

	local result = workspace:Raycast(footPart.Position, Vector3.new(0, -Config.RayLength, 0), params)
	if not result then
		return nil, nil
	end

	return self:_readSurface(result.Instance) or Config.Default, result.Instance
end

--[[ CACHE ]]

-- Every configured id, without repeats (the same variation may serve two
-- surfaces). The jump goes in here too: it uses the same pool and the same cache.
function FootstepController:_allIds(): { string }
	local seen, list = {}, {}

	local function add(entry)
		for _, id in (entry and entry.Ids) or {} do
			if not seen[id] then
				seen[id] = true
				table.insert(list, id)
			end
		end
	end

	for _, surface in Config.Surfaces do
		add(surface)
	end
	add(Config.Jump)

	return list
end

--[[
	Pulls the assets into the client cache once, on join.

	These instances never play: they exist only so the download has already
	happened when the first step asks for the sound, including after dying, since
	the feet pool is rebuilt per character and the cache is not.
]]
function FootstepController:_warmCache()
	if self._warmFolder then
		return
	end

	local ids = self:_allIds()
	if #ids == 0 then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "FootstepCache"
	folder.Parent = SoundService
	self._warmFolder = folder

	local sounds = {}
	for _, id in ids do
		local sound = Instance.new("Sound")
		sound.Name = id
		sound.SoundId = id
		sound.Volume = 0
		sound.Parent = folder
		table.insert(sounds, sound)
	end

	-- Yields: stays off the init thread.
	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(sounds)
		end)

		if not ok then
			log:StudioWarn(`failed to preload the footsteps: {err}`)
			return
		end

		for _, sound in sounds do
			if not sound.IsLoaded then
				self:_warnOnce(`preload:{sound.SoundId}`, `{sound.SoundId} did not load; steps using this variation will be silent or late.`)
			end
		end
	end)
end

--[[
	One ready Sound per (foot, id), hung on the foot itself.

	Hung on the foot because the sound is 3D and must follow the character; one per
	id because changing an instance's SoundId at step time would bring back the
	loading wait this pool exists to eliminate.
]]
function FootstepController:_buildPool(character: Model)
	self._pool = {}

	local ids = self:_allIds()
	if #ids == 0 then
		return
	end

	local created = {}

	for side in FOOT_PARTS do
		local footPart = self:_getFoot(character, side)
		if footPart then
			local bySide = {}
			self._pool[side] = bySide

			for _, id in ids do
				local sound = Instance.new("Sound")
				sound.Name = `Footstep_{side}`
				sound.SoundId = id
				sound.RollOffMinDistance = Config.RollOffMin
				sound.RollOffMaxDistance = Config.RollOffMax
				sound.Parent = footPart
				bySide[id] = sound
				table.insert(created, sound)
			end
		end
	end

	-- The assets already came in through `_warmCache`, so this resolves from the cache
	-- and only makes sure these instances are ready before the first step.
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(created)
		end)
	end)
end

--[[ SOUND ]]

-- Picks a variation, avoiding the surface's previous one.
function FootstepController:_pickId(surfaceName: string, ids: { string }): string?
	if #ids == 0 then
		return nil
	end
	if #ids == 1 then
		return ids[1]
	end

	local chosen = ids[math.random(#ids)]
	if chosen == self._lastId[surfaceName] then
		-- One retry is enough: with N >= 2 it lands on another in practice, and it is
		-- not worth looping over a footstep.
		chosen = ids[math.random(#ids)]
	end

	self._lastId[surfaceName] = chosen
	return chosen
end

--[[
	Plays the step on an instance that already exists and is already loaded.

	Creating the Sound at step time put the sound out of place: a freshly assigned
	SoundId loads asynchronously, so `:Play()` does not sound when called, but when
	the asset finishes arriving. While the first one loaded, the next steps piled
	up, and all of them sounded together the instant loading finished: delayed and
	stacked steps.
]]
--[[
	Plays a config entry (surface or jump) on a pool instance.

	`key` is only the entry's identity: it serves the "which variation played last
	time" memory and keeps warnings from mixing.
]]
function FootstepController:_playFrom(entry, key: string, side: string)
	local id = self:_pickId(key, entry.Ids or {})
	if not id then
		self:_warnOnce(`ids:{key}`, `"{key}" has no id configured.`)
		return
	end

	local sound = self._pool[side] and self._pool[side][id]
	if not sound or not sound.Parent then
		self:_warnOnce(`pool:{id}`, `no sound ready for {id} on the {side} foot; did not play.`)
		return
	end

	local range = entry.PitchRange or Config.PitchRange
	sound.Volume = (entry.Volume or 1) * Config.Volume
	sound.PlaybackSpeed = range[1] + math.random() * (range[2] - range[1])

	-- The same instance may be requested again before it ends: it goes back to the
	-- start instead of ignoring Play. Since feet alternate and variations do not
	-- repeat, in practice each instance is only reused long after the clip ended.
	sound.TimePosition = 0
	sound:Play()

	if not sound.IsLoaded then
		self:_warnOnce(`notloaded:{id}`, `{id} was not loaded yet; the sound may play late.`)
	end
end

function FootstepController:_playStep(surfaceName: string, side: string)
	local surface = Config.Surfaces[surfaceName]
	if not surface then
		self:_warnOnce(`surface:{surfaceName}`, `surface "{surfaceName}" does not exist in SharedConfig.FootstepConfig.Surfaces.`)
		return
	end

	self:_playFrom(surface, surfaceName, side)
end

--[[ STEP ]]

--[[
	Plays the step for the ground under the requested foot. The shared path for the
	animation marker and landing.
]]
function FootstepController:_stepOnSurface(side: string)
	local character = self._character
	if not character or not character.Parent then
		return
	end

	local footPart = self:_getFoot(character, side)
	if not footPart then
		return
	end

	local surfaceName, hitPart = self:_surfaceUnder(footPart, character)
	if not surfaceName then
		if hitPart then
			self:_warnOnce(
				`untagged:{hitPart:GetFullName()}`,
				`{hitPart:GetFullName()} has no "{Config.Attribute}" attribute; silent step.`
			)
		end
		return
	end

	self:_playStep(surfaceName, side)
end

-- Consumes the next foot in the alternation.
function FootstepController:_takeFoot(preferred: string?): string
	local side = preferred
	if side ~= "Left" and side ~= "Right" then
		side = self._nextFoot
	end

	self._nextFoot = if side == "Left" then "Right" else "Left"
	return side :: string
end

--[[
	A lock shared by the marker and landing: without it, landing while already
	walking would play the landing step and the next marker's step almost together.
]]
function FootstepController:_canStep(): boolean
	local now = os.clock()
	local sinceLast = now - self._lastStep

	if sinceLast < Config.MinInterval then
		-- Worth knowing: if this shows up a lot, it is a duplicated marker in the
		-- animation (or two tracks playing the same animation), not a sound problem.
		log:Debug(string.format("step skipped: %.0fms since the previous one, minimum is %.0fms",
			sinceLast * 1000, Config.MinInterval * 1000))
		return false
	end

	self._lastStep = now
	return true
end

--[[
	A "Step" marker firing.

	`markerValue` is the value the marker carries in the animation, if any: "Left"
	or "Right" pins the foot. Without a value it alternates, which already covers a
	normal walk, where markers come one per side.
]]
function FootstepController:_onStep(markerValue: string?)
	local character = self._character
	local humanoid = self._humanoid
	if not character or not character.Parent or not humanoid then
		return
	end

	-- No steps in the air: a jump or fall may cross the end of a walk cycle.
	if humanoid.FloorMaterial == Enum.Material.Air then
		return
	end

	if not self:_canStep() then
		return
	end

	self:_stepOnSurface(self:_takeFoot(markerValue))
end

--[[
	Landing: the same step sound, for the ground landed on.

	It skips the `FloorMaterial` check: on the frame `Landed` fires it may still be
	`Air`, and then the fall's sound would vanish. The ray under the foot, which by
	then already reaches the ground, says where they stepped.
]]
function FootstepController:_onLanded()
	local character = self._character
	if not character or not character.Parent then
		return
	end

	if not self:_canStep() then
		return
	end

	local side = self:_takeFoot(nil)
	log:Debug("landed | foot", side)
	self:_stepOnSurface(side)
end

--[[
	Jump.

	Outside the step lock on purpose: someone jumping while walking just took a step,
	and the lock would eat the jump sound. The lock here only guards against the
	`Jumping` state being re-entered within the same jump.

	It also does not consume the foot alternation (jumping is not stepping) and does
	not look at the surface: the jump sound is the same on any ground.
]]
function FootstepController:_onJumped()
	local character = self._character
	if not character or not character.Parent then
		return
	end

	if not Config.Jump then
		return
	end

	local now = os.clock()
	if now - self._lastJump < Config.MinInterval then
		return
	end
	self._lastJump = now

	log:Debug("jumped")
	self:_playFrom(Config.Jump, "Jump", self._nextFoot)
end

--[[ LIFECYCLE ]]

--[[
	Whether this track is the one driving steps now: the last to start, among those
	that have the marker and are still playing. With none playing, it takes over
	itself.
]]
function FootstepController:_ownsSteps(track: AnimationTrack): boolean
	local owner, startedAt = nil, -math.huge

	for other in self._markerTracks do
		if other.IsPlaying then
			local at = self._trackStarted[other] or 0
			if at > startedAt then
				owner, startedAt = other, at
			end
		end
	end

	return owner == nil or owner == track
end

function FootstepController:_bindTrack(track: AnimationTrack)
	local maid = self._maid
	if not maid then return end

	-- Before the dedupe: `AnimationPlayed` fires on every play of the same track, and
	-- that is exactly what marks "just started".
	self._trackStarted[track] = os.clock()

	if self._boundTracks[track] then return end
	self._boundTracks[track] = true

	local animationId = track.Animation and track.Animation.AnimationId or "?"

	-- A track without the marker simply never fires: connecting to all of them costs
	-- nothing and lets the animation itself say whether it has steps.
	maid:GiveTask(track:GetMarkerReachedSignal(MARKER):Connect(function(value: string?)
		self._markerTracks[track] = true

		if not self:_ownsSteps(track) then
			log:Debug(string.format("marker from %s skipped: another animation with a marker started later and is playing", track.Name))
			return
		end

		log:Debug(string.format(`marker "{MARKER}" fired | animation %s (%s) | value %s | %.0fms since the previous one`,
			track.Name, animationId, value or "(no value)", (os.clock() - self._lastStep) * 1000))
		self:_onStep(value)
	end))
end

function FootstepController:_bindCharacter(character: Model)
	if self._maid then
		self._maid:DoCleaning()
	end

	local maid = Maid.new()
	self._maid = maid
	-- New character, new tracks: the old ones died with the previous Animator.
	self._boundTracks = setmetatable({}, { __mode = "k" }) :: any
	self._markerTracks = setmetatable({}, { __mode = "k" }) :: any
	self._trackStarted = setmetatable({}, { __mode = "k" }) :: any

	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end

	local animator = humanoid:WaitForChild("Animator", 10)
	if not animator or not animator:IsA("Animator") then
		return
	end

	self._character = character
	self._humanoid = humanoid
	self._nextFoot = "Right"

	-- Before hooking up the listeners: when the first marker fires, the sound must
	-- already be hung on the foot and ready.
	self:_buildPool(character)

	-- Walk comes from the default Animate and Run from MovementController: both go
	-- through the same Animator, so a single listener covers both.
	maid:GiveTask(animator.AnimationPlayed:Connect(function(track)
		self:_bindTrack(track)
	end))

	-- Tracks already playing when the character appeared.
	for _, track in animator:GetPlayingAnimationTracks() do
		self:_bindTrack(track)
	end

	-- Falling is stepping too; and the jump has its own sound.
	maid:GiveTask(humanoid.StateChanged:Connect(function(_, newState)
		if newState == Enum.HumanoidStateType.Landed then
			self:_onLanded()
		elseif newState == Enum.HumanoidStateType.Jumping then
			self:_onJumped()
		end
	end))

	-- The pool dies with the feet; the table is what must be released, or it would
	-- keep pointing at Sounds of a character that no longer exists.
	maid:GiveTask(function()
		self._character = nil
		self._humanoid = nil
		self._pool = {}
	end)
end

function FootstepController:construct()
	-- Once per session, and before the first character: the client cache survives
	-- death and respawn, the feet pool does not.
	self:_warmCache()

	local function onCharacter(character: Model)
		self:_bindCharacter(character)
	end

	if Player.Character then
		task.spawn(onCharacter, Player.Character)
	end

	Player.CharacterAdded:Connect(onCharacter)

	Player.CharacterRemoving:Connect(function()
		if self._maid then
			self._maid:DoCleaning()
			self._maid = nil
		end
	end)
end

function FootstepController:start() end

function FootstepController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

return FootstepController
