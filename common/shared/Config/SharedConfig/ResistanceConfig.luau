--[[
	Enemy resistances and elemental matchups.

	final damage = base * (1 - Resist[attackerClass]) * Matchup[attackerClass][enemyElement]

	Per enemy, in `Mob.Entities`:

	  Resist  = { Fire = 0.5 }    fraction of that class's damage BLOCKED.
	                              0.5 = blocks 50%, 1 = immune, -0.5 = takes 50% extra.
	  Element = "Electric"        optional. The enemy's own element, used for the
	                              matchup chart. A string or a list ({"Fire", "Melee"}).

	If `Element` is missing, the enemy's elements are the classes it has a positive
	`Resist` for. So `Resist = { Electric = 0.5 }` makes it an Electric enemy
	with no extra field.

	Enemies with neither field are untouched (multiplier 1).
	Units with no `Class` (the Azure today) are never resisted or boosted.
	Class names come from `WeatherConfig.ClassList`:
	Melee, Ranged, Magic, Fire, Ice, Electric.

    Example of how to wire them into mobs;
    KorbloxMage     = { Folder = "Impossible", Health = 5,   SpeedMultiplier = 1, Resist = { Electric = 0.5 } },              -- electric-res, so Ice hits it for 1.5x
    KorbloxGremlin  = { Folder = "Impossible", Health = 20,  SpeedMultiplier = 1 / 1.75, Resist = { Fire = 0.5, Melee = 0.25 } },
    OverseerKnight  = { Folder = "Nightmare",  Health = 120, SpeedMultiplier = 1 / 1.75, Element = "Ice", Resist = { Ice = 0.75, Fire = -0.5 } }, -- ice enemy, takes +50% from Fire
    KorbloxDeathRaider = { Folder = "Impossible", Boss = true, Health = 900, SpeedMultiplier = 1 / 2, Gimmicks = { BOSS_STUN }, Resist = { Magic = 1 } }, -- immune to Magic
]]

local Mob = require(script.Parent.Mob)

local ResistanceConfig = {}

-- Master switch. false = the whole system does nothing.
ResistanceConfig.Enabled = true

-- Tune these two numbers and every matchup below follows.
local STRONG = 1.5   -- attacker is strong against the enemy's element: +50%
local WEAK = 0.75    -- attacker is weak against the enemy's element:   -25%

--[[
	[attacker class] = { [enemy element] = damage multiplier }

	Two triangles, and every entry is its own number, so you can write any
	value you like instead of STRONG/WEAK:

	  Fire > Ice > Electric > Fire
	  Melee > Ranged > Magic > Melee

	Anything not listed is 1 (neutral).
]]
ResistanceConfig.Matchups = {
	Fire     = { Ice = STRONG,      Electric = WEAK },
	Ice      = { Electric = STRONG, Fire = WEAK },
	Electric = { Fire = STRONG,     Ice = WEAK },

	Melee    = { Ranged = STRONG,   Magic = WEAK },
	Ranged   = { Magic = STRONG,    Melee = WEAK },
	Magic    = { Melee = STRONG,    Ranged = WEAK },
}

--[[
	What to do when a unit has more than one class (`Class = {"Melee", "Fire"}`):
	  "Best"    use the class that deals the most damage (default)
	  "Worst"   use the class that deals the least
	  "Average" average them
]]
ResistanceConfig.MultiClass = "Best"

--[[ ================================ QUERIES ================================ ]]

local EMPTY = table.freeze({})

local elementsCache = {}
local multiplierCache = {}

local function toList(value)
	if value == nil then return EMPTY end
	if typeof(value) == "string" then return { value } end
	return value
end

-- The enemy's elements: its `Element`, else every class it has a positive Resist for.
local function elementsOf(entityName : string)
	local cached = elementsCache[entityName]
	if cached then return cached end

	local entity = Mob.Entities[entityName]
	local elements = EMPTY

	if entity then
		if entity.Element then
			elements = toList(entity.Element)
		elseif entity.Resist then
			local derived = {}
			for element, amount in entity.Resist do
				if amount > 0 then
					table.insert(derived, element)
				end
			end
			elements = derived
		end
	end

	elementsCache[entityName] = elements
	return elements
end

local function compute(entityName : string, class : string) : number
	local entity = Mob.Entities[entityName]
	if not entity then return 1 end

	local multiplier = 1

	local resist = entity.Resist and entity.Resist[class]
	if resist then
		multiplier *= (1 - math.min(resist, 1))
	end

	local chart = ResistanceConfig.Matchups[class]
	if chart then
		for _, element in elementsOf(entityName) do
			local value = chart[element]
			if value then
				multiplier *= value
			end
		end
	end

	return math.max(0, multiplier)
end

local function multiplierFor(entityName : string, class : string) : number
	local byClass = multiplierCache[entityName]
	if not byClass then
		byClass = {}
		multiplierCache[entityName] = byClass
	end

	local cached = byClass[class]
	if cached == nil then
		cached = compute(entityName, class)
		byClass[class] = cached
	end

	return cached
end

--[=[
	The damage multiplier for an enemy hit by a unit of these classes.

	`classes` is a string or a list (what `WeatherConfig.GetClasses` returns). With no
	classes, or the system off, returns 1. A result of 0 means the enemy is immune.
]=]
function ResistanceConfig.GetMultiplier(entityName : string?, classes) : number
	if not ResistanceConfig.Enabled or not entityName or not classes then return 1 end

	if typeof(classes) == "string" then
		return multiplierFor(entityName, classes)
	end

	local count = #classes
	if count == 0 then return 1 end
	if count == 1 then return multiplierFor(entityName, classes[1]) end

	local best, worst, sum = -math.huge, math.huge, 0
	for _, class in classes do
		local value = multiplierFor(entityName, class)
		best = math.max(best, value)
		worst = math.min(worst, value)
		sum += value
	end

	local mode = ResistanceConfig.MultiClass
	if mode == "Worst" then return worst end
	if mode == "Average" then return sum / count end
	return best
end

-- Call after changing a Resist / Element / Matchups value at runtime.
function ResistanceConfig.ClearCache()
	table.clear(elementsCache)
	table.clear(multiplierCache)
end

return ResistanceConfig