
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

-- Model is the name of the model inside ReplicatedStorage.Shared.Assets.CratesModel
-- that the unboxing spawns for that rarity.
module.CRATES = {
	["Common"] = {
		DisplayName = "Common Crate",
		Order = 1,
		Image = "rbxassetid://135726334725408",
		Model = "CommonCrate",
	},

	["Rare"] = {
		DisplayName = "Rare Crate",
		Order = 2,
		Image = "rbxassetid://125866367274436",
		Model = "RareCrate",
	},

	["Epic"] = {
		DisplayName = "Epic Crate",
		Order = 3,
		Image = "rbxassetid://135666773191804",
		Model = "EpicCrate",
	},

	["Legendary"] = {
		DisplayName = "Legendary Crate",
		Order = 4,
		Image = "rbxassetid://96648127627723",
		Model = "LegendaryCrate",
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
	Name of the model in Assets.CratesModel for a rarity, or nil when the rarity
	does not exist.
]=]
function module.getModelName(rarity: string?): string?
	local resolvedRarity = module.resolveRarity(rarity)
	if not resolvedRarity then
		return nil
	end

	return module.CRATES[resolvedRarity].Model
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

return module
