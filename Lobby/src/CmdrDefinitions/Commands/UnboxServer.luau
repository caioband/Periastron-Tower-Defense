local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

return function(_context, players : { Player }, rarity : string)
	local CrateService = Framework:Get("CrateService", false, true)

	local rolled = {}

	for _, player in players do
		local result = CrateService:PlayUnboxing(player, rarity)
		if result then
			local chain = { result.Crate }
			for _, upgrade in result.Upgrades do
				table.insert(chain, upgrade)
			end

			local crate = table.concat(chain, " -> ")

			table.insert(rolled, string.format(
				"%s: [%s] %s%s",
				player.Name,
				crate,
				result.Rarity,
				result.Unit and (" / " .. result.Unit) or ""
			))
		end
	end

	if #rolled == 0 then
		return string.format("Could not play a %s unboxing for anyone.", rarity)
	end

	return table.concat(rolled, "\n")
end
