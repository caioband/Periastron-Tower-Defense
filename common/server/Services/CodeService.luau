local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)

local Framework = Me.new()
local log = Log.new("CodeService")

local Config = ServerConfig.Codes
local LevelConfig = SharedConfig.LevelConfig

local IS_QA = Environment.IsQA()

local DATA_KEY = "RedeemedCodes"

local REQUEST_EVENT = "RedeemCode"
local RESULT_EVENT = "CodeRedeemResult"

--[[
	Redeems codes typed on the codes panel (`CodeController`).

	The client sends only the text. Everything is decided here, in this order:

	  1. the input is a string of sane length, and the player is not retrying faster
	     than `ATTEMPT_COOLDOWN`, valid code or not;
	  2. the player is at least `MIN_LEVEL` (from `Stats.XP`, see `LevelConfig`);
	  3. the player is in `GROUP_ID` (a web call, so it yields);
	  4. the code exists, has started (`StartsAt`), and has not expired (`ExpiresAt`);
	  5. the player has not redeemed it before (`Profile.RedeemedCodes`).

	Then it marks the code and pays through `RewardService`, with nothing that
	yields in between, and a player has one redemption in flight at a time: two
	clicks never pay twice.

	Two flags exist for test codes. `QaOnly` answers `Invalid` outside the QA
	universe. `Persist = false` keeps the redemption in `SessionRedeemed` instead of
	the profile, so it is forgotten when the player leaves this server and works
	again on the next one.

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

	-- [Player] = { [code] = os.time() } for codes with `Persist = false`
	SessionRedeemed = {},
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

	Reasons: `Invalid`, `Empty`, `Cooldown`, `Busy`, `NotLoaded`, `LowLevel`, `NotInGroup`,
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

	local loaded = self:_profileOf(player)
	if not loaded then
		return false, "NotLoaded"
	end

	-- Before the group: no web call, and no join prompt for a code they cannot use yet.
	local stats = loaded.Stats
	local xp = typeof(stats) == "table" and tonumber(stats.XP) or 0
	if LevelConfig:Resolve(xp).Level < Config.MIN_LEVEL then
		return false, "LowLevel"
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

	if not definition
		or (definition.StartsAt and time < definition.StartsAt)
		or (definition.QaOnly and not IS_QA)
	then
		return false, "Invalid"
	end

	if time >= definition.ExpiresAt then
		return false, "Expired"
	end

	local persist = definition.Persist ~= false
	local redeemed = if persist then profile[DATA_KEY] else self.SessionRedeemed[player]
	if typeof(redeemed) == "table" and redeemed[code] then
		return false, "AlreadyRedeemed"
	end

	-- Marked before paying, with nothing that yields in between: see the header.
	if persist then
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
	else
		local session = self.SessionRedeemed[player] or {}
		session[code] = time
		self.SessionRedeemed[player] = session
	end

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

			-- The client writes the required level into the message.
			MinLevel = if reason == "LowLevel" then Config.MIN_LEVEL else nil,
		})
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.LastAttempt[player] = nil
		self.Busy[player] = nil
		self.SessionRedeemed[player] = nil
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
