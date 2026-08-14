--[[
	Single source of truth for the maps a lobby group can pick.

	The key of each entry is the map *name*, and it has to match the folder inside
	`ReplicatedStorage.Shared.Assets.Maps` -- that is the name `MapService:LoadMap`
	takes in the Game place, and it is what the portal hands over when the group
	leaves the lobby.

	`Image` is what the map template in `ChooseMaps` and the portal billboard show.
	The two entries below carry the placeholder icon that shipped with the UI: swap
	them for the real thumbnails.
]]

local module = {}

module.MAPS = {
	["Snowy"] = {
		DisplayName = "Snowy",
		Order = 1,
		Image = "rbxassetid://137712595982446",
	},

	["Default"] = {
		DisplayName = "Default",
		Order = 2,
		Image = "rbxassetid://137712595982446",
	},
}

--[=[
	Returns the canonical map name for the passed string (case insensitive),
	or nil when the map does not exist.
]=]
function module.resolveMap(mapName : string?) : string?
	if typeof(mapName) ~= "string" then
		return nil
	end

	if module.MAPS[mapName] then
		return mapName
	end

	local lowered = string.lower(mapName)
	for name in module.MAPS do
		if string.lower(name) == lowered then
			return name
		end
	end

	return nil
end

--[=[
	Image of a map, or an empty string when the map does not exist.
]=]
function module.getImage(mapName : string?) : string
	local resolvedMap = module.resolveMap(mapName)
	if not resolvedMap then
		return ""
	end

	return module.MAPS[resolvedMap].Image or ""
end

--[=[
	Map names sorted by their configured Order, for UI iteration.
]=]
function module.getOrderedMaps() : { string }
	local ordered = {}
	for name in module.MAPS do
		table.insert(ordered, name)
	end

	table.sort(ordered, function(a, b)
		return (module.MAPS[a].Order or 0) < (module.MAPS[b].Order or 0)
	end)

	return ordered
end

return module
