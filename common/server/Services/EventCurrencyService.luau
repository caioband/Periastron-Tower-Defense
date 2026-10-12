local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local SharedConfig = require(Configs:WaitForChild("SharedConfig"))
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("EventCurrencyService")

local Config = SharedConfig.EventCurrencyConfig
local STAT = Config.StatKey
local SEASON = Config.SeasonKey

--[[
	The event currency: `Stats.EventCurrency`, tagged with the season it was earned in
	(`Stats.EventSeason`).

	**Wiping.** Bump `SharedConfig.EventCurrencyConfig.Season` and publish. Every profile
	whose `EventSeason` is lower gets its balance set to 0 the next time it loads, and
	before any write lands on it. A profile with a season equal to or higher than this
	server's is left alone, so an old server still running the previous number can never
	wipe someone a new server already moved forward.

	The keys are not in `Config.Data.Template` on purpose: this service creates them on
	load, so nothing else in the data layer had to change.
]]

local EventCurrencyService = {
	Services = {
		DataService = {},
	},
	Signals = {
		-- (player, previous, updated, reason)
		Changed = Signal.new(),
	},
}

--[[ INTERNAL ]]

local function cleanAmount(amount : any) : number?
	if typeof(amount) ~= "number" or amount ~= amount or amount == math.huge or amount == -math.huge then
		return nil
	end

	return math.max(math.floor(amount), 0)
end

local function applyAction(action : string, current : number, amount : number) : number
	if action == "set" then
		return amount
	elseif action == "remove" then
		return math.max(current - amount, 0)
	end

	return current + amount
end

-- Brings a Stats table up to this server's season. Returns true if it changed anything.
local function syncSeason(stats : { [string] : any }) : boolean
	local changed = false

	if typeof(stats[STAT]) ~= "number" then
		stats[STAT] = 0
		changed = true
	end

	local season = tonumber(stats[SEASON]) or 0
	if season < Config.Season then
		stats[STAT] = 0
		stats[SEASON] = Config.Season
		changed = true
	end

	return changed
end

function EventCurrencyService:_getStats(player : Player) : { [string] : any }?
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	local stats = entry and entry.Profile.Data.Stats

	return if typeof(stats) == "table" then stats else nil
end

function EventCurrencyService:_sync(player : Player)
	local stats = self:_getStats(player)
	if not stats then
		return
	end

	local season = tonumber(stats[SEASON]) or 0
	if typeof(stats[STAT]) == "number" and season >= Config.Season then
		return
	end

	local wiped = season < Config.Season and (tonumber(stats[STAT]) or 0) > 0

	self.Services.DataService:Update(player, "Stats", function(current)
		current = current or {}
		syncSeason(current)
		return current
	end)

	if wiped then
		log:Info(`wiped {player.Name}'s event currency (season {season} -> {Config.Season}).`)
	end
end

--[[ API ]]

--[=[
	The current balance, or nil if the profile has not loaded.
]=]
function EventCurrencyService:Peek(player : Player) : number?
	local stats = self:_getStats(player)
	if not stats then
		return nil
	end

	if (tonumber(stats[SEASON]) or 0) < Config.Season then
		return 0
	end

	return tonumber(stats[STAT]) or 0
end

function EventCurrencyService:CanAfford(player : Player, amount : number) : boolean
	local balance = self:Peek(player)
	local cost = cleanAmount(amount)

	return balance ~= nil and cost ~= nil and balance >= cost
end

--[=[
	`set`, `add` or `remove`, ignoring `Enabled`. Returns `(previous, new)` or
	`nil, nil, reason`. The season check runs inside the same write, so a value never
	lands on a stale season.
]=]
function EventCurrencyService:Apply(player : Player, action : string, amount : number, reason : string?) : (number?, number?, string?)
	if action ~= "set" and action ~= "add" and action ~= "remove" then
		return nil, nil, `unknown action '{tostring(action)}'.`
	end

	local clean = cleanAmount(amount)
	if not clean then
		return nil, nil, "amount must be a number."
	end

	if not self:_getStats(player) then
		return nil, nil, `{player.Name}'s profile has not loaded yet.`
	end

	local previous, updated = 0, 0

	self.Services.DataService:Update(player, "Stats", function(stats)
		stats = stats or {}
		syncSeason(stats)

		previous = stats[STAT]
		updated = applyAction(action, previous, clean)
		stats[STAT] = updated

		return stats
	end)

	if previous ~= updated then
		self.Signals.Changed:Fire(player, previous, updated, reason)
	end

	return previous, updated, nil
end

--[=[
	Gives event currency. Refused while the event is off (`Enabled = false`).
]=]
function EventCurrencyService:Add(player : Player, amount : number, reason : string?) : (number?, number?, string?)
	if not Config.Enabled then
		return nil, nil, "the event is not active."
	end

	return self:Apply(player, "add", amount, reason)
end

function EventCurrencyService:Remove(player : Player, amount : number, reason : string?) : (number?, number?, string?)
	return self:Apply(player, "remove", amount, reason)
end

--[=[
	Takes `amount` only if the player has all of it. Check and charge happen in one
	write, so two purchases at once cannot both pass. Returns `(ok, balance)`.
]=]
function EventCurrencyService:Spend(player : Player, amount : number, reason : string?) : (boolean, number?)
	local cost = cleanAmount(amount)
	if not cost or not self:_getStats(player) then
		return false, nil
	end

	local ok, previous, updated = false, 0, 0

	self.Services.DataService:Update(player, "Stats", function(stats)
		stats = stats or {}
		syncSeason(stats)

		previous = stats[STAT]
		if previous >= cost then
			stats[STAT] = previous - cost
			ok = true
		end
		updated = stats[STAT]

		return stats
	end)

	if ok and previous ~= updated then
		self.Signals.Changed:Fire(player, previous, updated, reason)
	end

	return ok, updated
end

--[[ LIFECYCLE ]]

function EventCurrencyService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; event currency will not sync.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_sync(player)
	end)

	for _, player in Players:GetPlayers() do
		self:_sync(player)
	end
end

function EventCurrencyService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function EventCurrencyService:init()
end

return EventCurrencyService
