--!strict
--[[
	Per-player map persistence.

	Keys (one DataStore, Config.DATASTORE_NAME):
	  idx_<userId>            { maps = { [mapId] = { name, modified, count } } }
	  map_<userId>_<mapId>    encoded map (Serializer.encodeMap)
	  prefabs_<userId>        { list = { { id, name, objects = { relative records } } } }

	Ownership is the key itself: the userId always comes from the Player object on
	the server, never from the client, and loaded content is checked against it.

	In Studio without API access the store falls back to memory so the editor
	stays testable; that is announced once in the output and to the player.
]]
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Serializer = require(Shared.Serializer)
local MapRules = require(Shared.MapRules)

type Map = Serializer.Map

local MapStore = {}

local store: DataStore? = nil
local memory: { [string]: any }? = nil
MapStore.usingMemory = false

local function withRetry<T>(label: string, fn: () -> T): (boolean, any)
	local lastError: any = nil
	for attempt = 1, Config.DATASTORE_RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		warn(string.format("[MapStore] %s failed (attempt %d/%d): %s", label, attempt, Config.DATASTORE_RETRIES, tostring(result)))
		if attempt < Config.DATASTORE_RETRIES then
			task.wait(2 ^ (attempt - 1))
		end
	end
	return false, lastError
end

function MapStore.init()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.DATASTORE_NAME)
	end)
	if ok then
		local probeOk, probeErr = pcall(function()
			return (result :: DataStore):GetAsync("probe")
		end)
		if probeOk then
			store = result
			return
		end
		if RunService:IsStudio() then
			warn("[MapStore] DataStore unavailable in Studio (" .. tostring(probeErr) .. "). Maps are kept in memory for this session. Enable Game Settings > Security > 'Enable Studio Access to API Services' to persist.")
			memory = {}
			MapStore.usingMemory = true
			return
		end
		store = result
		return
	end

	if RunService:IsStudio() then
		warn("[MapStore] DataStoreService unavailable (" .. tostring(result) .. "). Using memory.")
		memory = {}
		MapStore.usingMemory = true
	else
		error("[MapStore] DataStoreService unavailable: " .. tostring(result))
	end
end

local function get(key: string): (boolean, any)
	if memory then
		return true, Serializer.copy(memory[key])
	end
	local ds = store :: DataStore
	return withRetry("Get " .. key, function()
		return ds:GetAsync(key)
	end)
end

local function update(key: string, transform: (any) -> any): (boolean, any)
	if memory then
		local mem = memory
		local value = transform(Serializer.copy(mem[key]))
		if value ~= nil then
			mem[key] = Serializer.copy(value)
		end
		return true, value
	end
	local ds = store :: DataStore
	return withRetry("Update " .. key, function()
		return ds:UpdateAsync(key, transform)
	end)
end

local function remove(key: string): (boolean, any)
	if memory then
		memory[key] = nil
		return true, nil
	end
	local ds = store :: DataStore
	return withRetry("Remove " .. key, function()
		return ds:RemoveAsync(key)
	end)
end

local function indexKey(userId: number): string
	return "idx_" .. userId
end

local function mapKey(userId: number, mapId: string): string
	return "map_" .. userId .. "_" .. mapId
end

local function prefabKey(userId: number): string
	return "prefabs_" .. userId
end

local function countEntries(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function countObjects(map: Map): number
	return countEntries(map.objects)
end

export type Entry = { id: string, name: string, modified: number, count: number }

function MapStore.list(userId: number): (boolean, { Entry } | string)
	local ok, index = get(indexKey(userId))
	if not ok then
		return false, "Could not reach saved maps. Try again shortly."
	end
	local entries: { Entry } = {}
	if typeof(index) == "table" and typeof(index.maps) == "table" then
		for id, info in index.maps do
			if typeof(info) == "table" then
				table.insert(entries, {
					id = id,
					name = tostring(info.name),
					modified = tonumber(info.modified) or 0,
					count = tonumber(info.count) or 0,
				})
			end
		end
	end
	table.sort(entries, function(a, b)
		return a.modified > b.modified
	end)
	return true, entries
end

function MapStore.save(userId: number, map: Map): (boolean, string?)
	if map.owner ~= userId then
		return false, "You do not own this map."
	end

	local encoded = Serializer.encodeMap(map)
	local okJson, json = pcall(HttpService.JSONEncode, HttpService, encoded)
	if not okJson then
		return false, "Map data could not be encoded."
	end
	if #json > Config.MAX_SAVE_BYTES then
		return false, string.format("Map is too large to save (%d KB).", math.floor(#json / 1024))
	end

	local okIndex, index = get(indexKey(userId))
	if not okIndex then
		return false, "Could not reach saved maps. Your work is still here; try again."
	end
	local maps = (typeof(index) == "table" and typeof(index.maps) == "table") and index.maps or {}
	if not maps[map.id] and countEntries(maps) >= Config.MAX_MAPS_PER_PLAYER then
		return false, string.format("You can keep at most %d maps. Delete one first.", Config.MAX_MAPS_PER_PLAYER)
	end

	local okContent = update(mapKey(userId, map.id), function()
		return encoded
	end)
	if not okContent then
		return false, "Saving failed. Your work is still here; try again."
	end

	local okWrite = update(indexKey(userId), function(old)
		local value = typeof(old) == "table" and old or {}
		value.maps = typeof(value.maps) == "table" and value.maps or {}
		value.maps[map.id] = { name = map.name, modified = map.modified, count = countObjects(map) }
		return value
	end)
	if not okWrite then
		return false, "Map saved, but the map list could not be updated. Save again to fix it."
	end

	return true, nil
end

function MapStore.load(userId: number, mapId: string): (boolean, Map | string)
	if not MapRules.validId(mapId) then
		return false, "Invalid map id."
	end
	local ok, data = get(mapKey(userId, mapId))
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
	if map.owner ~= userId then
		return false, "You do not own this map."
	end
	return true, map
end

function MapStore.rename(userId: number, mapId: string, name: string): (boolean, string?)
	local ok, result = MapStore.load(userId, mapId)
	if not ok then
		return false, result :: string
	end
	local map = result :: Map
	map.name = name
	map.modified = os.time()
	return MapStore.save(userId, map)
end

function MapStore.duplicate(userId: number, mapId: string, name: string): (boolean, Map | string)
	local ok, result = MapStore.load(userId, mapId)
	if not ok then
		return false, result
	end
	local map = result :: Map
	map.id = Serializer.newId()
	map.name = name
	map.created = os.time()
	map.modified = map.created
	local saved, err = MapStore.save(userId, map)
	if not saved then
		return false, err or "Duplicate failed."
	end
	return true, map
end

function MapStore.delete(userId: number, mapId: string): (boolean, string?)
	if not MapRules.validId(mapId) then
		return false, "Invalid map id."
	end
	local okIndex = update(indexKey(userId), function(old)
		local value = typeof(old) == "table" and old or {}
		value.maps = typeof(value.maps) == "table" and value.maps or {}
		value.maps[mapId] = nil
		return value
	end)
	if not okIndex then
		return false, "Delete failed. Try again."
	end
	local okRemove = remove(mapKey(userId, mapId))
	if not okRemove then
		return false, "Removed from the list, but the map data could not be deleted."
	end
	return true, nil
end

function MapStore.loadPrefabs(userId: number): (boolean, any)
	local ok, data = get(prefabKey(userId))
	if not ok then
		return false, "Could not load prefabs."
	end
	if typeof(data) ~= "table" or typeof(data.list) ~= "table" then
		return true, {}
	end
	return true, data.list
end

function MapStore.savePrefabs(userId: number, list: { any }): (boolean, string?)
	local ok = update(prefabKey(userId), function()
		return { list = list }
	end)
	if not ok then
		return false, "Could not save prefabs."
	end
	return true, nil
end

return MapStore
