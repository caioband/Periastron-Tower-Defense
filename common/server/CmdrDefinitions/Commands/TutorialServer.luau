local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Ver a oferta de tutorial sem zerar a própria data.

	Ela normalmente sai sozinha para quem tem `Tutorial = false` no perfil, ao cair
	no lobby — o que significa que, depois da primeira vez, só quem apaga o perfil a
	vê de novo. Este comando entra pelo mesmo `:Prompt` e não escreve nada, então
	serve tanto para testar a fala quanto para mostrá-la a alguém.
]]
return function(context, players : { Player }?)
	local TutorialService = Framework:Get("TutorialService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	TutorialService:Prompt(targets)

	return `Tutorial offer sent to {#targets} player(s).`
end
