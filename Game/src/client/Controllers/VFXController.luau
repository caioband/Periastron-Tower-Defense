local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Framework = Me.new()

local DEFAULT_LIFETIME = 2
local DEFAULT_EMIT_COUNT = 25

local VFXController = {
	Controllers = {
		UnitPlacementController = {}
	}
}
VFXController.Library = {}

local function resolveBaseCFrame(target, offset)
	if typeof(target) == "CFrame" then
		return target * CFrame.new(offset), nil
	end
	if typeof(target) == "Vector3" then
		return CFrame.new(target + offset), nil
	end
	if typeof(target) == "Instance" then
		if target:IsA("Model") then
			return target:GetPivot() * CFrame.new(offset), target
		elseif target:IsA("BasePart") then
			return target.CFrame * CFrame.new(offset), target
		end
	end
	return nil, nil
end

local function setClonePivot(clone, cf)
	if clone:IsA("Model") then
		if not clone.PrimaryPart then
			local part = clone:FindFirstChildWhichIsA("BasePart")
			if part then clone.PrimaryPart = part end
		end
		clone:PivotTo(cf)
	elseif clone:IsA("BasePart") then
		clone.CFrame = cf
	end
end

local function getCloneRoot(clone)
	if clone:IsA("Model") then
		return clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	end
	return clone
end

local function getModelRoot(model)
	return model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
end

function VFXController:Play(effectName, target, options)
	options = options or {}
	local template = self.Library[effectName]
	if not template then return end

	local offset = options.Offset or Vector3.new(0, 0, 0)
	local baseCF, targetModel = resolveBaseCFrame(target, offset)
	if not baseCF then return end

	local clone = template:Clone()
	setClonePivot(clone, baseCF)
	clone.Parent = Workspace

	if options.Attach and (typeof(target) == "Instance" and target:IsA("Model")) then
		local targetRoot = getModelRoot(target)
		local cloneRoot = getCloneRoot(clone)
		if targetRoot and cloneRoot then
			cloneRoot.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = cloneRoot
			weld.Part1 = targetRoot
			weld.Parent = cloneRoot
		end
	end

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			local count = options.EmitCount or descendant:GetAttribute("EmitCount") or DEFAULT_EMIT_COUNT
			descendant:Emit(count)
		elseif descendant:IsA("Sound") then
			descendant:Play()
		elseif descendant:IsA("Light") then
			descendant.Enabled = true
		end
	end

	local lifetime = options.Duration or clone:GetAttribute("Lifetime") or DEFAULT_LIFETIME
	task.delay(lifetime, function()
		if clone and clone.Parent then
			clone:Destroy()
		end
	end)

	return clone
end

function VFXController:Trigger(unitName, eventName, context)
	if not unitName then return end
	context = context or {}

	local config = SharedConfig.UnitVFXConfig and SharedConfig.UnitVFXConfig[unitName]
	if not config then return end

	for _, entry in config do
		if entry.Event ~= eventName then continue end

		local target
		if entry.Target == "Unit" then
			target = context.unitModel
			if not target and context.unitId then
				target = self:resolveUnitModel(context.unitId)
			end
		elseif entry.Target == "Mob" then
			if context.mobModel and context.mobModel.Parent then
				target = context.mobModel
			else
				target = context.position
			end
		end

		if not target then continue end

		self:Play(entry.Effect, target, entry)
	end
end

function VFXController:resolveUnitModel(unitId)
	local placement = self.Controllers.UnitPlacementController
	if not placement or not placement.createdClasses then return nil end
	for model, class in placement.createdClasses do
		if class and class.unitId == unitId then
			return model
		end
	end
	return nil
end

function VFXController:buildLibrary()
	local folder = Assets:FindFirstChild("VFX")
	if not folder then return end
	for _, effect in folder:GetChildren() do
		self.Library[effect.Name] = effect
	end
end

function VFXController:construct()
	self:buildLibrary()
end

function VFXController:start()
end

function VFXController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return VFXController
