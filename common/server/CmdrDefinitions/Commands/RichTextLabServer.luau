local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Escrever marcação, apertar DISPLAY, ver.

	Sem alvo, a bancada abre para quem rodou o comando — ela é ferramenta de quem
	está mexendo no texto, não anúncio. Passar jogadores serve para mostrar o
	resultado a outra pessoa na mesma sessão.
]]
return function(context, players : { Player }?)
	local RichTextLabService = Framework:Get("RichTextLabService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }

	RichTextLabService:Toggle(targets)

	if #targets == 1 and targets[1] == context.Executor then
		return "Rich text lab toggled."
	end

	return `Rich text lab toggled for {#targets} player(s).`
end
