local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Clears every active rune, through the same `RuneService:Clear` as `rune <tier 0>`.
	Open to QA testers (`QA_COMMANDS`): it only takes buffs away, so it cannot be used
	to give anyone anything.
]]
return function(context, players : { Player }?)
	local RuneService = Framework:Get("RuneService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }
	local cleared = 0

	for _, player in targets do
		if RuneService:Clear(player) then
			cleared += 1
		end
	end

	return `Runes cleared for {cleared} of {#targets} player(s).`
end
