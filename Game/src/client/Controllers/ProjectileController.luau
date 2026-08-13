local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = Shared:WaitForChild("Assets")

local DEFAULT_SPEED = 60
local MAX_FLIGHT_TIME = 3
local ARRIVE_DISTANCE = 1

local ProjectileController = {}
ProjectileController.Library = {}

local function getRoot(instance)
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
	end
	return instance
end

local function setCFrame(instance, cf)
	if instance:IsA("Model") then
		if not instance.PrimaryPart then
			local part = instance:FindFirstChildWhichIsA("BasePart")
			if part then instance.PrimaryPart = part end
		end
		instance:PivotTo(cf)
	else
		instance.CFrame = cf
	end
end

local function targetPosition(targetModel, fallback)
	if targetModel and targetModel.Parent then
		local root = getRoot(targetModel)
		if root then
			return root.Position
		end
		return targetModel:GetPivot().Position
	end
	return fallback
end

function ProjectileController:Fire(startPos, targetModel, config, onArrive, fallbackPos)
	config = config or {}

	local fired = false
	local function finish(impactPos)
		if fired then return end
		fired = true
		if onArrive then onArrive(impactPos) end
	end

	local template = self.Library[config.Asset]
	if not template or not startPos then
		finish(fallbackPos or startPos)
		return
	end

	local speed = config.Speed or DEFAULT_SPEED
	local projectile = template:Clone()

	local lastTarget = targetPosition(targetModel, fallbackPos or startPos)
	local pos = startPos
	setCFrame(projectile, CFrame.lookAt(pos, lastTarget))
	projectile.Parent = Workspace

	local elapsed = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt

		local goal
		if targetModel and targetModel.Parent then
			goal = targetPosition(targetModel, lastTarget)
		else
			goal = fallbackPos or lastTarget
		end
		lastTarget = goal

		local toGoal = goal - pos
		local distance = toGoal.Magnitude
		local step = speed * dt

		if distance <= math.max(step, ARRIVE_DISTANCE) or elapsed >= MAX_FLIGHT_TIME then
			conn:Disconnect()
			if projectile then projectile:Destroy() end
			finish(goal)
			return
		end

		local direction = toGoal.Unit
		pos = pos + direction * step
		setCFrame(projectile, CFrame.lookAt(pos, pos + direction))
	end)
end

function ProjectileController:buildLibrary()
	local folder = Assets:FindFirstChild("Projectiles")
	if not folder then return end
	for _, asset in folder:GetChildren() do
		self.Library[asset.Name] = asset
	end
end

function ProjectileController:construct()
	self:buildLibrary()
end

function ProjectileController:start()
end

function ProjectileController:init()
	self:construct()
end

return ProjectileController
