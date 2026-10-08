local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

local EVENT = "GiftAnnounce"
local CHANNEL = "RBXGeneral"
local WAIT_TIMEOUT = 10

local NAME_COLOR = "#FFD54A"
local ITEM_COLOR = "#7CE0FF"

local GiftChatController = {
	Controllers = {},
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

function GiftChatController:_channel() : TextChannel?
	local channels = TextChatService:WaitForChild("TextChannels", WAIT_TIMEOUT)
	local channel = channels and channels:WaitForChild(CHANNEL, WAIT_TIMEOUT)

	if channel and channel:IsA("TextChannel") then
		return channel
	end

	return nil
end

function GiftChatController:_show(buyer : string, recipient : string, item : string)
	local channel = self:_channel()
	if not channel then
		return
	end

	channel:DisplaySystemMessage(`{colored(NAME_COLOR, buyer)} gifted {colored(NAME_COLOR, recipient)} {colored(ITEM_COLOR, item)}`)
end

function GiftChatController:construct()
	Framework:Listen(EVENT, function(buyer : any, recipient : any, item : any)
		if typeof(buyer) ~= "string" or typeof(recipient) ~= "string" or typeof(item) ~= "string" then
			return
		end

		task.spawn(function()
			self:_show(buyer, recipient, item)
		end)
	end)
end

function GiftChatController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function GiftChatController:init()
end

return GiftChatController