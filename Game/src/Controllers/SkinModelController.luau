local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local SharedConfig = require(Configs.SharedConfig)

local Framework = Me.new()
local log = Log.new("SkinModelController")

local SkinConfig = SharedConfig.SkinConfig
local Units = Assets:WaitForChild("Units")

local SKIN_FOLDER_NAME = "Skin"
local ROOT_NAME = "HumanoidRootPart"
local SEPARATOR = "/"
local MAX_ANCHOR_HOPS = 8

--[=[
	Dresses placed units in their owner's equipped skin.

	`UnitPlacementController` still builds the default unit; this listens to the same
	`ReplicateUnit`, finds that model by its `UnitID`, and welds the skin's parts onto
	the default rig: each skin part to the default part with the same path (so the
	existing animations drive it), or, for parts the default model lacks, to whatever
	that part is welded to in the skin model. The default parts are then hidden with
	`LocalTransparencyModifier`, so raycasts and selection keep using them.

	A skin model is a copy of the unit's model with the same part names and a
	`HumanoidRootPart`, in `Assets.Skins`.
]=]
local SkinModelController = {}

--[[ INTERNAL ]]

local function pathOf(part : Instance, root : Instance) : string
	local names = {}
	local node = part

	while node and node ~= root do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end

	return table.concat(names, SEPARATOR)
end

local function partsByPath(model : Instance, skip : Instance?) : { [string] : BasePart }
	local map = {}

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not (skip and descendant:IsDescendantOf(skip)) then
			local path = pathOf(descendant, model)
			if map[path] == nil then
				map[path] = descendant
			end
		end
	end

	return map
end

local function hide(part : BasePart)
	part.LocalTransparencyModifier = 1

	for _, descendant in part:GetDescendants() do
		if descendant:IsA("Decal") then
			descendant.LocalTransparencyModifier = 1
		end
	end
end

function SkinModelController:_skinTemplate(skin)
	local folder = Assets:FindFirstChild(SkinConfig.MODEL_FOLDER)
	return folder and folder:FindFirstChild(skin.Model)
end

-- Where each skin part goes on the default rig, computed once per skin from the two
-- models at rest.
function SkinModelController:_plan(skinId : string, unitName : string)
	local cached = self.Plans[skinId]
	if cached ~= nil then
		return cached or nil
	end

	local skin = SkinConfig.Get(skinId)
	local skinTemplate = skin and self:_skinTemplate(skin)
	local baseTemplate = Units:FindFirstChild(unitName)

	if not skinTemplate or not baseTemplate then
		log:StudioWarn(`skin {skinId}: missing Assets.{SkinConfig.MODEL_FOLDER}.{skin and skin.Model or "?"} or Assets.Units.{unitName}`)
		self.Plans[skinId] = false
		return nil
	end

	local baseParts = partsByPath(baseTemplate)
	local skinParts = partsByPath(skinTemplate)
	local baseRoot = baseParts[ROOT_NAME]
	local skinRoot = skinParts[ROOT_NAME]

	if not baseRoot or not skinRoot then
		log:StudioWarn(`skin {skinId}: both models need a {ROOT_NAME}`)
		self.Plans[skinId] = false
		return nil
	end

	-- What each skin part is welded to: Part1 -> Part0 first, the reverse as fallback.
	local parentOf, childOf = {}, {}
	for _, descendant in skinTemplate:GetDescendants() do
		if descendant:IsA("JointInstance") or descendant:IsA("WeldConstraint") then
			local part0, part1 = descendant.Part0, descendant.Part1
			if part0 and part1 then
				parentOf[part1] = parentOf[part1] or part0
				childOf[part0] = childOf[part0] or part1
			end
		end
	end

	local function anchorFor(part : BasePart) : string
		local direct = pathOf(part, skinTemplate)
		if baseParts[direct] then
			return direct
		end

		for _, links in { parentOf, childOf } do
			local node = part
			for _ = 1, MAX_ANCHOR_HOPS do
				node = links[node]
				if not node then
					break
				end

				local path = pathOf(node, skinTemplate)
				if baseParts[path] then
					return path
				end
			end
		end

		return ROOT_NAME
	end

	local steps = {}
	for path, part in skinParts do
		if path == ROOT_NAME then
			continue
		end

		local anchor = anchorFor(part)
		local aligned = baseRoot.CFrame * skinRoot.CFrame:ToObjectSpace(part.CFrame)

		table.insert(steps, {
			Path = path,
			Anchor = anchor,
			Offset = baseParts[anchor].CFrame:ToObjectSpace(aligned),
		})
	end

	local plan = { Steps = steps, Template = skinTemplate }
	self.Plans[skinId] = plan

	return plan
end

function SkinModelController:_apply(model : Model, unitName : string, skinId : string)
	if model:GetAttribute("SkinId") == skinId then
		return
	end

	local plan = self:_plan(skinId, unitName)
	if not plan then
		return
	end

	local live = partsByPath(model, model:FindFirstChild(SKIN_FOLDER_NAME))
	local clone = plan.Template:Clone()
	local cloneParts = partsByPath(clone)

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("JointInstance") or descendant:IsA("WeldConstraint") then
			descendant:Destroy()
		end
	end

	local folder = Instance.new("Folder")
	folder.Name = SKIN_FOLDER_NAME

	for _, step in plan.Steps do
		local part = cloneParts[step.Path]
		local anchor = live[step.Anchor]

		if part and anchor then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			part.CFrame = anchor.CFrame * step.Offset
			part.Parent = folder

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = anchor
			weld.Part1 = part
			weld.Parent = part
		end
	end

	clone:Destroy()
	folder.Parent = model

	for path, part in live do
		if path ~= ROOT_NAME then
			hide(part)
		end
	end

	model:SetAttribute("SkinId", skinId)
end

function SkinModelController:_findUnit(unitId : string) : Model?
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("UnitID") == unitId then
			return child
		end
	end

	return nil
end

function SkinModelController:_onReplicate(unitName : string, ownerUserId : number, unitId : string)
	local owner = Players:GetPlayerByUserId(ownerUserId)
	if not owner then
		return
	end

	local equipped = SkinConfig.decodeEquipped(owner:GetAttribute(SkinConfig.ATTRIBUTE))
	local skinId = equipped[unitName]
	if not skinId then
		return
	end

	local model = self:_findUnit(unitId)
	if not model then
		return
	end

	local ok, err = pcall(self._apply, self, model, unitName, skinId)
	if not ok then
		log:Warn(`skin {skinId} on {unitName} failed: {err}`)
	end
end

--[[ LIFECYCLE ]]

function SkinModelController:start()
	-- Deferred so `UnitPlacementController`'s own listener has built the model first.
	Framework:Listen("ReplicateUnit", function(unitName, _cf, ownerUserId, unitId)
		if typeof(unitName) ~= "string" or typeof(unitId) ~= "string" or typeof(ownerUserId) ~= "number" then
			return
		end

		task.defer(function()
			self:_onReplicate(unitName, ownerUserId, unitId)
		end)
	end)
end

function SkinModelController:init()
	self.Plans = {}
end

return SkinModelController