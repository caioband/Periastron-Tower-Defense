local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	A segunda parte do tutorial sem a primeira.

	Ela normalmente chega pelo bilhete `TutorialDone` que o servidor da partida
	embarca no teleporte de volta — ou seja, só depois de vencer as cinco waves.
	Este comando entra pelo mesmo `PromptShop` e não escreve nada no perfil: serve
	para conferir a fala, o destaque no botão da loja e o fecho na compra da caixa.
]]
return function(context, players : { Player }?)
	local TutorialService = Framework:Get("TutorialService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	TutorialService:PromptShop(targets)

	return `Lobby tutorial step sent to {#targets} player(s).`
end
