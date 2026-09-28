local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared.Util.GameClock)

local Me = require(Vendor.Me)

local Framework = Me.new()

local SpeedConfig = SharedConfig.SpeedConfig

--[[
	The match speed, and there is a single one for the whole room.

	The `Interface.Speed` button belongs to everyone: whoever clicks speeds up the
	match for the others too. There is no reason for it to differ: the simulation
	(enemies walking, towers attacking, waves spawning) belongs to the server, so
	either everyone plays sped up or nobody does. What the client does with the number
	is draw the right art on the button and move enemy models at the same pace.

	**How speed reaches the game.** This service only keeps the step and adjusts the
	server's `GameClock`; no gameplay rule looks at it. The clock is what makes the
	game run faster: `MobService`, `UnitService`, and `WaveService` ask it for "now"
	instead of `os.clock()`, and every duration shrinks on its own. See
	`Shared.Util.GameClock`.

	**The client asks, the server decides.** The click sends the desired step (not
	"advance one"): two players clicking at the same instant both land on 1.5x,
	instead of one pushing the other to 2x. The index comes over the network, so it
	goes through `SpeedConfig.IsValid` before it counts.

	**Back to 1x every round.** The service is in `WaveService`'s round-scoped list: a
	new match starts at normal speed, not at the 2x someone left on in the previous one.

	See docs/game/match-speed.md.
]]

-- How much real time the same player waits between two accepted clicks. Without
-- this, holding the click becomes a burst of broadcasts to the whole room.
local CLICK_COOLDOWN = 0.15

local SpeedService = {
	Services = {},

	-- The step in use, an index into `SpeedConfig.Steps`.
	Index = SpeedConfig.DEFAULT_INDEX,

	--[[
		The scale imposed from outside the button (today, the Time Acceleration card),
		and the token of the override in effect. Nil when the step rules.
	]]
	Override = nil,
	OverrideToken = 0,

	-- [UserId] = os.clock() of the last accepted click.
	LastClick = {},
}

--[[ INTERNAL ]]

--[=[
	Sends the current step. With `player`, only to them (someone who just joined or
	loaded the interface); without it, to the whole room.
]=]
function SpeedService:broadcast(player : Player?)
	if player then
		Framework:Fire("GameSpeedChanged", player, self.Index)
		Framework:Fire("GameSpeedOverride", player, self.Override)
		return
	end

	for _, other in Players:GetPlayers() do
		Framework:Fire("GameSpeedChanged", other, self.Index)
	end
end

--[=[
	Sends the scale imposed from outside the button. It goes separately from the step
	because the two coexist: the button keeps showing the step the room chose while
	the card speeds up the clock on top.
]=]
function SpeedService:broadcastOverride()
	for _, player in Players:GetPlayers() do
		Framework:Fire("GameSpeedOverride", player, self.Override)
	end
end

--- The scale the clock should be at now: the override if there is one, otherwise the step.
function SpeedService:effectiveScale() : number
	return self.Override or SpeedConfig.GetScale(self.Index)
end

--[[ API ]]

function SpeedService:GetIndex() : number
	return self.Index
end

function SpeedService:GetScale() : number
	return SpeedConfig.GetScale(self.Index)
end

--[=[
	Changes the room's step. Returns `false` for an invalid request or for the step
	already in effect; in that case nothing is replicated.
]=]
function SpeedService:SetIndex(index : number) : boolean
	if not SpeedConfig.IsValid(index) then return false end
	if index == self.Index then return false end

	self.Index = index

	-- With an override active, the step changes the button's art and not the clock: the
	-- card rules time until it expires.
	GameClock.SetScale(self:effectiveScale())

	self:broadcast()

	return true
end

--[=[
	Imposes a scale from outside the button, for `duration` **real seconds**.
	`CardShopService` calls it (the Time Acceleration card).

	Outside the button's cycle on purpose: 3x is not a `SpeedConfig` step, and there is
	no art for it: the button keeps showing the step the room chose, and the override
	only touches the clock.

	The seconds are real, not match time. A 15s override measured on the very clock it
	speeds up would last 5 seconds of screen time, and what the card promises is
	fifteen seconds of sped-up play.

	When the deadline passes, the clock returns to the step in effect at that moment,
	not the one in effect when the card was used: someone may have clicked the button
	during the fifteen seconds.
]=]
function SpeedService:SetOverride(scale : number?, duration : number?)
	self.OverrideToken += 1
	local token = self.OverrideToken

	self.Override = scale and math.max(SpeedConfig.GetScale(SpeedConfig.DEFAULT_INDEX), scale) or nil
	GameClock.SetScale(self:effectiveScale())
	self:broadcastOverride()

	if not self.Override or not duration or duration <= 0 then return end

	task.delay(duration, function()
		-- Another override came in midway: its deadline rules now.
		if self.OverrideToken ~= token then return end

		self.Override = nil
		GameClock.SetScale(self:effectiveScale())
		self:broadcastOverride()
	end)
end

--- A new match starts at 1x, even if the previous one ended sped up.
function SpeedService:ResetRound()
	table.clear(self.LastClick)

	self:SetOverride(nil)
	self:SetIndex(SpeedConfig.DEFAULT_INDEX)
end

--[[ LIFECYCLE ]]

function SpeedService:construct()
	GameClock.SetScale(self:effectiveScale())

	Framework:Listen("SetGameSpeed", function(player : Player, index : any)
		local now = os.clock()
		if now - (self.LastClick[player.UserId] or 0) < CLICK_COOLDOWN then return end
		self.LastClick[player.UserId] = now

		self:SetIndex(index)
	end)

	-- The controller asks when it starts: a player joining mid-match already gets the
	-- button at the room's speed.
	Framework:Listen("RequestGameSpeed", function(player : Player)
		self:broadcast(player)
	end)

	Framework:Listen("GameSpeedChanged", function() end)
	Framework:Listen("GameSpeedOverride", function() end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.LastClick[player.UserId] = nil
	end)
end

function SpeedService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function SpeedService:init()
end

return SpeedService
