local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Point at a button without needing a tutorial step for it.

	The path is names from `PlayerGui` (`highlight HUD.HUDLeft.Shop`), the only way
	the server can talk about a screen that only exists on the client. Without a
	path, it clears.
]]
return function(context, path : string?, players : { Player }?)
	local HighlightService = Framework:Get("HighlightService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	if not path or path == "" then
		HighlightService:Hide(targets)

		return "Highlight cleared."
	end

	HighlightService:Show(targets, path)

	return `Highlighting "{path}" for {#targets} player(s).`
end
