--!strict
--[[
	Catalog metadata for props copied from Peri TD's maps.

	The props themselves live in ServerStorage.MapEditorAssets.Peri (one child per
	prop, named as in Peri). This table only says how each is listed: display
	name, category, which Peri map folder it exports to, and whether it blocks
	enemy routes in validation. A prop missing here still appears, under Props.
]]
export type Entry = { name: string?, category: string, folder: string?, blocks: boolean? }

local PeriAssets: { [string]: Entry } = {
	Tree = { category = "Nature", blocks = true },
	SmallTree = { name = "Small Tree", category = "Nature", blocks = true },
	Bush = { category = "Nature" },
	Sprout = { category = "Nature" },
	Flower = { category = "Nature" },
	Flower1 = { name = "Flower (Volcano)", category = "Nature" },
	Lily = { name = "Lily Pad", category = "Nature" },
	Seed = { category = "Nature" },
	Log = { category = "Nature", blocks = true },
	LogPile = { name = "Log Pile", category = "Nature", blocks = true },
	Rock = { category = "Nature", blocks = true },
	Geyser = { category = "Nature" },
	Cave = { category = "Nature", blocks = true },
	Iceberg = { category = "Nature", folder = "Locked", blocks = true },
	Water = { category = "Ground", folder = "Locked" },

	HayBale = { name = "Hay Bale", category = "Props", blocks = true },
	Tractor = { category = "Props", blocks = true },
	Box = { category = "Props", blocks = true },
	BigBox = { name = "Big Box", category = "Props", blocks = true },
	SmallBox = { name = "Small Box", category = "Props", blocks = true },
	Cooler = { category = "Props", blocks = true },
	Bucket = { category = "Props", blocks = true },
	Cone = { name = "Beach Umbrella", category = "Props" },
	Trash = { name = "Trash Can", category = "Props", blocks = true },
	SurfBoard = { name = "Surfboard", category = "Props" },
	SandCastle = { name = "Sand Castle", category = "Props", blocks = true },
	Sign = { category = "Props" },
	Rug = { category = "Props" },
	Light = { category = "Props", blocks = true },
	Lamp = { category = "Props", blocks = true },

	Chair = { category = "Furniture", blocks = true },
	Bed = { category = "Furniture", blocks = true },
	Bookshelf = { category = "Furniture", blocks = true },
	Bookstand = { category = "Furniture", blocks = true },
	Shelf = { category = "Furniture", blocks = true },
	Fridge1 = { name = "Fridge", category = "Furniture", blocks = true },
	Radio = { category = "Furniture", blocks = true },
	RadioStand = { name = "Radio Stand", category = "Furniture", blocks = true },
	VendingMachine = { name = "Vending Machine", category = "Furniture", blocks = true },
	MicroPlant = { name = "Potted Plant", category = "Furniture", blocks = true },

	GuardTower = { name = "Guard Tower", category = "Structures", blocks = true },
	Wall = { name = "Beach Wall", category = "Structures", blocks = true },
	House1 = { name = "House (small)", category = "Structures", blocks = true },
	House2 = { name = "House (tall)", category = "Structures", blocks = true },
}

return PeriAssets
