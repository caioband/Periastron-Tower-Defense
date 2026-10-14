local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local BubbleAssets = Shared:WaitForChild("Assets"):WaitForChild("UI"):WaitForChild("Bubbles")

local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local GamepassConfig = SharedConfig.GamepassConfig
local NametagConfig = SharedConfig.NametagConfig

local Framework = Me.new()

local ExampleController = {
	Controllers = {
		MovementController = {}
	},
	_activeTypers = {}
}

local TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

--[[
	The tags before the speaker's name: `[PROGRAMMER] [VIP] Someone: hi`.

	**Gamepass tag.** `MonetizationService` publishes one attribute per pass with a
	`ChatTag` on the `Player`.

	**Staff tag.** The equipped nametag is published as `EquippedNametag` on the
	`Player` by `NametagService`. When it is a restricted nametag (`UserIds` in
	`NametagConfig`), its `Title` becomes a tag, coloured with the first stop of its
	Title gradient. Only the server can equip a restricted nametag, so nobody can show
	someone else's tag.

	**Why attributes and not the profile.** The tags must appear on **other** players'
	messages, and the profile replica only reaches its owner. Attributes replicate to
	the whole room; the server still writes, and this only reads.

	**Why on the client.** `TextChatService`'s `OnIncomingMessage` is client-side by
	nature: it only decorates what already arrived. Nothing here decides who has what.

	See docs/common/gamepasses.md.
]]
local TAG_FORMAT = "[%s] "
local COLORED_TAG_FORMAT = '<font color="#%s">[%s]</font> '

--- The staff tag for an equipped restricted nametag: its Title and colour, or nil.
local function staffTagOf(player : Player) : (string?, Color3?)
	local id = player:GetAttribute(NametagConfig.ATTRIBUTE)
	if typeof(id) ~= "string" or id == "" or not NametagConfig.IsRestricted(id) then
		return nil, nil
	end

	local nametag = NametagConfig.Get(id)
	local title = nametag and NametagConfig.nonEmpty(nametag.Title)
	if not title then
		return nil, nil
	end

	local style = nametag.Style and nametag.Style.Title
	local gradient = style and style.Gradient
	local color = if typeof(gradient) == "ColorSequence"
		then gradient.Keypoints[1].Value
		elseif style and typeof(style.TextColor3) == "Color3" then style.TextColor3
		else Color3.new(1, 1, 1)

	return title, color
end

--- The gamepass chat tag the server published for this player, or nil.
local function passTagOf(player : Player) : string?
	local owned = {}
	for key, pass in GamepassConfig.PASSES do
		if pass.ChatTag then
			owned[key] = player:GetAttribute(GamepassConfig.attributeName(key)) == true
		end
	end

	return GamepassConfig.chatTagOf(owned)
end

function ExampleController:construct()
	self._maid = Maid.new()
end

function ExampleController:start()

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end
	self:construct()

	local chatInputBar = TextChatService:WaitForChild("ChatInputBarConfiguration")

	self._maid:GiveTask(chatInputBar:GetPropertyChangedSignal("IsFocused"):Connect(function()
		local thinkingAnimation = self.Controllers["MovementController"]:getAnimation("Thinking")
		if chatInputBar.IsFocused then thinkingAnimation:Play() else thinkingAnimation:Stop() end
		Framework:Fire("TypingStatusChanged", chatInputBar.IsFocused)
	end))

	self:_bindChatTags()

	Framework:Listen("TypingStatusBroadcast", function(player, isTyping)
		if isTyping then
			self._activeTypers[player.Name] = "Running"
			self:PlayTypingAnimation(player)
		else
			self._activeTypers[player.Name] = nil
		end
	end)
end

--[=[
	Puts the staff tag and the gamepass tag in front of the speaker's name.

	Only player messages are decorated: a nil `TextSource` is the system speaking
	(joined, left, a command), and a tag there would look like the server bought a
	pass or works on the game.

	Returning `nil` leaves the message exactly as it arrived, which is what happens
	for players with no tag. The authored `PrefixText` already carries the player's
	name: the tags go **before** it, not in its place.
]=]
function ExampleController:_bindChatTags()
	TextChatService.OnIncomingMessage = function(message : TextChatMessage)
		local source = message.TextSource
		if not source then
			return nil
		end

		local player = Players:GetPlayerByUserId(source.UserId)
		if not player then
			return nil
		end

		local prefix = ""

		local staffTitle, staffColor = staffTagOf(player)
		if staffTitle and staffColor then
			prefix ..= string.format(COLORED_TAG_FORMAT, staffColor:ToHex(), staffTitle)
		end

		local passTag = passTagOf(player)
		if passTag then
			prefix ..= string.format(TAG_FORMAT, passTag)
		end

		if prefix == "" then
			return nil
		end

		local properties = Instance.new("TextChatMessageProperties")
		properties.PrefixText = prefix .. message.PrefixText

		return properties
	end

	self._maid:GiveTask(function()
		TextChatService.OnIncomingMessage = nil
	end)
end

function ExampleController:PlayTypingAnimation(player)
	if self._activeTypers[player.Name] ~= "Running" then return end

	local character = player.Character or player.CharacterAdded:Wait()
	local head = character:FindFirstChild("Head")
	if not head then return end

	local sections = {}
	for i = 1, 3 do
		local part = BubbleAssets:FindFirstChild("Section" .. i):Clone()
		local billboard = part:FindFirstChildOfClass("BillboardGui")

		if billboard then
			billboard.Size = UDim2.new(0, 0, 0, 0)
			billboard.Enabled = false
			billboard.StudsOffset = Vector3.new(0, 1.5, 0)
			billboard.Parent = head
			table.insert(sections, billboard)
		end
		part:Destroy()
	end

	task.spawn(function()
		while self._activeTypers[player.Name] == "Running" do
			for i = 1, 3 do
				if self._activeTypers[player.Name] ~= "Running" then break end

				for _, s in pairs(sections) do
					s.Enabled = false
					s.Size = UDim2.new(0, 0, 0, 0)
				end

				local b = sections[i]
				if b and self._activeTypers[player.Name] == "Running" then
					b.Enabled = true
					TweenService:Create(b, TWEEN_INFO, {Size = UDim2.new(1, 0, 1, 0)}):Play()
				end

				local startWait = tick()
				while tick() - startWait < 1 do
					if self._activeTypers[player.Name] ~= "Running" then break end
					task.wait(0.1)
				end
			end
		end
		for _, s in pairs(sections) do s:Destroy() end
	end)
end

function ExampleController:init()

end

return ExampleController