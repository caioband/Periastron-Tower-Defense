local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	O lado servidor da seta de indicação.

	A seta é toda do cliente (`ArrowController`): ela é enfeite, e enfeite que o
	servidor replicasse custaria rede a cada giro. O que atravessa é só a posição —
	um `Vector3`, que o Warp serializa —, e cada cliente monta a sua.

	Serve para o que o servidor sabe e o cliente não: onde está o mob que o tutorial
	quer apontar, qual tile a partida mandou destacar. O comando `arrow` do Cmdr
	entra pelo mesmo caminho.

	Fica em `common/` porque o modelo existe nas duas places.
]]

local ArrowService = {
	Services = {}
}

--[[ API ]]

export type PointOptions = {
	Height : number?,
	Spin : number?,
	Amplitude : number?,
	BobSpeed : number?,
	Scale : number?,
}

--[=[
	Aponta uma posição para cada jogador da lista. Uma seta por jogador: mandar de
	novo troca de lugar em vez de somar setas na tela.
]=]
function ArrowService:Point(players : { Player }, position : Vector3, options : PointOptions?)
	for _, player in players do
		Framework:Fire("ArrowPoint", player, position, options)
	end
end

--[=[
	Apaga a seta. É o mesmo evento sem posição — o cliente entende a ausência como
	"apague", e assim não existe um segundo identificador para declarar e manter.
]=]
function ArrowService:Clear(players : { Player })
	for _, player in players do
		Framework:Fire("ArrowPoint", player, false)
	end
end

--[[ CICLO DE VIDA ]]

function ArrowService:construct()
	-- O identificador do evento nasce no servidor: sem este `Listen` vazio, o
	-- `Listen` do cliente ficaria dez segundos esperando um evento que ninguém
	-- registrou — e levaria junto o resto do `construct` dele.
	Framework:Listen("ArrowPoint", function() end)
end

function ArrowService:start()
end

function ArrowService:init()
	self:construct()
end

return ArrowService
