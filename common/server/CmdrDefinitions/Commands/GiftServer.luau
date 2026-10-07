local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor:WaitForChild("Me"))
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local Environment = require(Shared.Util.Environment)

local GiftConfig = SharedConfig.GiftConfig
local GamepassConfig = SharedConfig.GamepassConfig
local RobuxShopConfig = SharedConfig.RobuxShopConfig

local Framework = Me.new()

local TAG = "[GiftTest]"
local WAIT_TIMEOUT = 10
local OFFLINE_POLL_TIMEOUT = 20
local OFFLINE_POLL_INTERVAL = 2
local GIFT_TABLES = { "Inbox", "Received", "Outgoing", "Unseen" }

local counter = 0

local function countKeys(map : any) : number
	if typeof(map) ~= "table" then
		return 0
	end

	local count = 0
	for _ in map do
		count += 1
	end

	return count
end

local function nameOf(userId : number) : string
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.Name
	end

	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)

	return ok and name or "unknown"
end

local function snapshotOf(giftService : any, player : Player, item : any) : any
	local data = giftService:_data(player)
	if not data then
		return nil
	end

	local gifts = typeof(data.Gifts) == "table" and data.Gifts or {}
	local gifted = typeof(data.GiftedPasses) == "table" and data.GiftedPasses or {}
	local stats = typeof(data.Stats) == "table" and data.Stats or {}
	local isPass = item.Kind == "Pass"

	return {
		Inbox = countKeys(gifts.Inbox),
		Received = countKeys(gifts.Received),
		Unseen = countKeys(gifts.Unseen),
		Cash = tonumber(stats.Cash) or 0,
		Owns = isPass and GamepassConfig.owns(data, item.Pass) or false,
		GiftedId = isPass and gifted[item.Pass] or nil,
	}
end

return function(context, userIds : { number }, itemKey : string)
	local sender = context.Executor
	if not sender then
		return "Run this command as a player."
	end

	if not (Environment.IsQA() or RunService:IsStudio()) then
		return "gift is a test command: QA and Studio only."
	end

	local GiftService = Framework:Get("GiftService", false, true)
	local DataService = Framework:Get("DataService", false, true)

	local item = GiftConfig.ITEMS[itemKey]
	local problem = GiftConfig.problem(item)
	if problem then
		return `'{itemKey}' cannot be gifted: {problem}.`
	end

	if not GiftService:_data(sender) then
		return "Your profile is not loaded yet."
	end

	local isPass = item.Kind == "Pass"
	local pack = (not isPass) and RobuxShopConfig.packOfProduct(item.Pack) or nil
	local displayName = GiftConfig.displayName(itemKey) or itemKey

	local summary = {}

	for _, recipientId in userIds do
		counter += 1

		local giftId = `TEST_{sender.UserId}_{os.time()}_{counter}`
		local recipientName = nameOf(recipientId)
		local startedAt = os.clock()

		local passed = 0
		local failed = 0

		local function check(label : string, ok : boolean, detail : string)
			if ok then
				passed += 1
				print(`{TAG} [PASS] {label}: {detail}`)
			else
				failed += 1
				warn(`{TAG} [FAIL] {label}: {detail}`)
			end
		end

		print(`{TAG} =============================================`)
		print(`{TAG} GIFT TEST #{counter}`)
		print(`{TAG} SENDER      : {sender.Name} (UserId {sender.UserId}, display "{sender.DisplayName}")`)
		print(`{TAG} RECIPIENT   : {recipientName} (UserId {recipientId})`)
		print(`{TAG} PRODUCT     : {itemKey} -> "{displayName}"`)
		print(`{TAG} KIND        : {item.Kind}{isPass and ` (pass key {item.Pass}, pass id {GamepassConfig.PASSES[item.Pass].Id})` or ` ({pack and pack.Coins or "?"} coins, pack product {tostring(item.Pack)})`}`)
		print(`{TAG} GIFT PRODUCT: {item.ProductId}`)
		print(`{TAG} GIFT ID     : {giftId}`)

		if recipientId == sender.UserId then
			warn(`{TAG} sender and recipient are the same player (the real flow refuses SelfGift).`)
		end

		local status, reason = GiftService:GetRecipientStatus(recipientId, itemKey)
		if not status then
			check("recipient lookup", false, `GetRecipientStatus returned '{tostring(reason)}'`)
			print(`{TAG} RESULT      : FAILED ({passed} passed, {failed} failed)`)
			table.insert(summary, `{recipientName}: FAILED (recipient lookup: {tostring(reason)})`)
			continue
		end

		check("recipient lookup", true, `{status.Username}, inbox {status.InboxCount}, owns {itemKey}: {tostring(status.Owned[itemKey] == true)}, pending {itemKey}: {tostring(status.Pending[itemKey] == true)}`)

		if status.Owned[itemKey] then
			warn(`{TAG} recipient already owns this pass (real flow would refuse AlreadyOwns; delivery will be flagged Duplicate).`)
		end
		if status.Pending[itemKey] then
			warn(`{TAG} recipient already has this gift pending (real flow would refuse AlreadyPending).`)
		end

		local recipient = Players:GetPlayerByUserId(recipientId)
		local senderBefore = snapshotOf(GiftService, sender, item)
		local recipientBefore = recipient and snapshotOf(GiftService, recipient, item) or nil

		print(`{TAG} ---- BEFORE ----`)
		print(`{TAG} sender    : inbox {senderBefore.Inbox}, received {senderBefore.Received}, cash {senderBefore.Cash}`)
		if recipientBefore then
			print(`{TAG} recipient : inbox {recipientBefore.Inbox}, received {recipientBefore.Received}, cash {recipientBefore.Cash}, owns pass {tostring(recipientBefore.Owns)}, gifted pass id {tostring(recipientBefore.GiftedId)}`)
		else
			print(`{TAG} recipient : not on this server (inbox {status.InboxCount} from profile read)`)
		end

		DataService:Update(sender, "Gifts", function(current)
			local gifts = typeof(current) == "table" and current or {}

			for _, name in GIFT_TABLES do
				if typeof(gifts[name]) ~= "table" then
					gifts[name] = {}
				end
			end

			gifts.Outgoing[itemKey] = {
				RecipientId = recipientId,
				RecipientName = recipientName,
				Message = "Test gift",
				At = os.time(),
			}

			return gifts
		end)

		local senderData = GiftService:_data(sender)
		local intent = senderData and senderData.Gifts and senderData.Gifts.Outgoing and senderData.Gifts.Outgoing[itemKey]
		check(
			"sender intent written",
			typeof(intent) == "table" and intent.RecipientId == recipientId,
			`Outgoing.{itemKey} -> RecipientId {typeof(intent) == "table" and tostring(intent.RecipientId) or "nil"} (expected {recipientId})`
		)

		print(`{TAG} calling GiftService:_onPurchase with fake PurchaseId {giftId} ...`)
		local ok, routed = pcall(GiftService._onPurchase, GiftService, itemKey, sender, { PurchaseId = giftId })

		if not ok then
			check("receipt handler", false, `error: {tostring(routed)}`)
			print(`{TAG} RESULT      : FAILED ({passed} passed, {failed} failed)`)
			table.insert(summary, `{recipientName}: FAILED (error in _onPurchase)`)
			continue
		end

		check("receipt handler", routed == true, `_onPurchase returned {tostring(routed)} (true = gift routed, false = receipt would be retried)`)
		if not routed then
			print(`{TAG} RESULT      : FAILED ({passed} passed, {failed} failed)`)
			table.insert(summary, `{recipientName}: FAILED (not routed)`)
			continue
		end

		senderData = GiftService:_data(sender)
		local storedIntent = senderData and senderData.Gifts and senderData.Gifts.Outgoing and senderData.Gifts.Outgoing[itemKey]
		check(
			"intent consumed",
			typeof(storedIntent) == "table" and storedIntent.ConsumedBy == giftId,
			`Outgoing.{itemKey}.ConsumedBy = {typeof(storedIntent) == "table" and tostring(storedIntent.ConsumedBy) or "nil"} (expected {giftId})`
		)

		print(`{TAG} ROUTED      : {sender.Name} -> {recipientName} ({recipient and "same server" or "other server / offline, sent by message"})`)

		if recipient then
			local delivered = false
			local deadline = os.clock() + WAIT_TIMEOUT

			while os.clock() < deadline do
				local data = GiftService:_data(recipient)
				if data and data.Gifts and data.Gifts.Received and data.Gifts.Received[giftId] then
					delivered = true
					break
				end

				task.wait(0.25)
			end

			check(
				"claimed by recipient",
				delivered,
				delivered and `Received[{giftId}] present after {string.format("%.2f", os.clock() - startedAt)}s` or `not in Received after {WAIT_TIMEOUT}s (still in inbox or claim failing)`
			)

			local recipientAfter = snapshotOf(GiftService, recipient, item)
			local recipientData = GiftService:_data(recipient)
			local inboxEntry = recipientData and recipientData.Gifts and recipientData.Gifts.Inbox and recipientData.Gifts.Inbox[giftId]
			local unseenEntry = recipientData and recipientData.Gifts and recipientData.Gifts.Unseen and recipientData.Gifts.Unseen[giftId]

			check("inbox cleared", inboxEntry == nil, inboxEntry == nil and "gift id no longer in Inbox" or "gift id still in Inbox")

			if recipientAfter then
				print(`{TAG} ---- AFTER ----`)
				print(`{TAG} recipient : inbox {recipientAfter.Inbox}, received {recipientAfter.Received}, cash {recipientAfter.Cash}, owns pass {tostring(recipientAfter.Owns)}, gifted pass id {tostring(recipientAfter.GiftedId)}`)

				if isPass then
					check("pass granted", recipientAfter.Owns == true, `Gamepasses.{item.Pass} = {tostring(recipientAfter.Owns)}`)
					check(
						"gift recorded",
						recipientAfter.GiftedId ~= nil,
						`GiftedPasses.{item.Pass} = {tostring(recipientAfter.GiftedId)}{recipientAfter.GiftedId == giftId and " (this gift)" or " (an earlier gift: this one was a duplicate)"}`
					)
				elseif pack then
					local delta = recipientAfter.Cash - (recipientBefore and recipientBefore.Cash or 0)
					check("coins granted", delta == pack.Coins, `Stats.Cash {recipientBefore and recipientBefore.Cash or "?"} -> {recipientAfter.Cash} (+{delta}, expected +{pack.Coins})`)
				end

				if recipientBefore then
					check(
						"received log",
						recipientAfter.Received > recipientBefore.Received,
						`Received count {recipientBefore.Received} -> {recipientAfter.Received}`
					)
				end
			end

			if unseenEntry then
				print(`{TAG} notification: Unseen entry present (from {tostring(unseenEntry.SenderName)}, Duplicate = {tostring(unseenEntry.Duplicate)}, Message = "{tostring(unseenEntry.Message)}")`)
			else
				print(`{TAG} notification: Unseen entry already cleared (the client acknowledged the toast) or not created`)
			end
		else
			print(`{TAG} recipient is not on this server: polling their stored profile for up to {OFFLINE_POLL_TIMEOUT}s ...`)

			local confirmed = false
			local deadline = os.clock() + OFFLINE_POLL_TIMEOUT

			while os.clock() < deadline do
				task.wait(OFFLINE_POLL_INTERVAL)

				local now = GiftService:GetRecipientStatus(recipientId, itemKey)
				if now then
					print(`{TAG} poll: inbox {now.InboxCount} (was {status.InboxCount}), pending {itemKey}: {tostring(now.Pending[itemKey] == true)}, owns {itemKey}: {tostring(now.Owned[itemKey] == true)}`)

					if now.InboxCount > status.InboxCount or now.Pending[itemKey] or (isPass and now.Owned[itemKey] and not status.Owned[itemKey]) then
						confirmed = true
						break
					end
				end
			end

			check(
				"queued for recipient",
				confirmed,
				confirmed and "gift visible in the recipient's stored profile (it claims when they next join)" or "not visible yet: inconclusive (an online recipient on another server may have already claimed it)"
			)
		end

		print(`{TAG} ---- SENDER AFTER ----`)
		local senderAfter = snapshotOf(GiftService, sender, item)
		if senderAfter then
			print(`{TAG} sender    : inbox {senderAfter.Inbox}, received {senderAfter.Received}, cash {senderAfter.Cash} (a sender never pays here: the Robux prompt is skipped)`)
		end

		local verdict = failed == 0 and "SUCCESS" or "FAILED"
		print(`{TAG} RESULT      : {verdict} | {passed} passed, {failed} failed | {sender.Name} -> {recipientName} | {itemKey} | {string.format("%.2f", os.clock() - startedAt)}s`)
		print(`{TAG} =============================================`)

		table.insert(summary, `{sender.Name} -> {recipientName}: {itemKey} {verdict} ({passed} passed, {failed} failed)`)
	end

	return table.concat(summary, "\n")
end