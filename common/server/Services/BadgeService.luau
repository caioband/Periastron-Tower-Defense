local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local RobloxBadges = game:GetService("BadgeService")

local ServerConfig = require(ServerScriptService:WaitForChild("Config"))
local Util = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util")
local Log = require(Util:WaitForChild("Log"))
local Environment = require(Util:WaitForChild("Environment"))

local log = Log.new("BadgeService")

-- This environment's badges: a badge only awards in its own universe.
local BADGES = ServerConfig.Badges[Environment.Name] or {}

--[[
	Awards the Roblox badges listed in `ServerConfig.Badges`, from the table of the
	environment it runs in (Production or QA). It is the only door:
	code that wants to award a badge calls `BadgeService:Award(player, "Name")` and
	does not talk to the Roblox API directly.

	**Why ask before awarding.** `AwardBadge` on a badge the player already has breaks
	nothing, but spends the same quota; `UserHasBadgeAsync` is cheap, and most calls
	are for players who already earned it. The answer is cached for the session, so
	the same badge is not queried twice for the same player.

	**Retry.** The badges API fails now and then under load; each call tries
	`MAX_ATTEMPTS` times before giving up with a warning.

	**Studio.** Roblox does not award badges in Studio, so `Award` does nothing there.

	`Award` may yield (it is a network call); callers that do not want to wait call
	it inside a `task.spawn`.

	See docs/common/badges.md.
]]

local MAX_ATTEMPTS = 3
local RETRY_DELAY = 2

local BadgeService = {
	Services = {}
}

--[[ INTERNAL ]]

local function withRetry(label : string, callback : () -> any) : (boolean, any)
	local ok, result
	for attempt = 1, MAX_ATTEMPTS do
		ok, result = pcall(callback)
		if ok then
			return true, result
		end
		if attempt < MAX_ATTEMPTS then
			task.wait(RETRY_DELAY)
		end
	end

	log:Warn(`{label} failed {MAX_ATTEMPTS}x: {result}`)
	return false, result
end

--[[ API ]]

--[=[
	Awards badge `name` (the key in `ServerConfig.Badges`) to the player if they do
	not have it yet. Returns `true` if the player ends up with the badge, whether they
	just earned it or already had it.
]=]
function BadgeService:Award(player : Player, name : string) : boolean
	local badgeId = BADGES[name]
	if not badgeId then
		log:StudioWarn(`badge "{name}" is not in ServerConfig.Badges.{Environment.Name}.`)
		return false
	end

	if RunService:IsStudio() then
		return false
	end

	local owned = self.Owned[player]
	if not owned then
		owned = {}
		self.Owned[player] = owned
	end
	if owned[badgeId] then
		return true
	end

	local okHas, hasBadge = withRetry(`UserHasBadgeAsync({name})`, function()
		return RobloxBadges:UserHasBadgeAsync(player.UserId, badgeId)
	end)
	if not okHas then
		return false
	end

	-- The player may have left during the query.
	if player.Parent ~= Players then
		return false
	end

	if not hasBadge then
		local okAward, awarded = withRetry(`AwardBadge({name})`, function()
			return RobloxBadges:AwardBadge(player.UserId, badgeId)
		end)
		if not okAward or not awarded then
			return false
		end
	end

	-- Only stores it if the player's session is still the same table (they did not leave midway).
	if self.Owned[player] == owned then
		owned[badgeId] = true
	end

	return true
end

--[[ LIFECYCLE ]]

function BadgeService:construct()
	Players.PlayerRemoving:Connect(function(player : Player)
		self.Owned[player] = nil
	end)
end

function BadgeService:start()
end

function BadgeService:init()
	-- [Player] = { [badgeId] = true }: what the player is already known to have.
	self.Owned = {}

	self:construct()
end

return BadgeService
