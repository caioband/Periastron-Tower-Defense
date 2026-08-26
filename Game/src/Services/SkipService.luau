local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local SkipConfig = SharedConfig.SkipConfig

--[=[
	A votacao de pular a wave.

	O prompt nao tem botao para abrir: ele aparece quando a partida trava. O
	criterio e o contato — nenhuma unidade encostou em nenhum mob por
	`SkipConfig.IdleTime` segundos. Quem marca o contato e o proprio `DamageMob` do
	`MobService` (`LastContact`), que e por onde passa todo dano do jogo; aqui so se
	le o relogio.

	Fechada a votacao, quem pula a wave e o `WaveService:SkipWave()`: a proxima
	comeca com os mobs da anterior ainda no caminho.

	**A votacao e do momento, e nao da wave.** Voltou a haver contato — um mob
	entrou no alcance de alguem, uma tripmine estourou —, o prompt sai da tela e os
	votos que estavam la sao descartados. O motivo de pular deixou de existir, e um
	voto dado ha meia wave nao pode fechar a votacao de agora.

	Cada abertura tem um `Token`. E ele que deixa o cliente esconder o prompt
	quando o jogador clica em Cancel sem esconder o proximo: um token novo e uma
	votacao nova, que aparece de novo para todo mundo.
]=]
local SkipService = {
	Services = {
		WaveService = {},
		MobService = {},
	},

	-- Votos da votacao aberta, por UserId. Zerados a cada abertura e a cada
	-- fechamento — ver o comentario acima.
	Votes = {},
	Active = false,
	Token = 0,
}

--[[ INTERNAL ]]

function SkipService:_tally() : (number, number, number)
	local voted = 0
	local total = 0

	for _, player in Players:GetPlayers() do
		total += 1
		if self.Votes[player.UserId] then
			voted += 1
		end
	end

	return voted, total, SkipConfig.RequiredVotes(total)
end

--[=[
	O estado da votacao para um jogador. `required` vai junto porque e ele que o
	contador da tela mostra: "1/3" e um voto dado de tres que faltam, e nao um de
	tres jogadores.
]=]
function SkipService:_sendTo(player : Player)
	local voted, total, required = self:_tally()

	Framework:Fire("SkipState", player, {
		active = self.Active,
		votes = voted,
		total = total,
		required = required,
		voted = self.Votes[player.UserId] == true,
		token = self.Token,
	})
end

function SkipService:_broadcast()
	for _, player in Players:GetPlayers() do
		self:_sendTo(player)
	end
end

function SkipService:_open()
	if self.Active then return end

	self.Active = true
	self.Token += 1
	table.clear(self.Votes)

	self:_broadcast()
end

function SkipService:_close()
	if not self.Active then return end

	self.Active = false
	table.clear(self.Votes)

	self:_broadcast()
end

--[=[
	Se a votacao deveria estar na tela agora: uma wave pulavel no ar e ninguem
	encostando em ninguem ha `IdleTime` segundos.
]=]
function SkipService:_shouldOffer() : boolean
	local waveService = self.Services.WaveService
	local mobService = self.Services.MobService

	if not waveService or not mobService then return false end
	if not waveService:CanSkipWave() then return false end

	return (os.clock() - (mobService.LastContact or 0)) >= SkipConfig.IdleTime
end

--[=[
	Conta os votos e pula a wave se der. Fecha a votacao nos dois casos: fechada
	com sucesso ela cumpriu o que tinha para fazer, e recusada pelo `SkipWave`
	(a wave acabou sozinha entre o voto e a contagem) ela perdeu o objeto.
]=]
function SkipService:_evaluate()
	if not self.Active then return end

	local waveService = self.Services.WaveService
	if not waveService then return end

	local voted, total, required = self:_tally()
	if total == 0 or voted < required then return end

	self:_close()
	waveService:SkipWave()
end

--[=[
	O laco que vigia a partida. Roda o round inteiro, e nao so quando ha wave: a
	condicao de abrir e a mesma que a de manter aberto, entao o prompt entra e sai
	sozinho conforme a partida trava e destrava.
]=]
function SkipService:_watch()
	task.spawn(function()
		while true do
			task.wait(SkipConfig.PollInterval)

			local shouldOffer = self:_shouldOffer()

			if self.Active and not shouldOffer then
				self:_close()
			elseif not self.Active and shouldOffer then
				self:_open()
			end
		end
	end)
end

--[[ CICLO DE VIDA ]]

function SkipService:construct()
	--[[
		`wants` e explicito em vez de alternar o voto: o prompt tem dois botoes, e o
		Cancel precisa poder tirar o voto de quem clicou em Confirm sem depender de
		o cliente saber em que estado ele estava.
	]]
	Framework:Listen("VoteSkip", function(player : Player, wants : boolean?)
		if not self.Active then return end

		local vote = if wants == false then nil else true
		if self.Votes[player.UserId] == vote then return end

		self.Votes[player.UserId] = vote

		self:_broadcast()
		self:_evaluate()
	end)

	--[[
		O cliente pede o estado quando termina de carregar a Interface. Sem isso,
		quem entra no meio de uma votacao aberta so a veria no proximo voto: o
		`SkipState` do `PlayerAdded` sai antes de o controller dele estar escutando.
	]]
	Framework:Listen("RequestSkipState", function(player : Player)
		self:_sendTo(player)
	end)

	--[[
		Quem entra muda quantos votos faltam para todo mundo, e quem sai tambem —
		inclusive podendo fechar a votacao ao sair, se era ele o voto que faltava.
	]]
	Players.PlayerAdded:Connect(function()
		self:_broadcast()
		self:_evaluate()
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.Votes[player.UserId] = nil

		task.defer(function()
			self:_broadcast()
			self:_evaluate()
		end)
	end)

	self:_watch()
end

function SkipService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function SkipService:init()
	-- So o que sai daqui para o cliente: `VoteSkip` e `RequestSkipState` ganham o
	-- remoto no `construct`, quando os escutamos de verdade.
	Framework:Listen("SkipState", function() end)
end

return SkipService
