
--[[
	Single source of truth for rarity tiers.

	Units carry their tier in UnitStats.Rarity, the crate pools roll a tier, and the
	unboxing reel paints its entries with the tier colour. Adding a tier means editing
	ORDER and TIERS -- everything else reads from here.

	Crates reuse the first four names for their own types: what belongs to the crate
	itself (model, icon) lives in CrateConfig, the tier lives here.

	Nothing in this file is secret. The drop odds are NOT here -- they are server side,
	in ServerScriptService.Config.Crate.
]]

local UnitStats = require(script.Parent.UnitStats)

local module = {}

-- Weakest to strongest.
module.ORDER = {
	"Common",
	"Rare",
	"Epic",
	"Legendary",
	"Cosmic",
}

--[[
	ReelWeight is display only: how often a tier shows up as filler on the unboxing
	reel while it spins. It has nothing to do with the chance of actually getting it --
	the reel just needs to look like the tiers it can land on.
]]
module.TIERS = {
	["Common"] = {
		Order = 1,
		DisplayName = "Common",
		Color = Color3.fromRGB(29, 33, 250),
		ReelWeight = 40,
	},

	["Rare"] = {
		Order = 2,
		DisplayName = "Rare",
		Color = Color3.fromRGB(31, 230, 74),
		ReelWeight = 28,
	},

	["Epic"] = {
		Order = 3,
		DisplayName = "Epic",
		Color = Color3.fromRGB(227, 19, 255),
		ReelWeight = 18,
	},

	["Legendary"] = {
		Order = 4,
		DisplayName = "Legendary",
		Color = Color3.fromRGB(255, 191, 51),
		ReelWeight = 10,
	},

	["Cosmic"] = {
		Order = 5,
		DisplayName = "Cosmic",
		Color = Color3.fromRGB(0, 255, 234),
		ReelWeight = 4,
	},
}

--[=[
	Returns the canonical tier name for the passed string (case insensitive),
	or nil when the tier does not exist.
]=]
function module.resolve(rarity: string?): string?
	if typeof(rarity) ~= "string" then
		return nil
	end

	if module.TIERS[rarity] then
		return rarity
	end

	local lowered = string.lower(rarity)
	for _, rarityName in module.ORDER do
		if string.lower(rarityName) == lowered then
			return rarityName
		end
	end

	return nil
end

function module.getOrder(rarity: string?): number?
	local resolvedRarity = module.resolve(rarity)
	return resolvedRarity and module.TIERS[resolvedRarity].Order
end

function module.getColor(rarity: string?): Color3?
	local resolvedRarity = module.resolve(rarity)
	return resolvedRarity and module.TIERS[resolvedRarity].Color
end

--[=[
	The tier right below the passed one, or nil for the weakest one.
]=]
function module.getLowerRarity(rarity: string?): string?
	local order = module.getOrder(rarity)
	if not order or order <= 1 then
		return nil
	end

	return module.ORDER[order - 1]
end

--[[
	Which units sit in each tier, read off UnitStats. Built once -- UnitStats is
	static -- and sorted so a roll is reproducible for a given seed.
]]
local unitsByRarity: { [string]: { string } }? = nil

local function buildUnitIndex(): { [string]: { string } }
	local index = {}
	for _, rarity in module.ORDER do
		index[rarity] = {}
	end

	for unitName, stats in UnitStats do
		local rarity = module.resolve(stats.Rarity)
		if not rarity then
			warn(string.format("[RarityConfig]: unit %q has no valid Rarity (%s).", unitName, tostring(stats.Rarity)))
			continue
		end

		table.insert(index[rarity], unitName)
	end

	for _, units in index do
		table.sort(units)
	end

	return index
end

--[=[
	Every unit of a tier, in a stable order. Empty when no unit carries that tier yet.
]=]
function module.getUnitsOfRarity(rarity: string?): { string }
	local resolvedRarity = module.resolve(rarity)
	if not resolvedRarity then
		return {}
	end

	if not unitsByRarity then
		unitsByRarity = buildUnitIndex()
	end

	return (unitsByRarity :: { [string]: { string } })[resolvedRarity]
end

return module
