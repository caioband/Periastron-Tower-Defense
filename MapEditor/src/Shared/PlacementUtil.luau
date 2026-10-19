local Players = game:GetService("Players")

local PlacementUtil = {}

PlacementUtil.PathClearance = 4

function PlacementUtil.PathProbe(cf : CFrame, size : Vector3) : (CFrame, Vector3)
	local clearance = PlacementUtil.PathClearance

	return cf * CFrame.new(0, -clearance / 2, 0),
		Vector3.new(size.X, size.Y + clearance, size.Z)
end

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
