local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.TutorialConfig

--[[
	O roteiro do tutorial na tela do jogador.

	O servidor manda `TutorialStep` quando um passo abre e `TutorialStepDone` quando
	ele é cumprido; daqui saem as três coisas que o jogador vê:

	  1. a **instrução**, pela caixa de fala de sempre — sem borrão e sem esconder a
	     UI, ao contrário de toda outra fala do jogo: o passo pede para o jogador
	     usar o HUD, e escondê-lo enquanto se pede isso seria uma piada de mau gosto;
	  2. o **destaque** na carta que ele tem de usar, pelo `HighlightController`;
	  3. a **seta** no ponto do mapa onde a unidade tem de entrar, pelo
	     `ArrowController`;
	  4. a **trava de botões**, pelo `ButtonGateController`: o que o passo não pede
	     para de aceitar clique. Quem escreve a whitelist é o config (`Buttons` do
	     passo), e ela **sobrevive ao passo** — a trava é da partida, como a do deck.

	**O bloqueio das outras cartas mora aqui**, e o `CardController` pergunta:
	`:AllowsCard(nome)` é o que ele consulta antes de pôr uma carta na mão. É
	educação de interface — quem recusa de verdade é o `TutorialMatchService`, no
	servidor, porque cliente não se fiscaliza.

	Fica na Game: o roteiro é da partida, e partida só existe aqui.
]]

-- Quanto esperar uma peça de tela do passo aparecer, em décimos de segundo: a
-- carta (`awaitCard`) e o botão que o passo aponta (`awaitHighlight`). O passo pode
-- pedir mais com `HighlightWait`, em segundos — ver o passo da tela de resultado.
local UI_WAIT_FRAMES = 50

--[=[
	Quanto uma fala de passo pode ficar na tela antes de o passo seguir sem ela.

	O destaque e as setas entram no `OnClosed` da fala, e só ali. Fala que não fecha
	é um passo que nunca aponta nada: a instrução fica na tela, o jogador a lê, e
	depois dela não há holofote em botão nenhum.

	Vinte segundos é muito mais que a fala mais longa do roteiro (duas linhas em modo
	automático), então isto não dispara em partida normal. Disparando, o output diz — e
	é essa linha que transforma "o passo não apontou nada" num defeito com endereço.
]=]
local SPEECH_TIMEOUT = 20

local TutorialStepController = {
	Controllers = {
		DialogController = {},
		HighlightController = {},
		ArrowController = {},
		RoundCardShopController = {},
		SpeedController = {},
		ButtonGateController = {},
	}
}

TutorialStepController.Step = nil :: any

--[[
	Esta partida é o tutorial?

	Vira `true` no primeiro passo que chegar e nunca mais volta: o roteiro abre o
	passo do Ready antes de qualquer outra coisa, então quando a loja de cartas
	aparece (wave 2) a resposta já está aqui. É o que permite ao tutorial valer
	**entre** os passos — o clique fora da loja, por exemplo, não fecha a loja em
	nenhum momento da partida, e não só enquanto um passo de compra está aberto.
]]
TutorialStepController.InTutorial = false

--[[
	O componente `Card`, quando ele já resolveu. Ver `resolveCardComponent` — ele é
	guardado justamente para o caminho do passo nunca ter de esperar por um `require`
	que dorme.
]]
TutorialStepController.CardComponent = nil :: any

-- As cartas que o roteiro tranca até o passo delas: `{ [Id] = true }`. O servidor
-- manda a lista junto do passo de compra, e é ela que a mão consulta.
TutorialStepController.LockedCards = {}

--[[
	A hotbar está fora da tela porque há uma fala no ar? Ver `setCardsHidden`.

	Guardado aqui, e não lido do `DialogController`, porque ele é reaplicado quando o
	componente `Card` resolve — e ele pode resolver depois de a fala já ter começado.
]]
TutorialStepController.DeckHidden = false

-- As unidades que a mão aceita agora: `{ [nome] = true }`, ou `nil` com o deck
-- solto. É o último pedido do roteiro (ver `setAllowedCards`), e vale **entre** os
-- passos — quem pergunta é o `AllowsCard`.
TutorialStepController.AllowedUnits = nil :: { [string] : boolean }?

-- As setas do passo. São várias no fecho, que aponta os dois pontos livres.
TutorialStepController.Arrows = {}

--[[
	As escutas que valem só enquanto o passo está aberto — hoje as do menu de
	velocidade (ver `watchSpeedOptions`). O `clear` as desfaz, como faz com as setas:
	escuta de passo que sobrevive ao passo aponta o destaque para o lugar errado no
	passo seguinte.
]]
TutorialStepController.StepConnections = {}

--[[ INTERNAL ]]

--[=[
	O componente `Card` do `UILibraryController`, ou `nil` enquanto ele não resolveu.

	**Esta função não dorme, e é o ponto inteiro dela.** O `Card` faz
	`Interface:WaitForChild("TowerContainer")` no escopo do módulo, então o primeiro
	`require` dele cede a thread até a tela replicar — no primeiro segundo da sessão
	isso é uma espera de verdade. Chamando-o de dentro do `show`, o passo ficava
	suspenso entre o `self.Step = step` e o registro do `OnClosed` da fala, e é nessa
	fresta que dois avisos do servidor (que já não têm ordem garantida — ver o
	`TutorialStepDone`) se atropelavam.

	Quem paga a espera é o `resolveCardComponent`, uma vez, em thread própria. Até ele
	voltar, quem pergunta recebe `nil` e segue — o que ficou por dizer à hotbar está
	guardado em `DeckHidden` e `AllowedUnits`, e é reaplicado assim que o componente
	chega.
]=]
function TutorialStepController:cardComponent() : any
	return self.CardComponent
end

--[=[
	Resolve o componente `Card`, uma vez, e põe nele o que o roteiro já tinha pedido.

	A reaplicação no fim não é zelo: a hotbar pode ter sido escondida por uma fala, ou
	trancada por um passo, **antes** de o componente existir — e sem isto esse pedido
	se perderia em silêncio: a mão apareceria por cima da fala, ou a carta que o
	roteiro tranca continuaria equipável.
]=]
function TutorialStepController:resolveCardComponent()
	local library = script.Parent:FindFirstChild("UILibraryController")
	local components = library and library:FindFirstChild("Components")
	local card = components and components:FindFirstChild("Card")
	if not card then
		warn("[TutorialStepController]: nao achei o componente Card; a hotbar nao responde ao roteiro.")

		return
	end

	local success, component = pcall(require, card)
	if not success or type(component) ~= "table" then
		warn(`[TutorialStepController]: o componente Card nao carregou: {component}`)

		return
	end

	self.CardComponent = component

	if component.setHidden then
		component.setHidden(component, self.DeckHidden)
	end

	if component.setAllowed then
		component.setAllowed(component, self.AllowedUnits)
	end
end

function TutorialStepController:cardOf(unitName : string?) : GuiObject?
	if not unitName then
		return nil
	end

	local component = self:cardComponent()
	local getter = component and component.getCard

	return getter and getter(component, unitName)
end

--[=[
	Tira (ou devolve) a hotbar enquanto a fala do passo está na tela.

	A regra é da **fala**, e não do passo: caixa no ar, mão fora; caixa fechada, mão
	de volta. A fala vem primeiro justamente para ser lida, e carta acesa embaixo dela
	é convite a clicar antes de terminar de ler — ainda mais numa tela em que a caixa
	pode cair bem em cima da hotbar.

	Quem devolve é o próprio componente, e ele devolve **cada carta ao estado que ela
	tinha**: carta sem unidade sobrando continua apagada, em vez de acender junto.
]=]
function TutorialStepController:setCardsHidden(hidden : boolean)
	self.DeckHidden = hidden == true

	local component = self:cardComponent()
	local setter = component and component.setHidden

	if setter then
		setter(component, self.DeckHidden)
	end
end

--[=[
	Tranca a hotbar nas cartas que o passo permite.

	`nil` destranca tudo. A tranca fica guardada no componente, então ela sobrevive à
	remontagem da hotbar — troca de deck, respawn, e o recomeço de partida de quem
	venceu e foi jogar de novo.
]=]
function TutorialStepController:setAllowedCards(allowed : { [string] : boolean }?)
	-- Guardado aqui também: a hotbar recusa o clique sozinha (`Active = false`), mas
	-- quem responde ao `CardController` é o `AllowsCard`, e as duas respostas têm de
	-- sair da mesma lista para não discordarem uma da outra.
	self.AllowedUnits = allowed

	local component = self:cardComponent()
	local setter = component and component.setAllowed

	if setter then
		setter(component, allowed)
	end
end

--[=[
	As cartas que este passo deixa usar, ou `nil` quando ele não regula a hotbar.

	Passo de colocação com unidade pedida deixa só ela; o do fecho (`PlaceRest`)
	quer o deck inteiro no chão e não tranca nada.
]=]
function TutorialStepController:allowedOf(step : any) : { [string] : boolean }?
	--[[
		Quem manda é a lista que o servidor mandou com o passo: ela é a trava do deck,
		e vale **entre** os passos também. `nil` dela quer dizer deck solto — é o que
		chega no passo do fecho, na última wave.

		O passo de colocação pode apertar ainda mais (só a carta que ele pede), mas
		nunca afrouxar.
	]]
	local allowed = step and step.AllowedUnits

	if step and step.Kind == "Place" and step.Unit then
		return { [step.Unit] = true }
	end

	return allowed
end

--[=[
	Mostra o passo: fala, destaque e seta.
]=]
function TutorialStepController:show(step : any)
	self.Step = step

	--[[
		A trava vem **antes** da fala, e não com o destaque.

		A fala do passo é justamente o momento em que o jogador ainda não sabe onde
		clicar: deixá-lo solto enquanto lê a instrução é convidá-lo a descobrir por
		conta própria, que é o contrário do que o passo está fazendo. E a trava não
		atrapalha a leitura — a fala se passa por clique em qualquer lugar, não por um
		botão.
	]]
	self:gateFor(step)

	local dialog = self.Controllers.DialogController

	--[[
		A fala vem primeiro e sozinha; o destaque e a seta entram quando ela fecha.

		Os dois ao mesmo tempo disputam o olho do jogador: ele lê metade da
		instrução, vê a luz piscar na carta e vai clicar antes de saber o porquê. E
		há o caso pior — a fala fica **em cima** do que está sendo apontado.
	]]
	if dialog and step.Lines then
		print(`[DEBUG/Tutorial] passo "{step.Id}": mostrando a fala; o visual entra quando ela fechar.`)

		-- A mão sai enquanto a caixa está no ar, e volta no `showVisuals`.
		self:setCardsHidden(true)

		local shown = false

		local function reveal(reason : string)
			-- Outro passo pode ter aberto enquanto a fala corria, e aí o visual é o dele:
			-- acender o holofote deste aqui seria apontar o botão do passo anterior.
			if shown or self.Step ~= step then return end

			shown = true

			print(`[DEBUG/Tutorial] passo "{step.Id}": {reason}, mostrando destaque e seta.`)
			self:showVisuals(step)
		end

		local disconnect
		disconnect = dialog:OnClosed(function()
			if disconnect then
				disconnect()
			end

			reveal("fala fechou")
		end)

		--[[
			A rede: fala que não fecha não pode custar o destaque (ver `SPEECH_TIMEOUT`).
			O `reveal` é idempotente, então ela e o `OnClosed` podem correr os dois.
		]]
		task.delay(SPEECH_TIMEOUT, function()
			if shown or self.Step ~= step then return end

			warn(`[TutorialStepController]: a fala do passo "{step.Id}" nao fechou em {SPEECH_TIMEOUT}s; seguindo sem ela.`)

			if disconnect then
				disconnect()
			end

			reveal("a fala estourou o prazo")
		end)

		-- A fonte e o tamanho saem do `Speech`: a fala do passo é a mesma voz da
		-- oferta que trouxe o jogador até aqui.
		dialog:Play(step.Lines, Config.Speech({
			-- A UI fica: o passo pede para usar o HUD.
			HideUI = false,
			Blur = false,
			Duck = false,
			Auto = true,
		}))

		return
	end

	self:showVisuals(step)
end

--[=[
	O destaque e a seta do passo. Separado do `show` porque eles entram **depois**
	da fala, e não junto dela.
]=]
function TutorialStepController:showVisuals(step : any)
	-- A fala saiu (ou o passo não tinha nenhuma): a mão volta. É aqui, e não no fim
	-- da fala, porque passo sem fala chega direto neste ponto.
	self:setCardsHidden(false)

	self:setAllowedCards(self:allowedOf(step))

	--[[
		O que o destaque abraça: a carta da hotbar, quando o passo pede uma unidade,
		ou o caminho de tela que o passo declarar (o botão de 2x, por exemplo). O
		caminho vem do config para um passo novo não exigir código novo.
	]]
	local highlight = self.Controllers.HighlightController
	if highlight then
		local target = self:cardOf(step.Unit)

		if not target and step.Highlight then
			target = highlight:Find(step.Highlight)
		end

		--[[
			O alvo pode ainda não estar de pé quando o passo abre: o botão de Ready só
			fica visível quando a contagem do intervalo começa, e o passo dele abre um
			instante antes disso. `Show` recusa alvo invisível — e recusar calado
			deixaria o passo sem destaque nenhum —, então o caminho é **esperado** em vez
			de procurado uma vez só.
		]]
		if not (target and highlight:Show(target)) and step.Highlight then
			self:awaitHighlight(step)
		end

		self:refreshGate()
	end

	-- A carta da loja e a carta da mão só existem depois que a loja abre e depois
	-- que a compra acontece — as duas chegam **depois** do passo. Por isso elas são
	-- esperadas, em vez de procuradas uma vez só.
	if step.Kind == "Buy" or step.Kind == "Use" then
		self:awaitCard(step)
	end

	-- O menu de velocidade também nasce depois — e, ao contrário das cartas, some e
	-- volta quantas vezes o jogador quiser.
	if step.Kind == "Speed" then
		self:watchSpeedOptions(step)
	end

	-- Uma seta por lugar: o passo do fecho aponta os dois pontos livres de uma vez.
	local arrow = self.Controllers.ArrowController
	if arrow then
		if typeof(step.Position) == "Vector3" then
			table.insert(self.Arrows, arrow:Point(step.Position))
		end

		for _, position in (step.Positions or {}) do
			if typeof(position) == "Vector3" then
				table.insert(self.Arrows, arrow:Point(position))
			end
		end
	end
end

--[=[
	A whitelist do passo virando alvos que o `ButtonGateController` entende.

	Caminho de tela passa reto — quem resolve é o gate, e resolver lá é o que permite
	um caminho que só existe depois (a carta na mesa da loja) ser encontrado quando
	ela chegar. O que é traduzido aqui são os **apelidos**, porque a peça deles não
	tem caminho fixo: ela é clonada em runtime e o nome depende do passo.

	O apelido não vira instância aqui: vira **função**, que o gate chama a cada
	varredura. É o que faz o passo da compra funcionar — a carta na mesa não existe
	quando o passo abre, e um alvo resolvido agora seria `nil` para sempre, deixando a
	whitelist sem justamente o botão que o passo pede. Pelo mesmo caminho, o
	`@Highlight` acompanha o destaque quando ele escorrega do botão da loja para a
	carta (ver `awaitCard`), sem ninguém ter de reavisar o gate.
]=]
function TutorialStepController:gateTargets(step : any, list : { any }?) : { any }
	local out = {}

	local aliases = {
		["@Highlight"] = function()
			local highlight = self.Controllers.HighlightController

			return highlight and highlight:GetTarget() or nil
		end,

		["@Deck"] = function()
			local interface = PlayerGui:FindFirstChild("Interface")

			return interface and interface:FindFirstChild("TowerContainer") or nil
		end,

		["@Card"] = function()
			return self:cardOf(step.Unit)
		end,

		["@Hand"] = function()
			return if step.Card then self:handCardOf(step.Card) else nil
		end,

		["@Offer"] = function()
			return if step.Card then self:offerCardOf(step.Card) else nil
		end,

		--[=[
			As opções do menu de velocidade — **todas**, e não só a que o passo pede.

			O botão `Interface.Speed` não abre um painel: ele clona a si mesmo uma vez por
			degrau e pendura os clones **ao lado dele**, no mesmo pai (ver
			`SpeedController:createOption`). Eles não são filhos do botão, então liberar o
			botão não os libera — foi assim que o passo do 1,5x ficou com o menu abrindo e
			nenhuma opção clicável.

			Todas, porque escolher é comparar: o menu com uma opção viva e as outras mortas
			não ensina o que o botão faz. Qual delas o servidor aceita continua sendo conta
			dele; o que o passo espera é o degrau de `Index`, e é nele que o destaque
			pousa quando o menu abre (ver `watchSpeedOptions`).
		]=]
		["@SpeedOptions"] = function()
			local speed = self.Controllers.SpeedController

			return speed and speed:GetOptions() or nil
		end,
	}

	for _, entry in (list or {}) do
		if type(entry) ~= "string" then
			continue
		end

		if string.sub(entry, 1, 1) ~= "@" then
			table.insert(out, entry)

			continue
		end

		local alias = aliases[entry]

		if alias then
			table.insert(out, alias)
		else
			warn(`[TutorialStepController]: o passo "{step.Id}" pede o apelido "{entry}", que nao existe.`)
		end
	end

	return out
end

--[=[
	Tranca a tela no que este passo libera.

	Passo sem `Buttons` **não mexe na trava**: nem tranca, nem destrava. É o que faz
	um roteiro antigo continuar funcionando e o que mantém de pé a whitelist do passo
	anterior enquanto o passo novo não tem opinião sobre o assunto.

	A válvula só corre enquanto o passo está aberto — ver `onStepDone`.
]=]
function TutorialStepController:gateFor(step : any)
	local gate = self.Controllers.ButtonGateController
	if not gate or not step or not step.Buttons then return end

	local allow = self:gateTargets(step, step.Buttons)

	-- A caixa de fala entra em todo passo: botão de escolha que não aceita clique é
	-- uma conversa sem saída.
	for _, entry in (Config.ButtonGate.Always or {}) do
		table.insert(allow, entry)
	end

	gate:Lock({
		Allow = allow,
		Block = self:gateTargets(step, step.BlockedButtons),
		Ignore = Config.ButtonGate.Ignore,
		Release = step.ButtonRelease or Config.ButtonGate.Release,
	})
end

--[=[
	Segue o menu de velocidade com o destaque e com a whitelist.

	O botão `Interface.Speed` não abre um painel: ele **clona a si mesmo** uma vez por
	degrau e põe os clones ao lado dele. Enquanto o menu está fechado, o que o passo
	aponta é o botão; aberto, o que ele tem de apontar é o degrau que pede — apontar o
	botão que o jogador acabou de clicar não diz qual das três opções é a certa, e as
	três são iguais menos pela arte.

	As opções são criadas e destruídas de verdade, então quem avisa são o `ChildAdded`
	e o `ChildRemoved` do pai — não há sinal a escutar nem laço a manter de pé. O
	`defer` existe porque o clone nasce **antes** de o `SpeedController` escrever o
	degrau nele: apontar no mesmo quadro pegaria a opção sem atributo.

	Fechado o menu, o destaque volta ao botão. O jogador que abriu e clicou fora não
	pode ficar sem nada apontado no meio de um passo.
]=]
function TutorialStepController:watchSpeedOptions(step : any)
	local speed = self.Controllers.SpeedController
	local button = speed and speed:GetButton()
	local parent = button and button.Parent
	if not parent then return end

	local function update()
		if self.Step ~= step then return end

		local highlight = self.Controllers.HighlightController
		local target = speed:GetOption(step.Index) or button

		if highlight and target then
			highlight:Show(target)
		end

		-- A whitelist do passo pede `@SpeedOptions`, e a lista mudou: a conta do gate
		-- não espera o próximo botão nascer para ser refeita.
		self:refreshGate()
	end

	table.insert(self.StepConnections, parent.ChildAdded:Connect(function()
		task.defer(update)
	end))

	table.insert(self.StepConnections, parent.ChildRemoved:Connect(function()
		task.defer(update)
	end))
end

--[=[
	Manda o gate refazer a conta agora.

	Ele já se reaplica sozinho quando um botão nasce, mas o destaque mudar de alvo não
	cria botão nenhum — e o apelido `@Highlight` segue o destaque. Sem isto, o passo
	que libera "o que estiver destacado" continuaria liberando o alvo antigo.
]=]
function TutorialStepController:refreshGate()
	local gate = self.Controllers.ButtonGateController

	if gate then
		gate:Refresh()
	end
end

--[=[
	Espera a carta do passo aparecer na tela e a destaca.

	Passo de **compra** aponta a carta na mesa da loja; passo de **uso** aponta a
	carta que foi parar na hotbar. As duas nascem depois do passo abrir, e nenhuma
	das duas demora mais que o tempo de a loja subir — por isso a espera tem um
	orçamento curto e desiste calada: o passo continua valendo com a fala e o
	bloqueio, só sem o destaque.
]=]
function TutorialStepController:awaitCard(step : any)
	local highlight = self.Controllers.HighlightController
	if not highlight or not step.Card then return end

	task.spawn(function()
		for _ = 1, UI_WAIT_FRAMES do
			if self.Step ~= step then return end

			local target = if step.Kind == "Buy"
				then self:artOf(self:offerCardOf(step.Card))
				else self:artOf(self:handCardOf(step.Card))

			if target then
				highlight:Show(target)
				self:refreshGate()

				return
			end

			task.wait(0.1)
		end
	end)
end

--[=[
	Espera o botão que o passo aponta aparecer na tela e o destaca.

	É o irmão do `awaitCard` para caminho de tela. Desiste calada pelo mesmo motivo:
	o passo continua valendo com a fala, e um destaque que nunca chegou é melhor que
	um laço que nunca morre.
]=]
function TutorialStepController:awaitHighlight(step : any)
	local highlight = self.Controllers.HighlightController
	if not highlight or not step.Highlight then return end

	-- Alvo que nasce no fim de uma animação longa (o botão da tela de resultado)
	-- pede mais tempo que um botão de HUD, que já está lá.
	local frames = if typeof(step.HighlightWait) == "number"
		then math.max(1, math.round(step.HighlightWait * 10))
		else UI_WAIT_FRAMES

	task.spawn(function()
		for _ = 1, frames do
			if self.Step ~= step then return end

			local target = highlight:Find(step.Highlight)

			if target and highlight:Show(target) then
				self:refreshGate()

				return
			end

			task.wait(0.1)
		end

		warn(`[TutorialStepController]: o passo "{step.Id}" pede o destaque em "{step.Highlight}", que nao apareceu na tela.`)
	end)
end

--[=[
	A carta na mesa da loja de round.
]=]
function TutorialStepController:offerCardOf(cardId : string) : GuiObject?
	local shop = self.Controllers.RoundCardShopController

	return shop and shop:GetOfferCard(cardId) or nil
end

--[=[
	A carta dentro de um wrapper, quando o que se tem é o wrapper.

	O wrapper é a vaga do layout e o destaque não deve abraçá-lo; a carta é o filho
	que carrega a arte. Sem a carta dentro, o wrapper serve — é melhor apontar a
	vaga certa que não apontar nada.
]=]
function TutorialStepController:artOf(wrapper : GuiObject?) : GuiObject?
	if not wrapper then
		return nil
	end

	for _, child in wrapper:GetChildren() do
		if child:IsA("GuiButton") or child:IsA("ImageLabel") then
			return child
		end
	end

	return wrapper
end

--[=[
	A carta de round que já está na hotbar, esperando uso. O componente `Card` a
	nomeia `RoundCard_<Id>` quando ela entra.
]=]
function TutorialStepController:handCardOf(cardId : string) : GuiObject?
	local interface = PlayerGui:FindFirstChild("Interface")
	local container = interface and interface:FindFirstChild("TowerContainer")

	return container and container:FindFirstChild(`RoundCard_{cardId}`) or nil
end

--[=[
	Tira o passo da tela. Chamado quando ele é cumprido e quando outro abre por
	cima — um passo por vez, como no servidor.

	O que ele **não** desfaz são as duas travas: a do deck (`AllowedUnits`) e a de
	botões (`gateFor`). Elas são da partida, e não do passo — soltá-las aqui abriria o
	intervalo entre duas waves como a hora de sair do roteiro.
]=]
function TutorialStepController:clear()
	self.Step = nil

	self:clearVisuals()
end

--[=[
	Apaga o que o passo desenhou: o destaque, as setas e as escutas dele.

	Separado do `clear` porque o respawn precisa de metade dele — lá o passo continua
	aberto, e o que se quer é redesenhar por cima da tela nova, não esquecer o passo.
]=]
function TutorialStepController:clearVisuals()
	local highlight = self.Controllers.HighlightController
	if highlight then
		highlight:Hide()
	end

	for _, arrow in self.Arrows do
		arrow:Destroy()
	end

	table.clear(self.Arrows)

	for _, connection in self.StepConnections do
		connection:Disconnect()
	end

	table.clear(self.StepConnections)
end

--[=[
	O jogador renasceu: o passo aberto se redesenha na tela nova.

	Morrer não fecha passo nenhum — ele continua de pé no servidor, segurando a wave
	se for o caso —, mas leva junto tudo o que tem `ResetOnSpawn`: a caixa de fala, a
	tela de resultado, e no lobby a `HUD` inteira. Sem isto o jogador voltava para uma
	partida parada num passo que não aponta mais nada.

	**A fala tem precedência.** Se ela estiver voltando (ver
	`DialogController:IsResuming`), o destaque e as setas esperam o fim dela, como
	esperariam na primeira vez — acender o holofote por cima de uma instrução que está
	a um segundo de reaparecer é a mesma disputa pelo olho do jogador que o `show`
	evita.

	O destaque em si já se reencontra sozinho pelo caminho de nomes
	(`HighlightController:rebind`); o que só daqui pode vir são as **setas**, que
	apontam lugares do mapa e não têm dono na tela, e a **trava de botões**, que tem
	de ser refeita contra a árvore nova.
]=]
function TutorialStepController:reassert()
	local step = self.Step
	if not step then return end

	print(`[DEBUG/Tutorial] respawn com o passo "{step.Id}" aberto; redesenhando.`)

	-- A tela é outra: a whitelist tem de ser recontada contra ela.
	self:gateFor(step)

	local dialog = self.Controllers.DialogController
	if dialog and (dialog:IsOpen() or dialog:IsResuming()) then
		local disconnect
		disconnect = dialog:OnClosed(function()
			if disconnect then
				disconnect()
			end

			if self.Step ~= step then return end

			self:clearVisuals()
			self:showVisuals(step)
		end)

		return
	end

	self:clearVisuals()
	self:showVisuals(step)
end

--[[ API ]]

--[=[
	A hotbar pode pôr esta carta na mão agora?

	Sem passo aberto, tudo é permitido — fora do roteiro o tutorial não se mete. Com
	um passo de colocação aberto, só a carta dele.
]=]
function TutorialStepController:AllowsCard(unitName : string) : boolean
	--[[
		A trava do deck vem antes do passo e sobrevive a ele: entre a wave 1 e a 5 não
		há passo de colocação nenhum, e sem esta pergunta a carta trancada voltaria a
		ser equipável no intervalo. É a mesma conta do `CanPlace` no servidor.
	]]
	local allowed = self.AllowedUnits
	if allowed and not allowed[unitName] then
		return false
	end

	local step = self.Step

	if not step or step.Kind ~= "Place" or not step.Unit then
		return true
	end

	return unitName == step.Unit
end

--[=[
	Esta carta de round já pode ser usada?

	Espelha o `CanUse` do servidor para a mão não aceitar o clique de uma carta que
	o servidor recusaria — a diferença é que aqui o jogador não vê nada acontecer,
	em vez de ver a mira abrir e a carta voltar.
]=]
function TutorialStepController:AllowsCardUse(cardId : string) : boolean
	local step = self.Step

	if not step or step.Kind ~= "Use" or not step.Card then
		return not self.LockedCards or not self.LockedCards[cardId]
	end

	return cardId == step.Card
end

--[=[
	Esta partida é o tutorial?

	Quem pergunta é quem tem de se comportar diferente nela e não faz parte do
	roteiro — hoje o `ResultController`, que tranca o "PLAY AGAIN" da tela de fim.

	A resposta só é confiável depois do primeiro passo, que chega no intervalo antes
	da wave 1: qualquer tela de partida é bem depois disso.
]=]
function TutorialStepController:IsTutorial() : boolean
	return self.InTutorial == true
end

--[=[
	A loja de cartas de round pode ser fechada com um clique fora agora?

	**Na partida de tutorial, nunca.** O `RoundCardShopController` pergunta isto
	antes de dispensar a loja, e quem está aprendendo o que é a loja clica na mesa,
	no fundo e no que estiver por perto antes de escolher uma carta — fechar no
	primeiro desses cliques tira da tela justamente o que o passo mandou ler.

	A saída continua existindo e é a de sempre: o botão que abriu a loja a fecha.
	O que sai é só o "clicou em qualquer lugar, fechou".

	Fora do tutorial nada muda — a loja se dispensa como sempre se dispensou.
]=]
function TutorialStepController:AllowsShopDismiss() : boolean
	if self.InTutorial then
		return false
	end

	local step = self.Step

	return not (step and step.Kind == "Buy")
end

--[=[
	O passo aberto agora, para quem precisar decidir alguma coisa com ele.
]=]
function TutorialStepController:GetStep() : any
	return self.Step
end

--[[ CICLO DE VIDA ]]

function TutorialStepController:construct()
	--[[
		O respawn não fecha o passo, mas destrói metade do que ele desenhou. Ver
		`reassert`.

		`task.defer` porque o `CharacterAdded` chega **antes** de a `StarterGui` ter
		terminado de ser reclonada: procurar o botão do passo no mesmo quadro acharia a
		tela velha, ou nenhuma. Quem espera de verdade são o destaque e a fala, cada um
		com o prazo dele; aqui só se sai da frente do quadro do nascimento.
	]]
	Player.CharacterAdded:Connect(function()
		task.defer(function()
			self:reassert()
		end)
	end)

	Framework:Listen("TutorialStep", function(step : any)
		if type(step) ~= "table" then return end

		self.InTutorial = true

		if type(step.Locked) == "table" then
			self.LockedCards = step.Locked
		end

		self:clear()
		self:show(step)
	end)

	Framework:Listen("TutorialStepDone", function(id : any)
		local step = self.Step

		--[=[
			O fim de **um** passo não pode apagar o seguinte.

			Os dois avisos saem do servidor com microssegundos de diferença — o passo do
			Ready fecha quando a contagem acaba, e a wave 1 abre o passo do Slingshot no
			quadro seguinte — e eles viajam em **eventos diferentes**, que o `Me` (Warp)
			enfileira separados: a ordem de chegada no cliente não é garantida.

			Sem conferir o id, o "acabou o Ready" chegando atrasado limpava o passo que
			já estava aberto: `self.Step` virava `nil`, e quando a fala do Slingshot
			fechava o `show` desistia sozinho — fala na tela, nenhum destaque, nenhuma
			seta e a hotbar sem a trava do passo.
		]=]
		if step and id ~= nil and step.Id ~= id then
			print(`[DEBUG/Tutorial] "{id}" terminou depois de "{step.Id}" abrir; o passo aberto fica.`)

			return
		end

		--[[
			Passo cumprido tira o **prazo** da válvula, e não a trava.

			A válvula existe para o passo que não reconheceu o que o jogador fez. Passo
			cumprido não é esse caso: o que vem depois dele é a wave correndo, com nada a
			clicar até o passo seguinte, e deixar o prazo correndo ali devolveria a tela
			inteira no meio do roteiro por o jogador ter esperado.
		]]
		local gate = self.Controllers.ButtonGateController
		if gate then
			gate:HoldRelease()
		end

		-- Passo cumprido destranca a carta dele: daí para a frente ela é uma carta
		-- como outra qualquer.
		if step and step.Kind == "Use" and step.Card then
			self.LockedCards[step.Card] = nil
		end

		self:clear()
	end)
end

function TutorialStepController:start()
end

function TutorialStepController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	-- Em thread própria porque ele dorme (ver `cardComponent`), e o `init` do
	-- framework não pode dormir: os controllers seguintes esperariam por este.
	task.spawn(function()
		self:resolveCardComponent()
	end)

	self:construct()
end

return TutorialStepController
