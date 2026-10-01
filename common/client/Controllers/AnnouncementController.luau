local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

local GUI_NAME = "GlobalAnnouncementBanner"
local MARKUP = "[img=rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150] [gradient=purple]%s: %s[/gradient]"

local POSITION = UDim2.fromScale(0.5, 0.15)
local SIZE = UDim2.fromScale(0.7, 0.12)
local BAND_COLOR = Color3.fromRGB(30, 10, 55)
local BAND_TRANSPARENCY = 0.25

local FADE_IN = 0.4
local HOLD = 5
local FADE_OUT = 0.5

local OPTIONS = {
	Font = "rbxasset://fonts/families/PressStart2P.json",
	Speed = 45,
	Anim = "slide",
	AnimDuration = 0.3,
	Fit = { TextRatio = 0.8, MaxRows = 2, WidthPerChar = 1, MinTextSize = 8, Debug = false },
	Stroke = { Thickness = 0.06, Color = Color3.fromRGB(110, 40, 200) },
	Align = Enum.HorizontalAlignment.Center,
	VerticalAlign = Enum.VerticalAlignment.Center,
}

local AnnouncementController = {
	Controllers = {
		RichTextController = {},
	},

	Gui = nil,
	Token = 0,
}

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 30
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local band = Instance.new("Frame")
	band.Name = "Band"
	band.AnchorPoint = Vector2.new(0.5, 0.5)
	band.Position = POSITION
	band.Size = SIZE
	band.BackgroundColor3 = BAND_COLOR
	band.BackgroundTransparency = 1
	band.BorderSizePixel = 0
	band.Parent = gui

	local edges = Instance.new("UIGradient")
	edges.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0),
		NumberSequenceKeypoint.new(0.8, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	edges.Parent = band

	local container = Instance.new("Frame")
	container.Name = "Text"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromScale(0.8, 0.75)
	container.BackgroundTransparency = 1
	container.Parent = band

	return gui, band, container
end

function AnnouncementController:show(username : string, userId : number, message : string)
	local rich = self.Controllers.RichTextController
	if not rich then return end

	self.Token += 1
	local token = self.Token

	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end

	local gui, band, container = build()
	gui.Parent = PlayerGui
	self.Gui = gui

	TweenService:Create(band, TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = BAND_TRANSPARENCY,
	}):Play()

	local text = string.format(MARKUP, userId, rich:Escape(username), rich:Escape(message))
	local handle = rich:Write(container, text, OPTIONS)

	if self.Token ~= token then return end

	local typingTime = (#username + #message + 2) / OPTIONS.Speed

	task.delay(typingTime + HOLD, function()
		if self.Token ~= token or not gui.Parent then return end

		if handle then
			handle:Clear()
		end

		TweenService:Create(band, TweenInfo.new(FADE_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			BackgroundTransparency = 1,
		}):Play()

		task.delay(FADE_OUT + 0.5, function()
			if gui.Parent then
				gui:Destroy()
			end
			if self.Gui == gui then
				self.Gui = nil
			end
		end)
	end)
end

function AnnouncementController:start()
	for name in self.Controllers do
		self.Controllers[name] = Framework:Get(name)
	end

	Framework:Listen("GlobalAnnouncement", function(username : any, userId : any, message : any)
		if typeof(username) ~= "string" or typeof(userId) ~= "number" or typeof(message) ~= "string" then return end

		task.spawn(function()
			self:show(username, userId, message)
		end)
	end)
end

function AnnouncementController:init()
end

return AnnouncementController