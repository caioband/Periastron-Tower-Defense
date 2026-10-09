local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local PathUtil = require(Shared.Util.PathUtil)
local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local DEFAULT_CONTACT_RADIUS = 1.5

local function fireAll(event : string, ...)
	for _, player in Players:GetPlayers() do
		Framework:Fire(event, player, ...)
	end
end

local function atLevel(value, level : number)
	if type(value) == "table" then
		if #value == 0 then return nil end
		return value[math.clamp(level + 1, 1, #value)]
	end
	return value
end

local function segmentDistance(a0 : Vector3, a1 : Vector3, b0 : Vector3, b1 : Vector3) : number
	local p1 = Vector2.new(a0.X, a0.Z)
	local q1 = Vector2.new(a1.X, a1.Z)
	local p2 = Vector2.new(b0.X, b0.Z)
	local q2 = Vector2.new(b1.X, b1.Z)

	local d1 = q1 - p1
	local d2 = q2 - p2
	local r = p1 - p2
	local a = d1:Dot(d1)
	local e = d2:Dot(d2)
	local f = d2:Dot(r)

	if a <= 1e-6 and e <= 1e-6 then
		return r.Magnitude
	end

	local s, t
	if a <= 1e-6 then
		s = 0
		t = math.clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)
		if e <= 1e-6 then
			t = 0
			s = math.clamp(-c / a, 0, 1)
		else
			local b = d1:Dot(d2)
			local denom = a * e - b * b
			s = if denom > 1e-6 then math.clamp((b * f - c * e) / denom, 0, 1) else 0
			t = (b * s + f) / e

			if t < 0 then
				t = 0
				s = math.clamp(-c / a, 0, 1)
			elseif t > 1 then
				t = 1
				s = math.clamp((b - c) / a, 0, 1)
			end
		end
	end

	return ((p1 + d1 * s) - (p2 + d2 * t)).Magnitude
end

local NecromancerService = {
	Services = {
		MobService = {},
		UnitService = {},
	},
	Minions = {},
	MinionCounts = {},
}

function NecromancerService:getConfig(unitName : string?)
	local stats = unitName and SharedConfig.UnitStats[unitName]
	return stats and stats.Necromancy
end

function NecromancerService:GetMinionCount(unitId : string) : number
	return self.MinionCounts[unitId] or 0
end

function NecromancerService:GetMinionHealth(unitName : string, victimMaxHealth : number, level : number) : number
	local config = self:getConfig(unitName)
	local health = config and config.Health or {}

	local scale = atLevel(health.Scale, level) or 0
	local flat = atLevel(health.Flat, level) or 0
	local minimum = math.max(1, health.Min or 1)
	local maximum = math.max(minimum, health.Max or math.huge)

	local raw = (victimMaxHealth or 1) * scale + flat

	return math.clamp(math.floor(raw + 0.5), minimum, maximum)
end

function NecromancerService:canConvert(entry, victim) : boolean
	local config = self:getConfig(entry.unitName)
	if not config or not victim or not victim.Name then return false end

	if config.ExcludeBosses and SharedConfig.Mob.IsBoss(victim.Name) then return false end
	if config.Exclude and table.find(config.Exclude, victim.Name) then return false end

	return true
end

function NecromancerService:TryConvert(entry, victim) : string?
	if not entry or not self:canConvert(entry, victim) then return nil end

	return self:spawnMinion(entry, victim)
end

function NecromancerService:snapshot(minion)
	return {
		Id = minion.Id,
		Name = minion.Name,
		UnitName = minion.UnitName,
		UnitId = minion.UnitId,
		Route = minion.RouteIndex,
		Distance = minion.Distance,
		Speed = minion.Speed,
		Health = minion.Health,
		MaxHealth = minion.MaxHealth,
	}
end

function NecromancerService:spawnMinion(entry, victim) : string?
	local config = self:getConfig(entry.unitName)
	local routes = self.Services.MobService:getRoutes()

	local routeIndex = victim.RouteIndex or 1
	if not routes[routeIndex] then
		routeIndex = 1
	end

	local route = routes[routeIndex]
	if not route or not route.smooth or route.smooth.length <= 0 then return nil end

	local maxHealth = self:GetMinionHealth(entry.unitName, victim.MaxHealth or 1, entry.upgrades or 0)
	local speed = (victim.BaseSpeed or SharedConfig.Mob.BaseSpeed) * (victim.SpeedScale or 1) * (config.SpeedScale or 1)

	local minionId = HttpService:GenerateGUID(false)
	local minion = {
		Id = minionId,
		Name = victim.Name,
		UnitName = entry.unitName,
		UnitId = entry.unitId,
		OwnerUserId = entry.ownerUserId,
		RouteIndex = routeIndex,
		Smooth = route.smooth,
		Distance = route.smooth.length,
		Speed = speed,
		Health = maxHealth,
		MaxHealth = maxHealth,
		ContactRadius = config.ContactRadius or DEFAULT_CONTACT_RADIUS,
		Classes = SharedConfig.WeatherConfig.GetClasses(entry.unitName),
		Ignored = {},
	}

	self.Minions[minionId] = minion
	self.MinionCounts[entry.unitId] = self:GetMinionCount(entry.unitId) + 1

	fireAll("MinionSpawned", self:snapshot(minion))

	return minionId
end

function NecromancerService:removeMinion(minionId : string, reason : string)
	local minion = self.Minions[minionId]
	if not minion then return end

	self.Minions[minionId] = nil

	local count = self:GetMinionCount(minion.UnitId) - 1
	self.MinionCounts[minion.UnitId] = if count > 0 then count else nil

	fireAll("MinionRemoved", minionId, reason)
end

function NecromancerService:clear()
	for minionId in self.Minions do
		fireAll("MinionRemoved", minionId, "Reset")
	end

	table.clear(self.Minions)
	table.clear(self.MinionCounts)
end

function NecromancerService:trade(minion, mobId : string, mob)
	local mobService = self.Services.MobService
	local unitService = self.Services.UnitService

	local enemyHealth = mob.Health
	local request = math.max(1, math.ceil(minion.Health))

	local dealt = mobService:DamageMob(mobId, request, minion.OwnerUserId, 0, nil, minion.Classes)
	if dealt <= 0 then
		minion.Ignored[mobId] = true
		return
	end

	local entry = unitService.UnitsById[minion.UnitId]
	if entry then
		unitService:addDamageDone(entry, dealt)
	end

	fireAll("MobDamageTick", mobId, dealt)

	minion.Health = math.max(0, minion.Health - math.min(minion.Health, enemyHealth))
	fireAll("MinionHit", minion.Id, minion.Health)
end

function NecromancerService:step(dt : number)
	if next(self.Minions) == nil then return end

	local mobService = self.Services.MobService
	if not mobService or not mobService.ActiveMobs then return end

	if (mobService.BaseHealth or 0) <= 0 then
		self:clear()
		return
	end

	local scaled = GameClock.Scaled(dt)

	for minionId, minion in self.Minions do
		local from = PathUtil.GetPositionAtDistance(minion.Smooth, minion.Distance)
		minion.Distance = math.max(0, minion.Distance - minion.Speed * scaled)
		local to = PathUtil.GetPositionAtDistance(minion.Smooth, minion.Distance)

		if from and to then
			for mobId, mob in mobService.ActiveMobs do
				if minion.Ignored[mobId] then continue end

				local current = mobService:getMobPosition(mobId)
				if not current then continue end

				local previous = mobService:getPreviousMobPosition(mobId) or current

				if segmentDistance(from, to, previous, current) <= minion.ContactRadius then
					self:trade(minion, mobId, mob)

					if minion.Health <= 0 then break end
				end
			end
		end

		if minion.Health <= 0 then
			self:removeMinion(minionId, "Died")
		elseif minion.Distance <= 0 then
			self:removeMinion(minionId, "Exit")
		end
	end
end

function NecromancerService:ResetRound()
	self:clear()
end

function NecromancerService:start()
	for name in self.Services do
		self.Services[name] = Framework:Get(name)
	end

	Framework:Listen("MinionSpawned", function() end)
	Framework:Listen("MinionHit", function() end)
	Framework:Listen("MinionRemoved", function() end)

	Framework:Listen("ClientReady", function(player)
		for _, minion in self.Minions do
			Framework:Fire("MinionSpawned", player, self:snapshot(minion))
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		self:step(dt)
	end)
end

function NecromancerService:init()
end

return NecromancerService