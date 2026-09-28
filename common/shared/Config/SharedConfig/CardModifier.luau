--[[
	The buffs and debuffs round cards leave on the field.

	A round card rarely does one thing and ends: it **leaves a rule in effect**.
	Trumpet speeds everyone up 15%, Overcharge splits Electric from the rest, the
	staffs draw a ring on the ground where the rule applies only inside, and Bloxy
	Cola applies to one tower for ten seconds.

	This module is the grammar of those rules. It holds no state: `CardModifierService`
	(server) and `CardModifierController` (client, to draw the ring and show the
	right range on the card) keep the live list. Only the math lives here: given a
	modifier, a unit, and the rest of the field, does it apply? How much?

	It is shared because both sides **must** give the same answer: the server
	applies damage with the multiplier, and the range circle the player sees comes
	from the same function.

	## What a modifier is

	A flat record (it crosses the network, so no functions or metatables):

	| Field | What it is |
	| --- | --- |
	| `Uid` | who created it: the `uid` of the used card, which expiry removes it by |
	| `Card` | the card `Id`, for logs and the ring color |
	| `Stats` | the multipliers: `{ Damage = 1.25 }` |
	| `Flags` | what is not a number: today only `Cleave` |
	| `Classes` | the classes it affects; without it, all |
	| `Exclude` | inverts `Classes`: applies to units **not** of those classes |
	| `Farm` | `true` only for income units, `false` only for the rest |
	| `UnitId` | only that unit |
	| `Zone` | `{ Position, Radius }`: only units inside the ring |
	| `Condition` | a question about the unit's **neighborhood** (see below) |
	| `Scaling` | a multiplier that grows with how many units of a class are on the map |
	| `BaseHealthBelow` | only applies while base health is below this fraction |
	| `ExpiresAt` | the `GameClock` instant it dies; without it, it lasts the round |

	A card can create **several** records, which is how it does two opposite things
	at once: Overcharge is `{ Classes = {"Electric"}, Damage = 1.25 }` plus
	`{ Classes = {"Electric"}, Exclude = true, Damage = 0.89 }`. Separate records
	let the same function answer for both without knowing any card.

	## Stats

	Everything is a **multiplier**, as with weather: 1.25 is "+25%", 0.8 is "-20%".

	| Stat | Where it applies |
	| --- | --- |
	| `Damage` | damage per hit (`UnitService:getDamage`) |
	| `AttackSpeed` | above 1 hits faster; divides the cooldown |
	| `Range` | range, and with it the circle the player sees |
	| `Income` | farm income (`payFarmUnits`) |
	| `HitIncome` | the cash that damage and kills pay |
	| `Slow` | how much an ice unit's slow weighs |
	| `Burn` | how much a burn charges per tick |

	`Slow` and `Burn` are global: they describe the state the tower left on the
	enemy, not the tower. `MobService` reads them through `Global`.

	## Conditions

	`Condition` is what cannot be answered by looking at the unit alone; it needs
	the rest of the field, which arrives in `world`:

	- `Isolated`: no other unit within `ConditionRadius` (Iceolated, rewarding a
	  lone ice tower).
	- `NearClass`: at least one unit of class `ConditionClass` within
	  `ConditionRadius` (the other side of Ice to Meet You: units near an ice tower
	  work slower).

	Both measure on the horizontal plane: two towers at different heights in the
	same area are neighbors.

	See docs/game/round-cards.md.
]]

local UnitStats = require(script.Parent.UnitStats)
local WeatherConfig = require(script.Parent.WeatherConfig)

local CardModifier = {}

--[[
	Stat names, in one place. Whoever writes a card in `RoundCardConfig` and whoever
	reads a multiplier in the service use these keys: a misspelled stat is a card
	that does nothing, the kind of mistake that never shows in the log.
]]
CardModifier.Stats = {
	Damage = "Damage",
	AttackSpeed = "AttackSpeed",
	Range = "Range",
	Income = "Income",
	HitIncome = "HitIncome",
	Slow = "Slow",
	Burn = "Burn",
}

--- What is not a number. See `CardModifier.Enabled`.
CardModifier.Flags = {
	Cleave = "Cleave",
}

CardModifier.Conditions = {
	Isolated = "Isolated",
	NearClass = "NearClass",
}

--[[ INTERNAL ]]

local function hasAnyClass(unitName : string?, classes : { string }) : boolean
	for _, class in classes do
		if WeatherConfig.HasClass(unitName, class) then
			return true
		end
	end

	return false
end

--- Income unit (the Entrepreneur and any that follow).
local function isFarm(unitName : string?) : boolean
	local stats = unitName and UnitStats[unitName]

	return stats ~= nil and stats.Farm ~= nil
end

--[[
	Distance on the horizontal plane. Y is left out on purpose: the staff's ring is a
	circle drawn on the ground, and a tower on a rock inside it is inside it.
]]
local function flatDistance(a : Vector3, b : Vector3) : number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

--[[ API ]]

--[=[
	How many field units are within `radius` of `unit`, not counting itself.

	`className` restricts the count to a class; without it, any unit counts.
	`world.Units` is the list of descriptors (`{ UnitId, UnitName, Position }`);
	without it there is no neighborhood and the answer is zero, so a proximity
	condition simply does not apply instead of erroring.
]=]
function CardModifier.CountNear(world, unit, radius : number, className : string?) : number
	local units = world and world.Units
	if not units or not unit.Position then
		return 0
	end

	local count = 0

	for _, other in units do
		if other.UnitId == unit.UnitId or not other.Position then
			continue
		end

		if className and not WeatherConfig.HasClass(other.UnitName, className) then
			continue
		end

		if flatDistance(other.Position, unit.Position) <= radius then
			count += 1
		end
	end

	return count
end

--- How many units of the class are on the map. What Abrakadabra counts.
function CardModifier.CountClass(world, className : string?) : number
	local units = world and world.Units
	if not units then
		return 0
	end

	local count = 0

	for _, other in units do
		if not className or WeatherConfig.HasClass(other.UnitName, className) then
			count += 1
		end
	end

	return count
end

--[=[
	Does this modifier apply to this unit?

	Filters are cumulative and ordered from cheapest to most expensive: comparing an
	id costs nothing, scanning the whole neighborhood does, so there is no reason to
	measure distance for a unit already rejected by class.

	`ExpiresAt` is **not** checked here. The service has the clock and prunes the
	list; checking again per unit and stat would repeat the same question hundreds of
	times per frame.
]=]
function CardModifier.Applies(modifier, unit, world) : boolean
	if modifier.UnitId and modifier.UnitId ~= unit.UnitId then
		return false
	end

	if modifier.Classes then
		local matches = hasAnyClass(unit.UnitName, modifier.Classes)

		if modifier.Exclude then
			if matches then return false end
		elseif not matches then
			return false
		end
	end

	if modifier.Farm ~= nil and isFarm(unit.UnitName) ~= modifier.Farm then
		return false
	end

	local zone = modifier.Zone
	if zone then
		if not unit.Position or flatDistance(unit.Position, zone.Position) > (zone.Radius or 0) then
			return false
		end
	end

	--[[
		Base health is a fraction from 0 to 1. Without it (a client that has not
		received the first `UpdateBaseHealth`) the modifier stays out: better to show
		the number without the bonus for a moment than promise a bonus the server is
		not giving.
	]]
	if modifier.BaseHealthBelow then
		local ratio = world and world.BaseHealthRatio

		if not ratio or ratio >= modifier.BaseHealthBelow then
			return false
		end
	end

	local condition = modifier.Condition
	if condition == CardModifier.Conditions.Isolated then
		if CardModifier.CountNear(world, unit, modifier.ConditionRadius or 0) > 0 then
			return false
		end
	elseif condition == CardModifier.Conditions.NearClass then
		if CardModifier.CountNear(world, unit, modifier.ConditionRadius or 0, modifier.ConditionClass) <= 0 then
			return false
		end
	end

	return true
end

--[=[
	A stat's multiplier for a unit: the product of everything that applies to it.

	A product, not a replacement as with weather. Weather is one and writes the
	final number per class, while cards are bought one by one and **stack** on
	purpose: a player who spent two uses on the same tower type must see both apply.

	`Scaling` enters here too, which is what gives Abrakadabra: instead of a fixed
	number, the multiplier is `1 + (units of the class) * Amount`.
]=]
function CardModifier.Multiplier(modifiers, stat : string, unit, world) : number
	if not modifiers then return 1 end

	local total = 1

	for _, modifier in modifiers do
		if not CardModifier.Applies(modifier, unit, world) then
			continue
		end

		local value = modifier.Stats and modifier.Stats[stat]
		if value then
			total *= value
		end

		local scaling = modifier.Scaling
		if scaling and scaling.Stat == stat then
			total *= 1 + CardModifier.CountClass(world, scaling.Class) * (scaling.Amount or 0)
		end
	end

	return total
end

--[=[
	Whether a `Flags` entry is on for this unit.

	Separate from `Multiplier` because not everything a card does is a number.
	"Melee also hits the one behind" has no middle ground, and writing it as a 1.0
	multiplier would be a lie the next reader would try to multiply.
]=]
function CardModifier.Enabled(modifiers, flag : string, unit, world) : boolean
	return CardModifier.FlagValue(modifiers, flag, unit, world) ~= nil
end

--[=[
	The **value** of a `Flags` entry on for this unit, or `nil`.

	The value is usually the numbers that behavior needs: Cleave carries how many
	bodies the swing hits, how much the second loses, and the width of the line.
	They live in the modifier, not a `UnitService` constant, because the card picks
	them: a second cleave card with its own numbers should not need combat changes.

	The **first** that applies wins. Two cleave cards at once does not happen today,
	and adding their numbers would invent a third behavior nobody asked for.
]=]
function CardModifier.FlagValue(modifiers, flag : string, unit, world)
	if not modifiers then return nil end

	for _, modifier in modifiers do
		local value = modifier.Flags and modifier.Flags[flag]

		if value and CardModifier.Applies(modifier, unit, world) then
			return value
		end
	end

	return nil
end

--[=[
	A stat multiplier that belongs to **no** unit in particular: the burn already on
	an enemy, the slow already applied.

	Only unfiltered modifiers count. A zone or class modifier describes towers, and
	the burn on an enemy does not know which tower it came from; counting it here
	would let a ring drawn in one corner change a burn in another.
]=]
function CardModifier.Global(modifiers, stat : string) : number
	if not modifiers then return 1 end

	local total = 1

	for _, modifier in modifiers do
		if modifier.UnitId or modifier.Classes or modifier.Zone or modifier.Condition or modifier.Farm ~= nil then
			continue
		end

		local value = modifier.Stats and modifier.Stats[stat]
		if value then
			total *= value
		end
	end

	return total
end

return CardModifier
