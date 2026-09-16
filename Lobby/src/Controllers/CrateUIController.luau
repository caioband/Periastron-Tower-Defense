local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local UIUtil = require(Util.UIUtil)

local Framework = Me.new()

--[[ CONSTANTS ]]
local CRATE_UI_NAME = "crateui"
local HUD_UI_NAME = "HUD"

local PANEL_NAME = "Rectangle"
local HUD_FRAME_NAME = "HUDFrame"
local TOGGLE_BUTTON_NAME = "Backpack"

local OPEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FADE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local OPEN_FROM_SCALE = 0.85
local CLOSE_TO_SCALE = 0.9

--[=[
	Owns the crate panel: the Backpack button opens and closes it.

	Was a LocalScript parented to the HUD (StarterGui.HUD.BackpackToggle). It lives
	here so the UI holds no code. Opening a crate does **not** close the panel.
]=]
local CrateUIController = {
	Controllers = {},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

function CrateUIController:_playTween(object : Instance, info : TweenInfo, goal : { [string]: any }) : Tween
	local tween = TweenService:Create(object, info, goal)

	self.TweenMaid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
	return tween
end

function CrateUIController:_setOpen(open : boolean)
	local panel = self.Panel
	if not panel or not panel.Parent or not self.PanelScale then
		return
	end

	if open == self.IsOpenState then
		return
	end

	self.IsOpenState = open
	self.TweenMaid:DoCleaning()

	if open then
		self.PanelScale.Scale = OPEN_FROM_SCALE
		panel.ImageTransparency = 1
		panel.Visible = true

		self:_playTween(self.PanelScale, OPEN_INFO, { Scale = 1 })
		self:_playTween(panel, FADE_INFO, { ImageTransparency = 0 })
	else
		self:_playTween(self.PanelScale, CLOSE_INFO, { Scale = CLOSE_TO_SCALE })

		local fade = self:_playTween(panel, CLOSE_INFO, { ImageTransparency = 1 })
		fade.Completed:Once(function(state : Enum.PlaybackState)
			-- Reopened mid-fade: the open tween owns the panel now.
			if state == Enum.PlaybackState.Completed and not self.IsOpenState then
				panel.Visible = false
			end
		end)
	end

	self.Signals.OpenChanged:Fire(open)
end

--[=[
	Binds to a crateui instance. crateui has ResetOnSpawn enabled, so this runs again
	for every fresh copy the engine parents into PlayerGui.
]=]
function CrateUIController:_bindPanel(screenGui : ScreenGui)
	local panel = screenGui:WaitForChild(PANEL_NAME, 10)
	local panelScale = panel and panel:FindFirstChildWhichIsA("UIScale")

	if not panel or not panelScale then
		warn(`[CrateUIController]: Could not find {CRATE_UI_NAME}.{PANEL_NAME} with a UIScale.`)
		return
	end

	self.TweenMaid:DoCleaning()

	self.Panel = panel
	self.PanelScale = panelScale

	-- The panel starts closed, like the old script left it.
	self.IsOpenState = false
	panel.Visible = false
end

--[=[
	Binds the Backpack button on the HUD. It sits inside a wrapper frame, so it is
	looked up by name anywhere under the HUD frame -- and its hover and click
	animations belong to HUDButtonController, shared by every button up there.
]=]
function CrateUIController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, 10)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, TOGGLE_BUTTON_NAME, 10)

	if not button or not button:IsA("GuiButton") then
		warn(`[CrateUIController]: Could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{TOGGLE_BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:Toggle()
	end))
end

function CrateUIController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if not child:IsA("ScreenGui") then
			return
		end

		if child.Name == CRATE_UI_NAME then
			self:_bindPanel(child)
		elseif child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

function CrateUIController:IsOpen() : boolean
	return self.IsOpenState == true
end

function CrateUIController:Open()
	self:_setOpen(true)
end

function CrateUIController:Close()
	self:_setOpen(false)
end

function CrateUIController:Toggle()
	self:_setOpen(not self.IsOpenState)
end

function CrateUIController:construct()
	self:_observeUI()
end

function CrateUIController:start()

end

function CrateUIController:init()
	self.Maid = Maid.new()
	self.TweenMaid = Maid.new()
	self.HudMaid = Maid.new()

	self.Maid:GiveTask(self.TweenMaid)
	self.Maid:GiveTask(self.HudMaid)

	self.IsOpenState = false

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CrateUIController
