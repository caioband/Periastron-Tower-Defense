local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	O lado servidor da bancada de texto rico.

	A bancada em si é toda do cliente (`RichTextLabController`); o servidor existe
	aqui por causa da permissão: quem manda abrir é o comando `richtext` do Cmdr, e
	é o `BeforeRun` do `CmdrService` que decide se quem pediu pode. Bancada que o
	cliente abrisse por conta própria seria uma tela de dev na mão de qualquer
	jogador.

	Fica em `common/` porque o Cmdr roda nas duas places.
]]

local RichTextLabService = {
	Services = {}
}

--[[ API ]]

--[=[
	Abre a bancada para quem estiver na lista, ou fecha se já estiver aberta — o
	comando é o mesmo interruptor nos dois sentidos.
]=]
function RichTextLabService:Toggle(players : { Player })
	for _, player in players do
		Framework:Fire("RichTextLabToggle", player)
	end
end

--[[ CICLO DE VIDA ]]

function RichTextLabService:construct()
	-- O identificador do evento nasce no servidor: sem este `Listen` vazio, o
	-- `Listen` do cliente ficaria dez segundos esperando um evento que ninguém
	-- registrou — e levaria junto o resto do `construct` dele.
	Framework:Listen("RichTextLabToggle", function() end)
end

function RichTextLabService:start()
end

function RichTextLabService:init()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

return RichTextLabService
