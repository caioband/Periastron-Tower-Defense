local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Reads `FriendInvites` from a player on this server, without `viewdata`'s raw
	dump: totals first, then each friend in the order the draw would prefer them.
	Read-only.
]]
return function(context, player : Player?)
	local FriendInviteService = Framework:Get("FriendInviteService", false, true)

	return FriendInviteService:Describe(player or context.Executor)
end
