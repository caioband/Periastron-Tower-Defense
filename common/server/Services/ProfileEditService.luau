local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs:WaitForChild("SharedConfig"))
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("ProfileEditService")

local LevelConfig = SharedConfig.LevelConfig

--[[
	Profile editing for admin commands (`cash`, `shards`, `units`, `level`), with the
	player anywhere: on this server, on another one, or offline.

	An edit is an **operation**: `{ Key, Field, Action, Amount }`, changing
	`Data[Key][Field]`, a number. Today there are two keys: `Stats` (Cash, Shards, and
	Level) and `Units` (how many of each unit).

	`Stats.Level` is the one field that is not stored: the level is always derived
	from `Stats.XP` (see `LevelConfig`), so the operation is done in levels and
	written back as XP (`editLevel`).

	**Which way it goes.**
	  1. The player is on this server → `DataService:Update`, immediately, and the
	     replica notifies the client as with any other write.
	  2. The profile has a session open on another server → `MessageAsync`. That
	     server receives it within seconds (`DataService` registers the
	     `MessageHandler`), applies it, and saves. A session from a server that
	     crashed also lands here: the message waits for the player to join again.
	  3. No session → the same message, followed by a short session opened **only to
	     consume it**: apply, save, and close.

	**Why case 3 also goes by message.** Between seeing "no session" and opening
	ours there is a gap; if the player joins in it, whoever wins the profile is the
	one that consumes the message. It is applied exactly once (ProfileStore marks it
	processed) and is never lost. And if our short session steals the profile from a
	server that just opened it, that server's `DataService` kicks the player (see its
	`OnSessionEnd`) instead of letting them play without saving.

	See docs/common/admin-commands.md.
]]

local MESSAGE_KIND = "AdminEdit"

-- How long case 3's short session waits for the profile before giving up. Giving
-- up loses nothing: the message is already on the profile and applies next session.
local OFFLINE_SESSION_TIMEOUT = 15

-- What each key accepts, and whether zero leaves the table.
local KEYS = {
	-- A currency at zero stays on the profile as `0`: that is the template's format.
	-- `Level` is virtual: it is written as `XP` (see `editLevel`).
	Stats = { Fields = { Cash = true, Shards = true, Level = true }, DropZero = false },

	-- A unit at zero leaves the table: that is what a profile that never had the unit
	-- looks like, and `DeckConfig` reads both cases with the same `or 0`.
	Units = { Fields = nil, DropZero = true },
}

local ProfileEditService = {
	Services = {
		DataService = {},
	}
}

--[[ INTERNAL ]]

--[=[
	The value after the operation. Never negative: an oversized `remove` is a typo,
	not a request to owe.
]=]
local function applyAction(action : string, current : number, amount : number) : number
	if action == "set" then
		return math.max(amount, 0)
	elseif action == "remove" then
		return math.max(current - amount, 0)
	end

	return math.max(current + amount, 0)
end

--[=[
	`Stats.Level`: the operation in levels, clamped to 1..MAX_LEVEL, and the result
	written to `Stats.XP` as the start of that level (zero progress in it).

	When the level does not change (a `remove` at level 1, an `add` at the max) the
	XP is left alone, so the progress in the level survives; a `set` always writes,
	which is how to zero it.
]=]
local function editLevel(tbl : { [string] : number }, op) : ({ [string] : number }, number, number)
	local previous = LevelConfig:Resolve(tbl.XP).Level
	local updated = math.clamp(applyAction(op.Action, previous, math.floor(op.Amount)), 1, LevelConfig.MAX_LEVEL)

	if updated ~= previous or op.Action == "set" then
		tbl.XP = LevelConfig:GetTotalXPForLevel(updated)
	end

	return tbl, previous, updated
end

--[=[
	Applies the operation to a `{ [Field] = number }` table and returns
	`(table, previous, new)`. It is the only math: all three paths go through here.
]=]
local function editTable(tbl : { [string] : number }?, op) : ({ [string] : number }, number, number)
	tbl = if typeof(tbl) == "table" then tbl else {}

	if op.Key == "Stats" and op.Field == "Level" then
		return editLevel(tbl, op)
	end

	local previous = tonumber(tbl[op.Field]) or 0
	local updated = applyAction(op.Action, previous, op.Amount)

	if updated == 0 and KEYS[op.Key].DropZero then
		tbl[op.Field] = nil
	else
		tbl[op.Field] = updated
	end

	return tbl, previous, updated
end

local function validate(op) : string?
	local rule = KEYS[op.Key]
	if not rule then
		return `'{op.Key}' is not an editable key.`
	end
	if rule.Fields and not rule.Fields[op.Field] then
		return `'{op.Field}' is not editable in {op.Key}.`
	end
	if op.Action ~= "set" and op.Action ~= "add" and op.Action ~= "remove" then
		return `unknown action '{op.Action}'.`
	end
	if typeof(op.Amount) ~= "number" then
		return "amount must be a number."
	end

	return nil
end

local function displayName(userId : number) : string
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.Name
	end

	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)

	return if ok and name then name else `#{userId}`
end

--[=[
	Case 3: opens the profile only to consume pending messages, then closes it.

	While the short session is open, the key is marked in `DataService`
	(`OfflineSessions`): ProfileStore refuses to open the same key twice on the same
	server, and a player who joins **here** in the meantime waits for it to close
	instead of ending up without a profile.
]=]
function ProfileEditService:_consumeOffline(userId : number, nonce : string) : (number?, number?)
	local dataService = self.Services.DataService
	local store = dataService.Packages.ProfileManager
	local profileKey = "Player_" .. userId

	--[[
		The player may have joined **here** while the message was in flight. The check
		and the mark happen together, without yielding the thread between them: a
		player who joins after this waits for the mark to clear
		(`DataService:CreatePlayer`), and one who joined before already opened (or is
		opening) their session, which consumes the message on its own. Opening ours on
		top would make ProfileStore return `nil` for theirs.
	]]
	if Players:GetPlayerByUserId(userId) then
		return nil, nil
	end

	dataService.OfflineSessions[userId] = true

	local previous, updated

	local ok, err = pcall(function()
		local deadline = os.clock() + OFFLINE_SESSION_TIMEOUT
		local session = store:StartSessionAsync(profileKey, {
			Cancel = function()
				return os.clock() > deadline
			end,
		})
		if not session then
			return
		end

		session:MessageHandler(function(message, processed)
			local p, u = self:ApplyMessage(session.Data, message, processed)
			if typeof(message) == "table" and message.Nonce == nonce then
				previous, updated = p, u
			end
		end)

		session:EndSession()
	end)

	dataService.OfflineSessions[userId] = nil

	if not ok then
		log:Warn(`short session for {profileKey} failed: {err}`)
	end

	return previous, updated
end

--[[ API ]]

--[=[
	The `MessageHandler` every `DataService` registers on each session, and case 3's
	short session too. Applies the edit message directly to `data` and marks it
	processed. A message of another type passes through for whoever understands it.

	Returns `(previous, new)` when it applied.
]=]
function ProfileEditService:ApplyMessage(data : any, message : any, processed : () -> ()) : (number?, number?)
	if typeof(message) ~= "table" or message.Kind ~= MESSAGE_KIND then
		return nil, nil
	end

	local op = message.Op
	if typeof(op) ~= "table" or validate(op) then
		log:Warn("invalid edit message discarded.")
		processed()
		return nil, nil
	end

	local tbl, previous, updated = editTable(data[op.Key], op)
	data[op.Key] = tbl

	processed()

	return previous, updated
end

--[=[
	Like `ApplyMessage`, but for the profile open on this server: it goes through
	`DataService:Update`, which is what notifies the replica (and the client).
]=]
function ProfileEditService:ApplyMessageToPlayer(player : Player, message : any, processed : () -> ())
	if typeof(message) ~= "table" or message.Kind ~= MESSAGE_KIND then
		return
	end

	local op = message.Op
	if typeof(op) ~= "table" or validate(op) then
		log:Warn("invalid edit message discarded.")
		processed()
		return
	end

	self.Services.DataService:Update(player, op.Key, function(current)
		return (editTable(current, op))
	end)

	processed()
end

--[=[
	Applies the operation to `userId`'s profile, wherever it is, and returns the line
	the console prints.
]=]
function ProfileEditService:Edit(userId : number, op) : string
	local problem = validate(op)
	if problem then
		return problem
	end

	local dataService = self.Services.DataService
	if not dataService then
		return "DataService unavailable."
	end

	local label = `{op.Key}.{op.Field}`

	-- 1. On this server.
	local player = Players:GetPlayerByUserId(userId)
	if player then
		if not (dataService.Profiles and dataService.Profiles[player]) then
			return `{player.Name}: profile still loading, try again.`
		end

		local previous, updated = 0, 0
		dataService:Update(player, op.Key, function(current)
			local tbl
			tbl, previous, updated = editTable(current, op)
			return tbl
		end)

		return `{player.Name} {label} {previous} -> {updated}`
	end

	local name = displayName(userId)
	local store = dataService.Packages.ProfileManager
	local profileKey = "Player_" .. userId

	local okRead, snapshot = pcall(store.GetAsync, store, profileKey)
	if not okRead then
		return `{name}: failed to read profile ({snapshot}).`
	end
	if not snapshot then
		return `{name}: has no profile in this store (never played?). Nothing changed.`
	end

	local nonce = HttpService:GenerateGUID(false)
	local message = { Kind = MESSAGE_KIND, Op = op, Nonce = nonce }

	local okSend, sent = pcall(store.MessageAsync, store, profileKey, message)
	if not okSend or not sent then
		return `{name}: failed to send the edit ({okSend and "store closing" or sent}).`
	end

	-- 2. Session open on another server (or from a server that crashed).
	if snapshot.Session then
		return `{name} {label}: {op.Action} {op.Amount} sent to their server (online elsewhere; applies in a few seconds, or on next join).`
	end

	-- 3. No session.
	local previous, updated = self:_consumeOffline(userId, nonce)
	if updated then
		return `{name} {label} {previous} -> {updated} (offline, saved)`
	end

	return `{name} {label}: {op.Action} {op.Amount} queued (profile busy; applies on next join).`
end

--[=[
	What the Cmdr commands call: the operation for each `userId`, one line per
	player. Serial on purpose: each may wait on the DataStore, and in parallel an
	`all` would fire every read at once.
]=]
function ProfileEditService:RunCommand(userIds : { number }, op) : string
	if #userIds == 0 then
		return "Nobody matched."
	end

	local lines = {}
	for _, userId in userIds do
		table.insert(lines, self:Edit(userId, table.clone(op)))
	end

	return table.concat(lines, "\n")
end

--[[ LIFECYCLE ]]

function ProfileEditService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end
end

function ProfileEditService:init()
end

return ProfileEditService
