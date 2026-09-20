local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared.Util.PathUtil)
local GameClock = require(Shared.Util.GameClock)

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local WaveConfig = ServerConfig.Wave
local GamepassConfig = SharedConfig.GamepassConfig
local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local TutorialConfig = SharedConfig.TutorialConfig

local Framework = Me.new()

local DataConfig = ServerConfig.Data

local INTERMISSION_TIME = 60
local WAVE_INTERVAL = 1.25
local SELECTION_TIME = 15

-- Respiro entre o ultimo voto de recomecar e o round de fato reiniciar, para o
-- contador cheio aparecer na tela antes dela sair.
local PLAY_AGAIN_DELAY = 1.5
local MAX_WAVES = DataConfig.MAX_WAVES
local BASE_WINNING_XP = DataConfig.BASE_WINNING_XP

-- Coins e shards de fim de partida sao o numero cheio de cada preset
-- (`WinCash`/`WinShards`), e nao uma base multiplicada -- so o XP continua assim.
local DifficultyConfig = ServerConfig.Difficulty

local PortalConfig = SharedConfig.PortalConfig

--[[
	Estados do round. `Finished` e o unico em que a votacao de recomecar aceita
	voto — antes disso o botao nem esta na tela.
]]
local ROUND_STATE = {
	Idle = "Idle",
	Running = "Running",
	Finished = "Finished",
}

-- Services que guardam estado de partida e sabem se limpar sozinhos. Cada um
-- expoe `ResetRound()`; quem entrar nessa lista passa a ser zerado junto.
local ROUND_SCOPED_SERVICES = { "MobService", "UnitService", "DifficultyService", "WeatherRoundService", "SpeedService", "CardShopService" }

local WaveService = {
	Services = {
		MobService = {},
		UnitService = {},
		DifficultyService = {},
		DataService = {},
		WeatherRoundService = {},
		SpeedService = {},
		CardShopService = {},
		TutorialMatchService = {}
	},
	Signals = {
		Ended = Signal.new(),

		--[[
			Disparado no comeco de cada wave, com o numero dela e o preset em uso.

			Quem escuta hoje e o `WeatherRoundService`, que joga o dado do clima e
			liga o que estava agendado. Fica como sinal e nao como chamada direta
			porque o round nao precisa saber que existe clima: se o service sumir, o
			`setWave` continua igual.
		]]
		WaveStarted = Signal.new(),

		--[[
			O round entrou em `Running` (`RoundStarted`) e saiu dele (`RoundClosed`),
			seja pelo fim da partida, seja por um `StopRound`/`ResetRound` no meio.

			Quem escuta e o `MatchStatsService`, que conta o tempo de cada jogador
			dentro da partida. `RoundClosed` so dispara para um round que estava
			rodando: o reset da tela de resultado (`Finished`) nao fecha nada.
		]]
		RoundStarted = Signal.new(),
		RoundClosed = Signal.new(),

		--[[
			(won : boolean, preset) -- a partida chegou ao fim de verdade: ultima wave
			vencida ou base no chao. Dispara depois das recompensas, com os jogadores que
			estavam na sala. Reset e saida nao disparam isto (so o `RoundClosed`).

			Quem escuta e o `ContractTrackerService`: a vitoria dos contratos e esta, com
			o mapa, a dificuldade e a vida da base de agora.
		]]
		MatchFinished = Signal.new(),
	},
	ReadyPlayers = {},
	PlayAgainVotes = {},

	-- Quanto cada jogador ja recebeu neste round, por UserId. Zerado a cada round.
	PaidRewards = {},
	GameOver = false,
	State = ROUND_STATE.Idle,

	-- Incrementado a cada Start/Stop. Todo ponto de espera do round confere se a
	-- geracao ainda e a dele; se nao for, aquele round foi descartado e a corotina
	-- se encerra sozinha. E o que torna o reset seguro em qualquer ponto, mesmo
	-- que o cancelamento da thread falhe.
	Generation = 0
}

function WaveService:setWave(waveCount : number)
	self.WaveCount = waveCount

	-- A composicao da wave e segredo de servidor; o cliente so precisa do "tem
	-- boss?" para trocar a musica junto com o comeco da wave.
	local preset = self.Difficulty or self.Services.DifficultyService:GetSelected()
	local hasBoss = WaveConfig.HasBoss(waveCount, preset and preset.Name)

	for _, Player in Players:GetPlayers() do
		Framework:Fire("SetWave", Player, self.WaveCount, hasBoss)
	end

	self.Signals.WaveStarted:Fire(self.WaveCount, preset, self:getMaxWaves(preset))
end

function WaveService:waitForAllPlayers()
	while true do
		local allReady = true
		for _, player in Players:GetPlayers() do
			if not player:HasTag("ClientReady") then
				allReady = false
			end
		end

		if allReady and #Players:GetPlayers() > 0 then
			break
		end
		task.wait(0.5)
	end
end

function WaveService:timeLeft()
	if not self.IntermissionEndsAt then return 0 end
	return math.max(0, math.ceil(self.IntermissionEndsAt - os.clock()))
end

function WaveService:allReady()
	local players = Players:GetPlayers()
	if #players == 0 then return false end
	for _, player in players do
		if not self.ReadyPlayers[player.UserId] then
			return false
		end
	end
	return true
end

function WaveService:broadcastReadyState(timeLeft)
	local readyCount = 0
	local total = 0
	for _, player in Players:GetPlayers() do
		total += 1
		if self.ReadyPlayers[player.UserId] then
			readyCount += 1
		end
	end
	for _, player in Players:GetPlayers() do
		Framework:Fire("WaveIntermission", player, {
			active = self.IntermissionActive == true,
			ready = readyCount,
			total = total,
			timeLeft = timeLeft,
			isReady = self.ReadyPlayers[player.UserId] == true,
		})
	end
end

function WaveService:runIntermission(duration)
	self.ReadyPlayers = {}
	self.IntermissionActive = true
	self.IntermissionEndsAt = os.clock() + duration

	self:broadcastReadyState(self:timeLeft())

	local lastShown = nil
	while os.clock() < self.IntermissionEndsAt do
		if self:allReady() then break end
		local remaining = self:timeLeft()
		if remaining ~= lastShown then
			lastShown = remaining
			self:broadcastReadyState(remaining)
		end
		task.wait(0.2)
	end

	self.IntermissionActive = false
	self.ReadyPlayers = {}
	self:broadcastReadyState(0)
end

--[=[
	Recompensa de fim de partida: coins, shards e XP de uma vez.

	Coins e XP sao lineares na fracao de waves sobrevividas. Shards nao: so
	entram depois de `SHARD_WAVE_THRESHOLD` e dai seguem uma curva, entao a moeda
	cara se concentra em quem chega perto do fim.
]=]
--[=[
	Quantas waves a partida tem. Cada dificuldade define a sua (`MaxWaves`);
	`DataConfig.MAX_WAVES` fica so como fallback para preset sem o campo.
]=]
--[=[
	Paga o premio de wave concluida a todos os jogadores da partida.

	E o unico dinheiro do jogo que nao depende do que o jogador fez: nao e por
	dano, nem por morte, nem de farm -- e por a wave ter acabado. Por isso sai
	igual para todo mundo, inclusive para quem entrou no meio da partida.

	Quem chama e o `runRound`, depois da checagem de game over: wave que terminou
	porque a base caiu nao paga.
]=]
function WaveService:payWaveCash()
	local amount = WaveConfig.GetWaveCash(self.WaveCount)
	if amount <= 0 then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	for _, player in Players:GetPlayers() do
		mobService:addCash(player, amount)
	end
end

function WaveService:getMaxWaves(preset)
	preset = preset or self.Difficulty
	return (preset and preset.MaxWaves) or MAX_WAVES
end

--[=[
	O premio de uma partida, pela fracao de waves sobrevividas.

	`lost` e o que separa a base ter caido de o jogador ter chegado ao fim:

	* **Derrota** (`true`): shard nenhum, e os coins saem multiplicados pelo
	  `LOSS_CASH_MULTIPLIER`. Perder na ultima wave nao pode pagar quase o mesmo que
	  vencer -- a run inteira e o produto, e nao o tempo em pe.
	* **Vitoria ou saida** (`false`/`nil`): a conta cheia. O `GrantLeaveReward` chama
	  sem o argumento de proposito: quem sai no meio de um round que ainda esta
	  rodando nao perdeu, a partida dele so nao terminou.
]=]
function WaveService:computeReward(preset, lost : boolean?)
	-- Sem preset (uma saida antes de a votacao terminar) o premio e o do padrao, que
	-- e o mesmo que os multiplicadores `or 1` davam quando a base era a do Medio.
	preset = preset or DifficultyConfig.Get(nil)

	local maxWaves = self:getMaxWaves(preset)
	local wavesSurvived = math.clamp(self.WaveCount or 0, 0, maxWaves)
	local progress = maxWaves > 0 and (wavesSurvived / maxWaves) or 0

	-- O premio da run completa e o do preset; quem sai antes leva a fracao de waves.
	local coins = (preset.WinCash or 0) * progress
	local xp = BASE_WINNING_XP * progress * (preset.WinXpMultiplier or 1)

	local shards = 0
	local threshold = DataConfig.SHARD_WAVE_THRESHOLD or 0
	if threshold < 1 and progress > threshold then
		local normalized = (progress - threshold) / (1 - threshold)
		shards = (preset.WinShards or 0) * (normalized ^ (DataConfig.SHARD_CURVE or 1))
	end

	if lost then
		coins *= (DataConfig.LOSS_CASH_MULTIPLIER or 1)

		-- Zerado depois da curva, e nao pulando a conta: a derrota nao muda **quando**
		-- os shards comecariam a cair, ela tira todos eles.
		shards = 0
	end

	return {
		coins = math.max(0, math.floor(coins + 0.5)),
		shards = math.max(0, math.floor(shards + 0.5)),
		xp = math.max(0, math.floor(xp + 0.5)),
	}
end

--[=[
	A recompensa **deste** jogador: a base da partida, ja multiplicada pelas gamepasses
	que o perfil dele declara (2x Coins, 1.5x Shards, o XP do VIP).

	A base e uma so para a sala inteira -- ela sai das waves sobrevividas e da
	dificuldade, que sao da partida e nao de ninguem. O que e de cada um e o
	multiplicador, e por isso ele entra aqui e nao no `computeReward`: duas pessoas na
	mesma run terminam com numeros diferentes sem que a run tenha duas contas.

	Perfil que nao carregou multiplica por 1: recompensa cheia do jogo base, nunca
	zero. E arredondado no fim, e nao antes -- multiplicar um numero ja arredondado
	perde o meio ponto duas vezes.
]=]
function WaveService:rewardsFor(player : Player, rewards)
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	local profile = entry and entry.Profile.Data or nil

	return {
		coins = math.floor(rewards.coins * GamepassConfig.coinMultiplier(profile) + 0.5),
		shards = math.floor(rewards.shards * GamepassConfig.shardMultiplier(profile) + 0.5),
		xp = math.floor(rewards.xp * GamepassConfig.xpMultiplier(profile) + 0.5),
	}
end

--[=[
	Credita a recompensa da partida no perfil do jogador, descontando o que ele ja
	recebeu neste round.

	O desconto e o que faz a recompensa de saida conviver com a de fim de round.
	Sem ele, dois casos quebram: quem sai no exato instante do fim seria pago pelo
	`onRoundEnded` e de novo pela saida, e quem sai na wave 19 e volta para o mesmo
	round levaria as duas recompensas cheias.

	Como a conta cresce com a wave e o que ja foi pago sai fora, o total de quem
	entra e sai no meio da partida nunca passa do que recebeu quem ficou o round
	inteiro. Devolve `false` quando nao ha nada a pagar.
]=]
function WaveService:grantReward(player : Player, rewards) : boolean
	local paid = self.PaidRewards[player.UserId]

	local coins = math.max(0, rewards.coins - (paid and paid.coins or 0))
	local shards = math.max(0, rewards.shards - (paid and paid.shards or 0))
	local xp = math.max(0, rewards.xp - (paid and paid.xp or 0))

	if coins <= 0 and shards <= 0 and xp <= 0 then return false end

	local dataService = self.Services.DataService
	if not dataService then return false end

	self.PaidRewards[player.UserId] = {
		coins = (paid and paid.coins or 0) + coins,
		shards = (paid and paid.shards or 0) + shards,
		xp = (paid and paid.xp or 0) + xp,
	}

	dataService:Update(player, "Stats", function(stats)
		stats.Cash = (stats.Cash or 0) + coins

		-- O total ganho, que nunca desce (a MOST COINS). Os ganhos de coins do jogo sao
		-- este e o resgate de contrato (`ContractService`); os outros `+=` no `Cash`
		-- sao estorno de compra e o Cmdr.
		stats.CoinsEarned = (tonumber(stats.CoinsEarned) or 0) + coins

		stats.Shards = (stats.Shards or 0) + shards
		stats.XP = (stats.XP or 0) + xp
		return stats
	end)

	return true
end

--[=[
	A recompensa de quem sai antes do fim -- por vontade propria ou porque o
	servidor esta desligando.

	E a mesma conta do fim de round (`computeReward`), que ja e proporcional as
	waves sobrevividas: quem sai na wave 18 de 20 leva quase tudo, quem sai na 2
	leva quase nada. Nada e disparado para o cliente: nao ha tela de resultado
	para quem esta indo embora.

	So enquanto o round esta rodando. Em `Finished` o `onRoundEnded` ja pagou todo
	mundo que estava na sala, e em `Idle` nao existe partida para pagar -- sair na
	votacao de dificuldade ou no intervalo nao vale recompensa nenhuma, e a conta
	devolveria zero de qualquer forma (wave 0).

	Quem chama e o `DataService`, com o perfil ainda aberto (ver `OnBeforeRelease`),
	e nao o `PlayerRemoving` daqui: e o que garante que o credito entra antes da
	sessao fechar nos dois caminhos de saida.
]=]
function WaveService:GrantLeaveReward(player : Player)
	if self.State ~= ROUND_STATE.Running then return end

	local preset = self.Difficulty or self.Services.DifficultyService:GetSelected()
	local rewards = self:rewardsFor(player, self:computeReward(preset))

	if self:grantReward(player, rewards) then
		print(string.format(
			"[WaveService]: %s saiu na wave %d/%d; recompensa proporcional paga (%d coins, %d shards, %d XP).",
			player.Name, self.WaveCount or 0, self:getMaxWaves(preset), rewards.coins, rewards.shards, rewards.xp))
	end
end

function WaveService:onRoundEnded(won : boolean)
	local preset = self.Difficulty or self.Services.DifficultyService:GetSelected()
	local maxWaves = self:getMaxWaves(preset)

	-- Aqui a partida acabou, entao "nao venceu" quer dizer derrota -- e nao "ainda
	-- esta rodando", que e o caso do `GrantLeaveReward`.
	local rewards = self:computeReward(preset, not won)
	local dataService = self.Services.DataService

	local mobService = self.Services.MobService
	local mvp = mobService and mobService:GetMVP() or nil

	for _, player in Players:GetPlayers() do
		-- Uma conta por jogador: a base e da partida, as gamepasses sao de cada um.
		-- E este numero -- o que ele de fato recebeu -- que vai para a tela dele.
		local playerRewards = self:rewardsFor(player, rewards)

		self:grantReward(player, playerRewards)

		if won then
			-- O tutorial vencido encerra o assunto no perfil. O `TutorialService` é
			-- comum às duas places, então quem escreve aqui é o mesmo que lê no lobby.
			local tutorialMatch = self.Services.TutorialMatchService
			if tutorialMatch and tutorialMatch:IsTutorial() then
				local tutorialService = Framework:Get("TutorialService", false, false)

				if tutorialService then
					tutorialService:Complete(player)
				end

				-- A vitoria tambem e o passo 10 do funil de onboarding, e e ela que diz
				-- ao `TutorialMatchService` que a saida deste jogador nao e abandono.
				tutorialMatch:NoteWon()

				local analytics = Framework:Get("AnalyticsService", false, false)

				if analytics then
					analytics:LogFunnelStep(player, "MatchWon")
				end
			end

			--[[
				A vitoria no perfil. E o unico lugar que escreve `Stats.Wins` -- a coluna
				"Wins" do leaderstats da Lobby le exatamente esta chave, e sem isto ela
				ficava parada no zero do template para sempre.

				Separado do `grantReward` de proposito: aquilo e proporcional as waves e
				tambem paga quem sai no meio; isto e binario e so vale para quem estava na
				sala quando a ultima wave caiu.
			]]
			if dataService then
				dataService:Update(player, "Stats", function(stats)
					stats.Wins = (stats.Wins or 0) + 1

					--[[
						A mesma vitoria contada de novo, agora com a dificuldade em que ela
						aconteceu -- e o que destrava as dificuldades de cima
						(`SharedConfig.DifficultyUnlockConfig`). O total acima nao serve para
						isso: ele nao sabe dizer se as vitorias sao do Easy ou do Impossible.

						A chave nasce aqui, na primeira vitoria naquela dificuldade, em vez de
						vir pronta do template -- a lista de presets e do config do servidor, e
						copia-la para dentro do perfil seria a mesma lista em dois lugares. Quem
						le trata chave ausente como zero.
					]]
					local difficultyWins = stats[UnlockConfig.WINS_KEY]
					if typeof(difficultyWins) ~= "table" then
						difficultyWins = {}
						stats[UnlockConfig.WINS_KEY] = difficultyWins
					end

					difficultyWins[preset.Name] = (difficultyWins[preset.Name] or 0) + 1

					return stats
				end)
			end

			Framework:Fire("Win", player)
		end

		Framework:Fire("RoundReward", player, {
			won = won,
			rewards = playerRewards,
			wavesSurvived = math.clamp(self.WaveCount or 0, 0, maxWaves),
			maxWaves = maxWaves,
			mvp = mvp,
		})
	end

	--[[
		O fecho do roteiro do tutorial: a tela de resultado é a última coisa que ele
		aponta, e o passo abre junto dela. Quem espera a tela terminar de se revelar
		para acender o holofote é o cliente — daqui não dá para saber em que ponto da
		animação ela está.

		Fora do tutorial não faz nada.
	]]
	local tutorial = self.Services.TutorialMatchService
	if tutorial then
		tutorial:BeginFinal()
	end

	self.Signals.MatchFinished:Fire(won, preset)
end

function WaveService:getArrowLeadTime()
	local cfg = SharedConfig.ArrowConfig

	-- A rota mais longa manda: as setas do lado mais comprido precisam chegar ao
	-- fim antes do primeiro mob nascer.
	local longest = 0
	for _, route in self.Services.MobService:getRoutes() do
		longest = math.max(longest, route.smooth.length)
	end

	local traversal = longest / cfg.Speed
	local lastArrowFinish = (cfg.Count - 1) * cfg.Stagger + traversal
	return lastArrowFinish + cfg.Buffer
end

--[[ ciclo de vida do round ]]

function WaveService:isCurrent(generation : number)
	return self.Generation == generation
end

--[=[
	Espera a wave terminar de um jeito que possa ser abortado.

	`Signal:Wait()` nao serve aqui: se a thread do round for cancelada enquanto
	espera, a conexao interna do sinal fica pendurada e o proximo `Fire` tenta
	acordar uma thread morta. Aqui a conexao e nossa, e `StopRound` a solta antes
	de cancelar a thread.

	Retorna false quando o round foi descartado durante a espera.
]=]
function WaveService:awaitWaveEnd(generation : number)
	local thread = coroutine.running()
	local finished = false
	local connection

	local function release()
		if finished then return end
		finished = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
		self.WaveAwaiter = nil
	end

	connection = self.Signals.Ended:Connect(function()
		if finished then return end
		release()
		task.spawn(thread)
	end)

	self.WaveAwaiter = release

	coroutine.yield()

	return self:isCurrent(generation)
end

function WaveService:runRound(generation : number)
	self:waitForAllPlayers()
	if not self:isCurrent(generation) then return end

	-- O tutorial não vota: a partida dele é desenhada para ser vencida, e escolher
	-- `Nightmare` nela seria escolher perder. Recebendo um preset do
	-- `TutorialMatchService`, a votação nem abre — e o cliente, que só mostra a tela
	-- quando o servidor a anuncia, não mostra nada.
	local tutorial = self.Services.TutorialMatchService
	local forced = tutorial and tutorial:GetForcedPreset()

	local preset = forced or self.Services.DifficultyService:RunSelection(SELECTION_TIME)
	if not self:isCurrent(generation) then return end
	self.Difficulty = preset

	-- Pular a votação não pode significar "ninguém decidiu nada": é o estado de
	-- dificuldade decidida que faz a hotbar aparecer na tela.
	if forced then
		self.Services.DifficultyService:Force(TutorialConfig.Match.Difficulty)
	end

	--[[
		O primeiro passo do tutorial acontece **aqui**, no intervalo, e não numa wave:
		ele aponta o botão de Ready e fecha quando a contagem termina — no tempo dela
		ou antes, se o jogador clicar. Ele abre antes da contagem de propósito, para a
		fala correr com o relógio ainda cheio.

		Fora do tutorial as duas chamadas não fazem nada.
	]]
	if tutorial then
		tutorial:BeginIntermission()
	end

	self:runIntermission(preset.IntermissionTime or INTERMISSION_TIME)
	if not self:isCurrent(generation) then return end

	if tutorial then
		tutorial:NoteIntermissionEnd()
	end

	local won = false
	while not self.GameOver do
		self:setWave((self.WaveCount or 0) + 1)

		-- O roteiro do tutorial abre **antes** de os mobs nascerem, e pode segurar a
		-- wave enquanto o passo não for cumprido (a wave 1 não nasce com o mapa
		-- vazio). Fora do tutorial as duas chamadas não fazem nada.
		if tutorial then
			tutorial:BeginStep(self.WaveCount)
			tutorial:AwaitStep(self.WaveCount)

			if not self:isCurrent(generation) then return end
		end

		--[[
			Tempo real de proposito, mesmo acelerado: esta espera existe para as setas do
			caminho terminarem de correr antes do primeiro mob nascer, e quem as
			desenha e o `WaveController`, que anima em tempo de tela. Encurtar so
			este lado poria o mob no mapa com a seta ainda no meio da rota.
		]]
		task.wait(self:getArrowLeadTime())
		if not self:isCurrent(generation) then return end

		-- Tempo real, como a espera das setas logo acima: e daqui que o `SkipService`
		-- conta os segundos ate oferecer a votacao de pular.
		self.WaveStartedAt = os.clock()
		self.Services.MobService:SpawnWave(self.WaveCount)

		if not self:awaitWaveEnd(generation) then return end
		if self.GameOver then break end

		-- Antes da checagem de vitoria de proposito: a ultima wave tambem e uma wave
		-- concluida, e ela paga como as outras.
		self:payWaveCash()

		if self.WaveCount >= self:getMaxWaves(preset) then
			won = true
			self.GameOver = true
			break
		end

		-- O respiro entre waves e ritmo de partida, entao encolhe junto com ela.
		GameClock.Wait(preset.WaveInterval or WAVE_INTERVAL)
		if not self:isCurrent(generation) then return end
	end

	self:onRoundEnded(won)
end

--[[ pular a wave ]]

--[=[
	Se a wave que esta no ar agora pode ser pulada.

	Sao quatro condicoes, e todas as quatro sao sobre o laco do round, nao sobre o
	jogador: o round tem que estar rodando, o laco tem que estar **esperando o fim
	de uma wave** (`WaveAwaiter`), a wave tem que ter acabado de nascer inteira
	(`AllMobsSpawned`) e tem que existir uma proxima wave.

	O `AllMobsSpawned` e o mais importante dos quatro: pular no meio de um spawn
	poria duas corotinas de `SpawnWave` no ar ao mesmo tempo, e a primeira a
	terminar diria que a wave inteira nasceu quando so uma delas nasceu.

	A ultima wave nao pula porque nao ha para onde: `WaveCount >= MaxWaves` e a
	condicao de vitoria logo abaixo do `awaitWaveEnd`, e adiantar isso seria
	entregar a partida com os inimigos ainda no caminho.
]=]
function WaveService:CanSkipWave() : boolean
	if self.State ~= ROUND_STATE.Running or self.GameOver then return false end
	if not self.WaveAwaiter then return false end
	if (self.WaveCount or 0) >= self:getMaxWaves() then return false end

	local mobService = self.Services.MobService

	return mobService ~= nil and mobService.AllMobsSpawned == true
end

--[=[
	Comeca a proxima wave sem esperar a atual acabar. Quem chama e o `SkipService`,
	quando a votacao fecha.

	E o mesmo `Ended` que o `MobService` dispara quando o ultimo mob morre: para o
	laco do round, a wave acabou, e ela paga como qualquer outra (o dinheiro de wave
	e a renda das farms). A diferenca esta no mapa, nao no codigo — os mobs que
	sobraram continuam andando, continuam pagando por dano e por morte, e continuam
	podendo derrubar a base. Pular e trocar espera por risco, e nao por desconto.

	Os dois `Ended` nao se atrapalham: enquanto a proxima wave nao chama
	`awaitWaveEnd` de novo ninguem esta escutando, e a partir dai o `MobService` so
	dispara quando **todos** os mobs vivos morrerem, os que sobraram inclusive.
]=]
function WaveService:SkipWave() : boolean
	if not self:CanSkipWave() then return false end

	print(string.format("[WaveService]: wave %d pulada por votacao.", self.WaveCount or 0))
	self.Signals.Ended:Fire()

	return true
end

--[=[
	Comeca um round do zero. Nao limpa nada — quem quer partida limpa chama
	`ResetRound()`, que zera os services e chama isto no fim.
]=]
function WaveService:StartRound()
	if self.State == ROUND_STATE.Running then
		warn("[WaveService]: StartRound ignorado, ja existe um round em andamento.")
		return false
	end

	self.Generation += 1
	local generation = self.Generation

	self.State = ROUND_STATE.Running
	self.GameOver = false
	self.WaveCount = 0
	table.clear(self.PaidRewards)

	self.Signals.RoundStarted:Fire()

	self.RoundThread = task.spawn(function()
		self:runRound(generation)

		-- So encerra se ninguem tiver comecado outro round no meio do caminho.
		if self:isCurrent(generation) then
			self.State = ROUND_STATE.Finished
			self.RoundThread = nil

			self.Signals.RoundClosed:Fire()

			-- A votacao de recomecar abre junto com a tela de resultado.
			self:broadcastPlayAgain()
		end
	end)

	return true
end

--[=[
	Aborta o que estiver acontecendo — votacao, intervalo, wave no meio — e deixa
	o servidor em Idle. Nao limpa mobs nem unidades; isso e `ResetRound`.
]=]
function WaveService:StopRound(reason : string?)
	local wasRunning = self.State == ROUND_STATE.Running

	-- Invalida a geracao antes de tudo: o que escapar do cancelamento encontra
	-- uma geracao diferente no proximo ponto de espera e se encerra sozinho.
	self.Generation += 1

	-- Um recomecar agendado nao pode sobreviver a um stop.
	self:cancelPlayAgainRestart()

	if self.WaveAwaiter then
		self.WaveAwaiter()
		self.WaveAwaiter = nil
	end

	-- Cancelar a propria thread mataria quem pediu o stop.
	if self.RoundThread and self.RoundThread ~= coroutine.running() then
		pcall(task.cancel, self.RoundThread)
	end
	self.RoundThread = nil

	self.State = ROUND_STATE.Idle
	self.IntermissionActive = false
	self.IntermissionEndsAt = nil
	self.GameOver = false
	table.clear(self.ReadyPlayers)

	if wasRunning then
		self.Signals.RoundClosed:Fire()
	end

	if reason then
		print(string.format("[WaveService]: round interrompido (%s).", reason))
	end
end

--- Se existe um round em `Running` agora (da espera pelos jogadores ate o fim).
function WaveService:IsRoundRunning() : boolean
	return self.State == ROUND_STATE.Running
end

--[=[
	Devolve a partida ao ponto zero. Pode ser chamado a qualquer momento — durante
	a votacao de dificuldade, no meio de uma wave, na tela de resultado — e de
	qualquer lugar do servidor:

		local Framework = require(ReplicatedStorage.Shared.Vendor.Me).new()
		Framework:Get("WaveService"):ResetRound()

	`autoStart = false` deixa o servidor parado em Idle esperando um
	`StartRound()`; qualquer outro valor recomeca na hora.
]=]
function WaveService:ResetRound(autoStart : boolean?)
	self:StopRound("reset")

	self.WaveCount = 0
	self.Difficulty = nil
	table.clear(self.ReadyPlayers)
	table.clear(self.PlayAgainVotes)
	table.clear(self.PaidRewards)

	for _, serviceName in ROUND_SCOPED_SERVICES do
		local service = self.Services[serviceName]
		if service and service.ResetRound then
			service:ResetRound()
		end
	end

	-- So `RoundRestarted`: disparar `SetWave` aqui faria o cliente tocar o som e as
	-- setas de uma "wave 0". Quem zera o contador e o proprio WaveController.
	for _, player in Players:GetPlayers() do
		Framework:Fire("RoundRestarted", player)
	end

	if autoStart ~= false then
		self:StartRound()
	end
end

--[[ votacao de recomecar ]]

function WaveService:playAgainTally()
	local voted = 0
	local total = 0

	for _, player in Players:GetPlayers() do
		total += 1
		if self.PlayAgainVotes[player.UserId] then
			voted += 1
		end
	end

	return voted, total
end

function WaveService:broadcastPlayAgain()
	local voted, total = self:playAgainTally()

	for _, player in Players:GetPlayers() do
		Framework:Fire("PlayAgainState", player, {
			votes = voted,
			total = total,
			voted = self.PlayAgainVotes[player.UserId] == true,
			active = self.State == ROUND_STATE.Finished,
		})
	end
end

function WaveService:cancelPlayAgainRestart()
	if self.PlayAgainRestart then
		pcall(task.cancel, self.PlayAgainRestart)
		self.PlayAgainRestart = nil
	end
end

--[=[
	Unanimidade entre quem esta no servidor. Quem sai deixa de contar, entao um
	jogador que abandona a tela de resultado nao trava o recomeco dos outros.

	Fechada a votacao, o reset espera PLAY_AGAIN_DELAY — tempo de o ultimo
	jogador ver o contador cheio antes da tela sair. A janela e cancelavel: quem
	tirar o voto (ou entrar no servidor) nesse intervalo derruba o agendamento, e
	a condicao e conferida de novo na hora de disparar.
]=]
function WaveService:evaluatePlayAgain()
	if self.State ~= ROUND_STATE.Finished then
		self:cancelPlayAgainRestart()
		return
	end

	local voted, total = self:playAgainTally()
	if total == 0 or voted < total then
		self:cancelPlayAgainRestart()
		return
	end

	if self.PlayAgainRestart then return end

	self.PlayAgainRestart = task.delay(PLAY_AGAIN_DELAY, function()
		-- Limpo primeiro: o ResetRound abaixo passa por StopRound, que cancelaria
		-- justamente esta thread se ela ainda estivesse registrada.
		self.PlayAgainRestart = nil

		if self.State ~= ROUND_STATE.Finished then return end

		local currentVoted, currentTotal = self:playAgainTally()
		if currentTotal == 0 or currentVoted < currentTotal then return end

		self:ResetRound()
	end)
end

--[[ saida para o lobby ]]

function WaveService:sendToLobby(player : Player)
	if not player or not player.Parent then return end

	-- O caixa da partida e volatil, mas o premio do round ja foi para o perfil:
	-- salvar antes de sair evita perder a ultima recompensa.
	local dataService = self.Services.DataService
	if dataService and dataService.Save then
		dataService:Save(player)
	end

	--[[
		A volta do tutorial leva um bilhete: `TutorialDone`.

		É com ele que o lobby sabe apontar a loja assim que o jogador cai lá — e é
		**só** um bilhete, nada é gravado no perfil. Empurrãozinho que acontece uma
		vez, logo depois da partida, e não um marco que sobrevive a um logout.
	]]
	local tutorialMatch = self.Services.TutorialMatchService
	local options = nil

	if tutorialMatch and tutorialMatch:IsTutorial() then
		options = Instance.new("TeleportOptions")
		options:SetTeleportData({ TutorialDone = true })
	end

	local success, err = pcall(function()
		TeleportService:TeleportAsync(PortalConfig.LOBBY_PLACE_ID, { player }, options)
	end)

	if not success then
		warn(string.format("[WaveService]: teleporte de %s para o lobby falhou (%s).", player.Name, tostring(err)))
		Framework:Fire("LobbyTeleportFailed", player)
	end
end

function WaveService:construct()
	Framework:Listen("ReadyWave", function(player)
		if not self.IntermissionActive then return end
		if self.ReadyPlayers[player.UserId] then
			self.ReadyPlayers[player.UserId] = nil
		else
			self.ReadyPlayers[player.UserId] = true
		end
		self:broadcastReadyState(self:timeLeft())
	end)

	Framework:Listen("VotePlayAgain", function(player)
		if self.State ~= ROUND_STATE.Finished then return end

		if self.PlayAgainVotes[player.UserId] then
			self.PlayAgainVotes[player.UserId] = nil
		else
			self.PlayAgainVotes[player.UserId] = true
		end

		self:broadcastPlayAgain()
		self:evaluatePlayAgain()
	end)

	Framework:Listen("RequestLobbyTeleport", function(player)
		self:sendToLobby(player)
	end)

	--[[
		A recompensa de saida nao entra aqui: ela precisa do perfil aberto, e a
		ordem entre este `PlayerRemoving` e o do `DataService` nao e garantida. Quem
		chama o `GrantLeaveReward` e o proprio `DataService`, logo antes de fechar a
		sessao -- o que cobre tambem o desligamento do servidor, onde `PlayerRemoving`
		nem sempre chega a disparar.
	]]
	local dataService = self.Services.DataService
	if dataService and dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player)
			self:GrantLeaveReward(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		self.PlayAgainVotes[player.UserId] = nil

		-- O que saiu podia ser o unico voto faltando.
		if self.State == ROUND_STATE.Finished then
			task.defer(function()
				self:broadcastPlayAgain()
				self:evaluatePlayAgain()
			end)
		end
	end)

	TeleportService.TeleportInitFailed:Connect(function(player, _result, message)
		warn(string.format("[WaveService]: TeleportInitFailed para %s (%s).", player.Name, tostring(message)))
		Framework:Fire("LobbyTeleportFailed", player)
	end)

	self:StartRound()
end

function WaveService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function WaveService:init()
	Framework:Listen("SetWave", function() end)
	Framework:Listen("WaveIntermission", function() end)
	Framework:Listen("Win", function() end)
	Framework:Listen("RoundReward", function() end)
	Framework:Listen("PlayAgainState", function() end)
	Framework:Listen("RoundRestarted", function() end)
	Framework:Listen("LobbyTeleportFailed", function() end)
end

return WaveService
