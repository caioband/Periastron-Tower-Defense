local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	See the dialog box working without depending on an NPC existing.

	The text is `DialogConfig.Demo`, and it is fixed for a reason: it is a sentence
	that exercises the typewriter, the effect, the pause, the line break, and
	`[event=]` all at once. If rich text breaks, it breaks here in front of someone.
]]
return function(_context, players : { Player }?, auto : boolean?)
	local DialogService = Framework:Get("DialogService", false, true)

	DialogService:SendDemo(players, { Auto = auto == true })

	local target = if players and #players > 0 then `{#players} player(s)` else "everyone"

	return `Test dialogue sent to {target}.`
end
