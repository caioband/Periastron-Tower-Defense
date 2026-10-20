local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("MapEditor").Config)
local Maid = require(script.Parent.Maid)
local Signal = require(script.Parent.Signal)
local Pointer = require(script.Parent.Pointer)

local player = Players.LocalPlayer

local BuildCamera = {}
BuildCamera.RightClick = Signal.new()
BuildCamera.Tap = Signal.new()

local TOUCH_LOOK_SENSITIVITY = 0.3
local TOUCH_PAN_SPEED = 0.08
local TOUCH_ZOOM_SPEED = 0.12
local TOUCH_DRAG_THRESHOLD = 10
local TAP_MAX_TIME = 0.35
local VERTICAL_SPEED_MULTIPLIER = 0.6

local maid = Maid.new()
local enabled = false
local position = Vector3.zero
local yaw, pitch = 0, -0.6
local looking = false
local rightDownAt, rightDownPos = 0, Vector2.zero
local rightMoved = false
local wheelImpulse = 0
local controls = nil
local anchoredRoot = nil

local touches = {}
local touchOrder = {}
local pinch = nil
local gestureUsedMulti = false
local touchFilter = nil
local verticalInput = 0

local function getControls()
	local success, module = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5))
	end)
	if success and module then
		return module:GetControls()
	end
	return nil
end

local function rotation()
	return CFrame.fromOrientation(pitch, yaw, 0)
end

local function keyAxis(positive, negative)
	local value = 0
	if UserInputService:IsKeyDown(positive) then
		value += 1
	end
	if UserInputService:IsKeyDown(negative) then
		value -= 1
	end
	return value
end

local function blocked()
	return touchFilter ~= nil and touchFilter() == true
end

local function clearTouches()
	table.clear(touches)
	table.clear(touchOrder)
	pinch = nil
	gestureUsedMulti = false
end

local function update(dt)
	local camera = workspace.CurrentCamera
	local typing = UserInputService:GetFocusedTextBox() ~= nil
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	local rot = rotation()

	if not typing and not ctrl then
		local forward = keyAxis(Enum.KeyCode.W, Enum.KeyCode.S)
		local right = keyAxis(Enum.KeyCode.D, Enum.KeyCode.A)
		local up = keyAxis(Enum.KeyCode.Space, Enum.KeyCode.C)
		local fast = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and Config.CAMERA_FAST_MULTIPLIER or 1
		local speed = Config.CAMERA_SPEED * fast
		position += (rot.LookVector * forward + rot.RightVector * right + Vector3.yAxis * up) * speed * dt
	end

	if verticalInput ~= 0 then
		position += Vector3.yAxis * verticalInput * Config.CAMERA_SPEED * VERTICAL_SPEED_MULTIPLIER * dt
	end

	if wheelImpulse ~= 0 then
		position += rot.LookVector * wheelImpulse
		wheelImpulse = 0
	end

	camera.CFrame = CFrame.new(position) * rot
end

local function touchBegan(input, processed)
	if processed or blocked() then
		return
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	touches[input] = { pos = pos, start = pos, at = os.clock(), moved = false }
	table.insert(touchOrder, input)
	if #touchOrder >= 2 then
		gestureUsedMulti = true
		pinch = nil
		for _, t in touches do
			t.moved = true
		end
	end
end

local function touchChanged(input)
	local t = touches[input]
	if not t then
		return
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	local delta = pos - t.pos
	t.pos = pos
	if blocked() then
		return
	end

	if #touchOrder == 1 then
		if not t.moved and (pos - t.start).Magnitude > TOUCH_DRAG_THRESHOLD then
			t.moved = true
		end
		if t.moved then
			local sensitivity = math.rad(TOUCH_LOOK_SENSITIVITY)
			yaw -= delta.X * sensitivity
			pitch = math.clamp(pitch - delta.Y * sensitivity, math.rad(-89), math.rad(89))
		end
	elseif #touchOrder >= 2 then
		local a = touches[touchOrder[1]]
		local b = touches[touchOrder[2]]
		if not (a and b) then
			return
		end
		local mid = (a.pos + b.pos) / 2
		local spread = (a.pos - b.pos).Magnitude
		if pinch then
			local rot = rotation()
			local dMid = mid - pinch.mid
			position += (-rot.RightVector * dMid.X + rot.UpVector * dMid.Y) * TOUCH_PAN_SPEED
			position += rot.LookVector * (spread - pinch.spread) * TOUCH_ZOOM_SPEED
		end
		pinch = { mid = mid, spread = spread }
	end
end

local function touchEnded(input)
	local t = touches[input]
	if not t then
		return
	end
	touches[input] = nil
	local index = table.find(touchOrder, input)
	if index then
		table.remove(touchOrder, index)
	end
	pinch = nil

	if #touchOrder == 0 then
		local wasMulti = gestureUsedMulti
		gestureUsedMulti = false
		if not wasMulti and not t.moved and os.clock() - t.at <= TAP_MAX_TIME and not blocked() then
			BuildCamera.Tap:Fire(Pointer.fromInput(input))
		end
	end
end

function BuildCamera.isEnabled()
	return enabled
end

function BuildCamera.isLooking()
	if looking then
		return true
	end
	for _, t in touches do
		if t.moved then
			return true
		end
	end
	return false
end

function BuildCamera.setTouchFilter(filter)
	touchFilter = filter
end

function BuildCamera.setVerticalInput(value)
	verticalInput = value
end

function BuildCamera.enable(startCF)
	if enabled then
		return
	end
	enabled = true

	local camera = workspace.CurrentCamera
	local cf = startCF or camera.CFrame
	position = cf.Position
	local look = cf.LookVector
	yaw = math.atan2(-look.X, -look.Z)
	pitch = math.asin(math.clamp(look.Y, -1, 1))

	camera.CameraType = Enum.CameraType.Scriptable

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		root.Anchored = true
		anchoredRoot = root
	end

	controls = controls or getControls()
	if controls then
		controls:Disable()
	end

	clearTouches()

	RunService:BindToRenderStep("MapEditorCamera", Enum.RenderPriority.Camera.Value + 1, update)
	maid:Give(function()
		RunService:UnbindFromRenderStep("MapEditorCamera")
	end)

	maid:Give(UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Touch then
			touchBegan(input, processed)
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 and not processed then
			looking = true
			rightMoved = false
			rightDownAt = os.clock()
			rightDownPos = UserInputService:GetMouseLocation()
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end))

	maid:Give(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			touchEnded(input)
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 and looking then
			looking = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			if not rightMoved and os.clock() - rightDownAt < 0.3 then
				BuildCamera.RightClick:Fire(rightDownPos)
			end
		end
	end))

	maid:Give(UserInputService.InputChanged:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Touch then
			touchChanged(input)
		elseif input.UserInputType == Enum.UserInputType.MouseMovement and looking then
			local delta = input.Delta
			if delta.Magnitude > 2 then
				rightMoved = true
			end
			local sensitivity = math.rad(Config.CAMERA_SENSITIVITY)
			yaw -= delta.X * sensitivity
			pitch = math.clamp(pitch - delta.Y * sensitivity, math.rad(-89), math.rad(89))
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
			wheelImpulse += input.Position.Z * 4
		end
	end))
end

function BuildCamera.disable()
	if not enabled then
		return
	end
	enabled = false
	looking = false
	verticalInput = 0
	clearTouches()
	maid:Clean()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default

	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom

	if anchoredRoot and anchoredRoot.Parent then
		anchoredRoot.Anchored = false
	end
	anchoredRoot = nil

	if controls then
		controls:Enable()
	end
end

function BuildCamera.focus(center, radius)
	local distance = math.max(12, radius * 2.2)
	local rot = CFrame.fromOrientation(math.rad(-35), yaw, 0)
	pitch = math.rad(-35)
	position = center - rot.LookVector * distance
end

function BuildCamera.setPosition(cf)
	position = cf.Position
	local look = cf.LookVector
	yaw = math.atan2(-look.X, -look.Z)
	pitch = math.asin(math.clamp(look.Y, -1, 1))
end

return BuildCamera