--!strict
--[[
	Per-player map persistence, on top of the shared PlayerMapService.

	Where things live:
	  profile PlayerMaps.Maps[mapId]        { Name, Created, Modified, Count }
	  profile PlayerMaps.Prefabs[prefabId]  { Name, Created, Count }
	  DataStore map_<userId>_<mapId>        encoded map (Serializer.encodeMap)
	  DataStore prefab_<userId>_<prefabId>  { v, id, name, owner, objects = { relative records } }

	The profile is the list; the DataStore holds the content, so other places can
	read a map from its key alone (see docs/common/player-maps.md).

	Ownership is the key itself: the userId always comes from the Player object on
	the server, never from the client, and loaded content is checked against it.

	Content is written before the index, so the list never shows a map whose save
	failed. Only this server writes a player's content (the profile session lock
	keeps them on one server), which is why the prefab list can be cached.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Serializer = require(Shared.Serializer)
local MapRules = require(Shared.MapRules)

local Me = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Vendor"):WaitForChild("Me"))

type Map = Serializer.Map

local MapStore = {}

local PREFAB_VERSION = 1

local service: any = nil
MapStore.usingMemory = false

-- [userId] = prefab list as the client gets it, filled on the first load.
local prefabCache: { [number]: { any } } = {}

local function count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function describe(reason: any, detail: any, fallback: string): string
	if reason == service.REASONS.TooLarge then
		return string.format("Map is too large to save (%d KB).", math.floor((tonumber(detail) or 0) / 1024))
	end
	if reason == service.REASONS.NotLoaded then
		return "Your data is still loading. Try again in a moment."
	end
	return fallback
end

function MapStore.init()
	service = Me.new():Get("PlayerMapService", false, true)
	service:AwaitReady()
	MapStore.usingMemory = service.UsingMemory
end

--- Waits for the player's profile. `false` when it did not open in time.
function MapStore.awaitProfile(player: Player): boolean
	return service:AwaitData(player) ~= nil
end

export type Entry = { id: string, name: string, modified: number, count: number, published: boolean }

function MapStore.list(player: Player): (boolean, { Entry } | string)
	local data = service:GetData(player)
	if not data then
		return false, describe(service.REASONS.NotLoaded, nil, "")
	end
	local entries: { Entry } = {}
	for id, info in data.Maps do
		table.insert(entries, {
			id = id,
			name = tostring(info.Name),
			modified = tonumber(info.Modified) or 0,
			count = tonumber(info.Count) or 0,
			published = info.Published ~= nil,
		})
	end
	table.sort(entries, function(a, b)
		return a.modified > b.modified
	end)
	return true, entries
end

function MapStore.save(player: Player, map: Map): (boolean, string?)
	if map.owner ~= player.UserId then
		return false, "You do not own this map."
	end

	local data = service:GetData(player)
	if not data then
		return false, describe(service.REASONS.NotLoaded, nil, "")
	end
	if not data.Maps[map.id] and count(data.Maps) >= Config.MAX_MAPS_PER_PLAYER then
		return false, string.format("You can keep at most %d maps. Delete one first.", Config.MAX_MAPS_PER_PLAYER)
	end

	local key = service.MapKey(player.UserId, map.id)
	if not key then
		return false, "Invalid map id."
	end

	local okContent, reason, detail = service:SetAsync(key, Serializer.encodeMap(map))
	if not okContent then
		return false, describe(reason, detail, "Saving failed. Your work is still here; try again.")
	end

	local written = service:Update(player, function(value)
		value.Maps[map.id] = {
			Name = map.name,
			Created = map.created,
			Modified = map.modified,
			Count = count(map.objects),
		}
		return value
	end)
	if not written then
		return false, "Map saved, but the map list could not be updated. Save again to fix it."
	end

	return true, nil
end

function MapStore.load(player: Player, mapId: string): (boolean, Map | string)
	local key = MapRules.validId(mapId) and service.MapKey(player.UserId, mapId)
	if not key then
		return false, "Invalid map id."
	end
	local ok, data = service:GetAsync(key)
	if not ok then
		return false, "Could not load the map. Try again shortly."
	end
	if data == nil then
		return false, "That map no longer exists."
	end
	local map, err = Serializer.decodeMap(data)
	if not map then
		return false, err or "Map data is corrupt."
	end
	if map.owner ~= player.UserId then
		return false, "You do not own this map."
	end
	return true, map
end

function MapStore.rename(player: Player, mapId: string, name: string): (boolean, string?)
	local ok, result = MapStore.load(player, mapId)
	if not ok then
		return false, result :: string
	end
	local map = result :: Map
	map.name = name
	map.modified = os.time()
	return MapStore.save(player, map)
end

function MapStore.duplicate(player: Player, mapId: string, name: string): (boolean, Map | string)
	local ok, result = MapStore.load(player, mapId)
	if not ok then
		return false, result
	end
	local map = result :: Map
	map.id = Serializer.newId()
	map.name = name
	map.created = os.time()
	map.modified = map.created
	local saved, err = MapStore.save(player, map)
	if not saved then
		return false, err or "Duplicate failed."
	end
	return true, map
end

function MapStore.delete(player: Player, mapId: string): (boolean, string?)
	local key = MapRules.validId(mapId) and service.MapKey(player.UserId, mapId)
	if not key then
		return false, "Invalid map id."
	end
	local written = service:Update(player, function(value)
		value.Maps[mapId] = nil
		return value
	end)
	if not written then
		return false, describe(service.REASONS.NotLoaded, nil, "")
	end
	local okRemove = service:RemoveAsync(key)
	if not okRemove then
		return false, "Removed from the list, but the map data could not be deleted."
	end
	return true, nil
end

--- Every prefab of the player, `{ { id, name, objects } }`, oldest first.
function MapStore.loadPrefabs(player: Player): (boolean, any)
	local cached = prefabCache[player.UserId]
	if cached then
		return true, cached
	end

	local data = service:GetData(player)
	if not data then
		return false, describe(service.REASONS.NotLoaded, nil, "")
	end

	local keys = {}
	for id in data.Prefabs do
		local key = service.PrefabKey(player.UserId, id)
		if key then
			table.insert(keys, key)
		end
	end

	local values, failed = service:GetManyAsync(keys)
	if #failed > 0 then
		return false, "Could not load prefabs."
	end

	local list = {}
	for id, info in data.Prefabs do
		local value = values[service.PrefabKey(player.UserId, id)]
		if typeof(value) == "table" and value.owner == player.UserId and typeof(value.objects) == "table" then
			table.insert(list, { id = id, name = tostring(info.Name), objects = value.objects, created = tonumber(info.Created) or 0 })
		end
	end
	table.sort(list, function(a, b)
		return a.created < b.created
	end)

	prefabCache[player.UserId] = list
	return true, list
end

function MapStore.savePrefab(player: Player, name: string, objects: { any }): (boolean, any)
	local okList, list = MapStore.loadPrefabs(player)
	if not okList then
		return false, list
	end
	if #list >= Config.MAX_PREFABS then
		return false, string.format("You can keep at most %d prefabs.", Config.MAX_PREFABS)
	end

	local id = Serializer.newId()
	local key = service.PrefabKey(player.UserId, id) :: string
	local created = os.time()

	local okContent, reason, detail = service:SetAsync(key, {
		v = PREFAB_VERSION,
		id = id,
		name = name,
		owner = player.UserId,
		objects = objects,
	})
	if not okContent then
		return false, describe(reason, detail, "Could not save prefab.")
	end

	local written = service:Update(player, function(value)
		value.Prefabs[id] = { Name = name, Created = created, Count = #objects }
		return value
	end)
	if not written then
		service:RemoveAsync(key)
		return false, describe(service.REASONS.NotLoaded, nil, "")
	end

	table.insert(list, { id = id, name = name, objects = objects, created = created })
	return true, list
end

function MapStore.deletePrefab(player: Player, prefabId: string): (boolean, any)
	local key = MapRules.validId(prefabId) and service.PrefabKey(player.UserId, prefabId)
	if not key then
		return false, "Invalid prefab."
	end
	local okList, list = MapStore.loadPrefabs(player)
	if not okList then
		return false, list
	end

	local written = service:Update(player, function(value)
		value.Prefabs[prefabId] = nil
		return value
	end)
	if not written then
		return false, describe(service.REASONS.NotLoaded, nil, "")
	end

	for i, prefab in list do
		if prefab.id == prefabId then
			table.remove(list, i)
			break
		end
	end

	-- The prefab is already off the list; leftover content is only wasted space.
	service:RemoveAsync(key)
	return true, list
end

function MapStore.forget(player: Player)
	prefabCache[player.UserId] = nil
end

return MapStore
