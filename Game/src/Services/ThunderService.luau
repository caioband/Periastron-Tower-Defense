local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.WeatherConfig.Thunder
local WeatherConfig = SharedConfig.WeatherConfig

--[[
	Thunder weather strikes.

	While the `Config.Weather` weather is on, a strike falls every `Config.Interval`
	seconds. Where it falls is random: on top of a placed unit, or at any point inside
	the map's BoundingBox.

	The chance of hitting a unit is a pity: it rises with each strike that hits the
	ground and returns to the floor when one hits. Without it, a low fixed chance could
	go a whole match without a strike on any unit; a high fixed chance would turn the
	weather into a machine gun on the towers.

	The server only decides **when** and **where**: `VFXController` draws it, because
	the `ReplicatedStorage.vfx` module is client-only. Rolling here is what makes
	everyone see the same strike in the same place.

	It lives in Game because it depends on `UnitService` and the loaded map. The
	weather itself is shared (`common/server/Services/WeatherService`).

	The strike does not take health: it stuns. A unit hit squarely stops for
	`Stun.Direct` (20s, the whole wave), and the shock jumps to nearby units, which
	stop for `Stun.Chain` (5s). `Electric` units are the exception that makes the
	weather worth it for someone: besides `Effects.Thunder`'s passive bonus, being
	struck does **not** stun them; it charges them with more damage and a shorter
	cooldown for `Charge.Duration`. All the numbers are in `WeatherConfig.Thunder`.

	See docs/game/weather-in-match.md.
]]

local ThunderService = {
	Services = {
		WeatherService = {},
		UnitService = {}
	}
}

ThunderService.NextStrike = nil :: number?
ThunderService.UnitChance = Config.UnitChance

--[[ TARGETS ]]

--[=[
	Any placed unit, or nil if there is none.

	`unitName` restricts to one unit type: the `strike` command uses it to test the
	strike on a specific unit instead of waiting for luck.
]=]
function ThunderService:pickTarget(unitName : string?, skipImmune : boolean?)
	local unitService = self.Services.UnitService
	local units = unitService and unitService.PlacedUnits
	if not units or #units == 0 then
		return nil
	end

	--[[
		A unit immune to thunder leaves the draw instead of being drawn and ignored.

		It would not be stunned anyway, and leaving it in the pool would spoil the pity:
		every strike spent on a Magic unit would count as "hit a unit" and the chance
		would return to the floor with nothing happening on screen.

		This only applies to the weather's strike. The `strike` command still reaches
		any unit, because testing the visual on a Magic unit is legitimate.
	]]
	local matches = {}
	for _, entry in units do
		if unitName and entry.unitName ~= unitName then continue end
		if skipImmune and WeatherConfig.IsImmune(Config.Weather, entry.unitName) then continue end

		table.insert(matches, entry)
	end

	if #matches == 0 then
		return nil
	end

	return matches[math.random(1, #matches)]
end

function ThunderService:getMap() : Instance?
	return workspace:FindFirstChild(WeatherConfig.TargetName)
end

--[=[
	A point on the ground inside the map box.

	X and Z are drawn from the box; Y comes from a downward ray, because the terrain
	has varying height and dropping the strike at the bottom of the box would bury it
	in the high parts. The BoundingBox itself does not get in the query's way:
	`LoadMap` clones it with `CanQuery` off.
]=]
function ThunderService:pickGround() : Vector3?
	local target = self:getMap()
	if not target then
		return nil
	end

	local weatherService = self.Services.WeatherService
	if not weatherService then
		return nil
	end

	local center, size = weatherService:GetMapBounds(target)
	if not center or not size then
		return nil
	end

	local x = center.X + (math.random() - 0.5) * size.X
	local z = center.Z + (math.random() - 0.5) * size.Z
	local top = center.Y + size.Y / 2
	local bottom = center.Y - size.Y / 2

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { target }

	local result = workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, bottom - top, 0), params)

	-- A hole in the map (or a point outside the geometry): the bottom of the box will do.
	return result and result.Position or Vector3.new(x, bottom, z)
end

--[[ STRIKE EFFECT ]]

--[=[
	Units within the arc's reach, from a point.

	`hit` is who already got shocked in this discharge: neither target nor bridge.
	Without it the arc would go back to whoever it just hit and the jump would never
	end.
]=]
function ThunderService:findChainTargets(origin : Vector3, hit : { [string]: boolean })
	local unitService = self.Services.UnitService
	local units = unitService and unitService.PlacedUnits
	if not units then
		return {}
	end

	local radius = Config.Stun.Radius or 0
	local found = {}

	for _, entry in units do
		if hit[entry.unitId] then continue end
		if WeatherConfig.IsImmune(Config.Weather, entry.unitName) then continue end

		if (entry.cf.Position - origin).Magnitude <= radius then
			table.insert(found, entry)
		end
	end

	return found
end

--[=[
	What a unit gets for being touched by the strike.

	A stun for everyone except `Electric` units: they get the charge instead, with
	damage above and cooldown below normal for a few seconds. It is the other side of
	thunder: for most units it is a lost wave, and for Electric it is the best wave of
	the match.

	Electric still serves as a bridge for the arc: the jump leaves from it like from
	any other hit unit.
]=]
function ThunderService:applyHit(entry, duration : number)
	local unitService = self.Services.UnitService
	if not unitService then return end

	if not WeatherConfig.HasClass(entry.unitName, "Electric") then
		unitService:StunUnit(entry, duration)
		return
	end

	local charge = Config.Charge
	if not charge then return end

	unitService:ChargeUnit(entry, charge.Damage, charge.AttackSpeed, charge.Duration or 0)
end

--[=[
	The whole discharge, starting from the unit the strike hit squarely.

	The jump moves in layers: units within the hit unit's radius get `Chain`, units
	within *their* radius get it in the next layer, up to `Hops` layers. With today's
	`Hops = 1` there is only one layer, but the search is breadth-first because the
	number is config, and a recursive implementation without visited tracking would
	bounce between two neighboring units forever.

	Each unit is touched only once per discharge, and the jump's stun is much shorter
	than the direct hit's (5s against 20s): a well-placed strike should hurt, not
	black out the map.

	Returns the drawn arcs, so the client links the units with the same asset as the
	strike.
]=]
function ThunderService:chainFrom(entry)
	local stun = Config.Stun
	if not stun then return {} end

	local hit = { [entry.unitId] = true }
	local links = {}

	local frontier = { entry }
	local hops = math.max(0, stun.Hops or 0)
	local maxTargets = stun.MaxTargets or math.huge

	for _ = 1, hops do
		local nextFrontier = {}

		for _, source in frontier do
			local targets = self:findChainTargets(source.cf.Position, hit)

			for index, target in targets do
				if index > maxTargets then break end

				hit[target.unitId] = true
				self:applyHit(target, stun.Chain or 0)
				table.insert(nextFrontier, target)

				table.insert(links, {
					fromId = source.unitId,
					toId = target.unitId,
					from = source.cf.Position,
					to = target.cf.Position,
				})
			end
		end

		if #nextFrontier == 0 then break end
		frontier = nextFrontier
	end

	return links
end

--[[ STRIKES ]]

local function broadcast(position : Vector3, unitId : string?)
	for _, player in Players:GetPlayers() do
		Framework:Fire("LightningStrike", player, position, unitId)
	end
end

-- The jump's arcs, so the client links one unit to another with the same asset as
-- the strike. An empty list does not become an event.
local function broadcastChain(links)
	if #links == 0 then return end

	for _, player in Players:GetPlayers() do
		Framework:Fire("LightningChain", player, links)
	end
end

--[=[
	A strike on a unit. Returns the hit entry, or nil if there was no target: that is
	what the `strike` command uses to say whom it hit.

	The `unitId` goes along with the position: the client refines it to the model's
	exact feet, which it measures from the unit's box. The position from here is only
	the fallback for when the model has not replicated yet.
]=]
function ThunderService:strikeUnit(unitName : string?, skipImmune : boolean?)
	local entry = self:pickTarget(unitName, skipImmune)
	if not entry then
		return nil
	end

	broadcast(entry.cf.Position, entry.unitId)

	--[[
		The visual goes first and the effect after, on the same execution line: both
		arrive on the same frame, and the order only decides which event the client
		processes first. The strike going first is what makes the stun highlight appear
		*with* the flash instead of blinking before it.
	]]
	local stun = Config.Stun
	if stun and not WeatherConfig.IsImmune(Config.Weather, entry.unitName) then
		self:applyHit(entry, stun.Direct or 0)
		broadcastChain(self:chainFrom(entry))
	end

	return entry
end

-- A strike at any point on the map. Returns where it fell, or nil if it could not measure.
function ThunderService:strikeGround() : Vector3?
	local position = self:pickGround()
	if not position then
		return nil
	end

	broadcast(position, nil)
	return position
end

--[=[
	A weather strike: draws between unit and ground, and updates the pity.

	Hit a unit: the chance returns to the floor. Fell on the ground **with units on
	the map**: it goes up a step. With no units at all the chance stays put; see the
	`UnitChance` comment in the config.
]=]
function ThunderService:rollStrike()
	local hasUnits = self:pickTarget(nil, true) ~= nil

	if hasUnits and math.random() < self.UnitChance then
		if self:strikeUnit(nil, true) then
			self.UnitChance = Config.UnitChance
			return
		end
	end

	self:strikeGround()

	if hasUnits then
		self.UnitChance = math.min(Config.MaxUnitChance, self.UnitChance + Config.UnitChanceStep)
	end
end

--[=[
	The beat.

	The clock only runs with the weather on, and resets when it leaves: that way
	turning thunder on does not fire a strike left over from the previous time, and
	the first strike always waits a full interval instead of falling with the weather
	change. The pity resets too: the new weather starts at the floor.
]=]
function ThunderService:step(now : number)
	local weatherService = self.Services.WeatherService
	local active = weatherService and weatherService:GetCurrent() == Config.Weather

	if not active then
		self.NextStrike = nil
		self.UnitChance = Config.UnitChance
		return
	end

	if not self.NextStrike then
		self.NextStrike = now + Config.Interval
		return
	end

	if now < self.NextStrike then
		return
	end

	self.NextStrike = now + Config.Interval
	self:rollStrike()
end

function ThunderService:construct()
	RunService.Heartbeat:Connect(function()
		-- Match time: the stun this weather applies already shrinks with speed
		-- (`UnitService` sets the deadline on the same clock), so the cadence must
		-- shrink too; otherwise speeding up would be a way to take less weather per
		-- wave.
		self:step(GameClock.Now())
	end)
end

function ThunderService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function ThunderService:init()
	Framework:Listen("LightningStrike", function() end)
	Framework:Listen("LightningChain", function() end)
end

return ThunderService
