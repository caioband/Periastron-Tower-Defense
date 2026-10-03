local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("CodeService")

local Config = ServerConfig.Codes

local DATA_KEY = "RedeemedCodes"

local REQUEST_EVENT = "RedeemCode"
local RESULT_EVENT = "CodeRedeemResult"

--[[
	Redeems codes typed on the codes panel (`CodeController`).

	The client sends only the text. Everything is decided here, in this order:

	  1. the input is a string of sane length, and the player is not retrying faster
	     than `ATTEMPT_COOLDOWN`, valid code or not;
	  2. the player is in `GROUP_ID` (a web call, so it yields);
	  3. the code exists, has started (`StartsAt`), and has not expired (`ExpiresAt`);
	  4. the player has not redeemed it before (`Profile.RedeemedCodes`).

	Then it marks the code and pays through `RewardService`, with nothing that
	yields in between, and a player has one redemption in flight at a time: two
	clicks never pay twice.

	The group is checked before the code so a player outside it always gets the
	join prompt, whatever they typed. A code that has not started answers
	`Invalid`, the same as one that does not exist, so it cannot be found early.

	`IsInGroup` is cached for the whole session on the server, so a player who joins
	the group mid-session would keep failing. On a "no", `GetGroupsAsync`, which is
	not cached, asks again.

	The answer goes back as `CodeRedeemResult` with the client's request id: Warp does
	not order events, and the client must match the answer to the attempt.

	See docs/common/codes.md.
]]
local CodeService = {
	Services = {
		DataService = {},
		RewardService = {},
	},

	-- [Player] = os.clock() of the last attempt
	LastAttempt = {},

	-- [Player] = true while a redemption is waiting on the group check
	Busy = {},
}

--[[ INTERNAL ]]

local function normalize(text : string) : string
	return string.upper((string.gsub(text, "^%s*(.-)%s*$", "%1")))
end

function CodeService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[=[
	Whether the player is in the group: `true`, `false`, or `nil` when Roblox could
	not answer. Never errors.
]=]
local function isInGroup(player : Player, groupId : number) : boolean?
	local cachedOk, cached = pcall(player.IsInGroup, player, groupId)
	if cachedOk and cached then
		return true
	end

	-- The cached answer may be stale: the player could have joined a moment ago.
	local freshOk, groups = pcall(GroupService.GetGroupsAsync, GroupService, player.UserId)
	if freshOk and typeof(groups) == "table" then
		for _, group in groups do
			if group.Id == groupId then
				return true
			end
		end

		return false
	end

	return if cachedOk then false else nil
end

--[[ EXTERNAL ]]

--[=[
	Tries to redeem `text` for `player`. Returns whether it paid, the reason when it
	did not, and on success the normalized code and its rewards. Yields (group check).

	Reasons: `Invalid`, `Empty`, `Cooldown`, `Busy`, `NotLoaded`, `NotInGroup`,
	`GroupCheckFailed`, `Expired`, `AlreadyRedeemed`. The client's texts for them
	are in `SharedConfig.CodeConfig.Messages`.
]=]
function CodeService:Redeem(player : Player, text : any) : (boolean, string?, string?, any?)
	if typeof(text) ~= "string" or #text > Config.MAX_LENGTH * 4 then
		return false, "Invalid"
	end

	local code = normalize(text)
	if code == "" then
		return false, "Empty"
	end

	if #code > Config.MAX_LENGTH then
		return false, "Invalid"
	end

	if self.Busy[player] then
		return false, "Busy"
	end

	local now = os.clock()
	local last = self.LastAttempt[player]
	if last and now - last < Config.ATTEMPT_COOLDOWN then
		return false, "Cooldown"
	end

	self.LastAttempt[player] = now

	if not self:_profileOf(player) then
		return false, "NotLoaded"
	end

	self.Busy[player] = true
	local member = isInGroup(player, Config.GROUP_ID)
	self.Busy[player] = nil

	if member == nil then
		return false, "GroupCheckFailed"
	elseif not member then
		return false, "NotInGroup"
	end

	-- The group check yielded: the player may have left and the profile closed.
	local profile = self:_profileOf(player)
	if not profile then
		return false, "NotLoaded"
	end

	local definition = Config.Codes[code]
	local time = os.time()

	if not definition or (definition.StartsAt and time < definition.StartsAt) then
		return false, "Invalid"
	end

	if time >= definition.ExpiresAt then
		return false, "Expired"
	end

	local redeemed = profile[DATA_KEY]
	if typeof(redeemed) == "table" and redeemed[code] then
		return false, "AlreadyRedeemed"
	end

	-- Marked before paying, with nothing that yields in between: see the header.
	self.Services.DataService:Update(player, DATA_KEY, function(current)
		local copy = {}

		if typeof(current) == "table" then
			for key, value in current do
				copy[key] = value
			end
		end

		copy[code] = time

		return copy
	end)

	self.Services.RewardService:Grant(player, definition.Rewards)

	log:Debug(`{player.Name} redeemed {code}.`)

	return true, nil, code, definition.Rewards
end

function CodeService:construct()
	Framework:Listen(REQUEST_EVENT, function(player : Player, requestId : any, text : any)
		if typeof(requestId) ~= "number" then
			return
		end

		local success, reason, code, rewards = self:Redeem(player, text)

		if not player.Parent then
			return
		end

		Framework:Fire(RESULT_EVENT, player, {
			Id = requestId,
			Success = success,
			Reason = reason,
			Code = code,
			Rewards = rewards,

			-- The client opens the join prompt for this group.
			GroupId = if reason == "NotInGroup" then Config.GROUP_ID else nil,
		})
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.LastAttempt[player] = nil
		self.Busy[player] = nil
	end)
end

function CodeService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function CodeService:init()
	-- Only the server fires this one; without the empty Listen the client would wait
	-- ten seconds for the identifier (see docs/architecture/me-framework.md).
	Framework:Listen(RESULT_EVENT, function() end)
end

return CodeService
