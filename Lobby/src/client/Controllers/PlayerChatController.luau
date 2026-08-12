local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BubbleAssets = Shared:WaitForChild("Assets"):WaitForChild("UI"):WaitForChild("Bubbles")

local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Shared.Me)

local Framework = Me.new()

local ExampleController = {
	Controllers = {
		MovementController = {}
	},
	_activeTypers = {}
}

local TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

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

	Framework:Listen("TypingStatusBroadcast", function(player, isTyping)
		if isTyping then
			self._activeTypers[player.Name] = "Running"
			self:PlayTypingAnimation(player)
		else
			self._activeTypers[player.Name] = nil
		end
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
