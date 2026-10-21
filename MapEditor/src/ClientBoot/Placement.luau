local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local Serializer = require(Shared.Serializer)
local MapRules = require(Shared.MapRules)
local Factory = require(Shared.InstanceFactory)

local State = require(script.Parent.State)
local Geometry = require(script.Parent.Geometry)
local Signal = require(script.Parent.Signal)
local Pointer = require(script.Parent.Pointer)

local player = Players.LocalPlayer

local Placement = {}
Placement.Changed = Signal.new()
Placement.excluded = {}

local active = nil

local VALID = Color3.fromHex("46C267")
local INVALID = Color3.fromHex("E5484D")

local PATH_SNAP_RANGE = 2.5
local PATH_SNAP_HEIGHT = 6
local FACE_INSET = 0.05
local FLAT = Vector3.new(1, 0, 1)

local function ghostify(inst)
	Factory.forEachPart(inst, function(part)
		part.Transparency = math.max(part.Transparency, 0.45)
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
	end)
	for _, d in inst:GetDescendants() do
		if d:IsA("Light") then
			d.Enabled = false
		end
	end
end

local function bottomFor(rotation)
	local minY = math.huge
	for _, corner in active.corners do
		local y = (rotation * corner).Y
		if y < minY then
			minY = y
		end
	end
	return if minY == math.huge then 0 else minY
end

local function constraints()
	local yawOnly, rotatable = false, true
	for _, item in active.items do
		local def = Catalog.get(item.t)
		if def then
			if not def.rotatable then
				rotatable = false
			end
			if def.yawOnly then
				yawOnly = true
			end
		end
	end
	return rotatable, yawOnly
end

local function evaluate(pivot, hit)
	if not hit then
		return false, "Point at a surface."
	end
	if not MapRules.inBounds(State.toLocalPoint(pivot.Position)) then
		return false, "Outside the build area."
	end
	if State.objectCount() + #active.items > Config.MAX_OBJECTS then
		return false, "Object limit reached."
	end
	for _, item in active.items do
		local def = Catalog.get(item.t)
		local limit = def and Catalog.limit(def)
		if def and limit and State.countType(def.id) >= limit then
			if limit == 1 then
				return false, "The map already has a " .. def.name .. "."
			end
			return false, string.format("A map can have at most %d %ss.", limit, def.name)
		end
	end
	return true, nil
end

local function isPathDef(def)
	return def ~= nil and def.periFolder == "Path" and def.role ~= Catalog.ROLE.NoBuild
end

local function boxOf(inst)
	if inst:IsA("BasePart") then
		return inst.CFrame, inst.Size
	elseif inst:IsA("Model") then
		return inst:GetBoundingBox()
	end
	return nil, nil
end

local function isWedge(part)
	return part:IsA("WedgePart") or (part:IsA("Part") and part.Shape == Enum.PartType.Wedge)
end

local function topAt(inst, point)
	local parts = {}
	if inst:IsA("BasePart") then
		table.insert(parts, inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	local best = nil
	for _, part in parts do
		local cf = part.CFrame
		if cf.UpVector.Y < 0.99 then
			continue
		end
		local l = cf:PointToObjectSpace(point)
		local half = part.Size / 2
		if math.abs(l.X) <= half.X + 0.01 and math.abs(l.Z) <= half.Z + 0.01 then
			local y = if isWedge(part) then (math.clamp(l.Z, -half.Z, half.Z) / part.Size.Z) * part.Size.Y else half.Y
			local worldY = (cf * Vector3.new(l.X, y, l.Z)).Y
			if not best or worldY > best then
				best = worldY
			end
		end
	end
	return best
end

local function pathSnap(pivot)
	if #active.items ~= 1 or not isPathDef(Catalog.get(active.items[1].t)) then
		return nil
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) then
		return nil
	end

	local gcf, gsize = active.ghost:GetBoundingBox()
	if gcf.UpVector.Y < 0.99 then
		return nil
	end
	local gCenter = gcf.Position

	local best, bestDist = nil, PATH_SNAP_RANGE
	for id, rec in State.map.objects do
		if not isPathDef(Catalog.get(rec.t)) then
			continue
		end
		local inst = State.instanceFor(id)
		if not inst then
			continue
		end
		local ncf, nsize = boxOf(inst)
		if not ncf or ncf.UpVector.Y < 0.99 then
			continue
		end
		local reach = (gsize.Magnitude + nsize.Magnitude) / 2 + PATH_SNAP_RANGE
		if ((ncf.Position - gCenter) * FLAT).Magnitude > reach then
			continue
		end

		local look = ncf:ToObjectSpace(gcf).LookVector
		local gx, gz
		if math.abs(look.Z) > 0.999 then
			gx, gz = gsize.X / 2, gsize.Z / 2
		elseif math.abs(look.X) > 0.999 then
			gx, gz = gsize.Z / 2, gsize.X / 2
		else
			continue
		end

		local lp = ncf:PointToObjectSpace(gCenter)
		local here = Vector2.new(lp.X, lp.Z)
		local nx, nz = nsize.X / 2, nsize.Z / 2
		for _, side in { { "X", 1 }, { "X", -1 }, { "Z", 1 }, { "Z", -1 } } do
			local axis, sign = side[1], side[2]
			local target = if axis == "X" then Vector2.new(sign * (nx + gx), 0) else Vector2.new(0, sign * (nz + gz))
			local d = (here - target).Magnitude
			if d < bestDist then
				bestDist = d
				best = {
					inst = inst,
					ncf = ncf,
					nsize = nsize,
					axis = axis,
					sign = sign,
					target = target,
					nHalf = if axis == "X" then nx else nz,
					gHalf = if axis == "X" then gx else gz,
				}
			end
		end
	end
	if not best then
		return nil
	end

	local dirLocal = if best.axis == "X" then Vector3.new(best.sign, 0, 0) else Vector3.new(0, 0, best.sign)
	local dirWorld = best.ncf:VectorToWorldSpace(dirLocal)

	local nFace = best.ncf:PointToWorldSpace(dirLocal * (best.nHalf - FACE_INSET))
	local nTop = topAt(best.inst, nFace) or (best.ncf.Position.Y + best.nsize.Y / 2)

	local gFace = gCenter - dirWorld * (best.gHalf - FACE_INSET)
	local gTop = topAt(active.ghost, gFace) or (gCenter.Y + gsize.Y / 2)
	local relHeight = gTop - gCenter.Y

	local targetWorld = best.ncf:PointToWorldSpace(Vector3.new(best.target.X, 0, best.target.Y))
	local newCenter = Vector3.new(targetWorld.X, nTop - relHeight, targetWorld.Z)
	if math.abs(newCenter.Y - gCenter.Y) > PATH_SNAP_HEIGHT then
		return nil
	end
	return pivot + (newCenter - gCenter)
end

local function update()
	if not active then
		return
	end
	local camera = workspace.CurrentCamera
	local mouse = Pointer.location()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = { active.ghost }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	for _, inst in Placement.excluded do
		table.insert(exclude, inst)
	end
	params.FilterDescendantsInstances = exclude

	local result = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
	local surface, normal = nil, Vector3.yAxis
	if result then
		surface = result.Position
		normal = result.Normal
	elseif ray.Direction.Y < -1e-3 then
		local t = (State.origin.Y - ray.Origin.Y) / ray.Direction.Y
		surface = ray.Origin + ray.Direction * t
	end

	if not surface then
		active.valid, active.reason = false, "Point at a surface."
		active.snapped = false
		active.highlight.FillColor = INVALID
		active.highlight.OutlineColor = INVALID
		return
	end

	local align = if State.alignSurface and result then Geometry.alignToNormal(normal) else CFrame.identity
	local bottom = bottomFor(active.rotation)

	local lp = State.toLocalPoint(surface)
	if State.gridOn then
		local g = State.gridSize()
		lp = Vector3.new(Geometry.snap(lp.X, g), lp.Y, Geometry.snap(lp.Z, g))
		if State.snapY then
			lp = Vector3.new(lp.X, Geometry.snap(lp.Y, g), lp.Z)
		end
	end
	local world = State.toWorldPoint(lp)
	local up = align.UpVector
	local pivot = CFrame.new(world - up * bottom) * align * active.rotation

	active.ghost:PivotTo(pivot)
	active.snapped = false
	local snappedPivot = pathSnap(pivot)
	if snappedPivot then
		pivot = snappedPivot
		active.ghost:PivotTo(pivot)
		active.snapped = true
	end

	active.pivot = pivot
	active.valid, active.reason = evaluate(pivot, surface)
	local color = active.valid and VALID or INVALID
	active.highlight.FillColor = color
	active.highlight.OutlineColor = color
end

function Placement.isActive()
	return active ~= nil
end

function Placement.info()
	return active and active.info
end

function Placement.reason()
	return active and active.reason
end

function Placement.isSnapped()
	return active ~= nil and active.snapped == true
end

function Placement.begin(items, info)
	Placement.cancel()
	if #items == 0 then
		return
	end
	local templates = Shared:WaitForChild("Templates")
	local ghost = Instance.new("Model")
	ghost.Name = "EditorGhost"
	for _, item in items do
		local inst = Factory.build(item, templates, CFrame.identity, false)
		if inst then
			ghostify(inst)
			inst.Parent = ghost
		end
	end
	ghost.WorldPivot = CFrame.identity

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 0.65
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = ghost
	highlight.Parent = ghost

	active = {
		ghost = ghost,
		items = items,
		info = info or {},
		rotation = CFrame.identity,
		corners = Geometry.localCorners(ghost, CFrame.identity),
		highlight = highlight,
		valid = false,
		reason = nil,
		snapped = false,
		pivot = CFrame.identity,
	}

	ghost.Parent = workspace.CurrentCamera
	RunService:BindToRenderStep("MapEditorPlacement", Enum.RenderPriority.Camera.Value + 2, update)
	Placement.Changed:Fire(true)
end

function Placement.cancel()
	if not active then
		return
	end
	RunService:UnbindFromRenderStep("MapEditorPlacement")
	active.ghost:Destroy()
	active = nil
	Placement.Changed:Fire(false)
end

function Placement.rotate(axis, degrees)
	if not active then
		return
	end
	local rotatable, yawOnly = constraints()
	if not rotatable then
		return
	end
	if yawOnly and axis ~= Vector3.yAxis then
		return
	end
	active.rotation = CFrame.fromAxisAngle(axis, math.rad(degrees)) * active.rotation
end

function Placement.confirm()
	if not active then
		return nil, "Nothing to place."
	end
	update()
	if not active.valid then
		return nil, active.reason or "Cannot place here."
	end
	local records = {}
	for _, item in active.items do
		local rec = Serializer.copy(item)
		rec.id = Serializer.newId()
		local world = active.pivot * Serializer.recordCFrame(item)
		Serializer.setCFrame(rec, State.toLocalCF(world))
		table.insert(records, rec)
	end
	return records, nil
end

function Placement.singleItem(typeId)
	local def = Catalog.get(typeId)
	if not def then
		return nil
	end
	local rec = { id = "ghost", t = def.id, p = { 0, 0, 0 }, r = { 0, 0, 0 } }
	if def.kind == "Part" and def.size then
		rec.s = Serializer.vec(def.size)
	end
	return rec
end

return Placement