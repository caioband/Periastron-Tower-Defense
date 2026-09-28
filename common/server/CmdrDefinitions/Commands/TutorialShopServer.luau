local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	The second part of the tutorial without the first.

	It normally arrives through the `TutorialDone` ticket the match server attaches
	to the teleport back, that is, only after winning the five waves. This command
	goes through the same `PromptShop` and writes nothing to the profile: it is for
	checking the dialog, the shop button highlight, and the wrap-up on buying the
	crate.
]]
return function(context, players : { Player }?)
	local TutorialService = Framework:Get("TutorialService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	TutorialService:PromptShop(targets)

	return `Lobby tutorial step sent to {#targets} player(s).`
end
