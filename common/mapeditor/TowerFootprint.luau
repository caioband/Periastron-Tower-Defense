--!strict
--[[
	Where a playtest tower may stand, by the match's own rules, so the editor refuses
	exactly what the game refuses:

	- path: the unit's real bounding box, stretched down by `PlacementUtil.PathProbe`,
	  touches no Grid part (UnitService:isSpotFree);
	- obstruction: the unit's root part, where it would stand, touches no map part
	  other than the ground under it (UnitPlacementController);
	- spacing: two units stand at least half their widths added apart, measured flat
	  (both of the above);
	- nobody is standing there (PlacementUtil.FindBlockingCharacter).

	The client asks it to paint the ghost and the server asks it to accept the tower,
	so the two answers cannot drift apart.
]]
local PlacementUtil = require(script.Parent.PlacementUtil)

local TowerFootprint = {}

export type Info = {
	size: Vector3,
	lift: number,
	rootSize: Vector3,
}

export type Other = {
	name: string,
	position: Vector3,
}

local cache: { [Model]: Info } = {}

function TowerFootprint.info(template: Model): Info
	local cached = cache[template]
	if cached then
		return cached
	end
	local cf, size = template:GetBoundingBox()
	local root = template:FindFirstChild("HumanoidRootPart") or template.PrimaryPart
	local info: Info = { size = size, lift = size.Y / 2, rootSize = Vector3.one }
	if root and root:IsA("BasePart") then
		info.lift = root.Position.Y - (cf.Position.Y - size.Y / 2)
		info.rootSize = root.Size
	end
	cache[template] = info
	return info
end

-- The match places a unit half its model's height above the ground
-- (UnitPlacementController); range and the path test are measured from there.
function TowerFootprint.placedPosition(template: Model, ground: Vector3): Vector3
	return ground + Vector3.new(0, TowerFootprint.info(template).size.Y / 2, 0)
end

local probe: Part? = nil

local function partsIn(cf: CFrame, size: Vector3, params: OverlapParams): { BasePart }
	local part = probe
	if not part or not part.Parent then
		part = Instance.new("Part")
		part.Name = "TowerFootprintProbe"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.Parent = workspace
		probe = part
	end
	local p = part :: Part
	p.Size = size
	p.CFrame = cf
	return workspace:GetPartsInPart(p, params)
end

function TowerFootprint.check(
	units: Instance,
	unitName: string,
	ground: Vector3,
	others: { Other },
	grid: { BasePart },
	mapRoot: Instance?,
	groundPart: Instance?
): (boolean, string?)
	local template = units:FindFirstChild(unitName)
	if not template or not template:IsA("Model") then
		return false, "Unknown tower."
	end
	local info = TowerFootprint.info(template)
	local cf = CFrame.new(TowerFootprint.placedPosition(template, ground))

	if #grid > 0 then
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = grid
		local probeCF, probeSize = PlacementUtil.PathProbe(cf, info.size)
		if #partsIn(probeCF, probeSize, params) > 0 then
			return false, "On the path."
		end
	end

	if mapRoot then
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { mapRoot }
		for _, part in partsIn(CFrame.new(ground + Vector3.new(0, info.lift, 0)), info.rootSize, params) do
			if part ~= groundPart then
				return false, "Obstructed by " .. part.Name .. "."
			end
		end
	end

	for _, other in others do
		local otherTemplate = units:FindFirstChild(other.name)
		local otherWidth = if otherTemplate and otherTemplate:IsA("Model")
			then TowerFootprint.info(otherTemplate).size.X
			else info.size.X
		local offset = (other.position - ground) * Vector3.new(1, 0, 1)
		if offset.Magnitude < (info.size.X + otherWidth) / 2 then
			return false, "Too close to another tower."
		end
	end

	if PlacementUtil.FindBlockingCharacter(cf, info.size) then
		return false, "A player is standing there."
	end

	return true, nil
end

return TowerFootprint
