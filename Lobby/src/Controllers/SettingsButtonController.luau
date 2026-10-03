local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("SettingsButtonController")

--[[ CONSTANTS ]]

--[=[
	The HUD button that opens the settings: `HUD.HUDLeft.Wrapper.Settings`, below
	`Contracts` and `RobuxShop` in the left column.

	Only the Lobby has this HUD, so the names live here and not in `SettingsConfig`,
	which is in the `Shared` Package every place receives.
]=]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDLeft"
local HUD_BUTTON_NAME = "Settings"

local WAIT_TIMEOUT = 10

--[=[
	The Lobby's HUD door to the settings panel.

	**The panel is `SettingsController`'s** (common, in every place, with its
	TopbarPlus icon): this only turns the button's click into `Toggle()`. The icon
	follows the panel's `OpenChanged`, so opening from here selects it too, and the
	X closes both.

	The button's slide and sink belong to `HUDButtonController`, which animates both
	columns. The HUD is `ResetOnSpawn`, so the bind runs again on every new copy.

	See docs/common/settings.md.
]=]
local SettingsButtonController = {
	Controllers = {
		SettingsController = {},
	},
}

--[[ INTERNAL ]]

function SettingsButtonController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)
	local button = hudFrame and hudFrame:FindFirstChild(HUD_BUTTON_NAME, true)

	if not button or not button:IsA("GuiButton") then
		if not self.WarnedButton then
			self.WarnedButton = true
			log:StudioWarn(`could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		end

		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		local settings = self.Controllers.SettingsController
		if settings then
			settings:Toggle()
		end
	end))
end

function SettingsButtonController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

function SettingsButtonController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	if not self.Controllers.SettingsController then
		log:StudioWarn("no SettingsController -- the HUD Settings button does nothing.")
	end

	self:_observeUI()
end

function SettingsButtonController:init()
	self.Maid = Maid.new()

	-- The HUD button's click, which the engine rebuilds on every respawn.
	self.HudMaid = Maid.new()
	self.Maid:GiveTask(self.HudMaid)

	self.WarnedButton = false
end

return SettingsButtonController
