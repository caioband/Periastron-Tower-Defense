local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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