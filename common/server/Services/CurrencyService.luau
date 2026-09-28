local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("CurrencyService")

--[[
	Changes a player's saved currencies: `Stats.Cash` and `Stats.Shards`.

	It writes currency to a player **on this server** (`Apply`): this is how
	`RobuxShopService` credits coin packs. It also reads (`Peek`) and seeds
	`Stats.CoinsEarned`.

	Cmdr's `cash` and `shards` commands do not go through here: they reach players
	off the server, and `ProfileEditService` writes for them. **Do not delete `Apply`
	thinking it was only for the commands**: without it the pack callback errors,
	the receipt comes back as `NotProcessedYet`, and nobody gets the coins.

	This is not match money. That belongs to `MobService.SessionCash`, lives only
	while the round lasts, and never reaches the profile; `roundcash` changes it, and
	lives in Game next to the service that owns it.

	It lives in `common/` because both places have an open profile: the player can
	be in the Lobby or mid-match when the command runs.

	See docs/common/data-and-profiles.md.
]]

local CurrencyService = {
	Services = {
		DataService = {}
	}
}

-- The `Data.Stats` keys this service accepts changing. Writing a key the template
-- lacks would create a ghost field in the profile that nobody reads.
CurrencyService.Stats = {
	Cash = "Cash",
	Shards = "Shards",
}

--[[ INTERNAL ]]

--[=[
	The value after the operation. Never negative: a negative balance exists nowhere
	in the game, and an oversized `remove` is a typo, not a request to owe.
]=]
local function applyAction(action : string, current : number, amount : number) : number
	if action == "set" then
		return math.max(amount, 0)
	elseif action == "remove" then
		return math.max(current - amount, 0)
	end

	return math.max(current + amount, 0)
end

--[=[
	Creates `Stats.CoinsEarned` (total coins earned, for MOST COINS) on a profile
	that lacks it, starting from the current balance.

	The balance is the minimum the player has earned, so it is the best starting
	point for someone who played before the key existed: better than zero, which
	would put them behind a newcomer. A new profile has a zero balance and starts at
	zero.

	That is why the key is not in the template (see `Config.Data`): reconcile would
	create it at zero before this service saw it was missing. It runs once per
	profile, and only while the key does not exist.
]=]
function CurrencyService:_seedCoinsEarned(player : Player)
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	local stats = entry and entry.Profile.Data.Stats

	if typeof(stats) ~= "table" or stats.CoinsEarned ~= nil then
		return
	end

	dataService:Update(player, "Stats", function(current)
		if current.CoinsEarned == nil then
			current.CoinsEarned = math.max(0, math.floor(tonumber(current.Cash) or 0))
		end

		return current
	end)
end

--[[ API ]]

--[=[
	Reads a currency from the open profile, or `nil` if the profile has not loaded yet.
]=]
function CurrencyService:Peek(player : Player, stat : string) : number?
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	if not entry then
		return nil
	end

	local stats = entry.Profile.Data.Stats

	return (stats and stats[stat]) or 0
end

--[=[
	Applies `set`, `add`, or `remove` to a currency and returns `(previous, new)`, or
	`nil` plus the reason.

	The read and the write happen inside the same `Update`, not around it: that is
	what guarantees `add` sums on top of the value there now, not the one there when
	the command was typed.
]=]
function CurrencyService:Apply(player : Player, stat : string, action : string, amount : number) : (number?, number?, string?)
	if not self.Stats[stat] then
		return nil, nil, string.format("'%s' is not a known currency.", tostring(stat))
	end

	local dataService = self.Services.DataService
	if not dataService then
		return nil, nil, "DataService unavailable."
	end

	if not (dataService.Profiles and dataService.Profiles[player]) then
		return nil, nil, string.format("%s's profile has not loaded yet.", player.Name)
	end

	local previous, updated = 0, 0

	dataService:Update(player, "Stats", function(stats)
		stats = stats or {}

		previous = stats[stat] or 0
		updated = applyAction(action, previous, amount)
		stats[stat] = updated

		return stats
	end)

	return previous, updated, nil
end

--[[ LIFECYCLE ]]

function CurrencyService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; CoinsEarned will not be backfilled on old profiles.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_seedCoinsEarned(player)
	end)

	-- Players who loaded before this service started: their signal already fired.
	for _, player in Players:GetPlayers() do
		self:_seedCoinsEarned(player)
	end
end

function CurrencyService:start()
	-- With a wait: `construct` now listens to `PlayerDataLoaded`, and a DataService
	-- that has not started yet would leave an older profile without `CoinsEarned`.
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function CurrencyService:init()
end

return CurrencyService
