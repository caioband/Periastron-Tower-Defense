local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local State = require(script.Parent.State)
local UI = require(script.Parent.UI)
local Pointer = require(script.Parent.Pointer)

local player = Players.LocalPlayer

local Hotkeys = {}

local TOGGLE_KEY = Enum.KeyCode.K
local COLLAPSED_HEIGHT = 38

local panel = nil
local list = nil
local toggle = nil
local expandedSize = nil
local collapsed = false

local function setLabel(text)
	if not toggle then
		return
	end
	toggle.Text = text
	local label = toggle:FindFirstChild("Label")
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function applyCollapsed()
	if not panel then
		return
	end
	if collapsed then
		panel.Size = UDim2.new(expandedSize.X.Scale, expandedSize.X.Offset, 0, COLLAPSED_HEIGHT)
	else
		panel.Size = expandedSize
	end
	if list then
		list.Visible = not collapsed
	end
	setLabel(if collapsed then "+" else "-")
end

function Hotkeys.toggle()
	collapsed = not collapsed
	applyCollapsed()
end

function Hotkeys.init()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("MapEditorUI")
	panel = gui:WaitForChild("Hotkeys")
	list = panel:FindFirstChild("List")
	toggle = panel:FindFirstChild("Toggle")
	expandedSize = panel.Size
	panel.Visible = false

	if toggle and toggle:IsA("GuiButton") then
		toggle.Activated:Connect(Hotkeys.toggle)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= TOGGLE_KEY then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if State.active and State.mode == "Build" then
			Hotkeys.toggle()
		end
	end)

	applyCollapsed()
end

function Hotkeys.update()
	if not panel then
		return
	end
	local show = State.active
		and State.mode == "Build"
		and #State.selection == 0
		and not UI.modalOpen()
		and not Pointer.isTouch()
		and UserInputService.KeyboardEnabled
	if panel.Visible ~= show then
		panel.Visible = show
	end
end

function Hotkeys.hide()
	if panel then
		panel.Visible = false
	end
end

return Hotkeys