local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local Me = require(Vendor.Me)

local Framework = Me.new()

local WeatherConfig = SharedConfig.WeatherConfig

local GUI_NAME = "WeatherOverrideBanner"
local MARKUP = "[gradient=override][shiny=white]WEATHER OVERRIDDEN TO %s[/shiny][/gradient]"

local POSITION = UDim2.fromScale(0.5, 0.28)
local SIZE = UDim2.fromScale(0.7, 0.1)
local BAND_COLOR = Color3.fromRGB(5, 35, 20)
local BAND_TRANSPARENCY = 0.3

local FADE_IN = 0.4
local HOLD = 4
local FADE_OUT = 0.5

local OPTIONS = {
	Font = "rbxasset://fonts/families/PressStart2P.json",
	Speed = 45,
	Anim = "slide",
	AnimDuration = 0.3,
	Fit = { TextRatio = 0.8, MaxRows = 1, WidthPerChar = 1, MinTextSize = 8, Debug = false },
	Stroke = { Thickness = 0.06, Color = Color3.fromRGB(140, 255, 190) },
	Align = Enum.HorizontalAlignment.Center,
	VerticalAlign = Enum.VerticalAlignment.Center,
}

local EnemyWeatherOverrideController = {
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
	gui.DisplayOrder = 20
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
	container.Size = UDim2.fromScale(0.8, 0.7)
	container.BackgroundTransparency = 1
	container.Parent = band

	return gui, band, container
end

function EnemyWeatherOverrideController:show(weatherName : string)
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

	local display = rich:Escape(WeatherConfig.GetDisplayName(weatherName))
	local handle = rich:Write(container, string.format(MARKUP, display), OPTIONS)

	if self.Token ~= token then return end

	task.delay(HOLD, function()
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

function EnemyWeatherOverrideController:start()
	for name in self.Controllers do
		self.Controllers[name] = Framework:Get(name)
	end

	Framework:Listen("EnemyWeatherOverride", function(weatherName : any)
		if typeof(weatherName) ~= "string" then return end

		task.spawn(function()
			self:show(weatherName)
		end)
	end)
end

function EnemyWeatherOverrideController:init()
end

return EnemyWeatherOverrideController