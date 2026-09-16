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
		RUN_FOV = 78,
		WALK_FOV = 70,
	},

	-- (isRunning : boolean) -- o botao de correr do celular acende e apaga por aqui.
	Changed = Instance.new("BindableEvent"),
	isRunning = false,
}

local function tweenFov(fov : number)
	TweenService:Create(Camera, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = fov }):Play()
end

function module:updateAnimation()
	local runAnimation = movementController:getAnimation("Run")
	if not runAnimation or not self.humanoid then return end

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

--[=[
	Liga ou desliga a corrida. O Shift do teclado segura (liga no aperto, desliga
	no soltar); o botao do celular alterna -- os dois passam por aqui.
]=]
function module:setRunning(running : boolean)
	if not self.humanoid or running == self.isRunning then return end

	if running then
		self.humanoid.WalkSpeed = self.SETTINGS.RUN_SPEED
	elseif self.humanoid.WalkSpeed == self.SETTINGS.RUN_SPEED then
		self.humanoid.WalkSpeed = self.SETTINGS.WALK_SPEED
	end

	self.isRunning = running

	self:updateAnimation()
	tweenFov(running and self.SETTINGS.RUN_FOV or self.SETTINGS.WALK_FOV)

	self.Changed:Fire(running)
end

function module:toggle()
	self:setRunning(not self.isRunning)
end

function module:begin(character)
	self.character = character
	self.humanoid = character:WaitForChild("Humanoid")

	self.connections = {}
	self.isRunning = false
	self.Changed:Fire(false)

	table.insert(self.connections, self.humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
		self:updateAnimation()
	end))

	table.insert(self.connections, self.humanoid.Jumping:Connect(function(active)
		local runAnimation = movementController:getAnimation("Run")
		if active then
			if runAnimation and runAnimation.IsPlaying then
				runAnimation:Stop()
			end
		end

		if not active and self.isRunning then
			task.wait(0.55)
			self:updateAnimation()
		end
	end))

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode ~= Enum.KeyCode.LeftShift then return end

		self:setRunning(true)
	end))

	table.insert(self.connections, UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode ~= Enum.KeyCode.LeftShift then return end

		self:setRunning(false)
	end))
end

function module:stop()
	if self.connections then
		for _, connection in (self.connections) do
			connection:Disconnect()
		end
	end

	-- Morrer correndo nao pode deixar a camera aberta no FOV da corrida.
	if self.isRunning then
		tweenFov(self.SETTINGS.WALK_FOV)
	end

	self.isRunning = false
	self.humanoid = nil
	self.connections = nil

	self.Changed:Fire(false)
end

return module
