local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.RichTextConfig

--[[
	The rich text workbench: write the markup, press DISPLAY, look.

	It opens through Cmdr (`richtext`) and serves a single purpose: trying markup
	without editing config, without pressing Play again, and without inventing an
	NPC to speak. It is where you find out that `amp=.3` on wiggle shakes too much
	before the effect ends up on a game screen.

	Three parts, which is what the workbench needs:

		PREVIEW   the container where text is drawn (it goes to
		          `RichTextController:Bind`, like any game screen)
		INPUT     the box where markup is written
		DISPLAY   the button that draws; CLEAR erases and PRESET switches the preset

	**The screen is built in code, on purpose.** `StarterGui` is not synced by Rojo:
	a screen authored in Studio would not be in git, and a dev tool that depends on
	someone having the place open at the right version is useless. Here it is born
	from the file, the same in both places.

	**Switching presets recreates the handle** instead of just adjusting the existing
	one. A handle's options accumulate (that is `RichTextController`'s contract: what
	you request keeps applying), and in a workbench that would lie: the `Warning`
	outline would survive into `Instant`, and you would be looking at a mix no game
	screen would have.

	It lives in `common/` because markup is the same in both places.

	See docs/common/rich-text.md.
]]

local RichTextLabController = {
	Controllers = {
		RichTextController = {}
	}
}

RichTextLabController.Gui = nil :: ScreenGui?
RichTextLabController.Preview = nil :: Frame?
RichTextLabController.Input = nil :: TextBox?
RichTextLabController.PresetButton = nil :: TextButton?
RichTextLabController.Handle = nil :: any

-- Index into `Presets`, the list of names the PRESET button cycles through.
RichTextLabController.Presets = {}
RichTextLabController.PresetIndex = 1

local COLORS = {
	Panel = Color3.fromRGB(24, 24, 30),
	Preview = Color3.fromRGB(14, 14, 18),
	Input = Color3.fromRGB(34, 34, 42),
	Button = Color3.fromRGB(46, 46, 58),
	Accent = Color3.fromRGB(64, 132, 96),
	Stroke = Color3.fromRGB(70, 70, 86),
	Text = Color3.fromRGB(235, 235, 240),
	Faded = Color3.fromRGB(150, 150, 165),
}

local PLACEHOLDER = "[color=yellow]text[/color] with [shake]effect[/shake][pause=0.5] and [wiggle]wave[/wiggle]"

--[[ INTERNAL ]]

--[=[
	`Instance.new` with properties and parent in a single call. The whole screen is
	built from here down, and without it there would be three times as many
	assignment lines.
]=]
local function create(className : string, properties : { [string] : any }, parent : Instance?) : any
	local instance = Instance.new(className)

	for property, value in properties do
		(instance :: any)[property] = value
	end

	if parent then
		instance.Parent = parent
	end

	return instance
end

--[=[
	A button in the bottom bar.
]=]
local function createButton(text : string, color : Color3, layoutOrder : number, parent : Instance) : TextButton
	local button = create("TextButton", {
		Name = text,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = COLORS.Text,
		TextSize = 14,
		Font = Enum.Font.GothamMedium,
		AutoButtonColor = true,
		LayoutOrder = layoutOrder,
	}, parent)

	create("UICorner", { CornerRadius = UDim.new(0, 6) }, button)
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
	}, button)

	return button
end

--[=[
	Builds the screen. Once per session: closing only hides it.
]=]
function RichTextLabController:build()
	if self.Gui and self.Gui.Parent then
		return
	end

	local gui = create("ScreenGui", {
		Name = "RichTextLab",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 50,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, PlayerGui)

	local panel = create("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.52, 0.66),
		BackgroundColor3 = COLORS.Panel,
		BorderSizePixel = 0,
	}, gui)

	create("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
	create("UIStroke", { Color = COLORS.Stroke, Thickness = 1 }, panel)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, panel)
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, panel)

	--[[ TITLE ]]

	local header = create("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0.08, 0),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
	}, panel)

	create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "RICH TEXT LAB",
		TextColor3 = COLORS.Faded,
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)

	local close = create("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = COLORS.Button,
		BorderSizePixel = 0,
		Text = "X",
		TextColor3 = COLORS.Text,
		TextSize = 14,
		Font = Enum.Font.GothamBold,
	}, header)

	create("UICorner", { CornerRadius = UDim.new(0, 6) }, close)

	--[[ PREVIEW: the render container ]]

	local preview = create("Frame", {
		Name = "Preview",
		Size = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = COLORS.Preview,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = 2,
	}, panel)

	create("UICorner", { CornerRadius = UDim.new(0, 8) }, preview)

	--[[ INPUT ]]

	local input = create("TextBox", {
		Name = "Input",
		Size = UDim2.new(1, 0, 0.26, 0),
		BackgroundColor3 = COLORS.Input,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		MultiLine = true,
		Text = PLACEHOLDER,
		PlaceholderText = PLACEHOLDER,
		PlaceholderColor3 = COLORS.Faded,
		TextColor3 = COLORS.Text,
		TextSize = 15,
		Font = Enum.Font.Code,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 3,
	}, panel)

	create("UICorner", { CornerRadius = UDim.new(0, 8) }, input)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
	}, input)

	--[[ BUTTONS ]]

	local bar = create("Frame", {
		Name = "Actions",
		Size = UDim2.new(1, 0, 0.1, 0),
		BackgroundTransparency = 1,
		LayoutOrder = 4,
	}, panel)

	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, bar)

	local display = createButton("DISPLAY", COLORS.Accent, 1, bar)
	local clear = createButton("CLEAR", COLORS.Button, 2, bar)
	local preset = createButton("PRESET", COLORS.Button, 3, bar)

	self.Gui = gui
	self.Preview = preview
	self.Input = input
	self.PresetButton = preset

	self:refreshPresetButton()

	display.Activated:Connect(function()
		self:Display()
	end)

	clear.Activated:Connect(function()
		self:Clear()
	end)

	preset.Activated:Connect(function()
		self:CyclePreset()
	end)

	close.Activated:Connect(function()
		self:Close()
	end)
end

--[=[
	The list of presets the button cycles through: the config's, plus `Defaults`
	alone, which is what a screen with no preset gets, so it must be testable here
	too.

	Sorted by name so the button does not change order between sessions: the order
	of a `pairs` over the config is not the same twice.
]=]
function RichTextLabController:buildPresetList()
	local names = { "Defaults" }

	for name in Config.Presets do
		table.insert(names, name)
	end

	table.sort(names, function(a, b)
		if a == "Defaults" then return true end
		if b == "Defaults" then return false end

		return a < b
	end)

	self.Presets = names
end

function RichTextLabController:currentPreset() : string?
	local name = self.Presets[self.PresetIndex]

	return if name == "Defaults" then nil else name
end

function RichTextLabController:refreshPresetButton()
	local button = self.PresetButton
	if not button then return end

	button.Text = `PRESET: {self.Presets[self.PresetIndex]}`
end

--[=[
	The preview handle, created with the current preset.
]=]
function RichTextLabController:getHandle() : any
	if self.Handle then
		return self.Handle
	end

	local preview = self.Preview
	if not preview then
		return nil
	end

	self.Handle = self.Controllers.RichTextController:Bind(preview, {
		Preset = self:currentPreset(),
	})

	return self.Handle
end

--[[ API ]]

--[=[
	Draws whatever is in the box.
]=]
function RichTextLabController:Display()
	local input = self.Input
	local handle = self:getHandle()
	if not input or not handle then return end

	handle:Write(input.Text)
end

--[=[
	Clears the preview without closing the workbench.
]=]
function RichTextLabController:Clear()
	local handle = self.Handle
	if not handle then return end

	handle:Clear(true)
end

--[=[
	The next preset in the list.

	It releases the old handle instead of reusing it: a new preset must arrive at a
	clean configuration, or what the previous preset requested would keep applying
	underneath (see the header).
]=]
function RichTextLabController:CyclePreset()
	self.PresetIndex += 1
	if self.PresetIndex > #self.Presets then
		self.PresetIndex = 1
	end

	self:refreshPresetButton()

	local preview = self.Preview
	if preview then
		self.Controllers.RichTextController:Release(preview)
		self.Handle = nil
	end

	self:Display()
end

function RichTextLabController:Open()
	self:build()

	local gui = self.Gui
	if gui then
		gui.Enabled = true
	end
end

function RichTextLabController:Close()
	local gui = self.Gui
	if gui then
		gui.Enabled = false
	end
end

function RichTextLabController:Toggle() : boolean
	local gui = self.Gui

	if gui and gui.Enabled then
		self:Close()

		return false
	end

	self:Open()

	return true
end

function RichTextLabController:IsOpen() : boolean
	local gui = self.Gui

	return gui ~= nil and gui.Enabled
end

--[[ LIFECYCLE ]]

function RichTextLabController:construct()
	self:buildPresetList()

	-- Cmdr's `richtext` command opens it, through the server: permission to run
	-- commands lives there, and a workbench the client opened on its own would be a
	-- dev screen in any player's hands.
	Framework:Listen("RichTextLabToggle", function()
		self:Toggle()
	end)
end

function RichTextLabController:start()
end

function RichTextLabController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return RichTextLabController
