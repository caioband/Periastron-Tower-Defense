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

--[=[
	Dano por golpe no nivel dado, com o mesmo arredondamento que o servidor usa
	em `UnitService:executeAttack` — o card tem que mostrar o numero que vai de
	fato entrar no mob.
]=]
function UnitUpgradeConfig:GetDamage(unitName, level)
	local stats = UnitStats[unitName]
	local baseDamage = stats and stats.Damage or 0
	return math.floor(baseDamage * self:GetDamageMultiplier(unitName, level or 0) + 0.5)
end

--[=[
	Dano por segundo: todos os golpes de um ciclo de ataque divididos pelo cooldown.
]=]
function UnitUpgradeConfig:GetDPS(unitName, level)
	local stats = UnitStats[unitName]
	local cooldown = self:GetCooldown(unitName, level)
	if cooldown <= 0 then return 0 end
	return self:GetDamage(unitName, level) * ((stats and stats.Hits) or 1) / cooldown
end

--[=[
	Total de caixa investido na unidade: o custo de colocacao mais o custo de cada
	upgrade ja comprado. Serve para o cliente calcular o valor de venda sem precisar
	do `entry.invested` do servidor — as duas contas seguem a mesma tabela.
]=]
function UnitUpgradeConfig:GetInvested(unitName, level)
	local stats = UnitStats[unitName]
	local total = stats and stats.Cost or 0

	for currentLevel = 0, (level or 0) - 1 do
		total += self:GetCost(unitName, currentLevel)
	end

	return total
end

function UnitUpgradeConfig:IsMaxed(level)
	return (level or 0) >= self.MaxUpgrades
end

return UnitUpgradeConfig
