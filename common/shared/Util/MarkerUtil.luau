--[[
	The markers the map leaves for the UI: where a shop is and where it drops the
	player.

	Both Lobby shops use the same pair of parts: a reference, the center of the
	opening radius, and a landing spot, where the teleport leaves the character.
	This module only finds one of those parts and reads where it is; what to do
	with it belongs to each controller.

	The search is **deep** inside the map, not only direct children: markers are
	grouped in the model of their shop (`Map.Shop`, `Map.Deco.Houses.CardShop`),
	and requiring them loose at the map root would make an artist break the shop
	just by organizing the tree. Each marker name is unique in the map.
]]

local Log = require(script.Parent.Log)

local MarkerUtil = {}

--[=[
	Where a marker is, whether it is a Part or a Model.

	Returns nil for anything else, and nil is the right answer, not an error: a
	marker that became a Folder by accident leaves the shop closed, not the game
	broken.
]=]
function MarkerUtil.pivotOf(part : Instance?) : CFrame?
	if not part then
		return nil
	end

	if part:IsA("BasePart") then
		return part.CFrame
	elseif part:IsA("Model") then
		return part:GetPivot()
	end

	return nil
end

--[=[
	Half the marker's height, so the character lands **on top** of it instead of
	half buried. Zero for anything without its own height.
]=]
function MarkerUtil.halfHeightOf(part : Instance?) : number
	if part and part:IsA("BasePart") then
		return part.Size.Y / 2
	end

	return 0
end

--[=[
	Finds a marker under `Workspace.<parentName>`, with a cache and one warning per
	name.

	`cache` is a controller-owned table keyed by marker name: an entry is reused
	while the part is in the world and rebuilt when it leaves (a map change
	reparents everything, and a reference kept forever would point at an old map).

	`warned` is the same for warnings: a missing marker is an authoring mistake, and
	repeating the warning on every respawn only floods the Output. `source` is the
	name that appears in the warning, so it says which shop lacks the part.
]=]
function MarkerUtil.find(
	parentName : string,
	partName : string,
	cache : { [string] : Instance? },
	warned : { [string] : boolean },
	source : string
) : Instance?
	local cached = cache[partName]
	if cached and cached.Parent then
		return cached
	end

	local map = workspace:FindFirstChild(parentName)
	local part = map and map:FindFirstChild(partName, true)

	if not part and not warned[partName] then
		warned[partName] = true
		Log.new(source):StudioWarn(`no {partName} under Workspace.{parentName}.`)
	end

	cache[partName] = part
	return part
end

return MarkerUtil
