--[[
	What unit placement asks about the path.

	It lives here, not on each side, because the question is asked twice: the
	client asks to paint the ghost green or red, the server asks to accept or
	refuse. If the two answers diverge the player sees a green ghost and the unit
	does not spawn, or worse, the reverse. See docs/game/unit-placement.md.
]]
local Players = game:GetService("Players")

local PlacementUtil = {}

--[[
	How much air above the path still counts as path.

	Without it, the only test was the unit's own box touching the rail, and the
	rail is thin (25 cm) and flush with the floor. Anything that lifted the unit a
	hand's width (the edge of a bridge, a rock over the path, a step) took the path
	out of the box, and the tower became valid on top of it.

	Four studs is the tallest enemy in the game (the Redcliff Champion, 3.35) with
	margin: the space the path actually occupies while a wave passes.
]]
PlacementUtil.PathClearance = 4

--[[
	The ghost's collision group.

	It lives here because both sides use it: `CollisionService` (server) registers
	the group and makes it non-collidable with everything, and
	`UnitPlacementController` (client) puts the ghost parts in it. A group only
	exists if the server registers it, so both must use the same name.

	> Nothing else may join this group. Placement queries (`GetPartsInPart` and
	> friends) use `OverlapParams` in the `Default` group, and a part in a group
	> that does not collide with `Default` is **invisible** to them: map geometry in
	> here would be terrain the ghost passes through without turning red. The ghost
	> may, because it is exactly what nobody should see.
]]
PlacementUtil.GhostCollisionGroup = "PlacementGhost"

--[[
	The player characters' collision group.

	It exists for the same reason, and the pair between the two is the point: ghost
	and character do not collide. `CollisionService` (server) registers both and
	declares the pair, and it also puts **every BasePart** of each character here
	(body, accessories, and anything added to the model later).

	Unlike the ghost group, this one collides with everything else normally:
	characters still hit the map, other characters, and placed units. Only the
	ghost is left out.

	> This does **not** remove characters from placement queries.
	> `FindBlockingCharacter` queries with `OverlapParams` in `Default`, and what
	> counts is collidability between the params' group and the part's: since this
	> group collides with `Default`, a character still shows up and still blocks.
]]
PlacementUtil.CharacterCollisionGroup = "Character"

--[=[
	The box that tests the path: the unit's own volume plus a column of
	`PathClearance` studs under it.

	Returns `CFrame, Vector3` to feed the same `GetPartsInPart` on both sides; the
	rotation comes along because the unit may have been rotated before dropping.
]=]
function PlacementUtil.PathProbe(cf : CFrame, size : Vector3) : (CFrame, Vector3)
	local clearance = PlacementUtil.PathClearance

	return cf * CFrame.new(0, -clearance / 2, 0),
		Vector3.new(size.X, size.Y + clearance, size.Z)
end

--[=[
	The player character inside the unit's box, or `nil` if the spot is free.

	Only player characters, on purpose. Enemies and placed units also have a
	Humanoid, but neither counts here: units are already blocked by the minimum
	tower distance, and enemies do not exist as models on the server
	(`MobController` clones them on the client). Blocking enemies on one side only
	would paint the ghost red where the server would accept, exactly the divergence
	this module exists to prevent.

	The box is the unit's full bounding box, the same on both sides: the ghost is
	drawn at 80% size, but the whole unit will occupy the ground.

	Accessories do not count. Hats and wings stick out far from the body and are
	queryable like any part; without this exception, the player would see
	placement refused on a spot that looks empty.
]=]
function PlacementUtil.FindBlockingCharacter(cf : CFrame, size : Vector3) : Model?
	local characters = {}

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(characters, character)
		end
	end

	if #characters == 0 then return nil end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = characters

	for _, part in workspace:GetPartBoundsInBox(cf, size, overlapParams) do
		if part:FindFirstAncestorOfClass("Accessory") then continue end

		for _, character in characters do
			if part:IsDescendantOf(character) then
				return character
			end
		end
	end

	return nil
end

return PlacementUtil
