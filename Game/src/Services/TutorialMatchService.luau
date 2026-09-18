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

-- O mesmo atributo que o `MapService` lê para escolher o mapa no Studio. Ele é a
-- segunda porta do tutorial: ver `resolve`.
local STUDIO_MAP_ATTRIBUTE = "StudioMap"

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

	local step = self:StepFor(wave)
	if not step then
		self.Step = nil

		return
	end

	self.Step = step
	self.Done = false

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

	print(string.format("[DEBUG/Tutorial] abrindo passo '%s' (wave %d, %s)%s",
		step.Id, wave, step.Kind, step.Hold and " — segurando a wave" or ""))

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
			Position = point and point.Position or nil,
			Positions = positions,
			Lines = step.Lines,
			Locked = locked,
			AllowedUnits = self:allowedUnits(),
		})
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

	for _, player in Players:GetPlayers() do
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
		self:resolve()
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
