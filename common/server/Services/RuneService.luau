local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("RuneService")

local RuneConfig = SharedConfig.RuneConfig

--[[
	Active runes (`Data.Runes`): their clock and their bonus, in every place.

	**The clock only runs while the profile is open here.** The profile keeps the
	seconds left; this service subtracts the time since its last write every
	`FLUSH_INTERVAL` and when the profile closes, and drops a rune that reaches
	zero. Time offline and time spent teleporting between places is never
	subtracted. Between two writes, `GetEntry` and `GetBonus` read the live value
	(saved minus elapsed), so a rune stops counting the second it runs out, not at
	the next write.

	The client counts down on its own from the last write it received (see
	`RuneShopController`), so the shop's timer does not need a write per second.

	**A match keeps the best bonus it saw** (`Lock`): `WaveService` locks each
	player's runes when the round starts and when a player loads into a running
	round, and `GetBonus` never returns less than the lock until `Unlock`. A rune
	that runs out on Nightmare's wave 34 still pays the end of that match.

	Selling runes is the Lobby's `RuneShopService`; this service only grants them.

	See docs/common/runes.md.
]]

-- Seconds between writes of the time spent. Short enough that a crash loses
-- little; each write replicates only this player's `Runes`, and only when they
-- have one.
local FLUSH_INTERVAL = 30

local RuneService = {
	Services = {
		DataService = {},
	},

	-- [Player] = `os.clock()` of the last second already subtracted.
	Since = {},

	-- [Player] = { [Id] = bonus }: the floor `Lock` set for the current match.
	Locks = {},
}

--[[ INTERNAL ]]

function RuneService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--- Seconds of play not yet subtracted from the profile.
function RuneService:_elapsed(player : Player) : number
	local since = self.Since[player]
	return if since then os.clock() - since else 0
end

function RuneService:_track(player : Player)
	if self.Since[player] == nil then
		self.Since[player] = os.clock()
	end
end

function RuneService:_forget(player : Player)
	self.Since[player] = nil
	self.Locks[player] = nil
end

--[=[
	Subtracts the whole seconds played since the last write, and runs `mutate` on the
	settled table in the **same** `Update`: a purchase sees the real time left, and
	nothing yields between reading and writing.

	Without `mutate` and without an active rune it writes nothing (only the clock
	moves on), so players without runes never replicate a thing.
]=]
function RuneService:_write(player : Player, mutate : ((runes : { [string] : any }) -> ())?) : boolean
	local profile = self:_profileOf(player)
	if not profile then
		return false
	end

	local seconds = 0
	local since = self.Since[player]

	if since then
		seconds = math.max(math.floor(os.clock() - since), 0)
		self.Since[player] = since + seconds
	end

	local saved = profile.Runes
	local hasRunes = typeof(saved) == "table" and next(saved) ~= nil

	if not mutate and (seconds <= 0 or not hasRunes) then
		return false
	end

	self.Services.DataService:Update(player, "Runes", function(runes)
		runes = typeof(runes) == "table" and runes or {}

		for id in runes do
			local entry = RuneConfig.entryOf(runes, id)

			if entry and entry.Remaining - seconds > 0 then
				runes[id].Remaining = entry.Remaining - seconds
			else
				-- Ran out, or no longer in the config.
				runes[id] = nil
			end
		end

		if mutate then
			mutate(runes)
		end

		return runes
	end)

	return true
end

--[[ API ]]

--[=[
	The rune's live record, `{ Tier, Remaining }`, with the seconds played since the
	last write already taken off. Nil when it is not active.
]=]
function RuneService:GetEntry(player : Player, id : string) : { Tier : number, Remaining : number }?
	local profile = self:_profileOf(player)
	local entry = RuneConfig.entryOf(profile and profile.Runes, id)

	if not entry then
		return nil
	end

	entry.Remaining -= self:_elapsed(player)

	return if entry.Remaining > 0 then entry else nil
end

--- The bonus a rune gives this player now (0.2 is +20%), never less than the match's lock.
function RuneService:GetBonus(player : Player, id : string) : number
	local entry = self:GetEntry(player, id)
	local tier = entry and RuneConfig.getTier(id, entry.Tier)
	local bonus = if tier then tier.Bonus else 0

	local locks = self.Locks[player]
	local locked = locks and locks[id] or 0

	return math.max(bonus, locked)
end

--- `1 + GetBonus`: what a reward is multiplied by.
function RuneService:GetMultiplier(player : Player, id : string) : number
	return 1 + self:GetBonus(player, id)
end

--[=[
	Keeps the player's current bonuses as a floor until `Unlock`: the match a rune
	was active in pays the whole match with it. Locking again keeps the higher of
	the two.
]=]
function RuneService:Lock(player : Player)
	local locks = self.Locks[player] or {}

	for _, rune in RuneConfig.Runes do
		locks[rune.Id] = math.max(locks[rune.Id] or 0, self:GetBonus(player, rune.Id))
	end

	self.Locks[player] = locks
end

function RuneService:Unlock(player : Player)
	self.Locks[player] = nil
end

function RuneService:UnlockAll()
	table.clear(self.Locks)
end

--[=[
	Grants a rune by the rules in `RuneConfig.purchaseAction`: the same tier extends,
	a higher one replaces, a lower one is refused. **Charges nothing**: that is the
	shop's job, which refunds when this returns false.

	`seconds` overrides `DURATION` (the `rune` admin command, to test expiry).

	Returns true and the action (`"New"`, `"Extend"`, `"Upgrade"`), or false and the
	reason (`"UnknownRune"`, `"NotLoaded"`, `"LowerTier"`).
]=]
function RuneService:Grant(player : Player, id : string, tier : number, seconds : number?) : (boolean, string?)
	if not RuneConfig.getTier(id, tier) then
		return false, "UnknownRune"
	end

	local duration = seconds or RuneConfig.DURATION
	local action, reason = nil, nil

	local wrote = self:_write(player, function(runes)
		local active = RuneConfig.entryOf(runes, id)

		action, reason = RuneConfig.purchaseAction(active, tier)

		if action == "Extend" and active then
			runes[id].Remaining = active.Remaining + duration
		elseif action then
			runes[id] = { Tier = tier, Remaining = duration }
		end
	end)

	if not wrote then
		return false, "NotLoaded"
	end

	if not action then
		return false, reason
	end

	return true, action
end

--[=[
	Removes one rune, or every rune when `id` is nil. For the admin commands.

	The match lock goes too: a rune cleared mid-match no longer pays that match, so
	what the tester sees at the end matches what they cleared.
]=]
function RuneService:Clear(player : Player, id : string?) : boolean
	local locks = self.Locks[player]
	if locks and id then
		locks[id] = nil
	else
		self.Locks[player] = nil
	end

	return self:_write(player, function(runes)
		if id then
			runes[id] = nil
		else
			table.clear(runes)
		end
	end)
end

--[[ LIFECYCLE ]]

function RuneService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; rune time will not run out.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_track(player)
	end)

	-- Players who loaded before this service started: their signal already fired.
	for _, player in Players:GetPlayers() do
		if self:_profileOf(player) then
			self:_track(player)
		end
	end

	--[[
		The last chunk goes in with the profile still open. Order 1, after the order-0
		hooks: `WaveService`'s leave reward reads `GetBonus` and must still find the
		match's lock.
	]]
	dataService:OnBeforeRelease(function(player : Player)
		self:_write(player)
		self:_forget(player)
	end, 1)

	-- Cleanup for players who left without an open profile (the hook above does not run).
	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self:_forget(player)
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)

			for player in self.Since do
				self:_write(player)
			end
		end
	end)
end

function RuneService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function RuneService:init()
end

return RuneService
