local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Write markup, press DISPLAY, look.

	Without a target, the workbench opens for whoever ran the command: it is a tool
	for whoever is working on the text, not an announcement. Passing players shows
	the result to someone else in the same session.
]]
return function(context, players : { Player }?)
	local RichTextLabService = Framework:Get("RichTextLabService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	RichTextLabService:Toggle(targets)

	if #targets == 1 and targets[1] == context.Executor then
		return "Rich text lab toggled."
	end

	return `Rich text lab toggled for {#targets} player(s).`
end
