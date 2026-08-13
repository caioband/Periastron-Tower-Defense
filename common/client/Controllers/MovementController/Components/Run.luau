local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local movementController = require(script.Parent.Parent)

local Camera = workspace.CurrentCamera
local Player = Players.LocalPlayer

local module = {
	SETTINGS = {
		WALK_SPEED = 16,
		RUN_SPEED = 24,
	},
}

function module:begin(character)
	self.character = character
	self.humanoid = character:WaitForChild("Humanoid")

	self.connections = {}
	self.isRunning = false

	local function updateAnimation()
		local runAnimation = movementController:getAnimation("Run")
		if not runAnimation then return end

		local isMoving = self.humanoid.MoveDirection.Magnitude > 0

		if self.isRunning and isMoving then
			if not runAnimation.IsPlaying then
				runAnimation:Play()
			end
		else
			if runAnimation.IsPlaying then
				runAnimation:Stop()
			end
		end
	end

	table.insert(self.connections, self.humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(updateAnimation))

	table.insert(self.connections, self.humanoid.Jumping:Connect(function(active)
		local runAnimation = movementController:getAnimation("Run")
		if active then
			if runAnimation and runAnimation.IsPlaying then
				runAnimation:Stop()
			end
		end

		if not active and self.isRunning then
			task.wait(0.55)
			updateAnimation()
		end
	end))

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode ~= Enum.KeyCode.LeftShift then return end

		self.humanoid.WalkSpeed = self.SETTINGS.RUN_SPEED
		self.isRunning = true

		updateAnimation()

		local Tween = TweenService:Create(Camera, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {FieldOfView = 78})
		Tween:Play()
	end))

	table.insert(self.connections, UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode ~= Enum.KeyCode.LeftShift then return end

		if self.humanoid.WalkSpeed == self.SETTINGS.RUN_SPEED then
			self.humanoid.WalkSpeed = self.SETTINGS.WALK_SPEED
		end

		self.isRunning = false

		updateAnimation()

		local Tween = TweenService:Create(Camera, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {FieldOfView = 70})
		Tween:Play()
	end))
end

function module:stop()
	for _, connection in (self.connections) do
		connection:Disconnect()
	end

	self.isRunning = nil
	self.connections = nil
end

return module
