local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("FriendInviteController")

local Player = Players.LocalPlayer

--[[
	The "your friend is online" notification.

	`FriendInviteService` sends `FriendInvitePrompt` with `Exclude` (friends in
	cooldown), `Preferred` (friends with history, best first), and `LaunchData`
	(the mark that lets the server tell our invites from the player's own when the
	friend joins). This controller:

	  1. asks Roblox for the online friends (`GetFriendsOnline`, client only);
	  2. drops those on this server and those in `Exclude`;
	  3. picks the first `Preferred` still eligible, or any eligible at random;
	  4. reports the pick (`FriendInviteShown`) and shows a CoreGui notification
	     with the friend's headshot, `Invite`, and `Decline`, for `DURATION`
	     seconds;
	  5. on `Invite`, reports it (`FriendInviteAnswered`) and opens Roblox's
	     invite prompt aimed at that friend, carrying `LaunchData`.

	With no eligible friend it shows nothing. One notification at a time: a
	prompt that arrives while one is on screen is ignored.

	`Invite` counts the click, not the invite: Roblox does not tell the game
	whether the prompt was actually sent.

	See docs/lobby/friend-invite.md.
]]

-- How long the notification stays up when nobody clicks.
local DURATION = 20

local TITLE = "%s is online!"
local TEXT = "Invite them to play with you?"
local INVITE_BUTTON = "Invite"
local DECLINE_BUTTON = "Decline"
local ICON = "rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"

-- The invite prompt's own message, under the friend's name.
local INVITE_MESSAGE = "Come play Periastron Tower Defense with me!"

-- `GetFriendsOnline` answers at most this many.
local MAX_FRIENDS = 200

-- `SetCore` fails until the CoreGui registers the notification; retry for a while.
local SETCORE_ATTEMPTS = 10
local SETCORE_RETRY = 1

local FriendInviteController = {
	Controllers = {}
}

-- True while a notification is on screen.
FriendInviteController.Busy = false

--[[ INTERNAL ]]

local function toSet(list : any) : { [number] : boolean }
	local set = {}
	if typeof(list) ~= "table" then return set end

	for _, userId in list do
		if typeof(userId) == "number" then
			set[userId] = true
		end
	end

	return set
end

--[=[
	The friend to suggest: `{ UserId, DisplayName }`, or nil when nobody is
	eligible.
]=]
function FriendInviteController:pick(payload : any)
	local ok, friends = pcall(Player.GetFriendsOnline, Player, MAX_FRIENDS)
	if not ok or typeof(friends) ~= "table" then
		log:Debug("could not read online friends:", friends)
		return nil
	end

	local exclude = toSet(payload and payload.Exclude)

	local eligible = {}
	local byId = {}
	for _, friend in friends do
		local userId = friend.VisitorId
		if typeof(userId) ~= "number" then continue end
		if exclude[userId] or Players:GetPlayerByUserId(userId) then continue end

		local entry = {
			UserId = userId,
			DisplayName = friend.DisplayName or friend.UserName or "Your friend",
		}
		table.insert(eligible, entry)
		byId[userId] = entry
	end

	if #eligible == 0 then return nil end

	local preferred = payload and payload.Preferred
	if typeof(preferred) == "table" then
		for _, userId in preferred do
			if byId[userId] then
				return byId[userId]
			end
		end
	end

	return eligible[math.random(1, #eligible)]
end

function FriendInviteController:invite(userId : number, launchData : string?)
	local ok, canSend = pcall(SocialService.CanSendGameInviteAsync, SocialService, Player, userId)
	if not ok or not canSend then
		log:Debug(`cannot send an invite to {userId}:`, canSend)
		return
	end

	local options = Instance.new("ExperienceInviteOptions")
	options.InviteUser = userId
	options.PromptMessage = INVITE_MESSAGE
	if typeof(launchData) == "string" then
		options.LaunchData = launchData
	end

	local prompted, err = pcall(SocialService.PromptGameInvite, SocialService, Player, options)
	if not prompted then
		log:Debug("invite prompt failed:", err)
	end
end

function FriendInviteController:notify(friend) : boolean
	local answered = false

	local callback = Instance.new("BindableFunction")
	callback.OnInvoke = function(button : string)
		if answered then return end
		answered = true
		self.Busy = false

		local accepted = button == INVITE_BUTTON
		Framework:Fire("FriendInviteAnswered", friend.UserId, accepted)

		if accepted then
			task.spawn(self.invite, self, friend.UserId, friend.LaunchData)
		end
	end

	local notification = {
		Title = string.format(TITLE, friend.DisplayName),
		Text = TEXT,
		Icon = string.format(ICON, friend.UserId),
		Duration = DURATION,
		Callback = callback,
		Button1 = INVITE_BUTTON,
		Button2 = DECLINE_BUTTON,
	}

	for _ = 1, SETCORE_ATTEMPTS do
		if pcall(StarterGui.SetCore, StarterGui, "SendNotification", notification) then
			task.delay(DURATION + 1, function()
				if not answered then
					answered = true
					self.Busy = false
				end
				callback:Destroy()
			end)

			return true
		end

		task.wait(SETCORE_RETRY)
	end

	callback:Destroy()
	log:StudioWarn("could not send the CoreGui notification; the friend suggestion was dropped.")

	return false
end

function FriendInviteController:suggest(payload : any)
	if self.Busy then return end
	self.Busy = true

	local friend = self:pick(payload)
	if not friend then
		self.Busy = false
		log:Debug("no eligible online friend to suggest.")
		return
	end

	friend.LaunchData = payload and payload.LaunchData

	Framework:Fire("FriendInviteShown", friend.UserId)

	if not self:notify(friend) then
		self.Busy = false
	end
end

--[[ LIFECYCLE ]]

function FriendInviteController:construct()
	Framework:Listen("FriendInvitePrompt", function(payload)
		task.spawn(self.suggest, self, payload)
	end)
end

function FriendInviteController:start()
end

function FriendInviteController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return FriendInviteController
