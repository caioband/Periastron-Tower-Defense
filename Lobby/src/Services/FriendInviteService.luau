local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("FriendInviteService")

--[[
	The "your friend is online, invite them" suggestion in the Lobby.

	A while after the player arrives, and then every `PROMPT_INTERVAL` seconds
	while they stay in the Lobby, this service sends `FriendInvitePrompt` to
	their client with what the profile says about their friends. The client asks
	Roblox which friends are online (`GetFriendsOnline` only answers for the
	LocalPlayer), picks one, and shows it in a CoreGui notification with `Invite`
	and `Decline` (see `FriendInviteController`).

	**The draw.** Roblox does not tell a game who the player talks to or plays
	with most, so we learn it. The client prefers, among the eligible online
	friends, the one who accepted the most invites from this player
	(`FriendInvites.Accepted`), then the one invited most times through the
	notification (`FriendInvites.Invited`), ties drawn at random; with no history
	it draws any eligible friend.

	**Accepted invites.** A player who joins the Lobby from an invite carries the
	inviter in `GetJoinData().ReferredByPlayerId`. The invites this system opens
	also carry `LAUNCH_DATA` in `LaunchData`, which is how `System` (our
	notification) is told apart from `Manual` (any other invite from the player,
	such as the Roblox menu or a share link); `Total` is both. The count goes to
	the **inviter's** profile through `ProfileEditService`, which reaches them on
	this server, on another one, or offline. It is read once per join: the join
	data belongs to that join only.

	**Who is eligible:** online, not on this server, and not suggested in the
	last `COOLDOWN` seconds (`FriendInvites.Shown`). The cooldown starts when the
	friend is **shown**, whatever the answer, so the next suggestions go through
	the rest of the friend list.

	**The client only reports; the server decides what counts.** `Shown` is only
	taken after a prompt this service sent, and only for someone who really is a
	friend (`IsFriendsWith`). `Invited` only counts the friend that was shown
	last, once. A client firing the events by hand can at most rearrange its own
	suggestions.

	Profile keys are the friend's `UserId` **as a string**: a DataStore cannot
	save a table with sparse numeric keys.

	**Decline snoozes.** After `Decline`, the next automatic suggestion waits
	`DECLINE_SNOOZE` seconds from the click instead of the usual interval. It is
	kept per server, not in the profile.

	Cmdr's `friendinvite` goes through `:Prompt`, outside the schedule (and the snooze).

	See docs/lobby/friend-invite.md.
]]

local DATA_KEY = "FriendInvites"

--[[
	Whether the automatic suggestion runs. Off since 2026-10-07, by request: no
	notification appears on its own. What stays on is everything that is not the
	notification nagging: accepted invites are still credited (`creditReferral`), and
	Cmdr's `friendinvite` still sends one by hand. Turning it back on is only this flag.
]]
local AUTO_SUGGEST = false

-- What the invites opened by the notification carry in `LaunchData`. The client
-- gets it in the prompt, so this is the only copy.
local LAUNCH_DATA = "FriendInvite"

-- How many friends Cmdr's `friendinvitestats` lists.
local STATS_LINES = 20

-- Seconds after the client is ready before the suggestion: the player just
-- landed, and the intro, the HUD, and the tutorial offer come first.
local PROMPT_DELAY = 30

-- Seconds between suggestions after the first one. Each friend still sits out
-- `COOLDOWN` after being shown, so a player with few friends online soon gets
-- nothing until one comes back into the draw.
local PROMPT_INTERVAL = 2 * 60

-- Seconds a suggested friend stays out of the draw.
local COOLDOWN = 60 * 60

-- Seconds after a `Decline` before the next automatic suggestion.
local DECLINE_SNOOZE = 5 * 60

local FriendInviteService = {
	Services = {
		DataService = {},
		ProfileEditService = {},
		TutorialService = {},
	}
}

-- [Player] = true: a prompt went out and the client has not reported its pick.
FriendInviteService.Pending = {}

-- [Player] = UserId: the friend on screen, until the player answers.
FriendInviteService.Current = {}

-- [Player] = true: this join's referral was already read.
FriendInviteService.Credited = {}

-- [Player] = true: the suggestion loop is running for this player.
FriendInviteService.Scheduled = {}

-- [Player] = os.clock() before which the loop sends nothing (set by `Decline`).
FriendInviteService.SnoozedUntil = {}

--[[ INTERNAL ]]

local function readInvites(data : any) : { Invited : { [string] : number }, Accepted : { [string] : any }, Shown : { [string] : number } }
	local invites = data and data[DATA_KEY]
	if typeof(invites) ~= "table" then
		invites = {}
	end

	for _, key in { "Invited", "Accepted", "Shown" } do
		if typeof(invites[key]) ~= "table" then
			invites[key] = {}
		end
	end

	return invites
end

-- `{ System, Manual, Total }` for one friend, zeros when missing.
local function acceptedOf(invites, key : string) : { System : number, Manual : number, Total : number }
	local entry = invites.Accepted[key]
	entry = if typeof(entry) == "table" then entry else {}

	return {
		System = tonumber(entry.System) or 0,
		Manual = tonumber(entry.Manual) or 0,
		Total = tonumber(entry.Total) or 0,
	}
end

-- Every friend with history: `{ [UserId string] = true }`.
local function knownFriends(invites) : { [string] : boolean }
	local keys = {}
	for key in invites.Invited do
		keys[key] = true
	end
	for key in invites.Accepted do
		keys[key] = true
	end

	return keys
end

-- A UserId from the client: a positive whole number, or nil.
local function toUserId(value : any) : number?
	if typeof(value) ~= "number" or value ~= value then return nil end
	if value <= 0 or value % 1 ~= 0 then return nil end

	return value
end

--[=[
	What the client needs for the draw: friends still in cooldown (`Exclude`),
	friends with history, best first (`Preferred`: most accepted invites, then
	most `Invite` clicks), and what to put in the invite's `LaunchData`.
]=]
local function buildPayload(invites, ignoreCooldown : boolean)
	local now = os.time()

	local exclude = {}
	if not ignoreCooldown then
		for key, shownAt in invites.Shown do
			local userId = tonumber(key)
			if userId and typeof(shownAt) == "number" and now - shownAt < COOLDOWN then
				table.insert(exclude, userId)
			end
		end
	end

	-- A random key per entry so ties come out in a different order each time;
	-- `table.sort` alone is not stable, but it is not random either.
	local ranked = {}
	for key in knownFriends(invites) do
		local userId = tonumber(key)
		local accepted = acceptedOf(invites, key).Total
		local clicks = tonumber(invites.Invited[key]) or 0

		if userId and (accepted > 0 or clicks > 0) then
			table.insert(ranked, { UserId = userId, Accepted = accepted, Clicks = clicks, Tie = math.random() })
		end
	end

	table.sort(ranked, function(a, b)
		if a.Accepted ~= b.Accepted then
			return a.Accepted > b.Accepted
		end
		if a.Clicks ~= b.Clicks then
			return a.Clicks > b.Clicks
		end

		return a.Tie < b.Tie
	end)

	local preferred = {}
	for index, entry in ranked do
		preferred[index] = entry.UserId
	end

	return {
		Exclude = exclude,
		Preferred = preferred,
		LaunchData = LAUNCH_DATA,
	}
end

--[=[
	The client picked a friend and put them on screen: starts the cooldown.
]=]
function FriendInviteService:onShown(player : Player, friendId : any)
	local userId = toUserId(friendId)
	if not userId or not self.Pending[player] then return end
	self.Pending[player] = nil

	local ok, isFriend = pcall(player.IsFriendsWith, player, userId)
	if not ok or not isFriend then return end
	if not player.Parent then return end

	self.Current[player] = userId

	local now = os.time()
	self.Services.DataService:Update(player, DATA_KEY, function(stored)
		local invites = readInvites({ [DATA_KEY] = stored })

		-- Expired entries go away on every write; without this, `Shown` would keep
		-- every friend ever suggested.
		for key, shownAt in invites.Shown do
			if typeof(shownAt) ~= "number" or now - shownAt >= COOLDOWN then
				invites.Shown[key] = nil
			end
		end

		invites.Shown[tostring(userId)] = now

		return invites
	end)

	log:Debug(`{player.Name} was shown friend {userId}`)
end

--[=[
	The player clicked a button on the notification. Only `Invite` writes;
	`Decline` snoozes the schedule (`DECLINE_SNOOZE`).
]=]
function FriendInviteService:onAnswered(player : Player, friendId : any, accepted : any)
	local userId = toUserId(friendId)
	if not userId or self.Current[player] ~= userId then return end
	self.Current[player] = nil

	if accepted ~= true then
		self.SnoozedUntil[player] = os.clock() + DECLINE_SNOOZE
		log:Debug(`{player.Name} declined friend {userId}; next suggestion in {DECLINE_SNOOZE}s`)
		return
	end

	self.Services.DataService:Update(player, DATA_KEY, function(stored)
		local invites = readInvites({ [DATA_KEY] = stored })

		local key = tostring(userId)
		invites.Invited[key] = (tonumber(invites.Invited[key]) or 0) + 1

		return invites
	end)

	log:Debug(`{player.Name} invited friend {userId}`)
end

--[=[
	The player joined from an invite: credits it to the inviter, wherever they
	are. `System` when the invite came from our notification, `Manual` otherwise.
]=]
function FriendInviteService:creditReferral(player : Player)
	if self.Credited[player] then return end
	self.Credited[player] = true

	local ok, joinData = pcall(player.GetJoinData, player)
	if not ok or typeof(joinData) ~= "table" then return end

	local inviter = toUserId(joinData.ReferredByPlayerId)
	if not inviter or inviter == player.UserId then return end

	local editor = self.Services.ProfileEditService
	if not editor then
		log:Warn(`no ProfileEditService; the invite {player.Name} accepted from {inviter} is not counted.`)
		return
	end

	local source = if joinData.LaunchData == LAUNCH_DATA then "System" else "Manual"

	local result = editor:Edit(inviter, {
		Key = DATA_KEY,
		Action = "increment",
		Path = { "Accepted", tostring(player.UserId) },
		Counters = { [source] = 1, Total = 1 },
	})

	log:Debug(`{player.Name} accepted a {source} invite from {inviter}: {result}`)
end

--[=[
	Whether the automatic suggestion may go out now. Not while the tutorial has
	the player's attention: the offer is pending (`Tutorial = false`) or the shop
	step after the tutorial match is running (`TutorialService.Returned`, cleared
	when that unboxing ends). Checked on every beat, so the suggestions start as
	soon as the tutorial is out of the way.
]=]
function FriendInviteService:canSuggest(player : Player) : boolean
	local dataService = self.Services.DataService
	local entry = dataService.Profiles and dataService.Profiles[player]
	if not entry then return false end

	if entry.Profile.Data.Tutorial == false then return false end

	local tutorial = self.Services.TutorialService
	if tutorial and tutorial.Returned and tutorial.Returned[player] then return false end

	return true
end

--[=[
	The automatic suggestion: first after `PROMPT_DELAY`, then every
	`PROMPT_INTERVAL` until the player leaves the Lobby. A `Decline` holds the
	next beat until `SnoozedUntil`.
]=]
function FriendInviteService:schedule(player : Player)
	if not AUTO_SUGGEST then return end
	if self.Scheduled[player] then return end
	self.Scheduled[player] = true

	self.Services.DataService:Get(player, function()
		task.delay(PROMPT_DELAY, function()
			while player.Parent and self.Scheduled[player] do
				local snoozed = self.SnoozedUntil[player]
				if snoozed and os.clock() < snoozed then
					task.wait(snoozed - os.clock())
					continue
				end

				if self:canSuggest(player) then
					self:Prompt(player, false)
				end

				task.wait(PROMPT_INTERVAL)
			end
		end)
	end)
end

--[[ API ]]

--[=[
	Sends the suggestion now. `ignoreCooldown` puts friends suggested in the last
	hour back in the draw (Cmdr's `friendinvite`).

	The client shows nothing when no friend is eligible.
]=]
function FriendInviteService:Prompt(player : Player, ignoreCooldown : boolean?)
	self.Services.DataService:Get(player, function(data)
		if not player.Parent then return end

		self.Pending[player] = true
		Framework:Fire("FriendInvitePrompt", player, buildPayload(readInvites(data), ignoreCooldown == true))
	end)
end

--[=[
	What Cmdr's `friendinvitestats` prints: the player's totals and the friends
	with history, best first (the same order as the draw).
]=]
function FriendInviteService:Describe(player : Player) : string
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	if not entry then
		return `{player.Name}: profile not loaded.`
	end

	local invites = readInvites(entry.Profile.Data)
	local now = os.time()

	local rows = {}
	local totals = { Clicks = 0, System = 0, Manual = 0, Total = 0 }
	for key in knownFriends(invites) do
		local accepted = acceptedOf(invites, key)
		local clicks = tonumber(invites.Invited[key]) or 0

		totals.Clicks += clicks
		totals.System += accepted.System
		totals.Manual += accepted.Manual
		totals.Total += accepted.Total

		table.insert(rows, { Key = key, Clicks = clicks, Accepted = accepted })
	end

	table.sort(rows, function(a, b)
		if a.Accepted.Total ~= b.Accepted.Total then
			return a.Accepted.Total > b.Accepted.Total
		end
		if a.Clicks ~= b.Clicks then
			return a.Clicks > b.Clicks
		end

		return a.Key < b.Key
	end)

	local cooling = 0
	for _, shownAt in invites.Shown do
		if typeof(shownAt) == "number" and now - shownAt < COOLDOWN then
			cooling += 1
		end
	end

	local lines = {
		`{player.Name}: {totals.Clicks} Invite click(s); accepted System {totals.System}, Manual {totals.Manual}, Total {totals.Total}; {cooling} friend(s) in cooldown.`,
	}

	for index, row in rows do
		if index > STATS_LINES then
			table.insert(lines, `... and {#rows - STATS_LINES} more.`)
			break
		end

		local okName, name = pcall(Players.GetNameFromUserIdAsync, Players, tonumber(row.Key))
		local label = if okName and name then `{name} (#{row.Key})` else `#{row.Key}`

		table.insert(lines, `  {label}: clicks {row.Clicks}; accepted System {row.Accepted.System}, Manual {row.Accepted.Manual}, Total {row.Accepted.Total}`)
	end

	return table.concat(lines, "\n")
end

--[[ LIFECYCLE ]]

function FriendInviteService:construct()
	if not self.Services.DataService then
		log:Warn("no DataService; the friend invite suggestion is off.")
		return
	end

	Framework:Listen("FriendInviteShown", function(player : Player, friendId : any)
		self:onShown(player, friendId)
	end)

	Framework:Listen("FriendInviteAnswered", function(player : Player, friendId : any, accepted : any)
		self:onAnswered(player, friendId, accepted)
	end)

	Players.PlayerAdded:Connect(function(player : Player)
		task.spawn(self.creditReferral, self, player)
		self:schedule(player)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(self.creditReferral, self, player)
		self:schedule(player)
	end

	Players.PlayerRemoving:Connect(function(player : Player)
		self.Pending[player] = nil
		self.Current[player] = nil
		self.Credited[player] = nil
		self.Scheduled[player] = nil
		self.SnoozedUntil[player] = nil
	end)
end

function FriendInviteService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function FriendInviteService:init()
	Framework:Listen("FriendInvitePrompt", function() end) -- only so the event exists
end

return FriendInviteService
