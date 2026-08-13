local UnitStats = require(script.Parent.UnitStats)

local UnitUpgradeConfig = {
	MaxUpgrades = 5,
}

UnitUpgradeConfig.Default = {
	BaseCost = 100,
	CostMultiplier = 1.6,
	DamageMultiplier = 1.25,
	CooldownMultiplier = 1,
}

UnitUpgradeConfig.Units = {
	["Azure"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = 1.25,
	},
	["Subspace Tripminer"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = 1.25,
	},
	["Entrepreneur"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = 1.25,
	},
	["Sword"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = 1.25,
		CooldownMultiplier = 0.9,
	},
	["Slasher"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = 1.25,
		CooldownMultiplier = 0.9,
	},
	["Slingshot"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = 1.25,
	},
	["Rocket"] = {
		BaseCost = 150,
		CostMultiplier = 1.7,
		DamageMultiplier = 1.3,
	},
}

function UnitUpgradeConfig:GetUnitData(unitName)
	return self.Units[unitName] or self.Default
end

function UnitUpgradeConfig:GetCost(unitName, currentLevel)
	local data = self:GetUnitData(unitName)
	return math.floor(data.BaseCost * (data.CostMultiplier ^ currentLevel) + 0.5)
end

function UnitUpgradeConfig:GetDamageMultiplier(unitName, level)
	local data = self:GetUnitData(unitName)
	return data.DamageMultiplier ^ level
end

function UnitUpgradeConfig:GetRange(unitName, level)
	local stats = UnitStats[unitName]
	if not stats then return 10 end

	local baseRange = stats.Range or 10
	local rangeStats = stats.RangeStats
	if not rangeStats then return baseRange end

	local increased = baseRange + ((level or 0) * (rangeStats.Increment or 0))
	return math.min(increased, math.max(rangeStats.Max or increased, baseRange))
end

function UnitUpgradeConfig:GetCooldown(unitName, level)
	local stats = UnitStats[unitName]
	local baseCooldown = stats and stats.Cooldown or 1
	local data = self:GetUnitData(unitName)
	return baseCooldown * ((data.CooldownMultiplier or 1) ^ (level or 0))
end

function UnitUpgradeConfig:IsMaxed(level)
	return (level or 0) >= self.MaxUpgrades
end

return UnitUpgradeConfig
