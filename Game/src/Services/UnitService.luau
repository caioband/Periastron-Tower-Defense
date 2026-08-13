local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Units = Assets:WaitForChild("Units")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared:WaitForChild("Util"):WaitForChild("PathUtil"))

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local TARGET_SCANS_PER_FRAME = 8
local MAX_PLACE_DISTANCE = 2048

local UnitService = {
	Services = {
		MobService = {},
		DataService = {},
		WaveService = {}
	},
	PlacedUnits = {},
	UnitsById = {},
	UnitSizes = {},
	SessionCards = {},
	SessionCardMax = {}
}

for _, model in Units:GetChildren() do
	local _, size = model:GetBoundingBox()
	UnitService.UnitSizes[model.Name] = size.X
end

function UnitService:getCardCount(player, unitName)
	local cards = self.SessionCards[player.UserId]
	if not cards then return 0 end
	return cards[unitName] or 0
end

function UnitService:setCardCount(player, unitName, count)
	local cards = self.SessionCards[player.UserId]
	if not cards then return end
	cards[unitName] = count
	Framework:Fire("UpdateCardCounts", player, unitName, count)
end

function UnitService:decrementCardCount(player, unitName)
	local current = self:getCardCount(player, unitName)
	self:setCardCount(player, unitName, math.max(0, current - 1))
end

function UnitService:incrementCardCount(player, unitName)
	local current = self:getCardCount(player, unitName)
	local maxCards = self.SessionCardMax[player.UserId]
	local cap = maxCards and maxCards[unitName] or current
	self:setCardCount(player, unitName, math.min(cap, current + 1))
end

function UnitService:initPlayerCards(player)
	self.Services.DataService:Get(player, function(profileData)
		local cards = {}
		local cardMax = {}
		for unitName, amount in pairs(profileData.Units or {}) do
			cards[unitName] = amount
			cardMax[unitName] = amount
		end
		self.SessionCards[player.UserId] = cards
		self.SessionCardMax[player.UserId] = cardMax

		for unitName, count in cards do
			Framework:Fire("UpdateCardCounts", player, unitName, count)
		end
	end)
end

function UnitService:StunRandomUnit(duration)
	if #self.PlacedUnits == 0 then return end

	local entry = self.PlacedUnits[math.random(1, #self.PlacedUnits)]
	entry.StunnedUntil = os.clock() + (duration or 0)

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitStunned", plr, entry.unitId, duration or 0)
	end
end

function UnitService:construct()
	Framework:Listen("ReplicateUnit", function() end)
	Framework:Listen("RemoveUnit", function() end)
	Framework:Listen("UnitStunned", function() end)
	Framework:Listen("UpdateCardCounts", function() end)
	Framework:Listen("RequestCardCounts", function(player)
		local cards = self.SessionCards[player.UserId]
		if not cards then return end
		for unitName, count in cards do
			Framework:Fire("UpdateCardCounts", player, unitName, count)
		end
	end)

	Framework:Listen("UnitUpgraded", function() end)
	Framework:Listen("UnitSwing", function() end)
	Framework:Listen("TripmineThrown", function() end)
	Framework:Listen("TripmineTriggered", function() end)
	Framework:Listen("FarmPayout", function() end)

	Framework:Listen("SellUnit", function(player, unitId)
		local foundIndex = nil
		for i, entry in ipairs(self.PlacedUnits) do
			if entry.unitId == unitId and entry.ownerUserId == player.UserId then
				foundIndex = i
				break
			end
		end

		if not foundIndex then return end

		local entry = self.PlacedUnits[foundIndex]
		table.remove(self.PlacedUnits, foundIndex)
		self.UnitsById[entry.unitId] = nil

		local refund = math.floor((entry.invested or 0) * SharedConfig.SellRefundRatio)

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("RemoveUnit", plr, entry.unitId)
		end

		self.Services.MobService:addCash(player, refund)
		self:incrementCardCount(player, entry.unitName)
	end)

	Framework:Listen("UpgradeUnit", function(player, unitId)
		local entry = self.UnitsById[unitId]
		if not entry or entry.ownerUserId ~= player.UserId then return end

		local currentLevel = entry.upgrades or 0
		if SharedConfig.UnitUpgradeConfig:IsMaxed(currentLevel) then return end

		local cost = SharedConfig.UnitUpgradeConfig:GetCost(entry.unitName, currentLevel)
		local currentCash = self.Services.MobService:getCash(player)
		if currentCash < cost then return end

		entry.upgrades = currentLevel + 1
		entry.invested = (entry.invested or 0) + cost
		self.Services.MobService:spendCash(player, cost)

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("UnitUpgraded", plr, unitId, entry.upgrades)
		end
	end)

	self.PlayersReady = {}
	Framework:Listen("ClientReady", function(player)
		self.PlayersReady[player.UserId] = true
		for _, entry in self.PlacedUnits do
			Framework:Fire("ReplicateUnit", player, entry.unitName, entry.cf, entry.ownerUserId, entry.unitId, entry.upgrades or 0)
		end
		local cards = self.SessionCards[player.UserId]
		if cards then
			for unitName, count in cards do
				Framework:Fire("UpdateCardCounts", player, unitName, count)
			end
		end
	end)

	Framework:Listen("PlaceUnit", function(player, unitName, cf)
		if typeof(unitName) ~= "string" or typeof(cf) ~= "CFrame" then return end

		local position = cf.Position
		if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then return end
		if position.Magnitude > MAX_PLACE_DISTANCE then return end

		local stats = SharedConfig.UnitStats[unitName]
		if not stats then return end

		local placeCost = stats.Cost or 0
		if self.Services.MobService:getCash(player) < placeCost then return end

		if self:getCardCount(player, unitName) <= 0 then return end

		local unitSizeX = self.UnitSizes[unitName] or 2
		local isValid = true

		local checkSize = Vector3.new(unitSizeX, 6, unitSizeX)
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = CollectionService:GetTagged("Grid")
		local gridProbe = Instance.new("Part")
		gridProbe.Size = checkSize
		gridProbe.Anchored = true
		gridProbe.CanCollide = false
		gridProbe.CanQuery = false
		gridProbe.CanTouch = false
		gridProbe.Transparency = 1
		gridProbe.CFrame = CFrame.new(cf.Position)
		gridProbe.Parent = workspace
		local gridParts = workspace:GetPartsInPart(gridProbe, overlapParams)
		gridProbe:Destroy()
		if #gridParts > 0 then
			isValid = false
		end

		if isValid then
			for _, entry in ipairs(self.PlacedUnits) do
				local otherSizeX = self.UnitSizes[entry.unitName] or 2
				local minDist = (unitSizeX + otherSizeX) / 2
				local posA = Vector3.new(cf.Position.X, 0, cf.Position.Z)
				local posB = Vector3.new(entry.cf.Position.X, 0, entry.cf.Position.Z)
				if (posA - posB).Magnitude < minDist then
					isValid = false
					break
				end
			end
		end

		if isValid then
			local unitId = HttpService:GenerateGUID(false)
			local newEntry = { unitId = unitId, unitName = unitName, cf = cf, ownerUserId = player.UserId, upgrades = 0, invested = placeCost, lastAttack = 0 }
			table.insert(self.PlacedUnits, newEntry)
			self.UnitsById[unitId] = newEntry

			self.Services.MobService:spendCash(player, placeCost)
			self:decrementCardCount(player, unitName)

			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("ReplicateUnit", plr, unitName, cf, player.UserId, unitId, 0)
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		self:stepCombat()
	end)
end

function UnitService:stepCombat()
	local units = self.PlacedUnits
	local count = #units
	if count == 0 then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	local now = os.clock()
	local scansLeft = TARGET_SCANS_PER_FRAME

	self:stepTripmines(now)

	for i = 1, count do
		local entry = units[i]
		local stats = SharedConfig.UnitStats[entry.unitName]

		if stats and stats.Farm then continue end

		if stats and stats.Tripmine then
			if now >= (entry.StunnedUntil or 0) then
				self:stepTripminer(entry, stats, now)
			end
			continue
		end

		if mobService.ActiveMobCount > 0
			and stats
			and now >= (entry.StunnedUntil or 0)
			and now - (entry.lastAttack or 0) >= SharedConfig.UnitUpgradeConfig:GetCooldown(entry.unitName, entry.upgrades or 0)
		then
			local unitPosition = entry.cf.Position
			local range = SharedConfig.UnitUpgradeConfig:GetRange(entry.unitName, entry.upgrades or 0)

			local targetId = entry.targetMobId
			local targetValid = false
			if targetId and mobService.ActiveMobs[targetId] then
				local pos = mobService:getMobPosition(targetId)
				targetValid = pos ~= nil and (pos - unitPosition).Magnitude <= range
			end

			if not targetValid then
				entry.targetMobId = nil
				if scansLeft > 0 then
					scansLeft -= 1
					targetId = mobService:GetNearestMobInRange(unitPosition, range)
					entry.targetMobId = targetId
					targetValid = targetId ~= nil
				end
			end

			if targetValid then
				entry.lastAttack = now
				self:executeAttack(entry, stats, targetId)
			end
		end
	end
end

function UnitService:getMineLimit(entry, tripmineConfig)
	return (tripmineConfig.BaseLimit or 3) + (entry.upgrades or 0) * (tripmineConfig.LimitPerUpgrade or 1)
end

function UnitService:getActiveMineCount(entry)
	local total = entry.pendingMines or 0
	if entry.mines then
		for _ in entry.mines do
			total += 1
		end
	end
	return total
end

function UnitService:getRandomPathPointInRange(entry)
	local smooth = self.Services.MobService:getSmoothPath()
	if not smooth or not smooth.points or #smooth.points < 2 or smooth.length <= 0 then return nil end

	local unitPosition = entry.cf.Position
	local range = SharedConfig.UnitUpgradeConfig:GetRange(entry.unitName, entry.upgrades or 0)

	local step = 1
	local candidates = {}
	local d = 0
	while d <= smooth.length do
		local p = PathUtil.GetPositionAtDistance(smooth, d)
		if p then
			local flat = Vector3.new(p.X - unitPosition.X, 0, p.Z - unitPosition.Z)
			if flat.Magnitude <= range then
				table.insert(candidates, d)
			end
		end
		d += step
	end
	if #candidates == 0 then return nil end

	local distance = candidates[math.random(1, #candidates)] + (math.random() - 0.5) * step
	distance = math.clamp(distance, 0, smooth.length)

	local point = PathUtil.GetPositionAtDistance(smooth, distance)
	local ahead = PathUtil.GetPositionAtDistance(smooth, math.min(smooth.length, distance + 0.5))
	local direction = Vector3.new(ahead.X - point.X, 0, ahead.Z - point.Z)
	if direction.Magnitude < 0.001 then
		local behind = PathUtil.GetPositionAtDistance(smooth, math.max(0, distance - 0.5))
		direction = Vector3.new(point.X - behind.X, 0, point.Z - behind.Z)
	end

	local offset = Vector3.zero
	if direction.Magnitude > 0.001 then
		local perpendicular = direction.Unit:Cross(Vector3.yAxis)
		offset = perpendicular * ((math.random() - 0.5) * 2 * 1.5)
	end

	return point + offset + Vector3.new(0, 0.35, 0)
end

function UnitService:stepTripminer(entry, stats, now)
	local config = stats.Tripmine
	entry.mines = entry.mines or {}

	local cooldown = SharedConfig.UnitUpgradeConfig:GetCooldown(entry.unitName, entry.upgrades or 0)
	if now - (entry.lastAttack or 0) < cooldown then return end

	if self:getActiveMineCount(entry) >= self:getMineLimit(entry, config) then return end

	local position = self:getRandomPathPointInRange(entry)
	if not position then return end

	entry.lastAttack = now
	entry.pendingMines = (entry.pendingMines or 0) + 1

	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[entry.unitName]
	local sequence = attackConfig and attackConfig.AttackSequence
	local windup = sequence and sequence[1] and sequence[1].HitTime or 0

	local mineId = HttpService:GenerateGUID(false)
	local yaw = math.random() * math.pi * 2
	local mineCF = CFrame.new(position) * CFrame.Angles(0, yaw, 0)

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitSwing", plr, entry.unitId, entry.unitName, false, 1)
	end

	task.delay(windup, function()
		entry.pendingMines = math.max(0, (entry.pendingMines or 1) - 1)
		if not self.UnitsById[entry.unitId] then return end
		entry.mines[mineId] = { position = position, cf = mineCF }
		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("TripmineThrown", plr, entry.unitId, mineId, mineCF)
		end
	end)
end

function UnitService:stepTripmines(now)
	local mobService = self.Services.MobService
	if mobService.ActiveMobCount == 0 then return end

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local config = stats and stats.Tripmine
		if config and entry.mines then
			for mineId, mine in entry.mines do
				local triggeredBy = mobService:GetNearestMobInRange(mine.position, config.TriggerRadius or 2.5)
				if triggeredBy then
					entry.mines[mineId] = nil
					local damage = math.floor(stats.Damage * SharedConfig.UnitUpgradeConfig:GetDamageMultiplier(entry.unitName, entry.upgrades or 0) + 0.5)
					local radius = config.AOE and config.AOE.Radius or 6
					local mobsHit = mobService:GetMobsInRadius(mine.position, radius)
					for _, mobId in ipairs(mobsHit) do
						mobService:DamageMob(mobId, damage, entry.ownerUserId)
					end
					for _, plr in ipairs(Players:GetPlayers()) do
						Framework:Fire("TripmineTriggered", plr, entry.unitId, mineId)
					end
				end
			end
		end
	end
end

function UnitService:payFarmUnits()
	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local farm = stats and stats.Farm
		if farm then
			local player = Players:GetPlayerByUserId(entry.ownerUserId)
			if player then
				local amount = math.floor((farm.Income or 0) * SharedConfig.UnitUpgradeConfig:GetDamageMultiplier(entry.unitName, entry.upgrades or 0) + 0.5)
				self.Services.MobService:addCash(player, amount)
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("FarmPayout", plr, entry.unitId, amount)
				end
			end
		end
	end
end

function UnitService:executeAttack(entry, unitStats, initialMobId)
	local unitName = entry.unitName
	local unitId = entry.unitId
	local ownerUserId = entry.ownerUserId
	local unitPosition = entry.cf.Position
	local upgradeLevel = entry.upgrades or 0

	local damage = math.floor(unitStats.Damage * SharedConfig.UnitUpgradeConfig:GetDamageMultiplier(unitName, upgradeLevel) + 0.5)
	local aoe = unitStats.AOE
	local range = SharedConfig.UnitUpgradeConfig:GetRange(unitName, upgradeLevel)
	local totalHits = unitStats.Hits or 1

	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[unitName]
	local sequence = attackConfig and attackConfig.AttackSequence
	local stepIndex = 1
	local windup = 0
	if sequence and #sequence > 0 then
		stepIndex = ((entry.attackStep or 0) % #sequence) + 1
		entry.attackStep = stepIndex
		windup = sequence[stepIndex].HitTime or 0
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitSwing", plr, unitId, unitName, initialMobId, stepIndex)
	end

	task.spawn(function()
		if windup > 0 then
			task.wait(windup)
		end

		for i = 1, totalHits do
			local resolvedMobId = initialMobId
			if resolvedMobId and not self.Services.MobService.ActiveMobs[resolvedMobId] then
				resolvedMobId = self.Services.MobService:GetNearestMobInRange(unitPosition, range)
			end

			local predictedPos = resolvedMobId and self.Services.MobService:PredictPosition(resolvedMobId)

			local hits = {}
			if aoe then
				local aoeCenter = predictedPos or unitPosition
				local mobsInRadius = self.Services.MobService:GetMobsInRadius(aoeCenter, aoe.Radius)
				for _, targetId in ipairs(mobsInRadius) do
					self.Services.MobService:DamageMob(targetId, damage, ownerUserId)
					table.insert(hits, { mobId = targetId, damage = damage })
				end
				if #hits == 0 and resolvedMobId then
					self.Services.MobService:DamageMob(resolvedMobId, damage, ownerUserId)
					table.insert(hits, { mobId = resolvedMobId, damage = damage })
				end
			elseif resolvedMobId then
				self.Services.MobService:DamageMob(resolvedMobId, damage, ownerUserId)
				table.insert(hits, { mobId = resolvedMobId, damage = damage })
			end

			local visualMobId = resolvedMobId or initialMobId
			if visualMobId then
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("AttackVisual", plr, unitId, unitName, visualMobId, hits)
				end
			end

			if i < totalHits then
				task.wait(unitStats.HitInterval)
			end
		end
	end)
end

function UnitService:getUnitNameById(unitId)
	local entry = self.UnitsById[unitId]
	return entry and entry.unitName or nil
end

function UnitService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	local waveService = self.Services.WaveService
	if waveService and waveService.Signals and waveService.Signals.Ended then
		waveService.Signals.Ended:Connect(function()
			if waveService.GameOver then return end
			self:payFarmUnits()
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		self:initPlayerCards(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:initPlayerCards(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.SessionCards[player.UserId] = nil
		self.SessionCardMax[player.UserId] = nil
	end)

	self:construct()
end

function UnitService:init()

end

return UnitService
