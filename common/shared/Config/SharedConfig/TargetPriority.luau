--[[
	A unit's target priority: what the card's `Priority` button cycles.

	It lives in Config, not Util, because both sides need the same list and names:
	the client sends the mode it wants and the server checks that it exists. The
	targeting math (`IsBetter`) lives here for the same reason: the server decides
	who takes damage and the client only turns the unit toward the target; if the
	two disagreed, the tower would hit one enemy while facing another.

	The modes:
	  First      the enemy furthest along the path (closest to the base)
	  Last       the enemy least far along the path (the most recent arrival)
	  Weakest    the lowest current health
	  Strongest  the highest current health

	"Furthest along" is the distance walked on the enemy's own route, the same number
	on both sides: the server's `mob.Distance`, and `MobController:GetPathDistance`
	on the client.

	See docs/game/upgrade-card.md.
]]
local TargetPriority = {}

TargetPriority.Default = "First"

--[=[
	Not a mode the player can pick: it is not in `Order` or `Labels`, so `Exists` and
	`Get` do not know it. It is for server code that only wants "who is nearest the
	tower" (`MobService:GetNearestMobInRange`).
]=]
TargetPriority.Nearest = "Nearest"

-- The button's cycle order: a click moves one step and wraps at the end.
TargetPriority.Order = { "First", "Last", "Weakest", "Strongest" }

-- Text on the button. Short, because the label is TextScaled on a low button.
TargetPriority.Labels = {
	First = "FIRST",
	Last = "LAST", 
	Weakest = "WEAKEST",
	Strongest = "STRONGEST",
}

function TargetPriority.Exists(mode : string?) : boolean
	return mode ~= nil and TargetPriority.Labels[mode] ~= nil
end

--[=[
	The mode, sanitized: anything other than the four becomes the default. Used
	for what arrives from the client and for units that still carry a mode from
	before this list changed (`Closest`, `Farthest`).
]=]
function TargetPriority.Get(mode : string?) : string
	if TargetPriority.Exists(mode) then
		return mode :: string
	end

	return TargetPriority.Default
end

function TargetPriority.Next(mode : string?) : string
	local current = TargetPriority.Get(mode)
	local index = table.find(TargetPriority.Order, current) or 1

	return TargetPriority.Order[(index % #TargetPriority.Order) + 1]
end

function TargetPriority.Label(mode : string?) : string
	return TargetPriority.Labels[TargetPriority.Get(mode)]
end

export type Candidate = { distance : number, health : number, progress : number }

--[=[
	Whether `candidate` replaces `best`. Both already passed the range check; this
	only compares which matters more.

	`progress` is the distance walked along the enemy's route. Ties fall through to
	the next criterion, so two enemies never swap places on every scan because of
	table order:

	  First / Last          progress, then the one closer to the tower
	  Weakest / Strongest   health, then the one further along, then closer to the tower
]=]
function TargetPriority.IsBetter(mode : string?, candidate : Candidate, best : Candidate?) : boolean
	if not best then
		return true
	end

	if mode == TargetPriority.Nearest then
		return candidate.distance < best.distance
	end

	local resolved = TargetPriority.Get(mode)

	if resolved == "First" then
		if candidate.progress ~= best.progress then
			return candidate.progress > best.progress
		end
	elseif resolved == "Last" then
		if candidate.progress ~= best.progress then
			return candidate.progress < best.progress
		end
	elseif resolved == "Weakest" then
		if candidate.health ~= best.health then
			return candidate.health < best.health
		end
		if candidate.progress ~= best.progress then
			return candidate.progress > best.progress
		end
	elseif resolved == "Strongest" then
		if candidate.health ~= best.health then
			return candidate.health > best.health
		end
		if candidate.progress ~= best.progress then
			return candidate.progress > best.progress
		end
	end

	return candidate.distance < best.distance
end

return TargetPriority