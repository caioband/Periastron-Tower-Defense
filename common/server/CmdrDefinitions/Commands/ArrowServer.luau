local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Ver a seta sem precisar de um passo de tutorial para isso.

	Sem posição, apaga. Sem jogadores, aponta para quem rodou — que é o caso de
	quem está conferindo se a seta gira e flutua do jeito certo.
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
