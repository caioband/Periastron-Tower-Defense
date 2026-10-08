local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local IndexConfig = SharedConfig.IndexConfig

local Framework = Me.new()
local log = Log.new("IndexService")

--[[
	The player's Index: the writer.

	The structure and rules are in `SharedConfig.IndexConfig`; this is only the write
	door, and there is a single one for both places. Each trigger calls from where
	the information exists:

	  - unit obtained   -> `CrateService` and `SummoningService` (Lobby)
	  - map entered     -> `MapService` (Game), which knows which map loaded
	  - enemy spawned   -> `MobService` (Game), for every player in the match
	  - weather started -> `WeatherRoundService` (Game), on `WeatherStarted`

	It also writes `IndexSeen`, the keys the player clicked in the Lobby's Index UI
	(`IndexSeen` event, from `IndexController`). The client only names the key: a
	key the player has not discovered is refused, so a forged click can light
	nothing and clear nothing that matters.

	**Discovery is forever.** Nothing here deletes: a sold unit stays discovered,
	because the Index is a memory of what the player has seen, not an inventory.

	**A pre-existing profile counts too.** When the profile loads, the units the
	player already owns enter the Index at once (`_syncOwnedUnits`). Without that,
	someone who played before the Index existed would start with an empty catalog
	while holding a full deck, and each of their units would only enter the day they
	pulled another copy from a crate.
]]
local IndexService = {
	Services = {
		DataService = {},
	},
}

--[[ INTERNAL ]]

--- The player's open profile, or nil while it has not loaded.
function IndexService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[=[
	Writes a category's new keys in a single pass.

	One write per key would cost one replication per key, and the normal
	`_syncOwnedUnits` case is exactly a handful at once. Returns how many were new:
	zero means nothing was written and nothing was replicated.
]=]
function IndexService:_unlock(player : Player, category : string, keys : { string }) : number
	-- Only what the Index can show: a key with no page (the tutorial map) would be a
	-- "new" nobody can ever click. See `IndexConfig.isKnown`.
	return self:_write(player, IndexConfig.DISCOVERED_KEY, category, keys, function(profile, key)
		return IndexConfig.isKnown(category, key) and not IndexConfig.has(profile, category, key)
	end)
end

--[=[
	Adds keys to `profile[root][category]`, only those `accepts` lets through, in a
	single `Update`. Shared by discovery (`Index`) and clicks (`IndexSeen`), which
	have the same shape and differ only in which keys are worth writing.
]=]
function IndexService:_write(player : Player, root : string, category : string, keys : { string }, accepts : (any, string) -> boolean) : number
	if not IndexConfig.isCategory(category) then
		log:StudioWarn(string.format("%q is not an Index category.", tostring(category)))
		return 0
	end

	local dataService = self.Services.DataService
	if not dataService or not dataService.Update then
		log:Warn("DataService is not ready; discovery dropped.")
		return 0
	end

	local profile = self:_profileOf(player)
	if not profile then
		return 0
	end

	-- Filter before writing: `Update` replicates the whole key, so rewriting what
	-- was already there sends a replication to say nothing.
	local pending = {}
	for _, key in keys do
		if typeof(key) == "string" and key ~= "" and accepts(profile, key) and not table.find(pending, key) then
			table.insert(pending, key)
		end
	end

	if #pending == 0 then
		return 0
	end

	dataService:Update(player, root, function(index)
		index = typeof(index) == "table" and index or IndexConfig.createEmpty()

		local entries = index[category]
		if typeof(entries) ~= "table" then
			entries = {}
			index[category] = entries
		end

		for _, key in pending do
			entries[key] = true
		end

		return index
	end)

	return #pending
end

--[=[
	The units the player already owns enter the Index when the profile loads.

	Only real copies count (`amount > 0`): a zeroed entry is a unit they had and no
	longer have, and it would already have been discovered the day they got it.
]=]
function IndexService:_syncOwnedUnits(player : Player)
	local profile = self:_profileOf(player)
	local units = profile and profile.Units

	if typeof(units) ~= "table" then return end

	local owned = {}
	for unitName, amount in units do
		if typeof(unitName) == "string" and (tonumber(amount) or 0) > 0 then
			table.insert(owned, unitName)
		end
	end

	self:_unlock(player, "Units", owned)
end

--[[ API ]]

--[=[
	Discovers a key in a category. Returns `true` only when it was new: that return
	is how a "new in the index!" on screen knows it has something to announce.
]=]
function IndexService:Unlock(player : Player, category : string, key : string) : boolean
	return self:_unlock(player, category, { key }) > 0
end

--- Several keys at once, in a single write. Returns how many were new.
function IndexService:UnlockMany(player : Player, category : string, keys : { string }) : number
	return self:_unlock(player, category, keys)
end

--- The obtained unit entered the player's catalog.
function IndexService:UnlockUnit(player : Player, unitName : string) : boolean
	return self:Unlock(player, "Units", unitName)
end

--- The map the player just played entered their catalog.
function IndexService:UnlockMap(player : Player, mapName : string) : boolean
	return self:Unlock(player, "Maps", mapName)
end

--- An enemy (its `Mob.Entities` key) spawned in the player's match.
function IndexService:UnlockEnemy(player : Player, entityName : string) : boolean
	return self:Unlock(player, "Enemies", entityName)
end

--- A weather (its `Assets.Weathers` name) went live in the player's match.
function IndexService:UnlockWeather(player : Player, weatherName : string) : boolean
	return self:Unlock(player, "Weathers", weatherName)
end

--[=[
	The player clicked the key in the Index UI: it stops being "new". Only a key
	already discovered and not seen yet is written. Returns whether it was written.
]=]
function IndexService:MarkSeen(player : Player, category : string, key : string) : boolean
	return self:_write(player, IndexConfig.SEEN_KEY, category, { key }, function(profile, candidate)
		return IndexConfig.isNew(profile, category, candidate)
	end) > 0
end

--- Whether the player already discovered this key.
function IndexService:Has(player : Player, category : string, key : string) : boolean
	return IndexConfig.has(self:_profileOf(player), category, key)
end

--[[ LIFECYCLE ]]

function IndexService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; the Index will not be written.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_syncOwnedUnits(player)
	end)

	-- The Index UI's click. Everything that arrives is checked in `MarkSeen`.
	Framework:Listen("IndexSeen", function(player : Player, category : any, key : any)
		if typeof(category) ~= "string" or typeof(key) ~= "string" then return end

		self:MarkSeen(player, category, key)
	end)

	-- Players already in when this service started: their signal already fired.
	for _, player in Players:GetPlayers() do
		if self:_profileOf(player) then
			self:_syncOwnedUnits(player)
		end
	end
end

function IndexService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function IndexService:init()
end

return IndexService
