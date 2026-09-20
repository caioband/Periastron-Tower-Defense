local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.TutorialConfig
local RoundCardConfig = SharedConfig.RoundCardConfig
local DifficultyConfig = ServerConfig.Difficulty
local AnalyticsConfig = ServerConfig.Analytics

-- O mesmo atributo que o `MapService` lê para escolher o mapa no Studio. Ele é a
-- segunda porta do tutorial: ver `resolve`.
local STUDIO_MAP_ATTRIBUTE = "StudioMap"

--[[
	A "wave" do intervalo: o passo do botão de Ready, que acontece **antes** de a
	primeira nascer.

	O roteiro é indexado por wave, e o intervalo não tem número — então ele fica com
	o zero, que é o que a partida tem em `WaveCount` enquanto a contagem corre. Ver
	`BeginIntermission`.
]]
local INTERMISSION_WAVE = 0

--[[
	A partida de tutorial: quem diz que **esta** partida é o tutorial, e o que ela
	impõe por ser isso.

	**Duas portas, e só duas.**

	  1. `TeleportData.Tutorial == true`, que é o que o Lobby embarca quando o
	     jogador aceita a oferta. É a porta de verdade, a que vale em servidor
	     publicado.
	  2. O atributo `StudioMap = "Tutorial"` na pasta `ServerStorage.Maps`, que é a
	     porta do Studio — no Studio não existe TeleportData, e sem isto não haveria
	     como ensaiar o roteiro.

	Carregar o mapa `Tutorial` **sem** nenhuma das duas roda uma partida comum nele:
	é assim que se testa o mapa (caminho, nós, `PlacementPoints`) sem o roteiro por
	cima. A flag e o mapa dizem coisas diferentes de propósito.

	**O que esta fatia impõe:**

	  - a dificuldade é o preset `Tutorial` e a **votação é pulada** — a partida é
	    desenhada para o jogador ganhar, e escolher `Nightmare` no tutorial seria
	    escolher perder;
	  - o deck da partida é o do `TutorialConfig.Match.Deck` (duas Archer e uma
	    Slasher), **sem tocar no perfil**.

	O roteiro em si (o que acontece em cada uma das 5 waves) vem nas próximas fatias
	e se pendura aqui.

	> A resposta é decidida **uma vez**, na primeira pergunta, e guardada: um
	> servidor é de tutorial ou não é pela vida inteira dele. Perguntar de novo a
	> cada wave abriria a porta para a partida mudar de natureza no meio.
]]

local TutorialMatchService = {
	Services = {
		UnitService = {},
		SpeedService = {},
		WeatherRoundService = {},
		MobService = {},
		AnalyticsService = {},
	}
}

-- O passo aberto agora, e se ele já foi cumprido. Um passo por vez: o roteiro é
-- uma fila, não um conjunto.
TutorialMatchService.Step = nil :: any
TutorialMatchService.Done = false

-- O deck já foi solto? Vira `true` no passo que declara `UnlocksDeck` (a wave 5) e
-- é o que faz a trava de cartas valer do começo da partida até lá.
TutorialMatchService.DeckUnlocked = false

-- Os passos já cumpridos, por `Id`. É o que permite a uma carta ficar trancada
-- até o passo dela abrir e destrancada depois. Ver `CanUse`.
TutorialMatchService.Completed = {}

-- `nil` enquanto ninguém perguntou; `true`/`false` depois da primeira resposta.
TutorialMatchService.Tutorial = nil :: boolean?

--[[
	A partida foi vencida?

	Só existe para a telemetria: o teleporte de volta e o jogador que desiste saem
	os dois pelo `PlayerRemoving`, e é este booleano que os separa. Ver `NoteWon`.
]]
TutorialMatchService.Won = false

-- A wave do último passo aberto. É o número que o evento de abandono leva, e sai
-- daqui em vez do `WaveService` para não pendurar uma dependência a mais.
TutorialMatchService.LastWave = nil :: number?

--[[ INTERNAL ]]

--[=[
	A flag que o Lobby embarcou no teleporte deste jogador.
]=]
function TutorialMatchService:teleportedFlag(player : Player) : boolean
	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	if not success or typeof(joinData) ~= "table" then
		return false
	end

	local teleportData = joinData.TeleportData
	if typeof(teleportData) ~= "table" then
		return false
	end

	return teleportData.Tutorial == true
end

--[=[
	O atributo do Studio, a segunda porta.
]=]
function TutorialMatchService:studioFlag() : boolean
	local maps = ServerStorage:FindFirstChild("Maps")
	if not maps then
		return false
	end

	return maps:GetAttribute(STUDIO_MAP_ATTRIBUTE) == Config.Match.Map
end

--[=[
	Decide, uma vez, se este servidor é de tutorial.

	Em servidor publicado a resposta é do TeleportData, e por isso ela espera o
	primeiro jogador — é dele que o JoinData vem, e ele só chega depois do boot. É a
	mesma espera que o `MapService` faz para descobrir o mapa, e pelo mesmo motivo.
]=]
function TutorialMatchService:resolve() : boolean
	if self.Tutorial ~= nil then
		return self.Tutorial
	end

	if RunService:IsStudio() and self:studioFlag() then
		self.Tutorial = true

		print("[TutorialMatchService]: partida de tutorial pelo atributo StudioMap.")

		return true
	end

	local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()

	self.Tutorial = self:teleportedFlag(player)

	if self.Tutorial then
		print(`[TutorialMatchService]: partida de tutorial pelo TeleportData de {player.Name}.`)
	end

	return self.Tutorial
end

--[[ API ]]

--[=[
	Esta partida é o tutorial?

	**Pode ceder a thread** na primeira chamada de um servidor publicado, esperando
	o primeiro jogador. Quem chama de dentro do round já tem jogador na sala, então
	na prática ela responde na hora.
]=]
function TutorialMatchService:IsTutorial() : boolean
	return self:resolve()
end

--[=[
	O preset que esta partida impõe, ou `nil` quando ela é comum.

	É o que o `WaveService` usa para pular a votação de dificuldade: recebendo um
	preset daqui, ele nem abre a votação.
]=]
function TutorialMatchService:GetForcedPreset() : any
	if not self:IsTutorial() then
		return nil
	end

	local name = Config.Match.Difficulty
	local preset = DifficultyConfig.Presets[name]

	if not preset then
		warn(`[TutorialMatchService]: o preset "{name}" nao existe em Config.Difficulty.Presets; a partida vai votar como sempre.`)

		return nil
	end

	return preset
end

--[=[
	O deck desta partida, ou `nil` quando ela é comum: `{ [unidade] = quantas }`, no
	mesmo formato que o `DeckConfig.tally` devolve.

	Uma cópia a cada chamada — quem recebe mexe na tabela (é ela que vira a contagem
	de cartas da sessão), e o config não pode ser gasto pela partida.
]=]
function TutorialMatchService:GetDeck() : { [string] : number }?
	if not self:IsTutorial() then
		return nil
	end

	local counts = {}

	for _, slot in Config.Match.Deck do
		counts[slot.Unit] = (counts[slot.Unit] or 0) + slot.Amount
	end

	return counts
end

--[=[
	As cartas do deck do tutorial na ordem da hotbar, ou `nil` fora dele.

	A hotbar do cliente é desenhada a partir do **perfil** (`DeckConfig.unitList`), e
	o deck do tutorial não está no perfil de propósito. Por isso ele viaja: sem esta
	lista, o servidor conheceria as cartas e a tela não mostraria nenhuma.
]=]
function TutorialMatchService:GetDeckOrder() : { string }?
	if not self:IsTutorial() then
		return nil
	end

	local order = {}

	for _, slot in Config.Match.Deck do
		table.insert(order, slot.Unit)
	end

	return order
end

--[[ O ROTEIRO ]]

--[=[
	O passo desta wave, se houver.
]=]
function TutorialMatchService:StepFor(wave : number) : any
	for _, step in Config.Match.Steps do
		if step.Wave == wave then
			return step
		end
	end

	return nil
end

--[=[
	A part do mapa em que o passo pede a unidade.

	Lida do mapa **carregado** (`Workspace.Map`), e não de `ServerStorage`: a cópia
	guardada está longe do mundo, e a posição dela não serve para apontar nada.
]=]
function TutorialMatchService:pointFor(step : any) : BasePart?
	if not step or not step.Point then
		return nil
	end

	local part = self:pointNamed(step.Point)
	if not part then
		warn(`[TutorialMatchService]: o passo "{step.Id}" pede o ponto "{step.Point}", que nao existe em Map.PlacementPoints.`)
	end

	return part
end

--[=[
	Uma part de `Map.PlacementPoints` pelo nome.
]=]
function TutorialMatchService:pointNamed(name : string) : BasePart?
	local map = workspace:FindFirstChild("Map")
	local points = map and map:FindFirstChild("PlacementPoints")
	local part = points and points:FindFirstChild(name)

	return if part and part:IsA("BasePart") then part else nil
end

--[=[
	Abre o passo desta wave: manda o cliente mostrar a instrução e trava o que o
	passo restringe.

	O que o cliente recebe é o suficiente para ele desenhar — o tipo do passo, a
	carta permitida, a posição do ponto e as falas. A **regra** fica aqui: o cliente
	apaga as outras cartas por educação, o servidor as recusa por segurança.
]=]
function TutorialMatchService:BeginStep(wave : number)
	if not self:IsTutorial() then return end

	-- Passo da wave anterior que segura a **próxima** (o uso do Weather Report) é
	-- esperado aqui, antes de o passo desta wave abrir: um passo por vez, e a wave
	-- nova não começa por cima de uma tarefa que ficou pendente.
	self:awaitPending()

	self:openStep(self:StepFor(wave))
end

--[=[
	Abre o passo que o roteiro guarda para o fim da partida — o da tela de
	resultado, que não pertence a wave nenhuma.

	Quem chama é o `onRoundEnded`, no mesmo instante em que a tela é mandada. Não
	espera passo pendente: a partida acabou, e o que ficou por fazer ficou.
]=]
function TutorialMatchService:BeginFinal()
	if not self:IsTutorial() then return end

	self:openStep(self:finalStep())
end

--[=[
	O passo de fim de partida, se o roteiro tiver um.
]=]
function TutorialMatchService:finalStep() : any
	for _, step in Config.Match.Steps do
		if step.Kind == "Lobby" then
			return step
		end
	end

	return nil
end

--[=[
	Põe um passo no ar: guarda-o, aplica o que ele impõe e manda o cliente desenhar.

	É o corpo que o `BeginStep` e o `BeginFinal` dividem — os dois só diferem em
	**qual** passo procurar.
]=]
function TutorialMatchService:openStep(step : any)
	if not step then
		self.Step = nil

		return
	end

	self.Step = step
	self.Done = false
	self.LastWave = step.Wave or self.LastWave

	if step.UnlocksDeck then
		self.DeckUnlocked = true
	end

	self:scheduleWeather(step)
	self:ensureCash(step)

	local point = self:pointFor(step)

	-- O passo do fecho aponta vários lugares de uma vez: uma seta por ponto livre.
	local positions = nil
	if step.Points then
		positions = {}

		for _, name in step.Points do
			local part = self:pointNamed(name)

			if part then
				table.insert(positions, part.Position)
			end
		end
	end

	print(string.format("[DEBUG/Tutorial] abrindo passo '%s' (%s, %s)%s",
		step.Id,
		if step.Wave then `wave {step.Wave}` else "fim de partida",
		step.Kind,
		step.Hold and " — segurando a wave" or ""))

	-- As cartas que o roteiro ainda tranca, para a mão do cliente não aceitar o
	-- clique de uma que o servidor recusaria.
	local locked = {}
	for _, other in Config.Match.Steps do
		if other.Kind == "Use" and other.Card and not self.Completed[other.Id] then
			locked[other.Card] = true
		end
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("TutorialStep", player, {
			Id = step.Id,
			Kind = step.Kind,
			Unit = step.Unit,
			Card = step.Card,
			Highlight = step.Highlight,
			HighlightWait = step.HighlightWait,
			Position = point and point.Position or nil,
			Positions = positions,
			Lines = step.Lines,

			-- O que o passo faz com a hotbar: `Deck` enquanto ele corre, `HidesDeck`
			-- quando ele fecha. Os dois viajam porque quem desenha a mão é o cliente.
			Deck = step.Deck,
			HidesDeck = step.HidesDeck,
			Locked = locked,
			AllowedUnits = self:allowedUnits(),
		})
	end
end

--[=[
	Abre o passo do intervalo — o primeiro do roteiro, o do botão de Ready.

	Quem chama é o `WaveService`, **antes** de a contagem começar: a fala entra
	enquanto o relógio ainda está cheio, e quando ela fecha o botão já está na tela
	para o destaque abraçar.

	Fora de partida de tutorial, e no roteiro que não tiver um passo para a wave
	zero, não faz nada — como toda a API daqui.
]=]
function TutorialMatchService:BeginIntermission()
	self:BeginStep(INTERMISSION_WAVE)
end

--[=[
	A contagem do intervalo terminou: fecha o passo do Ready.

	"Terminou" é o fim do `runIntermission`, e ele vem dos dois jeitos — o relógio
	zerou, ou todo mundo ficou pronto antes dele, que numa partida de tutorial é o
	clique do jogador no botão que o passo acabou de apontar. Os dois querem dizer a
	mesma coisa para o roteiro: a wave 1 vem aí, e o passo dela é o próximo.
]=]
function TutorialMatchService:NoteIntermissionEnd()
	local step = self.Step

	if step and step.Kind == "Ready" then
		self:CompleteStep()
	end
end

--[=[
	Espera um passo da wave anterior que pediu para segurar a seguinte (`HoldNext`).
]=]
function TutorialMatchService:awaitPending()
	local step = self.Step

	while step and step.HoldNext and not self.Done and self.Step == step do
		task.wait(0.2)
		step = self.Step
	end
end

--[=[
	Agenda o clima que o passo pede para a wave seguinte.

	Entra pelo mesmo `Scheduled`/`ScheduledWave` do sorteio normal, e não por um
	caminho paralelo: assim o aviso de clima sai na tela pelo código de sempre, que
	é justamente o que este passo do tutorial está ensinando a ler.
]=]
function TutorialMatchService:scheduleWeather(step : any)
	if not step.ScheduleWeather or #step.ScheduleWeather == 0 then return end

	local weather = self.Services.WeatherRoundService
	if not weather then return end

	local name = step.ScheduleWeather[math.random(1, #step.ScheduleWeather)]

	weather.Scheduled = name
	weather.ScheduledWave = step.Wave + 1

	weather:broadcastWarning(name, 1)

	print(`[TutorialMatchService]: "{name}" agendado para a wave {step.Wave + 1}.`)
end

--[=[
	A rede contra o beco sem saída: passo que **obriga** uma compra e segura a wave
	não pode encontrar um jogador sem dinheiro.

	Completa só a diferença, e só até o preço — não é presente, é a garantia de que
	o roteiro não trava. Fora de um passo com `Ensure`, ninguém ganha nada.
]=]
function TutorialMatchService:ensureCash(step : any)
	if not step.Ensure or not step.Card then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	local card = RoundCardConfig.Get(step.Card)
	local price = card and math.max(0, card.Price or 0) or 0
	if price <= 0 then return end

	for _, player in Players:GetPlayers() do
		local missing = price - (mobService:getCash(player) or 0)

		if missing > 0 then
			mobService:addCash(player, missing)

			print(`[TutorialMatchService]: completei {missing} para {player.Name} poder comprar "{step.Card}".`)
		end
	end
end

--[=[
	Segura a wave enquanto o passo dela não for cumprido.

	Quem chama é o `WaveService`, depois de anunciar o número da wave e antes de os
	mobs nascerem. Passo sem `Hold` não segura nada — a fala aparece e a wave corre
	por cima dela, que é o certo para instrução que não exige ação.

	O laço olha a geração do passo, e não um booleano solto: um `StopRound` no meio
	do tutorial fecha o passo, e a espera tem de morrer junto.
]=]
function TutorialMatchService:AwaitStep(wave : number)
	local step = self.Step
	if not step or step.Wave ~= wave or not step.Hold then
		return
	end

	while self.Step == step and not self.Done do
		-- O degrau da sala é estado, não evento: olhar o valor dispensa enxertar
		-- código no `SpeedService` para ele avisar o tutorial.
		if step.Kind == "Speed" then
			local speed = self.Services.SpeedService

			if speed and speed:GetIndex() >= (step.Index or 2) then
				self:CompleteStep()

				break
			end
		end

		task.wait(0.2)
	end
end

--[=[
	Este jogador ainda tem carta de unidade na mão?

	Lido do `UnitService`, que é quem conta as cartas da sessão — a contagem do
	perfil não serve, porque o deck do tutorial não vem dele.
]=]
function TutorialMatchService:handIsEmpty(player : Player) : boolean
	local unitService = self.Services.UnitService
	if not unitService then
		return true
	end

	local cards = unitService.SessionCards and unitService.SessionCards[player.UserId]
	if not cards then
		return true
	end

	for _, count in cards do
		if count > 0 then
			return false
		end
	end

	return true
end

--[=[
	O passo foi cumprido: avisa o cliente e solta a wave.
]=]
function TutorialMatchService:CompleteStep()
	local step = self.Step
	if not step or self.Done then return end

	self.Done = true
	self.Completed[step.Id] = true

	print(`[DEBUG/Tutorial] passo "{step.Id}" cumprido; a wave esta liberada.`)

	local analytics = self.Services.AnalyticsService

	for _, player in Players:GetPlayers() do
		--[[
			O funil de onboarding usa **o `Id` do passo** como nome, e por isso o
			roteiro e a lista de `ServerConfig.Analytics` não precisam de uma tabela de
			tradução entre elas.

			O passo do fim de partida fica de fora: ele não é uma tarefa que o jogador
			cumpre, e quem registra a volta ao lobby é o lobby, pelo bilhete do
			teleporte.
		]]
		if analytics and step.Kind ~= "Lobby" then
			analytics:LogFunnelStep(player, step.Id)
		end

		Framework:Fire("TutorialStepDone", player, step.Id)
	end
end

--[=[
	A loja de cartas tem de abrir nesta wave?

	O calendário normal é do `RoundCardConfig.IsShopWave`; o tutorial abre na wave
	que o roteiro mandar, por cima dele.
]=]
function TutorialMatchService:ShouldOpenShop(wave : number) : boolean
	if not self:IsTutorial() then
		return false
	end

	local step = self:StepFor(wave)

	return step ~= nil and step.OpenShop == true
end

--[=[
	A carta que o passo desta wave planta na rotação, se houver.
]=]
function TutorialMatchService:ForcedCard(wave : number) : string?
	if not self:IsTutorial() then
		return nil
	end

	local step = self:StepFor(wave)

	return step and step.Kind == "Buy" and step.Card or nil
end

--[=[
	Esta compra é permitida agora?

	Com um passo de compra aberto, só a carta dele. As outras duas continuam na
	mesa e recusadas — o jogador vê que existem, e aprende qual delas o passo quer.
]=]
function TutorialMatchService:CanBuy(cardId : string) : boolean
	local step = self.Step

	if not step or step.Kind ~= "Buy" or self.Done then
		return true
	end

	return cardId == step.Card
end

--[=[
	As unidades que a mão aceita agora: `{ [nome] = true }`, ou `nil` quando o deck
	está solto.

	Fora de partida de tutorial devolve `nil` — o jogo normal não tranca nada.
]=]
function TutorialMatchService:allowedUnits() : { [string] : boolean }?
	if not self:IsTutorial() or self.DeckUnlocked then
		return nil
	end

	local list = Config.Match.AllowedUnits
	if not list or #list == 0 then
		return nil
	end

	local allowed = {}
	for _, unitName in list do
		allowed[unitName] = true
	end

	return allowed
end

--[=[
	O passo de uso que pede esta carta, se o roteiro tiver um.
]=]
function TutorialMatchService:useStepFor(cardId : string) : any
	for _, step in Config.Match.Steps do
		if step.Kind == "Use" and step.Card == cardId then
			return step
		end
	end

	return nil
end

--[=[
	Esta carta já pode ser usada?

	Carta que o roteiro regula fica **trancada até o passo dela abrir**: a Weather
	Report é comprada na wave 2 e serve para a 3, e gastá-la antes de o clima existir
	é perder a carta e a lição junto — o jogador ficaria preso num passo que pede uma
	carta que ele não tem mais.

	Carta que o roteiro não menciona passa sempre; passo já cumprido também libera.
]=]
function TutorialMatchService:CanUse(cardId : string) : boolean
	if not self:IsTutorial() then
		return true
	end

	local step = self:useStepFor(cardId)
	if not step then
		return true
	end

	if self.Step == step and not self.Done then
		return true
	end

	return self.Completed[step.Id] == true
end

--[=[
	Uma compra aconteceu. Fecha o passo de compra que pedia esta carta.
]=]
function TutorialMatchService:NoteBuy(cardId : string)
	local step = self.Step

	if step and step.Kind == "Buy" and step.Card == cardId then
		self:CompleteStep()
	end
end

--[=[
	Um uso aconteceu. Fecha o passo de uso que pedia esta carta.
]=]
function TutorialMatchService:NoteUse(cardId : string)
	local step = self.Step

	if step and step.Kind == "Use" and step.Card == cardId then
		self:CompleteStep()
	end
end

--[=[
	A partida de tutorial foi vencida.

	Quem chama é o `WaveService`, no mesmo ramo que escreve a vitória no perfil. É
	só para a telemetria: sem isto, o teleporte de volta pareceria um jogador
	desistindo — os dois saem pelo `PlayerRemoving`.
]=]
function TutorialMatchService:NoteWon()
	self.Won = true
end

--[=[
	Melhorar uma unidade é permitido agora?

	**Na partida de tutorial, nunca** — e não só enquanto um passo está aberto.

	Duas razões, e as duas valem a partida inteira: o dinheiro está contado para o
	deck (`StartingCash` cobre as três torres, e um upgrade no meio do caminho deixa
	o passo do fecho sem com que comprar as outras duas), e o roteiro já ensina
	quatro coisas — colocar, comprar, usar carta e acelerar. Melhorar torre é a
	lição da primeira partida de verdade.

	O botão continua na tela, trancado (`ToggleTower`): o jogador vê que existe.
	Aqui é quem recusa, porque cliente não se fiscaliza.

	Fora de partida de tutorial devolve `true` — o jogo normal não tranca nada.
]=]
function TutorialMatchService:CanUpgrade() : boolean
	return not self:IsTutorial()
end

--[=[
	Vender uma unidade é permitido agora?

	**Na partida de tutorial, nunca**, pelo mesmo motivo do `CanUpgrade` e por um
	que é só dela: vender desfaz um passo que o roteiro já deu por cumprido. A
	Slingshot da wave 1 é a torre com que o jogador aprende clima, loja e velocidade
	— sem ela no chão, as três lições seguintes acontecem num mapa vazio, e a carta
	que volta para a mão não tem passo que a peça de novo.

	O botão continua na tela, trancado (`ToggleTower`). Aqui é quem recusa.
]=]
function TutorialMatchService:CanSell() : boolean
	return not self:IsTutorial()
end

--[=[
	Esta colocação é permitida agora?

	`true` quando não há passo de colocação aberto — fora do roteiro, o tutorial não
	se mete. Com passo aberto, só passa a carta pedida e só perto do ponto pedido: é
	a metade da regra que não depende do cliente se comportar.
]=]
function TutorialMatchService:CanPlace(unitName : string, cf : CFrame) : boolean
	--[[
		A trava do deck vale a partida inteira até o passo do fecho, e não só
		enquanto um passo está aberto: entre a wave 1 e a 5 não há passo de colocação
		nenhum, e sem isto o jogador poria as Archer no mapa no primeiro intervalo.
	]]
	local allowed = self:allowedUnits()
	if allowed and not allowed[unitName] then
		return false
	end

	local step = self.Step
	if not step or self.Done then
		return true
	end

	-- O passo do fecho aceita qualquer carta, mas só nos pontos que sobraram: a
	-- lição da wave 5 é cobrir o mapa, não obedecer a um lugar.
	if step.Kind == "PlaceRest" then
		for _, name in (step.Points or {}) do
			local part = self:pointNamed(name)

			if part and (cf.Position - part.Position).Magnitude <= (step.Radius or 10) then
				return true
			end
		end

		return false
	end

	if step.Kind ~= "Place" then
		return true
	end

	if step.Unit and unitName ~= step.Unit then
		return false
	end

	local point = self:pointFor(step)
	if not point then
		-- Ponto que não existe no mapa não pode virar cadeado: o passo já avisou no
		-- output, e prender o jogador por causa disso seria transformar um erro de
		-- montagem numa partida travada.
		return true
	end

	return (cf.Position - point.Position).Magnitude <= (step.Radius or 10)
end

--[[ TELEMETRIA ]]

--[=[
	Quem entrou na partida de tutorial, e quem saiu dela antes de vencer.

	Ligado uma vez, e **só** quando o servidor se resolveu como tutorial (ver
	`construct`): partida comum não paga por esta escuta.

	O servidor é reservado e a partida é de um jogador só, mas o passo é por
	jogador — quem chegar aqui por um caminho que não seja o teleporte da oferta
	entra no funil do mesmo jeito.
]=]
function TutorialMatchService:watchPlayers()
	local analytics = self.Services.AnalyticsService
	if not analytics then return end

	local function joined(player : Player)
		analytics:LogFunnelStep(player, "MatchJoined")
	end

	for _, player in Players:GetPlayers() do
		joined(player)
	end

	Players.PlayerAdded:Connect(joined)

	--[[
		Sair sem ter vencido é o abandono — e é justamente o que o funil não conta:
		quem desiste na wave 3 e quem cai por internet param no mesmo passo, e nenhum
		dos dois deixa rastro no perfil (a chave fica em `false`, de propósito).

		O teleporte de volta depois da vitória também sai por aqui; quem os separa é
		o `Won`.
	]]
	Players.PlayerRemoving:Connect(function(player : Player)
		if self.Won then return end

		local step = self.Step

		analytics:LogEvent(player, AnalyticsConfig.Events.Abandoned, self.LastWave or 0, {
			step and step.Id or "None",
		})
	end)
end

--[[ CICLO DE VIDA ]]

function TutorialMatchService:construct()
	-- Os identificadores nascem no servidor: sem estes `Listen` vazios, o cliente
	-- ficaria dez segundos esperando eventos que ninguém registrou.
	Framework:Listen("TutorialStep", function() end)
	Framework:Listen("TutorialStepDone", function() end)
	Framework:Listen("TutorialDeck", function() end)

	-- Resolve fora do caminho do primeiro round: a espera pelo primeiro jogador
	-- acontece aqui, numa thread própria, e não dentro do `runRound`.
	task.spawn(function()
		if not self:resolve() then return end

		self:watchPlayers()
	end)

	local unitService = self.Services.UnitService
	if not unitService then return end

	-- A colocação que passou por todas as conferências do `UnitService` — inclusive
	-- a nossa — é a que cumpre o passo. Escutar o sinal, em vez de enxertar mais
	-- código no `PlaceUnit`, deixa a regra do tutorial fora do caminho quente da
	-- partida.
	unitService.Signals.UnitPlaced:Connect(function(player : Player, unitName : string)
		local step = self.Step
		if not step then return end

		if step.Kind == "Place" and (not step.Unit or step.Unit == unitName) then
			self:CompleteStep()

			return
		end

		-- O fecho acaba quando a mão esvazia: com carta sobrando ainda há ponto para
		-- cobrir, e o passo continua pedindo.
		if step.Kind == "PlaceRest" and self:handIsEmpty(player) then
			self:CompleteStep()
		end
	end)
end

function TutorialMatchService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function TutorialMatchService:init()
end

return TutorialMatchService
