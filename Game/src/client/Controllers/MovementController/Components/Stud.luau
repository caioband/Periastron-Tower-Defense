local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = Shared:WaitForChild("Assets")
local Bricks = Assets:WaitForChild("Bricks")

local Stud = Bricks:WaitForChild("StudPart")

local module = {
	SETTINGS = {
		TIME_IN_BETWEEN = 0.15,
		ANIMATION_INFO = TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	}
}

local random = Random.new()

local function emitStud(character, isLanding)
	local humanoidrootpart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not humanoidrootpart then return end

	local startCF
	local finalCF

	if isLanding then
		startCF = humanoidrootpart.CFrame * CFrame.new(0, -2.5, 0)

		local angle = math.rad(random:NextNumber(0, 360))
		local distance = random:NextNumber(3, 7)
		local height = random:NextNumber(1, 3)

		local offset = Vector3.new(math.cos(angle) * distance, height, math.sin(angle) * distance)

		local finalRotationX = random:NextNumber(-180, 180)
		local finalRotationY = random:NextNumber(-180, 180)
		local finalRotationZ = random:NextNumber(-180, 180)

		finalCF = CFrame.new(startCF.Position + offset) * CFrame.Angles(math.rad(finalRotationX), math.rad(finalRotationY), math.rad(finalRotationZ))
	else
		-- Isolate the position from the rotation
		local startPosCF = humanoidrootpart.CFrame * CFrame.new(0, -2.5, 0)
		startCF = startPosCF * CFrame.Angles(math.rad(random:NextNumber(0, 360)), math.rad(random:NextNumber(0, 360)), math.rad(random:NextNumber(0, 360)))

		local spreadX = random:NextNumber(-3, 3)
		local pushZ = random:NextNumber(1.5, 4)
		local endY = random:NextNumber(-2.5, -2.0) -- Stays strictly at foot level or pops up slightly

		local finalPosCF = humanoidrootpart.CFrame * CFrame.new(spreadX, endY, pushZ)

		local finalRotationX = random:NextNumber(-180, 180)
		local finalRotationY = random:NextNumber(-180, 180)
		local finalRotationZ = random:NextNumber(-180, 180)

		finalCF = finalPosCF * CFrame.Angles(math.rad(finalRotationX), math.rad(finalRotationY), math.rad(finalRotationZ))
	end

	local studClone = Stud:Clone()
	studClone.CFrame = startCF
	studClone.Anchored = true
	studClone.CanCollide = false
	studClone.Parent = workspace

	local animInfo = isLanding and TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out) or module.SETTINGS.ANIMATION_INFO

	local transparencyTween = TweenService:Create(studClone, animInfo, {Transparency = 1})
	local positionTween = TweenService:Create(studClone, animInfo, {CFrame = finalCF})

	positionTween:Play()
	transparencyTween:Play()

	task.delay(animInfo.Time, function()
		if studClone then
			studClone:Destroy()
		end
	end)
end

function module:begin(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local humanoidrootpart = character:WaitForChild("HumanoidRootPart", 10)

	if not humanoid then return end

	if self.connections ~= nil then
		self:stop()
		task.wait()
	end

	self.character = character
	self.connections = {}
	self.lastEmit = os.clock()

	table.insert(self.connections, RunService.RenderStepped:Connect(function()
		if self.lastEmit and (os.clock() - self.lastEmit) < self.SETTINGS.TIME_IN_BETWEEN then
			return
		end

		if humanoid.MoveDirection.Magnitude <= 0 then return end
		if humanoid:GetState() ~= Enum.HumanoidStateType.Running and humanoid:GetState() ~= Enum.HumanoidStateType.RunningNoPhysics then return end

		self.lastEmit = os.clock()
		emitStud(character, false)
	end))

	table.insert(self.connections, humanoid.StateChanged:Connect(function(oldState, newState)
		if newState == Enum.HumanoidStateType.Landed then
			for i = 1, 6 do
				emitStud(character, true)
			end
		end
	end))
end

function module:stop()
	if self.connections then
		for _, connection in (self.connections) do
			connection:Disconnect()
		end
		self.connections = nil
	end
end

return module
