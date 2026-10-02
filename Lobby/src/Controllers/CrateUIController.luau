local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Signal = require(Packages.Signal)

local ProximityPanel = require(Util.ProximityPanel)
local UIUtil = require(Util.UIUtil)

local Framework = Me.new()
local log = Log.new("CrateUIController")

--[[ CONSTANTS ]]

--[=[
	The UI path: `crateui.Frame.Rectangle`, the same shape as `Contracts.Frame.MainBoard`.
	`Frame` is the outer frame `ProximityPanel` shows and hides; `Rectangle` is the art
	the `OpenShop` animation scales and fades.
]=]
local GUI = {
	ScreenGui = "crateui",
	Wrapper = "Frame",
	Panel = "Rectangle",
	PityList = "Pity",
}

local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDFrame"
local TOGGLE_BUTTON_NAME = "Backpack"

local OPEN_ANIMATION = "OpenShop"
local HIDE_REASON = "Backpack"

--[=[
	Owns the crate panel: the Backpack button opens it.

	The panel itself (frame, `OpenShop`, the blur, hiding the rest of the UI, and the X)
	belongs to `ProximityPanel`, the same as the contracts board and the shops. **No
	`GetReference`**: the backpack has no place on the map, so it lives on the HUD button
	and the X. With the HUD hidden while it is open, the X is how it closes.

	Opening a crate does **not** close the panel: the player keeps opening crates from it.
]=]
local CrateUIController = {
	Controllers = {
		InterfaceController = {},
		HUDBadgeController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	Each new copy of `crateui` (it has `ResetOnSpawn`). `maid` is `ProximityPanel`'s bind
	maid, cleaned on the next copy.
]=]
function CrateUIController:_onBind(panel : GuiObject, maid : any)
	-- The pity list scrolls as far as its rows go, however many there are.
	local pityList = panel:FindFirstChild(GUI.PityList)
	if pityList and pityList:IsA("ScrollingFrame") then
		local connection = UIUtil.fitCanvasHeight(pityList)
		if connection then
			maid:GiveTask(connection)
		end
	end
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
		log:StudioWarn(`could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{TOGGLE_BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:Toggle()
	end))
end

--- The HUD, through the Backpack button. `ProximityPanel` follows `crateui`.
function CrateUIController:_observeUI()
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

function CrateUIController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function CrateUIController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function CrateUIController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function CrateUIController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function CrateUIController:construct()
	self.Proximity = ProximityPanel.new({
		Name = "CrateUIController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		InterfaceController = self.Controllers.InterfaceController,

		OnBind = function(_screenGui, _wrapper, panel, maid)
			self:_onBind(panel, maid)
		end,

		--[[
			The backpack was opened, so its `New` badge is done: the player has seen the
			shelf. A crate that lands after this lights the badge again on its own.

			Here and not on the button's click because the panel also opens through
			`Open()` -- open is open, wherever it comes from.
		]]
		BeforeOpen = function()
			local badges = self.Controllers.HUDBadgeController
			if badges then
				badges:NoteSeen(TOGGLE_BUTTON_NAME)
			end
		end,
	})

	local openChanged = self.Proximity.Signals.OpenChanged:Connect(function(isOpen : boolean)
		self.Signals.OpenChanged:Fire(isOpen)
	end)

	self.Maid:GiveTask(function()
		openChanged:Disconnect()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_observeUI()
end

function CrateUIController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function CrateUIController:init()
	self.Maid = Maid.new()

	-- The HUD button's click, which the engine rebuilds on every respawn.
	self.HudMaid = Maid.new()
	self.Maid:GiveTask(self.HudMaid)

	self.Proximity = nil
end

return CrateUIController
