
--[[
	Single source of truth for crates.

	Both the server (validation / granting) and the client (UI order, labels and
	images) read from here, so adding a new rarity only requires editing RARITIES
	and CRATES -- the data template, the cmdr type and the crate UI follow along.
]]

local module = {}

module.RARITIES = {
	"Common",
	"Rare",
	"Epic",
	"Legendary",
}

module.CRATES = {
	["Common"] = {
		DisplayName = "Common Crate",
		Order = 1,
		Image = "rbxassetid://135726334725408",
		Color = Color3.fromRGB(29, 33, 250),
	},

	["Rare"] = {
		DisplayName = "Rare Crate",
		Order = 2,
		Image = "rbxassetid://125866367274436",
		Color = Color3.fromRGB(31, 230, 74),
	},

	["Epic"] = {
		DisplayName = "Epic Crate",
		Order = 3,
		Image = "rbxassetid://135666773191804",
		Color = Color3.fromRGB(227, 19, 255),
	},

	["Legendary"] = {
		DisplayName = "Legendary Crate",
		Order = 4,
		Image = "rbxassetid://96648127627723",
		Color = Color3.fromRGB(255, 191, 51),
	},
}

module.MAX_CRATES_PER_RARITY = 9999

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
