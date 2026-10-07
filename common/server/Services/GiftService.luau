local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TextService = game:GetService("TextService")
local TextChatService = game:GetService("TextChatService")
local DataStoreService = game:GetService("DataStoreService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local GiftConfig = SharedConfig.GiftConfig
local GamepassConfig = SharedConfig.GamepassConfig
local RobuxShopConfig = SharedConfig.RobuxShopConfig
local Config = ServerConfig.Gifting

local Framework = Me.new()
local log = Log.new("GiftService")

local MESSAGE_KIND = "Gift"

local EVENTS = {
	Request = "RequestGift",           -- client -> server
	RequestResult = "GiftRequestResult",
	Lookup = "LookupGiftRecipient",    -- client -> server
	LookupResult = "GiftLookupResult",
	Notify = "GiftNotification",       -- server -> client
	Seen = "GiftSeen",                 -- client -> server
}

--[[
	Gifting for game passes and developer products.

	Roblox has no native gifting, so a gift is a developer product the BUYER pays
	for (`GiftConfig`). What each side does:

	  **Buyer.** `RequestGift` validates everything, writes an **intent**
	  (`Data.Gifts.Outgoing[itemKey]`: who, which message) into the buyer's profile
	  and waits for it to be SAVED before opening the purchase prompt. There is one
	  intent per item, so it is locked while it belongs to a purchase in progress
	  (prompt open, or bought with the receipt not paid out yet): a second gift of
	  the same item would replace it, and the pending receipt would go to the new
	  recipient. Roblox's answer to the prompt (`PromptProductPurchaseFinished`)
	  frees a closed prompt's intent and locks a bought one's. The receipt then
	  comes through `MonetizationService:RegisterProduct` like any other product,
	  so `PurchaseHistory` and the save-before-`PurchaseGranted` already make the
	  payout exactly-once from the buyer's side.

	  **Delivery.** The gift id is the `PurchaseId`. It reaches the recipient's
	  `Data.Gifts.Inbox` by one of two roads: straight into the profile (saved
	  before the receipt is confirmed) when they are on this server, or as a
	  ProfileStore message (same road as `ProfileEditService`) when they are
	  elsewhere or offline. The inbox write drops an id it has already seen
	  (`Inbox` or `Received`), so a receipt retried after a failed save or a crash
	  cannot deliver twice.

	  **Recipient.** `Deliver` claims inbox entries once the profile is open (and,
	  in the Lobby, the client is ready). A pass goes into `Data.GiftedPasses`,
	  which `MonetizationService:RecalibratePasses` merges into `Gamepasses`; a pass
	  they already own becomes coins instead (`Config.Gifting.DUPLICATE_COINS`). A
	  pack goes through `RobuxShopService:Grant`. The payout and the inbox removal
	  happen with nothing yielding in between, so a save can never land between
	  them.

	The message handlers (`ApplyMessage*`) only move data into the inbox. All game
	logic runs at claim time, on a server that has the profile and the services.

	Never-played recipients are refused: there is no profile to deliver to.

	See docs/common/gifting.md.
]]
local GiftService = {
	Services = {
		DataService = {},
		MonetizationService = {},
		RobuxShopService = {},
		CurrencyService = {},
	},

	-- [Player] = os.clock()
	LastRequest = {},
	LastLookup = {},

	-- [UserId] = { At = os.clock(), Status = GetRecipientStatus's answer }
	LookupCache = {},

	-- [Player] = true
	Busy = {},
	Delivering = {},
	Dirty = {},
}

--[[ INTERNAL ]]

local GIFT_TABLES = { "Inbox", "Received", "Outgoing", "Unseen" }

--[=[
	Makes sure `Data.Gifts` has all its tables. Old profiles get them through
	DataService's reconcile, but an offline short session works on the raw data,
	before any reconcile.
]=]
local function shaped(gifts : any) : any
	if typeof(gifts) ~= "table" then
		gifts = {}
	end

	for _, name in GIFT_TABLES do
		if typeof(gifts[name]) ~= "table" then
			gifts[name] = {}
		end
	end

	return gifts
end

local function stampOf(value : any) : number
	if typeof(value) == "table" then
		return tonumber(value.At) or 0
	end

	return tonumber(value) or 0
end

local function pruneOldest(map : { [string] : any }, cap : number)
	local count = 0
	for _ in map do
		count += 1
	end
	if count <= cap then
		return
	end

	local list = {}
	for id, value in map do
		table.insert(list, { Id = id, Stamp = stampOf(value) })
	end
	table.sort(list, function(a, b)
		return a.Stamp < b.Stamp
	end)

	for index = 1, count - cap do
		map[list[index].Id] = nil
	end
end

local function countKeys(map : any) : number
	local count = 0
	for _ in map do
		count += 1
	end

	return count
end

local function validGift(gift : any) : boolean
	return typeof(gift) == "table"
		and typeof(gift.Id) == "string" and #gift.Id > 0 and #gift.Id <= 40
		and typeof(gift.ItemKey) == "string" and #gift.ItemKey <= 50
		and typeof(gift.SenderId) == "number"
		and typeof(gift.SenderName) == "string" and #gift.SenderName <= 100
		and (gift.Message == nil or (typeof(gift.Message) == "string" and #gift.Message <= 800))
		and typeof(gift.At) == "number"
end

--[=[
	The gifts still waiting in a profile's message queue (sent by `_route`, not yet
	moved into `Inbox` by a `MessageHandler`). ProfileStore has no public reader for
	the queue, so this reads its internal `global_updates` list (`{ {index,
	message}, ... }`), refreshed on every load and save. Works on a `GetAsync`
	snapshot and on an open session alike.
]=]
local function queuedGifts(profile : any) : { any }
	local list = {}

	local updates = typeof(profile) == "table" and profile.global_updates
	if typeof(updates) ~= "table" then
		return list
	end

	for _, update in updates do
		local message = typeof(update) == "table" and update[#update]
		if typeof(message) == "table" and message.Kind == MESSAGE_KIND and validGift(message.Gift) then
			table.insert(list, message.Gift)
		end
	end

	return list
end

--[=[
	Whether a stored intent still belongs to a purchase in progress: its prompt is
	open, or it was bought and the receipt has not paid out. Replacing it then would
	send that receipt to the new recipient. Intents from before the `State` field
	never lock.
]=]
local function intentBusy(intent : any, now : number) : boolean
	if typeof(intent) ~= "table" or intent.ConsumedBy ~= nil then
		return false
	end

	if intent.State == "Paid" then
		return now - (tonumber(intent.PaidAt) or 0) < Config.PAID_LOCK
	end
	if intent.State == "Prompt" then
		return now - (tonumber(intent.At) or 0) < Config.PROMPT_LOCK
	end

	return false
end

local function entryOf(gift : any) : any
	return {
		ItemKey = gift.ItemKey,
		SenderId = gift.SenderId,
		SenderName = gift.SenderName,
		Message = gift.Message,
		At = gift.At,
	}
end

--- Adds the gift to a `Data.Gifts` table unless that id was already seen.
local function appendTo(gifts : any, gift : any)
	if gifts.Inbox[gift.Id] or gifts.Received[gift.Id] then
		return
	end

	gifts.Inbox[gift.Id] = entryOf(gift)
end

function GiftService:_data(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

function GiftService:_intentOf(player : Player, itemKey : string) : any
	local data = self:_data(player)
	local outgoing = data and typeof(data.Gifts) == "table" and data.Gifts.Outgoing

	return typeof(outgoing) == "table" and outgoing[itemKey] or nil
end

--[=[
	Removes the buyer's intent for an item while it is still only a prompt (never
	one that was bought or consumed). With `at`, only the intent written at that
	time, so a late answer cannot remove a newer one.
]=]
function GiftService:_dropIntent(player : Player, itemKey : string, at : number?)
	if not self:_data(player) then
		return
	end

	self.Services.DataService:Update(player, "Gifts", function(current)
		local gifts = shaped(current)
		local stored = gifts.Outgoing[itemKey]

		if typeof(stored) == "table" and stored.ConsumedBy == nil and stored.State == "Prompt"
			and (at == nil or stored.At == at) then
			gifts.Outgoing[itemKey] = nil
		end

		return gifts
	end)
end

--[=[
	Whether Roblox lets these two users text each other (chat settings and parental
	controls). A free-text note from one user to another is direct communication,
	so it is gated like a private message. Any error counts as "no".
]=]
local function canMessage(sender : Player, recipientId : number) : boolean
	local ok, allowed = pcall(function()
		if not TextChatService:CanUserChatAsync(sender.UserId) then
			return false
		end

		local direct = TextChatService:CanUsersDirectChatAsync(sender.UserId, { recipientId })
		return typeof(direct) == "table" and table.find(direct, recipientId) ~= nil
	end)

	return ok and allowed == true
end

--[=[
	The message, cut and filtered for the recipient. `nil` for an empty or
	unfilterable message, or when the two users may not text each other: a gift
	without a note beats a gift with text that should not reach them.
]=]
local function filterMessage(sender : Player, recipientId : number, text : any) : string?
	if typeof(text) ~= "string" or text == "" or not utf8.len(text) then
		return nil
	end

	if not canMessage(sender, recipientId) then
		return nil
	end

	local cut = utf8.offset(text, GiftConfig.MAX_MESSAGE_LENGTH + 1)
	if cut then
		text = string.sub(text, 1, cut - 1)
	end

	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, sender.UserId, Enum.TextFilterContext.PrivateChat)
		return filtered:GetNonChatStringForUserAsync(recipientId)
	end)

	if ok and typeof(result) == "string" and result ~= "" then
		return result
	end

	return nil
end

--[[ RECIPIENT SIDE ]]

--[=[
	The ProfileStore message handlers. They only put the gift in the inbox (same
	rules as `ProfileEditService:ApplyMessage*`: a message of another kind passes
	through untouched, and a handled one is marked processed).
]=]
function GiftService:ApplyMessage(data : any, message : any, processed : () -> ()) : boolean
	if typeof(message) ~= "table" or message.Kind ~= MESSAGE_KIND then
		return false
	end

	local gift = message.Gift
	if not validGift(gift) then
		log:Warn("invalid gift message discarded.")
		processed()
		return false
	end

	data.Gifts = shaped(data.Gifts)
	appendTo(data.Gifts, gift)
	processed()

	return true
end

function GiftService:ApplyMessageToPlayer(player : Player, message : any, processed : () -> ())
	if typeof(message) ~= "table" or message.Kind ~= MESSAGE_KIND then
		return
	end

	-- Started too early to have DataService: leave the message unprocessed, it comes back.
	local dataService = self.Services.DataService
	if not dataService or not dataService.Update then
		return
	end

	local gift = message.Gift
	if not validGift(gift) then
		log:Warn("invalid gift message discarded.")
		processed()
		return
	end

	dataService:Update(player, "Gifts", function(current)
		local gifts = shaped(current)
		appendTo(gifts, gift)
		return gifts
	end)
	processed()

	self:Deliver(player)
end

--[=[
	Claims one inbox entry. Returns `false` when it could not (retried later), `true`
	when it paid out or there was nothing to claim. Nothing in here yields.
]=]
function GiftService:_claim(player : Player, giftId : string) : boolean
	local dataService = self.Services.DataService
	local data = self:_data(player)
	local entry = data and data.Gifts and data.Gifts.Inbox and data.Gifts.Inbox[giftId]
	if typeof(entry) ~= "table" then
		return true
	end

	-- Only the payout is checked, not the gift product: a gift already paid for
	-- still pays out after its product is turned off.
	local item = GiftConfig.ITEMS[entry.ItemKey]
	local problem = GiftConfig.payoutProblem(item)
	if problem then
		log:Warn(`gift {giftId} ({tostring(entry.ItemKey)}) stays in the inbox: {problem}.`)
		return false
	end

	local duplicate = false
	local coins = 0
	local passKey : string? = nil

	if item.Kind == "Pass" then
		local gifted = typeof(data.GiftedPasses) == "table" and data.GiftedPasses or {}
		duplicate = GamepassConfig.owns(data, item.Pass) or gifted[item.Pass] ~= nil

		if duplicate then
			-- They already have it: coins instead, and no gift record (what they
			-- already own stays the only claim to the pass).
			coins = tonumber(Config.DUPLICATE_COINS[item.Pass]) or 0

			if coins > 0 then
				local currency = self.Services.CurrencyService
				if not currency or not currency.Apply then
					return false
				end

				local _, updated = currency:Apply(player, "Cash", "add", coins)
				if updated == nil then
					return false
				end
			else
				log:Warn(`gift {giftId}: {player.Name} already owns {item.Pass} and DUPLICATE_COINS pays nothing for it.`)
			end
		else
			passKey = item.Pass

			dataService:Update(player, "GiftedPasses", function(current)
				local copy = table.clone(typeof(current) == "table" and current or {})
				copy[passKey] = copy[passKey] or giftId
				return copy
			end)

			-- Shows up now; the recalibrate below re-asks Roblox and rewrites the same
			-- thing with the chat tag attribute.
			dataService:Update(player, "Gamepasses", function(current)
				local copy = table.clone(typeof(current) == "table" and current or {})
				copy[passKey] = true
				return copy
			end)
		end
	else
		local pack = RobuxShopConfig.packOfProduct(item.Pack)
		local robuxShop = self.Services.RobuxShopService
		if not pack or not robuxShop or not robuxShop.Grant or not robuxShop:Grant(player, pack) then
			return false
		end
	end

	local now = os.time()
	dataService:Update(player, "Gifts", function(current)
		local gifts = shaped(current)

		gifts.Inbox[giftId] = nil
		gifts.Received[giftId] = now
		pruneOldest(gifts.Received, Config.RECEIVED_CAP)

		local seen = entryOf(entry)
		seen.At = now
		seen.Duplicate = duplicate
		seen.Coins = coins > 0 and coins or nil
		gifts.Unseen[giftId] = seen
		pruneOldest(gifts.Unseen, Config.UNSEEN_CAP)

		return gifts
	end)

	if passKey then
		local monetization = self.Services.MonetizationService
		if monetization and monetization.RecalibratePasses then
			task.spawn(function()
				monetization:RecalibratePasses(player)
			end)
		end
	end

	Framework:Fire(EVENTS.Notify, player, {
		Type = "Received",
		GiftId = giftId,
		ItemKey = entry.ItemKey,
		SenderId = entry.SenderId,
		SenderName = entry.SenderName,
		Message = entry.Message,
		Duplicate = duplicate,
		Coins = coins > 0 and coins or nil,
	})

	return true
end

--- Claims the whole inbox once. Returns how many could not be claimed.
function GiftService:_claimAll(player : Player) : number
	local data = self:_data(player)
	local inbox = data and data.Gifts and data.Gifts.Inbox
	if typeof(inbox) ~= "table" then
		return 0
	end

	local ids = {}
	for id, entry in inbox do
		if typeof(entry) == "table" then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a, b)
		local ea, eb = inbox[a], inbox[b]
		if ea.At ~= eb.At then
			return ea.At < eb.At
		end

		return a < b
	end)

	local failures = 0
	for _, id in ids do
		if not self:_data(player) then
			break
		end

		if not self:_claim(player, id) then
			failures += 1
		end
	end

	return failures
end

--[=[
	Claims what is waiting for this player: on join, when a gift arrives, and for
	retries. One run per player at a time; a call during a run asks for another
	pass. `DataService:Get` waits for the profile and, in the Lobby, for the client,
	so the notification is not fired at a client that has not loaded.
]=]
function GiftService:Deliver(player : Player)
	self.Services.DataService:Get(player, function()
		if self.Delivering[player] then
			self.Dirty[player] = true
			return
		end
		self.Delivering[player] = true

		task.spawn(function()
			local attempts = 0

			repeat
				self.Dirty[player] = nil
				attempts += 1

				local failures = self:_claimAll(player)
				if failures > 0 and attempts < Config.DELIVER_MAX_ATTEMPTS and player.Parent then
					task.wait(Config.DELIVER_RETRY_DELAY)
					self.Dirty[player] = true
				end
			until not self.Dirty[player] or not player.Parent

			self.Delivering[player] = nil
		end)
	end)
end

--[[ BUYER SIDE ]]

--[=[
	Sends a gift to `recipientId`. Returns `(true)` when it is stored (or queued
	durably), or `(false, reason)`: `NoProfile` means it can never be delivered
	there, `ServiceUnavailable` means try again.
]=]
function GiftService:_route(recipientId : number, gift : any) : (boolean, string?)
	local dataService = self.Services.DataService

	-- 1. On this server, with an open profile.
	local recipient = Players:GetPlayerByUserId(recipientId)
	if recipient and dataService.Profiles[recipient] then
		dataService:Update(recipient, "Gifts", function(current)
			local gifts = shaped(current)
			appendTo(gifts, gift)
			return gifts
		end)
		self:Deliver(recipient)

		-- The receipt only saves the BUYER: without this, a crash before the
		-- recipient's autosave would lose a gift the buyer's profile says was paid
		-- out. On `false` the receipt comes back, and the redelivery is a no-op.
		if not dataService:Save(recipient) then
			return false, "ServiceUnavailable"
		end

		return true
	end

	-- 2. Everywhere else, by message: another server, offline, or still loading.
	local store = dataService.Packages.ProfileManager
	local profileKey = "Player_" .. recipientId

	local okRead, snapshot = pcall(store.GetAsync, store, profileKey)
	if not okRead then
		return false, "ServiceUnavailable"
	end
	if not snapshot then
		return false, "NoProfile"
	end

	local okSend, sent = pcall(store.MessageAsync, store, profileKey, { Kind = MESSAGE_KIND, Gift = gift })
	if not okSend or not sent then
		return false, "ServiceUnavailable"
	end

	-- No session anywhere: open one just to consume the message. Not awaited: the
	-- message is already queued, so the receipt must not wait on this.
	if not snapshot.Session then
		task.spawn(function()
			self:_consumeOffline(recipientId)
		end)
	end

	return true
end

--[=[
	Same short session as `ProfileEditService:_consumeOffline`, applying gift
	messages. Marks `OfflineSessions` so a player joining here waits for it, and
	skips when the editor's session is already open on that key.
]=]
function GiftService:_consumeOffline(userId : number)
	local dataService = self.Services.DataService
	local store = dataService.Packages.ProfileManager
	local profileKey = "Player_" .. userId

	if Players:GetPlayerByUserId(userId) or dataService.OfflineSessions[userId] then
		return
	end

	dataService.OfflineSessions[userId] = true

	local ok, err = pcall(function()
		local deadline = os.clock() + Config.OFFLINE_SESSION_TIMEOUT
		local session = store:StartSessionAsync(profileKey, {
			Cancel = function()
				return os.clock() > deadline
			end,
		})
		if not session then
			return
		end

		session:MessageHandler(function(message, processed)
			self:ApplyMessage(session.Data, message, processed)
		end)

		session:EndSession()
	end)

	dataService.OfflineSessions[userId] = nil

	if not ok then
		log:Warn(`short session for {profileKey} failed: {tostring(err)}`)
	end
end

--[=[
	The receipt of a gift product, called by `MonetizationService`. `false` makes
	the receipt come back later; it is safe to run twice for the same purchase.
]=]
function GiftService:_onPurchase(itemKey : string, player : Player, receiptInfo : any) : boolean
	local dataService = self.Services.DataService

	local data = self:_data(player)
	if not data then
		return false
	end

	local giftId = tostring(receiptInfo.PurchaseId)

	local outgoing = data.Gifts and data.Gifts.Outgoing
	local intent = typeof(outgoing) == "table" and outgoing[itemKey] or nil

	local usable = typeof(intent) == "table"
		and typeof(intent.RecipientId) == "number"
		and (intent.ConsumedBy == nil or intent.ConsumedBy == giftId)

	local recipientId = player.UserId
	local message = nil
	if usable then
		recipientId = intent.RecipientId
		message = intent.Message
	else
		-- Nothing to go on, and the player did pay: they keep what they bought.
		log:Warn(`no usable intent for purchase {giftId} ({itemKey}) from {player.Name}; granting it to the buyer.`)
	end

	local gift = {
		Id = giftId,
		ItemKey = itemKey,
		SenderId = player.UserId,
		SenderName = player.DisplayName,
		Message = message,
		At = os.time(),
	}

	local routed, reason = self:_route(recipientId, gift)
	if not routed and reason == "NoProfile" and recipientId ~= player.UserId then
		log:Warn(`recipient {recipientId} has no profile; granting purchase {giftId} to the buyer.`)
		recipientId = player.UserId
		routed = self:_route(recipientId, gift)
	end
	if not routed then
		return false
	end

	if usable and intent.ConsumedBy == nil then
		dataService:Update(player, "Gifts", function(current)
			local gifts = shaped(current)
			local stored = gifts.Outgoing[itemKey]
			if typeof(stored) == "table" and stored.ConsumedBy == nil then
				stored.ConsumedBy = giftId
			end
			return gifts
		end)
	end

	Framework:Fire(EVENTS.Notify, player, {
		Type = "Sent",
		GiftId = giftId,
		ItemKey = itemKey,
		RecipientId = recipientId,
		RecipientName = usable and intent.RecipientName or nil,
	})

	return true
end

--[[ REQUESTS ]]

--[=[
	What the buyer needs to know about a recipient: `{ UserId, Username, Owned,
	Pending, InboxCount }`, with `Owned` and `Pending` as `{ [itemKey] = true }`
	(passes only). Works for offline players. Returns `nil, reason` otherwise.

	With `onlyItemKey`, only that pass is asked of Roblox, and a failed web call
	is an error (a purchase decision rests on it). Without it, a failed call just
	leaves the pass unmarked (it is a display).
]=]
function GiftService:GetRecipientStatus(userId : number, onlyItemKey : string?) : (any?, string?)
	local dataService = self.Services.DataService

	local okName, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if not okName or typeof(name) ~= "string" then
		return nil, "RecipientNotFound"
	end

	local data
	local profile -- whatever holds the message queue: the open session or the snapshot
	local here = Players:GetPlayerByUserId(userId)
	local entry = here and dataService.Profiles[here]
	if entry then
		data = entry.Profile.Data
		profile = entry.Session
	else
		local store = dataService.Packages.ProfileManager
		local okRead, snapshot = pcall(store.GetAsync, store, "Player_" .. userId)
		if not okRead then
			return nil, "ServiceUnavailable"
		end
		if not snapshot then
			return nil, "RecipientNoProfile"
		end
		data = snapshot.Data
		profile = snapshot
	end
	data = typeof(data) == "table" and data or {}

	local gifts = typeof(data.Gifts) == "table" and data.Gifts or {}
	local inbox = typeof(gifts.Inbox) == "table" and gifts.Inbox or {}
	local received = typeof(gifts.Received) == "table" and gifts.Received or {}
	local gifted = typeof(data.GiftedPasses) == "table" and data.GiftedPasses or {}

	--[[
		Waiting = in the inbox, or still in the message queue (sent from another
		server and not applied yet: the recipient is elsewhere, or offline and the
		short session has not run). By id, so a message already applied but not yet
		cleared from the queue is not counted twice.
	]]
	local waiting = {} -- [giftId] = itemKey
	for id, gift in inbox do
		if typeof(gift) == "table" and typeof(gift.ItemKey) == "string" then
			waiting[id] = gift.ItemKey
		end
	end
	for _, gift in queuedGifts(profile) do
		if waiting[gift.Id] == nil and received[gift.Id] == nil then
			waiting[gift.Id] = gift.ItemKey
		end
	end

	local status = {
		UserId = userId,
		Username = name,
		Owned = {},
		Pending = {},
		InboxCount = countKeys(waiting),
	}

	for _, itemKey in waiting do
		status.Pending[itemKey] = true
	end

	for itemKey, item in GiftConfig.ITEMS do
		if item.Kind ~= "Pass" or not GiftConfig.isEnabled(item) then
			continue
		end
		if onlyItemKey and itemKey ~= onlyItemKey then
			continue
		end

		if GamepassConfig.owns(data, item.Pass) or gifted[item.Pass] ~= nil then
			status.Owned[itemKey] = true
			continue
		end

		local pass = GamepassConfig.PASSES[item.Pass]
		local okOwns, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, userId, pass.Id)
		if okOwns then
			if owns then
				status.Owned[itemKey] = true
			end
		elseif onlyItemKey then
			return nil, "ServiceUnavailable"
		end
	end

	return status
end

--- Everything after the cheap checks of `RequestGift`; may yield.
function GiftService:_prepare(player : Player, recipientId : number, itemKey : string, item : any, rawMessage : any) : (boolean, string?)
	local dataService = self.Services.DataService

	if Config.FRIENDS_ONLY then
		local ok, friends = pcall(player.IsFriendsWith, player, recipientId)
		if not ok then
			return false, "ServiceUnavailable"
		end
		if not friends then
			return false, "NotFriends"
		end
	end

	local status, reason = self:GetRecipientStatus(recipientId, itemKey)
	if not status then
		return false, reason
	end

	if status.InboxCount >= Config.MAX_INBOX then
		return false, "InboxFull"
	end
	if item.Kind == "Pass" then
		if status.Owned[itemKey] then
			return false, "AlreadyOwns"
		end
		if status.Pending[itemKey] then
			return false, "AlreadyPending"
		end
	end

	local message = filterMessage(player, recipientId, rawMessage)

	-- Everything above yielded: the buyer may be gone, or a receipt or a prompt
	-- answer may have changed the intent in the meantime.
	if player.Parent ~= Players or not self:_data(player) then
		return false, "Left"
	end
	if intentBusy(self:_intentOf(player, itemKey), os.time()) then
		return false, "PurchasePending"
	end

	local at = os.time()
	dataService:Update(player, "Gifts", function(current)
		local gifts = shaped(current)
		gifts.Outgoing[itemKey] = {
			RecipientId = recipientId,
			RecipientName = status.Username,
			Message = message,
			At = at,
			State = "Prompt",
		}
		return gifts
	end)

	-- The prompt only opens once the intent is on disk: a crash between the
	-- purchase and the next save would otherwise leave a receipt with no recipient.
	-- No prompt opens on failure, so the intent goes too (it would only lock).
	if not dataService:Save(player) then
		self:_dropIntent(player, itemKey, at)
		return false, "ServiceUnavailable"
	end
	if player.Parent ~= Players then
		return false, "Left"
	end

	MarketplaceService:PromptProductPurchase(player, item.ProductId)

	return true
end

--[=[
	Validates a gift and opens the purchase prompt. `true` means the prompt is
	open, not that the gift is done. Yields.

	Reasons: `Cooldown`, `Busy`, `UnknownItem`, `InvalidRecipient`, `SelfGift`,
	`NotLoaded`, `PurchasePending`, `NotFriends`, `RecipientNotFound`,
	`RecipientNoProfile`, `AlreadyOwns`, `AlreadyPending`, `InboxFull`, `Left`,
	`ServiceUnavailable`, `ServerError`.

	`PurchasePending`: this buyer's previous gift of the same item is still open
	(prompt not answered) or bought and not paid out yet.
]=]
function GiftService:RequestGift(player : Player, recipientId : any, itemKey : any, rawMessage : any) : (boolean, string?)
	if self.Busy[player] then
		return false, "Busy"
	end

	local now = os.clock()
	local last = self.LastRequest[player]
	if last and now - last < Config.REQUEST_COOLDOWN then
		return false, "Cooldown"
	end
	self.LastRequest[player] = now

	local item = typeof(itemKey) == "string" and GiftConfig.ITEMS[itemKey] or nil
	if not item or not GiftConfig.isEnabled(item) then
		return false, "UnknownItem"
	end

	if typeof(recipientId) ~= "number" or recipientId ~= recipientId or recipientId % 1 ~= 0 or recipientId <= 0 then
		return false, "InvalidRecipient"
	end
	if recipientId == player.UserId then
		return false, "SelfGift"
	end
	if not self:_data(player) then
		return false, "NotLoaded"
	end
	if intentBusy(self:_intentOf(player, itemKey), os.time()) then
		return false, "PurchasePending"
	end

	self.Busy[player] = true
	local ok, success, reason = pcall(self._prepare, self, player, recipientId, itemKey, item, rawMessage)
	self.Busy[player] = nil

	if not ok then
		log:Warn(`RequestGift failed for {player.Name}: {tostring(success)}`)
		return false, "ServerError"
	end

	return success, reason
end

--[=[
	`GetRecipientStatus` for the lookup (a display, never a purchase decision:
	`RequestGift` asks again). A recent answer for the same recipient is reused, and
	a recipient off this server (one DataStore read each) is refused while the
	server's GetAsync budget is low, so lookups never compete with profile loads and
	saves. The cooldown alone does not cover that: each new name is a new read.
]=]
function GiftService:_lookupStatus(userId : number) : (any?, string?)
	local cached = self.LookupCache[userId]
	if cached and os.clock() - cached.At < Config.LOOKUP_CACHE_SECONDS then
		return cached.Status
	end

	if not Players:GetPlayerByUserId(userId) then
		local ok, budget = pcall(DataStoreService.GetRequestBudgetForRequestType, DataStoreService, Enum.DataStoreRequestType.GetAsync)
		if ok and typeof(budget) == "number" and budget < Config.LOOKUP_MIN_BUDGET then
			return nil, "ServiceUnavailable"
		end
	end

	local status, reason = self:GetRecipientStatus(userId)
	if not status then
		return nil, reason
	end

	local now = os.clock()
	for id, old in self.LookupCache do
		if now - old.At >= Config.LOOKUP_CACHE_SECONDS then
			self.LookupCache[id] = nil
		end
	end
	self.LookupCache[userId] = { At = now, Status = status }

	return status
end

--- A username or a UserId from the client, as a UserId, or `nil, reason`.
local function resolveQuery(query : any) : (number?, string?)
	if typeof(query) == "number" then
		if query == query and query % 1 == 0 and query > 0 then
			return query
		end

		return nil, "RecipientNotFound"
	end

	if typeof(query) == "string" and #query >= 3 and #query <= 20 and string.match(query, "^[%w_]+$") then
		local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, query)
		if ok and typeof(id) == "number" then
			return id
		end
	end

	return nil, "RecipientNotFound"
end

--[[ LIFECYCLE ]]

function GiftService:construct()
	local dataService = self.Services.DataService
	local monetization = self.Services.MonetizationService

	-- [gift ProductId] = itemKey
	local itemOfProduct = {}

	-- Each gift product pays through the same receipt path as every other product.
	for itemKey, item in GiftConfig.ITEMS do
		local problem = GiftConfig.problem(item)
		if problem then
			log:Warn(`gift item '{itemKey}' disabled: {problem}.`)
			continue
		end

		itemOfProduct[item.ProductId] = itemKey
		monetization:RegisterProduct(item.ProductId, function(player : Player, receiptInfo : any)
			return self:_onPurchase(itemKey, player, receiptInfo)
		end)
	end

	--[[
		Roblox's answer to a gift prompt. It pays nothing (the receipt does): it only
		settles the intent's lock. A closed prompt frees the intent at once, so a
		cancelled gift neither blocks the next one nor waits around for a purchase
		made some other way. A bought one stays locked until its receipt consumes it.
	]]
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId : number, productId : number, isPurchased : boolean)
		local itemKey = itemOfProduct[productId]
		local player = itemKey and Players:GetPlayerByUserId(userId)
		if not player or not self:_data(player) then
			return
		end

		if not isPurchased then
			self:_dropIntent(player, itemKey)
			return
		end

		dataService:Update(player, "Gifts", function(current)
			local gifts = shaped(current)
			local stored = gifts.Outgoing[itemKey]
			if typeof(stored) == "table" and stored.ConsumedBy == nil then
				stored.State = "Paid"
				stored.PaidAt = os.time()
			end
			return gifts
		end)
	end)

	Framework:Listen(EVENTS.Request, function(player : Player, requestId : any, recipientId : any, itemKey : any, message : any)
		if typeof(requestId) ~= "number" then
			return
		end

		local success, reason = self:RequestGift(player, recipientId, itemKey, message)
		if not player.Parent then
			return
		end

		Framework:Fire(EVENTS.RequestResult, player, {
			Id = requestId,
			Success = success,
			Reason = reason,
		})
	end)

	Framework:Listen(EVENTS.Lookup, function(player : Player, requestId : any, query : any)
		if typeof(requestId) ~= "number" then
			return
		end

		local function answer(payload : any)
			if player.Parent then
				payload.Id = requestId
				Framework:Fire(EVENTS.LookupResult, player, payload)
			end
		end

		local now = os.clock()
		local last = self.LastLookup[player]
		if last and now - last < Config.LOOKUP_COOLDOWN then
			answer({ Success = false, Reason = "Cooldown" })
			return
		end
		self.LastLookup[player] = now

		local userId, reason = resolveQuery(query)
		if not userId then
			answer({ Success = false, Reason = reason })
			return
		end

		local status, statusReason = self:_lookupStatus(userId)
		if not status then
			answer({ Success = false, Reason = statusReason })
			return
		end

		answer({
			Success = true,
			UserId = status.UserId,
			Username = status.Username,
			Owned = status.Owned,
			Pending = status.Pending,
		})
	end)

	-- The client clears the toasts it has shown: one id, or nil for all.
	Framework:Listen(EVENTS.Seen, function(player : Player, giftId : any)
		if giftId ~= nil and typeof(giftId) ~= "string" then
			return
		end
		if not self:_data(player) then
			return
		end

		dataService:Update(player, "Gifts", function(current)
			local gifts = shaped(current)
			if giftId == nil then
				gifts.Unseen = {}
			else
				gifts.Unseen[giftId] = nil
			end
			return gifts
		end)
	end)

	-- Whatever is already waiting when the profile opens (offline gifts, failed claims).
	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:Deliver(player)
	end)
	for _, player in Players:GetPlayers() do
		self:Deliver(player)
	end

	Players.PlayerRemoving:Connect(function(player : Player)
		self.LastRequest[player] = nil
		self.LastLookup[player] = nil
		self.Busy[player] = nil
		self.Delivering[player] = nil
		self.Dirty[player] = nil
	end)
end

function GiftService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function GiftService:init()
	-- Only the server fires these; without the empty Listen the client would wait
	-- ten seconds for the identifier (see docs/architecture/me-framework.md).
	Framework:Listen(EVENTS.RequestResult, function() end)
	Framework:Listen(EVENTS.LookupResult, function() end)
	Framework:Listen(EVENTS.Notify, function() end)
end

return GiftService