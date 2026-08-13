local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Assets = Shared:WaitForChild("Assets")

local Me = require(Vendor.Me)
local Framework = Me.new()

local Player = Players.LocalPlayer

local FADE_TIME = 0.6

local LoadingController = {}

function LoadingController:buildScreen()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LoadingScreen"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 1000
	screenGui.Parent = Player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Overlay"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BorderSizePixel = 0
	frame.ZIndex = 10
	frame.Parent = screenGui

	local label = Instance.new("TextLabel")
	label.Name = "StatusLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 0.08)
	label.Position = UDim2.fromScale(0, 0.88)
	label.FontFace = Font.new("rbxassetid://12187371840", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Text = "LOADING 0%"
	label.ZIndex = 11
	label.Parent = frame

	self.screenGui = screenGui
	self.frame = frame
	self.label = label
end

function LoadingController:collectAssets()
	local instances = {}
	for _, inst in Assets:GetDescendants() do
		table.insert(instances, inst)
	end
	for _, inst in workspace:GetDescendants() do
		table.insert(instances, inst)
	end
	for _, inst in game.SoundService:GetDescendants() do
		table.insert(instances, inst)
	end
	return instances
end

function LoadingController:preloadAssets()
	local instances = self:collectAssets()
	local total = #instances

	if total == 0 then
		self.label.Text = "LOADING 100%"
		return
	end

	local loaded = 0
	ContentProvider:PreloadAsync(instances, function()
		loaded += 1
		local percent = math.floor((loaded / total) * 100)
		self.label.Text = string.format("LOADING %d%%", percent)
	end)
end

function LoadingController:fadeOut()
	local frameTween = TweenService:Create(self.frame, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 })
	local labelTween = TweenService:Create(self.label, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TextTransparency = 1 })

	frameTween.Completed:Connect(function()
		if self.screenGui then
			self.screenGui:Destroy()
			self.screenGui = nil
		end
	end)

	frameTween:Play()
	labelTween:Play()
end

function LoadingController:construct()
end

function LoadingController:start()
end

function LoadingController:init()
	self:buildScreen()
	self:preloadAssets()
	task.wait(2)
	self:fadeOut()

	local musicController = Framework:Get("MusicController", false, true)
	if musicController then
		musicController:OnLoadingComplete()
	end
end

return LoadingController
