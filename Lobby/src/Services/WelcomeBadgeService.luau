local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("WelcomeBadgeService")

--[[
	The `Welcome` badge: the player's first time in the game.

	The badge itself keeps "first time": Roblox knows whether the player already has it,
	and `BadgeService` asks before awarding. That is why this runs on every join, and
	depends on no mark on the profile (which resets when `PROFILE_KEY` changes).

	**Why `PlayerAdded` and not `PlayerDataLoaded`.** The badge does not depend on the
	profile; waiting for it would only delay the badge for a player whose profile is
	stuck in another session.

	**Why Lobby only.** Game is never the first place the player sees: they always go
	through the Lobby first.

	See docs/common/badges.md.
]]

local BADGE_NAME = "Welcome"

local WelcomeBadgeService = {
	Services = {
		BadgeService = {}
	}
}

--[[ LIFECYCLE ]]

function WelcomeBadgeService:construct()
	local badgeService = self.Services.BadgeService
	if not badgeService then
		log:Warn("no BadgeService; the welcome badge will not be awarded.")
		return
	end

	local function award(player : Player)
		badgeService:Award(player, BADGE_NAME)
	end

	Players.PlayerAdded:Connect(function(player : Player)
		task.spawn(award, player)
	end)

	-- Players who joined before `PlayerAdded` was connected.
	for _, player in Players:GetPlayers() do
		task.spawn(award, player)
	end
end

function WelcomeBadgeService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function WelcomeBadgeService:init()
end

return WelcomeBadgeService
