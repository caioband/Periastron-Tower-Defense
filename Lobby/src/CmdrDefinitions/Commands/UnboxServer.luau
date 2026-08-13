local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

return function(_context, players : { Player }, rarity : string)
	local CrateService = Framework:Get("CrateService", false, true)

	local played = {}

	for _, player in players do
		if CrateService:PlayUnboxing(player, rarity) then
			table.insert(played, player.Name)
		end
	end

	if #played == 0 then
		return string.format("Could not play a %s unboxing for anyone.", rarity)
	end

	return string.format("Playing a %s unboxing for %s.", rarity, table.concat(played, ", "))
end
