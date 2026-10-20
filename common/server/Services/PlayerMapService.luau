local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("PlayerMapService")

local Config = ServerConfig.PlayerMaps

--[[
	The maps players build in the Map Editor, for every place of the universe.

	Two halves:

	  - **The index**, in the player's profile (`PlayerMaps`): which maps and
	    prefabs they own, with name and dates, and the keys of maps they marked
	    (`Favorites`). It goes through `DataService`, so only players on this
	    server can be written; `GetPlayerDataAsync` reads anyone's.
	  - **The content**, in the `Config.PlayerMaps.STORE_NAME` DataStore, one key
	    per map or prefab. A key carries its owner, so any place reads a map from
	    the key alone, without the owner's profile.

	Keys look like `map_<userId>_<mapId>` and `prefab_<userId>_<prefabId>`; build
	them with `MapKey` / `PrefabKey` and read them with `ParseKey`, never by hand.

	The content is stored as given: the editor's `Serializer` encodes and decodes
	it. This service only checks the key and the size.

	In Studio without API access the DataStore falls back to memory, so the editor
	stays testable; `UsingMemory` says so, and the content is gone when the
	server stops. The profile itself goes through ProfileStore's own mock there.

	Every async call answers `ok, result` on success and `false, reason, detail`
	on failure, where `reason` is one of `REASONS`.

	See docs/common/player-maps.md.
]]

local PROFILE_KEY = "PlayerMaps"
local PROFILE_PREFIX = "Player_"

local MAX_ID_LENGTH = 24

local KINDS = {
	map = true,
	prefab = true,
}

-- Why an async call failed.
local REASONS = {
	InvalidKey = "InvalidKey",   -- the key is not a `map_` / `prefab_` key
	Unavailable = "Unavailable", -- the DataStore could not be opened
	TooLarge = "TooLarge",       -- over `MAX_VALUE_BYTES`; detail is the size in bytes
	NotEncodable = "NotEncodable", -- the value cannot become JSON
	Failed = "Failed",           -- every retry failed; detail is the last error
	NotLoaded = "NotLoaded",     -- the player's profile is not open on this server
	Full = "Full",               -- `Favorites` is at `MAX_FAVORITES`
}

export type KeyInfo = {
	Kind : "map" | "prefab",
	UserId : number,
	Id : string,
}

export type MapEntry = { Name : string, Created : number, Modified : number, Count : number }
export type PrefabEntry = { Name : string, Created : number, Count : number }
export type FavoriteEntry = { Added : number }

export type PlayerMapsData = {
	Maps : { [string] : MapEntry },
	Prefabs : { [string] : PrefabEntry },
	Favorites : { [string] : FavoriteEntry },
}

local PlayerMapService = {
	Services = {
		DataService = {},
	},

	REASONS = REASONS,

	-- `true` once the DataStore is open (or memory took its place).
	Ready = false,

	-- `true` in Studio without API access: content lives in `Memory` until the server stops.
	UsingMemory = false,

	Store = nil :: DataStore?,
	Memory = nil :: { [string] : any }?,
}

--[[ INTERNAL ]]

local function validId(id : any) : boolean
	return typeof(id) == "string"
		and #id >= 1
		and #id <= MAX_ID_LENGTH
		and string.match(id, "^[%w_%-]+$") ~= nil
end

local function makeKey(kind : string, userId : number, id : string) : string?
	if typeof(userId) ~= "number" or userId % 1 ~= 0 or not validId(id) then
		return nil
	end

	return `{kind}_{userId}_{id}`
end

local function deepCopy(value : any) : any
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in value do
		copy[key] = deepCopy(child)
	end

	return copy
end

local function count(t : { [any] : any }) : number
	local n = 0
	for _ in t do
		n += 1
	end

	return n
end

function PlayerMapService:_openStore()
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, Config.STORE_NAME)

	if ok then
		local store = result :: DataStore
		local probeOk, probeErr = pcall(store.GetAsync, store, "probe")

		-- Live servers keep the store even if the probe failed: the outage may be
		-- brief, and every call retries on its own.
		if probeOk or not Log.IsStudio() then
			self.Store = store
			self.Ready = true
			return
		end

		result = probeErr
	end

	if Log.IsStudio() then
		log:StudioWarn(`DataStore '{Config.STORE_NAME}' unavailable ({result}); player maps are kept in memory until the server stops. Enable Game Settings > Security > Enable Studio Access to API Services to persist them.`)
		self.Memory = {}
		self.UsingMemory = true
	else
		log:Warn(`could not open DataStore '{Config.STORE_NAME}': {result}`)
	end

	self.Ready = true
end

--- Yields until the DataStore is open (or memory took its place). The async calls
--- already wait on their own; call it to read `UsingMemory` at the right time.
function PlayerMapService:AwaitReady()
	while not self.Ready do
		task.wait()
	end
end

function PlayerMapService:_withRetry(label : string, fn : () -> any) : (boolean, any)
	local lastError = nil

	for attempt = 1, Config.RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end

		lastError = result
		log:Warn(`{label} failed (attempt {attempt}/{Config.RETRIES}): {result}`)

		if attempt < Config.RETRIES then
			task.wait(2 ^ (attempt - 1))
		end
	end

	return false, lastError
end

--[[ KEYS ]]

--- The content key of `mapId`, owned by `userId`. `nil` when the id is not a valid id.
function PlayerMapService.MapKey(userId : number, mapId : string) : string?
	return makeKey("map", userId, mapId)
end

--- The content key of a prefab. `nil` when the id is not a valid id.
function PlayerMapService.PrefabKey(userId : number, prefabId : string) : string?
	return makeKey("prefab", userId, prefabId)
end

--- What a key points at, or `nil` when it is not a key this service writes.
function PlayerMapService.ParseKey(key : any) : KeyInfo?
	if typeof(key) ~= "string" then
		return nil
	end

	local kind, userId, id = string.match(key, "^(%l+)_(%d+)_(.+)$")
	if not kind or not KINDS[kind] or not validId(id) then
		return nil
	end

	return {
		Kind = kind :: any,
		UserId = tonumber(userId) :: number,
		Id = id,
	}
end

--- Whether `id` can be part of a key: 1 to 24 letters, digits, `_` or `-`.
function PlayerMapService.ValidId(id : any) : boolean
	return validId(id)
end

--[[ CONTENT ]]

--- The value under `key`; `nil` (with `ok`) when nothing is stored there.
function PlayerMapService:GetAsync(key : string) : (boolean, any, any)
	if not PlayerMapService.ParseKey(key) then
		return false, REASONS.InvalidKey
	end

	self:AwaitReady()

	if self.Memory then
		return true, deepCopy(self.Memory[key])
	end

	local store = self.Store
	if not store then
		return false, REASONS.Unavailable
	end

	local ok, result = self:_withRetry(`Get {key}`, function()
		return store:GetAsync(key)
	end)
	if not ok then
		return false, REASONS.Failed, result
	end

	return true, result
end

--[[
	Several keys at once, in parallel. Answers `values, failed`: `values[key]` for
	each key read (missing when nothing is stored), and the keys that could not be
	read. Invalid keys count as failed.
]]
function PlayerMapService:GetManyAsync(keys : { string }) : ({ [string] : any }, { string })
	local values = {}
	local failed = {}
	local pending = #keys
	local thread = coroutine.running()

	-- A read that does not yield (memory) finishes inside `task.spawn`, before this
	-- thread is suspended: only resume it once it is actually waiting.
	local waiting = false

	for _, key in keys do
		task.spawn(function()
			local ok, value = self:GetAsync(key)
			if ok then
				values[key] = value
			else
				table.insert(failed, key)
			end

			pending -= 1
			if pending == 0 and waiting then
				task.spawn(thread)
			end
		end)
	end

	if pending > 0 then
		waiting = true
		coroutine.yield()
	end

	return values, failed
end

--[[
	Writes `value` under `key`. The key's owner goes in as the entry's user id, so
	a GDPR erasure request for that player finds it.
]]
function PlayerMapService:SetAsync(key : string, value : any) : (boolean, any, any)
	local info = PlayerMapService.ParseKey(key)
	if not info then
		return false, REASONS.InvalidKey
	end

	local okJson, json = pcall(HttpService.JSONEncode, HttpService, value)
	if not okJson then
		return false, REASONS.NotEncodable, json
	end
	if #json > Config.MAX_VALUE_BYTES then
		return false, REASONS.TooLarge, #json
	end

	self:AwaitReady()

	if self.Memory then
		self.Memory[key] = deepCopy(value)
		return true, nil
	end

	local store = self.Store
	if not store then
		return false, REASONS.Unavailable
	end

	local ok, result = self:_withRetry(`Set {key}`, function()
		return store:UpdateAsync(key, function()
			return value, { info.UserId }
		end)
	end)
	if not ok then
		return false, REASONS.Failed, result
	end

	return true, nil
end

function PlayerMapService:RemoveAsync(key : string) : (boolean, any, any)
	if not PlayerMapService.ParseKey(key) then
		return false, REASONS.InvalidKey
	end

	self:AwaitReady()

	if self.Memory then
		self.Memory[key] = nil
		return true, nil
	end

	local store = self.Store
	if not store then
		return false, REASONS.Unavailable
	end

	local ok, result = self:_withRetry(`Remove {key}`, function()
		return store:RemoveAsync(key)
	end)
	if not ok then
		return false, REASONS.Failed, result
	end

	return true, nil
end

--[[ INDEX (PROFILE) ]]

--[[
	The live `PlayerMaps` of a player on this server, or `nil` while the profile is
	not open. **Read only**: write through `Update`, or the replica and
	`DataUpdated` never hear about it.
]]
function PlayerMapService:GetData(player : Player) : PlayerMapsData?
	local profiles = self.Services.DataService and self.Services.DataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data[PROFILE_KEY]
end

--- `GetData`, waiting up to `timeout` seconds (10 by default) for the profile to open.
function PlayerMapService:AwaitData(player : Player, timeout : number?) : PlayerMapsData?
	local deadline = os.clock() + (timeout or 10)

	while player.Parent == Players and os.clock() < deadline do
		local data = self:GetData(player)
		if data then
			return data
		end

		task.wait(0.2)
	end

	return self:GetData(player)
end

--[[
	Read-modify-write of the player's `PlayerMaps`, like `DataService:Update`.
	Returns the new value, or `nil` when the profile is not open.
]]
function PlayerMapService:Update(player : Player, callback : (PlayerMapsData) -> PlayerMapsData?) : PlayerMapsData?
	if not self:GetData(player) then
		return nil
	end

	return self.Services.DataService:Update(player, PROFILE_KEY, callback)
end

--[[
	Anyone's `PlayerMaps`: the live table when they are on this server, otherwise a
	read of their saved profile (what was on disk at their last save). `ok` with
	`nil` means the player has no profile.
]]
function PlayerMapService:GetPlayerDataAsync(userId : number) : (boolean, PlayerMapsData?)
	local player = Players:GetPlayerByUserId(userId)
	local live = player and self:GetData(player)
	if live then
		return true, live
	end

	local packages = self.Services.DataService and self.Services.DataService.Packages
	local manager = packages and packages.ProfileManager
	if not manager then
		return false, nil
	end

	local ok, profile = pcall(manager.GetAsync, manager, PROFILE_PREFIX .. userId)
	if not ok then
		log:Warn(`could not read the profile of {userId}: {profile}`)
		return false, nil
	end

	return true, profile and profile.Data and profile.Data[PROFILE_KEY] or nil
end

--[[ FAVORITES ]]

function PlayerMapService:IsFavorite(player : Player, key : string) : boolean
	local data = self:GetData(player)
	return data ~= nil and data.Favorites[key] ~= nil
end

--- Marks the map `key` (anyone's). Already marked answers `true`.
function PlayerMapService:AddFavorite(player : Player, key : string) : (boolean, string?)
	local info = PlayerMapService.ParseKey(key)
	if not info or info.Kind ~= "map" then
		return false, REASONS.InvalidKey
	end

	local data = self:GetData(player)
	if not data then
		return false, REASONS.NotLoaded
	end
	if data.Favorites[key] then
		return true, nil
	end
	if count(data.Favorites) >= Config.MAX_FAVORITES then
		return false, REASONS.Full
	end

	self:Update(player, function(value)
		value.Favorites[key] = { Added = os.time() }
		return value
	end)

	return true, nil
end

function PlayerMapService:RemoveFavorite(player : Player, key : string) : (boolean, string?)
	local data = self:GetData(player)
	if not data then
		return false, REASONS.NotLoaded
	end
	if not data.Favorites[key] then
		return true, nil
	end

	self:Update(player, function(value)
		value.Favorites[key] = nil
		return value
	end)

	return true, nil
end

--[[ LIFECYCLE ]]

function PlayerMapService:construct()
	task.spawn(function()
		self:_openStore()
	end)
end

function PlayerMapService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function PlayerMapService:init()
end

return PlayerMapService
