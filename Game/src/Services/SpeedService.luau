local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared.Util.GameClock)

local Me = require(Vendor.Me)

local Framework = Me.new()

local SpeedConfig = SharedConfig.SpeedConfig

--[[
	A velocidade da partida, e ela e uma so para a sala inteira.

	O botao `Interface.Speed` e de todo mundo: quem clica acelera a partida dos
	outros junto. Nao ha por que ser diferente -- a simulacao (mob andando, torre
	atacando, wave nascendo) e do servidor, entao ou todos jogam acelerado ou
	ninguem joga. O que o cliente faz com o numero e desenhar a arte certa no
	botao e mover os modelos de mob no mesmo ritmo.

	**Como a velocidade chega no jogo.** Este service so guarda o degrau e ajusta
	o `GameClock` do servidor; nenhuma regra de gameplay olha para ele. Quem faz o
	jogo correr mais rapido e o relogio: `MobService`, `UnitService` e
	`WaveService` pedem o "agora" a ele em vez de `os.clock()`, e todas as
	duracoes encolhem sozinhas. Ver `Shared.Util.GameClock`.

	**O cliente pede, o servidor decide.** O clique manda o degrau desejado (e nao
	um "avanca um"): dois jogadores clicando no mesmo instante param os dois no
	2x, em vez de um empurrar o outro ate o 3x. O indice vem pela rede, entao
	passa pelo `SpeedConfig.IsValid` antes de valer.

	**Volta ao 1x a cada round.** O service esta na lista de round-scoped do
	`WaveService`: partida nova comeca na velocidade normal, e nao no 3x que
	alguem deixou ligado na anterior.
]]

-- Quanto tempo real um mesmo jogador espera entre dois cliques aceitos. Sem
-- isto, segurar o clique vira uma rajada de broadcast para a sala inteira.
local CLICK_COOLDOWN = 0.15

local SpeedService = {
	Services = {},

	-- O degrau em uso, indice de `SpeedConfig.Steps`.
	Index = SpeedConfig.DEFAULT_INDEX,

	-- [UserId] = os.clock() do ultimo clique aceito.
	LastClick = {},
}

--[[ INTERNAL ]]

--[=[
	Manda o degrau atual. Com `player`, so para ele (quem acabou de entrar ou de
	carregar a interface); sem, para a sala inteira.
]=]
function SpeedService:broadcast(player : Player?)
	if player then
		Framework:Fire("GameSpeedChanged", player, self.Index)
		return
	end

	for _, other in Players:GetPlayers() do
		Framework:Fire("GameSpeedChanged", other, self.Index)
	end
end

--[[ API ]]

function SpeedService:GetIndex() : number
	return self.Index
end

function SpeedService:GetScale() : number
	return SpeedConfig.GetScale(self.Index)
end

--[=[
	Troca o degrau da sala. Devolve `false` para pedido invalido ou para o degrau
	que ja esta valendo -- nesse caso nada e replicado.
]=]
function SpeedService:SetIndex(index : number) : boolean
	if not SpeedConfig.IsValid(index) then return false end
	if index == self.Index then return false end

	self.Index = index
	GameClock.SetScale(self:GetScale())

	self:broadcast()

	return true
end

--- Partida nova comeca no 1x, mesmo que a anterior tenha acabado acelerada.
function SpeedService:ResetRound()
	table.clear(self.LastClick)
	self:SetIndex(SpeedConfig.DEFAULT_INDEX)
end

--[[ CICLO DE VIDA ]]

function SpeedService:construct()
	GameClock.SetScale(self:GetScale())

	Framework:Listen("SetGameSpeed", function(player : Player, index : any)
		local now = os.clock()
		if now - (self.LastClick[player.UserId] or 0) < CLICK_COOLDOWN then return end
		self.LastClick[player.UserId] = now

		self:SetIndex(index)
	end)

	-- O controller pergunta ao ligar: quem entra no meio da partida ja pega o
	-- botao na velocidade em que a sala esta.
	Framework:Listen("RequestGameSpeed", function(player : Player)
		self:broadcast(player)
	end)

	Framework:Listen("GameSpeedChanged", function() end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.LastClick[player.UserId] = nil
	end)
end

function SpeedService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function SpeedService:init()
end

return SpeedService
