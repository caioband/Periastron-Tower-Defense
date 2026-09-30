local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Log = require(Shared.Util.Log)

local log = Log.new("AfkRejoinService")

--[[
	Rejoins every player periodically so Roblox never disconnects them for being idle.

	Roblox drops a client after 20 minutes without input (Error Code 278). Sending
	the player through a teleport gives them a fresh session and a fresh idle timer,
	so a rejoin every 15 minutes keeps them in the game indefinitely.

	The clock starts when the player joins. If a teleport fails, or starts but never
	completes, the module tries again every `RetrySeconds` until the player is gone.

	Teleports do not work in Studio, so the module does nothing there.
]]

local Config = {
	-- Turn the whole module off without deleting it.
	Enabled = true,

	-- Seconds in the server before a player is rejoined. Keep it well below 1200
	-- (20 minutes), the point where Roblox kicks idle clients.
	RejoinSeconds = 15 * 60,

	-- Extra seconds added to `RejoinSeconds`. The AFK reward timer starts when the
	-- profile loads, a few seconds after the player joins, so this lets the payout
	-- due at the 15 minute mark land before the rejoin resets the timer.
	GraceSeconds = 15,

	-- Seconds to wait before trying again if the rejoin did not take the player away.
	RetrySeconds = 20,

	-- true: send the player back into this same server instead of a new one.
	-- Use it if the AFK place runs on reserved / private servers.
	SameServer = false,
}

local AfkRejoinService = {
	-- [Player] = true while that player has a rejoin loop running.
	Watching = {},
}

--[[ INTERNAL ]]

--- Starts the teleport. Returns `ok, err` from the `pcall`, because the call is a
--- web request that can fail.
function AfkRejoinService:_teleport(player : Player) : (boolean, any)
	local options : TeleportOptions? = nil

	if Config.SameServer then
		options = Instance.new("TeleportOptions")
		options.ServerInstanceId = game.JobId
	end

	return pcall(function()
		return TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
end

function AfkRejoinService:_watch(player : Player)
	if self.Watching[player] then return end
	self.Watching[player] = true

	task.spawn(function()
		task.wait(Config.RejoinSeconds + Config.GraceSeconds)

		-- Once the teleport works the player leaves and the loop ends. If it did not
		-- (failed, or cancelled after it began), the player is still here: retry.
		while player.Parent == Players do
			local ok, err = self:_teleport(player)

			if not ok then
				log:Warn(`could not rejoin {player.Name}: {err}`)
			end

			task.wait(Config.RetrySeconds)
		end

		self.Watching[player] = nil
	end)
end

--[[ LIFECYCLE ]]

function AfkRejoinService:construct()
	if not Config.Enabled then return end
	if Log.IsStudio() then return end

	Players.PlayerAdded:Connect(function(player : Player)
		self:_watch(player)
	end)

	-- Players already here when this service started.
	for _, player in Players:GetPlayers() do
		self:_watch(player)
	end
end

function AfkRejoinService:start()
	self:construct()
end

function AfkRejoinService:init()
end

return AfkRejoinService