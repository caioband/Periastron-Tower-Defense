local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	O lado servidor do holofote.

	O destaque é todo do cliente (`HighlightController`) — quem sabe onde um botão
	está na tela é a tela. Este service existe para o servidor poder **pedir**: o
	comando `highlight` do Cmdr entra por aqui, e é por aqui que um passo de
	tutorial decidido no servidor vai apontar um botão quando existir.

	O que atravessa a rede é um **caminho de nomes** (`"HUD.HUDLeft.Shop"`), e não
	uma referência: instância de UI do cliente não existe no servidor.

	Fica em `common/` porque o Cmdr roda nas duas places.
]]

local HighlightService = {
	Services = {}
}

--[[ API ]]

export type ShowOptions = {
	Padding : number?,
	Transparency : number?,
	BlockInput : boolean?,
}

--[=[
	Aponta, para cada jogador da lista, o GuiObject naquele caminho.
]=]
function HighlightService:Show(players : { Player }, path : string, options : ShowOptions?)
	for _, player in players do
		Framework:Fire("HighlightShow", player, path, options)
	end
end

--[=[
	Apaga o destaque. É o mesmo evento sem caminho — o cliente entende a ausência
	como "apague", e assim não existe um segundo evento para declarar e manter.
]=]
function HighlightService:Hide(players : { Player })
	for _, player in players do
		Framework:Fire("HighlightShow", player, false)
	end
end

--[[ CICLO DE VIDA ]]

function HighlightService:construct()
	-- O identificador do evento nasce no servidor: sem este `Listen` vazio, o
	-- `Listen` do cliente ficaria dez segundos esperando um evento que ninguém
	-- registrou — e levaria junto o resto do `construct` dele.
	Framework:Listen("HighlightShow", function() end)
end

function HighlightService:start()
end

function HighlightService:init()
	self:construct()
end

return HighlightService
