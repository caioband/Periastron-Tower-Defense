local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local movementController = require(script.Parent.Parent)

local Player = Players.LocalPlayer

local module = {
	SETTINGS = {
		KEYBIND = Enum.KeyCode.Q,
		ROLL_SPEED = 45,
		COOLDOWN = 1.5,
		AFTERIMAGE_INTERVAL = 0.03,
		AFTERIMAGE_LIFETIME = 0.2,
		AFTERIMAGE_TRANSPARENCY = 0.4,
	},
	isRolling = false,
	lastRoll = 0
}

function module:createAfterimage()
	local folder = Instance.new("Folder")
	folder.Name = "Afterimage"
	folder.Parent = workspace.Terrain

	for _, part in ipairs(self.character:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 1 then
			local clone = part:Clone()
			for _, child in ipairs(clone:GetChildren()) do
				if not child:IsA("DataModelMesh") then
					child:Destroy()
				end
			end

			clone.Color = Color3.fromRGB(255, 255, 255)
			clone.Material = Enum.Material.SmoothPlastic

			if clone:IsA("MeshPart") then
				clone.TextureID = ""
			end

			clone.Anchored = true
			clone.CanCollide = false
			clone.CanTouch = false
			clone.CanQuery = false
			clone.CastShadow = false
			clone.CFrame = part.CFrame
			clone.Transparency = self.SETTINGS.AFTERIMAGE_TRANSPARENCY
			clone.Parent = folder
			TweenService:Create(clone, TweenInfo.new(self.SETTINGS.AFTERIMAGE_LIFETIME, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), {
				Transparency = 1
			}):Play()
		end
	end

	task.delay(self.SETTINGS.AFTERIMAGE_LIFETIME, function()
		folder:Destroy()
	end)
end

--[=[
	Quanto do cooldown ainda falta, de 1 (acabou de dar o dash) a 0 (pronto). O
	botao do celular desenha a recarga com isto.
]=]
function module:getCooldownAlpha() : number
	local elapsed = os.clock() - self.lastRoll
	return math.clamp(1 - elapsed / self.SETTINGS.COOLDOWN, 0, 1)
end

--[=[
	O dash, se puder: a tecla do teclado e o botao do celular chamam o mesmo. Devolve
	se o dash de fato saiu.
]=]
function module:tryDash() : boolean
	if not self.rootPart or not self.humanoid then return false end
	if self.isRolling or (os.clock() - self.lastRoll < self.SETTINGS.COOLDOWN) then return false end

	do
		self.isRolling = true
		self.lastRoll = os.clock()

		local rollAnimation = movementController:getAnimation("Dash")
		if not rollAnimation then
			self.isRolling = false
			return false
		end

		local isAirborne = self.humanoid.FloorMaterial == Enum.Material.Air or self.humanoid:GetState() == Enum.HumanoidStateType.Freefall

		local att = Instance.new("Attachment")
		att.Parent = self.rootPart

		local bv = Instance.new("LinearVelocity")
		bv.Attachment0 = att
		bv.ForceLimitMode = Enum.ForceLimitMode.PerAxis

		if isAirborne then
			bv.MaxAxesForce = Vector3.new(999999, 999999, 999999)
		else
			bv.MaxAxesForce = Vector3.new(999999, 0, 999999)
		end

		bv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		bv.RelativeTo = Enum.ActuatorRelativeTo.World
		bv.Parent = self.rootPart

		local currentSpeed = Instance.new("NumberValue")
		currentSpeed.Value = self.SETTINGS.ROLL_SPEED

		-- Afterimage logic inside Heartbeat
		local lastAfterimageTime = 0
		local renderConnection
		renderConnection = RunService.Heartbeat:Connect(function()
			if not self.isRolling or not bv.Parent then
				if renderConnection then renderConnection:Disconnect() end
				return
			end

			local currentTime = os.clock()
			if currentTime - lastAfterimageTime >= self.SETTINGS.AFTERIMAGE_INTERVAL then
				lastAfterimageTime = currentTime
				self:createAfterimage()
			end

			local flatDirection = Vector3.new(self.rootPart.CFrame.LookVector.X, 0, self.rootPart.CFrame.LookVector.Z)
			if flatDirection.Magnitude > 0.001 then
				flatDirection = flatDirection.Unit
			else
				flatDirection = Vector3.new(0, 0, -1)
			end

			local targetY = (isAirborne and bv.MaxAxesForce.Y > 0) and 20 or 0
			bv.VectorVelocity = Vector3.new(flatDirection.X * currentSpeed.Value, targetY, flatDirection.Z * currentSpeed.Value)
		end)

		if isAirborne then
			task.delay(0.1, function()
				if bv and bv.Parent then
					bv.MaxAxesForce = Vector3.new(999999, 0, 999999)
				end
			end)
		end

		task.delay(0.15, function()
			if currentSpeed then
				TweenService:Create(currentSpeed, TweenInfo.new(1.25, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {Value = 0}):Play()
			end
		end)

		rollAnimation:Play()

		rollAnimation.Stopped:Once(function()
			if renderConnection then renderConnection:Disconnect() end
			if currentSpeed then currentSpeed:Destroy() end
			if bv then bv:Destroy() end
			if att then att:Destroy() end
			self.isRolling = false
		end)
	end

	return true
end

function module:begin(character)
	self.character = character
	self.humanoid = character:WaitForChild("Humanoid")
	self.rootPart = character:WaitForChild("HumanoidRootPart")

	self.connections = {}

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode ~= self.SETTINGS.KEYBIND then return end

		self:tryDash()
	end))
end

function module:stop()
	if self.connections then
		for _, connection in pairs(self.connections) do
			connection:Disconnect()
		end
		self.connections = nil
	end

	-- Sem personagem vivo o botao do celular nao pode dar dash num corpo morto.
	self.humanoid = nil
	self.rootPart = nil
end

return module
