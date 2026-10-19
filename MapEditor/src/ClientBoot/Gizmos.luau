local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Catalog = require(Shared.Catalog)
local Serializer = require(Shared.Serializer)
local Factory = require(Shared.InstanceFactory)

local State = require(script.Parent.State)
local Geometry = require(script.Parent.Geometry)
local Signal = require(script.Parent.Signal)

local Gizmos = {}
Gizmos.Commit = Signal.new()
Gizmos.hovering = false

local proxy = nil
local moveHandles, arcHandles, resizeHandles = nil, nil, nil
local dragging = nil
local hoverCount = 0

local MAX_GIZMO_OBJECTS = 400

local function editableSelection()
	local ids = {}
	for _, id in State.selection do
		local rec = State.map.objects[id]
		if not rec then
			continue
		end
		if rec.lk then
			return nil, "Selection contains locked objects."
		end
		table.insert(ids, id)
	end
	return ids, nil
end

local function snapshot(ids)
	local start = {}
	for _, id in ids do
		start[id] = Serializer.copy(State.map.objects[id])
	end
	return start
end

local function applyLocal(records)
	for id, rec in records do
		local inst = State.instanceFor(id)
		if inst then
			Factory.apply(inst, rec, State.origin, false)
		end
	end
end

local function restore()
	if dragging then
		applyLocal(dragging.start)
	end
end

local function finishDrag()
	local drag = dragging
	dragging = nil
	if not drag or not drag.result then
		return
	end
	local changed = {}
	for id, rec in drag.result do
		table.insert(changed, rec)
	end
	if #changed > 0 then
		Gizmos.Commit:Fire(drag.label, changed, drag.start)
	end
end

local function hoverEnter()
	hoverCount += 1
	Gizmos.hovering = true
end

local function hoverLeave()
	hoverCount = math.max(0, hoverCount - 1)
	Gizmos.hovering = hoverCount > 0
end

local function beginDrag(kind, label)
	local ids = editableSelection()
	if not ids or #ids == 0 then
		return
	end
	local primaryId = State.primary()
	if not table.find(ids, primaryId) then
		primaryId = ids[#ids]
	end
	dragging = {
		kind = kind,
		label = label,
		ids = ids,
		primary = primaryId,
		start = snapshot(ids),
		center = proxy.CFrame,
		size = proxy.Size,
		result = nil,
	}
end

local function onMove(face, distance)
	if not dragging or dragging.kind ~= "move" then
		return
	end
	local axis = Vector3.FromNormalId(face)
	local primary = dragging.start[dragging.primary]
	local startPos = Serializer.toVector(primary.p)
	local delta = axis * distance
	if State.gridOn then
		local g = State.gridSize()
		local along = axis:Dot(startPos + delta)
		delta = axis * (Geometry.snap(along, g) - axis:Dot(startPos))
	end
	local result = {}
	for id, rec in dragging.start do
		local moved = Serializer.copy(rec)
		moved.p = Serializer.vec(Serializer.toVector(rec.p) + delta)
		result[id] = moved
	end
	dragging.result = if delta.Magnitude > 1e-4 then result else nil
	applyLocal(result)
	proxy.CFrame = dragging.center + delta
end

local function onRotate(axisEnum, relativeAngle)
	if not dragging or dragging.kind ~= "rotate" then
		return
	end
	local degrees = math.deg(relativeAngle)
	if State.gridOn then
		degrees = Geometry.snap(degrees, State.rotStep())
	end
	local axis = Vector3.FromAxis(axisEnum)
	local center = State.toLocalPoint(dragging.center.Position)
	local turn = CFrame.new(center) * CFrame.fromAxisAngle(axis, math.rad(degrees)) * CFrame.new(-center)

	local result = {}
	for id, rec in dragging.start do
		local def = Catalog.get(rec.t)
		local cf = Serializer.recordCFrame(rec)
		local rotated = turn * cf
		local out = Serializer.copy(rec)
		if def and (not def.rotatable or (def.yawOnly and axisEnum ~= Enum.Axis.Y)) then
			out.p = Serializer.vec(rotated.Position)
		else
			Serializer.setCFrame(out, rotated)
		end
		result[id] = out
	end
	dragging.result = if math.abs(degrees) > 1e-3 then result else nil
	applyLocal(result)
end

local function onResize(face, distance)
	if not dragging or dragging.kind ~= "resize" then
		return
	end
	local id = dragging.primary
	local rec = dragging.start[id]
	local def = Catalog.get(rec.t)
	if not def then
		return
	end
	local delta = distance
	if State.gridOn then
		delta = Geometry.snap(distance, State.gridSize())
	end
	local out = Serializer.copy(rec)

	if def.kind == "Part" and def.resizable and rec.s then
		local axis = Vector3.FromNormalId(face)
		local absAxis = Vector3.new(math.abs(axis.X), math.abs(axis.Y), math.abs(axis.Z))
		local startSize = Serializer.toVector(rec.s)
		local newSize
		if def.uniform then
			local m = math.max(startSize.X, startSize.Y, startSize.Z) + delta
			newSize = Vector3.new(m, m, m)
		else
			newSize = startSize + absAxis * delta
		end
		local lo, hi = def.minSize or startSize, def.maxSize or startSize
		newSize = Vector3.new(math.clamp(newSize.X, lo.X, hi.X), math.clamp(newSize.Y, lo.Y, hi.Y), math.clamp(newSize.Z, lo.Z, hi.Z))
		local grown = (newSize - startSize):Dot(absAxis)
		local shift = if def.uniform then Vector3.zero else axis * (grown / 2)
		local cf = Serializer.recordCFrame(rec) * CFrame.new(shift)
		out.s = Serializer.vec(newSize)
		Serializer.setCFrame(out, cf)
	elseif def.scalable then
		local axis = Vector3.FromNormalId(face)
		local extent = math.max(0.5, math.abs(dragging.size:Dot(axis)))
		local startScale = rec.sc or 1
		local scale = math.clamp(startScale * (1 + delta / extent), def.minScale or 0.25, def.maxScale or 4)
		out.sc = Serializer.round(scale, 100)
	else
		return
	end

	dragging.result = { [id] = out }
	applyLocal(dragging.result)
end

function Gizmos.init(playerGui)
	proxy = Instance.new("Part")
	proxy.Name = "EditorGizmoProxy"
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanQuery = false
	proxy.CanTouch = false
	proxy.Transparency = 1
	proxy.Size = Vector3.one
	proxy.Parent = workspace.CurrentCamera

	moveHandles = Instance.new("Handles")
	moveHandles.Name = "EditorMoveHandles"
	moveHandles.Style = Enum.HandlesStyle.Movement
	moveHandles.Color3 = Color3.fromHex("34C6E6")
	moveHandles.Visible = false
	moveHandles.Parent = playerGui

	arcHandles = Instance.new("ArcHandles")
	arcHandles.Name = "EditorRotateHandles"
	arcHandles.Visible = false
	arcHandles.Parent = playerGui

	resizeHandles = Instance.new("Handles")
	resizeHandles.Name = "EditorResizeHandles"
	resizeHandles.Style = Enum.HandlesStyle.Resize
	resizeHandles.Color3 = Color3.fromHex("F5CD30")
	resizeHandles.Visible = false
	resizeHandles.Parent = playerGui

	for _, h in { moveHandles, arcHandles, resizeHandles } do
		h.MouseEnter:Connect(hoverEnter)
		h.MouseLeave:Connect(hoverLeave)
		h.MouseButton1Up:Connect(finishDrag)
	end

	moveHandles.MouseButton1Down:Connect(function()
		beginDrag("move", "Move")
	end)
	moveHandles.MouseDrag:Connect(onMove)

	arcHandles.MouseButton1Down:Connect(function()
		beginDrag("rotate", "Rotate")
	end)
	arcHandles.MouseDrag:Connect(onRotate)

	resizeHandles.MouseButton1Down:Connect(function()
		beginDrag("resize", "Resize")
	end)
	resizeHandles.MouseDrag:Connect(onResize)
end

function Gizmos.isDragging()
	return dragging ~= nil
end

function Gizmos.finish()
	finishDrag()
end

function Gizmos.cancel()
	restore()
	dragging = nil
end

local function hideAll()
	moveHandles.Visible = false
	arcHandles.Visible = false
	resizeHandles.Visible = false
	moveHandles.Adornee = nil
	arcHandles.Adornee = nil
	resizeHandles.Adornee = nil
	if hoverCount > 0 then
		hoverCount = 0
		Gizmos.hovering = false
	end
end

function Gizmos.update(placing)
	if not proxy then
		return
	end
	if dragging then
		return
	end

	local tool = State.tool
	if not State.active or State.mode ~= "Build" or placing or tool == "Select" or #State.selection == 0 then
		hideAll()
		return
	end

	local ids = editableSelection()
	if not ids or #ids == 0 or #ids > MAX_GIZMO_OBJECTS then
		hideAll()
		return
	end

	local instances = {}
	for _, id in ids do
		local inst = State.instanceFor(id)
		if inst then
			table.insert(instances, inst)
		end
	end
	local lo, hi = Geometry.bounds(instances)
	if not lo then
		hideAll()
		return
	end
	local size = (hi - lo):Max(Vector3.new(0.5, 0.5, 0.5))
	proxy.Size = size
	proxy.CFrame = CFrame.new((lo + hi) / 2)

	moveHandles.Visible = tool == "Move"
	moveHandles.Adornee = if tool == "Move" then proxy else nil
	arcHandles.Visible = tool == "Rotate"
	arcHandles.Adornee = if tool == "Rotate" then proxy else nil

	local resizeTarget = nil
	if tool == "Scale" and #ids == 1 then
		local rec = State.map.objects[ids[1]]
		local def = rec and Catalog.get(rec.t)
		local inst = instances[1]
		if def and inst then
			if def.kind == "Part" and def.resizable and inst:IsA("BasePart") then
				resizeTarget = inst
			elseif def.scalable then
				resizeTarget = proxy
			end
		end
	end
	resizeHandles.Visible = resizeTarget ~= nil
	resizeHandles.Adornee = resizeTarget
end

function Gizmos.hide()
	if proxy then
		hideAll()
	end
end

return Gizmos
