local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Ver a caixa de fala funcionando sem depender de um NPC existir.

	O texto é o `DialogConfig.Demo`, e ele é fixo por um motivo: é uma frase que
	exercita de uma vez a máquina de escrever, o efeito, a pausa, a quebra de linha
	e o `[event=]`. Se algo do texto rico quebrar, quebra aqui na frente de alguém.
]]
return function(_context, players : { Player }?, auto : boolean?)
	local DialogService = Framework:Get("DialogService", false, true)

	DialogService:SendDemo(players, { Auto = auto == true })

	local target = if players and #players > 0 then `{#players} player(s)` else "everyone"

	return `Test dialogue sent to {target}.`
end
