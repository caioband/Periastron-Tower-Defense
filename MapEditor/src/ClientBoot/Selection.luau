local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Factory = require(Shared.InstanceFactory)

local State = require(script.Parent.State)

local Selection = {}

local folder = nil
local boxes = {}
local hoverBox = nil

local PRIMARY = Color3.fromHex("F5CD30")
local SECONDARY = Color3.fromHex("34C6E6")
local LOCKED = Color3.fromHex("E5484D")
local HOVER = Color3.fromHex("FFFFFF")

function Selection.init()
	folder = Instance.new("Folder")
	folder.Name = "EditorSelection"
	folder.Parent = workspace.CurrentCamera

	hoverBox = Instance.new("SelectionBox")
	hoverBox.Name = "Hover"
	hoverBox.LineThickness = 0.02
	hoverBox.Color3 = HOVER
	hoverBox.SurfaceTransparency = 1
	hoverBox.Transparency = 0.5
	hoverBox.Parent = folder
end

function Selection.pick(screenPosition)
	local objects = State.objectsFolder()
	if not objects then
		return nil
	end
	local camera = workspace.CurrentCamera
	local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { objects }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
	if not result then
		return nil
	end
	local root = Factory.findRoot(result.Instance, objects)
	if not root then
		return nil
	end
	local id = root:GetAttribute(Factory.ID_ATTRIBUTE) or root.Name
	if State.map.objects[id] then
		return id, result.Position
	end
	return nil
end

function Selection.boxSelect(a, b)
	local camera = workspace.CurrentCamera
	local minX, maxX = math.min(a.X, b.X), math.max(a.X, b.X)
	local minY, maxY = math.min(a.Y, b.Y), math.max(a.Y, b.Y)
	local ids = {}
	for id, rec in State.map.objects do
		local world = State.toWorldPoint(Vector3.new(rec.p[1], rec.p[2], rec.p[3]))
		local screen, visible = camera:WorldToViewportPoint(world)
		if visible then
			local x, y = screen.X, screen.Y
			if x >= minX and x <= maxX and y >= minY and y <= maxY then
				table.insert(ids, id)
			end
		end
	end
	return ids
end

function Selection.setHover(id)
	if not hoverBox then
		return
	end
	local inst = id and not State.isSelected(id) and State.instanceFor(id) or nil
	hoverBox.Adornee = inst
end

function Selection.render()
	if not folder then
		return
	end
	local wanted = {}
	local primary = State.primary()
	if State.active and State.mode == "Build" then
		for _, id in State.selection do
			wanted[id] = true
		end
	end

	for id, box in boxes do
		if not wanted[id] then
			box:Destroy()
			boxes[id] = nil
		end
	end

	for id in wanted do
		local box = boxes[id]
		if not box then
			box = Instance.new("SelectionBox")
			box.LineThickness = 0.05
			box.SurfaceTransparency = 0.9
			box.Parent = folder
			boxes[id] = box
		end
		local inst = State.instanceFor(id)
		if box.Adornee ~= inst then
			box.Adornee = inst
		end
		local rec = State.map.objects[id]
		local color = if rec and rec.lk then LOCKED elseif id == primary then PRIMARY else SECONDARY
		box.Color3 = color
		box.SurfaceColor3 = color
	end
end

function Selection.clear()
	for id, box in boxes do
		box:Destroy()
		boxes[id] = nil
	end
	if hoverBox then
		hoverBox.Adornee = nil
	end
end

return Selection
