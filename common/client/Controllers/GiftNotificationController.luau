local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local Me = require(Vendor.Me)

local Framework = Me.new()

local GiftConfig = SharedConfig.GiftConfig

local NOTIFY_EVENT = "GiftNotification"
local SEEN_EVENT = "GiftSeen"
local CHANNEL = "RBXGeneral"
local WAIT_TIMEOUT = 10

local NAME_COLOR = "#FFD54A"
local ITEM_COLOR = "#7CE0FF"
local NOTE_COLOR = "#B8B8B8"

--[[
	Tells the player about gifts that concern them, in chat, on both places.

	Received: live through `GiftNotification`, and replayed from the profile's
	`Gifts.Unseen` for gifts claimed before this client was listening (offline
	gifts, the Game place handing out the profile before the client loads). Each
	shown gift is acknowledged with `GiftSeen`, which clears it from `Unseen`.

	Sent: the buyer's confirmation, or the fallback when the gift came back to them.

	Live and replayed copies of the same gift are shown once (by gift id).
]]
local GiftNotificationController = {
	Controllers = {
		DataController = {},
	},
}

local function escape(text : string) : string
	return (string.gsub(text, "[&<>\"']", {
		["&"] = "&amp;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		["\""] = "&quot;",
		["'"] = "&apos;",
	}))
end

local function colored(color : string, text : string) : string
	return `<font color="{color}">{escape(text)}</font>`
end

local function itemName(itemKey : any) : string
	if typeof(itemKey) ~= "string" then
		return "a gift"
	end

	return GiftConfig.displayName(itemKey) or itemKey
end

function GiftNotificationController:_channel() : TextChannel?
	local channels = TextChatService:WaitForChild("TextChannels", WAIT_TIMEOUT)
	local channel = channels and channels:WaitForChild(CHANNEL, WAIT_TIMEOUT)

	if channel and channel:IsA("TextChannel") then
		return channel
	end

	return nil
end

function GiftNotificationController:_say(text : string)
	task.spawn(function()
		local channel = self:_channel()
		if channel then
			channel:DisplaySystemMessage(text)
		end
	end)
end

function GiftNotificationController:_showReceived(giftId : string, entry : any)
	if self.Shown[giftId] then
		Framework:Fire(SEEN_EVENT, giftId)
		return
	end
	self.Shown[giftId] = true

	local sender = typeof(entry.SenderName) == "string" and entry.SenderName or "Someone"
	local item = itemName(entry.ItemKey)

	if entry.Duplicate then
		local coins = tonumber(entry.Coins)
		if coins and coins > 0 then
			self:_say(`{colored(NAME_COLOR, sender)} gifted you {colored(ITEM_COLOR, item)}. You already owned it, so you got {colored(ITEM_COLOR, `{coins} Coins`)} instead.`)
		else
			self:_say(`{colored(NAME_COLOR, sender)} gifted you {colored(ITEM_COLOR, item)}, but you already owned it.`)
		end
	else
		self:_say(`{colored(NAME_COLOR, sender)} gifted you {colored(ITEM_COLOR, item)}!`)
	end

	if typeof(entry.Message) == "string" and entry.Message ~= "" then
		self:_say(`{colored(NOTE_COLOR, `"{entry.Message}"`)}`)
	end

	Framework:Fire(SEEN_EVENT, giftId)
end

function GiftNotificationController:_showSent(payload : any)
	local giftId = payload.GiftId
	if typeof(giftId) ~= "string" then
		return
	end

	local key = "Sent_" .. giftId
	if self.Shown[key] then
		return
	end
	self.Shown[key] = true

	local item = itemName(payload.ItemKey)

	if payload.RecipientId == Players.LocalPlayer.UserId then
		self:_say(`Your gift of {colored(ITEM_COLOR, item)} could not be delivered, so it was given to you instead.`)
		return
	end

	local recipient = typeof(payload.RecipientName) == "string" and payload.RecipientName or "them"
	self:_say(`Your gift of {colored(ITEM_COLOR, item)} to {colored(NAME_COLOR, recipient)} was sent!`)
end

function GiftNotificationController:_replayUnseen()
	local dataController = self.Controllers.DataController
	if not dataController then
		return
	end

	local replica = dataController:GetReplica()
	local data = replica and replica.Data
	local gifts = data and data.Gifts
	local unseen = typeof(gifts) == "table" and gifts.Unseen
	if typeof(unseen) ~= "table" then
		return
	end

	local list = {}
	for giftId, entry in unseen do
		if typeof(giftId) == "string" and typeof(entry) == "table" then
			table.insert(list, { Id = giftId, Entry = entry })
		end
	end

	table.sort(list, function(a, b)
		local at, bt = tonumber(a.Entry.At) or 0, tonumber(b.Entry.At) or 0
		if at ~= bt then
			return at < bt
		end

		return a.Id < b.Id
	end)

	for _, gift in list do
		self:_showReceived(gift.Id, gift.Entry)
	end
end

function GiftNotificationController:construct()
	Framework:Listen(NOTIFY_EVENT, function(payload : any)
		if typeof(payload) ~= "table" then
			return
		end

		if payload.Type == "Received" and typeof(payload.GiftId) == "string" then
			self:_showReceived(payload.GiftId, payload)
		elseif payload.Type == "Sent" then
			self:_showSent(payload)
		end
	end)

	task.spawn(function()
		self:_replayUnseen()
	end)
end

function GiftNotificationController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function GiftNotificationController:init()
	self.Shown = {}
end

return GiftNotificationController