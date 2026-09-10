local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared.Util.PathUtil)
local GameClock = require(Shared.Util.GameClock)

local WaveConfig = ServerConfig.Wave
local DifficultyConfig = ServerConfig.Difficulty

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local BASE_MAX_HEALTH = 100
local MOB_DAMAGE = 20

-- De quanto em quanto tempo se reprocura o node mais perto de um mob. O mesmo
-- valor esta no `TargetingController`: os dois lados tem que enxergar o mob no
-- mesmo trecho do caminho, senao a torre mira num e o dano vai para outro.
local NODE_PROGRESS_REFRESH = 0.1

local function computeTurnDistances(positions)
	local turnDistances = {}
	local total = 0

	for i = 2, #positions do
		total += (positions[i] - positions[i - 1]).Magnitude
		if i < #positions then
			table.insert(turnDistances, total)
		end
	end

	return turnDistances
end

--[=[
	Velocidade de um mob agora: a base do spawn, vezes o que os gimmicks dele
	acumularam, vezes o que o clima faz, vezes o que as cartas fazem.

	Os fatores sao guardados separados de proposito. O clima entra e sai no
	meio da wave, e um mob que ja ganhou 30% por curva tem que manter esse ganho
	quando o vento parar — o que so funciona se a conta for refeita a partir da
	base em vez de ir multiplicando o valor corrente.

	As cartas somam dois fatores pelo mesmo motivo, e sao dois porque as duas
	lentidoes tem donos diferentes: `CardSpeedScale` e da sala (o Staff of Azure
	Ever Ice, que pega todo mundo de uma vez) e `SlowScale` e do mob (a lentidao que
	uma unidade de gelo deixou naquele inimigo). Uma nao pode apagar a outra.
]=]
local function computeSpeed(self, mob)
	return mob.BaseSpeed
		* (mob.SpeedScale or 1)
		* (self.WeatherSpeedScale or 1)
		* (self.CardSpeedScale or 1)
		* (mob.SlowScale or 1)
end

local GimmickHandlers = {
	PerTurnSpeedMultiplier = {
		OnTurn = function(self, mobId, mob, gimmick)
			local stacks = mob.GimmickState[gimmick] or 0
			local maxStacks = gimmick.MaxStacks
			if not maxStacks or stacks < maxStacks then
				stacks += 1
				mob.GimmickState[gimmick] = stacks
			end

			mob.SpeedScale = math.max(0.1, 1 + (stacks * (gimmick.Amount or 0)))
			mob.CurrentSpeed = computeSpeed(self, mob)

			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
			end
		end,
	},

	HealthThresholdStunRandomUnit = {
		OnDamage = function(self, mobId, mob, gimmick)
			if gimmick.Once and mob.GimmickState[gimmick] then return end
			if mob.Health > mob.MaxHealth * (gimmick.Threshold or 0.5) then return end

			mob.GimmickState[gimmick] = true

			local freezeTime = gimmick.AnimTime or 0
			mob.StunnedUntil = math.max(mob.StunnedUntil or 0, GameClock.Now() + freezeTime)

			for _, player in Players:GetPlayers() do
				Framework:Fire("MobPlayAttack", player, mobId)
				Framework:Fire("UpdateMobSpeed", player, mobId, 0)
			end

			GameClock.Delay(freezeTime, function()
				if not self.ActiveMobs[mobId] then return end

				for _, player in Players:GetPlayers() do
					Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
				end

				local unitService = self.Services.UnitService
				if unitService then
					unitService:StunRandomUnit(gimmick.StunDuration or 0)
				end
			end)
		end,
	},
}

local MobService = {
	Services = {
		WaveService = {},
		UnitService = {},
		DataService = {},
		DifficultyService = {},
		WeatherService = {},
		CardModifierService = {},
	},
	ActiveMobs = {},
	DebugParts = {},
	PositionCache = {},

	-- Onde cada mob estava no comeco do quadro. Ver `getPreviousMobPosition`.
	PreviousPositionCache = {},

	FrameId = 0,
	BaseHealth = BASE_MAX_HEALTH,
	MaxBaseHealth = BASE_MAX_HEALTH,
	ActiveMobCount = 0,
	HealthScale = 1,

	-- Clima no ar e o que ele faz com a velocidade dos inimigos. A vida nao tem
	-- campo equivalente porque ela so vale no spawn — ver `SpawnWave`.
	Weather = nil,
	WeatherSpeedScale = 1,

	--[[
		O que as cartas de round estao fazendo com a sala inteira.

		`CardSpeedScale` e a lentidao global do Staff of Azure Ever Ice, e
		`BrittleMultiplier` e o "quebradico" que ele deixa quando e usado durante a
		neve: todo dano que entra num inimigo passa por ele.

		Os dois vivem no service, e nao no mob, porque valem para quem nascer no meio
		da janela tambem -- a mesma razao do `FreezeUntil` la embaixo.
	]]
	CardSpeedScale = 1,
	CardSlowToken = 0,
	BrittleMultiplier = 1,
	BrittleToken = 0,
	SessionCash = {},
	SessionDamage = {},

	--[[
		`os.clock()` da ultima vez que uma unidade encostou num mob. Quem le e o
		`SkipService`: cinco segundos sem isso mudar e a partida travou, e o prompt
		de pular a wave entra na tela.

		Tempo real de proposito, e nao `GameClock`: o que ele mede e a paciencia de
		quem esta olhando, e nao o ritmo da partida.
	]]
	LastContact = 0,

	--[[
		Ate quando o Time Stop segura todo mundo, no relogio da partida, e o token
		do congelamento que esta valendo. Nil fora de um congelamento. Ver
		`FreezeAll`.
	]]
	FreezeUntil = nil,
	FreezeToken = 0,

	-- A sobra fracionaria do bonus da aura, por jogador. Ver `applyCashBonus`.
	BonusRemainder = {},
}

--[=[
	Liga (ou desliga, com nil) os efeitos do clima sobre os inimigos.

	Quem chama e o `WeatherRoundService`, no comeco da wave em que o clima entra ou
	sai. A velocidade e recalculada para todos os mobs que ja estao andando e
	replicada na hora — sem isso, quem nasceu antes do vento continuaria no ritmo
	antigo ate o fim do caminho, e dois mobs iguais andariam em velocidades
	diferentes na mesma wave.

	A vida nao e mexida aqui de proposito: mudar `MaxHealth` no meio da caminhada
	significaria ou curar o mob ou mata-lo na hora, e as duas coisas sao piores do
	que a wave seguinte ja nascer com o valor certo.
]=]
function MobService:ApplyWeather(weatherName : string?)
	self.Weather = weatherName
	self.WeatherSpeedScale = SharedConfig.WeatherConfig.GetMobMultiplier(weatherName, "Speed")

	for mobId, mob in self.ActiveMobs do
		local speed = computeSpeed(self, mob)
		if speed ~= mob.CurrentSpeed then
			mob.CurrentSpeed = speed
			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, speed)
			end
		end
	end
end

function MobService:GetWeather() : string?
	return self.Weather
end

--[=[
	Para todos os inimigos do mapa por `duration`. Quem chama e o `CardShopService`
	(carta Time Stop).

	O congelamento e o mesmo `StunnedUntil` que o gimmick do boss ja usava: o laco
	do Heartbeat so soma distancia quando o relogio da partida passa dele. Isso
	significa que o tempo do congelamento e **de partida**, e nao de tela -- quatro
	segundos no 2x sao dois segundos reais, do mesmo jeito que todo o resto do
	gameplay. E o unico jeito de o congelamento valer o mesmo tanto de caminho
	andado em qualquer velocidade.

	`FreezeUntil` fica guardado no service porque a wave pode continuar nascendo
	durante o congelamento: mob que nasce dentro da janela ja nasce parado, em vez
	de o Time Stop virar "para quem ja estava no mapa".

	O `UpdateMobSpeed` para zero e o outro lado da mesma coisa: quem move o modelo
	na tela e o `MobController`, e sem isso o boneco continuaria andando ate o
	servidor entregar a posicao de volta.
]=]
function MobService:FreezeAll(duration : number?) : number
	duration = math.max(0, duration or 0)
	if duration <= 0 then return 0 end

	self.FreezeUntil = math.max(self.FreezeUntil or 0, GameClock.Now() + duration)

	local frozen = 0
	for mobId, mob in self.ActiveMobs do
		mob.StunnedUntil = math.max(mob.StunnedUntil or 0, self.FreezeUntil)
		frozen += 1

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, 0)
		end
	end

	--[[
		Um token por congelamento. Dois Time Stops sobrepostos estendem a janela
		(`FreezeUntil` e um max), e ai so o ultimo degelo pode valer: sem isso o
		primeiro terminaria no meio do segundo e devolveria a velocidade dos mobs
		com a janela ainda aberta.
	]]
	self.FreezeToken = (self.FreezeToken or 0) + 1
	local token = self.FreezeToken

	GameClock.Delay(self.FreezeUntil - GameClock.Now(), function()
		if self.FreezeToken ~= token then return end

		self.FreezeUntil = nil

		for mobId, mob in self.ActiveMobs do
			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
			end
		end
	end)

	return frozen
end

--[[ O QUE AS CARTAS FAZEM COM OS INIMIGOS ]]

--[=[
	O multiplicador global de uma estatistica de carta (`Slow`, `Burn`).

	Atalho para nao espalhar o `CardModifier` por aqui: o que interessa a este
	service e um numero, e nao a gramatica que o produziu.
]=]
function MobService:cardStat(stat : string) : number
	local service = self.Services.CardModifierService

	return service and service:GetGlobal(stat) or 1
end

--[=[
	Manda a velocidade de agora de todo mundo para os clientes.

	Quem move o boneco na tela e o `MobController`, com a velocidade que o servidor
	mandou por ultimo: sem isso o mob continuaria andando no ritmo antigo ate a
	proxima vez que alguma outra coisa mexesse nele.

	Mob congelado fica de fora: para ele o cliente ja recebeu zero, e mandar a
	velocidade "de verdade" no meio de um Time Stop o poria a andar.
]=]
function MobService:_broadcastSpeeds()
	local now = GameClock.Now()

	for mobId, mob in self.ActiveMobs do
		local speed = computeSpeed(self, mob)
		mob.CurrentSpeed = speed

		if (mob.StunnedUntil or 0) > now then continue end

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, speed)
		end
	end
end

--[=[
	Esfria a sala inteira: todo inimigo anda `slow` mais devagar por `duration`, e
	com `brittle` todo dano que entrar neles no periodo vale mais. E o Staff of
	Azure Ever Ice.

	`slow` e a **fracao tirada**: 0.5 e "anda pela metade", 0.75 e "anda a um
	quarto". Escrito assim porque e assim que a carta se descreve para o jogador, e
	traduzir para escala num lugar so evita a confusao de ler "0.25" e achar que a
	carta e fraca.

	Vale para quem nascer no meio da janela tambem -- a escala mora no service e
	entra no `computeSpeed` de todo mundo, como o clima.

	Duas cartas sobrepostas: a **mais forte** manda, e o prazo e o token de quem
	entrou por ultimo. Multiplicar as duas faria um segundo uso durante o primeiro
	parar a sala inteira, que nao e o que nenhuma das duas prometeu.
]=]
function MobService:ChillAll(slow : number?, duration : number?, brittle : number?) : number
	duration = math.max(0, duration or 0)
	if duration <= 0 then return 0 end

	local scale = 1 - math.clamp(slow or 0, 0, 0.95)

	if scale < (self.CardSpeedScale or 1) then
		self.CardSpeedScale = scale
	end

	self.CardSlowToken = (self.CardSlowToken or 0) + 1
	local slowToken = self.CardSlowToken

	self:_broadcastSpeeds()

	--[[
		Tempo de partida, e nao real: os dez segundos da carta sao dez segundos de
		jogo, do mesmo jeito que o Time Stop e o atordoamento. No 3x eles passam em
		pouco mais de tres segundos de relogio de parede, e e isso que faz a carta
		valer o mesmo tanto de caminho andado em qualquer velocidade.
	]]
	GameClock.Delay(duration, function()
		if self.CardSlowToken ~= slowToken then return end

		self.CardSpeedScale = 1
		self:_broadcastSpeeds()
	end)

	if brittle and brittle > 1 then
		self.BrittleMultiplier = math.max(self.BrittleMultiplier or 1, brittle)

		self.BrittleToken = (self.BrittleToken or 0) + 1
		local brittleToken = self.BrittleToken

		GameClock.Delay(duration, function()
			if self.BrittleToken ~= brittleToken then return end

			self.BrittleMultiplier = 1
		end)
	end

	return self.ActiveMobCount
end

--[=[
	A lentidao que uma unidade deixa num inimigo so.

	`amount` e a fracao tirada, como no `ChillAll`, e a carta Chill Out entra por
	cima dela: `Slow` e um multiplicador global, entao 0.2 com a carta no campo vira
	0.22. O teto de 0.95 existe para nenhuma soma de cartas parar um inimigo de vez
	-- parar inimigo e o Time Stop, e ele custa outra carta.

	A **mais forte manda**, e nao a mais recente: um respingo fraco no meio de uma
	lentidao forte nao pode encurtar a forte. O prazo, esse sim, e sempre do ultimo
	golpe, senao lentidoes iguais em sequencia nunca renovariam.

	> ⚠️ Nenhuma unidade de hoje deixa lentidao: e `UnitStats[nome].Slow` que liga
	> isto, e o roster ainda nao tem uma unidade `Ice` -- o Electro para o inimigo
	> (`StunMob`) em vez de o atrasar. A mecanica existe para a carta Chill Out ter o
	> que multiplicar no dia em que uma existir.
]=]
function MobService:ApplySlow(mobId : string, amount : number?, duration : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	duration = math.max(0, duration or 0)
	if duration <= 0 then return end

	local effective = math.clamp((amount or 0) * self:cardStat("Slow"), 0, 0.95)
	if effective <= 0 then return end

	local scale = 1 - effective
	if scale < (mob.SlowScale or 1) then
		mob.SlowScale = scale
	end

	mob.SlowToken = (mob.SlowToken or 0) + 1
	local token = mob.SlowToken

	mob.CurrentSpeed = computeSpeed(self, mob)

	if (mob.StunnedUntil or 0) <= GameClock.Now() then
		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
		end
	end

	GameClock.Delay(duration, function()
		-- O mob pode ter morrido, e a tabela dele ja nao esta em lugar nenhum.
		if self.ActiveMobs[mobId] ~= mob or mob.SlowToken ~= token then return end

		mob.SlowScale = 1
		mob.CurrentSpeed = computeSpeed(self, mob)

		if (mob.StunnedUntil or 0) <= GameClock.Now() then
			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
			end
		end
	end)
end

--[=[
	Para um inimigo de vez, por `duration` segundos de partida.

	E o mesmo `StunnedUntil` do Time Stop e do gimmick do boss -- o laco de movimento
	so anda com `now >= StunnedUntil` --, so que num inimigo so. Nao e lentidao: a
	lentidao mexe na velocidade, e isto tira o mob do laco. Uma unidade pode deixar as
	duas no mesmo golpe, embora nenhuma deixe hoje: o Electro so para.

	**O prazo maior manda, e o mais curto nao encosta nele.** Um choque de 0,3s no meio
	de um Time Stop de 5s nao pode devolver o inimigo ao caminho quando os 0,3s
	acabarem -- por isso a saida antecipada la em cima e a conferencia do prazo na hora
	de soltar. Renovar um choque que ainda esta correndo so estende o prazo.

	O `UpdateMobSpeed` para zero e o outro lado disto: quem move o boneco na tela e o
	`MobController`, e sem o aviso ele continuaria andando ate o servidor mandar a
	posicao de volta.
]=]
function MobService:StunMob(mobId : string, duration : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	duration = math.max(0, duration or 0)
	if duration <= 0 then return end

	local stunnedUntil = GameClock.Now() + duration

	-- Ja esta parado por mais tempo do que este choque pediria: nao ha o que fazer,
	-- e mexer aqui seria encurtar o congelamento de quem chegou antes.
	if stunnedUntil <= (mob.StunnedUntil or 0) then return end

	mob.StunnedUntil = stunnedUntil

	for _, player in Players:GetPlayers() do
		Framework:Fire("UpdateMobSpeed", player, mobId, 0)
	end

	GameClock.Delay(duration, function()
		-- Morreu, ou a tabela dele ja e de outro mob com o mesmo id.
		if self.ActiveMobs[mobId] ~= mob then return end

		-- Um congelamento mais longo assumiu no meio deste: quem solta o mob e ele.
		if GameClock.Now() < (mob.StunnedUntil or 0) then return end

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
		end
	end)
end

--[=[
	Poe fogo num inimigo: `damage` de dano a cada `interval` segundos, `ticks`
	vezes.

	Cada tique passa pelo `DamageMob` como qualquer outro dano -- ele paga caixa,
	conta para o placar da unidade e mata se der. A carta Fire Hazard entra em cada
	tique, e nao no total: uma queimadura que ja esta no ar cobra mais assim que a
	carta e usada, em vez de esperar a proxima.

	Renovar substitui em vez de empilhar: dois golpes de fogo no mesmo inimigo sao
	uma queimadura com o prazo recomecado, e nao duas correndo em paralelo. Empilhar
	faria uma unidade de fogo rapida multiplicar o proprio DPS pelo numero de golpes
	que couberem na duracao.

	> ⚠️ Como a lentidao acima, nenhuma unidade de hoje queima: e
	> `UnitStats[nome].Burn` que liga isto, e o roster ainda nao tem uma unidade
	> `Fire`.
]=]
function MobService:ApplyBurn(mobId : string, damage : number?, ticks : number?, interval : number?, ownerUserId : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	damage = damage or 0
	ticks = math.floor(ticks or 0)
	interval = interval or 1

	if damage <= 0 or ticks <= 0 or interval <= 0 then return end

	mob.BurnToken = (mob.BurnToken or 0) + 1
	local token = mob.BurnToken

	task.spawn(function()
		for _ = 1, ticks do
			GameClock.Wait(interval)

			if self.ActiveMobs[mobId] ~= mob or mob.BurnToken ~= token then return end

			local tick = math.max(1, math.floor(damage * self:cardStat("Burn") + 0.5))
			self:DamageMob(mobId, tick, ownerUserId)
		end
	end)
end

--[=[
	Todas as rotas do mapa atual, com as distancias de curva ja calculadas.

	Mapa sem bifurcacao devolve uma rota so, e tudo que consome isso continua
	igual. Com bifurcacao, cada combinacao vira uma rota linear propria — o mob
	sorteia um indice no spawn e carrega ele pelo resto da vida.
]=]
function MobService:getRoutes()
	if not self.Routes then
		local routes = PathUtil.BuildRoutes(workspace.PathScriptable.Nodes)
		for _, route in routes do
			route.turnDistances = computeTurnDistances(route.positions)
		end
		self.Routes = routes
	end
	return self.Routes
end

--[=[
	Os nodes do caminho com a distancia de cada um ate o primeiro, para a
	prioridade `Farthest`. Cai junto com as rotas quando o mapa muda.
]=]
function MobService:getNodeDistances()
	if not self.NodeDistances then
		self.NodeDistances = PathUtil.BuildNodeDistances(self:getRoutes())
	end
	return self.NodeDistances
end

--[=[
	O quanto o mob ja andou do caminho, em cache.

	A varredura de nodes e barata, mas ela roda por unidade e por mob: numa wave
	grande com muitas torres no `Farthest` isso vira o produto dos dois. Como o
	mob nao muda de node a cada quadro, a conta vale por `NODE_PROGRESS_REFRESH`.
]=]
function MobService:getMobPathProgress(mob, position : Vector3, nodeDistances)
	local now = GameClock.Now()

	if mob.NodeProgress and now - (mob.NodeProgressClock or 0) < NODE_PROGRESS_REFRESH then
		return mob.NodeProgress
	end

	mob.NodeProgress = PathUtil.GetNodeProgress(nodeDistances, position)
	mob.NodeProgressClock = now

	return mob.NodeProgress
end

function MobService:getSmoothPath(routeIndex : number?)
	local routes = self:getRoutes()
	local route = routes[routeIndex or 1] or routes[1]
	return route.smooth
end

function MobService:getDifficulty()
	local difficultyService = self.Services.DifficultyService
	if difficultyService and difficultyService.GetSelected then
		return difficultyService:GetSelected()
	end

	return DifficultyConfig.Get()
end

function MobService:ApplyDifficulty(preset)
	self.MaxBaseHealth = preset.BaseHealth or BASE_MAX_HEALTH
	self.BaseHealth = self.MaxBaseHealth
	self:broadcastBaseHealth()

	-- A partida comeca aqui: zera o placar de dano que decide o MVP.
	table.clear(self.SessionDamage)

	for _, player in Players:GetPlayers() do
		self.SessionCash[player.UserId] = player.Name == "raixyzdev" and 1000000 or preset.StartingCash
		Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
	end
end

function MobService:initPlayerCash(player)
	local startingCash = player.Name == "raixyzdev" and 1000000 or self:getDifficulty().StartingCash
	self.SessionCash[player.UserId] = startingCash
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
end

function MobService:getCash(player)
	return self.SessionCash[player.UserId] or 0
end

function MobService:addCash(player, amount)
	if not player or not player.Parent then return end
	self.SessionCash[player.UserId] = (self.SessionCash[player.UserId] or 0) + amount
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
end

function MobService:spendCash(player, amount)
	if not player or not player.Parent then return end
	self.SessionCash[player.UserId] = math.max(0, (self.SessionCash[player.UserId] or 0) - amount)
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
end

function MobService:broadcastBaseHealth()
	for _, player in Players:GetPlayers() do
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
	end
end

function MobService:removeMob(mobId)
	if not self.ActiveMobs[mobId] then return end
	self.ActiveMobs[mobId] = nil
	self.PositionCache[mobId] = nil
	self.PreviousPositionCache[mobId] = nil
	self.ActiveMobCount = math.max(0, self.ActiveMobCount - 1)

	for _, player in Players:GetPlayers() do
		Framework:Fire("KillClientMob", player, mobId)
	end

	if self.ActiveMobCount == 0 and self.AllMobsSpawned then
		self.Services.WaveService.Signals.Ended:Fire()
	end
end

function MobService:mobEscaped(mobId)
	if not self.ActiveMobs[mobId] then return end

	self.BaseHealth = math.max(0, self.BaseHealth - (self:getDifficulty().MobDamage or MOB_DAMAGE))
	self:broadcastBaseHealth()

	if self.BaseHealth <= 0 then
		self:onGameOver()
		return
	end

	self:removeMob(mobId)
end

function MobService:onGameOver()
	for mobId, _ in self.ActiveMobs do
		for _, player in Players:GetPlayers() do
			Framework:Fire("KillClientMob", player, mobId)
		end
	end
	table.clear(self.ActiveMobs)
	table.clear(self.PositionCache)
	table.clear(self.PreviousPositionCache)
	self.ActiveMobCount = 0
	self.AllMobsSpawned = false

	for _, player in Players:GetPlayers() do
		Framework:Fire("GameOver", player)
	end

	self.BaseHealth = self.MaxBaseHealth
	self:broadcastBaseHealth()

	local waveService = self.Services.WaveService
	if waveService then
		waveService.GameOver = true
		waveService.Signals.Ended:Fire()
	end
end

--[=[
	Devolve o service ao estado de antes da partida. Chamado pelo WaveService em
	`ResetRound()`; nao mexe em nada que seja de outro service.

	Diferente de `onGameOver`, aqui nao ha aviso de fim de jogo: os mobs somem dos
	clientes e o placar de dano zera, sem disparar `GameOver`.
]=]
function MobService:ResetRound()
	for mobId, _ in self.ActiveMobs do
		for _, player in Players:GetPlayers() do
			Framework:Fire("KillClientMob", player, mobId)
		end
	end

	table.clear(self.ActiveMobs)
	table.clear(self.PositionCache)
	table.clear(self.PreviousPositionCache)
	table.clear(self.SessionDamage)
	table.clear(self.BonusRemainder)
	self.ActiveMobCount = 0
	self.AllMobsSpawned = false
	self.LastContact = os.clock()

	-- Um Time Stop do round anterior nao pode congelar a primeira wave do proximo.
	-- O `FreezeToken` sobe para o degelo agendado nao mexer mais em nada.
	self.FreezeUntil = nil
	self.FreezeToken = (self.FreezeToken or 0) + 1

	-- E o mesmo para as cartas: a lentidao e o quebradico do Azure Ever Ice sao de
	-- partida, e os tokens sobem para o fim agendado de cada um nao acordar depois.
	self.CardSpeedScale = 1
	self.CardSlowToken = (self.CardSlowToken or 0) + 1
	self.BrittleMultiplier = 1
	self.BrittleToken = (self.BrittleToken or 0) + 1

	-- As rotas sao reconstruidas no proximo SpawnWave; largar o cache evita
	-- carregar geometria velha caso o mapa mude entre rounds.
	self.Routes = nil
	self.NodeDistances = nil

	self.BaseHealth = self.MaxBaseHealth
	self:broadcastBaseHealth()

	for _, player in Players:GetPlayers() do
		self:initPlayerCash(player)
	end
end

function MobService:PredictPosition(mobId)
	local mob = self.ActiveMobs[mobId]
	if not mob then return nil end

	return PathUtil.GetPositionAtDistance(self:getSmoothPath(mob.RouteIndex), mob.Distance)
end

--[=[
	Onde o mob estava no comeco deste quadro.

	Cacheado por quadro pelo mesmo motivo do `getMobPosition`: quem pergunta e o
	gatilho das tripmines, uma vez por mina, e sem cache a conta viraria o produto
	de minas por mobs.

	Sem `LastDistance` (o mob nasceu neste quadro), a resposta e a posicao de agora
	-- ele nao andou nada ainda, entao o "segmento" dele e um ponto.
]=]
function MobService:getPreviousMobPosition(mobId)
	local cached = self.PreviousPositionCache[mobId]
	if cached and cached.frame == self.FrameId then
		return cached.pos
	end

	local mob = self.ActiveMobs[mobId]
	if not mob then return nil end

	local pos = if mob.LastDistance
		then PathUtil.GetPositionAtDistance(self:getSmoothPath(mob.RouteIndex), mob.LastDistance)
		else self:getMobPosition(mobId)

	self.PreviousPositionCache[mobId] = { frame = self.FrameId, pos = pos }

	return pos
end

--[=[
	A menor distancia de `point` ate o segmento `a`-`b`. So o plano XZ interessa:
	tudo aqui anda no chao, e a mina fica 0.35 stud acima dele.
]=]
local function distanceToSegment(point : Vector3, a : Vector3, b : Vector3) : number
	local flatPoint = Vector3.new(point.X, 0, point.Z)
	local flatA = Vector3.new(a.X, 0, a.Z)
	local segment = Vector3.new(b.X - a.X, 0, b.Z - a.Z)

	local lengthSquared = segment:Dot(segment)
	if lengthSquared < 1e-6 then
		return (flatPoint - flatA).Magnitude
	end

	local t = math.clamp((flatPoint - flatA):Dot(segment) / lengthSquared, 0, 1)

	return (flatPoint - (flatA + segment * t)).Magnitude
end

--[=[
	Um mob cujo **caminho percorrido neste quadro** passou a menos de `radius` de
	`position`, ou nil. Qual deles nao importa: quem pergunta e o gatilho da
	tripmine, que so quer saber se alguem cruzou.

	E diferente de perguntar quem esta perto agora, e a diferenca so aparece rapido:
	um mob anda `CurrentSpeed * dt` por quadro, e nesse pulo ele pode entrar e sair
	do raio sem nunca ser visto parado dentro dele. Com o jogo em 3x e o servidor a
	30Hz, o inimigo mais rapido do Nightmare da passos de quase 6 studs -- mais que
	o diametro do gatilho de uma tripmine, que ele entao atravessa intacto.

	Testar o segmento em vez do ponto tira o quadro da conta: a mina explode pela
	**distancia**, e nao pela sorte de o quadro ter caido em cima dela.

	Devolve o primeiro que servir, sem montar lista: isto roda uma vez por mina por
	quadro, e uma tabela por chamada seria lixo a coletar em cada um deles.
]=]
function MobService:GetMobCrossing(position : Vector3, radius : number) : string?
	for mobId, _ in self.ActiveMobs do
		local current = self:getMobPosition(mobId)
		if not current then continue end

		local previous = self:getPreviousMobPosition(mobId) or current

		if distanceToSegment(position, previous, current) <= radius then
			return mobId
		end
	end

	return nil
end

function MobService:processTurnGimmicks(mobId, mob)
	local turnDistances = mob.TurnDistances
	if not turnDistances then return end

	while mob.NextTurnIndex <= #turnDistances and mob.Distance >= turnDistances[mob.NextTurnIndex] do
		for _, gimmick in mob.Gimmicks do
			local handler = GimmickHandlers[gimmick.Type]
			if handler and handler.OnTurn then
				handler.OnTurn(self, mobId, mob, gimmick)
			end
		end
		mob.NextTurnIndex += 1
	end
end

function MobService:processDamageGimmicks(mobId, mob)
	for _, gimmick in mob.Gimmicks do
		local handler = GimmickHandlers[gimmick.Type]
		if handler and handler.OnDamage then
			handler.OnDamage(self, mobId, mob, gimmick)
		end
	end
end

function MobService:SpawnWave(waveNumber)
	local mobConfig = SharedConfig.Mob
	local preset = self:getDifficulty()
	local spawnList = WaveConfig.GetSpawns(waveNumber, preset.Name)
	local healthScale = preset.HealthMultiplier * (preset.HealthGrowth ^ (waveNumber - 1))

	--[[
		A vida do clima entra na mesma escala da dificuldade, e por isso tambem
		desconta no premio por dano (ver `awardDamageReward`): sem isso a seca faria
		bater no inimigo pagar 40% a mais, e o clima que era para apertar viraria
		bonus de economia.

		Lido uma vez, no comeco da wave: o clima que valeu para o primeiro mob vale
		para todos os da wave, mesmo que ele saia no meio da caminhada.
	]]
	healthScale *= SharedConfig.WeatherConfig.GetMobMultiplier(self.Weather, "Health")

	-- Guardado porque o premio em caixa por dano desconta esta mesma escala.
	self.HealthScale = healthScale

	--[[
		Velocidade tambem sobe com a wave, mas com teto: sem o `SpeedGrowthCap` um
		preset longo acabaria com mobs rapidos demais para as torres acompanharem, e
		os gimmicks que ja multiplicam velocidade (o Wall Smasher ganha 30% por
		curva) entrariam por cima disso.
	]]
	local speedScale = math.min(
		preset.SpeedMultiplier * (preset.SpeedGrowth ^ (waveNumber - 1)),
		preset.SpeedMultiplier * (preset.SpeedGrowthCap or math.huge)
	)

	self.Routes = nil
	self.NodeDistances = nil
	local routes = self:getRoutes()

	self.AllMobsSpawned = false

	--[[
		A contagem **nao** e zerada aqui: uma wave pulada (`WaveService:SkipWave`)
		nasce por cima dos mobs da anterior, e zerar faria os que sobraram
		descontarem da conta da wave nova — o `Ended` sairia com inimigos vivos no
		mapa. O numero ja e o de mobs vivos: o spawn soma, o `removeMob` subtrai, e
		o reset de round zera.
	]]

	-- A janela de ociosidade recomeca com a wave: os mobs ainda estao a caminho das
	-- unidades, e o silencio da caminhada nao e a partida travada.
	self.LastContact = os.clock()

	task.spawn(function()
		for _, spawnEntry in spawnList do
			local entityDefinition = mobConfig.Entities[spawnEntry.Entity]
			if entityDefinition then
				-- Sem o clima: ele entra em `computeSpeed`, para poder sair depois sem
				-- levar junto o que os gimmicks somaram.
				local baseSpeed = mobConfig.BaseSpeed * (entityDefinition.SpeedMultiplier or 1) * speedScale
				local maxHealth = math.max(1, math.floor(((entityDefinition.Health or 10) * healthScale) + 0.5))

				for i = 1, (spawnEntry.Amount or 1) do
					if self.BaseHealth <= 0 then break end
					local mobId = HttpService:GenerateGUID(false)

					-- A bifurcacao e resolvida aqui: o mob sorteia por qual
					-- combinacao de caminhos vai passar. Como cada rota ja e uma
					-- polilinha completa, nada precisa acontecer no ponto onde
					-- os caminhos se separam.
					local routeIndex = math.random(1, #routes)
					local route = routes[routeIndex]

					-- Nascer dentro de um Time Stop e nascer parado: ver `FreezeAll`.
					local frozenUntil = self.FreezeUntil or 0
					local spawnSpeed = baseSpeed * self.WeatherSpeedScale * (self.CardSpeedScale or 1)

					self.ActiveMobs[mobId] = {
						Name = spawnEntry.Entity,
						Health = maxHealth,
						MaxHealth = maxHealth,
						BaseSpeed = baseSpeed,
						SpeedScale = 1,

						-- A lentidao que uma unidade de gelo deixa neste inimigo. Ver
						-- `ApplySlow`.
						SlowScale = 1,
						CurrentSpeed = spawnSpeed,
						Distance = 0,
						StunnedUntil = frozenUntil,
						RouteIndex = routeIndex,
						PathLength = route.smooth.length,
						TurnDistances = route.turnDistances,
						NextTurnIndex = 1,
						Gimmicks = entityDefinition.Gimmicks or {},
						GimmickState = {},
						Reward = spawnEntry.Reward,
					}
					self.ActiveMobCount += 1

					for _, player in Players:GetPlayers() do
						Framework:Fire("SpawnClientMob", player, {
							Id = mobId,
							Name = spawnEntry.Entity,
							Speed = if frozenUntil > GameClock.Now() then 0 else spawnSpeed,
							MaxHealth = maxHealth,
							Route = routeIndex,
						})
					end
					GameClock.Wait(spawnEntry.SpawnDelay or 1)
				end
			end
		end

		self.AllMobsSpawned = true

		if self.ActiveMobCount == 0 and self.BaseHealth > 0 then
			self.Services.WaveService.Signals.Ended:Fire()
		end
	end)
end

function MobService:getMobPosition(mobId)
	local cached = self.PositionCache[mobId]
	if cached and cached.frame == self.FrameId then
		return cached.pos
	end
	local pos = self:PredictPosition(mobId)
	self.PositionCache[mobId] = { frame = self.FrameId, pos = pos }
	return pos
end

--[=[
	O mob que a unidade escolhe dentro do alcance, pelo criterio que o dono dela
	deixou no botao `Priority` do card. A comparacao mora no `TargetPriority`,
	compartilhado com o cliente — ver o modulo.
]=]
function MobService:GetBestMobInRange(position : Vector3, range : number, priority : string?)
	local bestId = nil
	local best = nil

	-- So o `Farthest` olha o caminho; nos outros modos nem se monta a lista.
	local nodeDistances = TargetPriority.UsesPathProgress(priority) and self:getNodeDistances() or nil

	for mobId, mob in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if not pos then continue end

		local dist = (pos - position).Magnitude
		if dist > range then continue end

		local candidate = { distance = dist, health = mob.Health or 0 }

		if nodeDistances then
			candidate.progress = self:getMobPathProgress(mob, pos, nodeDistances)
		end

		if TargetPriority.IsBetter(priority, candidate, best) then
			best = candidate
			bestId = mobId
		end
	end

	return bestId
end

-- Sem prioridade nenhuma: o mais perto. Quem so quer "quem esta ai" — a mina que
-- pergunta quem pisou nela — continua chamando por aqui.
function MobService:GetNearestMobInRange(position : Vector3, range : number)
	return self:GetBestMobInRange(position, range, TargetPriority.Default)
end

--[=[
	A corrente do raio: o alvo mirado e os vizinhos por onde ela salta.

	Comeca no `startMobId` e, a cada passo, pula para o inimigo **mais proximo do
	ultimo tocado** que ainda nao esta na corrente e esta a no maximo `radius` dele.
	Para quando a corrente chega a `maxTargets` ou quando nao ha mais ninguem ao
	alcance do ultimo salto.

	**O raio e medido do ultimo inimigo, e nao da unidade** -- e o que separa isto de
	um `GetMobsInRadius`. A corrente anda junto com a fila do caminho e chega bem alem
	do alcance de quem a disparou, enquanto uma area do mesmo tamanho so pegaria quem
	estivesse amontoado em volta do alvo.

	Sai na ordem em que o raio passa, que e a ordem que o cliente desenha (um arco de
	cada um para o seguinte) e a que uma queda de dano por salto usaria, se um dia
	existir -- a unidade de hoje nao tem nenhuma.

	O alvo mirado vem sempre na corrente, mesmo sozinho: quem chama ja resolveu que
	ele leva o golpe, e uma corrente vazia significaria um golpe perdido.
]=]
function MobService:GetChainTargets(startMobId : string, maxTargets : number?, radius : number?) : { string }
	local chain = { startMobId }

	local limit = math.max(1, math.floor(maxTargets or 1))
	local reach = math.max(0, radius or 0)
	if limit <= 1 or reach <= 0 then
		return chain
	end

	local current = self:getMobPosition(startMobId)
	if not current then
		return chain
	end

	local visited = { [startMobId] = true }

	while #chain < limit do
		local nextId, nextPos, nextDistance = nil, nil, nil

		for mobId in self.ActiveMobs do
			if visited[mobId] then continue end

			local pos = self:getMobPosition(mobId)
			if not pos then continue end

			local distance = (pos - current).Magnitude
			if distance > reach then continue end

			if not nextDistance or distance < nextDistance then
				nextId, nextPos, nextDistance = mobId, pos, distance
			end
		end

		-- O ultimo da corrente esta sozinho: o raio morre nele, mesmo faltando salto.
		if not nextId then break end

		visited[nextId] = true
		current = nextPos
		table.insert(chain, nextId)
	end

	return chain
end

function MobService:GetMobsInRadius(position, radius)
	local result = {}
	for mobId, _ in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if pos and (pos - position).Magnitude <= radius then
			table.insert(result, mobId)
		end
	end
	return result
end

--[=[
	Quem esta na linha que sai de `origin` passando por `through`, ate `length`
	studs de distancia e a no maximo `width` studs da linha.

	E a conta do projetil que atravessa: ele nao para no alvo, entao quem vem
	**atras** dele na mesma linha leva junto. A linha nao para no alvo tambem --
	ela vai ate o alcance da unidade, que e o que decide quem ainda esta perto o
	bastante para ser acertado.

	**A conta e no plano, ignorando o Y.** A unidade fica numa plataforma e o mob
	anda no chao, entao a linha entre os dois desce; medindo em 3D, um inimigo no
	caminho ficaria "longe da linha" so por estar mais baixo que a torre, e a
	flecha o atravessaria sem tirar vida.

	Sai ordenado pela distancia ao longo da linha: e a ordem em que a flecha passa
	por eles, que e a ordem que o cliente desenha e a que um dano decrescente por
	inimigo atravessado usaria, se um dia existir.
]=]
function MobService:GetMobsAlongLine(origin : Vector3, through : Vector3, length : number, width : number)
	local flat = Vector3.new(1, 0, 1)

	local heading = (through - origin) * flat
	if heading.Magnitude < 1e-4 then
		return {}
	end

	local direction = heading.Unit
	local found = {}

	for mobId, _ in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if not pos then continue end

		local offset = (pos - origin) * flat
		local along = offset:Dot(direction)

		-- Atras da unidade, ou passado o alcance dela.
		if along < 0 or along > length then continue end

		if (offset - direction * along).Magnitude <= width then
			table.insert(found, { id = mobId, along = along })
		end
	end

	table.sort(found, function(a, b)
		return a.along < b.along
	end)

	local result = {}
	for _, entry in ipairs(found) do
		table.insert(result, entry.id)
	end

	return result
end

-- Placar de dano da partida. Guarda o nome junto porque o MVP e reportado no
-- fim do round, quando o jogador pode ja ter saido do servidor.
function MobService:addDamageStat(userId, damage)
	if not userId or not damage or damage <= 0 then return end

	local entry = self.SessionDamage[userId]
	if not entry then
		local player = Players:GetPlayerByUserId(userId)
		entry = { damage = 0, name = player and player.DisplayName or "?" }
		self.SessionDamage[userId] = entry
	end

	entry.damage += damage
end

--[=[
	Quanto dano um jogador ja causou nesta partida. Zero para quem ainda nao bateu
	em nada, e para todo mundo depois que o round reinicia -- o placar e limpo junto
	com a partida.
]=]
function MobService:GetDamageDealt(userId : number?) : number
	local entry = userId and self.SessionDamage[userId]

	return entry and entry.damage or 0
end

function MobService:GetMVP()
	local best = nil
	local bestDamage = 0

	for userId, entry in self.SessionDamage do
		if entry.damage > bestDamage then
			bestDamage = entry.damage
			best = {
				userId = userId,
				name = entry.name,
				damage = math.floor(entry.damage + 0.5),
			}
		end
	end

	return best
end

--[=[
	Paga o dano que entrou, descontando a inflacao de vida da wave.

	A vida dos mobs cresce por dificuldade e por wave (`HealthScale`), e sem o
	desconto a renda cresceria junto: no Impossivel a wave 27 tem inimigos 24x mais
	gordos que a wave 1, entao bater neles pagaria 24x mais pelo mesmo trabalho, e
	o dano voltava a ser a economia inteira. Dividindo pela mesma escala, um ponto
	de dano vale o mesmo em qualquer wave e em qualquer preset.
]=]
--[=[
	Soma o bonus da aura do Entrepreneur a um premio, sem perder a parte quebrada.

	Os premios sao inteiros e quase todos pequenos: 15% de um kill de 3 da 0,45, e
	15% do piso de 1 do premio por dano da 0,15 -- arredondados na hora, os dois
	sumiriam, e a aura pareceria nao fazer nada justamente onde ela mais aparece.

	Entao a sobra fica guardada por jogador e vira caixa assim que passa de 1. Um
	bonus pequeno paga devagar em vez de nao pagar nunca, e ao longo de uma wave o
	total sai igual a porcentagem cheia.

	`bonus` e fracao: 0.15 e "+15%". Sem bonus, o premio volta intocado.
]=]
function MobService:applyCashBonus(player, amount : number, bonus : number?, scale : number?) : number
	--[[
		A escala das cartas entra **antes** do bonus da aura, e nao somada a ele: a
		aura e uma fracao que se acumula entre farms (15% + 15% = 30%), e o anel do
		Robux Royalty e um multiplicador em cima do premio. Somar os dois faria
		"1.1x" virar "+10 pontos percentuais", que e outro numero.

		A sobra quebrada da escala cai no mesmo balde da aura, e por isso ela e
		aplicada aqui dentro em vez de no premio ja arredondado: 1.1 de um premio de
		1 e 1,1, e arredondar por fora jogaria os 10% fora em todo golpe pequeno --
		que sao quase todos.
	]]
	scale = scale or 1

	if amount <= 0 or (scale == 1 and (not bonus or bonus <= 0)) then
		return amount
	end

	local scaled = amount * scale
	local carried = (self.BonusRemainder[player.UserId] or 0) + scaled + (scaled * (bonus or 0))
	local whole = math.floor(carried)

	self.BonusRemainder[player.UserId] = carried - whole

	return whole
end

function MobService:awardDamageReward(killerUserId, damage, bonus : number?, cashScale : number?)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end

	local scale = self.HealthScale
	if not scale or scale <= 0 then scale = 1 end

	local reward = math.max(1, math.floor((damage * ServerConfig.Data.CASH_PER_DAMAGE) / scale))
	self:addCash(player, self:applyCashBonus(player, reward, bonus, cashScale))
end

function MobService:awardKillReward(killerUserId, reward, bonus : number?, cashScale : number?)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end
	local amount = reward or math.random(ServerConfig.Data.CASH_PER_KILL_MIN, ServerConfig.Data.CASH_PER_KILL_MAX)
	self:addCash(player, self:applyCashBonus(player, amount, bonus, cashScale))
end

--[=[
	Devolve o dano que de fato entrou, para quem chamou poder creditar a unidade
	(o card de upgrade mostra o total por unidade em `DmgDone`).
]=]
--[=[
	`cashBonus` e a aura do Entrepreneur em cima da unidade que bateu -- uma fracao
	que o `UnitService` congela no comeco do golpe, junto com o dano e o alcance.
	Ela entra nos dois premios, o de dano e o de morte.
]=]
function MobService:DamageMob(mobId, damage, killerUserId, cashBonus : number?, cashScale : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return 0 end

	-- Alguem encostou em alguem: a partida nao esta travada. Marcado aqui porque
	-- este e o unico caminho de dano do jogo — torre, tripmine, respingo de area.
	self.LastContact = os.clock()

	--[[
		O "quebradico" do Staff of Azure Ever Ice usado durante a neve: todo dano que
		entra num inimigo vale mais enquanto ele durar.

		E aqui, no unico caminho de dano do jogo, e nao em cada unidade: ele nao e um
		buff de torre — o inimigo e que esta mais fragil, e um tiro de tripmine ou um
		respingo de area conta igual.
	]]
	local incoming = (damage or 10) * (self.BrittleMultiplier or 1)
	if incoming ~= (damage or 10) then
		incoming = math.max(1, math.floor(incoming + 0.5))
	end

	-- Conta o dano que de fato entrou: um golpe de 70 num mob com 5 de vida vale 5.
	-- Vale tanto para o MVP quanto para a caixa — pagar o valor cheio do golpe
	-- premiava o excedente e transformava o dano na economia inteira da partida.
	local effectiveDamage = math.min(mob.Health, incoming)
	self:addDamageStat(killerUserId, effectiveDamage)

	mob.Health -= incoming
	self:awardDamageReward(killerUserId, effectiveDamage, cashBonus, cashScale)

	self:processDamageGimmicks(mobId, mob)

	if mob.Health <= 0 then
		self:awardKillReward(killerUserId, mob.Reward, cashBonus, cashScale)
		self:removeMob(mobId)
	end

	return effectiveDamage
end

function MobService:construct()
	Framework:Listen("UpdateCash", function() end)
	Framework:Listen("RequestCash", function(player)
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		else
			Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
		end
	end)
	Framework:Listen("SpawnClientMob", function() end)
	Framework:Listen("UpdateMobSpeed", function() end)
	Framework:Listen("KillClientMob", function() end)
	Framework:Listen("HitClientMob", function() end)
	Framework:Listen("AttackVisual", function() end)
	Framework:Listen("MobPlayAttack", function() end)
	Framework:Listen("UpdateBaseHealth", function() end)

	--[=[
		O valor de agora, para quem acabou de achar o billboard da base no mapa.

		O `UpdateBaseHealth` so sai quando a vida muda, e o mapa chega ao cliente
		muito antes do primeiro vazamento -- sem este pedido o numero ficaria no texto
		que veio autorado na GUI ate um inimigo passar. Mesmo motivo do `RequestCash`.
	]=]
	Framework:Listen("RequestBaseHealth", function(player)
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
	end)
	Framework:Listen("GameOver", function() end)
	Framework:Listen("ReplicateUnit", function() end)
	Framework:Listen("Bridge", function() end)
	Framework:Listen("ClientReady", function(player)
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		else
			Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
		end
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
		for mobId, mobData in self.ActiveMobs do
			Framework:Fire("SpawnClientMob", player, {
				Id = mobId,
				Name = mobData.Name,
				Speed = mobData.CurrentSpeed,
				MaxHealth = mobData.MaxHealth,
				Health = mobData.Health,
				Route = mobData.RouteIndex,
			})
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		self.FrameId += 1

		--[[
			O quadro em tempo de partida. Acelerado o mob anda mais por segundo real
			sem ninguem mexer na velocidade dele: e o mesmo `CurrentSpeed`, so que
			multiplicado por um `dt` maior. O cliente faz a mesma conta no
			`MobController`, com a escala que o `SpeedService` mandou.
		]]
		dt = GameClock.Scaled(dt)

		local now = GameClock.Now()

		--[[
			O clima e conferido aqui em vez de ser empurrado por quem o liga.

			Sao duas leituras de tabela por quadro, e em troca a velocidade dos
			inimigos acompanha qualquer troca de clima — a do round e a do comando
			`weather`, que nao passa pelo `WeatherRoundService`. Um empurrao explicito
			so cobriria a primeira, e testar o vento na mao daria uma partida
			diferente da de verdade.
		]]
		local weatherService = self.Services.WeatherService
		local currentWeather = weatherService and weatherService:GetCurrent() or nil
		if currentWeather ~= self.Weather then
			self:ApplyWeather(currentWeather)
		end

		for mobId, mob in self.ActiveMobs do
			--[[
				De onde ele saiu neste quadro. E o que deixa o gatilho da tripmine testar
				o **trecho andado** em vez da posicao parada -- acelerado, o passo de um
				quadro passa do diametro do gatilho e o mob atravessaria a mina intacto.
				Ver `GetMobCrossing`.

				Escrito mesmo com o mob parado (congelado ou atordoado): ai o segmento e
				um ponto, que e a resposta certa para quem nao andou.
			]]
			mob.LastDistance = mob.Distance

			if now >= mob.StunnedUntil then
				mob.Distance += mob.CurrentSpeed * dt
				self:processTurnGimmicks(mobId, mob)
			end

			-- Comprimento por mob: com bifurcacao os dois lados nao precisam ter
			-- o mesmo tamanho.
			if mob.Distance >= mob.PathLength then
				self:mobEscaped(mobId)
				if self.BaseHealth <= 0 then break end
			end
		end
	end)

	if self.CanDebug then
		RunService.Heartbeat:Connect(function()
			for mobId, _ in self.ActiveMobs do
				local pos = self:PredictPosition(mobId)
				if not pos then continue end

				local part = self.DebugParts[mobId]
				if not part then
					part = Instance.new("Part")
					part.Size = Vector3.new(2, 2, 2)
					part.Color = Color3.new(1, 0, 0)
					part.Anchored = true
					part.CanCollide = false
					part.Transparency = 0.5
					part.Parent = workspace
					self.DebugParts[mobId] = part
				end
				part.Position = pos
			end

			for mobId, part in self.DebugParts do
				if not self.ActiveMobs[mobId] then
					part:Destroy()
					self.DebugParts[mobId] = nil
				end
			end
		end)
	end

end

function MobService:start()
	for ServiceName, _ in self.Services do
		self.Services[ServiceName] = Framework:Get(ServiceName)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		end
	end

	Players.PlayerAdded:Connect(function(player)
		self:initPlayerCash(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.SessionCash[player.UserId] = nil
		self.BonusRemainder[player.UserId] = nil
	end)

	self:construct()
end

function MobService:init()
end

return MobService
