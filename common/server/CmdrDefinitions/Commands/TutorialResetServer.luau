local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	See the tutorial offer again.

	The `Tutorial` key settles the matter on the first answer (winning **or**
	declining), so someone testing the flow would see it only once per profile. This
	command sets the key back to `false` and, in the Lobby, reopens the dialog right
	away.

	It touches nothing else: units, coins, and crates stay where they were.
]]
return function(context, players : { Player }?)
	local TutorialService = Framework:Get("TutorialService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	for _, player in targets do
		TutorialService:Reset(player)
	end

	return `Tutorial reset for {#targets} player(s).`
end
