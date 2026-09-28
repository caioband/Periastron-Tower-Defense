local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Me = require(Vendor.Me)

local Framework = Me.new()

local WeatherConfig = SharedConfig.WeatherConfig

local WEATHER = "Snow"

--[[
	The snow freeze.

	While the `Snow` weather is active, every so often a random unit freezes and
	stops attacking. The attack speed cut everyone gets lives in the
	`WeatherConfig.Effects.Snow` multipliers; only the freeze's beat is here, the one
	part of snow that needs a clock.

	Freezing is the same stun lightning uses (`UnitService:StunUnit`): the client
	already draws the highlight and the unit already stops looking for targets. What
	changes is who can be picked: units immune to the weather (Magic, today) are left
	out of the draw, not just "picked and not frozen", or a map with many Magic units
	would go whole waves with nothing happening.

	It mirrors `ThunderService`: same shape, same place, and the clock resets along
	with the weather so the first freeze always waits a full interval instead of
	landing with the transition.

	See docs/game/weather-in-match.md.
]]

local SnowService = {
	Services = {
		WeatherService = {},
		UnitService = {}
	}
}

SnowService.NextFreeze = nil :: number?

function SnowService:getConfig()
	local effects = WeatherConfig.GetEffects(WEATHER)
	return effects and effects.Freeze
end

--[=[
	Freezes a random unit. Returns the frozen entry, or nil when there was nobody
	eligible on the map.
]=]
function SnowService:FreezeRandom()
	local config = self:getConfig()
	if not config then return nil end

	local unitService = self.Services.UnitService
	if not unitService then return nil end

	return unitService:StunRandomUnit(config.Duration or 0, WEATHER)
end

function SnowService:step(now : number)
	local config = self:getConfig()
	local weatherService = self.Services.WeatherService
	local active = config and weatherService and weatherService:GetCurrent() == WEATHER

	if not active then
		self.NextFreeze = nil
		return
	end

	local interval = config.Interval or 30

	if not self.NextFreeze then
		self.NextFreeze = now + interval
		return
	end

	if now < self.NextFreeze then
		return
	end

	self.NextFreeze = now + interval
	self:FreezeRandom()
end

function SnowService:construct()
	RunService.Heartbeat:Connect(function()
		-- Match time: the stun this weather applies already shrinks with speed
		-- (`UnitService` sets the deadline on the same clock), so the cadence must
		-- shrink too; otherwise speeding up would be a way to take less weather per
		-- wave.
		self:step(GameClock.Now())
	end)
end

function SnowService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function SnowService:init()
end

return SnowService
