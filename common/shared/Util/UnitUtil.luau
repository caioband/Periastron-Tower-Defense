local module = {}

function module:_lookForClosestEntity(position : Vector3)
	local closestEntity = nil
	local closestDistance = math.huge
	for _, entity in workspace.Entities:GetChildren() do
		local distance = (entity.PrimaryPart.Position - position).Magnitude
		if distance < closestDistance then
			closestDistance = distance
			closestEntity = entity
		end
	end
	return closestEntity
end

return module
