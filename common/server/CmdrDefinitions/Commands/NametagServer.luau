local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

return function(_context, action : string, players : { Player }, nametagId : string)
	local NametagService = Framework:Get("NametagService", false, true)

	if #players == 0 then
		return "Nobody matched."
	end

	local lines = {}
	for _, player in players do
		local ok, reason
		if action == "give" then
			ok, reason = NametagService:Grant(player, nametagId)
		elseif action == "take" then
			ok, reason = NametagService:Revoke(player, nametagId)
		elseif action == "equip" then
			ok, reason = NametagService:Equip(player, nametagId)
		else
			ok, reason = NametagService:Unequip(player, nametagId)
		end

		table.insert(lines, if ok then `{player.Name}: {action} {nametagId}` else `{player.Name}: {reason}`)
	end

	return table.concat(lines, "\n")
end