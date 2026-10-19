local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("MapEditor").Config)
local Maid = require(script.Parent.Maid)
local Signal = require(script.Parent.Signal)

local player = Players.LocalPlayer

local BuildCamera = {}
BuildCamera.RightClick = Signal.new()

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

	if wheelImpulse ~= 0 then
		position += rot.LookVector * wheelImpulse
		wheelImpulse = 0
	end

	camera.CFrame = CFrame.new(position) * rot
end

function BuildCamera.isEnabled()
	return enabled
end

function BuildCamera.isLooking()
	return looking
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

	RunService:BindToRenderStep("MapEditorCamera", Enum.RenderPriority.Camera.Value + 1, update)
	maid:Give(function()
		RunService:UnbindFromRenderStep("MapEditorCamera")
	end)

	maid:Give(UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseButton2 and not processed then
			looking = true
			rightMoved = false
			rightDownAt = os.clock()
			rightDownPos = UserInputService:GetMouseLocation()
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end))

	maid:Give(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 and looking then
			looking = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			if not rightMoved and os.clock() - rightDownAt < 0.3 then
				BuildCamera.RightClick:Fire(rightDownPos)
			end
		end
	end))

	maid:Give(UserInputService.InputChanged:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseMovement and looking then
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
