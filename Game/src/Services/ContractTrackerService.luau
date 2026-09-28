local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("ContractTrackerService")

local Events = SharedConfig.ContractConfig.Events
local WeatherConfig = SharedConfig.WeatherConfig

--[[
	The match counted for contracts: what happens in the round becomes a `Record` in
	`ContractService`, with the context the filters look at (map, difficulty...).

	This service does not know which contracts the player has. It counts **everything**
	a contract could ask for, and `ContractService` matches events to contracts. A new
	contract that only combines existing events needs no line here.

	  | Event | Comes from |
	  | --- | --- |
	  | `Kill`, `BossKill`, `Stun`, `Damage` | `MobService`'s match scoreboard, read in batches |
	  | `MatchCashSpent`, `MatchCashEarned` | same: the match total, for `Max` |
	  | `WaveReached` | `WaveService.Signals.WaveStarted` |
	  | `Weather` | `WeatherRoundService.Signals.WeatherStarted` |
	  | `Win` | `WaveService.Signals.MatchFinished` |
	  | `MatchTime` | `MatchStatsService.Signals.Closed` |

	**Everything is the player's own.** Kills, damage, and stuns belong to whoever
	owned the unit; the cash is theirs. Only weather and wave belong to the room:
	everyone in the match lived through both.

	**The scoreboard is read, not listened to.** `MobService` only sums (see
	`SessionStats`), and this service sends the difference since the last read every
	`SYNC_INTERVAL`, at match end, and on leave. A signal per hit would be one event
	per damage.

	**A win carries the whole context:** map, difficulty, whether the base ended full,
	whether a friend was in the room, and the classes **every** placed unit had in
	common (the "only Fire units"). A unit sold midway counts: it was used.

	See docs/common/contracts.md.
]]

local SYNC_INTERVAL = 3

local ContractTrackerService = {
	Services = {
		ContractService = {},
		DataService = {},
		MapService = {},
		MatchStatsService = {},
		MobService = {},
		UnitService = {},
		WaveService = {},
		WeatherRoundService = {},
	},

	-- [Player] = { Kills, BossKills, Stuns, Damage }: what was already sent this match.
	Reported = {},

	-- [Player] = { { classes } }: the classes of each unit placed this match.
	Placed = {},

	-- ["lower:higher"] = boolean: friendship between two UserIds, asked once.
	Friends = {},
}

--[[ INTERNAL ]]

function ContractTrackerService:_record(player : Player, event : string, value : number, context)
	local contracts = self.Services.ContractService
	if contracts and value > 0 then
		contracts:Record(player, event, value, context)
	end
end

--- The current match's map and difficulty. Difficulty is nil before the vote.
function ContractTrackerService:_context()
	local mapService = self.Services.MapService
	local waveService = self.Services.WaveService
	local preset = waveService and waveService.Difficulty

	return {
		Map = mapService and mapService.CurrentMapName or nil,
		Difficulty = preset and preset.Name or nil,
	}
end

--[=[
	Sends the scoreboard difference since the last read. `Max` entries go with the
	match total: `ContractService` only keeps it if it beats the best so far.
]=]
function ContractTrackerService:_sync(player : Player)
	local mobService = self.Services.MobService
	if not mobService then return end

	local stats = mobService:GetSessionStats(player.UserId)
	local damage = math.floor(mobService:GetDamageDealt(player.UserId))

	local reported = self.Reported[player]
	if not reported then
		reported = { Kills = 0, BossKills = 0, Stuns = 0, Damage = 0 }
		self.Reported[player] = reported
	end

	local context = self:_context()

	local function send(event : string, field : string, current : number)
		-- A scoreboard lower than what was sent means it reset underneath (a new match).
		local last = reported[field]
		if current < last then
			last = 0
		end

		self:_record(player, event, current - last, context)
		reported[field] = current
	end

	send(Events.Kill, "Kills", stats.Kills)
	send(Events.BossKill, "BossKills", stats.BossKills)
	send(Events.Stun, "Stuns", stats.Stuns)
	send(Events.Damage, "Damage", damage)

	self:_record(player, Events.MatchCashSpent, math.floor(stats.Spent), context)
	self:_record(player, Events.MatchCashEarned, math.floor(stats.Earned), context)
end

function ContractTrackerService:_syncAll()
	for _, player in Players:GetPlayers() do
		self:_sync(player)
	end
end

--- Resets what belongs to the match: the scoreboard already sent and the placed units.
function ContractTrackerService:_resetMatch()
	table.clear(self.Reported)
	table.clear(self.Placed)
end

--- The classes all units placed by the player have in common.
function ContractTrackerService:_commonClasses(player : Player) : { [string] : boolean }
	local placed = self.Placed[player]
	if not placed or #placed == 0 then
		return {}
	end

	local common = nil

	for _, classes in placed do
		local set = {}
		for _, class in classes do
			set[class] = true
		end

		if common == nil then
			common = set
		else
			for class in common do
				if not set[class] then
					common[class] = nil
				end
			end
		end
	end

	return common or {}
end

--[=[
	Whether the two are friends on Roblox. Asks once per pair and caches; the query
	yields, so the caller is on its own thread.
]=]
function ContractTrackerService:_areFriends(a : Player, b : Player) : boolean
	local low, high = math.min(a.UserId, b.UserId), math.max(a.UserId, b.UserId)
	local key = low .. ":" .. high

	local cached = self.Friends[key]
	if cached ~= nil then
		return cached
	end

	local ok, result = pcall(a.IsFriendsWith, a, b.UserId)
	if not ok then
		return false
	end

	self.Friends[key] = result == true
	return result == true
end

function ContractTrackerService:_hasFriendHere(player : Player) : boolean
	for _, other in Players:GetPlayers() do
		if other ~= player and self:_areFriends(player, other) then
			return true
		end
	end

	return false
end

--[=[
	The match end: the whole scoreboard goes and, on a win, the win with its context.

	Base health is read here, not inside the thread: the friendship query yields, and
	during it the round may have restarted with the base full again.
]=]
function ContractTrackerService:_onMatchFinished(won : boolean, preset)
	self:_syncAll()

	local contracts = self.Services.ContractService

	if not won then
		for _, player in Players:GetPlayers() do
			contracts:Flush(player)
		end

		return
	end

	local mobService = self.Services.MobService
	local fullHealth = mobService ~= nil
		and (mobService.MaxBaseHealth or 0) > 0
		and (mobService.BaseHealth or 0) >= mobService.MaxBaseHealth

	local base = self:_context()
	local difficulty = (preset and preset.Name) or base.Difficulty

	for _, player in Players:GetPlayers() do
		local commonClasses = self:_commonClasses(player)

		task.spawn(function()
			local withFriends = self:_hasFriendHere(player)

			if not player.Parent then return end

			self:_record(player, Events.Win, 1, {
				Map = base.Map,
				Difficulty = difficulty,
				FullHealth = fullHealth,
				WithFriends = withFriends,
				CommonClasses = commonClasses,
			})

			contracts:Flush(player)
		end)
	end
end

--[[ LIFECYCLE ]]

function ContractTrackerService:construct()
	local waveService = self.Services.WaveService
	local unitService = self.Services.UnitService
	local weatherService = self.Services.WeatherRoundService
	local matchStats = self.Services.MatchStatsService
	local dataService = self.Services.DataService

	if not waveService or not self.Services.ContractService then
		log:Warn("no WaveService or ContractService; the match does not count toward contracts.")
		return
	end

	waveService.Signals.RoundStarted:Connect(function()
		self:_resetMatch()
	end)

	-- Reset mid-round or at round end: what the match did so far goes before
	-- `MobService`'s scoreboard resets.
	waveService.Signals.RoundClosed:Connect(function()
		self:_syncAll()
		self:_resetMatch()
	end)

	waveService.Signals.MatchFinished:Connect(function(won : boolean, preset)
		self:_onMatchFinished(won, preset)
	end)

	waveService.Signals.WaveStarted:Connect(function(waveNumber : number, preset)
		local context = self:_context()
		context.Difficulty = (preset and preset.Name) or context.Difficulty

		for _, player in Players:GetPlayers() do
			self:_record(player, Events.WaveReached, waveNumber, context)
		end
	end)

	if weatherService and weatherService.Signals then
		weatherService.Signals.WeatherStarted:Connect(function()
			local context = self:_context()

			for _, player in Players:GetPlayers() do
				self:_record(player, Events.Weather, 1, context)
			end
		end)
	end

	if unitService and unitService.Signals then
		unitService.Signals.UnitPlaced:Connect(function(player : Player, unitName : string)
			local placed = self.Placed[player]
			if not placed then
				placed = {}
				self.Placed[player] = placed
			end

			table.insert(placed, WeatherConfig.GetClasses(unitName))
		end)
	end

	if matchStats and matchStats.Signals then
		matchStats.Signals.Closed:Connect(function(player : Player, seconds : number)
			self:_record(player, Events.MatchTime, seconds, self:_context())
		end)
	end

	-- The last read for a player leaving, with the profile open and before
	-- `ContractService` writes its queue (it registers later, with a higher order).
	if dataService and dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:_sync(player)
			self.Reported[player] = nil
			self.Placed[player] = nil
		end)
	end

	-- Friendship is asked on join, not at match end: the query yields, and at win
	-- time the answer is already cached.
	Players.PlayerAdded:Connect(function(player : Player)
		for _, other in Players:GetPlayers() do
			if other ~= player then
				task.spawn(function()
					self:_areFriends(player, other)
				end)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.Reported[player] = nil
			self.Placed[player] = nil
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(SYNC_INTERVAL)

			if waveService:IsRoundRunning() then
				self:_syncAll()
			end
		end
	end)
end

function ContractTrackerService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function ContractTrackerService:init()
end

return ContractTrackerService
