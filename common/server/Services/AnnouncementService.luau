local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MessagingService = game:GetService("MessagingService")
local TextService = game:GetService("TextService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("AnnouncementService")

local TOPIC = "GlobalAnnouncement"
local MAX_LENGTH = 200
local COOLDOWN = 5
local FILTER_MESSAGES = true

local AnnouncementService = {
	Services = {},
}

AnnouncementService.LastSent = 0
AnnouncementService.Subscribed = false

function AnnouncementService:Deliver(username : string, userId : number, message : string)
	for _, player in Players:GetPlayers() do
		Framework:Fire("GlobalAnnouncement", player, username, userId, message)
	end
end

function AnnouncementService:Broadcast(username : string, userId : number, message : string) : (boolean, string)
	message = string.gsub(message, "^%s+", "")
	message = string.gsub(message, "%s+$", "")

	if message == "" then
		return false, "Message is empty."
	end

	local length = utf8.len(message)
	if not length then
		return false, "Message has invalid characters."
	end

	if length > MAX_LENGTH then
		message = string.sub(message, 1, utf8.offset(message, MAX_LENGTH + 1) - 1)
	end

	local remaining = COOLDOWN - (os.clock() - self.LastSent)
	if remaining > 0 then
		return false, string.format("Wait %.0f more second(s).", math.ceil(remaining))
	end

	if FILTER_MESSAGES then
		local success, filtered = pcall(function()
			local result = TextService:FilterStringAsync(message, userId)

			return result:GetNonChatStringForBroadcastAsync()
		end)

		if not success then
			log:Warn(`filter failed: {filtered}`)

			return false, "Could not filter the message."
		end

		message = filtered
	end

	self.LastSent = os.clock()

	local payload = { Username = username, UserId = userId, Message = message }

	local published = pcall(MessagingService.PublishAsync, MessagingService, TOPIC, payload)

	if not (published and self.Subscribed) then
		self:Deliver(username, userId, message)
	end

	if published then
		return true, "Announcement sent to all servers."
	end

	return true, "Cross-server publish failed; delivered to this server only."
end

function AnnouncementService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	task.spawn(function()
		local success, err = pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function(packet)
				local data = packet.Data

				if typeof(data) ~= "table" then return end
				if typeof(data.Username) ~= "string" or typeof(data.Message) ~= "string" then return end
				if typeof(data.UserId) ~= "number" then return end

				self:Deliver(data.Username, data.UserId, data.Message)
			end)
		end)

		if success then
			self.Subscribed = true
		else
			log:Warn(`could not subscribe to {TOPIC}: {err}`)
		end
	end)
end

function AnnouncementService:init()
	Framework:Listen("GlobalAnnouncement", function() end)
end

return AnnouncementService