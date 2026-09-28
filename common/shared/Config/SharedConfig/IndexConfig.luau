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
	| `Maps` | the player **plays** the map for the first time |
	| `Enemies` | no trigger yet; the category exists and stays empty |

	`Enemies` is here on purpose even with nothing filling it: profiles already get
	the key, so when the trigger exists no profile needs a migration (and
	`DataService`'s reconcile covers old ones).

	## Who reads

	The client, through the replica. Unboxing is the first: a unit the player has
	not discovered yet shows black on the reel.

	Discovering is **not** owning. The Index is memory: a sold unit (or a map the
	player can no longer pick) stays discovered. The profile's `Units` answers "owns
	it now", not this table.
]]

local IndexConfig = {}

--- The categories, in the order an index UI would show them.
IndexConfig.CATEGORIES = {
	"Units",
	"Maps",
	"Enemies",
}

--[[ API ]]

--[=[
	A new profile's Index: one empty category per `CATEGORIES` entry.

	This is what `Data.Template` stores. A new category here reaches old profiles
	by itself through `DataService`'s reconcile.
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
	local index = typeof(profile) == "table" and profile.Index
	local entries = typeof(index) == "table" and index[category]

	return typeof(entries) == "table" and entries or {}
end

--- Whether the profile has already discovered this key.
function IndexConfig.has(profile : any, category : string, key : any) : boolean
	if typeof(key) ~= "string" then return false end

	return IndexConfig.entriesOf(profile, category)[key] == true
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
