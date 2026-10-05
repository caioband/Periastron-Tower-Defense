local UnitStats = require(script.Parent.UnitStats)
local WeatherConfig = require(script.Parent.WeatherConfig)
local UnitAttackConfig = require(script.Parent.UnitAttackConfig)

--[[
	How each unit grows from level to level.

	The normal path is the formula: `BaseCost * CostMultiplier ^ level` for price,
	`Damage * DamageMultiplier ^ level` for damage, `Cooldown * CooldownMultiplier ^
	level` for attack speed. That is what `Default` does and what most units use: a
	geometric progression fits in three numbers and cannot fall out of sync with
	itself.

	Some units, though, have ladders **designed by hand**, and no geometric
	progression passes through all their steps. Those get optional fields:

	| Field | What it is |
	| --- | --- |
	| `Costs` | each upgrade's price, one per level bought (index = current level + 1). Overrides `BaseCost`/`CostMultiplier` |
	| `Damages` | damage at each level (index = level + 1), from 0 to max. Overrides `DamageMultiplier`; item 1 must equal `UnitStats` `Damage` |
	| `Cooldowns` | cooldown at each level (index = level + 1), from 0 to max. Overrides `CooldownMultiplier`; item 1 must equal `UnitStats` `Cooldown` |
	| `Incomes` | a farm's income per wave at each level (index = level + 1). Overrides `Farm.Income` x `DamageMultiplier`; item 1 must equal `UnitStats` `Farm.Income` |
	| `Slows` | a slow aura's slow at each level (index = level + 1), as the fraction removed: 0.3 is "30% slower". Only for units with `SlowAura` in `UnitStats` |

	Ten units use `Costs` today, because their price ladder was designed per wave,
	not by formula: the jumps are uneven on purpose. The Slingshot, Archer, and
	Berserker use `Cooldowns` (none of them drops at a fixed ratio), the Archer and
	Berserker use `Damages`, and only the Entrepreneur, the only farm, uses `Incomes`.

	**`Damages` is the last resort, not the easy way out.** The damage ladder goes
	through rounding, so a hand-designed table almost always still fits a ratio:
	find the multiplier range where all six numbers round right, as the Slingshot
	does with 1.304. Only when that range is empty (the Archer's and Berserker's
	steps cross, and no number works for all six) does the list come in.

	The rule is simple: **if the formula reproduces the table exactly, use the
	formula**. It documents the intent (the max-level target) and still holds if
	`MaxUpgrades` changes; the list does not. Range has the same choice, in
	`UnitStats`' `RangeStats`.
]]
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
	--[[
		Damage and cooldown stop at fixed targets at max level, by the same math as the
		Slasher below: the `MaxUpgrades`-th root of target/base, so the top lands
		exactly on 115 damage and a 3 s cooldown.

		| Level    | 0  | 1    | 2    | 3    | 4    | 5   |
		| Damage   | 38 | 47   | 59   | 73   | 92   | 115 |
		| Cooldown | 5  | 4.51 | 4.08 | 3.68 | 3.32 | 3   |
	]]
	["Subspace Tripminer"] = {
		-- With the 350 placement cost from `UnitStats`, maxing it costs 2,565.
		Costs = { 225, 300, 425, 550, 715 },
		DamageMultiplier = (115 / UnitStats["Subspace Tripminer"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
		CooldownMultiplier = (3 / UnitStats["Subspace Tripminer"].Cooldown) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
	--[=[
		| Level  | 0    | 1    | 2    | 3    | 4    | 5    |
		| Income | 60   | 75   | 95   | 120  | 150  | 225  |
		| Aura   | 10%  | 15%  | 20%  | 25%  | 30%  | 30%  |
		| Range  | 4    | 5    | 5    | 6    | 7    | 8    |

		Income is a hand ladder (`Incomes`) because its steps are not one ratio: the
		first four are near 1.25, and the last is 1.5. That jump is the unit's point:
		its level 5 costs 675 and returns 75 more per wave, the only purchase in the
		table that pays for itself in nine waves instead of killing something.

		Aura and range live in `UnitStats` (`Farm.Aura` and `RangeStats.Levels`), not
		here, because they are unit numbers, not upgrade ladder numbers.

		With the 200 placement cost from `UnitStats`, maxing it costs 2,050.
	]=]
	["Entrepreneur"] = {
		Costs = { 150, 250, 325, 450, 675 },
		Incomes = { 60, 75, 95, 120, 150, 225 },

		--[[
			Inert, kept only because `GetDamageMultiplier` is called for every unit: its
			`Damage` is 0, and income stopped coming from here when it got `Incomes`
			above. Changing this number changes nothing in game.
		]]
		DamageMultiplier = 1.25,
	},
	--[[
		| Level    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Damage   | 35   | 44   | 55   | 68   | 85   | 107  |
		| Cooldown | 2.00 | 1.80 | 1.62 | 1.46 | 1.31 | 1.18 |
		| DPS      | 17.5 | 24.4 | 34.0 | 46.6 | 64.8 | 90.6 |

		Damage and attack speed come from the formula; only the price is a hand ladder
		(`Costs`). With the 200 placement cost from `UnitStats`, maxing it costs 2,090.
	]]
	["Sword"] = {
		Costs = { 165, 250, 325, 450, 700 },
		DamageMultiplier = 1.25,
		CooldownMultiplier = 0.9,
	},
	--[=[
		| Level    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Damage   | 39   | 48   | 65   | 98   | 115  | 135  |
		| Cooldown | 6.00 | 5.80 | 5.50 | 5.25 | 5.10 | 4.80 |
		| Range    | 7    | 8    | 9    | 10   | 11   | 11   |
		| DPS      | 6.5  | 8.3  | 11.8 | 18.7 | 22.5 | 28.1 |

		**The DPS above is per hit, not what the unit deals.** It hits four times per
		cycle with a 10% `HitFalloff` (see its comment in `UnitStats`), so the combo is
		worth 3.44 full hits and real DPS is 3.44x the row: 22.3 at level 0 and 96.7 at
		max. The row is `Damage / Cooldown` only so it compares with the rest of the
		table, which is single-hit.

		Damage and attack speed are hand ladders, and neither fits a ratio. The
		cooldown drops in uneven steps (0.20, 0.30, 0.25, 0.15, and 0.30), how much the
		post-combo recovery shortens; the animation (2.9 s) does not change, which is
		why even at level 5 there are 1.9 s of waiting.

		**Damage has a step no ratio imitates: the third upgrade.** From 65 to 98 is
		+51% at once, against +17% for the next and +35% for the previous; the
		multiplier range that would round to all six numbers is empty by a wide margin
		(level 3 would need 1.357 and level 5 accepts no more than 1.244). That jump is
		the ladder's point: level 3 is where the unit stops being expensive and starts
		being worth it, where the decision to upgrade or sell lives.

		Upgrades buy attack speed and range too (7 to 11, through `UnitStats`
		`RangeStats`), and range changes the unit most: at 11 it covers a stretch of
		path instead of a point.

		With the 400 placement cost from `UnitStats`, maxing it costs 4,130.
	]=]
	["Berserker"] = {
		Costs = { 325, 480, 650, 875, 1400 },
		Damages = { 39, 48, 65, 98, 115, 135 },
		Cooldowns = { 6, 5.8, 5.5, 5.25, 5.1, 4.8 },
	},

		--[[
		| Level  | 0 | 1   | 2   | 3   | 4   | 5 |
		| Damage | 2 | 2.4 | 2.9 | 3.5 | 4.2 | 5 |

		Per tick, before the ramp. The tick interval stays at 0.25 s at every level (no
		`CooldownMultiplier`). Upgrades buy damage, range, and a shorter ramp
		(`Beam.MaxRampTime` in `UnitStats`, see `GetRampTime`).

		The fractions are real: the server carries what a tick cannot deal to the next
		one (`UnitService:stepBonfireBeam`), so level 1 deals 2, 2, 3, 2, 3... The UI's
		`GetDamage` rounds, so it shows 2, 2, 3, 3, 4, 5.

		With the 300 placement cost from `UnitStats`, maxing it costs 2,595.
	]]
	["Bonfire"] = {
		Costs = { 200, 300, 420, 575, 800 },
		DamageMultiplier = (5 / UnitStats["Bonfire"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
		DamageCaps = { 500, 1000, 1500, 2000, 2500, 3000 },
	},

	--[[
		| Level | 0   | 1   | 2   | 3   | 4   | 5   |
		| Slow  | 10% | 14% | 18% | 22% | 26% | 30% |
		| Range | 3   | 3.4 | 3.8 | 4.2 | 4.6 | 5   |

		The ring is on from placement, and each upgrade adds 4 points up to 30%. Range
		comes from `RangeStats` in `UnitStats`.

		With the 150 placement cost from `UnitStats`, maxing it costs 1,350. Provisional.
	]]
	["Cryomancer"] = {
		Costs = { 100, 150, 250, 325, 375 },
		Slows = { 0.10, 0.14, 0.18, 0.22, 0.26, 0.30 },

		-- Inert, kept only because `GetDamageMultiplier` is called for every unit: its
		-- `Damage` is 0.
		DamageMultiplier = 1,
	},

	--[[
		The Slasher's damage goes from **5 (base) to 9 (max level)**, and the multiplier
		is the `MaxUpgrades`-th root of 9/5, written as math rather than 1.12475 so the
		top lands exactly on 9 and keeps landing there if the upgrade cap changes. The
		resulting ladder, rounded as the server rounds:

		| Level    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Damage   | 5    | 6    | 6    | 7    | 8    | 9    |
		| Cooldown | 0.85 | 0.77 | 0.69 | 0.62 | 0.56 | 0.50 |
		| DPS      | 5.9  | 7.8  | 8.7  | 11.3 | 14.3 | 17.9 |

		**Level 2 repeats the damage, and it cannot not repeat**: five steps for four
		damage points. It is not a dead level because `CooldownMultiplier` cuts 10% of
		the interval every level; DPS rises from 5.9 to 17.9 with no flat step.

		Only the price is a hand ladder (`Costs`). With the 90 placement cost from
		`UnitStats`, maxing it costs 1,534.
	]]
	["Slasher"] = {
		Costs = { 100, 144, 230, 370, 600 },
		DamageMultiplier = (9 / UnitStats.Slasher.Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
		CooldownMultiplier = 0.9,
	},
	--[=[
		| Level    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Damage   | 7    | 9    | 12   | 16   | 20   | 26   |
		| Cooldown | 1.15 | 1.05 | 0.93 | 0.87 | 0.82 | 0.77 |
		| Range    | 12   | 13   | 14   | 15   | 15   | 16   |
		| DPS      | 6.1  | 8.6  | 12.9 | 18.4 | 24.4 | 33.8 |

		The cooldown is a hand ladder (`Cooldowns`) because its steps are not
		geometric: it drops 0.10, 0.12, 0.06, 0.05, and 0.05, strong at first and
		almost flat at the end; from level 3 up, upgrades buy damage, not attack speed.

		**`1.304` is not the max-level target written as a root**, unlike the Slasher
		and Frostione: `(26/7) ^ (1/5)` would give 1.3001 and level 3 would land at
		15.4, a 15 where the table wants 16. The range that rounds to all six numbers is
		very narrow (1.3034 to 1.3051), and 1.304 is inside it. Change any step and
		redo the math: there is no slack here, and if the range closes the way out is a
		hand `Damages`, like the Archer's and Berserker's.

		With the 175 placement cost from `UnitStats`, maxing it costs 1,725.
	]=]
	["Slingshot"] = {
		Costs = { 130, 210, 285, 375, 550 },
		DamageMultiplier = 1.304,
		Cooldowns = { 1.15, 1.05, 0.93, 0.87, 0.82, 0.77 },
	},
	--[[
		The shot's damage goes from 15 to 25 at max level, by the same math as the
		Slasher: the `MaxUpgrades`-th root of target/base. Only the shot grows; the burn
		is fixed.

		| Level  | 0  | 1  | 2  | 3  | 4  | 5  |
		| Damage | 15 | 17 | 18 | 20 | 23 | 25 |
	]]
	["Pyre"] = {
		-- With the 150 placement cost from `UnitStats`, maxing it costs 1,560.
		Costs = { 100, 185, 250, 375, 500 },
		DamageMultiplier = (25 / UnitStats["Pyre"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
	--[=[
		| Level    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Damage   | 16   | 20   | 25   | 31   | 37   | 45   |
		| Cooldown | 3.50 | 3.20 | 2.90 | 2.60 | 2.30 | 2.00 |
		| Range    | 12   | 13   | 14   | 15   | 16   | 17   |
		| DPS      | 4.6  | 6.3  | 8.7  | 12.0 | 16.1 | 22.5 |

		Damage and attack speed are hand ladders. The cooldown drops **exactly 0.30 s
		per level** (a straight line, and no straight line is a ratio) and stops at the
		2.00 s of the `Attack` animation at max level: the unit's floor, written this
		way so nobody lowers it without changing the animation too (see its comment in
		`UnitStats`).

		Damage needs `Damages` because the steps cross: for level 3 to land on 31 the
		multiplier would have to be at least 1.2399, and for level 4 to land on 37 it
		would have to be under 1.2373. There is no number between them, so the list is
		the only way, exactly the case the file header describes.

		The Archer and Slingshot no longer differ by pace: both gain damage and attack
		speed with upgrades, and what sets them apart is the piercing arrow (the
		Slingshot pokes one target, the Archer charges the line) and max range, 17
		against 16.

		With the 150 placement cost from `UnitStats`, maxing it costs 1,835.
	]=]
	["Archer"] = {
		Costs = { 125, 235, 300, 425, 600 },
		Damages = { 16, 20, 25, 31, 37, 45 },
		Cooldowns = { 3.5, 3.2, 2.9, 2.6, 2.3, 2 },
	},
	--[[
		The price ladder is by hand (`Costs`), not the old formula: the jump from level 1
		to 2 is smaller than from 0 to 1 (250 to 400 against 450 to 250), and no ratio
		goes backward. It is designed per wave: the first upgrade is cheap on purpose,
		so a player who spent 450 placing it is not stuck a whole wave without touching
		the tower, and the weight is on the last step: 1,500, more than the first three
		together.

		With the 450 placement cost from `UnitStats`, maxing it costs 4,090.
	]]
	["Rocket"] = {
		Costs = { 250, 400, 650, 840, 1500 },
		DamageMultiplier = 1.3,
	},

	--[[
		No `CooldownMultiplier`, like the Berserker: 2.5 s between bolts at every
		level. Attack speed here would not only buy damage but stuns on four enemies at
		once, and the closer the bolts, the more the line moves in jolts. Upgrades on
		this unit buy damage, range, and stun duration (see `GetStunDuration` and its
		comment in `UnitStats`).

		The price ladder is by hand (`Costs`), with the same design as the Rocket above:
		the first upgrade is the cheap one (225 against the 350 to place) and the last
		the expensive one (1,300).

		With the 350 placement cost from `UnitStats`, maxing it costs 3,770.
	]]
	["Electro"] = {
		Costs = { 225, 450, 635, 810, 1300 },
		DamageMultiplier = 1.25,
	},
	--[[
		Upgrades buy damage and attack speed up to fixed max-level targets: 14 damage
		(10 -> 14) and half the cooldown (1 s -> 0.5 s), for 28 DPS at the top. Same
		math as the Slasher below: the `MaxUpgrades`-th root of target/base. Slow and
		freeze do not grow, but a faster shot fills the four stacks sooner, so freezes
		become more frequent with level.

		| Level    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Damage   | 10   | 11   | 11   | 12   | 13   | 14   |
		| Cooldown | 1.00 | 0.87 | 0.76 | 0.66 | 0.57 | 0.50 |
		| DPS      | 10.0 | 12.6 | 14.5 | 18.2 | 22.6 | 28.0 |
	]]
	["Frostione"] = {
		-- With the 200 placement cost from `UnitStats`, maxing it costs 2,015.
		Costs = { 135, 250, 345, 470, 615 },
		DamageMultiplier = (14 / UnitStats["Frostione"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
		CooldownMultiplier = (0.5 / UnitStats["Frostione"].Cooldown) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
	--[[
		+15% damage per level, on all three attacks. The cooldown at the end of the
		sequence drops from 8 s to 6.5 s at max level, by the same math as the Slasher:
		the `MaxUpgrades`-th root of target/base. The meteor radius grows separately
		(`GetMeteorRadius`).
	]]
	["Archmage"] = {
		BaseCost = 300,
		CostMultiplier = 1.7,
		DamageMultiplier = 1.15,
		CooldownMultiplier = (6.5 / UnitStats["Archmage"].Cooldown) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
}

--[[
	Weather enters here, not in each caller.

	Every getter below takes an optional `weather` last: the name of the weather
	Model in effect. With nil (or a weather with no effect on that unit), the number
	returned is exactly the one without weather, so callers that do not care need
	no change.

	Keeping the math here is what makes server and client agree: the range
	`UnitService` uses to find targets, the circle `UnitPlacementController` draws,
	and the number the card shows all come from the same function.

	`WeatherConfig` owns the multipliers; they are only applied here. See
	docs/game/weather-in-match.md.
]]
local function weatherMultiplier(weather, unitName, stat)
	if not weather then return 1 end
	return WeatherConfig.GetUnitMultiplier(weather, unitName, stat)
end

function UnitUpgradeConfig:GetUnitData(unitName)
	return self.Units[unitName] or self.Default
end

--[=[
	What the **next** upgrade costs, from `currentLevel`.

	With `Costs` on the unit, it is item `currentLevel + 1` of the list; without it,
	the usual geometric formula. See the file header for when to use each.
]=]
function UnitUpgradeConfig:GetCost(unitName, currentLevel)
	local data = self:GetUnitData(unitName)
	local ladder = data.Costs

	if ladder then
		-- The clamp keeps a level outside the list from returning nil and becoming an
		-- arithmetic error on the card: callers already checked `IsMaxed`, but the price
		-- of a level that does not exist must still be a number.
		return ladder[math.clamp((currentLevel or 0) + 1, 1, #ladder)]
	end

	return math.floor(data.BaseCost * (data.CostMultiplier ^ currentLevel) + 0.5)
end

--[=[
	What it costs to **place** the unit on the map, with the current weather.

	`UnitStats[name].Cost` times the weather's `Cost` multiplier (rain discounts Ice
	by 25%). Without weather, or with weather that does not touch prices, returns the
	table number untouched.

	It exists for the same reason as the other getters: the server charges through
	here and the hotbar card shows through here, so the player cannot see one price
	and pay another.

	> **Selling does not follow the discount.** `GetInvested` still adds the list
	> price, and both sides use it for the sell value; the server stores the full
	> price in `entry.invested` even when it charged less. The reverse would require
	> the client to know what was paid for each unit (`invested` is not replicated),
	> and the discount would become a mismatch between what the card promises and
	> what the sale gives. In practice the discount is still only an advantage:
	> buying at 75 and selling at 50 is never a profit.
]=]
function UnitUpgradeConfig:GetPlaceCost(unitName, weather)
	local stats = UnitStats[unitName]
	local cost = stats and stats.Cost or 0

	return math.floor(cost * weatherMultiplier(weather, unitName, "Cost") + 0.5)
end

--[=[
	How much the unit's base damage grows up to `level`, **as a factor**, not as
	ready damage.

	Being a factor keeps both sides on the same rounding: the server
	(`UnitService:getDamage`) and the card (`formatDamageOrIncome`) multiply
	`UnitStats.Damage` by this number along with card, charge, and weather, and round
	once, at the end. Returning ready damage would round twice.

	With `Damages` on the unit, the factor is the ladder item divided by base damage,
	which is why item 1 must be the `UnitStats` `Damage` itself, or level 0 would not
	come out as 1. Without it, the usual geometric ratio.
]=]
function UnitUpgradeConfig:GetDamageMultiplier(unitName, level, weather)
	local data = self:GetUnitData(unitName)
	local ladder = data.Damages

	local multiplier
	if ladder then
		local stats = UnitStats[unitName]
		local baseDamage = stats and stats.Damage or 0
		local stepDamage = ladder[math.clamp((level or 0) + 1, 1, #ladder)]

		-- Zero base damage has no possible factor (the Entrepreneur is the case), and the
		-- division would return `nan` to the card. No farm declares `Damages`; the branch
		-- exists so declaring one does not break the screen.
		multiplier = if baseDamage > 0 then stepDamage / baseDamage else 1
	else
		multiplier = data.DamageMultiplier ^ level
	end

	return multiplier * weatherMultiplier(weather, unitName, "Damage")
end

function UnitUpgradeConfig:GetRange(unitName, level, weather)
	local stats = UnitStats[unitName]
	if not stats then return 10 end

	local baseRange = stats.Range or 10
	local rangeStats = stats.RangeStats

	local range = baseRange
	if rangeStats and rangeStats.Levels then
		-- Range per level, for ladders that are not a straight line (see `RangeStats` in
		-- the `UnitStats` header).
		local levels = rangeStats.Levels
		range = levels[math.clamp((level or 0) + 1, 1, #levels)]
	elseif rangeStats then
		local increased = baseRange + ((level or 0) * (rangeStats.Increment or 0))
		range = math.min(increased, math.max(rangeStats.Max or increased, baseRange))
	end

	-- After the upgrade cap, on purpose: weather cuts the range the unit has, not the
	-- range it could have.
	return range * weatherMultiplier(weather, unitName, "Range")
end

--[=[
	Cooldown between attacks.

	Weather attack speed enters as a division: a 1.3 multiplier is "hits 30% faster",
	the same cycle in 1/1.3 of the time.
]=]
function UnitUpgradeConfig:GetCooldown(unitName, level, weather)
	local stats = UnitStats[unitName]
	local baseCooldown = stats and stats.Cooldown or 1
	local data = self:GetUnitData(unitName)
	local ladder = data.Cooldowns

	local cooldown
	if ladder then
		cooldown = ladder[math.clamp((level or 0) + 1, 1, #ladder)]
	else
		cooldown = baseCooldown * ((data.CooldownMultiplier or 1) ^ (level or 0))
	end

	local attackSpeed = weatherMultiplier(weather, unitName, "AttackSpeed")
	if attackSpeed <= 0 then return cooldown end

	return cooldown / attackSpeed
end

--[=[
	How long the unit's attack stops an enemy, at the given level. Zero for units
	that do not stun.

	`Stun.Duration` is level 0's; with `Stun.MaxDuration`, the stun rises linearly to
	it at max level. No weather, like the aura: the thunder weather has its own stun
	(`WeatherConfig.Thunder`) and does not touch units'.
]=]
function UnitUpgradeConfig:GetStunDuration(unitName, level)
	local stats = UnitStats[unitName]
	local stun = stats and stats.Stun

	if not stun then
		return 0
	end

	local base = stun.Duration or 0
	local top = stun.MaxDuration or base
	local progress = math.clamp((level or 0) / self.MaxUpgrades, 0, 1)

	return base + (top - base) * progress
end

--[=[
	The radius of the ice area a hit spreads around the target, at the given level.
	Zero for units without `Frost` or without `Radius`.

	Same ladder as `GetStunDuration` above: `Frost.Radius` at level 0 and
	`Frost.MaxRadius` at max, linearly. Without `MaxRadius` the radius does not grow.
]=]
function UnitUpgradeConfig:GetFrostRadius(unitName, level)
	local stats = UnitStats[unitName]
	local frost = stats and stats.Frost

	if not frost or not frost.Radius then
		return 0
	end

	local base = frost.Radius
	local top = frost.MaxRadius or base
	local progress = math.clamp((level or 0) / self.MaxUpgrades, 0, 1)

	return base + (top - base) * progress
end

--[=[
	The Archmage meteor's explosion radius at the given level. Same ladder as
	`GetFrostRadius` above: `Combo.Meteor.Radius` at level 0 and `MaxRadius` at max,
	linearly. Zero for units without a meteor.
]=]
function UnitUpgradeConfig:GetMeteorRadius(unitName, level)
	local stats = UnitStats[unitName]
	local meteor = stats and stats.Combo and stats.Combo.Meteor

	if not meteor or not meteor.Radius then
		return 0
	end

	local base = meteor.Radius
	local top = meteor.MaxRadius or base
	local progress = math.clamp((level or 0) / self.MaxUpgrades, 0, 1)

	return base + (top - base) * progress
end


--[=[
	How much total damage a capped unit may deal at the given level, from
	`DamageCaps`. `math.huge` for units without one, so they never run out.
]=]
function UnitUpgradeConfig:GetDamageCap(unitName, level)
	local caps = self:GetUnitData(unitName).DamageCaps

	if not caps or #caps == 0 then
		return math.huge
	end

	return caps[math.clamp((level or 0) + 1, 1, #caps)]
end


--[=[
	How long a channeling unit needs to reach full ramp, at the given level. Zero for
	units without `Beam`.

	Same ladder as `GetStunDuration` above: `Beam.RampTime` at level 0 and
	`Beam.MaxRampTime` at max, linearly. Without `MaxRampTime` the time does not change.
	No weather: weather already cuts the damage it ramps through `GetDamageMultiplier`.
]=]
function UnitUpgradeConfig:GetRampTime(unitName, level)
	local stats = UnitStats[unitName]
	local beam = stats and stats.Beam

	if not beam then
		return 0
	end

	local base = beam.RampTime or 0
	local top = beam.MaxRampTime or base
	local progress = math.clamp((level or 0) / self.MaxUpgrades, 0, 1)

	-- A floor, so a typo of zero cannot turn the ramp into a division by zero.
	return math.max(0.1, base + (top - base) * progress)
end

--[=[
	How far into its ramp a channeling unit is, from 0 to 1, after burning `elapsed`
	seconds of match time. Zero for units without `Beam`.
]=]
function UnitUpgradeConfig:GetRampProgress(unitName, level, elapsed)
	local time = self:GetRampTime(unitName, level)

	if time <= 0 then
		return 0
	end

	return math.clamp((elapsed or 0) / time, 0, 1)
end

--[=[
	The damage factor at a ramp progress: `Beam.StartMultiplier` at 0 up to
	`Beam.MaxMultiplier` at 1, linearly. 1 for units without `Beam`.

	A factor, not ready damage, for the same reason as `GetDamageMultiplier`: the
	server multiplies it into the tick and rounds once at the end.
]=]
function UnitUpgradeConfig:GetRampMultiplier(unitName, progress)
	local stats = UnitStats[unitName]
	local beam = stats and stats.Beam

	if not beam then
		return 1
	end

	local start = beam.StartMultiplier or 1
	local top = beam.MaxMultiplier or start

	return start + (top - start) * math.clamp(progress or 0, 0, 1)
end

--[=[
	Which of the unit's `BeamStages` (in `UnitAttackConfig`) a ramp progress is in: the
	last stage whose `At` has been reached. 1 for units without stages.
]=]
function UnitUpgradeConfig:GetBeamStage(unitName, progress)
	local config = UnitAttackConfig[unitName]
	local stages = config and config.BeamStages

	if not stages then
		return 1
	end

	local index = 1

	for i, stage in ipairs(stages) do
		if (progress or 0) >= stage.At then
			index = i
		end
	end

	return index
end




--[=[
	A slow aura's slow at the given level (`Slows`), as the fraction removed: 0.3 is
	"walks 30% slower". Zero for units without `SlowAura`.

	No `weather`, like `GetAuraBonus` below: weather changes the ring's **radius**
	(`GetRange`), not how cold it is.
]=]
function UnitUpgradeConfig:GetAuraSlow(unitName, level)
	local stats = UnitStats[unitName]
	local slows = self:GetUnitData(unitName).Slows

	if not (stats and stats.SlowAura) or not slows or #slows == 0 then
		return 0
	end

	return slows[math.clamp((level or 0) + 1, 1, #slows)]
end

--[=[
	A farm's aura cash bonus at the given level, as an additive fraction: 0.15 is
	"+15%". A unit without an aura returns 0.

	`Aura.MaxBonus` is the cap, and it exists because the bonus **adds up across
	farms**: two covering the same tower are worth double, so this number, not the
	number of farms, limits stacking. Without the field, the math rises without end.

	It does not take `weather` on purpose, unlike the getters above. The bonus is
	economy, and economy does not follow weather (the same rule as `Farm.Income`,
	which `payFarmUnits` pays without weather so drought does not become a cash
	bonus). The aura **radius** is still `GetRange`, with weather, because it is the
	circle the player sees on the ground.
]=]
function UnitUpgradeConfig:GetAuraBonus(unitName, level)
	local stats = UnitStats[unitName]
	local aura = stats and stats.Farm and stats.Farm.Aura

	if not aura then
		return 0
	end

	local bonus = (aura.Bonus or 0) + (aura.BonusPerUpgrade or 0) * (level or 0)

	if aura.MaxBonus then
		return math.min(bonus, aura.MaxBonus)
	end

	return bonus
end

--[=[
	A farm's income per wave at the given level, **unrounded** and without cards.
	Zero for non-farms.

	Returning the raw number is on purpose: callers multiply by the `Income` card and
	round once at the end (`payFarmUnits` on the server, `formatDamageOrIncome` on
	the card). Rounding here would round twice and the card would promise different
	cash than what lands.

	With `Incomes` on the unit, it is item `level + 1`; without it, `Farm.Income`
	growing by `DamageMultiplier`.

	No `weather` for the same reason as `GetAuraBonus` above: income is economy.
]=]
function UnitUpgradeConfig:GetIncome(unitName, level)
	local stats = UnitStats[unitName]
	local farm = stats and stats.Farm

	if not farm then
		return 0
	end

	local ladder = self:GetUnitData(unitName).Incomes

	if ladder then
		return ladder[math.clamp((level or 0) + 1, 1, #ladder)]
	end

	return (farm.Income or 0) * self:GetDamageMultiplier(unitName, level or 0)
end

--[=[
	Damage per hit at the given level, with the same rounding the server uses in
	`UnitService:executeAttack`: the card must show the number that actually lands.
]=]
function UnitUpgradeConfig:GetDamage(unitName, level, weather)
	local stats = UnitStats[unitName]
	local baseDamage = stats and stats.Damage or 0
	return math.floor(baseDamage * self:GetDamageMultiplier(unitName, level or 0, weather) + 0.5)
end

--[=[
	Damage per second: all hits of an attack cycle divided by the cooldown.
]=]
function UnitUpgradeConfig:GetDPS(unitName, level, weather)
	local stats = UnitStats[unitName]
	local cooldown = self:GetCooldown(unitName, level, weather)
	if cooldown <= 0 then return 0 end
	return self:GetDamage(unitName, level, weather) * ((stats and stats.Hits) or 1) / cooldown
end

--[=[
	Total cash invested in the unit: the placement cost plus each upgrade bought. Lets
	the client compute the sell value without the server's `entry.invested`; both
	follow the same table.

	No weather on purpose, both ways: what was invested does not change because it
	started snowing, and rain's placement discount (`GetPlaceCost`) does not enter
	here either; see the comment there.
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
