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
	Applicable = setmetatable({}, { __mode = "k" }),
	Suffocations = {},
}

function SuffocateAbilityService:getModelSet() : string
	local preset = self.Services.MobService:getDifficulty()
	return (preset and preset.ModelSet) or SharedConfig.Mob.DefaultModelSet
end

function SuffocateAbilityService:appliesTo(mob) : boolean
	local cached = self.Applicable[mob]
	if cached == nil then
		local modelName = SharedConfig.Mob.GetModelName(self:getModelSet(), mob.Name)
		cached = table.find(Settings.Enemies, modelName) ~= nil
		self.Applicable[mob] = cached
	end
	return cached
end

function SuffocateAbilityService:entityForModel(modelSet : string, modelName : string) : string?
	local mobConfig = SharedConfig.Mob

	local matches = {}
	for entityName in mobConfig.Entities do
		if mobConfig.GetModelName(modelSet, entityName) == modelName then
			table.insert(matches, entityName)
		end
	end

	table.sort(matches)

	if #matches > 1 then
		warn("SuffocateAbilityService: model '" .. modelName .. "' is worn by several entities in set '" .. modelSet .. "'; using " .. matches[1])
	end

	return matches[1]
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

function SuffocateAbilityService:beginSuffocation(mobId : string, mob)
	local entry = self:pickVictim()
	if not entry then
		return
	end

	local duration = math.max(0.1, Settings.Duration or 4)
	entry.Suffocating = true

	table.insert(self.Suffocations, {
		MobId = mobId,
		Mob = mob,
		Entry = entry,
		EndsAt = GameClock.Now() + duration,
	})

	fireAll("UnitSuffocate", entry.unitId, duration, Settings.UnitAnim or "Suffocated")

	if Settings.StunUnit then
		self.Services.UnitService:StunUnit(entry, duration)
	end
end

function SuffocateAbilityService:beginCast(mobId : string, mob)
	self.Triggered[mob] = true

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

	local function finish()
		if mobService.ActiveMobs[mobId] ~= mob then
			return
		end

		if stopping and (mob.StunnedUntil or 0) <= GameClock.Now() then
			fireAll("UpdateMobSpeed", mobId, mob.CurrentSpeed)
		end

		self:beginSuffocation(mobId, mob)
	end

	if castTime > 0 then
		GameClock.Delay(castTime, finish)
	else
		finish()
	end
end

function SuffocateAbilityService:Trigger(mobId : string) : boolean
	local mob = self.Services.MobService.ActiveMobs[mobId]
	if not mob or self.Triggered[mob] then
		return false
	end
	self:beginCast(mobId, mob)
	return true
end

function SuffocateAbilityService:removeUnit(entry)
	local unitService = self.Services.UnitService

	for index, placed in ipairs(unitService.PlacedUnits) do
		if placed == entry then
			table.remove(unitService.PlacedUnits, index)
			break
		end
	end

	unitService.UnitsById[entry.unitId] = nil
	fireAll("RemoveUnit", entry.unitId)
end

-- Mirrors MobService:SpawnWave, for a single enemy placed mid-path.
function SuffocateAbilityService:spawnConverted(position : Vector3, sourceMob)
	local mobService = self.Services.MobService
	local mobConfig = SharedConfig.Mob
	local spawn = Settings.Spawn

	local modelSet = self:getModelSet()
	local entityName = self:entityForModel(modelSet, spawn.Model)
	local definition = entityName and mobConfig.Entities[entityName]
	if not entityName or not definition then
		warn("SuffocateAbilityService: no entity wears model '" .. tostring(spawn.Model) .. "' in set '" .. modelSet .. "'")
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

	local sourceDefinition = mobConfig.Entities[sourceMob.Name]
	local sourceBase = mobConfig.BaseSpeed * ((sourceDefinition and sourceDefinition.SpeedMultiplier) or 1)
	local speedScale = if sourceBase > 0 then sourceMob.BaseSpeed / sourceBase else 1
	local baseSpeed = mobConfig.BaseSpeed * (definition.SpeedMultiplier or 1) * speedScale

	local maxHealth = math.max(1, math.floor(((definition.Health or 10) * (mobService.HealthScale or 1)) + 0.5))

	local frozenUntil = mobService.FreezeUntil or 0
	local spawnSpeed = baseSpeed * (mobService.WeatherSpeedScale or 1) * (mobService.CardSpeedScale or 1)

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
		Gimmicks = mobConfig.GetGimmicks(modelSet, entityName),
		GimmickState = {},
		Reward = math.max(0, spawn.Reward or 0),
	}
	mobService.ActiveMobCount += 1

	fireAll("SpawnClientMob", {
		Id = mobId,
		Name = entityName,
		Speed = if frozenUntil > GameClock.Now() then 0 else spawnSpeed,
		MaxHealth = maxHealth,
		Route = routeIndex,
		ModelSet = modelSet,
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
			fireAll("UnitSuffocateEnd", entry.unitId)
		elseif now >= record.EndsAt then
			table.remove(self.Suffocations, index)

			local position = entry.cf.Position
			self:removeUnit(entry)
			self:spawnConverted(position, record.Mob)
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
			self:beginCast(mobId, mob)
		end
	end

	self:stepSuffocations()
end

function SuffocateAbilityService:start()
	for name in self.Services do
		self.Services[name] = Framework:Get(name)
	end

	Framework:Listen("UnitSuffocate", function() end)
	Framework:Listen("UnitSuffocateEnd", function() end)

	RunService.Heartbeat:Connect(function()
		self:step()
	end)
end

function SuffocateAbilityService:init()
end

return SuffocateAbilityService