local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

return function(_context, players : { Player }, rarity : string, amount : number)
	local CrateService = Framework:Get("CrateService", false, true)

	local succeeded = {}
	local failed = {}

	for _, player in players do
		if CrateService:SetCrates(player, rarity, amount) ~= nil then
			table.insert(succeeded, player.Name)
		else
			table.insert(failed, player.Name)
		end
	end

	if #succeeded == 0 then
		return string.format("Could not set %s crates: no player had loaded data (%s).", rarity, table.concat(failed, ", "))
	end

	local response = string.format("Set %s crates to %d for %s.", rarity, amount, table.concat(succeeded, ", "))
	if #failed > 0 then
		response ..= string.format(" Skipped (data not loaded): %s.", table.concat(failed, ", "))
	end

	return response
end
