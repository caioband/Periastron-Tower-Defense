local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)
local Icon = require(Packages:WaitForChild("topbarplus"))
local Log = require(Util.Log)

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local ProximityPanel = require(Util.ProximityPanel)

local SettingsConfig = SharedConfig.SettingsConfig

local Framework = Me.new()
local log = Log.new("SettingsController")

--[[ CONSTANTS ]]

local GUI = SettingsConfig.Gui
local ROW = SettingsConfig.Row

local HIDE_REASON = "Settings"

-- The `UIScale` the click pop needs, created when the template does not ship one.
local PRESS_SCALE_NAME = "PressScale"

-- [key] = the `SettingsConfig.List` entry
local DEFINITIONS = {}
for _, entry in SettingsConfig.List do
	DEFINITIONS[entry.Key] = entry
end

--[=[
	The settings panel: `StarterGui.SharedUIs.SettingsGUI`, opened by a TopbarPlus
	icon next to Satchel's Inventory.

	The panel itself (frame, animation, blur, screen request, the X) belongs to
	`ProximityPanel`, the same as the Lobby shops and the contracts board, with no
	`GetReference`: it has no spot on the map. It lives in `common/` because
	`SharedUIs` is in every place.

	**This controller holds the state; the systems apply it.** Each setting is a
	boolean read through `Get` or followed through `Observe`, and whoever owns the
	effect turns it off (`LightingController` the shadows, `MobController` the
	damage numbers). Music and sound effects are the exception and are applied here,
	because `MusicController` is lower level and depends on nobody.

	**Nothing is saved yet.** The values start from `SettingsConfig.List` in every
	place, and a teleport between the Lobby and the Game resets them.

	**The icon and the panel always agree.** The icon asks, the panel answers, and
	the icon is set back to whatever the panel ended up as: closing with the X
	deselects it, and a click the panel cannot honor (no copy of the screen yet)
	does not leave it selected.

	See docs/common/settings.md.
]=]
local SettingsController = {
	Controllers = {
		InterfaceController = {},
		MusicController = {},
	},
}

--[[
	The values live at module level, not in `init`: another controller may `Observe`
	from its own `init`, and `Me` does not promise this one's `init` ran first.
]]
SettingsController.Values = {}
for key, entry in DEFINITIONS do
	SettingsController.Values[key] = entry.Default ~= false
end

-- (key : string, value : boolean)
SettingsController.Changed = Signal.new()

-- [key] = { Button, State, Stroke, OnHoverImage, OnStrokeColor }, for the current copy
-- of the screen. At module level for the same reason as `Values`: `Set` renders the row.
SettingsController.Rows = {}

--[[ INTERNAL ]]

--- Puts the icon in the panel's state. Selecting it from here fires `toggled`
--- again, which `_onIconToggled` finds already settled.
function SettingsController:_syncIcon()
	local icon = self.Icon
	local isOpen = self.Proximity ~= nil and self.Proximity:IsOpen()

	if not icon or icon.isSelected == isOpen then
		return
	end

	if isOpen then
		icon:select()
	else
		icon:deselect()
	end
end

function SettingsController:_onIconToggled(isSelected : boolean)
	local panel = self.Proximity
	if not panel then
		return
	end

	if isSelected ~= panel:IsOpen() then
		if isSelected then
			panel:Open()
		else
			panel:Close()
		end
	end

	-- Deferred: `toggled` fires in the middle of TopbarPlus's own state change, and
	-- flipping the icon back from inside it would let the rest of that change run on
	-- top of ours.
	task.defer(function()
		self:_syncIcon()
	end)
end

--[=[
	The icon starts disabled and shows up with the first copy of the screen: a place
	without `SettingsGUI` would otherwise get a button that opens nothing.
]=]
function SettingsController:_createIcon()
	local config = SettingsConfig.Icon

	local icon = Icon.new()
		:setName(config.Name)
		:setLabel(config.Label)
		:setOrder(config.Order)
		:setEnabled(false)

	self.Icon = icon

	icon.toggled:Connect(function(isSelected : boolean)
		self:_onIconToggled(isSelected)
	end)

	self.Maid:GiveTask(function()
		icon:destroy()
		self.Icon = nil
	end)
end

--- Whether the setting has something to act on in this place. See `Requires`.
local function isAvailable(entry) : boolean
	return entry.Requires == nil or Framework:Get(entry.Requires, false, false) ~= nil
end

--- The row's toggle in the setting's state: the art and the ON/OFF text.
function SettingsController:_renderRow(key : string)
	local row = self.Rows[key]
	if not row then
		return
	end

	local enabled = self:Get(key)

	if row.Button and row.Button:IsA("ImageButton") then
		row.Button.Image = if enabled then SettingsConfig.ON_IMAGE else SettingsConfig.OFF_IMAGE
		row.Button.HoverImage = if enabled then row.OnHoverImage else SettingsConfig.OFF_HOVER_IMAGE
	end

	if row.State then
		row.State.Text = if enabled then SettingsConfig.ON_TEXT else SettingsConfig.OFF_TEXT
	end

	if row.Stroke then
		row.Stroke.Color = if enabled then row.OnStrokeColor else SettingsConfig.OFF_STROKE_COLOR
	end
end

--[=[
	The click on a toggle. The value changes **before** the sound: turning sound
	effects off gives a silent click, and turning them on gives one you hear, instead
	of the reverse.
]=]
function SettingsController:_onRowClicked(key : string)
	self:Set(key, not self:Get(key))

	local music = self.Controllers.MusicController
	if music then
		music:PlaySFX(SettingsConfig.CLICK_SOUND)
	end
end

--[=[
	The rows on a new copy of `SettingsGUI`: one clone of the authored template per
	setting available in this place, in `SettingsConfig.List` order. The template
	itself is thrown away; each copy of the screen brings its own.

	`maid` is `ProximityPanel`'s bind maid: the clicks die with this copy.
]=]
function SettingsController:_bindRows(panel : GuiObject, maid : any)
	table.clear(self.Rows)

	local list = panel:FindFirstChild(ROW.List, true)
	local template = list and list:FindFirstChild(ROW.Template)

	if not template then
		log:StudioWarn(`could not find {ROW.List}.{ROW.Template} in {GUI.ScreenGui} -- the panel stays empty.`)
		return
	end

	template.Parent = nil

	for index, entry in SettingsConfig.List do
		if not isAvailable(entry) then
			continue
		end

		local row = template:Clone()
		row.Name = entry.Key
		row.LayoutOrder = index
		row.Parent = list

		local label = row:FindFirstChild(ROW.Label, true)
		if label and label:IsA("TextLabel") then
			label.Text = entry.Label
		end

		local button = row:FindFirstChild(ROW.Button, true)
		local state = button and button:FindFirstChild(ROW.State, true)
		local stroke = state and state:FindFirstChildWhichIsA("UIStroke")

		-- The ON look is the template's own, read before the first render changes it.
		self.Rows[entry.Key] = {
			Button = button,
			State = state and state:IsA("TextLabel") and state or nil,
			Stroke = stroke,
			OnHoverImage = if button and button:IsA("ImageButton") then button.HoverImage else "",
			OnStrokeColor = if stroke then stroke.Color else nil,
		}

		self:_renderRow(entry.Key)

		if button and button:IsA("GuiButton") then
			if not button:FindFirstChildWhichIsA("UIScale") then
				local scale = Instance.new("UIScale")
				scale.Name = PRESS_SCALE_NAME
				scale.Parent = button
			end

			-- The match speed button's pop: it sinks while pressed and returns with an
			-- overshoot, with no hover growth.
			ButtonUtil.bindFeedback(button, maid, {
				PressScale = SettingsConfig.PRESS_SCALE,
				HoverScale = 1,
			})

			maid:GiveTask(button.Activated:Connect(function()
				self:_onRowClicked(entry.Key)
			end))
		else
			log:StudioWarn(`no {ROW.Button} in {ROW.Template} -- "{entry.Key}" cannot be toggled.`)
		end
	end

	template:Destroy()
end

--- Music and sound effects, which `MusicController` applies. See the header.
function SettingsController:_applyAudio()
	local music = self.Controllers.MusicController
	if not music then
		return
	end

	local musicConnection = self:Observe("Music", function(enabled : boolean)
		if enabled then
			music:Unmute()
		else
			music:Mute()
		end
	end)

	local effectsConnection = self:Observe("SoundEffects", function(enabled : boolean)
		music:SetSFXMuted(not enabled)
	end)

	self.Maid:GiveTask(function()
		musicConnection:Disconnect()
		effectsConnection:Disconnect()
	end)
end

--[[ EXTERNAL ]]

--- A setting's value. An unknown key warns and answers `true`: the game as authored.
function SettingsController:Get(key : string) : boolean
	local value = self.Values[key]
	if value == nil then
		log:StudioWarn(`unknown setting "{key}".`)
		return true
	end

	return value
end

function SettingsController:Set(key : string, value : boolean)
	if not DEFINITIONS[key] then
		log:StudioWarn(`unknown setting "{key}".`)
		return
	end

	if self.Values[key] == value then
		return
	end

	self.Values[key] = value
	self:_renderRow(key)
	self.Changed:Fire(key, value)
end

--[=[
	Calls `callback` with the setting's value now and again on every change.
	Returns the connection; `:Disconnect()` stops it.

		Settings:Observe("Shadows", function(enabled)
			...
		end)
]=]
function SettingsController:Observe(key : string, callback : (enabled : boolean) -> ())
	local connection = self.Changed:Connect(function(changedKey : string, value : boolean)
		if changedKey == key then
			callback(value)
		end
	end)

	callback(self:Get(key))

	return connection
end

function SettingsController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function SettingsController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function SettingsController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function SettingsController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function SettingsController:construct()
	self:_applyAudio()
	self:_createIcon()

	self.Proximity = ProximityPanel.new({
		Name = "SettingsController",
		Folder = GUI.Folder,
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = SettingsConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		Except = SettingsConfig.KEEP_ON_SCREEN,
		InterfaceController = self.Controllers.InterfaceController,

		-- A new copy starts closed without `OpenChanged` (dying with the panel open, since
		-- `SettingsGUI` resets on spawn), so the icon is set back here too.
		OnBind = function(_screenGui, _wrapper, panel, maid)
			self:_bindRows(panel, maid)

			if self.Icon then
				self.Icon:setEnabled(true)
			end

			self:_syncIcon()
		end,
	})

	local connection = self.Proximity.Signals.OpenChanged:Connect(function()
		self:_syncIcon()
	end)

	self.Maid:GiveTask(function()
		connection:Disconnect()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()
end

function SettingsController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function SettingsController:init()
	self.Maid = Maid.new()

	self.Icon = nil
	self.Proximity = nil
end

return SettingsController