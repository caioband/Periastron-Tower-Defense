local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Ver a oferta de tutorial de novo.

	A chave `Tutorial` encerra o assunto na primeira resposta — vencer **ou**
	recusar —, então quem está testando o fluxo só a veria uma vez por perfil. Este
	comando devolve a chave para `false` e, no lobby, reabre a fala na hora.

	Não mexe em mais nada: unidades, coins e crates continuam onde estavam.
]]
return function(context, players : { Player }?)
	local TutorialService = Framework:Get("TutorialService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	for _, player in targets do
		TutorialService:Reset(player)
	end

	return `Tutorial reset for {#targets} player(s).`
end
