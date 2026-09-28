local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	See the tutorial offer without resetting your own data.

	It normally appears on its own for players with `Tutorial = false` in their
	profile, on arriving in the Lobby, which means that after the first time only
	someone who wipes their profile sees it again. This command goes through the same
	`:Prompt` and writes nothing, so it works both to test the dialog and to show it
	to someone.
]]
return function(context, players : { Player }?)
	local TutorialService = Framework:Get("TutorialService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	TutorialService:Prompt(targets)

	return `Tutorial offer sent to {#targets} player(s).`
end
