
--[[
	Single source of truth for crates.

	Both the server (validation / granting) and the client (UI order, labels and
	images) read from here, so adding a new rarity only requires editing RARITIES
	and CRATES -- the data template, the cmdr type and the crate UI follow along.

	Only what belongs to the crate itself is here. The tier the four names refer to
	(colour, ordering against Cosmic, which units sit in it) is in RarityConfig, and
	what each crate can drop is server side, in ServerScriptService.Config.Crate.
]]

local module = {}

module.RARITIES = {
	"Common",
	"Rare",
	"Epic",
	"Legendary",
}

--[=[
	Each tier's crate.

	| Field | What it is |
	| --- | --- |
	| `DisplayName` | the name the player reads, with spaces |
	| `Key` | the crate's code name, without spaces (see below) |
	| `Image` | its icon in the backpack and the shop |
	| `Order` | its order in lists |

	**`Key` is the crate's name everywhere that is not on-screen text.** It is at
	once the model in `Assets.CratesModel` that unboxing spawns, the crate's
	container in `ShopUI`, and the shop item `Id` in `ShopConfig`. Three places that
	must match; one name guarantees they do.

	Note that **the table key is the tier, and `Key` is the crate**, and they no
	longer look alike: the `Common` tier's crate is `CrateOfBeginnings`. The table
	key links the crate to `RarityConfig` and the drop pool and cannot change
	without a profile migration; `Key` is only a name.
]=]
module.CRATES = {
	["Common"] = {
		DisplayName = "Crate Of Beginnings",
		Order = 1,
		Image = "rbxassetid://79442157203436",
		Key = "CrateOfBeginnings",
	},

	["Rare"] = {
		DisplayName = "Crate Of Nature",
		Order = 2,
		Image = "rbxassetid://100869885751562",
		Key = "CrateOfNature",
	},

	["Epic"] = {
		DisplayName = "Fragmented Crate",
		Order = 3,
		Image = "rbxassetid://130450778663107",
		Key = "FragmentedCrate",
	},

	["Legendary"] = {
		DisplayName = "Legendary Crate",
		Order = 4,
		Image = "rbxassetid://96648127627723",
		Key = "LegendaryCrate",
	},
}

module.MAX_CRATES_PER_RARITY = 9999

-- Display only: how often the "this crate upgrades" card shows up as filler on the
-- unboxing reel, against the ReelWeight of the tiers in RarityConfig. It is not the
-- chance of upgrading -- that is server side, in ServerScriptService.Config.Crate.
module.UPGRADE_REEL_WEIGHT = 12

--[=[
	Returns the canonical rarity name for the passed string (case insensitive),
	or nil when the rarity does not exist.
]=]
function module.resolveRarity(rarity: string?): string?
	if typeof(rarity) ~= "string" then
		return nil
	end

	if module.CRATES[rarity] then
		return rarity
	end

	local lowered = string.lower(rarity)
	for _, rarityName in module.RARITIES do
		if string.lower(rarityName) == lowered then
			return rarityName
		end
	end

	return nil
end

--[=[
	The code name of that tier's crate, or nil when the tier does not exist.

	The same name in three places (see `CRATES`): the model in
	`Assets.CratesModel`, the container in `ShopUI`, and the shop item `Id`.
]=]
function module.getKey(rarity: string?): string?
	local resolvedRarity = module.resolveRarity(rarity)
	if not resolvedRarity then
		return nil
	end

	return module.CRATES[resolvedRarity].Key
end

--[=[
	Name of the model in Assets.CratesModel for a rarity, or nil when the rarity
	does not exist. It is the crate's `Key` -- the model is named after the crate.
]=]
function module.getModelName(rarity: string?): string?
	return module.getKey(rarity)
end

--[=[
	The crate this one can turn into during an unboxing, or nil for the top one.

	Derived from the order of RARITIES, which is the same adjacent chain the server
	rolls in ServerScriptService.Config.Crate.UPGRADES -- what stays server side is
	the chance of it happening, not the fact that it can.
]=]
function module.getNextRarity(rarity: string?): string?
	local resolvedRarity = module.resolveRarity(rarity)
	if not resolvedRarity then
		return nil
	end

	local ordered = module.getOrderedRarities()
	for index, rarityName in ordered do
		if rarityName == resolvedRarity then
			return ordered[index + 1]
		end
	end

	return nil
end

--[=[
	Builds a fresh crate table with every rarity zeroed.
	Used by the data template and as a fallback when a profile has no crates yet.
]=]
function module.createEmptyCrates(): { [string]: number }
	local crates = {}
	for _, rarity in module.RARITIES do
		crates[rarity] = 0
	end

	return crates
end

--[=[
	Rarities sorted by their configured Order, for UI iteration.
]=]
function module.getOrderedRarities(): { string }
	local ordered = table.clone(module.RARITIES)
	table.sort(ordered, function(a, b)
		return (module.CRATES[a].Order or 0) < (module.CRATES[b].Order or 0)
	end)

	return ordered
end

--[[ PITY ]]

--[=[
	The guarantee (pity) for high rarities, in priority order: **one count per rarity,
	shared by every crate**. The profile's `Pity` counts how many openings in a row,
	of any crate, came out **without** that rarity; when the count reaches its limit
	(`PITY_THRESHOLDS`), the next opening delivers it, whatever the crate. The count
	resets whenever the rarity comes out, guaranteed or not.

	The counts are independent: pulling Cosmic does not reset Legendary's, and pulling
	Legendary does not reset Epic's. The guarantee delivers **exactly** its rarity: a
	due Epic comes out as Epic even where the draw could have given more. If several
	come due on the same opening, the first in this list wins, and the others wait for
	the next openings, because their counts stay at the limit.

	It is here, not with the odds on the server, because the limits are not chances:
	the backpack shows them as they are. `CrateService:OpenCrate` applies it; Cmdr's
	`unbox` does not open a real crate and touches no count.
]=]
module.PITY_RARITIES = { "Cosmic", "Legendary", "Epic" }

-- Openings in a row without the rarity, in any crate, that make the next one guaranteed.
module.PITY_THRESHOLDS = {
	Cosmic = 450,
	Legendary = 125,
	Epic = 25,
}

function module.getPityThreshold(rarity: string): number?
	return module.PITY_THRESHOLDS[rarity]
end

--[=[
	The profile's `Pity` as `{ [rarity] = count }`, from either shape it may have.

	Today it is `{ Legendary = 37, Cosmic = 210 }`. Profiles from before the shared
	count still hold one table per crate (`{ Common = { Legendary = 80 }, ... }`); for
	those, each rarity starts from its **highest** crate count, so nobody loses the
	progress they had. The next opening rewrites it in the new shape.
]=]
function module.readPity(pity: any): { [string]: number }
	local counts = {}
	if typeof(pity) ~= "table" then
		return counts
	end

	for _, rarity in module.PITY_RARITIES do
		local value = pity[rarity]

		if typeof(value) == "number" then
			counts[rarity] = value
		else
			local highest = 0
			for _, counters in pity do
				if typeof(counters) == "table" then
					highest = math.max(highest, tonumber(counters[rarity]) or 0)
				end
			end

			counts[rarity] = highest
		end
	end

	return counts
end

return module
