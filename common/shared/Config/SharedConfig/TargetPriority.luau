--[[
	A unit's target priority: what the card's `Priority` button cycles.

	It lives in Config, not Util, because both sides need the same list and names:
	the client sends the mode it wants and the server checks that it exists. The
	targeting math (`IsBetter`) lives here for the same reason: the server decides
	who takes damage and the client only turns the unit toward the target; if the
	two disagreed, the tower would hit one enemy while facing another.

	See docs/game/upgrade-card.md.
]]
local TargetPriority = {}

TargetPriority.Default = "Closest"

-- The button's cycle order: a click moves one step and wraps at the end.
TargetPriority.Order = { "Closest", "Farthest", "Weakest", "Strongest" }

-- Text on the button. Short, because the label is TextScaled on a low button.
TargetPriority.Labels = {
	Closest = "CLOSEST",
	Farthest = "FARTHEST",
	Weakest = "WEAKEST",
	Strongest = "STRONGEST",
}

function TargetPriority.Exists(mode : string?) : boolean
	return mode ~= nil and TargetPriority.Labels[mode] ~= nil
end

--[=[
	The mode, sanitized: anything other than the four becomes the default. Used
	for what arrives from the client and for old units with no stored priority.
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

--[=[
	Whether the mode needs the enemy's progress along the path.

	Only `Farthest`. Lets whoever builds the candidates skip the node scan in the
	other three modes, which only look at distance and health.
]=]
function TargetPriority.UsesPathProgress(mode : string?) : boolean
	return TargetPriority.Get(mode) == "Farthest"
end

export type Candidate = { distance : number, health : number, progress : number? }

--[=[
	Whether `candidate` replaces `best`. Both already passed the range check; this
	only compares which matters more.

	Distance breaks ties in every mode: with two enemies of equal health on
	`Weakest`, the unit keeps the closer one instead of switching targets on every
	scan as table order changes.
]=]
function TargetPriority.IsBetter(mode : string?, candidate : Candidate, best : Candidate?) : boolean
	if not best then
		return true
	end

	local resolved = TargetPriority.Get(mode)

	if resolved == "Farthest" then
		--[[
			"Farthest" is from the start of the path, not the tower: whoever has
			walked the most is shot first, because it is about to reach the base.

			Progress comes from the enemy's nearest node (`PathUtil.GetNodeProgress`)
			and does not exist until the whole path has reached the client. Without
			it, both sides fall back to the enemy farthest from the tower.
		]]
		if candidate.progress and best.progress then
			if candidate.progress ~= best.progress then
				return candidate.progress > best.progress
			end
		elseif candidate.distance ~= best.distance then
			return candidate.distance > best.distance
		end
	elseif resolved == "Weakest" then
		if candidate.health ~= best.health then
			return candidate.health < best.health
		end
	elseif resolved == "Strongest" then
		if candidate.health ~= best.health then
			return candidate.health > best.health
		end
	end

	return candidate.distance < best.distance
end

return TargetPriority
