local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local Settings = require(ServerScriptService:WaitForChild("Config"):WaitForChild("SuffocateAbility"))
local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local function fireAll(event : string, ...)
	for _, player in Players:GetPlayers() do
		Framework:Fire(event, player, ...)
	end
end

local SuffocateAbilityService = {
	Services = {
		MobService = {},
		UnitService = {},
	},
	Triggered = setmetatable({}, { __mode = "k" }),
	Suffocations = {},
}

function SuffocateAbilityService:appliesTo(mob) : boolean
	return table.find(Settings.Enemies, mob.Name) ~= nil
end

function SuffocateAbilityService:pickVictim()
	local pool = {}
	for _, entry in self.Services.UnitService.PlacedUnits do
		if not entry.Suffocating and not table.find(Settings.ExceptUnits or {}, entry.unitName) then
			table.insert(pool, entry)
		end
	end
	if #pool == 0 then
		return nil
	end
	return pool[math.random(1, #pool)]
end

function SuffocateAbilityService:beginSuffocation(mobId : string, mob, entry)
	local duration = math.max(0.1, Settings.Duration or 4)
	local endsAt = GameClock.Now() + duration
	local previousStun = entry.StunnedUntil or 0

	entry.Suffocating = true
	entry.StunnedUntil = math.max(previousStun, endsAt)

	table.insert(self.Suffocations, {
		MobId = mobId,
		Mob = mob,
		Entry = entry,
		EndsAt = endsAt,
		PreviousStun = previousStun,
		AppliedStun = entry.StunnedUntil,
	})

	fireAll("UnitSuffocate", entry.unitId, duration, Settings.UnitAnim or "Suffocated", Settings.UnitVFX or "")
end

function SuffocateAbilityService:playCast(mobId : string, mob)
	local mobService = self.Services.MobService
	local castTime = math.max(0, Settings.CastTime or 0)
	local stopping = castTime > 0 and Settings.StopWhileCasting ~= false

	if stopping then
		mob.StunnedUntil = math.max(mob.StunnedUntil or 0, GameClock.Now() + castTime)
		fireAll("UpdateMobSpeed", mobId, 0)
	end

	if Settings.EnemyAnim then
		fireAll("MobPlayAnim", mobId, Settings.EnemyAnim)
	end

	if stopping then
		GameClock.Delay(castTime, function()
			if mobService.ActiveMobs[mobId] ~= mob then
				return
			end
			if (mob.StunnedUntil or 0) <= GameClock.Now() then
				fireAll("UpdateMobSpeed", mobId, mob.CurrentSpeed)
			end
		end)
	end
end

function SuffocateAbilityService:trigger(mobId : string, mob) : boolean
	local entry = self:pickVictim()
	if not entry then
		return false
	end

	self.Triggered[mob] = true
	self:beginSuffocation(mobId, mob, entry)
	self:playCast(mobId, mob)
	return true
end

function SuffocateAbilityService:Trigger(mobId : string) : boolean
	local mob = self.Services.MobService.ActiveMobs[mobId]
	if not mob or self.Triggered[mob] then
		return false
	end
	return self:trigger(mobId, mob)
end

function SuffocateAbilityService:removeUnit(entry, fadeTime : number)
	local unitService = self.Services.UnitService

	for index, placed in ipairs(unitService.PlacedUnits) do
		if placed == entry then
			table.remove(unitService.PlacedUnits, index)
			break
		end
	end

	unitService.UnitsById[entry.unitId] = nil

	local unitId = entry.unitId
	if fadeTime > 0 then
		fireAll("UnitSuffocateFade", unitId, fadeTime)
		task.delay(fadeTime, function()
			fireAll("RemoveUnit", unitId)
		end)
	else
		fireAll("RemoveUnit", unitId)
	end
end

-- Mirrors MobService:SpawnWave, for a single enemy placed mid-path.
function SuffocateAbilityService:spawnConverted(position : Vector3, sourceMob)
	local mobService = self.Services.MobService
	local mobConfig = SharedConfig.Mob
	local spawn = Settings.Spawn

	local entityName = spawn.Entity
	local definition = mobConfig.Entities[entityName]
	if not definition then
		warn("SuffocateAbilityService: unknown spawn entity '" .. tostring(entityName) .. "'")
		return
	end

	local routes = mobService:getRoutes()
	local routeIndex, startDistance, bestSquared = 1, 0, math.huge
	for index, route in ipairs(routes) do
		local smooth = route.smooth
		for pointIndex, point in smooth.points do
			local dx = point.X - position.X
			local dz = point.Z - position.Z
			local squared = dx * dx + dz * dz
			if squared < bestSquared then
				bestSquared = squared
				routeIndex = index
				startDistance = smooth.cumulative[pointIndex] or 0
			end
		end
	end

	local route = routes[routeIndex]
	if not route then
		return
	end

	local maxHealth, baseSpeed, healthScale
	local waveStats = mobService:GetWaveStats(entityName)
	if waveStats then
		maxHealth = waveStats.MaxHealth
		baseSpeed = waveStats.BaseSpeed
		healthScale = waveStats.HealthScale
	else
		healthScale = sourceMob.HealthScale or 1
		maxHealth = math.max(1, math.floor(((definition.Health or 10) * healthScale) + 0.5))

		local sourceDefinition = mobConfig.Entities[sourceMob.Name]
		local sourceBase = mobConfig.BaseSpeed * ((sourceDefinition and sourceDefinition.SpeedMultiplier) or 1)
		local speedScale = if sourceBase > 0 then sourceMob.BaseSpeed / sourceBase else 1
		baseSpeed = mobConfig.BaseSpeed * (definition.SpeedMultiplier or 1) * speedScale
	end

	local frozenUntil = mobService.FreezeUntil or 0
	local spawnSpeed = baseSpeed * mobService.WeatherSpeedScale * (mobService.CardSpeedScale or 1)

	local turnDistances = route.turnDistances or {}
	local nextTurn = #turnDistances + 1
	for index, at in ipairs(turnDistances) do
		if at > startDistance then
			nextTurn = index
			break
		end
	end

	local mobId = HttpService:GenerateGUID(false)

	mobService.ActiveMobs[mobId] = {
		Name = entityName,
		Health = maxHealth,
		MaxHealth = maxHealth,
		BaseSpeed = baseSpeed,
		SpeedScale = 1,
		SlowScale = 1,
		CurrentSpeed = spawnSpeed,
		Distance = startDistance,
		LastDistance = startDistance,
		StunnedUntil = frozenUntil,
		RouteIndex = routeIndex,
		PathLength = route.smooth.length,
		TurnDistances = route.turnDistances,
		NextTurnIndex = nextTurn,
		Gimmicks = mobConfig.GetGimmicks(entityName),
		GimmickState = {},
		Reward = math.max(0, spawn.Reward or 0),
		HealthScale = healthScale,
	}
	mobService.ActiveMobCount += 1

	fireAll("SpawnClientMob", {
		Id = mobId,
		Name = entityName,
		Speed = if frozenUntil > GameClock.Now() then 0 else spawnSpeed,
		MaxHealth = maxHealth,
		Route = routeIndex,
	})

	if startDistance > 0 then
		fireAll("MobTeleported", mobId, startDistance)
	end
end

function SuffocateAbilityService:stepSuffocations()
	local mobService = self.Services.MobService
	local unitService = self.Services.UnitService
	local now = GameClock.Now()

	for index = #self.Suffocations, 1, -1 do
		local record = self.Suffocations[index]
		local entry = record.Entry

		if unitService.UnitsById[entry.unitId] ~= entry then
			table.remove(self.Suffocations, index)
		elseif mobService.ActiveMobs[record.MobId] ~= record.Mob then
			table.remove(self.Suffocations, index)
			entry.Suffocating = nil

			if (entry.StunnedUntil or 0) <= record.AppliedStun then
				entry.StunnedUntil = record.PreviousStun
			end

			fireAll("UnitSuffocateEnd", entry.unitId)
		elseif now >= record.EndsAt then
			table.remove(self.Suffocations, index)

			local position = entry.cf.Position
			self:removeUnit(entry, math.max(0, Settings.FadeTime or 0))
			self:spawnConverted(position, record.Mob)
		elseif (entry.StunnedUntil or 0) < record.EndsAt then
			entry.StunnedUntil = record.EndsAt
		end
	end
end

function SuffocateAbilityService:step()
	local mobService = self.Services.MobService
	local unitService = self.Services.UnitService
	if not mobService or not unitService or not mobService.ActiveMobs or not unitService.PlacedUnits then
		return
	end

	local threshold = Settings.Threshold or 0.7
	for mobId, mob in mobService.ActiveMobs do
		if not self.Triggered[mob]
			and mob.Health > 0
			and mob.Health <= mob.MaxHealth * threshold
			and self:appliesTo(mob)
		then
			self:trigger(mobId, mob)
		end
	end

	self:stepSuffocations()
end

function SuffocateAbilityService:guardDamage()
	local unitService = self.Services.UnitService
	if not unitService or not unitService.creditDamage or unitService.SuffocateGuarded then
		return
	end

	local original = unitService.creditDamage
	unitService.creditDamage = function(service, entry, ...)
		if entry and entry.Suffocating then
			return 0
		end
		return original(service, entry, ...)
	end
	unitService.SuffocateGuarded = true
end

function SuffocateAbilityService:start()
	for name in self.Services do
		self.Services[name] = Framework:Get(name)
	end

	self:guardDamage()

	Framework:Listen("UnitSuffocate", function() end)
	Framework:Listen("UnitSuffocateEnd", function() end)
	Framework:Listen("UnitSuffocateFade", function() end)

	RunService.Heartbeat:Connect(function()
		self:step()
	end)
end

function SuffocateAbilityService:init()
end

return SuffocateAbilityService