--!strict
local Config = require(script.Parent.Config)
local Catalog = require(script.Parent.Catalog)
local Serializer = require(script.Parent.Serializer)

type Record = Serializer.Record

local Factory = {}

Factory.ID_ATTRIBUTE = "EditorId"
Factory.TYPE_ATTRIBUTE = "EditorType"
Factory.SHAPE_ATTRIBUTE = "EditorShape"

local PART_TYPES = {
	Block = Enum.PartType.Block,
	Ball = Enum.PartType.Ball,
	Cylinder = Enum.PartType.Cylinder,
}

function Factory.newPartForShape(shape: string?): BasePart
	local part: BasePart
	if shape == "Wedge" then
		part = Instance.new("WedgePart")
	elseif shape == "CornerWedge" then
		part = Instance.new("CornerWedgePart")
	else
		local p = Instance.new("Part")
		p.Shape = PART_TYPES[shape or "Block"] or Enum.PartType.Block
		part = p
	end
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

function Factory.forEachPart(inst: Instance, fn: (BasePart) -> ())
	if inst:IsA("BasePart") then
		fn(inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			fn(d)
		end
	end
end

local function computeTransparency(def: Catalog.Def, rec: Record, export: boolean): number
	if export and def.exportTransparency ~= nil then
		return def.exportTransparency
	end
	if def.allowTransparency and rec.tr then
		return rec.tr
	end
	if not export and def.editorTransparency ~= nil then
		return def.editorTransparency
	end
	return def.transparency or 0
end

function Factory.needsRebuild(inst: Instance, rec: Record): boolean
	local def = Catalog.get(rec.t)
	if not def or not def.allowShape then
		return false
	end
	return inst:GetAttribute(Factory.SHAPE_ATTRIBUTE) ~= (rec.sh or "Block")
end

function Factory.apply(inst: Instance, rec: Record, origin: CFrame, export: boolean)
	local def = Catalog.get(rec.t)
	if not def then
		return
	end

	local cf = origin * Serializer.recordCFrame(rec)

	if inst:IsA("BasePart") then
		if def.kind == "Part" and rec.s then
			inst.Size = Serializer.toVector(rec.s)
		end
		inst.CFrame = cf
		if def.allowColor then
			inst.Color = if rec.c then Color3.fromHex(rec.c) else (def.color or inst.Color)
		end
		if def.allowMaterial then
			local material = def.material or Enum.Material.Plastic
			if rec.m then
				local ok, value = pcall(function()
					return (Enum.Material :: any)[rec.m]
				end)
				if ok and value then
					material = value
				end
			end
			inst.Material = material
		end
		inst.Transparency = computeTransparency(def, rec, export)
		if export and def.exportCollide ~= nil then
			inst.CanCollide = def.exportCollide
		end
	elseif inst:IsA("Model") then
		if def.scalable then
			local target = rec.sc or 1
			if math.abs(inst:GetScale() - target) > 1e-4 then
				inst:ScaleTo(target)
			end
		end
		inst:PivotTo(cf)
	end

	inst:SetAttribute(Factory.ID_ATTRIBUTE, rec.id)
	inst:SetAttribute(Factory.TYPE_ATTRIBUTE, rec.t)
	if def.allowShape then
		inst:SetAttribute(Factory.SHAPE_ATTRIBUTE, rec.sh or "Block")
	end
end

function Factory.build(rec: Record, templates: Instance, origin: CFrame, export: boolean): Instance?
	local def = Catalog.get(rec.t)
	if not def then
		return nil
	end

	local inst: Instance
	if def.allowShape then
		local part = Factory.newPartForShape(rec.sh)
		part.Color = def.color or part.Color
		part.Material = def.material or Enum.Material.Plastic
		part.CanCollide = def.collide ~= false
		if def.surface then
			part:SetAttribute(Config.PERI.SurfaceAttribute, def.surface)
		end
		inst = part
	else
		local template = templates:FindFirstChild(def.id)
		if not template then
			return nil
		end
		inst = template:Clone()
	end

	inst.Name = rec.id
	Factory.apply(inst, rec, origin, export)
	return inst
end

--[[
	Pivot convention for Peri assets: bottom-centre of the model's bounding box,
	oriented like the box. Templates and imported map instances both go through
	this, so a prop imported from a Peri map lands exactly where it was.
]]
function Factory.assetPivot(inst: Instance): CFrame
	if inst:IsA("Model") then
		local cf, size = inst:GetBoundingBox()
		return cf * CFrame.new(0, -size.Y / 2, 0)
	elseif inst:IsA("BasePart") then
		return inst.CFrame * CFrame.new(0, -inst.Size.Y / 2, 0)
	end
	return CFrame.identity
end

function Factory.findRoot(hit: Instance?, container: Instance): Instance?
	local current = hit
	while current and current.Parent ~= container do
		current = current.Parent
	end
	return current
end

return Factory
