--!strict
--[[
	Translates between the editor's map data and the Peri TD map folder format.

	Peri contract (ServerStorage.Maps.<Name>, read by MapService:LoadMap):
	  Content.Map.{Terrain, Locked, Path, InvisWalls}   cloned to workspace.Map
	      Path parts carry the "Grid" tag: the only tower-placement refusal.
	  Nodes          Parts "1".."N"; a fork is several same-named Folders of numbered Parts.
	                 Enemies start at the first step and end at the last.
	  SpawnLocation  player spawn, Enabled = false in storage.
	  BaseHP         Part > BillboardGui > Frame > TextLabel "Value" (+ ImageLabel).
	  BoundingBox    inert Part read by WeatherService.

	Editor -> Peri mapping:
	  enemy_spawn marker  -> node step 1
	  route steps         -> node steps 2..N-1 (single branch flattens to Parts, forks to Folders)
	  base marker         -> last node step, and BaseHP above it
	  player_spawn marker -> SpawnLocation (falls back to the enemy spawn)
	  catalog periFolder  -> Content.Map subfolder
	  no_build zones      -> invisible, non-colliding Grid parts in Path

	Node height matches Peri's maps: node centre sits NodeSize.Y/2 above the surface.
]]
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local Serializer = require(Shared.Serializer)
local RouteModel = require(Shared.RouteModel)
local Factory = require(Shared.InstanceFactory)
local MapRules = require(Shared.MapRules)

type Map = Serializer.Map
type Record = Serializer.Record

local PERI = Config.PERI

local Adapter = {}

local function newFolder(name: string, parent: Instance?): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function newNode(name: string, position: Vector3): Part
	local node = Instance.new("Part")
	node.Name = name
	node.Size = PERI.NodeSize
	node.CFrame = CFrame.new(position)
	node.Anchored = true
	node.CanCollide = false
	node.CanQuery = false
	node.CanTouch = false
	node.Transparency = 1
	node.Color = Color3.fromRGB(255, 0, 0)
	node.TopSurface = Enum.SurfaceType.Smooth
	node.BottomSurface = Enum.SurfaceType.Smooth
	return node
end

function Adapter.buildNodesFolder(map: Map, origin: CFrame): (Folder?, string?)
	local steps, err = RouteModel.steps(map)
	if not steps then
		return nil, err
	end

	local folder = newFolder("Nodes")
	for index, alts in steps do
		local name = tostring(index)
		if #alts == 1 and #alts[1] == 1 then
			local node = newNode(name, origin * alts[1][1].position)
			node:SetAttribute(Factory.ID_ATTRIBUTE, alts[1][1].id)
			node.Parent = folder
		else
			for _, alt in alts do
				local segment = newFolder(name, folder)
				for j, point in alt do
					local node = newNode(tostring(j), origin * point.position)
					node:SetAttribute(Factory.ID_ATTRIBUTE, point.id)
					node.Parent = segment
				end
			end
		end
	end
	return folder, nil
end

local function buildBaseHealth(position: Vector3): Part
	local part = Instance.new("Part")
	part.Name = PERI.BaseHealthPart
	part.Size = Vector3.one
	part.CFrame = CFrame.new(position)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(6, 1)
	gui.StudsOffset = Vector3.new(0, 0.85, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = part

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Parent = gui

	local value = Instance.new("TextLabel")
	value.Name = PERI.BaseHealthLabel
	value.Size = UDim2.fromScale(0.5, 1)
	value.Position = UDim2.fromScale(0.3, 0)
	value.BackgroundTransparency = 1
	value.TextScaled = true
	value.TextColor3 = Color3.new(1, 1, 1)
	value.Text = "100"
	value.FontFace = Font.new(PERI.BaseHealthFont, Enum.FontWeight.Bold)
	value.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 5.3
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = value

	local icon = Instance.new("ImageLabel")
	icon.Size = UDim2.fromScale(0.2, 1)
	icon.Position = UDim2.fromScale(0.1, 0)
	icon.BackgroundTransparency = 1
	icon.Image = PERI.BaseHealthIcon
	icon.Parent = frame

	return part
end

local function buildSpawn(cf: CFrame): SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnLocation"
	spawn.Size = Vector3.new(4, 0.5, 4)
	spawn.CFrame = cf * CFrame.new(0, 0.25, 0)
	spawn.Anchored = true
	spawn.Enabled = false
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Transparency = 1
	spawn.CanQuery = false
	spawn.TopSurface = Enum.SurfaceType.Smooth
	return spawn
end

local function computeBounds(root: Instance): (Vector3?, Vector3?)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	local any = false
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			any = true
			local half = d.Size / 2
			local cf = d.CFrame
			local extent = Vector3.new(
				math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z,
				math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z,
				math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
			)
			minV = minV:Min(cf.Position - extent)
			maxV = maxV:Max(cf.Position + extent)
		end
	end
	if not any then
		return nil, nil
	end
	return minV, maxV
end

local function buildBoundingBox(content: Instance, fallback: Vector3): Part
	local minV, maxV = computeBounds(content)
	local pad = Vector3.new(PERI.BoundsPadding, 0, PERI.BoundsPadding)
	local lo = if minV then minV - pad else fallback - Vector3.new(32, 0, 32)
	local hi = if maxV then maxV + pad else fallback + Vector3.new(32, PERI.BoundsMinHeight, 32)
	if hi.Y - lo.Y < PERI.BoundsMinHeight then
		hi = Vector3.new(hi.X, lo.Y + PERI.BoundsMinHeight, hi.Z)
	end

	local part = Instance.new("Part")
	part.Name = PERI.BoundsPartName
	part.Size = hi - lo
	part.CFrame = CFrame.new((lo + hi) / 2)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	return part
end

export type ExportReport = { objects: number, skipped: number, nodeSteps: number, warnings: { string } }

function Adapter.export(map: Map, name: string, templates: Instance, origin: CFrame?): (Folder, ExportReport)
	local o = origin or CFrame.identity
	local report: ExportReport = { objects = 0, skipped = 0, nodeSteps = 0, warnings = {} }

	local root = newFolder(name)
	root:SetAttribute("EditorSchema", Config.SCHEMA_VERSION)
	root:SetAttribute("EditorMapId", map.id)
	root:SetAttribute("EditorMapName", map.name)

	local content = newFolder("Content", root)
	local mapFolder = newFolder("Map", content)
	local subfolders = {}
	for _, folderName in PERI.ContentFolders do
		subfolders[folderName] = newFolder(folderName, mapFolder)
	end

	local ids = {}
	for id in map.objects do
		table.insert(ids, id)
	end
	table.sort(ids)

	for _, id in ids do
		local rec = map.objects[id]
		local def = Catalog.get(rec.t)
		if not def then
			report.skipped += 1
			table.insert(report.warnings, "Unknown type skipped: " .. tostring(rec.t))
			continue
		end
		if not def.periFolder then
			continue
		end
		local inst = Factory.build(rec, templates, o, true)
		if not inst then
			report.skipped += 1
			table.insert(report.warnings, "Missing template: " .. def.id)
			continue
		end
		if def.periFolder == "Path" then
			Factory.forEachPart(inst, function(part)
				CollectionService:AddTag(part, PERI.GridTag)
			end)
		end
		inst.Parent = subfolders[def.periFolder]
		report.objects += 1
	end

	local nodes, nodeErr = Adapter.buildNodesFolder(map, o)
	if nodes then
		report.nodeSteps = #nodes:GetChildren()
		nodes.Parent = root
	else
		newFolder("Nodes", root)
		table.insert(report.warnings, nodeErr or "No nodes.")
	end

	local enemySpawn = RouteModel.findRole(map, Catalog.ROLE.EnemySpawn)
	local playerSpawn = RouteModel.findRole(map, Catalog.ROLE.PlayerSpawn) or enemySpawn
	local base = RouteModel.findRole(map, Catalog.ROLE.Base)

	if playerSpawn then
		buildSpawn(o * Serializer.recordCFrame(playerSpawn)).Parent = root
	else
		table.insert(report.warnings, "No SpawnLocation: map has no player or enemy spawn.")
	end

	local fallback = Vector3.zero
	if base then
		fallback = (o * Serializer.toVector(base.p))
		buildBaseHealth(fallback + PERI.BaseHealthOffset).Parent = root
	else
		table.insert(report.warnings, "No BaseHP: map has no base.")
	end

	buildBoundingBox(mapFolder, fallback).Parent = root

	return root, report
end

export type ImportReport = { imported: number, skipped: { string }, waypoints: number }

local SHAPE_BY_CLASS = {
	WedgePart = "Wedge",
	CornerWedgePart = "CornerWedge",
}

local function shapeOf(part: BasePart): string?
	local byClass = SHAPE_BY_CLASS[part.ClassName]
	if byClass then
		return byClass
	end
	if part:IsA("Part") then
		return part.Shape.Name
	end
	return nil
end

local function materialName(material: Enum.Material): string?
	if MapRules.MATERIAL_SET[material.Name] then
		return material.Name
	end
	return nil
end

local function recordFromPart(part: BasePart, typeId: string, inverse: CFrame): Record
	local rec: Record = { id = Serializer.newId(), t = typeId, p = {}, r = {} }
	Serializer.setCFrame(rec, inverse * part.CFrame)
	rec.s = Serializer.vec(part.Size)
	rec.c = part.Color:ToHex()
	rec.m = materialName(part.Material)
	if part.Transparency > 0 and part.Transparency < 1 then
		rec.tr = part.Transparency
	end
	rec.sh = shapeOf(part)
	return rec
end

local function recordFromEditorInstance(inst: Instance, inverse: CFrame): Record?
	local typeId = inst:GetAttribute(Factory.TYPE_ATTRIBUTE)
	local def = Catalog.get(typeId)
	if not def then
		return nil
	end
	local rec: Record = { id = Serializer.newId(), t = def.id, p = {}, r = {} }
	if inst:IsA("BasePart") then
		Serializer.setCFrame(rec, inverse * inst.CFrame)
		rec.s = Serializer.vec(inst.Size)
		if def.allowColor then
			rec.c = inst.Color:ToHex()
		end
		if def.allowMaterial then
			rec.m = materialName(inst.Material)
		end
		if def.allowShape then
			rec.sh = shapeOf(inst)
		end
	elseif inst:IsA("Model") then
		Serializer.setCFrame(rec, inverse * inst:GetPivot())
		local scale = inst:GetScale()
		if math.abs(scale - 1) > 1e-3 then
			rec.sc = scale
		end
	else
		return nil
	end
	return rec
end

local function addMarker(map: Map, role: string, position: Vector3, yaw: number?, forced: Catalog.Def?): Record?
	local def = forced or Catalog.typeForRole(role)
	if not def then
		return nil
	end
	local rec: Record = {
		id = Serializer.newId(),
		t = def.id,
		p = Serializer.vec(position),
		r = { 0, Serializer.normalizeAngle(yaw or 0), 0 },
	}
	map.objects[rec.id] = rec
	return rec
end

local function surfaceFromNode(position: Vector3): Vector3
	return position - Vector3.new(0, PERI.NodeSize.Y / 2, 0)
end

local function stepPoints(child: Instance): { Vector3 }
	local points = {}
	if child:IsA("BasePart") then
		table.insert(points, child.Position)
		return points
	end
	local parts = {}
	for _, node in child:GetChildren() do
		if node:IsA("BasePart") then
			table.insert(parts, node)
		end
	end
	table.sort(parts, function(a, b)
		return (tonumber(a.Name) or math.huge) < (tonumber(b.Name) or math.huge)
	end)
	for _, node in parts do
		table.insert(points, node.Position)
	end
	return points
end

function Adapter.import(folder: Instance, owner: number, origin: CFrame?): (Map?, ImportReport | string)
	local inverse = (origin or CFrame.identity):Inverse()
	local report: ImportReport = { imported = 0, skipped = {}, waypoints = 0 }
	local map = Serializer.blankMap(owner, folder.Name)

	local content = folder:FindFirstChild("Content")
	local mapFolder = content and content:FindFirstChild("Map")
	if not mapFolder then
		return nil, "Folder has no Content.Map."
	end

	local skippedCounts: { [string]: number } = {}
	local function skip(reason: string)
		skippedCounts[reason] = (skippedCounts[reason] or 0) + 1
	end

	local assetByName: { [string]: string } = {}
	local templates = Shared:FindFirstChild("Templates")
	if templates then
		for _, template in templates:GetChildren() do
			local original = template:GetAttribute("PeriOriginalName")
			if typeof(original) == "string" then
				assetByName[original] = template.Name
			end
		end
	end

	local function importInstance(inst: Instance, folderName: string)
		local assetId = assetByName[inst.Name]
		if assetId and not inst:GetAttribute(Factory.TYPE_ATTRIBUTE) and (inst:IsA("Model") or inst:IsA("BasePart")) then
			local rec: Record = { id = Serializer.newId(), t = assetId, p = {}, r = {} }
			Serializer.setCFrame(rec, inverse * Factory.assetPivot(inst))
			if inst:IsA("Model") and math.abs(inst:GetScale() - 1) > 1e-3 then
				rec.sc = inst:GetScale()
			end
			local ok, err, clean = MapRules.sanitizeRecord(rec)
			if ok and clean then
				map.objects[clean.id] = clean
				report.imported += 1
			else
				skip(err or "invalid asset")
			end
			return
		end

		if inst:GetAttribute(Factory.TYPE_ATTRIBUTE) then
			local rec = recordFromEditorInstance(inst, inverse)
			if rec then
				local ok, _, clean = MapRules.sanitizeRecord(rec)
				if ok and clean then
					map.objects[clean.id] = clean
					report.imported += 1
					return
				end
			end
		end

		if inst:IsA("BasePart") and not inst:IsA("MeshPart") and not inst:IsA("UnionOperation") then
			local typeId = Catalog.IMPORT_TYPES[folderName]
			local rec = recordFromPart(inst, typeId, inverse)
			local ok, err, clean = MapRules.sanitizeRecord(rec)
			if ok and clean then
				map.objects[clean.id] = clean
				report.imported += 1
			else
				skip(err or "invalid part")
			end
		elseif inst:IsA("Model") or inst:IsA("Folder") then
			for _, child in inst:GetChildren() do
				importInstance(child, folderName)
			end
		elseif inst:IsA("BasePart") then
			skip(inst.ClassName .. " (mesh/union geometry has no catalog equivalent)")
		end
	end

	for _, folderName in PERI.ContentFolders do
		local sub = mapFolder:FindFirstChild(folderName)
		if sub then
			for _, child in sub:GetChildren() do
				importInstance(child, folderName)
			end
		end
	end

	local nodes = folder:FindFirstChild("Nodes")
	if nodes then
		local groups: { [string]: { Instance } } = {}
		local order = {}
		for _, child in nodes:GetChildren() do
			if not groups[child.Name] then
				groups[child.Name] = {}
				table.insert(order, child.Name)
			end
			table.insert(groups[child.Name], child)
		end
		table.sort(order, function(a, b)
			return (tonumber(a) or math.huge) < (tonumber(b) or math.huge)
		end)

		local stepList: { { { Vector3 } } } = {}
		for _, key in order do
			local alts = {}
			for _, child in groups[key] do
				local points = stepPoints(child)
				if #points > 0 then
					table.insert(alts, points)
				end
			end
			if #alts > 0 then
				table.insert(stepList, alts)
			end
		end

		local firstStep, lastStep = stepList[1], stepList[#stepList]
		local canSplitEnds = #stepList >= 2 and firstStep ~= nil and #firstStep <= Config.MAX_ENEMY_SPAWNS and #lastStep == 1 and #lastStep[1] >= 1

		if canSplitEnds then
			local lastAlt = lastStep[1]
			local basePos = table.remove(lastAlt, #lastAlt) :: Vector3

			local function yawToward(from: Vector3, to: Vector3?): number
				if not to then
					return 0
				end
				local d = (to - from) * Vector3.new(1, 0, 1)
				if d.Magnitude < 1e-3 then
					return 0
				end
				local _, yaw, _ = CFrame.lookAt(from, from + d):ToOrientation()
				return math.deg(yaw)
			end

			addMarker(map, Catalog.ROLE.Base, surfaceFromNode(inverse * basePos), 0)

			local function makeWaypoints(positions: { Vector3 }, lane: string?): { string }
				local waypointDef = Catalog.waypointFor(lane) :: Catalog.Def
				local ids = {}
				for _, position in positions do
					local rec: Record = { id = Serializer.newId(), t = waypointDef.id, p = Serializer.vec(surfaceFromNode(inverse * position)), r = { 0, 0, 0 } }
					map.objects[rec.id] = rec
					table.insert(ids, rec.id)
					report.waypoints += 1
				end
				return ids
			end

			local sharedStart = (stepList[2] and stepList[2][1] and stepList[2][1][1]) or basePos
			for index, alt in firstStep do
				local letter = Catalog.LANES[index]
				local spawnPos = table.remove(alt, 1) :: Vector3
				addMarker(map, Catalog.ROLE.EnemySpawn, surfaceFromNode(inverse * spawnPos), yawToward(spawnPos, alt[1] or sharedStart), Catalog.spawnFor(letter))
				if #firstStep == 1 then
					local ids = makeWaypoints(alt, nil)
					if #ids > 0 then
						table.insert(map.route.steps, { alts = { ids } })
					end
				else
					local ids = makeWaypoints(alt, letter)
					if #ids > 0 then
						table.insert(RouteModel.lanes(map.route), { lane = letter, ids = ids })
					end
				end
			end

			for s = 2, #stepList do
				local routeAlts = {}
				for _, alt in stepList[s] do
					local ids = makeWaypoints(alt, nil)
					if #ids > 0 then
						table.insert(routeAlts, ids)
					end
				end
				if #routeAlts > 0 then
					table.insert(map.route.steps, { alts = routeAlts })
				end
			end
			RouteModel.compact(map.route)
		elseif #stepList > 0 then
			table.insert(report.skipped, string.format("Nodes start on a fork of more than %d branches or end on a fork; route not imported.", Config.MAX_ENEMY_SPAWNS))
		end
	end

	local spawnLocation = folder:FindFirstChild("SpawnLocation")
	if spawnLocation and spawnLocation:IsA("BasePart") then
		local cf = inverse * spawnLocation.CFrame
		local _, yaw, _ = cf:ToOrientation()
		addMarker(map, Catalog.ROLE.PlayerSpawn, cf.Position - Vector3.new(0, spawnLocation.Size.Y / 2, 0), math.deg(yaw))
	end

	for reason, count in skippedCounts do
		table.insert(report.skipped, string.format("%d x %s", count, reason))
	end

	return map, report
end

return Adapter
