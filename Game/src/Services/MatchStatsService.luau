local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("MatchStatsService")

local MIN_MATCH_SECONDS = ServerConfig.Data.MIN_MATCH_SECONDS

--[[
	`Stats.MatchesPlayed` and `Stats.TimeInMatches`: how long each player spends inside
	a round, and how many matches went past `MIN_MATCH_SECONDS`.

	"Inside a round" is `WaveService` in `Running`: from waiting for players and the
	difficulty vote to the last wave. The results screen and the idle intermission in
	`Idle` do not count. Time is real time (`os.clock`), not `GameClock`: speeding up
	the match does not shorten the time the player spent in it.

	Each player has their own clock (`JoinedAt`), which opens when the round starts
	or when they join a running round, and closes in one of two places:

	  - the round closed (`WaveService.Signals.RoundClosed`): match end or reset;
	  - they left, or the server shut down (`DataService:OnBeforeRelease`, with the
	    profile still open).

	Closing means writing: the whole time goes to `TimeInMatches`, and if it passed the
	floor the match enters `MatchesPlayed`. A match only counts once per player,
	because closing removes their clock: a player who leaves and returns to the same
	round starts a new clock, and only counts again after another
	`MIN_MATCH_SECONDS`.
]]
local MatchStatsService = {
	Services = {
		DataService = {},
		WaveService = {},
	},

	-- [Player] = `os.clock()` from when they joined the running round.
	JoinedAt = {},

	Signals = {
		--[[
			(player, seconds): the player's clock closed, with the time they spent in that
			round. Fires before the profile closes, on leave too. `ContractTrackerService`
			listens ("Play 7 hours worth of matches").
		]]
		Closed = Signal.new(),
	},
}

--[[ INTERNAL ]]

function MatchStatsService:_open(player : Player)
	if self.JoinedAt[player] == nil then
		self.JoinedAt[player] = os.clock()
	end
end

--- Closes the player's clock and writes what it was worth.
function MatchStatsService:_close(player : Player)
	local joinedAt = self.JoinedAt[player]
	if not joinedAt then return end

	self.JoinedAt[player] = nil

	local seconds = math.floor(os.clock() - joinedAt)
	if seconds <= 0 then return end

	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	if not (profiles and profiles[player]) then return end

	self.Signals.Closed:Fire(player, seconds)

	-- Time and matches on a community map stay off the leaderboards.
	local mapService = Framework:Get("MapService")
	if mapService and mapService.IsCommunityMatch and mapService:IsCommunityMatch() then
		return
	end

	dataService:Update(player, "Stats", function(stats)
		stats.TimeInMatches = (tonumber(stats.TimeInMatches) or 0) + seconds

		if seconds >= MIN_MATCH_SECONDS then
			stats.MatchesPlayed = (tonumber(stats.MatchesPlayed) or 0) + 1
		end

		return stats
	end)
end

function MatchStatsService:_openAll()
	for _, player in Players:GetPlayers() do
		self:_open(player)
	end
end

function MatchStatsService:_closeAll()
	for player in self.JoinedAt do
		self:_close(player)
	end
end

--[[ LIFECYCLE ]]

function MatchStatsService:construct()
	local waveService = self.Services.WaveService
	local dataService = self.Services.DataService

	if not waveService then
		log:Warn("no WaveService; matches and match time will not be counted.")
		return
	end

	waveService.Signals.RoundStarted:Connect(function()
		self:_openAll()
	end)

	waveService.Signals.RoundClosed:Connect(function()
		self:_closeAll()
	end)

	Players.PlayerAdded:Connect(function(player : Player)
		if waveService:IsRoundRunning() then
			self:_open(player)
		end
	end)

	if dataService and dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:_close(player)
		end)
	end

	-- Cleanup for players who left without an open profile (the hook above does not even run).
	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.JoinedAt[player] = nil
		end)
	end)

	-- The first round starts in WaveService's `start`, which may have run before this
	-- one: its `RoundStarted` already fired.
	if waveService:IsRoundRunning() then
		self:_openAll()
	end
end

function MatchStatsService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function MatchStatsService:init()
end

return MatchStatsService
