local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local ServerConfig = require(Config.Server)
local PathUtil = require(Shared.Util.PathUtil)

local WaveConfig = ServerConfig.Wave
local DifficultyConfig = ServerConfig.Difficulty

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local BASE_MAX_HEALTH = 100
local MOB_DAMAGE = 20

local function computeTurnDistances(sortedNodes)
	local turnDistances = {}
	local total = 0

	for i = 2, #sortedNodes do
		total += (sortedNodes[i].Position - sortedNodes[i - 1].Position).Magnitude
		if i < #sortedNodes then
			table.insert(turnDistances, total)
		end
	end

	return turnDistances
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
			mob.CurrentSpeed = mob.BaseSpeed * mob.SpeedScale

			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
			end
		end,
	},

	HealthThresholdStunRandomUnit = {
		OnDamage = function(self, mobId, mob, gimmick)
			if gimmick.Once and mob.GimmickState[gimmick] then return end
			if mob.Health > mob.MaxHealth * (gimmick.Threshold or 0.5) then return end

			mob.GimmickState[gimmick] = true

			local freezeTime = gimmick.AnimTime or 0
			mob.StunnedUntil = math.max(mob.StunnedUntil or 0, os.clock() + freezeTime)

			for _, player in Players:GetPlayers() do
				Framework:Fire("MobPlayAttack", player, mobId)
				Framework:Fire("UpdateMobSpeed", player, mobId, 0)
			end

			task.delay(freezeTime, function()
				if not self.ActiveMobs[mobId] then return end

				for _, player in Players:GetPlayers() do
					Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
				end

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
		DifficultyService = {}
	},
	ActiveMobs = {},
	DebugParts = {},
	PositionCache = {},
	FrameId = 0,
	BaseHealth = BASE_MAX_HEALTH,
	MaxBaseHealth = BASE_MAX_HEALTH,
	ActiveMobCount = 0,
	SessionCash = {},
}

function MobService:getSmoothPath()
	if not self.SmoothPath then
		self.SmoothPath = PathUtil.BuildSmoothPath(workspace.PathScriptable.Nodes)
	end
	return self.SmoothPath
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
end

function MobService:spendCash(player, amount)
	if not player or not player.Parent then return end
	self.SessionCash[player.UserId] = math.max(0, (self.SessionCash[player.UserId] or 0) - amount)
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
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
	self.ActiveMobCount = math.max(0, self.ActiveMobCount - 1)

	for _, player in Players:GetPlayers() do
		Framework:Fire("KillClientMob", player, mobId)
	end

	if self.ActiveMobCount == 0 and self.AllMobsSpawned then
		self.Services.WaveService.Signals.Ended:Fire()
	end
end

function MobService:mobEscaped(mobId)
	if not self.ActiveMobs[mobId] then return end

	self.BaseHealth = math.max(0, self.BaseHealth - (self:getDifficulty().MobDamage or MOB_DAMAGE))
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
	self.ActiveMobCount = 0
	self.AllMobsSpawned = false

	for _, player in Players:GetPlayers() do
		Framework:Fire("GameOver", player)
	end

	self.BaseHealth = self.MaxBaseHealth
	self:broadcastBaseHealth()

	local waveService = self.Services.WaveService
	if waveService then
		waveService.GameOver = true
		waveService.Signals.Ended:Fire()
	end
end

function MobService:PredictPosition(mobId)
	local mob = self.ActiveMobs[mobId]
	if not mob then return nil end

	return PathUtil.GetPositionAtDistance(self:getSmoothPath(), mob.Distance)
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
	local mobConfig = ServerConfig.Mob
	local preset = self:getDifficulty()
	local spawnList = WaveConfig.GetSpawns(waveNumber, preset.Name)
	local healthScale = preset.HealthMultiplier * (preset.HealthGrowth ^ (waveNumber - 1))

	local pathNodes = workspace.PathScriptable.Nodes
	self.SmoothPath = PathUtil.BuildSmoothPath(pathNodes)
	local sortedNodes = PathUtil.GetSortedNodes(pathNodes)
	local turnDistances = computeTurnDistances(sortedNodes)

	self.AllMobsSpawned = false
	self.ActiveMobCount = 0

	task.spawn(function()
		for _, spawnEntry in spawnList do
			local entityDefinition = mobConfig.Entities[spawnEntry.Entity]
			if entityDefinition then
				local baseSpeed = mobConfig.BaseSpeed * (entityDefinition.SpeedMultiplier or 1) * preset.SpeedMultiplier
				local maxHealth = math.max(1, math.floor(((entityDefinition.Health or 10) * healthScale) + 0.5))

				for i = 1, (spawnEntry.Amount or 1) do
					if self.BaseHealth <= 0 then break end
					local mobId = HttpService:GenerateGUID(false)

					self.ActiveMobs[mobId] = {
						Name = spawnEntry.Entity,
						Health = maxHealth,
						MaxHealth = maxHealth,
						BaseSpeed = baseSpeed,
						SpeedScale = 1,
						CurrentSpeed = baseSpeed,
						Distance = 0,
						StunnedUntil = 0,
						SortedNodes = sortedNodes,
						TurnDistances = turnDistances,
						NextTurnIndex = 1,
						Gimmicks = entityDefinition.Gimmicks or {},
						GimmickState = {},
						Reward = spawnEntry.Reward,
					}
					self.ActiveMobCount += 1

					for _, player in Players:GetPlayers() do
						Framework:Fire("SpawnClientMob", player, {
							Id = mobId,
							Name = spawnEntry.Entity,
							Speed = baseSpeed,
							MaxHealth = maxHealth,
						})
					end
					task.wait(spawnEntry.SpawnDelay or 1)
				end
			end
		end

		self.AllMobsSpawned = true

		if self.ActiveMobCount == 0 and self.BaseHealth > 0 then
			self.Services.WaveService.Signals.Ended:Fire()
		end
	end)
end

function MobService:getMobPosition(mobId)
	local cached = self.PositionCache[mobId]
	if cached and cached.frame == self.FrameId then
		return cached.pos
	end
	local pos = self:PredictPosition(mobId)
	self.PositionCache[mobId] = { frame = self.FrameId, pos = pos }
	return pos
end

function MobService:GetNearestMobInRange(position, range)
	local bestId = nil
	local bestDist = math.huge
	for mobId, _ in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if not pos then continue end
		local dist = (pos - position).Magnitude
		if dist <= range and dist < bestDist then
			bestDist = dist
			bestId = mobId
		end
	end
	return bestId
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

function MobService:awardDamageReward(killerUserId, damage)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end
	local reward = math.max(1, math.floor(damage * ServerConfig.Data.CASH_PER_DAMAGE))
	self:addCash(player, reward)
end

function MobService:awardKillReward(killerUserId, reward)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end
	local amount = reward or math.random(ServerConfig.Data.CASH_PER_KILL_MIN, ServerConfig.Data.CASH_PER_KILL_MAX)
	self:addCash(player, amount)
end

function MobService:DamageMob(mobId, damage, killerUserId)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	mob.Health -= (damage or 10)
	self:awardDamageReward(killerUserId, damage or 10)

	self:processDamageGimmicks(mobId, mob)

	if mob.Health <= 0 then
		self:awardKillReward(killerUserId, mob.Reward)
		self:removeMob(mobId)
	end
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
	Framework:Listen("KillClientMob", function() end)
	Framework:Listen("HitClientMob", function() end)
	Framework:Listen("AttackVisual", function() end)
	Framework:Listen("MobPlayAttack", function() end)
	Framework:Listen("UpdateBaseHealth", function() end)
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
			})
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		self.FrameId += 1
		local now = os.clock()
		local pathLength = self:getSmoothPath().length

		for mobId, mob in self.ActiveMobs do
			if now >= mob.StunnedUntil then
				mob.Distance += mob.CurrentSpeed * dt
				self:processTurnGimmicks(mobId, mob)
			end

			if mob.Distance >= pathLength then
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
	end)

	self:construct()
end

function MobService:init()
end

return MobService
