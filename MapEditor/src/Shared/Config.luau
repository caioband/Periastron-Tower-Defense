--!strict
local Config = {}

Config.SCHEMA_VERSION = 1

Config.MAX_OBJECTS = 2500
Config.MAX_MAPS_PER_PLAYER = 20
Config.MAX_PREFABS = 20
Config.MAX_PREFAB_OBJECTS = 200
Config.MAX_NAME_LENGTH = 32
Config.MAX_OPS_PER_REQUEST = 400
Config.MAX_ROUTE_STEPS = 256
Config.MAX_ALTERNATIVES = 4
Config.MAX_ROUTES = 32
Config.MAX_ENEMY_SPAWNS = 2

Config.BOUNDS_HALF_XZ = 1024
Config.BOUNDS_MIN_Y = -64
Config.BOUNDS_MAX_Y = 512

Config.PLOT_SPACING = 2600
Config.PLOT_FLOOR_SIZE = Vector3.new(2048, 2, 2048)

Config.GRID_SIZES = { 0.25, 0.5, 1, 2, 4, 8 }
Config.DEFAULT_GRID_INDEX = 4
Config.ROTATION_STEPS = { 15, 45, 90 }
Config.DEFAULT_ROTATION_INDEX = 3

Config.HISTORY_LIMIT = 150
Config.AUTOSAVE_INTERVAL = 120
Config.SAVE_COOLDOWN = 6
Config.LOAD_COOLDOWN = 3
Config.REQUEST_RATE = 25
Config.REQUEST_BURST = 60
Config.HEAVY_REQUEST_RATE = 0.5
Config.HEAVY_REQUEST_BURST = 4
Config.BUILD_CHUNK = 150
Config.SNAPSHOT_CHUNK = 400

Config.CAMERA_SPEED = 40
Config.CAMERA_FAST_MULTIPLIER = 3
Config.CAMERA_SENSITIVITY = 0.25

Config.PERI = {
	ContentFolders = { "Terrain", "Locked", "Path", "InvisWalls" },
	GridTag = "Grid",
	BaseHealthPart = "BaseHP",
	BaseHealthLabel = "Value",
	BaseHealthIcon = "rbxassetid://135308485706703",
	BaseHealthFont = "rbxassetid://12187371840",
	BoundsPartName = "BoundingBox",
	SurfaceAttribute = "Surface",
	NodeSize = Vector3.new(1, 0.1357, 1),
	BaseHealthOffset = Vector3.new(0, 3.5, 0),
	BoundsPadding = 8,
	BoundsMinHeight = 32,
	PathClearance = 4,
	NodeCountAttribute = "NodeCount",
	PointCountAttribute = "PointCount",
}

Config.VALIDATION = {
	SampleStep = 2,
	BodyHeight = 1.5,
	GroundProbe = 12,
	MinSpawnBaseDistance = 4,
}

Config.PLAYTEST = {
	EnemyCount = 12,
	EnemySpacing = 1.25,
	EnemySpeed = 8,
	EnemyHealth = 12,
	EnemySize = Vector3.new(1.6, 2.4, 1.6),
	BaseHealth = 20,
	TowerSize = Vector3.new(2, 3, 2),
	TowerRange = 18,
	TowerDamage = 4,
	TowerCooldown = 0.5,
	TowerMinSpacing = 2.5,
	MaxTowers = 12,
}

Config.MATERIALS = {
	"Plastic", "SmoothPlastic", "Wood", "WoodPlanks", "Slate", "Concrete", "Brick", "Cobblestone",
	"Granite", "Marble", "Grass", "LeafyGrass", "Ground", "Sand", "Sandstone", "Rock", "Basalt",
	"Limestone", "Mud", "Salt", "Ice", "Snow", "Metal", "DiamondPlate", "Fabric", "Glass", "Neon",
	"Asphalt", "Pavement", "CrackedLava",
}

Config.COLORS = {
	"F2F3F3", "A3A2A5", "635F62", "1B2A35", "C4281C", "DA8541", "F5CD30", "4B974B", "287F47", "6C8F3E",
	"0D69AC", "6E99CA", "8C5B9F", "7C5C46", "D7C59A", "E8BAC8", "AA5500", "5A4C42", "B8E6FF", "FFFFFF",
}

Config.SHAPES = { "Block", "Ball", "Cylinder", "Wedge", "CornerWedge" }

return Config
