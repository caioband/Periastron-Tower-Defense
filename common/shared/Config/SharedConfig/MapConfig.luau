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
	portal billboard show. `IndexImage` is the map's item button in the Index (its
	preview shows `Image`, like the map picker), apart from `Image` so each can
	change on its own. Volcano still repeats its `Image` there, until its Index art
	exists; without the field, the Index falls back to `Image`.

	`Music` is the track name in `SoundService.SharedSounds.Musics`, and it is only
	needed when the track is **not** named like the key. `MapService` sends this
	name to `MusicController`, which looks the Sound up by exact name (the
	`SnowyCastle` track is "Snowy Castle", with a space). Without the field, the key
	is used.

	`WinsRequired` is how many wins the player needs to pick the map, and it does
	**two** things: it locks the map and orders the list. There is no separate
	order field on purpose: the list ascends by requirement, and a separate field
	would be the same rule written twice. A new 7-win map slots between Cave and
	Volcano by itself.

	Zero (or no field) is an open map: Farm is the only one today, where every new
	player starts.

	`Event` marks an event map and is the part it belongs to ("PART 1"). An event
	map is played from the lobby's `EventPortals` only: it is left out of
	`getOrderedMaps` (the normal picker, random picks, contracts, quests and
	challenges) and listed by `getEventMaps` instead. The picker card reads
	"PART 1 - Autumn Valley" (`getPickerName`).

	Nothing here is secret. The client reads it to draw the padlock, and
	`PortalService` checks the same thing with the same config when the group
	opens; see `isUnlocked` and docs/lobby/maps-panel.md.
]]

local module = {}

module.MAPS = {
	["Farm"] = {
		DisplayName = "Farm",
		WinsRequired = 0,
		Image = "rbxassetid://91827512669644",
		IndexImage = "rbxassetid://134889398940282",
	},

	-- The folder in `ServerStorage.Maps` is "Desert", with one S, and the key must
	-- match it. The old spelling, "Dessert", is still understood through `ALIASES`.
	["Desert"] = {
		DisplayName = "Desert",
		WinsRequired = 2,
		Image = "rbxassetid://115008998327555",
		IndexImage = "rbxassetid://124881823090136",
	},

	["Snowy"] = {
		DisplayName = "Snowy",
		WinsRequired = 3,
		Image = "rbxassetid://110763146643497",
		IndexImage = "rbxassetid://71579061428500",
	},

	["SnowyCastle"] = {
		DisplayName = "Snowy Castle",
		-- The track in the Package has a space in its name; the key is the map folder, not.
		Music = "Snowy Castle",
		WinsRequired = 4,
		Image = "rbxassetid://82438762834917",
		IndexImage = "rbxassetid://122289557219975",
	},

	-- The folder in `ServerStorage.Maps` is "Mountain", singular, and the key must
	-- match it or `LoadMap` cannot find the map. The plural is only in the name the
	-- player sees.
	["Mountain"] = {
		DisplayName = "Mountains",
		WinsRequired = 5,
		Image = "rbxassetid://111816748733146",
		IndexImage = "rbxassetid://81043528652201",
	},

	["Cave"] = {
		DisplayName = "Cave",
		WinsRequired = 6,
		Image = "rbxassetid://90052719869168",
		IndexImage = "rbxassetid://90926006085448",
	},

	["Volcano"] = {
		DisplayName = "Volcano",
		WinsRequired = 8,
		Image = "rbxassetid://102911300807811",
		IndexImage = "rbxassetid://102911300807811",
	},

	-- Beach, Swamp, and Pale Garden have no track in `SharedSounds.Musics` yet: the
	-- match has no music until one exists.
	["Beach"] = {
		DisplayName = "Beach",
		WinsRequired = 11,
		Image = "rbxassetid://98956022122852",
		IndexImage = "rbxassetid://77471496157497",
	},

	["Swamp"] = {
		DisplayName = "Swamp",
		WinsRequired = 13,
		Image = "rbxassetid://115839585540675",
		IndexImage = "rbxassetid://82590607432784",
	},

	-- The folder in `ServerStorage.Maps` has a space in its name, and so does the key.
	["Pale Garden"] = {
		DisplayName = "Pale Garden",
		WinsRequired = 16,
		Image = "rbxassetid://119383142532337",
		IndexImage = "rbxassetid://91937010857732",
	},

	-- An event map: only the `EventPortals` offer it (see `Event` above).
	["AutumnValley"] = {
		DisplayName = "Autumn Valley",
		Event = "PART 1",
		Music = "FallMap1",
		WinsRequired = 0,
		Image = "rbxassetid://0",
		IndexImage = "rbxassetid://0",
	},
}

--[=[
	Old map names that still resolve, `{ [old] = key }`. A rename only ever adds a
	line here; the old key never comes back into `MAPS`.

	Two things read it:

	  - `resolveMap`, so any old name arriving at runtime (teleport data, a
	    portal request, a Cmdr argument) lands on the current map.
	  - `DataService`, which rewrites the profile on load: `Index.Maps` and the
	    contracts' drawn `Params.Map` hold map **keys**, so a profile saved
	    under an old name would keep it forever. `DisplayName` is never saved, so
	    changing it needs no line here.

	`Dessert` is the key `Desert` had until 2026-08-24. No `PROD_KEY_2` profile
	should hold it (that store, the Index, and the contracts are all newer than
	the rename), so this is insurance, not a known repair.
]=]
module.ALIASES = {
	["Dessert"] = "Desert",
}

--[=[
	The Part each map folder carries at its root with the base health billboard,
	and the name of the TextLabel inside it where the number is written.

	Both names live here because both sides need them: `MapService` clones the Part
	into `workspace.Map` (otherwise the client would not see it, since maps do not
	replicate) and `BaseHealthController` finds the label there to write health on
	each `UpdateBaseHealth`.
]=]
module.BASE_HEALTH_PART = "BaseHP"
module.BASE_HEALTH_LABEL = "Value"

--[=[
	`MapService`'s spawn fallback: when a character spawns (or the map loads with it
	already in game) far from the map folder's first `SpawnLocation`, it is moved
	there.

	  - `SPAWN_HEIGHT_OFFSET` -- studs above the SpawnLocation center where the
	    character appears, so it does not spawn buried.
	  - `SPAWN_FALLBACK_RADIUS` -- up to this distance (in studs, on the horizontal
	    plane) the character counts as "at the spawn" and stays where Roblox put it.
]=]
module.SPAWN_HEIGHT_OFFSET = 5
module.SPAWN_FALLBACK_RADIUS = 25

--[=[
	Returns the canonical map name for the passed string (case insensitive),
	or nil when the map does not exist. An old name in `ALIASES` resolves to the
	map it became.
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

	for old, current in module.ALIASES do
		if string.lower(old) == lowered and module.MAPS[current] then
			return current
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
	How many wins the map requires. An unknown map requires zero: the caller
	already handled the invalid name, and a high number here would lock the list by
	mistake.
]=]
function module.getWinsRequired(mapName : string?) : number
	local resolvedMap = module.resolveMap(mapName)
	if not resolvedMap then
		return 0
	end

	local required = module.MAPS[resolvedMap].WinsRequired

	return typeof(required) == "number" and math.max(math.floor(required), 0) or 0
end

--[=[
	Whether this player may already pick the map.

	The same math on both sides: `ChooseMapsController` draws the padlock with it
	and `PortalService` refuses the group with it. Without `wins` (profile still
	loading) it counts as zero: only what is open shows open, never the reverse.
]=]
function module.isUnlocked(mapName : string?, wins : number?) : boolean
	local owned = typeof(wins) == "number" and math.floor(wins) or 0

	return owned >= module.getWinsRequired(mapName)
end

--[=[
	How many wins are still missing for the map to open, or zero when it is open.
	The number the padlock text writes.
]=]
function module.winsMissing(mapName : string?, wins : number?) : number
	local owned = typeof(wins) == "number" and math.floor(wins) or 0

	return math.max(module.getWinsRequired(mapName) - owned, 0)
end

--[=[
	The map's track in `SoundService.SharedSounds.Musics`.

	Falls back to the key when the map declares no `Music` (most maps, where both
	names already match). An unknown map returns nil, and `MusicController` has
	nothing to play.
]=]
function module.getMusic(mapName : string?) : string?
	local resolved = module.resolveMap(mapName)
	if not resolved then
		return nil
	end

	local entry = module.MAPS[resolved]
	local track = entry and entry.Music

	return typeof(track) == "string" and track or resolved
end

--- Whether the map is an event map, played only from the `EventPortals`.
function module.isEventMap(mapName : string?) : boolean
	local resolved = module.resolveMap(mapName)

	return resolved ~= nil and module.MAPS[resolved].Event ~= nil
end

--- "PART 1 - Autumn Valley" for an event map, the display name otherwise.
function module.getPickerName(mapName : string) : string
	local entry = module.MAPS[mapName]
	local name = entry and entry.DisplayName or mapName

	if entry and entry.Event then
		return `{entry.Event} - {name}`
	end

	return name
end

local function sorted(eventMaps : boolean) : { string }
	local ordered = {}
	for name, entry in module.MAPS do
		if (entry.Event ~= nil) == eventMaps then
			table.insert(ordered, name)
		end
	end

	table.sort(ordered, function(a, b)
		local requiredA, requiredB = module.getWinsRequired(a), module.getWinsRequired(b)

		if requiredA ~= requiredB then
			return requiredA < requiredB
		end

		return a < b
	end)

	return ordered
end

--[=[
	The normal map names for UI iteration, in the order the picker shows them:
	ascending by `WinsRequired`, and alphabetical by key among maps with the same
	requirement. Event maps are not in it: see `getEventMaps`.

	The tiebreak only exists to keep the order **stable**: two screens built from
	the same config list the same way, and the list does not change between openings.
]=]
function module.getOrderedMaps() : { string }
	return sorted(false)
end

--- The event maps, in the same order rule: what the `EventPortals` offer.
function module.getEventMaps() : { string }
	return sorted(true)
end

return module
