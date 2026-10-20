local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Pointer = {}

local usingTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local lastTouch = nil

local function center()
	local viewport = workspace.CurrentCamera.ViewportSize
	return Vector2.new(viewport.X / 2, viewport.Y / 2)
end

UserInputService.LastInputTypeChanged:Connect(function(inputType)
	if inputType == Enum.UserInputType.Touch then
		usingTouch = true
	elseif inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseWheel then
		usingTouch = false
	end
end)

function Pointer.isTouch()
	return usingTouch
end

function Pointer.fromInput(input)
	local inset = GuiService:GetGuiInset()
	return Vector2.new(input.Position.X, input.Position.Y) + inset
end

function Pointer.setTouch(position)
	lastTouch = position
	usingTouch = true
end

function Pointer.centerTouch()
	lastTouch = center()
end

function Pointer.location()
	if usingTouch then
		return lastTouch or center()
	end
	return UserInputService:GetMouseLocation()
end

return Pointer