local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("PlaytimeService")

local AfkConfig = SharedConfig.AfkConfig

--[[
	Playtime on the profile (`Stats.TimePlayed`, in seconds), in the Lobby and the
	Game.

	It counts from profile load until the session closes; before that there is
	nowhere to write, and the difference is seconds. Teleporting between Lobby and
	Game closes the session in one place and opens it in the other, so time in both
	adds to the same number.

	**Why it writes every minute and not only on leave.** The leaderboard reads the
	profiles of players on the server; saving only on leave, someone who stays hours
	in the Lobby would not move on it until they left. And a server that crashes
	loses at most the last minute.

	The fractional remainder is not lost: `Since` advances only by the whole seconds
	written, and the fraction goes into the next minute.

	**The AFK place does not count.** Time there goes to its own counter,
	`Stats.TimeInAfkArea` (`AfkAreaService`), and stays out of MOST TIME PLAYED;
	here the service does nothing.

	**AFK time does not count** where `AfkConfig.PausePlaytime` says so (the Lobby).
	When `AfkService` reports the player AFK, `PausedAt` freezes the clock; when
	they come back, `Since` moves forward by the time spent away. Nothing is written
	on the switch itself, so toggling AFK does not touch the profile.

	See docs/common/leaderboards.md and docs/common/afk.md.
]]

local FLUSH_INTERVAL = 60

local PlaytimeService = {
	Services = {
		DataService = {},
		AfkService = {},
	},

	-- [Player] = `os.clock()` of the last second already written.
	Since = {},

	-- [Player] = `os.clock()` when the player went AFK, while the clock is paused.
	PausedAt = {},
}

-- The place comes from the `Place` attribute each Rojo project sets on `Services`,
-- not from `PlaceId`, so QA copies of a place behave like the place itself.
local PLACE_NAME = ServerScriptService:WaitForChild("Services"):GetAttribute("Place")
local COUNTS_HERE = PLACE_NAME ~= "Afk"
local PAUSES_WHEN_AFK = AfkConfig.PausePlaytime[PLACE_NAME] == true

--[[ INTERNAL ]]

function PlaytimeService:_hasProfile(player : Player) : boolean
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles

	return profiles ~= nil and profiles[player] ~= nil
end

function PlaytimeService:_isAfk(player : Player) : boolean
	local afkService = self.Services.AfkService
	return afkService ~= nil and afkService:IsAfk(player)
end

function PlaytimeService:_track(player : Player)
	if self.Since[player] ~= nil then return end

	local now = os.clock()
	self.Since[player] = now

	-- Went AFK before the profile loaded.
	if PAUSES_WHEN_AFK and self:_isAfk(player) then
		self.PausedAt[player] = now
	end
end

--- Freezes or resumes the clock. Untracked players are handled by `_track`.
function PlaytimeService:_setPaused(player : Player, paused : boolean)
	local since = self.Since[player]
	if not since then return end

	local pausedAt = self.PausedAt[player]

	if paused and not pausedAt then
		self.PausedAt[player] = os.clock()
	elseif not paused and pausedAt then
		self.Since[player] = since + (os.clock() - pausedAt)
		self.PausedAt[player] = nil
	end
end

function PlaytimeService:_forget(player : Player)
	self.Since[player] = nil
	self.PausedAt[player] = nil
end

--- Writes the whole seconds since the last write to the profile.
function PlaytimeService:_flush(player : Player)
	local since = self.Since[player]
	if not since or not self:_hasProfile(player) then return end

	-- While paused, only the time up to the pause is owed.
	local now = self.PausedAt[player] or os.clock()
	local seconds = math.floor(now - since)
	if seconds <= 0 then return end

	self.Since[player] = since + seconds

	self.Services.DataService:Update(player, "Stats", function(stats)
		stats.TimePlayed = (tonumber(stats.TimePlayed) or 0) + seconds
		return stats
	end)
end

--[[ LIFECYCLE ]]

function PlaytimeService:construct()
	if not COUNTS_HERE then return end

	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; playtime will not be counted.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_track(player)
	end)

	-- Players who loaded before this service started: their signal already fired.
	for _, player in Players:GetPlayers() do
		if self:_hasProfile(player) then
			self:_track(player)
		end
	end

	-- The last chunk goes in with the profile still open, on both exit paths.
	if dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:_flush(player)
			self:_forget(player)
		end)
	end

	-- Cleanup for players who left without an open profile (the hook above does not even run).
	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self:_forget(player)
		end)
	end)

	local afkService = self.Services.AfkService
	if PAUSES_WHEN_AFK and afkService then
		afkService.Signals.AfkChanged:Connect(function(player : Player, afk : boolean)
			self:_setPaused(player, afk)
		end)
	end

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)

			for player in self.Since do
				self:_flush(player)
			end
		end
	end)
end

function PlaytimeService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function PlaytimeService:init()
end

return PlaytimeService
