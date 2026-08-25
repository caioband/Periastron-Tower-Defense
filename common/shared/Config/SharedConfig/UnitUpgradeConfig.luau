local UnitStats = require(script.Parent.UnitStats)
local WeatherConfig = require(script.Parent.WeatherConfig)

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

--[[
	O clima entra por aqui, e não em cada chamador.

	Todos os getters abaixo aceitam um `weather` opcional no fim — o nome do Model
	de clima que está no ar. Passando nil (ou um clima sem efeito para aquela
	unidade), o número devolvido é exatamente o de antes, então quem não se importa
	com clima não precisa mudar nada.

	Concentrar a conta aqui é o que faz o servidor e o cliente concordarem: o
	alcance que o `UnitService` usa para procurar alvo, o círculo que o
	`UnitPlacementController` desenha no chão e o número que o card mostra saem
	todos da mesma função. Se o clima entrasse só no combate, o jogador veria um
	círculo que não corresponde ao que a unidade alcança.

	Quem tem os multiplicadores é o `WeatherConfig`; aqui só se aplica.
]]
local function weatherMultiplier(weather, unitName, stat)
	if not weather then return 1 end
	return WeatherConfig.GetUnitMultiplier(weather, unitName, stat)
end

function UnitUpgradeConfig:GetUnitData(unitName)
	return self.Units[unitName] or self.Default
end

function UnitUpgradeConfig:GetCost(unitName, currentLevel)
	local data = self:GetUnitData(unitName)
	return math.floor(data.BaseCost * (data.CostMultiplier ^ currentLevel) + 0.5)
end

function UnitUpgradeConfig:GetDamageMultiplier(unitName, level, weather)
	local data = self:GetUnitData(unitName)
	return (data.DamageMultiplier ^ level) * weatherMultiplier(weather, unitName, "Damage")
end

function UnitUpgradeConfig:GetRange(unitName, level, weather)
	local stats = UnitStats[unitName]
	if not stats then return 10 end

	local baseRange = stats.Range or 10
	local rangeStats = stats.RangeStats

	local range = baseRange
	if rangeStats then
		local increased = baseRange + ((level or 0) * (rangeStats.Increment or 0))
		range = math.min(increased, math.max(rangeStats.Max or increased, baseRange))
	end

	-- Depois do teto de upgrade, de propósito: o clima corta o alcance que a
	-- unidade tem, não o que ela poderia ter.
	return range * weatherMultiplier(weather, unitName, "Range")
end

--[=[
	Cooldown entre ataques.

	A velocidade de ataque do clima entra como divisão: um multiplicador de 1.3 é
	"bate 30% mais rápido", ou seja, o mesmo ciclo em 1/1.3 do tempo.
]=]
function UnitUpgradeConfig:GetCooldown(unitName, level, weather)
	local stats = UnitStats[unitName]
	local baseCooldown = stats and stats.Cooldown or 1
	local data = self:GetUnitData(unitName)
	local cooldown = baseCooldown * ((data.CooldownMultiplier or 1) ^ (level or 0))

	local attackSpeed = weatherMultiplier(weather, unitName, "AttackSpeed")
	if attackSpeed <= 0 then return cooldown end

	return cooldown / attackSpeed
end

--[=[
	O bônus de caixa da aura de uma farm no nível dado, como fração somável: 0.15 é
	"+15%". Unidade sem aura devolve 0.

	Não aceita `weather` de propósito, ao contrário dos getters acima. O bônus é
	economia, e economia não anda com o clima — é a mesma regra do `Farm.Income`,
	que o `payFarmUnits` paga sem clima justamente para a seca não virar bônus de
	caixa. O **raio** da aura continua sendo o `GetRange`, esse sim com clima,
	porque é o círculo que o jogador vê desenhado no chão.
]=]
function UnitUpgradeConfig:GetAuraBonus(unitName, level)
	local stats = UnitStats[unitName]
	local aura = stats and stats.Farm and stats.Farm.Aura

	if not aura then
		return 0
	end

	return (aura.Bonus or 0) + (aura.BonusPerUpgrade or 0) * (level or 0)
end

--[=[
	Dano por golpe no nivel dado, com o mesmo arredondamento que o servidor usa
	em `UnitService:executeAttack` — o card tem que mostrar o numero que vai de
	fato entrar no mob.
]=]
function UnitUpgradeConfig:GetDamage(unitName, level, weather)
	local stats = UnitStats[unitName]
	local baseDamage = stats and stats.Damage or 0
	return math.floor(baseDamage * self:GetDamageMultiplier(unitName, level or 0, weather) + 0.5)
end

--[=[
	Dano por segundo: todos os golpes de um ciclo de ataque divididos pelo cooldown.
]=]
function UnitUpgradeConfig:GetDPS(unitName, level, weather)
	local stats = UnitStats[unitName]
	local cooldown = self:GetCooldown(unitName, level, weather)
	if cooldown <= 0 then return 0 end
	return self:GetDamage(unitName, level, weather) * ((stats and stats.Hits) or 1) / cooldown
end

--[=[
	Total de caixa investido na unidade: o custo de colocacao mais o custo de cada
	upgrade ja comprado. Serve para o cliente calcular o valor de venda sem precisar
	do `entry.invested` do servidor — as duas contas seguem a mesma tabela.

	Sem clima de propósito: o que se investiu não muda porque começou a nevar.
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
