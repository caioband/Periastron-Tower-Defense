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
	acumularam, vezes o que o clima faz.

	Os tres fatores sao guardados separados de proposito. O clima entra e sai no
	meio da wave, e um mob que ja ganhou 30% por curva tem que manter esse ganho
	quando o vento parar — o que so funciona se a conta for refeita a partir da
	base em vez de ir multiplicando o valor corrente.
]=]
local function computeSpeed(self, mob)
	return mob.BaseSpeed * (mob.SpeedScale or 1) * (self.WeatherSpeedScale or 1)
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
		WeatherService = {}
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
					local spawnSpeed = baseSpeed * self.WeatherSpeedScale

					self.ActiveMobs[mobId] = {
						Name = spawnEntry.Entity,
						Health = maxHealth,
						MaxHealth = maxHealth,
						BaseSpeed = baseSpeed,
						SpeedScale = 1,
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
function MobService:applyCashBonus(player, amount : number, bonus : number?) : number
	if not bonus or bonus <= 0 or amount <= 0 then
		return amount
	end

	local carried = (self.BonusRemainder[player.UserId] or 0) + (amount * bonus)
	local whole = math.floor(carried)

	self.BonusRemainder[player.UserId] = carried - whole

	return amount + whole
end

function MobService:awardDamageReward(killerUserId, damage, bonus : number?)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end

	local scale = self.HealthScale
	if not scale or scale <= 0 then scale = 1 end

	local reward = math.max(1, math.floor((damage * ServerConfig.Data.CASH_PER_DAMAGE) / scale))
	self:addCash(player, self:applyCashBonus(player, reward, bonus))
end

function MobService:awardKillReward(killerUserId, reward, bonus : number?)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end
	local amount = reward or math.random(ServerConfig.Data.CASH_PER_KILL_MIN, ServerConfig.Data.CASH_PER_KILL_MAX)
	self:addCash(player, self:applyCashBonus(player, amount, bonus))
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
function MobService:DamageMob(mobId, damage, killerUserId, cashBonus : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return 0 end

	-- Alguem encostou em alguem: a partida nao esta travada. Marcado aqui porque
	-- este e o unico caminho de dano do jogo — torre, tripmine, respingo de area.
	self.LastContact = os.clock()

	-- Conta o dano que de fato entrou: um golpe de 70 num mob com 5 de vida vale 5.
	-- Vale tanto para o MVP quanto para a caixa — pagar o valor cheio do golpe
	-- premiava o excedente e transformava o dano na economia inteira da partida.
	local effectiveDamage = math.min(mob.Health, damage or 10)
	self:addDamageStat(killerUserId, effectiveDamage)

	mob.Health -= (damage or 10)
	self:awardDamageReward(killerUserId, effectiveDamage, cashBonus)

	self:processDamageGimmicks(mobId, mob)

	if mob.Health <= 0 then
		self:awardKillReward(killerUserId, mob.Reward, cashBonus)
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
