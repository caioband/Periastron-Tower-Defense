--[[
	The player's Index: what they have discovered in the game.

	One category per kind of collectible, each storing only `{ [key] = true }` in
	the profile. The key is the one the rest of the game already uses (the unit
	name in `UnitStats`, the map name in `MapConfig`), so discovering duplicates no
	data: the Index says **whether** the player knows the thing, and its own config
	still describes it.

	## Who writes

	Only `IndexService` (server). Each category has a trigger:

	| Category | Discovered when |
	| --- | --- |
	| `Units` | the player **obtains** the unit (crate, summon) |
	| `Enemies` | the enemy **spawns** in a match the player is in (`MobService`) |
	| `Weathers` | the weather **goes live** in the player's match (`WeatherRoundService`); the warning alone does not count |
	| `Maps` | the player **enters** the map (`MapService`) |

	A new category reaches old profiles through `DataService`'s reconcile, so no
	migration is needed.

	## Seen

	`Index` has a twin, `IndexSeen`, with the same shape: what the player has
	**clicked** in the Index UI. A key discovered and not seen yet is "new", and
	that is what lights the `New` badge on the item and on the HUD's `Index`
	button. Only discovered keys can be seen; `IndexService` checks it.

	## Who reads

	The client, through the replica. Unboxing reads it (a unit the player has not
	discovered yet shows black on the reel), and so does the Lobby's Index UI
	(`IndexController`).

	Discovering is **not** owning. The Index is memory: a sold unit (or a map the
	player can no longer pick) stays discovered. The profile's `Units` answers "owns
	it now", not this table.
]]

local IndexConfig = {}

--- The categories, in the order the Index UI shows them (one page each).
IndexConfig.CATEGORIES = {
	"Units",
	"Enemies",
	"Weathers",
	"Maps",
}

--- The profile keys: what was discovered, and what of that was already clicked.
IndexConfig.DISCOVERED_KEY = "Index"
IndexConfig.SEEN_KEY = "IndexSeen"

--[=[
	The keys the Index knows, per category: the same sets the Lobby's Index pages
	list (`IndexCatalog`). A key outside them has no page, so it can never be
	clicked, and counting it as new would light the HUD badge forever. That
	happened with the tutorial map, which `MapService` recorded and `MapConfig`
	leaves out on purpose.

	Required on first use, not at the top: `SharedConfig` loads every sibling, and
	requiring them here at load time would tie this module to that order.
]=]
local KNOWN = {
	Units = function(key : string) : boolean
		local stats = require(script.Parent.UnitStats)[key]
		return typeof(stats) == "table" and stats.Rarity ~= nil
	end,

	Enemies = function(key : string) : boolean
		return require(script.Parent.Mob).Entities[key] ~= nil
	end,

	Weathers = function(key : string) : boolean
		return require(script.Parent.WeatherConfig).Indicator.Icons[key] ~= nil
	end,

	Maps = function(key : string) : boolean
		return require(script.Parent.MapConfig).MAPS[key] ~= nil
	end,
}

--[[ API ]]

--- Whether the key belongs to the category's catalog. See `KNOWN`.
function IndexConfig.isKnown(category : string, key : any) : boolean
	local known = KNOWN[category]
	return typeof(key) == "string" and known ~= nil and known(key)
end

--[=[
	A new profile's Index: one empty category per `CATEGORIES` entry.

	This is what `Data.Template` stores, for both `Index` and `IndexSeen`. A new
	category here reaches old profiles by itself through `DataService`'s reconcile.
]=]
function IndexConfig.createEmpty() : { [string]: { [string]: boolean } }
	local index = {}

	for _, category in IndexConfig.CATEGORIES do
		index[category] = {}
	end

	return index
end

--- Whether the name is a real category. Anything from outside goes through here.
function IndexConfig.isCategory(category : any) : boolean
	if typeof(category) ~= "string" then return false end

	for _, known in IndexConfig.CATEGORIES do
		if known == category then
			return true
		end
	end

	return false
end

--[=[
	A category's discoveries: `{ [key] = true }`.

	A profile not loaded yet (or a category that does not exist) counts as empty,
	not an error, the same agreement as `GamepassConfig.ownedOf`: until the data
	arrives, the player counts as having discovered nothing, which the UI can draw.
]=]
function IndexConfig.entriesOf(profile : any, category : string) : { [string]: boolean }
	return IndexConfig.tableOf(profile, IndexConfig.DISCOVERED_KEY, category)
end

--- A category's clicked keys: `{ [key] = true }`, with the same agreement as `entriesOf`.
function IndexConfig.seenOf(profile : any, category : string) : { [string]: boolean }
	return IndexConfig.tableOf(profile, IndexConfig.SEEN_KEY, category)
end

--- `profile[root][category]`, or an empty table when any step is missing.
function IndexConfig.tableOf(profile : any, root : string, category : string) : { [string]: boolean }
	local index = typeof(profile) == "table" and profile[root]
	local entries = typeof(index) == "table" and index[category]

	return typeof(entries) == "table" and entries or {}
end

--- Whether the profile has already discovered this key.
function IndexConfig.has(profile : any, category : string, key : any) : boolean
	if typeof(key) ~= "string" then return false end

	return IndexConfig.entriesOf(profile, category)[key] == true
end

--[=[
	Whether the key is "new": discovered, and not clicked in the Index yet. A key
	not discovered is never new, so a stray `IndexSeen` entry can light nothing; nor
	is a key the Index does not know (`isKnown`), which nobody could click.
]=]
function IndexConfig.isNew(profile : any, category : string, key : any) : boolean
	if not IndexConfig.has(profile, category, key) then return false end
	if not IndexConfig.isKnown(category, key) then return false end

	return IndexConfig.seenOf(profile, category)[key] ~= true
end

--- Whether anything in any category is new: the HUD button's badge.
function IndexConfig.hasNew(profile : any) : boolean
	for _, category in IndexConfig.CATEGORIES do
		local seen = IndexConfig.seenOf(profile, category)

		for key, discovered in IndexConfig.entriesOf(profile, category) do
			if discovered and seen[key] ~= true and IndexConfig.isKnown(category, key) then
				return true
			end
		end
	end

	return false
end

--- How many things the profile has discovered in a category.
function IndexConfig.count(profile : any, category : string) : number
	local total = 0

	for _, discovered in IndexConfig.entriesOf(profile, category) do
		if discovered then
			total += 1
		end
	end

	return total
end

return IndexConfig
