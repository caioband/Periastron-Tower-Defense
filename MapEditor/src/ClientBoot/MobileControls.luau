local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local State = require(script.Parent.State)
local Placement = require(script.Parent.Placement)
local BuildCamera = require(script.Parent.BuildCamera)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local THEME = UI.THEME

local MobileControls = {}

local BUTTON_SIZE = Vector2.new(64, 44)
local GAP = 6

local handlers = {}
local gui = nil
local bar = nil
local vertical = nil
local active = false
local multi = false
local currentKey = nil
local holdInput = nil

local function newButton(parent, text, order, color, textColor)
	local button = Instance.new("TextButton")
	button.Name = text
	button.LayoutOrder = order
	button.Size = UDim2.fromOffset(BUTTON_SIZE.X, BUTTON_SIZE.Y)
	button.BackgroundColor3 = color or THEME.Button
	button.TextColor3 = textColor or THEME.Text
	button.Font = Enum.Font.GothamBold
	button.TextSize = 14
	button.TextWrapped = true
	button.Text = text
	button.AutoButtonColor = true

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = THEME.Stroke
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button

	button.Parent = parent
	return button
end

local function addLayout(parent, direction)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, GAP)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Parent = parent
end

local function holdButton(parent, text, order, value)
	local button = newButton(parent, text, order)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			holdInput = input
			BuildCamera.setVerticalInput(value)
		end
	end)
	return button
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MapEditorMobile"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 11
	gui.Enabled = false

	local scale = Instance.new("UIScale")
	scale.Parent = gui
	local function rescale()
		local viewport = workspace.CurrentCamera.ViewportSize
		scale.Scale = math.clamp(math.min(viewport.X / 1000, viewport.Y / 600), 0.6, 1.6)
	end
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	rescale()

	bar = Instance.new("Frame")
	bar.Name = "ActionBar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -12)
	bar.Size = UDim2.fromOffset(0, BUTTON_SIZE.Y)
	bar.AutomaticSize = Enum.AutomaticSize.X
	addLayout(bar, Enum.FillDirection.Horizontal)
	bar.Parent = gui

	vertical = Instance.new("Frame")
	vertical.Name = "CameraHeight"
	vertical.BackgroundTransparency = 1
	vertical.AnchorPoint = Vector2.new(0, 1)
	vertical.Position = UDim2.new(0, 8, 1, -12)
	vertical.Size = UDim2.fromOffset(BUTTON_SIZE.X, 0)
	vertical.AutomaticSize = Enum.AutomaticSize.Y
	addLayout(vertical, Enum.FillDirection.Vertical)
	vertical.Parent = gui

	holdButton(vertical, "Up", 1, 1)
	holdButton(vertical, "Down", 2, -1)

	UserInputService.InputEnded:Connect(function(input)
		if input == holdInput then
			holdInput = nil
			BuildCamera.setVerticalInput(0)
		end
	end)

	gui.Parent = player:WaitForChild("PlayerGui")
end

local function toggleMulti()
	multi = not multi
	currentKey = nil
	UI.toast(multi and "Multi-select on: taps add or remove objects." or "Multi-select off.", "info")
end

local function actionsFor()
	if State.mode == "Playtest" then
		return "playtest", {}
	end

	if Placement.isActive() then
		return "place", {
			{ "Place", handlers.confirm, "on" },
			{ "Turn L", function()
				handlers.rotate(Vector3.yAxis, -1)
			end },
			{ "Turn R", function()
				handlers.rotate(Vector3.yAxis, 1)
			end },
			{ "Tilt", function()
				handlers.rotate(Vector3.xAxis, 1)
			end },
			{ "Cancel", handlers.cancel, "danger" },
		}
	end

	local key = "idle"
	local entries = {}
	if #State.selection > 0 then
		key = "sel"
		table.insert(entries, { "Turn L", function()
			handlers.rotate(Vector3.yAxis, -1)
		end })
		table.insert(entries, { "Turn R", function()
			handlers.rotate(Vector3.yAxis, 1)
		end })
		table.insert(entries, { "Copy", handlers.copy })
		table.insert(entries, { "Dupe", handlers.duplicate })
		table.insert(entries, { "Delete", handlers.delete, "danger" })
		table.insert(entries, { "Done", handlers.deselect })
	end
	if State.clipboard and #State.clipboard > 0 then
		key ..= "+paste"
		table.insert(entries, { "Paste", handlers.paste })
	end
	table.insert(entries, { "Multi", toggleMulti, if multi then "on" else nil })
	if multi then
		key ..= "+multi"
	end
	return key, entries
end

local function rebuild(entries)
	for _, child in bar:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	for i, entry in entries do
		local style = entry[3]
		local color = if style == "on" then THEME.ButtonOn elseif style == "danger" then THEME.Danger else THEME.Button
		local textColor = if style == "on" then THEME.TextDark else THEME.Text
		local button = newButton(bar, entry[1], i, color, textColor)
		local callback = entry[2]
		button.Activated:Connect(function()
			callback()
		end)
	end
end

function MobileControls.isSupported()
	return UserInputService.TouchEnabled
end

function MobileControls.multiSelect()
	return active and multi
end

function MobileControls.init(actionHandlers)
	handlers = actionHandlers
end

function MobileControls.setActive(on)
	if not MobileControls.isSupported() then
		return
	end
	if not gui then
		build()
	end
	active = on
	gui.Enabled = on
	currentKey = nil
	if not on then
		multi = false
		holdInput = nil
		BuildCamera.setVerticalInput(0)
	end
end

function MobileControls.update()
	if not active or not gui then
		return
	end
	local modal = UI.modalOpen()
	bar.Visible = not modal
	vertical.Visible = not modal
	local key, entries = actionsFor()
	if key ~= currentKey then
		currentKey = key
		rebuild(entries)
	end
end

return MobileControls