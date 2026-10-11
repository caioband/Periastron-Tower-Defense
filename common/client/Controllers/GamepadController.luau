local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GamepadService = game:GetService("GamepadService")
local GuiService = game:GetService("GuiService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local SharedConfig = require(Configs.SharedConfig)

local GamepadConfig = SharedConfig.GamepadConfig

local Framework = Me.new()
local log = Log.new("GamepadController")

--[[ CONSTANTS ]]
local HINTS_GUI_NAME = "GamepadHints"
local IGNORE_ATTRIBUTE = "IgnoreInterfaceHide"

local CONTEXT_ORDER_BASE = 100

--[=[
	Controller support.

	- `CURSOR_TOGGLE_KEY` (D-pad down) toggles Roblox's virtual cursor; A clicks GUI under it.
	- `BACK_KEY` (B) closes the most recently opened panel, or hides the cursor.
	- Opening a panel on gamepad shows the cursor; closing the last one hides it again,
	  unless the player toggled it by hand in between.
	- `QUICK_BINDS` call a controller method directly (Deck, Settings).

	**Contexts.** A system that owns gamepad buttons for a while (the tower card owns
	B/X/Y while a tower is selected, placement owns R2/Y/B while a ghost is out) calls
	`SetContext(owner, binds)`. Its keys are claimed: this controller stops acting on
	them (B no longer means Back) and the hint bar shows the owner's labels instead. An
	open panel always wins B back, so a menu over a selected tower still closes with B.

	**Reticle.** A dot at the screen center, where R2 aims when the cursor is off. Shown
	only while someone asks for it (`RequestReticle`), so the Lobby has none.

	Panels are found by polling `IsOpen`, because not every panel has an `OpenChanged`
	signal. The poll also builds the open order that B walks back through.

	Requires `StarterGui.VirtualCursorMode = Enabled`.
]=]
local GamepadController = {
	Controllers = {
		InterfaceController = {},
	},

	Signals = {
		-- (isActive : boolean)
		ActiveChanged = Signal.new(),

		-- (isEnabled : boolean)
		CursorChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

local function isGamepadInput(input : InputObject) : boolean
	return string.find(input.UserInputType.Name, "^Gamepad") ~= nil
end

local function computeActive() : boolean
	local ok, preferred = pcall(function()
		return UserInputService.PreferredInput
	end)

	if ok and preferred ~= nil then
		return preferred == Enum.PreferredInput.Gamepad
	end

	return string.find(UserInputService:GetLastInputType().Name, "^Gamepad") ~= nil
end

function GamepadController:_call(target, method : string, name : string)
	local fn = target and target[method]
	if typeof(fn) ~= "function" then
		log:StudioWarnOnce(`{name}.{method}`, `{name} has no {method}.`)
		return nil
	end

	local ok, result = pcall(fn, target)
	if not ok then
		log:StudioWarnOnce(`{name}.{method}.error`, `{name}:{method} errored:`, result)
		return nil
	end

	return result
end

function GamepadController:_addPanel(name : string, target, options)
	options = options or {}

	for _, panel in self.Panels do
		if panel.Name == name then
			return
		end
	end

	table.insert(self.Panels, {
		Name = name,
		Target = target,
		IsOpenMethod = options.IsOpenMethod or "IsOpen",
		CloseMethod = options.CloseMethod or "Close",
		Back = options.Back ~= false,
		AutoCursor = options.AutoCursor ~= false,
		Open = false,
	})
end

function GamepadController:_resolvePanels()
	for _, spec in GamepadConfig.PANELS do
		local controller = Framework:Get(spec.Controller, false, false)
		if controller then
			self:_addPanel(spec.Controller, controller, spec)
		end
	end
end

function GamepadController:_resolveQuickBinds()
	self.QuickBinds = {}

	for _, bind in GamepadConfig.QUICK_BINDS do
		local controller = Framework:Get(bind.Controller, false, false)
		if controller then
			table.insert(self.QuickBinds, {
				Key = bind.Key,
				Name = bind.Controller,
				Target = controller,
				Method = bind.Method,
				Label = bind.Label,
			})
		end
	end
end

function GamepadController:_setActive(active : boolean)
	if self.Active == active then
		return
	end

	self.Active = active

	if not active then
		self.AutoEnabled = false
		self:DisableCursor()
	end

	self.Signals.ActiveChanged:Fire(active)
	self:_refreshHintIcons()
	self:_refreshHints()
end

function GamepadController:_watchActive()
	local function refresh()
		self:_setActive(computeActive())
	end

	local ok, preferredSignal = pcall(function()
		return UserInputService:GetPropertyChangedSignal("PreferredInput")
	end)

	if ok and preferredSignal then
		self.Maid:GiveTask(preferredSignal:Connect(refresh))
	end

	self.Maid:GiveTask(UserInputService.LastInputTypeChanged:Connect(refresh))
	self.Maid:GiveTask(UserInputService.GamepadConnected:Connect(refresh))
	self.Maid:GiveTask(UserInputService.GamepadDisconnected:Connect(refresh))

	refresh()
end

function GamepadController:_watchCursor()
	self.Maid:GiveTask(GamepadService:GetPropertyChangedSignal("GamepadCursorEnabled"):Connect(function()
		local enabled = GamepadService.GamepadCursorEnabled

		if not enabled then
			self.AutoEnabled = false
		end

		self.Signals.CursorChanged:Fire(enabled)
		self:_refreshHints()
	end))
end

function GamepadController:_poll()
	local newlyOpened = false
	local changed = false

	for _, panel in self.Panels do
		local isOpen = self:_call(panel.Target, panel.IsOpenMethod, panel.Name) == true

		if isOpen ~= panel.Open then
			panel.Open = isOpen
			changed = true

			if isOpen then
				table.insert(self.Stack, panel)

				if panel.AutoCursor then
					newlyOpened = true
				end
			else
				local index = table.find(self.Stack, panel)
				if index then
					table.remove(self.Stack, index)
				end
			end
		end
	end

	local blocked = self:IsBlocked()

	if blocked then
		if self:IsCursorEnabled() then
			self.AutoEnabled = false
			self:DisableCursor()
		end
	elseif newlyOpened and GamepadConfig.AUTO_CURSOR_ON_PANEL and self.Active and not self:IsCursorEnabled() then
		self:EnableCursor()
		self.AutoEnabled = true
	end

	if #self.Stack == 0 and self.AutoEnabled then
		self.AutoEnabled = false
		self:DisableCursor()
	end

	if changed or blocked ~= self.WasBlocked then
		self.WasBlocked = blocked
		self:_refreshHints()
	end
end

function GamepadController:_startPolling()
	local thread = task.spawn(function()
		while true do
			self:_poll()
			task.wait(GamepadConfig.POLL_INTERVAL)
		end
	end)

	self.Maid:GiveTask(function()
		task.cancel(thread)
	end)
end

function GamepadController:_onInputBegan(input : InputObject, processed : boolean)
	if not isGamepadInput(input) then
		return
	end

	if UserInputService:GetFocusedTextBox() then
		return
	end

	if self:IsBlocked() then
		return
	end

	local key = input.KeyCode

	if key == GamepadConfig.CURSOR_TOGGLE_KEY then
		self.AutoEnabled = false
		self:ToggleCursor()
		return
	end

	-- An open panel always gets B, even when a context owns it: a menu opened over a
	-- selected tower must still close with B instead of upgrading the tower behind it.
	if key == GamepadConfig.BACK_KEY and self:_topBackPanel() then
		self:Back()
		return
	end

	if self:IsClaimed(key) then
		return
	end

	if key == GamepadConfig.BACK_KEY then
		self:Back()
		return
	end

	if processed then
		return
	end

	for _, bind in self.QuickBinds do
		if bind.Key == key then
			self:_call(bind.Target, bind.Method, bind.Name)
			return
		end
	end
end

--[[ CONTEXTS ]]

--[=[
	Every context key with the label of the **latest** context that names it, in first
	appearance order. Placement's "R2 Place" replaces the always-on "R2 Select" while a
	ghost is out, instead of showing both.
]=]
function GamepadController:_resolvedContext()
	local labels = {}
	local order = {}

	for _, context in self.Contexts do
		for _, bind in context.Binds do
			if labels[bind.Key] == nil then
				table.insert(order, bind.Key)
			end

			labels[bind.Key] = bind.Label or bind.Key.Name
		end
	end

	return labels, order
end

--[[ HINTS ]]

function GamepadController:_makeHint(parent : Instance, order : number, key : Enum.KeyCode)
	local height = GamepadConfig.HINT_HEIGHT

	local row = Instance.new("Frame")
	row.Name = `Hint_{key.Name}`
	row.LayoutOrder = order
	row.Size = UDim2.fromOffset(0, height)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.BackgroundColor3 = Color3.new(0, 0, 0)
	row.BackgroundTransparency = 0.4
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = row

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = row

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = row

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.LayoutOrder = 1
	icon.Size = UDim2.fromOffset(height - 8, height - 8)
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = row

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.LayoutOrder = 2
	label.Size = UDim2.fromOffset(0, height)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = row

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Parent = label

	row.Parent = parent

	return { Row = row, Icon = icon, Label = label, Key = key }
end

function GamepadController:_makeReticle(parent : Instance)
	local size = GamepadConfig.RETICLE_SIZE

	local reticle = Instance.new("Frame")
	reticle.Name = "Reticle"
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Position = UDim2.fromScale(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(size, size)
	reticle.BackgroundColor3 = Color3.new(1, 1, 1)
	reticle.BackgroundTransparency = 0.2
	reticle.BorderSizePixel = 0
	reticle.Active = false
	reticle.Visible = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = reticle

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.3
	stroke.Parent = reticle

	reticle.Parent = parent

	return reticle
end

function GamepadController:_buildHints()
	if not GamepadConfig.SHOW_HINTS then
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = HINTS_GUI_NAME
	gui.ResetOnSpawn = false

	-- The reticle must sit exactly where `PointerUtil` aims, which is the center of the
	-- whole viewport, top bar included.
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = GamepadConfig.HINTS_DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false

	-- Visibility is decided here, not by InterfaceController: the B hint has to stay
	-- up while a panel is hiding everything else. Cutscenes are covered by IsBlocked.
	gui:SetAttribute(IGNORE_ATTRIBUTE, true)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 16, 1, -16)
	bar.Size = UDim2.fromOffset(0, GamepadConfig.HINT_HEIGHT)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.BackgroundTransparency = 1
	bar.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = bar

	self.HintBar = bar

	self.Hints = {
		Cursor = self:_makeHint(bar, 1, GamepadConfig.CURSOR_TOGGLE_KEY),
		Back = self:_makeHint(bar, 2, GamepadConfig.BACK_KEY),
		Quick = {},
	}

	for index, bind in self.QuickBinds do
		local hint = self:_makeHint(bar, 10 + index, bind.Key)
		hint.Label.Text = bind.Label or bind.Name
		table.insert(self.Hints.Quick, hint)
	end

	if GamepadConfig.SHOW_RETICLE then
		self.Reticle = self:_makeReticle(gui)
	end

	gui.Parent = playerGui
	self.HintsGui = gui

	self.Maid:GiveTask(gui)

	self:_refreshHintIcons()
	self:_refreshHints()
end

function GamepadController:_setHintIcon(hint)
	local ok, image = pcall(function()
		return UserInputService:GetImageForKeyCode(hint.Key)
	end)

	if ok and typeof(image) == "string" and image ~= "" then
		hint.Icon.Image = image
		hint.Icon.Visible = true
		hint.Prefix = ""
	else
		hint.Icon.Visible = false
		hint.Prefix = `[{hint.Key.Name}] `
	end
end

--[=[
	Rebuilds the context rows from scratch. They change with selection, upgrades and
	placement, a handful of times per minute: rebuilding is simpler than diffing and
	costs nothing at that rate.
]=]
function GamepadController:_rebuildContextHints()
	for _, hint in self.ContextHints do
		hint.Row:Destroy()
	end

	table.clear(self.ContextHints)

	local bar = self.HintBar
	if not bar then
		return
	end

	local labels, order = self:_resolvedContext()

	for index, key in order do
		local hint = self:_makeHint(bar, CONTEXT_ORDER_BASE + index, key)
		self:_setHintIcon(hint)
		hint.Label.Text = (hint.Prefix or "") .. labels[key]

		table.insert(self.ContextHints, hint)
	end
end

function GamepadController:_refreshHintIcons()
	local hints = self.Hints
	if not hints then
		return
	end

	self:_setHintIcon(hints.Cursor)
	self:_setHintIcon(hints.Back)

	for index, hint in hints.Quick do
		self:_setHintIcon(hint)

		local bind = self.QuickBinds[index]
		hint.Label.Text = (hint.Prefix or "") .. ((bind and bind.Label) or "")
	end

	self:_rebuildContextHints()
end

function GamepadController:_refreshHints()
	local gui = self.HintsGui
	local hints = self.Hints
	if not gui or not hints then
		return
	end

	local visible = self.Active and not self:IsBlocked()
	gui.Enabled = visible

	local cursorOn = self:IsCursorEnabled()
	local hasBackTarget = self:_topBackPanel() ~= nil
	local backClaimed = self:IsClaimed(GamepadConfig.BACK_KEY)

	hints.Cursor.Label.Text = (hints.Cursor.Prefix or "") .. (cursorOn and "Hide Cursor" or "Cursor")

	hints.Back.Row.Visible = hasBackTarget or (cursorOn and not backClaimed)
	hints.Back.Label.Text = (hints.Back.Prefix or "") .. (hasBackTarget and "Close" or "Back")

	for _, hint in hints.Quick do
		hint.Row.Visible = not cursorOn and not self:IsClaimed(hint.Key)
	end

	-- Context actions are refused while a panel is open (see `HasOpenPanel`), so their
	-- hints leave with them.
	for _, hint in self.ContextHints do
		hint.Row.Visible = not hasBackTarget
	end

	if self.Reticle then
		self.Reticle.Visible = visible
			and not cursorOn
			and not hasBackTarget
			and next(self.ReticleRequests) ~= nil
	end
end

function GamepadController:_topBackPanel()
	for index = #self.Stack, 1, -1 do
		local panel = self.Stack[index]
		if panel.Open and panel.Back then
			return panel
		end
	end

	return nil
end

--[[ EXTERNAL ]]

function GamepadController:IsActive() : boolean
	return self.Active == true
end

function GamepadController:IsCursorEnabled() : boolean
	return GamepadService.GamepadCursorEnabled
end

--[=[
	True while a cutscene or portal countdown owns the screen, or the Roblox menu is
	open. Gamepad input is ignored and the cursor stays off.
]=]
function GamepadController:IsBlocked() : boolean
	if GuiService.MenuIsOpen then
		return true
	end

	local interface = self.Controllers.InterfaceController
	if interface then
		for _, reason in GamepadConfig.BLOCKING_HIDE_REASONS do
			if interface:IsHidden(reason) then
				return true
			end
		end
	end

	return false
end

--[=[
	True while any tracked panel is open, including ones B does not close (dialogs).
	World actions (tower upgrade/sell, placement) stand down while this is true.
]=]
function GamepadController:HasOpenPanel() : boolean
	return #self.Stack > 0
end

--[=[
	Shows the virtual cursor. `target` centers it on a GuiObject; nil uses the
	default position.
]=]
function GamepadController:EnableCursor(target : GuiObject?)
	GuiService.SelectedObject = nil

	local ok, err = pcall(function()
		GamepadService:EnableGamepadCursor(target)
	end)

	if not ok then
		log:StudioWarnOnce("enable", "EnableGamepadCursor failed (is StarterGui.VirtualCursorMode Enabled?):", err)
	end
end

function GamepadController:DisableCursor()
	if not GamepadService.GamepadCursorEnabled then
		return
	end

	pcall(function()
		GamepadService:DisableGamepadCursor()
	end)
end

function GamepadController:ToggleCursor()
	if self:IsCursorEnabled() then
		self:DisableCursor()
	else
		self:EnableCursor()
	end
end

--[=[
	Closes the most recently opened panel that allows it. With none open, hides the
	cursor. Returns whether it did anything.
]=]
function GamepadController:Back() : boolean
	local panel = self:_topBackPanel()

	if panel then
		self:_call(panel.Target, panel.CloseMethod, panel.Name)
		return true
	end

	if self:IsCursorEnabled() then
		self.AutoEnabled = false
		self:DisableCursor()
		return true
	end

	return false
end

--[=[
	Claims gamepad keys for `owner` and shows their labels in the hint bar. Calling it
	again with the same owner replaces that owner's binds in place.

		GamepadController:SetContext("TowerCard", {
			{ Key = Enum.KeyCode.ButtonB, Label = "Upgrade" },
			{ Key = Enum.KeyCode.ButtonX, Label = "Sell" },
		})

	The owner still listens to its own input; a context only tells this controller to
	keep its hands off those keys and what to write on screen. The cursor key can never
	be claimed.
]=]
function GamepadController:SetContext(owner : string, binds : { { Key : Enum.KeyCode, Label : string? } })
	local entry = nil

	for _, context in self.Contexts do
		if context.Owner == owner then
			entry = context
			break
		end
	end

	if not entry then
		entry = { Owner = owner, Binds = {} }
		table.insert(self.Contexts, entry)
	end

	local filtered = {}
	for _, bind in binds or {} do
		if bind.Key ~= GamepadConfig.CURSOR_TOGGLE_KEY then
			table.insert(filtered, bind)
		end
	end

	entry.Binds = filtered

	self:_rebuildContextHints()
	self:_refreshHints()
end

function GamepadController:ClearContext(owner : string)
	for index, context in self.Contexts do
		if context.Owner == owner then
			table.remove(self.Contexts, index)

			self:_rebuildContextHints()
			self:_refreshHints()
			return
		end
	end
end

--- Whether any context currently owns this key.
function GamepadController:IsClaimed(key : Enum.KeyCode) : boolean
	for _, context in self.Contexts do
		for _, bind in context.Binds do
			if bind.Key == key then
				return true
			end
		end
	end

	return false
end

--[=[
	Asks for the center reticle (where R2 aims with the cursor off). It shows while at
	least one owner wants it.
]=]
function GamepadController:RequestReticle(owner : string, enabled : boolean)
	self.ReticleRequests[owner] = if enabled then true else nil
	self:_refreshHints()
end

--[=[
	Adds a panel that is not in `GamepadConfig.PANELS`, e.g. one that only exists in
	the game place. `target` needs `IsOpen` and `Close` (or the methods named in
	`options.IsOpenMethod` / `options.CloseMethod`).

		GamepadController:RegisterPanel("UpgradePanel", UpgradeController)
		GamepadController:RegisterPanel("Results", ResultController, { Back = false })
]=]
function GamepadController:RegisterPanel(name : string, target, options : { [string] : any }?)
	self:_addPanel(name, target, options)
end

function GamepadController:UnregisterPanel(name : string)
	for index, panel in self.Panels do
		if panel.Name == name then
			table.remove(self.Panels, index)

			local stackIndex = table.find(self.Stack, panel)
			if stackIndex then
				table.remove(self.Stack, stackIndex)
			end

			self:_refreshHints()
			return
		end
	end
end

function GamepadController:construct()
	self:_resolvePanels()
	self:_resolveQuickBinds()

	self.Maid:GiveTask(UserInputService.InputBegan:Connect(function(input, processed)
		self:_onInputBegan(input, processed)
	end))

	self:_watchCursor()
	self:_buildHints()
	self:_watchActive()
	self:_startPolling()
end

function GamepadController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function GamepadController:init()
	self.Maid = Maid.new()

	self.Active = false
	self.AutoEnabled = false
	self.WasBlocked = false

	self.Panels = {}
	self.Stack = {}
	self.QuickBinds = {}

	-- Created here, not in `construct`: other controllers call `SetContext` and
	-- `RequestReticle` from their own `start`, which may run before this one's.
	self.Contexts = {}
	self.ContextHints = {}
	self.ReticleRequests = {}

	self.Hints = nil
	self.HintsGui = nil
	self.HintBar = nil
	self.Reticle = nil
end

return GamepadController