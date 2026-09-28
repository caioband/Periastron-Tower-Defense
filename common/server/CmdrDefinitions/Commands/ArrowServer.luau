local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	See the arrow without needing a tutorial step for it.

	Without a position, it clears. Without players, it points for whoever ran the
	command, which is the case when checking that the arrow spins and floats right.
]]
return function(context, position : Vector3?, players : { Player }?)
	local ArrowService = Framework:Get("ArrowService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	if not position then
		ArrowService:Clear(targets)

		return "Arrow cleared."
	end

	ArrowService:Point(targets, position)

	return `Arrow pointing at {math.floor(position.X)}, {math.floor(position.Y)}, {math.floor(position.Z)} for {#targets} player(s).`
end
