local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

return function(_context, action : string, players : { Player }, skinId : string)
	local SkinService = Framework:Get("SkinService", false, true)

	if #players == 0 then
		return "Nobody matched."
	end

	local lines = {}
	for _, player in players do
		local ok, reason
		if action == "give" then
			ok, reason = SkinService:Grant(player, skinId)
		elseif action == "take" then
			ok, reason = SkinService:Revoke(player, skinId)
		elseif action == "equip" then
			ok, reason = SkinService:Equip(player, skinId)
		else
			ok, reason = SkinService:Unequip(player, skinId)
		end

		table.insert(lines, if ok then `{player.Name}: {action} {skinId}` else `{player.Name}: {reason}`)
	end

	return table.concat(lines, "\n")
end