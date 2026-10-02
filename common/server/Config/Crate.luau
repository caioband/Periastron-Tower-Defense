
--[[
	Crate odds: SERVER ONLY.

	It lives here for the same reason as `Summon`: these are the game's drop chances,
	which the client does not need (and should not) read. What the client sees of
	rarity (name, color, order) is in
	`ReplicatedStorage.Shared.Config.SharedConfig.RarityConfig`.

	The pool returns only the RARITY. Which unit comes out is drawn afterward, among
	the units of that rarity (`RarityConfig.getUnitsOfRarity`). That is deliberate:
	to include a new unit in the drop, give it a `Rarity` in UnitStats. To leave one
	out without deleting it from the game, see `EXCLUDED_UNITS` just below.

	See docs/lobby/crates-and-unboxing.md.
]]

local module = {}

--[[
	Units that exist in the game but **drop from no crate**.

	This is not the same as deleting the unit: players who have it keep it, and it
	stays in the deck, the summon banner (`Summon`), stats, and balance. It only
	loses this way in.

	It lives here, not in UnitStats, because it is a **drop** rule, not a unit
	property: its `Rarity` is still Legendary, and that is what the card, the color,
	and the price read. An event or promo exclusive unit goes on this list the day
	the promo ends, and comes off it without touching anything else.

	The odds published in the shop do not change: they are **per rarity**, and
	removing the Azure does not remove the Legendary chance; it just makes the draw
	always land on the other two (Berserker and Electro). The `GetDisplayOdds` math
	still holds word for word.

	⚠️ Emptying an entire rarity here makes the draw **step down** and deliver a
	weaker unit instead, with a warning in the output: the same path as a rarity with
	no units at all. Always leave at least one unit per rarity the pool reaches.
]]
module.EXCLUDED_UNITS = {
	["Azure"] = true,
}

--[[
	Chance (in %) of each unit rarity, per crate opened. Each row sums to 100.

	The common crate does not reach Cosmic: its only way there is to upgrade first
	(see UPGRADES below).

	Cosmic has weight only in the epic tier (the Fragmented Crate), home of the
	Archmage, today's only Cosmic unit. It stays at zero in the other rows on
	purpose.

	⚠️ Zero in the pool is not "never": the common and rare crates can **upgrade** up
	to the epic one (see UPGRADES), and then the draw uses the epic pool. Through that
	path they also deliver Cosmic, much more rarely. `GetOdds` accounts for it; the
	Crate Of Beginnings shop hides the row (see `HIDDEN_DISPLAY_RARITIES`).

	**The common pool is derived backward**, from the chance the shop must show
	(`GetOdds`, with upgrades included), hence the odd numbers. The published target
	for the Crate Of Beginnings is 86 / 10 / 3 / 1.

	Its Cosmic (0.014%, hidden) comes only from upgrading to Fragmented and cannot be
	removed, so Common gives way: the shop shows 85.99, not 86.

	Changing UPGRADES or any other pool changes the Beginnings' published chance too,
	and the math must be redone. It is also why the common crate's upgrade chance is
	10% (see UPGRADES).
]]
module.POOLS = {
	["Common"] = {
		Common = 91.29021,
		Rare = 6.61667,
		Epic = 1.45667,
		Legendary = 0.63645,
		Cosmic = 0,
	},

	["Rare"] = {
		Common = 45,
		Rare = 40,
		Epic = 12,
		Legendary = 3,
		Cosmic = 0,
	},

	-- The Fragmented Crate is the only one with Cosmic (the Archmage): the 1% came out
	-- of Legendary, which held its weight while no Cosmic unit existed.
	["Epic"] = {
		Common = 0,
		Rare = 45,
		Epic = 45,
		Legendary = 9,
		Cosmic = 1,
	},

	["Legendary"] = {
		Common = 0,
		Rare = 20,
		Epic = 40,
		Legendary = 40,
		Cosmic = 0,
	},
}

--[[
	Rarities the SHOP does not show in a crate's odds. Display only: the draw, the
	upgrade, and the guarantee (pity) stay the same.

	The Crate Of Beginnings can still deliver Cosmic by upgrading up to the
	Fragmented Crate (about 0.014%). The row only leaves the screen; the other
	rarities keep their real chance, without redistributing the hidden one's weight.
]]
module.HIDDEN_DISPLAY_RARITIES = {
	["Common"] = { Cosmic = true },   -- Crate Of Beginnings
}

--[[
	Before drawing from the pool, the crate may upgrade to the next one, and then the
	upgraded crate's pool rules. Chance in %.
]]
module.UPGRADES = {
	-- Not 25: at 25%, the share that becomes Nature alone already exceeded 3% Epic
	-- and 10% Rare, so the Beginnings could not publish 86/10/3/1 (see POOLS). The
	-- ceiling that still works is ~17.7%; above it the Beginnings' Epic overflows.
	["Common"] = { To = "Rare", Chance = 10 },
	["Rare"] = { To = "Epic", Chance = 15 },
	["Epic"] = { To = "Legendary", Chance = 8 },
}

--[[
	With `true`, an upgraded crate rolls its own upgrade too: a Common can chain up
	to Legendary (10% * 15% * 8% = 0.12%). With `false`, it upgrades at most one
	step: the Common never goes past Rare.
]]
module.CHAIN_UPGRADES = true

--[=[
	The chance of each unit rarity coming out of a crate of that tier, **with upgrades
	already included**: the number the shop shows.

	The `POOLS` above are the chance after the crate stops upgrading, not the chance
	of buying that crate and getting that rarity. A Crate Of Beginnings upgrades to a
	Crate Of Nature in 10% of openings (and may continue from there), so the common
	pool applies only in 90% of them. The difference is not a detail: Legendary
	comes out at 0.64% by the pool and at **1%** in reality.

	Showing the raw pool would have the shop promise a number the game does not
	deliver, which is why the math is done here and not on screen: **the published
	chance is the real chance**.

	How the math goes: each step of the chain takes `1 - chance` of the remaining
	probability for the current tier and passes the rest on, until a tier with no
	upgrade. With `CHAIN_UPGRADES` off the chain stops at the first step, and the
	function still holds: it reads the same flag the draw reads.

	Returns a `{ [rarity] = percentage }` map summing to 100, or nil for a tier that
	does not exist. A rarity with zero chance is left out: a "0%" row in the shop is
	noise.
]=]
function module.GetOdds(crateRarity : string) : { [string]: number }?
	local pool = module.POOLS[crateRarity]
	if not pool then
		return nil
	end

	-- How much of each tier the purchased crate becomes, after the upgrade rolls.
	local tiers = {}
	local current = crateRarity
	local remaining = 1

	while true do
		local upgrade = module.UPGRADES[current]
		if not upgrade or not module.POOLS[upgrade.To] then
			tiers[current] = (tiers[current] or 0) + remaining
			break
		end

		local chance = math.clamp((upgrade.Chance or 0) / 100, 0, 1)
		tiers[current] = (tiers[current] or 0) + remaining * (1 - chance)
		remaining *= chance
		current = upgrade.To

		if not module.CHAIN_UPGRADES then
			tiers[current] = (tiers[current] or 0) + remaining
			break
		end
	end

	local odds = {}
	for tier, share in tiers do
		for rarity, chance in module.POOLS[tier] do
			odds[rarity] = (odds[rarity] or 0) + share * chance
		end
	end

	for rarity, chance in odds do
		if chance <= 0 then
			odds[rarity] = nil
		end
	end

	return odds
end

--[=[
	`GetOdds` without the rarities in `HIDDEN_DISPLAY_RARITIES`: what the shop shows.
]=]
function module.GetDisplayOdds(crateRarity : string) : { [string]: number }?
	local odds = module.GetOdds(crateRarity)
	local hidden = module.HIDDEN_DISPLAY_RARITIES[crateRarity]

	if odds and hidden then
		for rarity in hidden do
			odds[rarity] = nil
		end
	end

	return odds
end

-- The guarantee (pity) is not here: its limits are not chances. See
-- `SharedConfig.CrateConfig.PITY_RARITIES`.

return module
