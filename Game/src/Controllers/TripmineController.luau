local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Assets = Shared:WaitForChild("Assets")

local Me = require(Vendor.Me)
local Framework = Me.new()

local THROW_DURATION = 0.35
local THROW_HEIGHT = 4
local EXPLOSION_LIFETIME = 5

local TripmineController = {
	Controllers = {
		UnitPlacementController = {},
		MusicController = {}
	},
	Mines = {},
	MinesByUnit = {},
}

function TripmineController:getTemplate()
	if not self.template then
		local vfxFolder = Assets:FindFirstChild("VFX")
		self.template = vfxFolder and vfxFolder:FindFirstChild("SubspaceTripmine")
	end
	return self.template
end

function TripmineController:getUnitModel(unitId)
	local placement = self.Controllers.UnitPlacementController
	local class = placement and placement.classesById and placement.classesById[unitId]
	return class and class.model or nil
end

function TripmineController:playTriggerSound(parent)
	-- A Key faz o papel do ActiveSound antigo: só uma mina soando por vez.
	self.Controllers.MusicController:PlaySFX("SubspaceTripmineSFX", {
		Parent = parent,
		Key = "SubspaceTripmine",
	})
end

function TripmineController:throwMine(mineModel, startCF, endCF)
	mineModel:PivotTo(startCF)
	local startedAt = os.clock()
	local spin = math.random() * math.pi * 2
	local conn
	conn = RunService.RenderStepped:Connect(function()
		if not mineModel.Parent then
			conn:Disconnect()
			return
		end
		local alpha = math.min(1, (os.clock() - startedAt) / THROW_DURATION)
		local height = math.sin(alpha * math.pi) * THROW_HEIGHT
		local cf = startCF:Lerp(endCF, alpha) + Vector3.new(0, height, 0)
		mineModel:PivotTo(cf * CFrame.Angles(spin * alpha, 0, 0))
		if alpha >= 1 then
			conn:Disconnect()
			mineModel:PivotTo(endCF)
		end
	end)
end

function TripmineController:spawnMine(unitId, mineId, mineCF)
	local template = self:getTemplate()
	if not template then return end

	local mine = template:Clone()
	mine.Name = "SubspaceTripmine_" .. mineId
	mine.Parent = workspace.CurrentCamera

	self.Mines[mineId] = mine
	self.MinesByUnit[unitId] = self.MinesByUnit[unitId] or {}
	self.MinesByUnit[unitId][mineId] = true

	local unitModel = self:getUnitModel(unitId)
	local startCF = mineCF
	if unitModel and unitModel.Parent then
		startCF = CFrame.new(unitModel:GetPivot().Position + Vector3.new(0, 2, 0))
	end

	self:throwMine(mine, startCF, mineCF)
end

function TripmineController:triggerMine(unitId, mineId)
	local mine = self.Mines[mineId]
	self.Mines[mineId] = nil
	if self.MinesByUnit[unitId] then
		self.MinesByUnit[unitId][mineId] = nil
	end
	if not mine or not mine.Parent then return end

	local root = mine.PrimaryPart or mine:FindFirstChildWhichIsA("BasePart")
	if root then
		for _, descendant in mine:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant:Emit(descendant:GetAttribute("EmitCount") or 15)
			elseif descendant:IsA("BasePart") then
				descendant.Transparency = 1
			end
		end
		if root:IsA("BasePart") then
			root.Transparency = 1
		end
		self:playTriggerSound(root)
	end

	task.delay(EXPLOSION_LIFETIME, function()
		if mine and mine.Parent then
			mine:Destroy()
		end
	end)
end

function TripmineController:clearUnitMines(unitId)
	local mines = self.MinesByUnit[unitId]
	if not mines then return end
	for mineId in mines do
		local mine = self.Mines[mineId]
		self.Mines[mineId] = nil
		if mine and mine.Parent then
			mine:Destroy()
		end
	end
	self.MinesByUnit[unitId] = nil
end

function TripmineController:construct()
	Framework:Listen("TripmineThrown", function(unitId, mineId, mineCF)
		self:spawnMine(unitId, mineId, mineCF)
	end)

	Framework:Listen("TripmineTriggered", function(unitId, mineId)
		self:triggerMine(unitId, mineId)
	end)

	Framework:Listen("RemoveUnit", function(unitId)
		self:clearUnitMines(unitId)
	end)
end

function TripmineController:start()
end

function TripmineController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return TripmineController
