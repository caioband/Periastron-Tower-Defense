local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("PlaytimeService")

--[[
	Playtime on the profile (`Stats.TimePlayed`, in seconds), in both places.

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
]]

local FLUSH_INTERVAL = 60

local PlaytimeService = {
	Services = {
		DataService = {},
	},

	-- [Player] = `os.clock()` of the last second already written.
	Since = {},
}

--[[ INTERNAL ]]

function PlaytimeService:_hasProfile(player : Player) : boolean
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles

	return profiles ~= nil and profiles[player] ~= nil
end

function PlaytimeService:_track(player : Player)
	if self.Since[player] == nil then
		self.Since[player] = os.clock()
	end
end

--- Writes the whole seconds since the last write to the profile.
function PlaytimeService:_flush(player : Player)
	local since = self.Since[player]
	if not since or not self:_hasProfile(player) then return end

	local seconds = math.floor(os.clock() - since)
	if seconds <= 0 then return end

	self.Since[player] = since + seconds

	self.Services.DataService:Update(player, "Stats", function(stats)
		stats.TimePlayed = (tonumber(stats.TimePlayed) or 0) + seconds
		return stats
	end)
end

--[[ LIFECYCLE ]]

function PlaytimeService:construct()
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
			self.Since[player] = nil
		end)
	end

	-- Cleanup for players who left without an open profile (the hook above does not even run).
	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.Since[player] = nil
		end)
	end)

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
