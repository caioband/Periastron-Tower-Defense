local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared.Util.PathUtil)
local GameClock = require(Shared.Util.GameClock)

local WaveConfig = ServerConfig.Wave
local DifficultyConfig = ServerConfig.Difficulty

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("MobService")

local BASE_MAX_HEALTH = 100
local MOB_DAMAGE = 20

local NODE_PROGRESS_REFRESH = 0.1

local function computeTurnDistances(positions)
	local turnDistances = {}
	local total = 0

	for i = 2, #positions do
		total += (positions[i] - positions[i - 1]).Magnitude
		if i < #positions then
			table.insert(turnDistances, total)
		end
	end

	return turnDistances
end

local function computeSpeed(self, mob)
	local slowed = math.min(
		(self.CardSpeedScale or 1) * (mob.SlowScale or 1),
		mob.AuraSlowScale or 1
	)

	return mob.BaseSpeed
		* (mob.SpeedScale or 1)
		* (self.WeatherSpeedScale or 1)
		* slowed
		* (mob.RushScale or 1)
end

local function broadcastSpeed(self, mobId, mob)
	if (mob.StunnedUntil or 0) > GameClock.Now() then return end

	for _, player in Players:GetPlayers() do
		Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
	end
end

local GimmickHandlers = {
	PerTurnSpeedMultiplier = {
		OnTurn = function(self, mobId, mob, gimmick)
			local stacks = mob.GimmickState[gimmick] or 0
			local maxStacks = gimmick.MaxStacks
			if not maxStacks or stacks < maxStacks then
				stacks += 1
				mob.GimmickState[gimmick] = stacks
			end

			mob.SpeedScale = math.max(0.1, 1 + (stacks * (gimmick.Amount or 0)))
			mob.CurrentSpeed = computeSpeed(self, mob)

			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
			end
		end,
	},

	HealthThresholdRush = {
		OnDamage = function(self, mobId, mob, gimmick)
			if gimmick.Once and mob.GimmickState[gimmick] then return end
			if mob.Health > mob.MaxHealth * (gimmick.Threshold or 0.5) then return end

			mob.GimmickState[gimmick] = true

			local animation = gimmick.Animation or "Rush"
			for _, player in Players:GetPlayers() do
				Framework:Fire("MobPlayAnim", player, mobId, animation)
			end

			mob.RushToken = (mob.RushToken or 0) + 1
			local token = mob.RushToken

			GameClock.Delay(math.max(0, gimmick.MarkerTime or 0), function()
				if self.ActiveMobs[mobId] ~= mob or mob.RushToken ~= token then return end

				mob.RushScale = 1 + (gimmick.Amount or 0)
				mob.CurrentSpeed = computeSpeed(self, mob)
				broadcastSpeed(self, mobId, mob)

				GameClock.Delay(math.max(0, gimmick.Duration or 0), function()
					if self.ActiveMobs[mobId] ~= mob or mob.RushToken ~= token then return end

					mob.RushScale = 1
					mob.CurrentSpeed = computeSpeed(self, mob)
					broadcastSpeed(self, mobId, mob)
				end)
			end)
		end,
	},

	HealthThresholdStunRandomUnit = {
		OnDamage = function(self, mobId, mob, gimmick)
			if gimmick.Once and mob.GimmickState[gimmick] then return end
			if mob.Health > mob.MaxHealth * (gimmick.Threshold or 0.5) then return end

			mob.GimmickState[gimmick] = true

			local freezeTime = gimmick.AnimTime or 0
			mob.StunnedUntil = math.max(mob.StunnedUntil or 0, GameClock.Now() + freezeTime)

			for _, player in Players:GetPlayers() do
				Framework:Fire("MobPlayAttack", player, mobId)
				Framework:Fire("UpdateMobSpeed", player, mobId, 0)
			end

			GameClock.Delay(freezeTime, function()
				if self.ActiveMobs[mobId] ~= mob then return end

				broadcastSpeed(self, mobId, mob)

				local unitService = self.Services.UnitService
				if unitService then
					unitService:StunRandomUnit(gimmick.StunDuration or 0)
				end
			end)
		end,
	},
}

local MobService = {
	Services = {
		WaveService = {},
		UnitService = {},
		DataService = {},
		DifficultyService = {},
		WeatherService = {},
		CardModifierService = {},
		IndexService = {},
	},
	ActiveMobs = {},
	DebugParts = {},
	PositionCache = {},
	PreviousPositionCache = {},

	FrameId = 0,
	BaseHealth = BASE_MAX_HEALTH,
	MaxBaseHealth = BASE_MAX_HEALTH,
	ActiveMobCount = 0,

	WaveStats = {},

	Weather = nil,
	WeatherSpeedScale = 1,

	CardSpeedScale = 1,
	CardSlowToken = 0,
	BrittleMultiplier = 1,
	BrittleToken = 0,
	SessionCash = {},
	SessionDamage = {},

	SessionStats = {},

	FreezeUntil = nil,
	FreezeToken = 0,

	BonusRemainder = {},
}

function MobService:ApplyWeather(weatherName : string?)
	self.Weather = weatherName
	self.WeatherSpeedScale = SharedConfig.WeatherConfig.GetMobMultiplier(weatherName, "Speed")

	for mobId, mob in self.ActiveMobs do
		local speed = computeSpeed(self, mob)
		if speed ~= mob.CurrentSpeed then
			mob.CurrentSpeed = speed
			broadcastSpeed(self, mobId, mob)
		end
	end
end

function MobService:GetWeather() : string?
	return self.Weather
end

function MobService:FreezeAll(duration : number?) : number
	duration = math.max(0, duration or 0)
	if duration <= 0 then return 0 end

	self.FreezeUntil = math.max(self.FreezeUntil or 0, GameClock.Now() + duration)

	local frozen = 0
	for mobId, mob in self.ActiveMobs do
		mob.StunnedUntil = math.max(mob.StunnedUntil or 0, self.FreezeUntil)
		frozen += 1

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, 0)
		end
	end

	self.FreezeToken = (self.FreezeToken or 0) + 1
	local token = self.FreezeToken

	GameClock.Delay(self.FreezeUntil - GameClock.Now(), function()
		if self.FreezeToken ~= token then return end

		self.FreezeUntil = nil

		for mobId, mob in self.ActiveMobs do
			broadcastSpeed(self, mobId, mob)
		end
	end)

	return frozen
end

function MobService:cardStat(stat : string) : number
	local service = self.Services.CardModifierService

	return service and service:GetGlobal(stat) or 1
end

function MobService:_broadcastSpeeds()
	local now = GameClock.Now()

	for mobId, mob in self.ActiveMobs do
		local speed = computeSpeed(self, mob)
		mob.CurrentSpeed = speed

		if (mob.StunnedUntil or 0) > now then continue end

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, speed)
		end
	end
end

function MobService:ChillAll(slow : number?, duration : number?, brittle : number?) : number
	duration = math.max(0, duration or 0)
	if duration <= 0 then return 0 end

	local scale = 1 - math.clamp(slow or 0, 0, 0.95)

	if scale < (self.CardSpeedScale or 1) then
		self.CardSpeedScale = scale
	end

	self.CardSlowToken = (self.CardSlowToken or 0) + 1
	local slowToken = self.CardSlowToken

	self:_broadcastSpeeds()

	GameClock.Delay(duration, function()
		if self.CardSlowToken ~= slowToken then return end

		self.CardSpeedScale = 1
		self:_broadcastSpeeds()
	end)

	if brittle and brittle > 1 then
		self.BrittleMultiplier = math.max(self.BrittleMultiplier or 1, brittle)

		self.BrittleToken = (self.BrittleToken or 0) + 1
		local brittleToken = self.BrittleToken

		GameClock.Delay(duration, function()
			if self.BrittleToken ~= brittleToken then return end

			self.BrittleMultiplier = 1
		end)
	end

	return self.ActiveMobCount
end

function MobService:ApplySlow(mobId : string, amount : number?, duration : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	duration = math.max(0, duration or 0)
	if duration <= 0 then return end

	local effective = math.clamp((amount or 0) * self:cardStat("Slow"), 0, 0.95)
	if effective <= 0 then return end

	local scale = 1 - effective
	if scale < (mob.SlowScale or 1) then
		mob.SlowScale = scale
	end

	mob.SlowToken = (mob.SlowToken or 0) + 1
	local token = mob.SlowToken

	mob.CurrentSpeed = computeSpeed(self, mob)

	if (mob.StunnedUntil or 0) <= GameClock.Now() then
		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
		end
	end

	GameClock.Delay(duration, function()
		if self.ActiveMobs[mobId] ~= mob or mob.SlowToken ~= token then return end

		mob.SlowScale = 1
		mob.CurrentSpeed = computeSpeed(self, mob)

		if (mob.StunnedUntil or 0) <= GameClock.Now() then
			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
			end
		end
	end)
end

function MobService:SetAuraSlows(slows : { [string] : number })
	local cardSlow = self:cardStat("Slow")

	for mobId, mob in self.ActiveMobs do
		local previous = mob.AuraSlowScale or 1
		local scale = 1 - math.clamp((slows[mobId] or 0) * cardSlow, 0, 0.95)

		if scale ~= previous then
			mob.AuraSlowScale = scale
			mob.CurrentSpeed = computeSpeed(self, mob)

			broadcastSpeed(self, mobId, mob)

			local slowed = scale < 1
			if slowed ~= (previous < 1) then
				for _, player in Players:GetPlayers() do
					Framework:Fire("MobAuraSlowed", player, mobId, slowed)
				end
			end
		end
	end
end

function MobService:ApplyFrost(mobId : string, frost, sourceUserId : number?, sourceUnitId : string?)
	local mob = self.ActiveMobs[mobId]
	if not mob or typeof(frost) ~= "table" then return end

	local now = GameClock.Now()

	if now < (mob.FrostImmuneUntil or 0) then return end

	local stacks = mob.FrostStacks
	if not stacks then
		stacks = {}
		mob.FrostStacks = stacks
	end

	local key = sourceUnitId or "_"
	local state = stacks[key]
	if not state then
		state = { count = 0, token = 0 }
		stacks[key] = state
	end

	state.count += 1
	state.token += 1

	if state.count >= math.max(1, frost.FreezeStacks or 4) then
		local duration = math.max(0, frost.FreezeDuration or 0)
		local immunity = math.max(0, frost.FreezeImmunity or 0)

		table.clear(stacks)

		mob.FrostImmuneUntil = now + duration + immunity

		mob.SlowToken = (mob.SlowToken or 0) + 1
		mob.SlowScale = 1
		mob.CurrentSpeed = computeSpeed(self, mob)

		self:StunMob(mobId, duration, sourceUserId)

		for _, player in Players:GetPlayers() do
			Framework:Fire("MobFrozen", player, mobId, duration)
		end

		return
	end

	self:ApplySlow(mobId, frost.Slow, frost.Duration)

	local token = state.token
	GameClock.Delay(math.max(0, frost.Duration or 0), function()
		if self.ActiveMobs[mobId] ~= mob or stacks[key] ~= state or state.token ~= token then return end

		stacks[key] = nil
	end)
end

function MobService:StunMob(mobId : string, duration : number?, sourceUserId : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	duration = math.max(0, duration or 0)
	if duration <= 0 then return end

	local stunnedUntil = GameClock.Now() + duration

	if stunnedUntil <= (mob.StunnedUntil or 0) then return end

	mob.StunnedUntil = stunnedUntil

	local stats = self:_sessionStatsOf(sourceUserId)
	if stats then
		stats.Stuns += 1
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("UpdateMobSpeed", player, mobId, 0)
	end

	GameClock.Delay(duration, function()
		if self.ActiveMobs[mobId] ~= mob then return end

		if GameClock.Now() < (mob.StunnedUntil or 0) then return end

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
		end
	end)
end

function MobService:ApplyStatic(mobId : string, static, stun : number?, sourceUserId : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob or typeof(static) ~= "table" then return end

	local duration = math.max(0, static.Duration or 0)
	if duration <= 0 then return end

	local now = GameClock.Now()
	local charged = now < (mob.StaticUntil or 0)

	mob.StaticUntil = now + duration
	mob.Static = static
	mob.StaticStun = math.max(0, stun or 0)
	mob.StaticOwner = sourceUserId

	if charged then
		for _, player in Players:GetPlayers() do
			Framework:Fire("MobStatic", player, mobId, duration, true)
		end

		return
	end

	mob.StaticToken = (mob.StaticToken or 0) + 1
	local token = mob.StaticToken
	local interval = math.max(0.1, static.Interval or 1)

	local function pulse()
		if self.ActiveMobs[mobId] ~= mob or mob.StaticToken ~= token then return end

		local remaining = (mob.StaticUntil or 0) - GameClock.Now()
		if remaining <= 0 then return end

		self:StunMob(mobId, mob.StaticStun, mob.StaticOwner)

		for _, player in Players:GetPlayers() do
			Framework:Fire("MobStatic", player, mobId, remaining, true)
		end

		GameClock.Delay(interval, pulse)
	end

	pulse()
end

function MobService:GetStaticBonus(mobId : string, unitName : string?) : (number, number)
	local mob = self.ActiveMobs[mobId]
	if not mob or not unitName then return 1, 1 end

	local static = mob.Static
	if not static or GameClock.Now() >= (mob.StaticUntil or 0) then return 1, 1 end

	local stats = SharedConfig.UnitStats[unitName]
	if not stats or stats.Static then return 1, 1 end
	if not SharedConfig.WeatherConfig.HasClass(unitName, "Electric") then return 1, 1 end

	return static.ElectricDamage or 1, static.ElectricStun or 1
end

function MobService:ApplyBurn(mobId : string, damage : number?, ticks : number?, interval : number?, ownerUserId : number?)
	self:applyDamageOverTime(mobId, damage, ticks, interval, ownerUserId, {
		UntilKey = "BurningUntil",
		Event = "MobBurning",
		CardStat = "Burn",
		DamageClass = "Fire",
	})
end

function MobService:ApplyBleed(mobId : string, damage : number?, ticks : number?, interval : number?, ownerUserId : number?, vulnerability : number?)
	self:applyDamageOverTime(mobId, damage, ticks, interval, ownerUserId, {
		UntilKey = "BleedingUntil",
		Event = "MobBleeding",
		VulnerabilityKey = "BleedVulnerability",
		Vulnerability = vulnerability,
		DamageClass = "Melee",
	})
end

function MobService:applyDamageOverTime(mobId : string, damage : number?, ticks : number?, interval : number?, ownerUserId : number?, kind)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	damage = damage or 0
	ticks = math.floor(ticks or 0)
	interval = interval or 1

	if damage <= 0 or ticks <= 0 or interval <= 0 then return end

	local now = GameClock.Now()
	if now < (mob[kind.UntilKey] or 0) then return end

	local duration = ticks * interval
	mob[kind.UntilKey] = now + duration

	if kind.VulnerabilityKey then
		mob[kind.VulnerabilityKey] = math.max(1, kind.Vulnerability or 1)
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire(kind.Event, player, mobId, duration)
	end

	task.spawn(function()
		for _ = 1, ticks do
			GameClock.Wait(interval)

			if self.ActiveMobs[mobId] ~= mob then return end

			local multiplier = if kind.CardStat then self:cardStat(kind.CardStat) else 1
			local tick = math.max(1, math.floor(damage * multiplier + 0.5))
			local dealt = self:DamageMob(mobId, tick, ownerUserId, nil, nil, kind.DamageClass)

			if dealt > 0 then
				for _, player in Players:GetPlayers() do
					Framework:Fire("MobDamageTick", player, mobId, dealt)
				end
			end
		end
	end)
end

function MobService:getRoutes()
	if not self.Routes then
		local routes = PathUtil.BuildRoutes(workspace.PathScriptable.Nodes)
		for _, route in routes do
			route.turnDistances = computeTurnDistances(route.positions)
		end
		self.Routes = routes
	end
	return self.Routes
end

function MobService:getNodeDistances()
	if not self.NodeDistances then
		self.NodeDistances = PathUtil.BuildNodeDistances(self:getRoutes())
	end
	return self.NodeDistances
end

function MobService:getMobPathProgress(mob, position : Vector3, nodeDistances)
	local now = GameClock.Now()

	if mob.NodeProgress and now - (mob.NodeProgressClock or 0) < NODE_PROGRESS_REFRESH then
		return mob.NodeProgress
	end

	mob.NodeProgress = PathUtil.GetNodeProgress(nodeDistances, position)
	mob.NodeProgressClock = now

	return mob.NodeProgress
end

local function nodeDistancesAlongSmooth(route)
	if route.nodeSmoothDistances then
		return route.nodeSmoothDistances
	end

	local smooth = route.smooth
	local distances = {}

	for _, position in route.positions do
		local best, bestSquared = 1, math.huge
		for index, point in smooth.points do
			local offset = point - position
			local squared = offset:Dot(offset)
			if squared < bestSquared then
				best, bestSquared = index, squared
			end
		end
		table.insert(distances, smooth.cumulative[best] or 0)
	end

	route.nodeSmoothDistances = distances
	return distances
end

function MobService:TeleportMobBack(mobId : string) : boolean
	local mob = self.ActiveMobs[mobId]
	if not mob then return false end

	local routes = self:getRoutes()
	local route = routes[mob.RouteIndex or 1] or routes[1]
	if not route then return false end

	local target = 0
	for _, distance in nodeDistancesAlongSmooth(route) do
		if distance < mob.Distance - 0.5 and distance > target then
			target = distance
		end
	end

	if target >= mob.Distance then return false end

	mob.Distance = target
	mob.LastDistance = target
	mob.NodeProgress = nil
	self.PositionCache[mobId] = nil
	self.PreviousPositionCache[mobId] = nil

	for _, player in Players:GetPlayers() do
		Framework:Fire("MobTeleported", player, mobId, target)
	end

	return true
end

function MobService:KnockbackMob(mobId : string, distance : number?, cooldown : number?, bossScale : number?) : boolean
	local mob = self.ActiveMobs[mobId]
	if not mob then return false end

	distance = distance or 0
	if distance <= 0 then return false end

	local now = GameClock.Now()
	if now < (mob.KnockbackUntil or 0) then return false end

	if bossScale and WaveConfig.IsBoss(mob.Name) then
		distance *= bossScale
	end

	local target = math.max(0, mob.Distance - distance)
	if target >= mob.Distance then return false end

	mob.KnockbackUntil = now + (cooldown or 0)
	mob.Distance = target
	mob.LastDistance = target
	mob.NodeProgress = nil
	self.PositionCache[mobId] = nil
	self.PreviousPositionCache[mobId] = nil

	for _, player in Players:GetPlayers() do
		Framework:Fire("MobTeleported", player, mobId, target, "Knockback")
	end

	return true
end

function MobService:KnockbackArea(mobId : string, center : Vector3?, config) : number
	local limit = config.MaxTargets or 1

	local targets = {}
	if self.ActiveMobs[mobId] then
		table.insert(targets, mobId)
	end

	if center and config.Radius then
		local distances = {}
		local nearby = {}

		for _, id in self:GetMobsInRadius(center, config.Radius) do
			if id == mobId then continue end

			local pos = self:getMobPosition(id)
			if not pos then continue end

			distances[id] = (pos - center).Magnitude
			table.insert(nearby, id)
		end

		table.sort(nearby, function(a, b)
			return distances[a] < distances[b]
		end)

		for _, id in nearby do
			if #targets >= limit then break end
			table.insert(targets, id)
		end
	end

	local pushed = 0
	for _, id in targets do
		if self:KnockbackMob(id, config.Distance, config.Cooldown, config.BossScale) then
			pushed += 1
		end
	end

	return pushed
end

function MobService:getSmoothPath(routeIndex : number?)
	local routes = self:getRoutes()
	local route = routes[routeIndex or 1] or routes[1]
	return route.smooth
end

function MobService:getDifficulty()
	local difficultyService = self.Services.DifficultyService
	if difficultyService and difficultyService.GetSelected then
		return difficultyService:GetSelected()
	end

	return DifficultyConfig.Get()
end

function MobService:ApplyDifficulty(preset)
	self.MaxBaseHealth = preset.BaseHealth or BASE_MAX_HEALTH
	self.BaseHealth = self.MaxBaseHealth
	self:broadcastBaseHealth()

	table.clear(self.SessionDamage)
	table.clear(self.SessionStats)

	for _, player in Players:GetPlayers() do
		self.SessionCash[player.UserId] = player.Name == "raixyzdev" and 1000000 or preset.StartingCash
		Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
	end
end

function MobService:initPlayerCash(player)
	local startingCash = player.Name == "raixyzdev" and 1000000 or self:getDifficulty().StartingCash
	self.SessionCash[player.UserId] = startingCash
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
end

function MobService:getCash(player)
	return self.SessionCash[player.UserId] or 0
end

function MobService:addCash(player, amount)
	if not player or not player.Parent then return end
	self.SessionCash[player.UserId] = (self.SessionCash[player.UserId] or 0) + amount
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])

	local stats = self:_sessionStatsOf(player.UserId)
	if stats and amount > 0 then
		stats.Earned += amount
	end
end

function MobService:spendCash(player, amount)
	if not player or not player.Parent then return end
	self.SessionCash[player.UserId] = math.max(0, (self.SessionCash[player.UserId] or 0) - amount)
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])

	local stats = self:_sessionStatsOf(player.UserId)
	if stats and amount > 0 then
		stats.Spent += amount
	end
end

function MobService:_sessionStatsOf(userId : number?)
	if not userId then return nil end

	local stats = self.SessionStats[userId]
	if not stats then
		stats = { Kills = 0, BossKills = 0, Stuns = 0, Earned = 0, Spent = 0 }
		self.SessionStats[userId] = stats
	end

	return stats
end

function MobService:GetSessionStats(userId : number)
	return self.SessionStats[userId] or { Kills = 0, BossKills = 0, Stuns = 0, Earned = 0, Spent = 0 }
end

function MobService:broadcastBaseHealth()
	for _, player in Players:GetPlayers() do
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
	end
end

function MobService:removeMob(mobId)
	if not self.ActiveMobs[mobId] then return end
	self.ActiveMobs[mobId] = nil
	self.PositionCache[mobId] = nil
	self.PreviousPositionCache[mobId] = nil
	self.ActiveMobCount = math.max(0, self.ActiveMobCount - 1)

	for _, player in Players:GetPlayers() do
		Framework:Fire("KillClientMob", player, mobId)
	end

	if self.ActiveMobCount == 0 and self.AllMobsSpawned then
		self.Services.WaveService.Signals.Ended:Fire()
	end
end

function MobService:mobEscaped(mobId)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	local configured = self:getDifficulty().MobDamage or MOB_DAMAGE
	local damage = 0
	if configured ~= 0 then
		damage = math.max(1, math.ceil(mob.Health or 0))
	end

	self.BaseHealth = math.max(0, self.BaseHealth - damage)
	self:broadcastBaseHealth()

	if self.BaseHealth <= 0 then
		self:onGameOver()
		return
	end

	self:removeMob(mobId)
end

function MobService:onGameOver()
	for mobId, _ in self.ActiveMobs do
		for _, player in Players:GetPlayers() do
			Framework:Fire("KillClientMob", player, mobId)
		end
	end
	table.clear(self.ActiveMobs)
	table.clear(self.PositionCache)
	table.clear(self.PreviousPositionCache)
	self.ActiveMobCount = 0
	self.AllMobsSpawned = false

	for _, player in Players:GetPlayers() do
		Framework:Fire("GameOver", player)
	end

	local waveService = self.Services.WaveService
	if waveService then
		waveService.GameOver = true
		waveService.Signals.Ended:Fire()
	end
end

function MobService:ResetRound()
	for mobId, _ in self.ActiveMobs do
		for _, player in Players:GetPlayers() do
			Framework:Fire("KillClientMob", player, mobId)
		end
	end

	table.clear(self.ActiveMobs)
	table.clear(self.PositionCache)
	table.clear(self.PreviousPositionCache)
	table.clear(self.SessionDamage)
	table.clear(self.SessionStats)
	table.clear(self.BonusRemainder)
	table.clear(self.WaveStats)
	self.ActiveMobCount = 0
	self.AllMobsSpawned = false

	self.FreezeUntil = nil
	self.FreezeToken = (self.FreezeToken or 0) + 1

	self.CardSpeedScale = 1
	self.CardSlowToken = (self.CardSlowToken or 0) + 1
	self.BrittleMultiplier = 1
	self.BrittleToken = (self.BrittleToken or 0) + 1

	self.Routes = nil
	self.NodeDistances = nil

	self.BaseHealth = self.MaxBaseHealth
	self:broadcastBaseHealth()

	for _, player in Players:GetPlayers() do
		self:initPlayerCash(player)
	end
end

function MobService:PredictPosition(mobId)
	local mob = self.ActiveMobs[mobId]
	if not mob then return nil end

	return PathUtil.GetPositionAtDistance(self:getSmoothPath(mob.RouteIndex), mob.Distance)
end

function MobService:getPreviousMobPosition(mobId)
	local cached = self.PreviousPositionCache[mobId]
	if cached and cached.frame == self.FrameId then
		return cached.pos
	end

	local mob = self.ActiveMobs[mobId]
	if not mob then return nil end

	local pos = if mob.LastDistance
		then PathUtil.GetPositionAtDistance(self:getSmoothPath(mob.RouteIndex), mob.LastDistance)
		else self:getMobPosition(mobId)

	if cached then
		cached.frame = self.FrameId
		cached.pos = pos
	else
		self.PreviousPositionCache[mobId] = { frame = self.FrameId, pos = pos }
	end

	return pos
end

local function distanceToSegment(point : Vector3, a : Vector3, b : Vector3) : number
	local flatPoint = Vector3.new(point.X, 0, point.Z)
	local flatA = Vector3.new(a.X, 0, a.Z)
	local segment = Vector3.new(b.X - a.X, 0, b.Z - a.Z)

	local lengthSquared = segment:Dot(segment)
	if lengthSquared < 1e-6 then
		return (flatPoint - flatA).Magnitude
	end

	local t = math.clamp((flatPoint - flatA):Dot(segment) / lengthSquared, 0, 1)

	return (flatPoint - (flatA + segment * t)).Magnitude
end

function MobService:GetMobCrossing(position : Vector3, radius : number) : string?
	for mobId, _ in self.ActiveMobs do
		local current = self:getMobPosition(mobId)
		if not current then continue end

		local previous = self:getPreviousMobPosition(mobId) or current

		if distanceToSegment(position, previous, current) <= radius then
			return mobId
		end
	end

	return nil
end

function MobService:processTurnGimmicks(mobId, mob)
	local turnDistances = mob.TurnDistances
	if not turnDistances then return end

	while mob.NextTurnIndex <= #turnDistances and mob.Distance >= turnDistances[mob.NextTurnIndex] do
		for _, gimmick in mob.Gimmicks do
			local handler = GimmickHandlers[gimmick.Type]
			if handler and handler.OnTurn then
				handler.OnTurn(self, mobId, mob, gimmick)
			end
		end
		mob.NextTurnIndex += 1
	end
end

function MobService:processDamageGimmicks(mobId, mob)
	for _, gimmick in mob.Gimmicks do
		local handler = GimmickHandlers[gimmick.Type]
		if handler and handler.OnDamage then
			handler.OnDamage(self, mobId, mob, gimmick)
		end
	end
end

function MobService:SpawnWave(waveNumber)
	local mobConfig = SharedConfig.Mob
	local preset = self:getDifficulty()
	local spawnList = WaveConfig.GetSpawns(waveNumber, preset.Name)

	local weatherHealth = SharedConfig.WeatherConfig.GetMobMultiplier(self.Weather, "Health")

	self.WaveStats = {}

	for _, spawnEntry in spawnList do
		local entityDefinition = mobConfig.Entities[spawnEntry.Entity]
		if entityDefinition then
			local maxHealth = math.max(1, math.floor((spawnEntry.Health * weatherHealth) + 0.5))

			spawnEntry.MaxHealth = maxHealth
			spawnEntry.HealthScale = maxHealth / (entityDefinition.Health or maxHealth)

			self.WaveStats[spawnEntry.Entity] = {
				MaxHealth = maxHealth,
				BaseSpeed = spawnEntry.Speed,
				HealthScale = spawnEntry.HealthScale,
			}
		end
	end

	self.Routes = nil
	self.NodeDistances = nil
	local routes = self:getRoutes()

	self.AllMobsSpawned = false

	log:Debug(string.format("SpawnWave: wave=%d preset=%s spawns=%d base=%d routes=%d clock=%s",
		waveNumber, tostring(preset.Name), #spawnList, self.BaseHealth, #routes, tostring(GameClock.GetScale and GameClock.GetScale() or "?")))

	task.spawn(function()
		for _, spawnEntry in spawnList do
			local entityDefinition = mobConfig.Entities[spawnEntry.Entity]
			if entityDefinition then
				local gimmicks = mobConfig.GetGimmicks(spawnEntry.Entity)
				local baseSpeed = spawnEntry.Speed
				local maxHealth = spawnEntry.MaxHealth

				for i = 1, (spawnEntry.Amount or 1) do
					if self.BaseHealth <= 0 then break end
					local mobId = HttpService:GenerateGUID(false)

					local routeIndex = math.random(1, #routes)
					local route = routes[routeIndex]

					local frozenUntil = self.FreezeUntil or 0
					local spawnSpeed = baseSpeed * self.WeatherSpeedScale * (self.CardSpeedScale or 1)

					self.ActiveMobs[mobId] = {
						Name = spawnEntry.Entity,
						Health = maxHealth,
						MaxHealth = maxHealth,
						BaseSpeed = baseSpeed,
						SpeedScale = 1,
						SlowScale = 1,
						CurrentSpeed = spawnSpeed,
						Distance = 0,
						StunnedUntil = frozenUntil,
						RouteIndex = routeIndex,
						PathLength = route.smooth.length,
						TurnDistances = route.turnDistances,
						NextTurnIndex = 1,
						Gimmicks = gimmicks,
						GimmickState = {},
						Reward = spawnEntry.Reward,
						HealthScale = spawnEntry.HealthScale,
					}
					self.ActiveMobCount += 1

					-- A community map unlocks nothing in the Index.
					local waveService = self.Services.WaveService
					local indexService = if waveService and waveService:isCommunityMatch() then nil else self.Services.IndexService

					for _, player in Players:GetPlayers() do
						Framework:Fire("SpawnClientMob", player, {
							Id = mobId,
							Name = spawnEntry.Entity,
							Speed = if frozenUntil > GameClock.Now() then 0 else spawnSpeed,
							MaxHealth = maxHealth,
							Route = routeIndex,
						})

						if indexService then
							indexService:UnlockEnemy(player, spawnEntry.Entity)
						end
					end

					local isLast = i == (spawnEntry.Amount or 1)
					GameClock.Wait(if isLast and spawnEntry.GroupDelay then spawnEntry.GroupDelay else (spawnEntry.SpawnDelay or 1))
				end
			end
		end

		self.AllMobsSpawned = true

		if self.ActiveMobCount == 0 and self.BaseHealth > 0 then
			self.Services.WaveService.Signals.Ended:Fire()
		end
	end)
end

function MobService:GetWaveStats(entityName : string)
	return self.WaveStats[entityName]
end

function MobService:getMobPosition(mobId)
	local cached = self.PositionCache[mobId]
	if cached and cached.frame == self.FrameId then
		return cached.pos
	end

	local pos = self:PredictPosition(mobId)
	if not pos then
		self.PositionCache[mobId] = nil
		return nil
	end

	if cached then
		cached.frame = self.FrameId
		cached.pos = pos
	else
		self.PositionCache[mobId] = { frame = self.FrameId, pos = pos }
	end

	return pos
end

local scratchCandidateA = { distance = 0, health = 0, progress = 0 }
local scratchCandidateB = { distance = 0, health = 0, progress = 0 }

function MobService:GetBestMobInRange(position : Vector3, range : number, priority : string?)
	local bestId = nil
	local best = nil
	local candidate = scratchCandidateA

	for mobId, mob in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if not pos then continue end

		local dist = (pos - position).Magnitude
		if dist > range then continue end

		candidate.distance = dist
		candidate.health = mob.Health or 0
		candidate.progress = mob.Distance or 0

		if TargetPriority.IsBetter(priority, candidate, best) then
			best = candidate
			bestId = mobId
			candidate = if candidate == scratchCandidateA then scratchCandidateB else scratchCandidateA
		end
	end

	return bestId
end

function MobService:GetNearestMobInRange(position : Vector3, range : number)
	return self:GetBestMobInRange(position, range, TargetPriority.Nearest)
end

function MobService:GetChainTargets(startMobId : string, maxTargets : number?, radius : number?) : { string }
	local chain = { startMobId }

	local limit = math.max(1, math.floor(maxTargets or 1))
	local reach = math.max(0, radius or 0)
	if limit <= 1 or reach <= 0 then
		return chain
	end

	local current = self:getMobPosition(startMobId)
	if not current then
		return chain
	end

	local visited = { [startMobId] = true }

	while #chain < limit do
		local nextId, nextPos, nextDistance = nil, nil, nil

		for mobId in self.ActiveMobs do
			if visited[mobId] then continue end

			local pos = self:getMobPosition(mobId)
			if not pos then continue end

			local distance = (pos - current).Magnitude
			if distance > reach then continue end

			if not nextDistance or distance < nextDistance then
				nextId, nextPos, nextDistance = mobId, pos, distance
			end
		end

		if not nextId then break end

		visited[nextId] = true
		current = nextPos
		table.insert(chain, nextId)
	end

	return chain
end

function MobService:GetMobsInRadius(position, radius)
	local result = {}
	for mobId, _ in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if pos and (pos - position).Magnitude <= radius then
			table.insert(result, mobId)
		end
	end
	return result
end

function MobService:GetMobsAlongLine(origin : Vector3, through : Vector3, length : number, width : number)
	local flat = Vector3.new(1, 0, 1)

	local heading = (through - origin) * flat
	if heading.Magnitude < 1e-4 then
		return {}
	end

	local direction = heading.Unit
	local found = {}

	for mobId, _ in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if not pos then continue end

		local offset = (pos - origin) * flat
		local along = offset:Dot(direction)

		if along < 0 or along > length then continue end

		if (offset - direction * along).Magnitude <= width then
			table.insert(found, { id = mobId, along = along })
		end
	end

	table.sort(found, function(a, b)
		return a.along < b.along
	end)

	local result = {}
	for _, entry in ipairs(found) do
		table.insert(result, entry.id)
	end

	return result
end

function MobService:addDamageStat(userId, damage)
	if not userId or not damage or damage <= 0 then return end

	local entry = self.SessionDamage[userId]
	if not entry then
		local player = Players:GetPlayerByUserId(userId)
		entry = { damage = 0, name = player and player.DisplayName or "?" }
		self.SessionDamage[userId] = entry
	end

	entry.damage += damage
end

function MobService:GetDamageDealt(userId : number?) : number
	local entry = userId and self.SessionDamage[userId]

	return entry and entry.damage or 0
end

function MobService:GetMVP()
	local best = nil
	local bestDamage = 0

	for userId, entry in self.SessionDamage do
		if entry.damage > bestDamage then
			bestDamage = entry.damage
			best = {
				userId = userId,
				name = entry.name,
				damage = math.floor(entry.damage + 0.5),
			}
		end
	end

	return best
end

function MobService:applyCashBonus(player, amount : number, bonus : number?, scale : number?) : number
	scale = scale or 1

	if amount <= 0 or (scale == 1 and (not bonus or bonus <= 0)) then
		return amount
	end

	local scaled = amount * scale
	local carried = (self.BonusRemainder[player.UserId] or 0) + scaled + (scaled * (bonus or 0))
	local whole = math.floor(carried)

	self.BonusRemainder[player.UserId] = carried - whole

	return whole
end

function MobService:awardDamageReward(killerUserId, damage, bonus : number?, cashScale : number?, healthScale : number?)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end

	local scale = healthScale
	if not scale or scale <= 0 then scale = 1 end

	local reward = math.max(1, math.floor((damage * ServerConfig.Data.CASH_PER_DAMAGE) / scale))
	self:addCash(player, self:applyCashBonus(player, reward, bonus, cashScale))
end

function MobService:awardKillReward(killerUserId, reward, bonus : number?, cashScale : number?)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end
	local amount = reward or math.random(ServerConfig.Data.CASH_PER_KILL_MIN, ServerConfig.Data.CASH_PER_KILL_MAX)
	self:addCash(player, self:applyCashBonus(player, amount, bonus, cashScale))
end

function MobService:DamageMob(mobId, damage, killerUserId, cashBonus : number?, cashScale : number?, damageClasses)
	local mob = self.ActiveMobs[mobId]
	if not mob then return 0 end

	local vulnerability = 1
	if GameClock.Now() < (mob.BleedingUntil or 0) then
		vulnerability = mob.BleedVulnerability or 1
	end

	local elementMultiplier = SharedConfig.ResistanceConfig.GetMultiplier(mob.Name, damageClasses)
	if elementMultiplier <= 0 then
		return 0
	end

	local base = damage or 10
	local incoming = base * (self.BrittleMultiplier or 1) * vulnerability * elementMultiplier
	if incoming ~= base then
		incoming = math.max(1, math.floor(incoming + 0.5))
	end

	local effectiveDamage = math.min(mob.Health, incoming)
	self:addDamageStat(killerUserId, effectiveDamage)

	mob.Health -= incoming
	self:awardDamageReward(killerUserId, effectiveDamage, cashBonus, cashScale, mob.HealthScale)

	self:processDamageGimmicks(mobId, mob)

	if mob.Health <= 0 then
		self:awardKillReward(killerUserId, mob.Reward, cashBonus, cashScale)

		local stats = self:_sessionStatsOf(killerUserId)
		if stats then
			stats.Kills += 1

			if WaveConfig.IsBoss(mob.Name) then
				stats.BossKills += 1
			end
		end

		self:removeMob(mobId)
	end

	return effectiveDamage
end

function MobService:construct()
	Framework:Listen("UpdateCash", function() end)
	Framework:Listen("RequestCash", function(player)
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		else
			Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
		end
	end)
	Framework:Listen("SpawnClientMob", function() end)
	Framework:Listen("UpdateMobSpeed", function() end)
	Framework:Listen("MobFrozen", function() end)
	Framework:Listen("MobBurning", function() end)
	Framework:Listen("MobBleeding", function() end)
	Framework:Listen("MobStatic", function() end)
	Framework:Listen("MobAuraSlowed", function() end)
	Framework:Listen("MobDamageTick", function() end)
	Framework:Listen("MobTeleported", function() end)
	Framework:Listen("KillClientMob", function() end)
	Framework:Listen("HitClientMob", function() end)
	Framework:Listen("AttackVisual", function() end)
	Framework:Listen("MobPlayAttack", function() end)
	Framework:Listen("MobPlayAnim", function() end)
	Framework:Listen("UpdateBaseHealth", function() end)

	Framework:Listen("RequestBaseHealth", function(player)
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
	end)
	Framework:Listen("GameOver", function() end)
	Framework:Listen("ReplicateUnit", function() end)
	Framework:Listen("Bridge", function() end)
	Framework:Listen("ClientReady", function(player)
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		else
			Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
		end
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
		for mobId, mobData in self.ActiveMobs do
			Framework:Fire("SpawnClientMob", player, {
				Id = mobId,
				Name = mobData.Name,
				Speed = mobData.CurrentSpeed,
				MaxHealth = mobData.MaxHealth,
				Health = mobData.Health,
				Route = mobData.RouteIndex,
			})
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		self.FrameId += 1

		dt = GameClock.Scaled(dt)

		local now = GameClock.Now()

		local weatherService = self.Services.WeatherService
		local currentWeather = weatherService and weatherService:GetCurrent() or nil
		if currentWeather ~= self.Weather then
			self:ApplyWeather(currentWeather)
		end

		for mobId, mob in self.ActiveMobs do
			mob.LastDistance = mob.Distance

			if now >= mob.StunnedUntil then
				mob.Distance += mob.CurrentSpeed * dt
				self:processTurnGimmicks(mobId, mob)
			end

			if mob.Distance >= mob.PathLength then
				self:mobEscaped(mobId)
				if self.BaseHealth <= 0 then break end
			end
		end
	end)

	if self.CanDebug then
		RunService.Heartbeat:Connect(function()
			for mobId, _ in self.ActiveMobs do
				local pos = self:PredictPosition(mobId)
				if not pos then continue end

				local part = self.DebugParts[mobId]
				if not part then
					part = Instance.new("Part")
					part.Size = Vector3.new(2, 2, 2)
					part.Color = Color3.new(1, 0, 0)
					part.Anchored = true
					part.CanCollide = false
					part.Transparency = 0.5
					part.Parent = workspace
					self.DebugParts[mobId] = part
				end
				part.Position = pos
			end

			for mobId, part in self.DebugParts do
				if not self.ActiveMobs[mobId] then
					part:Destroy()
					self.DebugParts[mobId] = nil
				end
			end
		end)
	end
end

function MobService:start()
	for ServiceName, _ in self.Services do
		self.Services[ServiceName] = Framework:Get(ServiceName)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		end
	end

	Players.PlayerAdded:Connect(function(player)
		self:initPlayerCash(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.SessionCash[player.UserId] = nil
		self.BonusRemainder[player.UserId] = nil
	end)

	self:construct()
end

function MobService:init()
end

return MobService