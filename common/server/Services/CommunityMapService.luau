local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")
local TextService = game:GetService("TextService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)

local Framework = Me.new()
local log = Log.new("CommunityMapService")

local Config = ServerConfig.CommunityMaps

--[[
	The community catalog: the Map Editor maps their owners published, for every
	player to browse in the Lobby's `ChooseMaps.CommunityMaps` panel.

	Three stores, all under `Config.STORE_NAME`:

	  - **The entry** of each published map, in a DataStore under the map's own key
	    (`PlayerMapService.MapKey`): name, author, description, object count, and
	    the counters (`Config.STATS`). An unpublished map keeps its entry with
	    `Listed = false`, so publishing it again keeps its likes.
	  - **One OrderedDataStore per counter**, `<STORE_NAME>_<Stat>`, holding the
	    same number. It is what sorts the Featured tab, page by page.
	  - **The catalog** (`Config.CATALOG_KEY`): every listed map's name and author
	    in one entry, which is what search reads. It only changes on publish,
	    rename, and unpublish, so one key holds up.

	The player's side lives in their profile, through `PlayerMapService`: the
	`Published` time on their own `Maps` entries, the maps they liked
	(`PlayerMaps.Likes`), and the ones they marked (`PlayerMaps.Favorites`).

	**Counters are buffered.** A like, a visit, or a favorite changes the profile
	right away but only adds to `Deltas`; every `Config.FLUSH_INTERVAL` (and on
	shutdown) each map gets one write with the sum. What this server sends
	includes its own pending deltas, so a player sees their like land at once.

	**Reads are cached for every player on the server**: a sorted listing for
	`QUERY_CACHE_TIME` and a map entry for `META_CACHE_TIME`. Other servers see a
	new map or a new count once their copy expires.

	The client asks through `CommunityMapsRequest` (request id, action, payload)
	and hears back on `CommunityMapsResponse` with the same id: Warp does not order
	events, and the client drops answers to requests it already replaced.

	In Studio without API access everything is kept in memory, like
	`PlayerMapService`, and is gone when the server stops.

	See docs/common/community-maps.md.
]]

local REQUEST_EVENT = "CommunityMapsRequest"
local RESPONSE_EVENT = "CommunityMapsResponse"

local ENTRY_VERSION = 1

-- Entries read per OrderedDataStore page: more than one client page, so most
-- client pages come from what is already cached.
local ORDERED_PAGE_SIZE = 100

local TABS = {
	Featured = true,
	YourMaps = true,
	Favorites = true,
}

-- Why a call failed. The client turns these into text.
local REASONS = {
	InvalidKey = "InvalidKey",   -- not a map key, or not a map this player owns
	NotSaved = "NotSaved",       -- the map is not in the owner's index
	NotFound = "NotFound",       -- the map is not published (anymore)
	NotLoaded = "NotLoaded",     -- the player's profile is not open on this server
	Full = "Full",               -- `Likes` or `Favorites` is at its cap
	Filtered = "Filtered",       -- the text filter could not be reached
	Failed = "Failed",           -- the DataStore failed after every retry
	Busy = "Busy",               -- too many requests of this player in flight
	Invalid = "Invalid",         -- malformed request
	Disabled = "Disabled",       -- not available in this universe (see `PRODUCTION_ENABLED`)
	NotOwner = "NotOwner",       -- the map belongs to someone else
}

export type Entry = {
	v : number,
	Owner : number,
	OwnerName : string,
	Id : string,
	Name : string,
	Description : string,
	Count : number,
	Published : number,
	Updated : number,
	Listed : boolean,
	[string] : any, -- the counters, by `Config.STATS` name
}

local CommunityMapService = {
	Services = {
		PlayerMapService = {},
	},

	REASONS = REASONS,

	Ready = false,
	UsingMemory = false,

	Store = nil :: DataStore?,
	Ordered = {} :: { [string] : OrderedDataStore },

	-- Studio without API access: `{ Entries = { [key] = value }, Ordered = { [stat] = { [key] = number } } }`.
	Memory = nil :: any,

	-- [key] = { Value = Entry?, At = os.clock() }
	MetaCache = {},

	-- [stat .. order] = { At, Entries = { { Key, Value } }, Finished, Cursor, Loading }
	Queries = {},

	Catalog = nil :: { [string] : { N : string, O : string } }?,
	CatalogAt = 0,

	-- [key] = { [stat] = change not written yet }
	Deltas = {},

	-- [Player] = { [key] = true }: maps whose visit this player already counted here.
	Visited = {},

	-- [Player] = requests waiting on the DataStore
	Pending = {},
}

--[[ INTERNAL ]]

local STAT_SET = {}
for _, stat in Config.STATS do
	STAT_SET[stat] = true
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

local function count(t : { [any] : any }?) : number
	local n = 0
	for _ in t or {} do
		n += 1
	end

	return n
end

local function trim(text : string) : string
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

function CommunityMapService:_withRetry(label : string, fn : () -> any) : (boolean, any)
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

function CommunityMapService:_openStores()
	local ok, result = pcall(function()
		local store = DataStoreService:GetDataStore(Config.STORE_NAME)
		local ordered = {}
		for _, stat in Config.STATS do
			ordered[stat] = DataStoreService:GetOrderedDataStore(`{Config.STORE_NAME}_{stat}`)
		end

		-- Studio without API access only fails on the first call, not on GetDataStore.
		store:GetAsync("probe")

		return { Store = store, Ordered = ordered }
	end)

	if ok then
		self.Store = result.Store
		self.Ordered = result.Ordered
	elseif Log.IsStudio() then
		log:StudioWarn(`DataStore '{Config.STORE_NAME}' unavailable ({result}); community maps are kept in memory until the server stops.`)
		self.Memory = { Entries = {}, Ordered = {} }
		for _, stat in Config.STATS do
			self.Memory.Ordered[stat] = {}
		end
		self.UsingMemory = true
	else
		log:Warn(`could not open DataStore '{Config.STORE_NAME}': {result}; retrying on every call.`)
		self.Store = DataStoreService:GetDataStore(Config.STORE_NAME)
		for _, stat in Config.STATS do
			self.Ordered[stat] = DataStoreService:GetOrderedDataStore(`{Config.STORE_NAME}_{stat}`)
		end
	end

	self.Ready = true
end

function CommunityMapService:AwaitReady()
	while not self.Ready do
		task.wait()
	end
end

--[[ STORE ACCESS (DataStore or memory) ]]

function CommunityMapService:_get(key : string) : (boolean, any)
	self:AwaitReady()

	if self.Memory then
		return true, deepCopy(self.Memory.Entries[key])
	end

	return self:_withRetry(`Get {key}`, function()
		return (self.Store :: DataStore):GetAsync(key)
	end)
end

--[[
	Read-modify-write of `key`. `transform` gets the stored value and answers the
	new one and the user ids it belongs to; answering `nil` leaves the key alone.
	Returns whether the call worked and what is stored afterwards.
]]
function CommunityMapService:_update(key : string, transform : (any) -> (any, { number }?)) : (boolean, any)
	self:AwaitReady()

	if self.Memory then
		local value = transform(deepCopy(self.Memory.Entries[key]))
		if value ~= nil then
			self.Memory.Entries[key] = deepCopy(value)
		end
		return true, deepCopy(self.Memory.Entries[key])
	end

	local result = nil
	local store = self.Store :: DataStore
	local ok, err = self:_withRetry(`Update {key}`, function()
		return store:UpdateAsync(key, function(old)
			local value, userIds = transform(old)
			result = if value ~= nil then value else old
			if value == nil then
				return nil
			end
			return value, userIds
		end)
	end)

	if not ok then
		return false, err
	end

	return true, result
end

function CommunityMapService:_remove(key : string) : boolean
	self:AwaitReady()

	if self.Memory then
		self.Memory.Entries[key] = nil
		return true
	end

	return (self:_withRetry(`Remove {key}`, function()
		return (self.Store :: DataStore):RemoveAsync(key)
	end))
end

function CommunityMapService:_setOrdered(stat : string, key : string, value : number) : boolean
	self:AwaitReady()

	if self.Memory then
		self.Memory.Ordered[stat][key] = value
		return true
	end

	return (self:_withRetry(`SetOrdered {stat} {key}`, function()
		return self.Ordered[stat]:SetAsync(key, math.max(0, math.floor(value)))
	end))
end

function CommunityMapService:_removeOrdered(stat : string, key : string) : boolean
	self:AwaitReady()

	if self.Memory then
		self.Memory.Ordered[stat][key] = nil
		return true
	end

	return (self:_withRetry(`RemoveOrdered {stat} {key}`, function()
		return self.Ordered[stat]:RemoveAsync(key)
	end))
end

--[[
	A cursor over one ordering. Each `Next()` answers `ok, entries, finished`, with
	`entries` as `{ { Key, Value } }`.
]]
function CommunityMapService:_cursor(stat : string, ascending : boolean)
	if self.Memory then
		local sorted = {}
		for key, value in self.Memory.Ordered[stat] do
			table.insert(sorted, { Key = key, Value = value })
		end
		table.sort(sorted, function(a, b)
			if a.Value == b.Value then
				return a.Key < b.Key
			end
			return if ascending then a.Value < b.Value else a.Value > b.Value
		end)

		local index = 0
		return {
			Next = function()
				local entries = table.move(sorted, index + 1, index + ORDERED_PAGE_SIZE, 1, {})
				index += ORDERED_PAGE_SIZE
				return true, entries, index >= #sorted
			end,
		}
	end

	local pages : DataStorePages? = nil
	return {
		Next = function()
			local ok, err = self:_withRetry(`Sorted {stat}`, function()
				if pages then
					pages:AdvanceToNextPageAsync()
				else
					pages = self.Ordered[stat]:GetSortedAsync(ascending, ORDERED_PAGE_SIZE)
				end
			end)
			if not ok or not pages then
				return false, err
			end

			local entries = {}
			for _, item in pages:GetCurrentPage() do
				table.insert(entries, { Key = item.key, Value = item.value })
			end

			return true, entries, pages.IsFinished
		end,
	}
end

--[[ ENTRIES ]]

--- A map's entry, from the cache when it is fresh. `ok` with `nil` when there is none.
function CommunityMapService:_getEntry(key : string) : (boolean, Entry?)
	local cached = self.MetaCache[key]
	if cached and os.clock() - cached.At < Config.META_CACHE_TIME then
		return true, cached.Value
	end

	local ok, value = self:_get(key)
	if not ok then
		return false, nil
	end

	self.MetaCache[key] = { Value = value, At = os.clock() }
	return true, value
end

--- Several entries at once, in parallel. Keys that failed or have no entry are left out.
function CommunityMapService:_getEntries(keys : { string }) : { [string] : Entry }
	local found = {}
	local pending = #keys
	local thread = coroutine.running()
	local waiting = false

	for _, key in keys do
		task.spawn(function()
			local ok, value = self:_getEntry(key)
			if ok and value then
				found[key] = value
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

	return found
end

--- What the client gets of a map: the entry plus this server's pending counts.
function CommunityMapService:_view(key : string, entry : Entry) : { [string] : any }
	local deltas = self.Deltas[key]
	local view = {
		Key = key,
		Name = entry.Name,
		Description = entry.Description or "",
		Creator = entry.OwnerName,
		Owner = entry.Owner,
		Count = entry.Count or 0,
		Published = entry.Published or 0,
	}

	for _, stat in Config.STATS do
		view[stat] = math.max(0, (tonumber(entry[stat]) or 0) + (deltas and deltas[stat] or 0))
	end

	return view
end

function CommunityMapService:_forgetEntry(key : string)
	self.MetaCache[key] = nil
	self.Queries = {}
end

--[[ CATALOG ]]

function CommunityMapService:_getCatalog() : { [string] : { N : string, O : string } }
	if self.Catalog and os.clock() - self.CatalogAt < Config.QUERY_CACHE_TIME then
		return self.Catalog
	end

	local ok, value = self:_get(Config.CATALOG_KEY)
	if ok then
		self.Catalog = if typeof(value) == "table" then value else {}
		self.CatalogAt = os.clock()
	end

	return self.Catalog or {}
end

function CommunityMapService:_setCatalog(key : string, item : { N : string, O : string }?)
	local ok, value = self:_update(Config.CATALOG_KEY, function(old)
		local catalog = if typeof(old) == "table" then old else {}
		catalog[key] = item
		return catalog
	end)

	if ok then
		self.Catalog = value
		self.CatalogAt = os.clock()
	end
end

--[[ TEXT ]]

--- `text` as other players may see it, or `nil` when the filter could not answer.
function CommunityMapService:_filter(text : string, userId : number) : string?
	if text == "" then
		return ""
	end

	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, userId):GetNonChatStringForBroadcastAsync()
	end)

	if ok then
		return result
	end

	-- Studio may not reach the filter; nobody else sees the text there.
	return if Log.IsStudio() then text else nil
end

--[[ COUNTERS ]]

function CommunityMapService:_addDelta(key : string, stat : string, amount : number)
	local deltas = self.Deltas[key]
	if not deltas then
		deltas = {}
		self.Deltas[key] = deltas
	end

	deltas[stat] = (deltas[stat] or 0) + amount
end

--[[
	Writes every counter change this server collected, one entry update per map,
	then the orderings with the new totals. A map that failed keeps its changes
	for the next flush; one that is no longer listed drops them.
]]
function CommunityMapService:Flush()
	local deltas = self.Deltas
	self.Deltas = {}

	for key, changes in deltas do
		local ok, entry = self:_update(key, function(old)
			if typeof(old) ~= "table" or not old.Listed then
				return nil
			end

			for stat, amount in changes do
				old[stat] = math.max(0, (tonumber(old[stat]) or 0) + amount)
			end

			return old, { old.Owner }
		end)

		if not ok then
			for stat, amount in changes do
				self:_addDelta(key, stat, amount)
			end
			continue
		end

		if typeof(entry) ~= "table" or not entry.Listed then
			continue
		end

		self.MetaCache[key] = { Value = entry, At = os.clock() }

		for stat in changes do
			self:_setOrdered(stat, key, tonumber(entry[stat]) or 0)
		end
	end
end

--[[ LISTING ]]

--[[
	One client page of the Featured tab: the ordering read from the
	OrderedDataStore, shared by every player on the server until it expires.
	Answers the page's keys and whether more pages exist.
]]
function CommunityMapService:_sortedPage(stat : string, ascending : boolean, page : number) : (boolean, { string }, boolean)
	local id = stat .. (if ascending then "+" else "-")
	local query = self.Queries[id]

	if not query or os.clock() - query.At > Config.QUERY_CACHE_TIME then
		query = {
			At = os.clock(),
			Entries = {},
			Finished = false,
			Cursor = self:_cursor(stat, ascending),
			Loading = false,
		}
		self.Queries[id] = query
	end

	-- One page read at a time per ordering; the others wait and reuse it.
	local needed = page * Config.PAGE_SIZE + 1
	while #query.Entries < needed and not query.Finished do
		if query.Loading then
			task.wait()
			continue
		end

		query.Loading = true
		local ok, entries, finished = query.Cursor.Next()
		query.Loading = false

		if not ok then
			-- Start over next time instead of resuming a cursor in an unknown state.
			if self.Queries[id] == query then
				self.Queries[id] = nil
			end
			return false, {}, false
		end

		for _, entry in entries do
			table.insert(query.Entries, entry)
		end
		query.Finished = finished
	end

	local keys = {}
	local first = (page - 1) * Config.PAGE_SIZE + 1
	for index = first, math.min(first + Config.PAGE_SIZE - 1, #query.Entries) do
		table.insert(keys, query.Entries[index].Key)
	end

	return true, keys, #query.Entries > page * Config.PAGE_SIZE
end

local function matches(view : { [string] : any }, search : string) : boolean
	return string.find(string.lower(view.Name or ""), search, 1, true) ~= nil
		or string.find(string.lower(view.Creator or ""), search, 1, true) ~= nil
end

--[[
	Sorts `keys` by `stat` in memory, filters them by `search`, and answers one page.
	For the tabs whose keys are already known (the player's maps, their favorites,
	search results).
]]
function CommunityMapService:_localPage(keys : { string }, stat : string, ascending : boolean, search : string, page : number) : ({ any }, boolean)
	local entries = self:_getEntries(keys)

	local views = {}
	for key, entry in entries do
		if not entry.Listed then
			continue
		end

		local view = self:_view(key, entry)
		if search == "" or matches(view, search) then
			table.insert(views, view)
		end
	end

	table.sort(views, function(a, b)
		if a[stat] == b[stat] then
			return a.Published > b.Published
		end
		return if ascending then a[stat] < b[stat] else a[stat] > b[stat]
	end)

	local first = (page - 1) * Config.PAGE_SIZE + 1
	return table.move(views, first, first + Config.PAGE_SIZE - 1, 1, {}), #views > page * Config.PAGE_SIZE
end

--[=[
	One page of a tab. `query` is `{ Tab, Stat, Ascending, Search, Page }`, as sent
	by the client; anything off falls back to the defaults. Answers
	`{ Maps = { view }, Page, HasMore }`.
]=]
function CommunityMapService:List(player : Player, query : any) : (boolean, any)
	query = if typeof(query) == "table" then query else {}

	local tab = if TABS[query.Tab] then query.Tab else "Featured"
	local stat = if STAT_SET[query.Stat] then query.Stat else Config.DEFAULT_STAT
	local ascending = if typeof(query.Ascending) == "boolean" then query.Ascending else Config.DEFAULT_ASCENDING
	local page = if typeof(query.Page) == "number" then math.clamp(math.floor(query.Page), 1, 1000) else 1

	local search = if typeof(query.Search) == "string" then string.lower(trim(string.sub(query.Search, 1, Config.MAX_SEARCH_LENGTH))) else ""

	local PlayerMapService = self.Services.PlayerMapService

	if tab == "Featured" and search == "" then
		local ok, keys, hasMore = self:_sortedPage(stat, ascending, page)
		if not ok then
			return false, REASONS.Failed
		end

		local entries = self:_getEntries(keys)
		local maps = {}
		for _, key in keys do
			local entry = entries[key]
			if entry and entry.Listed then
				table.insert(maps, self:_view(key, entry))
			end
		end

		return true, { Maps = maps, Page = page, HasMore = hasMore }
	end

	local keys = {}

	if tab == "Featured" then
		for key, item in self:_getCatalog() do
			if string.find(string.lower(item.N or ""), search, 1, true) or string.find(string.lower(item.O or ""), search, 1, true) then
				table.insert(keys, key)
				if #keys >= Config.MAX_SEARCH_RESULTS then
					break
				end
			end
		end
	else
		local data = PlayerMapService:GetData(player)
		if not data then
			return false, REASONS.NotLoaded
		end

		if tab == "YourMaps" then
			for mapId, info in data.Maps do
				local key = info.Published and PlayerMapService.MapKey(player.UserId, mapId)
				if key then
					table.insert(keys, key)
				end
			end
		else
			for key in data.Favorites do
				table.insert(keys, key)
			end
		end
	end

	local maps, hasMore = self:_localPage(keys, stat, ascending, search, page)
	return true, { Maps = maps, Page = page, HasMore = hasMore }
end

--[[ PLAYER ACTIONS ]]

--- The entry of a listed map, or the reason it cannot be used.
function CommunityMapService:_listedEntry(key : any) : (Entry?, string?)
	local info = self.Services.PlayerMapService.ParseKey(key)
	if not info or info.Kind ~= "map" then
		return nil, REASONS.InvalidKey
	end

	local ok, entry = self:_getEntry(key)
	if not ok then
		return nil, REASONS.Failed
	end
	if not entry or not entry.Listed then
		return nil, REASONS.NotFound
	end

	return entry, nil
end

--- Likes or unlikes a listed map. Answers whether the player likes it now.
function CommunityMapService:SetLiked(player : Player, key : any, liked : boolean) : (boolean, any)
	local PlayerMapService = self.Services.PlayerMapService

	if liked then
		local _, reason = self:_listedEntry(key)
		if reason then
			return false, reason
		end
	elseif not PlayerMapService.ParseKey(key) then
		return false, REASONS.InvalidKey
	end

	-- Read after the yield above: a second click may have landed meanwhile.
	local data = PlayerMapService:GetData(player)
	if not data then
		return false, REASONS.NotLoaded
	end

	local likes = data.Likes or {}
	if (likes[key] ~= nil) == liked then
		return true, liked
	end
	if liked and count(likes) >= Config.MAX_LIKES then
		return false, REASONS.Full
	end

	PlayerMapService:Update(player, function(value)
		value.Likes = value.Likes or {}
		value.Likes[key] = if liked then { Added = os.time() } else nil
		return value
	end)

	self:_addDelta(key, "Likes", if liked then 1 else -1)
	return true, liked
end

--- Marks or unmarks a map as favorite. Answers whether it is a favorite now.
function CommunityMapService:SetFavorite(player : Player, key : any, favorite : boolean) : (boolean, any)
	local PlayerMapService = self.Services.PlayerMapService

	if favorite then
		local _, reason = self:_listedEntry(key)
		if reason then
			return false, reason
		end
	end

	if PlayerMapService:IsFavorite(player, key) == favorite then
		return true, favorite
	end

	local ok, reason
	if favorite then
		ok, reason = PlayerMapService:AddFavorite(player, key)
	else
		ok, reason = PlayerMapService:RemoveFavorite(player, key)
	end

	if not ok then
		return false, reason
	end

	self:_addDelta(key, "Favorites", if favorite then 1 else -1)
	return true, favorite
end

--- Counts a visit: once per player, map, and server.
function CommunityMapService:Visit(player : Player, key : any) : (boolean, any)
	local visited = self.Visited[player]
	if not visited then
		visited = {}
		self.Visited[player] = visited
	end

	if visited[key] then
		return true, nil
	end

	local _, reason = self:_listedEntry(key)
	if reason then
		return false, reason
	end

	visited[key] = true
	self:_addDelta(key, "Visits", 1)
	return true, nil
end

--- Counts a match played on a community map.
function CommunityMapService:CountPlay(key : string)
	self:_addDelta(key, "Plays", 1)
end

--[=[
	Whether community maps can be played and edited in this universe: always in QA,
	in Production only with `Config.PRODUCTION_ENABLED`.
]=]
function CommunityMapService:IsEnabled() : boolean
	return Environment.IsQA() or Config.PRODUCTION_ENABLED == true
end

--[=[
	The entry of a published map, or `nil` and the reason (`InvalidKey`, `NotFound`,
	`Failed`). What the Lobby checks before opening a group and the Game before
	building the map.
]=]
function CommunityMapService:GetListedEntry(key : any) : (Entry?, string?)
	return self:_listedEntry(key)
end

--[=[
	Sends the owner of a map to the Map Editor with that map open
	(`TeleportData.OpenMap`). Only their own maps, and only where the editor exists.
]=]
function CommunityMapService:Edit(player : Player, key : any) : (boolean, string?)
	local info = self.Services.PlayerMapService.ParseKey(key)
	if not info or info.Kind ~= "map" then
		return false, REASONS.InvalidKey
	end
	if info.UserId ~= player.UserId then
		return false, REASONS.NotOwner
	end
	if not self:IsEnabled() or not Environment.HasPlace("MapEditor") then
		return false, REASONS.Disabled
	end

	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ OpenMap = info.Id })

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Environment.GetPlaceId("MapEditor"), { player }, options)
	end)
	if not ok then
		log:Warn(`teleport of {player.Name} to the Map Editor failed: {err}`)
		return false, REASONS.Failed
	end

	return true, nil
end

--[[ PUBLISHING (Map Editor) ]]

--- Whether `mapId` of `player` is published, from their index.
function CommunityMapService:IsPublished(player : Player, mapId : string) : boolean
	local data = self.Services.PlayerMapService:GetData(player)
	local entry = data and data.Maps[mapId]

	return entry ~= nil and entry.Published ~= nil
end

--[=[
	Lists a saved map in the community catalog, or updates its text when it is
	already there. `info` is `{ Name, Description, Count }`; both texts go through
	the text filter. Counters survive an unpublish and a publish again.
]=]
function CommunityMapService:Publish(player : Player, mapId : string, info : { Name : string, Description : string?, Count : number }) : (boolean, string?)
	local PlayerMapService = self.Services.PlayerMapService

	local key = PlayerMapService.MapKey(player.UserId, mapId)
	if not key then
		return false, REASONS.InvalidKey
	end

	local data = PlayerMapService:GetData(player)
	if not data then
		return false, REASONS.NotLoaded
	end
	if not data.Maps[mapId] then
		return false, REASONS.NotSaved
	end

	local name = self:_filter(tostring(info.Name), player.UserId)
	local description = self:_filter(string.sub(trim(tostring(info.Description or "")), 1, Config.MAX_DESCRIPTION_LENGTH), player.UserId)
	if not name or not description then
		return false, REASONS.Filtered
	end

	local now = os.time()
	local ok, entry = self:_update(key, function(old)
		local value = if typeof(old) == "table" then old else {}

		for _, stat in Config.STATS do
			value[stat] = tonumber(value[stat]) or 0
		end

		value.v = ENTRY_VERSION
		value.Owner = player.UserId
		value.OwnerName = player.Name
		value.Id = mapId
		value.Name = name
		value.Description = description
		value.Count = tonumber(info.Count) or 0
		value.Published = if value.Listed then value.Published else now
		value.Updated = now
		value.Listed = true

		return value, { player.UserId }
	end)

	if not ok then
		return false, REASONS.Failed
	end

	for _, stat in Config.STATS do
		self:_setOrdered(stat, key, tonumber(entry[stat]) or 0)
	end

	self:_setCatalog(key, { N = name, O = player.Name })
	self:_forgetEntry(key)

	PlayerMapService:Update(player, function(value)
		local mapEntry = value.Maps[mapId]
		if mapEntry then
			mapEntry.Published = entry.Published
		end
		return value
	end)

	return true, nil
end

--[=[
	Keeps a published map's name and object count in step after the owner saves
	or renames it (`Count` left out keeps the old one). Does nothing for a map that
	is not published. The name was already filtered by the editor when it was given.
]=]
function CommunityMapService:Refresh(player : Player, mapId : string, info : { Name : string, Count : number? })
	if not self:IsPublished(player, mapId) then
		return
	end

	local key = self.Services.PlayerMapService.MapKey(player.UserId, mapId)
	if not key then
		return
	end

	local renamed = false
	local ok, entry = self:_update(key, function(old)
		if typeof(old) ~= "table" or not old.Listed then
			return nil
		end

		renamed = old.Name ~= info.Name
		old.Name = info.Name
		old.Count = tonumber(info.Count) or old.Count
		old.Updated = os.time()

		return old, { player.UserId }
	end)

	if not ok then
		return
	end

	self.MetaCache[key] = { Value = entry, At = os.clock() }

	if renamed then
		self:_setCatalog(key, { N = info.Name, O = player.Name })
	end
end

--[=[
	Takes a map out of the catalog. With `erase`, its entry and counters go too
	(the map itself was deleted); without it they stay for a publish again.
]=]
function CommunityMapService:Unpublish(player : Player, mapId : string, erase : boolean?) : (boolean, string?)
	local PlayerMapService = self.Services.PlayerMapService

	local key = PlayerMapService.MapKey(player.UserId, mapId)
	if not key then
		return false, REASONS.InvalidKey
	end

	for _, stat in Config.STATS do
		self:_removeOrdered(stat, key)
	end

	local ok
	if erase then
		ok = self:_remove(key)
	else
		ok = self:_update(key, function(old)
			if typeof(old) ~= "table" then
				return nil
			end
			old.Listed = false
			return old, { player.UserId }
		end)
	end

	self:_setCatalog(key, nil)
	self:_forgetEntry(key)

	if PlayerMapService:GetData(player) then
		PlayerMapService:Update(player, function(value)
			local mapEntry = value.Maps[mapId]
			if mapEntry then
				mapEntry.Published = nil
			end
			return value
		end)
	end

	if not ok then
		return false, REASONS.Failed
	end

	return true, nil
end

--[[ NETWORK ]]

local ACTIONS = {
	List = function(self, player, payload)
		return self:List(player, payload)
	end,
	Like = function(self, player, payload)
		return self:SetLiked(player, payload.Key, payload.Value == true)
	end,
	Favorite = function(self, player, payload)
		return self:SetFavorite(player, payload.Key, payload.Value == true)
	end,
	Visit = function(self, player, payload)
		return self:Visit(player, payload.Key)
	end,
	Edit = function(self, player, payload)
		return self:Edit(player, payload.Key)
	end,
}

function CommunityMapService:_onRequest(player : Player, requestId : any, action : any, payload : any)
	if typeof(requestId) ~= "number" then
		return
	end

	local function respond(ok : boolean, result : any)
		if player.Parent ~= Players then
			return
		end

		Framework:Fire(RESPONSE_EVENT, player, {
			Id = requestId,
			Ok = ok,
			Data = if ok then result else nil,
			Reason = if ok then nil else result,
		})
	end

	local handler = ACTIONS[action]
	if not handler or typeof(payload) ~= "table" then
		respond(false, REASONS.Invalid)
		return
	end

	local pending = self.Pending[player] or 0
	if pending >= Config.MAX_PENDING_REQUESTS then
		respond(false, REASONS.Busy)
		return
	end

	self.Pending[player] = pending + 1
	local success, ok, result = pcall(handler, self, player, payload)
	if self.Pending[player] then
		self.Pending[player] -= 1
	end

	if not success then
		log:Warn(`{action} from {player.Name} errored: {ok}`)
		respond(false, REASONS.Failed)
		return
	end

	respond(ok, result)
end

--[[ LIFECYCLE ]]

function CommunityMapService:construct()
	task.spawn(function()
		self:_openStores()
	end)

	Framework:Listen(REQUEST_EVENT, function(player : Player, requestId : any, action : any, payload : any)
		self:_onRequest(player, requestId, action, payload)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.Visited[player] = nil
		self.Pending[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(Config.FLUSH_INTERVAL)
			if next(self.Deltas) then
				self:Flush()
			end
		end
	end)

	game:BindToClose(function()
		if next(self.Deltas) then
			self:Flush()
		end
	end)
end

function CommunityMapService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function CommunityMapService:init()
	-- Only the server fires this one: declared here so the client's Listen finds it.
	Framework:Listen(RESPONSE_EVENT, function() end)
end

return CommunityMapService
