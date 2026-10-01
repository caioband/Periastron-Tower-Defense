local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Sends the friend invite suggestion now, through the same `:Prompt` the
	automatic one uses: the same draw, and the pick and the `Invite` click are
	written to the profile like the real thing.

	The friend is picked on the client, so the reply cannot say who: the
	notification is the answer. Nothing shows when no friend is online outside
	this server and off cooldown.
]]
return function(context, players : { Player }?, ignoreCooldown : boolean?)
	local FriendInviteService = Framework:Get("FriendInviteService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	for _, player in targets do
		FriendInviteService:Prompt(player, ignoreCooldown == true)
	end

	return `Friend invite suggestion sent to {#targets} player(s). Nothing shows for a player with no eligible online friend.`
end
