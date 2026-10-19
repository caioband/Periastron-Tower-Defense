--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local Factory = require(Shared.InstanceFactory)
local PeriAssets = require(Shared.PeriAssets)

local TemplateBuilder = {}

local STRIP_CLASSES = { "BaseScript", "ModuleScript", "ProximityPrompt", "ClickDetector", "Tool", "Humanoid" }

local function assetTemplate(source: Instance): Model?
	local model: Model
	if source:IsA("Model") then
		model = source:Clone()
	elseif source:IsA("BasePart") then
		model = Instance.new("Model")
		local part = source:Clone()
		part.Parent = model
		model.PrimaryPart = part
	else
		return nil
	end

	for _, d in model:GetDescendants() do
		for _, class in STRIP_CLASSES do
			if d:IsA(class) then
				d:Destroy()
				break
			end
		end
	end

	local hasPart = false
	Factory.forEachPart(model, function(part)
		hasPart = true
		part.Anchored = true
	end)
	if not hasPart then
		model:Destroy()
		return nil
	end

	model.WorldPivot = Factory.assetPivot(model)
	model:PivotTo(CFrame.identity)
	return model
end

local function buildPeriAssets(folder: Folder): number
	local assets = ServerStorage:FindFirstChild("MapEditorAssets")
	local peri = assets and assets:FindFirstChild("Peri")
	if not peri then
		return 0
	end
	local A = Catalog.ASSET_ATTRIBUTES
	local count = 0
	for _, source in peri:GetChildren() do
		local key = string.gsub(source.Name, "[^%w_]", "")
		local id = Catalog.ASSET_PREFIX .. key
		if key == "" or folder:FindFirstChild(id) then
			continue
		end
		local template = assetTemplate(source)
		if not template then
			warn("[MapEditor] Peri asset '" .. source.Name .. "' has no parts; skipped.")
			continue
		end
		local entry = PeriAssets[source.Name]
		template.Name = id
		template:SetAttribute(A.Asset, true)
		template:SetAttribute(A.Name, entry and entry.name or source.Name)
		template:SetAttribute(A.Category, entry and entry.category or "Props")
		template:SetAttribute(A.Folder, entry and entry.folder or source:GetAttribute("PeriFolder") or "Terrain")
		template:SetAttribute(A.Blocks, entry ~= nil and entry.blocks == true)
		template:SetAttribute(A.Source, source:GetAttribute("PeriSource") or source.Name)
		template:SetAttribute("PeriOriginalName", source.Name)
		template.Parent = folder
		Catalog.registerAsset(template)
		count += 1
	end
	return count
end

type PartOptions = { shape: string?, name: string?, collide: boolean?, transparency: number? }

local function add(model: Model, size: Vector3, cf: CFrame, color: string, material: Enum.Material, options: PartOptions?): BasePart
	local opts = options or {}
	local part = Factory.newPartForShape(opts.shape)
	part.Name = opts.name or "Part"
	part.Size = size
	part.CFrame = cf
	part.Color = Color3.fromHex(color)
	part.Material = material
	part.CanCollide = opts.collide ~= false
	part.Transparency = opts.transparency or 0
	part.Parent = model
	return part
end

local function worldBounds(inst: Instance): (Vector3, Vector3)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	Factory.forEachPart(inst, function(part)
		local half = part.Size / 2
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local corner = part.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
					minV = minV:Min(corner)
					maxV = maxV:Max(corner)
				end
			end
		end
	end)
	return minV, maxV
end

TemplateBuilder.worldBounds = worldBounds

local function finish(model: Model)
	local minV, maxV = worldBounds(model)
	local center = (minV + maxV) / 2
	model.WorldPivot = CFrame.new(center.X, minV.Y, center.Z)
	model:PivotTo(CFrame.identity)
end

local function label(part: BasePart, text: string, color: string, height: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(140, 30)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 250
	gui.LightInfluence = 0
	local text_ = Instance.new("TextLabel")
	text_.Size = UDim2.fromScale(1, 1)
	text_.BackgroundTransparency = 1
	text_.Text = text
	text_.TextColor3 = Color3.fromHex(color)
	text_.TextStrokeTransparency = 0.3
	text_.Font = Enum.Font.GothamBold
	text_.TextScaled = true
	text_.Parent = gui
	gui.Parent = part
end

local function markerize(model: Model)
	Factory.forEachPart(model, function(part)
		part.CanCollide = false
		part.CanTouch = false
		part.CastShadow = false
	end)
end

local N = CFrame.new
local A = CFrame.Angles
local R = math.rad
local M = Enum.Material

local builders: { [string]: (Model) -> () } = {}

builders.path_curve = function(m)
	local radius, segments = 6, 8
	for k = 0, segments - 1 do
		local theta = R((k + 0.5) * 90 / segments)
		local pos = Vector3.new(radius * math.cos(theta), 0.125, radius * math.sin(theta))
		local tangent = Vector3.new(-math.sin(theta), 0, math.cos(theta))
		add(m, Vector3.new(3, 0.25, 1.3), CFrame.lookAt(pos, pos + tangent), "7C5C46", M.Plastic)
	end
end

builders.path_bridge = function(m)
	add(m, Vector3.new(3, 0.5, 12), N(0, 1.25, 0), "AA5500", M.WoodPlanks, { name = "Deck" })
	for _, x in { -1.65, 1.65 } do
		add(m, Vector3.new(0.3, 0.3, 12), N(x, 2.4, 0), "7C5C46", M.Wood)
		for _, z in { -5.5, 0, 5.5 } do
			add(m, Vector3.new(0.4, 2.5, 0.4), N(x, 1.25, z), "7C5C46", M.Wood)
		end
	end
end

builders.stairs = function(m)
	for i = 0, 3 do
		local h = i + 1
		add(m, Vector3.new(8, h, 2), N(0, h / 2, -i * 2), "A3A2A5", M.Slate)
	end
end

builders.fence = function(m)
	for _, x in { -4, 0, 4 } do
		add(m, Vector3.new(0.4, 3, 0.4), N(x, 1.5, 0), "7C5C46", M.Wood)
	end
	for _, y in { 1, 2.2 } do
		add(m, Vector3.new(8.4, 0.3, 0.2), N(0, y, 0), "AA5500", M.WoodPlanks)
	end
end

builders.house = function(m)
	add(m, Vector3.new(10, 7, 8), N(0, 3.5, 0), "E8BAC8", M.Concrete, { name = "Body" })
	add(m, Vector3.new(10.6, 3, 4.3), N(0, 8.5, -2.15), "C4281C", M.Slate, { shape = "Wedge" })
	add(m, Vector3.new(10.6, 3, 4.3), N(0, 8.5, 2.15) * A(0, R(180), 0), "C4281C", M.Slate, { shape = "Wedge" })
	add(m, Vector3.new(2, 4, 0.2), N(0, 2, -4.05), "5A4C42", M.Wood)
	for _, x in { -3, 3 } do
		add(m, Vector3.new(1.6, 1.6, 0.2), N(x, 4.5, -4.05), "B8E6FF", M.Glass, { transparency = 0.2 })
	end
end

builders.watchtower = function(m)
	for _, x in { -3, 3 } do
		for _, z in { -3, 3 } do
			add(m, Vector3.new(1, 10, 1), N(x, 5, z), "7C5C46", M.Wood)
		end
	end
	add(m, Vector3.new(8, 1, 8), N(0, 10.5, 0), "AA5500", M.WoodPlanks)
	for _, s in { -1, 1 } do
		add(m, Vector3.new(8, 1.2, 0.3), N(0, 11.6, 3.85 * s), "7C5C46", M.Wood)
		add(m, Vector3.new(0.3, 1.2, 8), N(3.85 * s, 11.6, 0), "7C5C46", M.Wood)
	end
	add(m, Vector3.new(9, 2.5, 4.5), N(0, 14.25, -2.25), "635F62", M.Slate, { shape = "Wedge" })
	add(m, Vector3.new(9, 2.5, 4.5), N(0, 14.25, 2.25) * A(0, R(180), 0), "635F62", M.Slate, { shape = "Wedge" })
	for _, x in { -3, 3 } do
		for _, z in { -3, 3 } do
			add(m, Vector3.new(0.5, 1.8, 0.5), N(x, 13.1, z), "7C5C46", M.Wood)
		end
	end
end

builders.ruin_arch = function(m)
	for _, x in { -4, 4 } do
		add(m, Vector3.new(2, 8, 2), N(x, 4, 0), "A3A2A5", M.Cobblestone)
	end
	add(m, Vector3.new(10, 2, 2), N(0, 9, 0), "A3A2A5", M.Cobblestone)
	add(m, Vector3.new(2.4, 0.6, 2.4), N(-4, 0.3, 0), "635F62", M.Slate)
	add(m, Vector3.new(2.4, 0.6, 2.4), N(4, 0.3, 0), "635F62", M.Slate)
end

builders.barrel = function(m)
	add(m, Vector3.new(3, 2.4, 2.4), N(0, 1.5, 0) * A(0, 0, R(90)), "AA5500", M.Wood, { shape = "Cylinder" })
	for _, y in { 0.6, 2.4 } do
		add(m, Vector3.new(0.25, 2.5, 2.5), N(0, y, 0) * A(0, 0, R(90)), "635F62", M.Metal, { shape = "Cylinder" })
	end
end

builders.lamp_post = function(m)
	add(m, Vector3.new(1.2, 0.4, 1.2), N(0, 0.2, 0), "1B2A35", M.Metal)
	add(m, Vector3.new(0.4, 8, 0.4), N(0, 4.4, 0), "1B2A35", M.Metal)
	local lamp = add(m, Vector3.new(1, 1.2, 1), N(0, 8.9, 0), "F5CD30", M.Neon, { name = "Lamp" })
	local light = Instance.new("PointLight")
	light.Range = 16
	light.Brightness = 1.5
	light.Color = Color3.fromHex("FFE6A0")
	light.Parent = lamp
	add(m, Vector3.new(1.4, 0.3, 1.4), N(0, 9.65, 0), "1B2A35", M.Metal)
end

builders.bench = function(m)
	add(m, Vector3.new(5, 0.4, 1.6), N(0, 1.2, 0), "AA5500", M.WoodPlanks)
	add(m, Vector3.new(5, 1.4, 0.3), N(0, 2.1, 0.75), "AA5500", M.WoodPlanks)
	for _, x in { -2.2, 2.2 } do
		add(m, Vector3.new(0.3, 1, 1.4), N(x, 0.5, 0), "1B2A35", M.Metal)
	end
end

builders.sign = function(m)
	add(m, Vector3.new(0.4, 4, 0.4), N(0, 2, 0), "7C5C46", M.Wood)
	add(m, Vector3.new(3, 1.4, 0.2), N(0, 3.3, -0.3), "AA5500", M.WoodPlanks)
end

builders.tree_oak = function(m)
	add(m, Vector3.new(1.4, 6, 1.4), N(0, 3, 0), "7C5C46", M.Wood, { name = "Trunk" })
	add(m, Vector3.new(8, 8, 8), N(0, 8.5, 0), "4B974B", M.LeafyGrass, { shape = "Ball" })
	add(m, Vector3.new(5, 5, 5), N(2.5, 7, 1), "287F47", M.LeafyGrass, { shape = "Ball" })
	add(m, Vector3.new(5, 5, 5), N(-2.2, 7.5, -1.5), "287F47", M.LeafyGrass, { shape = "Ball" })
end

builders.tree_pine = function(m)
	add(m, Vector3.new(1, 4, 1), N(0, 2, 0), "7C5C46", M.Wood, { name = "Trunk" })
	local tiers = { { 6, 4.5 }, { 4.5, 6.3 }, { 3, 8.1 }, { 1.6, 9.6 } }
	for i, tier in tiers do
		add(m, Vector3.new(tier[1], 2, tier[1]), N(0, tier[2], 0) * A(0, R(45 * (i % 2)), 0), "287F47", M.Grass)
	end
end

builders.flowers = function(m)
	add(m, Vector3.new(4, 0.2, 4), N(0, 0.1, 0), "6C8F3E", M.Grass, { collide = false })
	local colors = { "C4281C", "F5CD30", "E8BAC8", "8C5B9F", "F2F3F3", "DA8541" }
	for i, color in colors do
		local angle = R(i * 60)
		add(m, Vector3.new(0.6, 0.6, 0.6), N(math.cos(angle) * 1.2, 0.5, math.sin(angle) * 1.2), color, M.SmoothPlastic, { shape = "Ball", collide = false })
	end
end

local function spawnBuilder(color: string, textColor: string, text: string)
	return function(m: Model)
		local pad = add(m, Vector3.new(4, 0.3, 4), N(0, 0.15, 0), color, M.SmoothPlastic, { name = "Pad", transparency = 0.15 })
		add(m, Vector3.new(1.4, 0.5, 2), N(0, 0.55, -1.2), "F2F3F3", M.Neon, { shape = "Wedge" })
		add(m, Vector3.new(0.3, 4, 0.3), N(1.8, 2.3, 1.8), color, M.Neon)
		label(pad, text, textColor, 4.5)
		markerize(m)
	end
end

local function waypointBuilder(color: string, letter: string)
	return function(m: Model)
		add(m, Vector3.new(1.6, 0.2, 1.6), N(0, 0.1, 0), color, M.Neon, { name = "Pad", transparency = 0.2 })
		add(m, Vector3.new(0.3, 2, 0.3), N(0, 1.2, 0), color, M.SmoothPlastic)
		add(m, Vector3.new(0.8, 0.8, 0.8), N(0, 2.4, 0), color, M.Neon, { shape = "Ball", name = "Waypoint" .. letter })
		markerize(m)
	end
end

builders.enemy_spawn = spawnBuilder("C4281C", "FF6B5E", "ENEMY SPAWN A")
builders.enemy_spawn_b = spawnBuilder("DA8541", "F5A524", "ENEMY SPAWN B")
builders.waypoint_a = waypointBuilder("FF6B5E", "A")
builders.waypoint_b = waypointBuilder("F5A524", "B")
builders.waypoint = waypointBuilder("34C6E6", "C")

builders.base = function(m)
	local body = add(m, Vector3.new(4, 3, 4), N(0, 1.5, 0), "0D69AC", M.SmoothPlastic, { name = "Body", transparency = 0.15 })
	add(m, Vector3.new(4.6, 1.5, 2.3), N(0, 3.75, -1.15), "6E99CA", M.SmoothPlastic, { shape = "Wedge" })
	add(m, Vector3.new(4.6, 1.5, 2.3), N(0, 3.75, 1.15) * A(0, R(180), 0), "6E99CA", M.SmoothPlastic, { shape = "Wedge" })
	label(body, "BASE", "7FC4FF", 4)
	markerize(m)
end

builders.player_spawn = function(m)
	local pad = add(m, Vector3.new(4, 0.3, 4), N(0, 0.15, 0), "4B974B", M.SmoothPlastic, { name = "Pad", transparency = 0.15 })
	add(m, Vector3.new(1.4, 0.5, 2), N(0, 0.55, -1.2), "F2F3F3", M.Neon, { shape = "Wedge" })
	label(pad, "PLAYER SPAWN", "8CFF8C", 3)
	markerize(m)
end

local function buildPart(def: Catalog.Def): BasePart
	local part = Factory.newPartForShape(def.shape)
	part.Size = def.size or Vector3.new(4, 1, 4)
	part.Color = def.color or Color3.new(0.6, 0.6, 0.6)
	part.Material = def.material or Enum.Material.Plastic
	part.Transparency = def.editorTransparency or def.transparency or 0
	part.CanCollide = def.collide ~= false
	if def.surface then
		part:SetAttribute(Config.PERI.SurfaceAttribute, def.surface)
	end
	return part
end

function TemplateBuilder.build(): Folder
	local existing = Shared:FindFirstChild("Templates")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Templates"

	local overrides = ServerStorage:FindFirstChild("MapEditorAssets")

	for _, def in Catalog.list do
		if def.allowShape then
			continue
		end

		local template: Instance? = nil
		local override = overrides and overrides:FindFirstChild(def.id)

		if override and (override:IsA("BasePart") or override:IsA("Model")) then
			template = override:Clone()
		elseif def.kind == "Part" then
			template = buildPart(def)
		else
			local builder = builders[def.id]
			if builder then
				local model = Instance.new("Model")
				builder(model)
				finish(model)
				template = model
			else
				warn("[MapEditor] No template builder for " .. def.id)
			end
		end

		if template then
			Factory.forEachPart(template, function(part)
				part.Anchored = true
			end)
			if def.surface and template:IsA("Model") then
				Factory.forEachPart(template, function(part)
					part:SetAttribute(Config.PERI.SurfaceAttribute, def.surface)
				end)
			end
			template.Name = def.id
			template.Parent = folder
		end
	end

	local assetCount = buildPeriAssets(folder)
	if assetCount == 0 then
		warn("[MapEditor] No Peri assets in ServerStorage.MapEditorAssets.Peri; the catalog only has building blocks.")
	end

	folder.Parent = Shared
	return folder
end

return TemplateBuilder
