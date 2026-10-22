--!strict
export type Def = {
	id: string,
	name: string,
	category: string,
	kind: string,
	description: string,
	periFolder: string?,
	role: string?,
	unique: boolean?,
	maxCount: number?,
	lane: string?,
	hidden: boolean?,
	shape: string?,
	size: Vector3?,
	minSize: Vector3?,
	maxSize: Vector3?,
	resizable: boolean,
	uniform: boolean?,
	scalable: boolean?,
	minScale: number?,
	maxScale: number?,
	rotatable: boolean,
	yawOnly: boolean?,
	blocksPath: boolean,
	towerPlaceable: boolean,
	allowColor: boolean,
	allowMaterial: boolean,
	allowTransparency: boolean,
	allowShape: boolean?,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	collide: boolean?,
	surface: string?,
	editorTransparency: number?,
	exportTransparency: number?,
	exportCollide: boolean?,
}

local Catalog = {}

Catalog.CATEGORIES = { "Ground", "Parts", "Paths", "Ramps & Stairs", "Walls", "Nature", "Props", "Furniture", "Structures", "Gameplay", "Prefabs" }

Catalog.ROLE = {
	EnemySpawn = "EnemySpawn",
	Waypoint = "Waypoint",
	Base = "Base",
	PlayerSpawn = "PlayerSpawn",
	NoBuild = "NoBuild",
}

Catalog.list = {} :: { Def }
Catalog.byId = {} :: { [string]: Def }

local SMALL = Vector3.new(0.2, 0.1, 0.2)

local function define(raw: { [string]: any })
	local def = raw :: any
	def.kind = def.kind or "Part"
	def.description = def.description or ""
	def.resizable = def.resizable == true
	def.rotatable = def.rotatable ~= false
	def.blocksPath = def.blocksPath == true
	def.towerPlaceable = def.towerPlaceable ~= false
	def.allowColor = def.allowColor == true
	def.allowMaterial = def.allowMaterial == true
	def.allowTransparency = def.allowTransparency == true
	if def.kind == "Part" and def.resizable then
		def.minSize = def.minSize or SMALL
		def.maxSize = def.maxSize or Vector3.new(512, 128, 512)
	end
	if def.scalable then
		def.minScale = def.minScale or 0.25
		def.maxScale = def.maxScale or math.huge
	end
	assert(not Catalog.byId[def.id], "Duplicate catalog id " .. def.id)
	Catalog.byId[def.id] = def :: Def
	table.insert(Catalog.list, def :: Def)
end

local function editablePart(raw: { [string]: any })
	raw.resizable = if raw.resizable == nil then true else raw.resizable
	raw.allowColor = if raw.allowColor == nil then true else raw.allowColor
	raw.allowMaterial = if raw.allowMaterial == nil then true else raw.allowMaterial
	raw.allowTransparency = if raw.allowTransparency == nil then true else raw.allowTransparency
	define(raw)
end

editablePart({ id = "ground_grass", name = "Grass Plate", category = "Ground", periFolder = "Locked", size = Vector3.new(32, 2, 32), color = Color3.fromHex("4B974B"), material = Enum.Material.Plastic, surface = "Grass", description = "Main ground slab (Farm style)." })
editablePart({ id = "ground_dirt", name = "Dirt Plate", category = "Ground", periFolder = "Locked", size = Vector3.new(16, 1, 16), color = Color3.fromHex("7C5C46"), material = Enum.Material.Ground })
editablePart({ id = "ground_stone", name = "Stone Plate", category = "Ground", periFolder = "Locked", size = Vector3.new(16, 1, 16), color = Color3.fromHex("A3A2A5"), material = Enum.Material.Slate })
editablePart({ id = "ground_sand", name = "Sand Plate", category = "Ground", periFolder = "Locked", size = Vector3.new(16, 1, 16), color = Color3.fromHex("D7C59A"), material = Enum.Material.Sand })
editablePart({ id = "ground_snow", name = "Snow Plate", category = "Ground", periFolder = "Locked", size = Vector3.new(16, 1, 16), color = Color3.fromHex("F2F3F3"), material = Enum.Material.Snow })
editablePart({ id = "platform_wood", name = "Wood Platform", category = "Ground", periFolder = "Terrain", size = Vector3.new(12, 1, 12), color = Color3.fromHex("AA5500"), material = Enum.Material.WoodPlanks })
editablePart({ id = "water_plane", name = "Water Plane", category = "Ground", periFolder = "Terrain", size = Vector3.new(16, 0.5, 16), color = Color3.fromHex("0D69AC"), material = Enum.Material.Glass, transparency = 0.35, collide = false, towerPlaceable = false })

--[[
	Basic parts: one of each classic Roblox part, to build your own props.

	Each entry's look (surface types, shape, class) comes from its template in
	ServerStorage.MapEditorAssets (part_block, part_studs, ...), which
	TemplateBuilder uses as the override for that id. Surface textures only
	render on Plastic, so these default to it; size, colour, material and
	transparency stay editable like any other part.
]]
local PART_GREY = Color3.fromHex("A3A2A5")
local BRICK = Vector3.new(4, 1.2, 2)
local PART_MAX = Vector3.new(512, 512, 512)
local function basicPart(raw: { [string]: any })
	raw.category = "Parts"
	raw.periFolder = "Terrain"
	raw.color = raw.color or PART_GREY
	raw.material = raw.material or Enum.Material.Plastic
	raw.size = raw.size or BRICK
	raw.maxSize = raw.maxSize or PART_MAX
	editablePart(raw)
end

basicPart({ id = "part_block", name = "Part", description = "Classic brick: studs on top, inlets underneath." })
basicPart({ id = "part_smooth", name = "Smooth Part", description = "Smooth on every face." })
basicPart({ id = "part_studs", name = "Stud Part", description = "Studs on every face." })
basicPart({ id = "part_inlet", name = "Inlet Part", description = "Inlets on every face." })
basicPart({ id = "part_weld", name = "Weld Part", description = "Weld surface on every face." })
basicPart({ id = "part_glue", name = "Glue Part", description = "Glue surface on every face." })
basicPart({ id = "part_universal", name = "Universal Part", description = "Universal surface on every face." })
basicPart({ id = "part_hinge", name = "Hinge Part", description = "Hinge on the top face. Decorative: map parts are anchored." })
basicPart({ id = "part_motor", name = "Motor Part", description = "Motor on the top face. Decorative: map parts are anchored." })
basicPart({ id = "part_cylinder", name = "Cylinder", size = Vector3.new(2, 2, 2) })
basicPart({ id = "part_ball", name = "Ball", size = Vector3.new(2, 2, 2), uniform = true })
basicPart({ id = "part_wedge", name = "Wedge" })
basicPart({ id = "part_cornerwedge", name = "Corner Wedge Part", size = Vector3.new(2, 2, 2) })
basicPart({ id = "part_truss", name = "Truss", size = Vector3.new(2, 2, 2), minSize = Vector3.new(2, 2, 2), allowMaterial = false, allowTransparency = false, description = "Truss segment. Lengths snap to 2-stud steps." })

local PATH_COLOR = Color3.fromHex("7C5C46")
local PATH_MIN = Vector3.new(1, 0.1, 1)
local PATH_MAX = Vector3.new(32, 4, 128)
editablePart({ id = "path_straight", name = "Path Straight", category = "Paths", periFolder = "Path", size = Vector3.new(3, 0.25, 8), minSize = PATH_MIN, maxSize = PATH_MAX, color = PATH_COLOR, material = Enum.Material.Plastic, towerPlaceable = false, description = "Enemy path. Towers can never be placed on Path pieces." })
editablePart({ id = "path_tile", name = "Path Tile", category = "Paths", periFolder = "Path", size = Vector3.new(3, 0.25, 3), minSize = PATH_MIN, maxSize = PATH_MAX, color = PATH_COLOR, material = Enum.Material.Plastic, towerPlaceable = false })
editablePart({ id = "path_wide", name = "Path Wide", category = "Paths", periFolder = "Path", size = Vector3.new(6, 0.25, 8), minSize = PATH_MIN, maxSize = PATH_MAX, color = PATH_COLOR, material = Enum.Material.Plastic, towerPlaceable = false })
editablePart({ id = "path_ramp", name = "Path Ramp", category = "Paths", periFolder = "Path", shape = "Wedge", size = Vector3.new(3, 2, 8), minSize = PATH_MIN, maxSize = PATH_MAX, color = PATH_COLOR, material = Enum.Material.Plastic, towerPlaceable = false })
define({ id = "path_curve", name = "Path Curve", category = "Paths", kind = "Model", periFolder = "Path", towerPlaceable = false, scalable = true, description = "Quarter turn, radius 6." })

editablePart({ id = "ramp", name = "Ramp", category = "Ramps & Stairs", periFolder = "Terrain", shape = "Wedge", size = Vector3.new(8, 4, 8), color = Color3.fromHex("4B974B"), material = Enum.Material.Plastic, surface = "Grass" })
editablePart({ id = "corner_wedge", name = "Corner Wedge", category = "Ramps & Stairs", periFolder = "Terrain", shape = "CornerWedge", size = Vector3.new(4, 4, 4), color = Color3.fromHex("A3A2A5"), material = Enum.Material.Slate })
define({ id = "stairs", name = "Stairs", category = "Ramps & Stairs", kind = "Model", periFolder = "Terrain", scalable = true })

editablePart({ id = "wall_brick", name = "Brick Wall", category = "Walls", periFolder = "Terrain", size = Vector3.new(1, 6, 12), color = Color3.fromHex("C4281C"), material = Enum.Material.Brick, blocksPath = true })
editablePart({ id = "wall_stone", name = "Stone Wall", category = "Walls", periFolder = "Terrain", size = Vector3.new(1.5, 8, 12), color = Color3.fromHex("635F62"), material = Enum.Material.Cobblestone, blocksPath = true })
editablePart({ id = "pillar", name = "Pillar", category = "Walls", periFolder = "Terrain", size = Vector3.new(2, 8, 2), color = Color3.fromHex("F2F3F3"), material = Enum.Material.Marble, blocksPath = true })
define({ id = "invis_wall", name = "Invisible Wall", category = "Walls", periFolder = "InvisWalls", size = Vector3.new(1, 24, 24), resizable = true, maxSize = Vector3.new(16, 512, 2048), color = Color3.fromHex("6E99CA"), material = Enum.Material.ForceField, editorTransparency = 0.6, exportTransparency = 1, exportCollide = true, description = "Keeps players inside the map. Invisible in game." })

define({ id = "enemy_spawn", name = "Enemy Spawn A", category = "Gameplay", kind = "Marker", role = "EnemySpawn", lane = "A", unique = true, yawOnly = true, towerPlaceable = false, description = "Start of lane A. Enemies walk Waypoint A's, then the shared Waypoint C's, then to the base." })
define({ id = "enemy_spawn_b", name = "Enemy Spawn B", category = "Gameplay", kind = "Marker", role = "EnemySpawn", lane = "B", unique = true, yawOnly = true, towerPlaceable = false, description = "Start of lane B for dual-lane maps. Enemies walk Waypoint B's, then the shared Waypoint C's, then to the base." })
define({ id = "waypoint_a", name = "Waypoint A", category = "Gameplay", kind = "Marker", role = "Waypoint", lane = "A", rotatable = false, towerPlaceable = false, description = "Lane A only. Added after the selected Waypoint A, or at the end of lane A." })
define({ id = "waypoint_b", name = "Waypoint B", category = "Gameplay", kind = "Marker", role = "Waypoint", lane = "B", rotatable = false, towerPlaceable = false, description = "Lane B only. Added after the selected Waypoint B, or at the end of lane B." })
define({ id = "waypoint", name = "Waypoint C (Shared)", category = "Gameplay", kind = "Marker", role = "Waypoint", rotatable = false, towerPlaceable = false, description = "Shared path: both lanes join here and walk the C's to the base. Added after the selected Waypoint C, or at the end." })
define({ id = "base", name = "Base", category = "Gameplay", kind = "Marker", role = "Base", unique = true, yawOnly = true, towerPlaceable = false, description = "Destination. End of the route; base health shows here." })
define({ id = "player_spawn", name = "Player Spawn", category = "Gameplay", kind = "Marker", role = "PlayerSpawn", unique = true, yawOnly = true, description = "Where players appear in a match." })
define({ id = "no_build", name = "No-Build Zone", category = "Gameplay", periFolder = "Path", role = "NoBuild", size = Vector3.new(8, 4, 8), resizable = true, maxSize = Vector3.new(256, 64, 256), color = Color3.fromHex("DA8541"), material = Enum.Material.ForceField, editorTransparency = 0.55, exportTransparency = 1, exportCollide = false, collide = false, towerPlaceable = false, description = "Blocks tower placement. Invisible in game." })

local IMPORT_MAX = Vector3.new(4096, 1024, 4096)
editablePart({ id = "import_terrain", name = "Imported Part", category = "Ground", periFolder = "Terrain", hidden = true, allowShape = true, size = Vector3.new(4, 4, 4), maxSize = IMPORT_MAX, color = Color3.fromHex("A3A2A5"), material = Enum.Material.Plastic })
editablePart({ id = "import_locked", name = "Imported Ground", category = "Ground", periFolder = "Locked", hidden = true, allowShape = true, size = Vector3.new(4, 4, 4), maxSize = IMPORT_MAX, color = Color3.fromHex("6C8F3E"), material = Enum.Material.Plastic })
editablePart({ id = "import_path", name = "Imported Path", category = "Paths", periFolder = "Path", hidden = true, allowShape = true, size = Vector3.new(2, 0.25, 4), maxSize = IMPORT_MAX, color = PATH_COLOR, material = Enum.Material.Plastic, towerPlaceable = false })
define({ id = "import_wall", name = "Imported Wall", category = "Walls", periFolder = "InvisWalls", hidden = true, allowShape = true, size = Vector3.new(1, 24, 24), resizable = true, maxSize = IMPORT_MAX, color = Color3.fromHex("6E99CA"), material = Enum.Material.ForceField, editorTransparency = 0.6, exportTransparency = 1, exportCollide = true })

Catalog.IMPORT_TYPES = {
	Terrain = "import_terrain",
	Locked = "import_locked",
	Path = "import_path",
	InvisWalls = "import_wall",
}

--[[
	Peri assets: real props copied from Peri TD's maps into
	ServerStorage.MapEditorAssets.Peri. The server turns each into a template
	carrying these attributes, and both sides register the catalog entry from
	the template, so the catalog lists exactly the assets that exist.
]]
Catalog.ASSET_PREFIX = "peri_"
Catalog.ASSET_ATTRIBUTES = {
	Asset = "PeriAsset",
	Name = "PeriName",
	Category = "PeriCategory",
	Folder = "PeriFolder",
	Blocks = "PeriBlocksPath",
	Source = "PeriSource",
}

function Catalog.registerAsset(template: Instance)
	local A = Catalog.ASSET_ATTRIBUTES
	if template:GetAttribute(A.Asset) ~= true then
		return
	end
	local id = template.Name
	if Catalog.byId[id] then
		return
	end
	local source = template:GetAttribute(A.Source)
	define({
		id = id,
		name = tostring(template:GetAttribute(A.Name) or id),
		category = tostring(template:GetAttribute(A.Category) or "Props"),
		kind = "Model",
		periFolder = tostring(template:GetAttribute(A.Folder) or "Terrain"),
		blocksPath = template:GetAttribute(A.Blocks) == true,
		scalable = true,
		description = if source then "From Peri: " .. tostring(source) else "From Peri TD.",
	})
end

function Catalog.registerAssets(templates: Instance)
	for _, template in templates:GetChildren() do
		Catalog.registerAsset(template)
	end
end

Catalog.LANES = { "A", "B" }

function Catalog.spawnFor(lane: string): Def?
	for _, def in Catalog.list do
		if def.role == Catalog.ROLE.EnemySpawn and def.lane == lane then
			return def
		end
	end
	return nil
end

function Catalog.waypointFor(lane: string?): Def?
	for _, def in Catalog.list do
		if def.role == Catalog.ROLE.Waypoint and def.lane == lane then
			return def
		end
	end
	return nil
end

function Catalog.limit(def: Def): number?
	if def.maxCount then
		return def.maxCount
	end
	if def.unique then
		return 1
	end
	return nil
end

function Catalog.get(id: string?): Def?
	if typeof(id) ~= "string" then
		return nil
	end
	return Catalog.byId[id]
end

function Catalog.typeForRole(role: string): Def?
	for _, def in Catalog.list do
		if def.role == role and not def.hidden then
			return def
		end
	end
	return nil
end

function Catalog.visible(): { Def }
	local out = {}
	for _, def in Catalog.list do
		if not def.hidden then
			table.insert(out, def)
		end
	end
	return out
end

function Catalog.isMarker(def: Def): boolean
	return def.kind == "Marker"
end

return Catalog