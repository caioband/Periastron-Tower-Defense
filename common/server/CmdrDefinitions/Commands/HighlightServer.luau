local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Apontar um botão sem precisar de um passo de tutorial para isso.

	O caminho é de nomes a partir da `PlayerGui` — `highlight HUD.HUDLeft.Shop` —,
	que é a única forma de o servidor falar de uma tela que só existe no cliente.
	Sem caminho, apaga.
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
