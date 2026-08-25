--[[
	Single source of truth for the maps a lobby group can pick.

	The key of each entry is the map *name*, and it has to match the folder inside
	`ServerStorage.Maps` in the Game place -- that is the name `MapService:LoadMap`
	takes, and it is what the portal hands over when the group leaves the lobby.

	The map folders live in ServerStorage precisely so they do not replicate: the
	client only ever sees the one map the server cloned into `workspace.Map`. That
	means this config is the *only* thing the lobby can read about maps, so an
	entry missing here is a map the lobby cannot offer.

	`DisplayName` is the only part players read, so it is free to differ from the
	key -- which is not. `Image` is what the map template in `ChooseMaps` and the
	portal billboard show.

	`Order` is just the sort for the picker; renumber freely.
]]

local module = {}

module.MAPS = {
	["Snowy"] = {
		DisplayName = "Snowy",
		Order = 1,
		Image = "rbxassetid://110763146643497",
	},

	["SnowyCastle"] = {
		DisplayName = "Snowy Castle",
		Order = 2,
		Image = "rbxassetid://82438762834917",
	},

	-- A pasta em `ServerStorage.Maps` se chama "Desert", com um S so, e a chave tem
	-- de bater com ela -- era "Dessert" e por isso este mapa nunca era sorteado nem
	-- carregado. O `DisplayName` continua sendo coisa a parte.
	["Desert"] = {
		DisplayName = "Dessert",
		Order = 3,
		Image = "rbxassetid://115008998327555",
	},

	-- A pasta em `ServerStorage.Maps` se chama "Mountain", no singular, e a chave
	-- tem de bater com ela ou o `LoadMap` nao acha o mapa. O plural fica so no
	-- nome que o jogador ve.
	["Mountain"] = {
		DisplayName = "Mountains",
		Order = 4,
		Image = "rbxassetid://111816748733146",
	},

	["Volcano"] = {
		DisplayName = "Volcano",
		Order = 5,
		Image = "rbxassetid://102911300807811",
	},

	["Cave"] = {
		DisplayName = "Cave",
		Order = 6,
		Image = "rbxassetid://90052719869168",
	},

	["Farm"] = {
		DisplayName = "Farm",
		Order = 7,
		Image = "rbxassetid://91827512669644",
	},
}

--[=[
	A Part que cada pasta de mapa traz na raiz com o billboard da vida da base, e o
	nome do TextLabel de dentro dela onde o numero e escrito.

	Os dois nomes moram aqui porque os dois lados precisam do mesmo: o `MapService`
	clona a Part para dentro de `workspace.Map` (sem isso o cliente nao a veria, ja
	que os mapas nao replicam) e o `BaseHealthController` acha o label la para
	escrever a vida a cada `UpdateBaseHealth`.
]=]
module.BASE_HEALTH_PART = "BaseHP"
module.BASE_HEALTH_LABEL = "Value"

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
