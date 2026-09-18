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
	     `ArrowController`.

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

local TutorialStepController = {
	Controllers = {
		DialogController = {},
		HighlightController = {},
		ArrowController = {},
		RoundCardShopController = {},
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

-- A mão está fora da tela por ordem do roteiro? Ver `setCardsHidden` e `WantsDeck`.
TutorialStepController.DeckHidden = false

-- As cartas que o roteiro tranca até o passo delas: `{ [Id] = true }`. O servidor
-- manda a lista junto do passo de compra, e é ela que a mão consulta.
TutorialStepController.LockedCards = {}

-- As setas do passo. São várias no fecho, que aponta os dois pontos livres.
TutorialStepController.Arrows = {}

--[[ INTERNAL ]]

--[=[
	A carta da hotbar, como instância, para o destaque poder abraçá-la.

	Vem do componente `Card` do `UILibraryController` — é ele que clona os
	`CardWrapper` e guarda cada um por nome de unidade. Requerer o componente direto
	(e não passar pelo `doComponent`, que roda numa thread e não devolve nada) é o
	único jeito de **pegar** algo dele.
]=]
function TutorialStepController:cardComponent() : any
	local library = script.Parent:FindFirstChild("UILibraryController")
	local components = library and library:FindFirstChild("Components")
	local card = components and components:FindFirstChild("Card")

	return card and require(card) :: any or nil
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
	Esconde (ou devolve) a hotbar enquanto a fala está na tela.

	A fala vem primeiro justamente para ser lida; carta acesa embaixo dela é convite
	a clicar antes de terminar de ler. Quem devolve é o próprio componente, e ele
	devolve **cada carta ao estado que ela tinha** — carta sem unidade sobrando
	continua apagada, em vez de acender junto.
]=]
function TutorialStepController:setCardsHidden(hidden : boolean)
	-- Guardado porque a pergunta sobrevive ao passo: entre um passo e outro é este
	-- valor que responde ao `WantsDeck`, e não o passo aberto (que não há).
	self.DeckHidden = hidden == true

	local component = self:cardComponent()
	local setter = component and component.setHidden

	if setter then
		setter(component, hidden)
	end
end

--[=[
	Tranca a hotbar nas cartas que o passo permite.

	`nil` destranca tudo. A tranca fica guardada no componente, então ela sobrevive à
	remontagem da hotbar — troca de deck, respawn, e o recomeço de partida de quem
	venceu e foi jogar de novo.
]=]
function TutorialStepController:setAllowedCards(allowed : { [string] : boolean }?)
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

	local dialog = self.Controllers.DialogController

	--[[
		A fala vem primeiro e sozinha; o destaque e a seta entram quando ela fecha.

		Os dois ao mesmo tempo disputam o olho do jogador: ele lê metade da
		instrução, vê a luz piscar na carta e vai clicar antes de saber o porquê. E
		há o caso pior — a fala fica **em cima** do que está sendo apontado.
	]]
	if dialog and step.Lines then
		print(`[DEBUG/Tutorial] passo "{step.Id}": mostrando a fala; o visual entra quando ela fechar.`)

		self:setCardsHidden(true)

		local disconnect
		disconnect = dialog:OnClosed(function()
			if disconnect then
				disconnect()
			end

			--[[
				Outro passo pode ter aberto enquanto a fala corria, e aí quem manda na
				hotbar é ele. Devolvê-la daqui a acenderia por cima da fala nova; quem a
				devolve quando não sobra passo nenhum é o `clear`.
			]]
			if self.Step ~= step then return end

			print(`[DEBUG/Tutorial] passo "{step.Id}": fala fechou, mostrando destaque e seta.`)
			self:showVisuals(step)
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
	-- A mão volta (ou fica fora) conforme o passo: é aqui, e não no fim da fala,
	-- porque passo sem fala nenhuma chega direto neste ponto.
	self:setCardsHidden(not self:needsDeck(step))

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
	end

	-- A carta da loja e a carta da mão só existem depois que a loja abre e depois
	-- que a compra acontece — as duas chegam **depois** do passo. Por isso elas são
	-- esperadas, em vez de procuradas uma vez só.
	if step.Kind == "Buy" or step.Kind == "Use" then
		self:awaitCard(step)
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
	Este passo precisa da hotbar na tela?

	`Deck = false` no config diz que não — o botão de Ready, a compra na loja e o 2x
	não pedem carta nenhuma, e a mão acesa embaixo deles só disputa o olho de quem
	está aprendendo onde clicar.

	O padrão é `true`: passo que não declara nada segue com o deck na tela.
]=]
function TutorialStepController:needsDeck(step : any) : boolean
	return not (step and step.Deck == false)
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
]=]
function TutorialStepController:clear(deckHidden : boolean?)
	self.Step = nil

	--[[
		A hotbar tem um dono por vez, e `nil` quer dizer "não mexa": é o que o passo
		**novo** passa, porque ele decide a mão um instante depois e devolvê-la aqui
		só para escondê-la de novo a faria piscar entre um passo e outro.

		A **trava do deck**, ao contrário, fica: ela é da partida e não do passo, e
		destravar aqui devolveria as cartas no intervalo entre uma wave e outra.
	]]
	if deckHidden ~= nil then
		self:setCardsHidden(deckHidden)
	end

	local highlight = self.Controllers.HighlightController
	if highlight then
		highlight:Hide()
	end

	for _, arrow in self.Arrows do
		arrow:Destroy()
	end

	table.clear(self.Arrows)
end

--[[ API ]]

--[=[
	A hotbar pode pôr esta carta na mão agora?

	Sem passo aberto, tudo é permitido — fora do roteiro o tutorial não se mete. Com
	um passo de colocação aberto, só a carta dele.
]=]
function TutorialStepController:AllowsCard(unitName : string) : boolean
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
	A hotbar pode estar na tela agora?

	Quem pergunta é o `RoundCardShopController`, ao fechar a loja: ele devolve a mão
	que escondeu ao abrir, e sem esta pergunta a devolveria por cima de um passo que
	a quer fora da tela — o da compra, justamente o passo em que a loja abre e fecha.

	A resposta é o último estado que o roteiro pediu, e não o passo aberto: entre
	um passo e outro não há passo nenhum, e a mão que a Slingshot levou embora
	(`HidesDeck`) não pode voltar só porque a loja fechou no meio do caminho.

	Fora do tutorial, sempre sim — lá a hotbar não é assunto nosso.
]=]
function TutorialStepController:WantsDeck() : boolean
	if not self.InTutorial then
		return true
	end

	return not self.DeckHidden
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

		-- Passo cumprido destranca a carta dele: daí para a frente ela é uma carta
		-- como outra qualquer.
		if step and step.Kind == "Use" and step.Card then
			self.LockedCards[step.Card] = nil
		end

		--[[
			Passo cumprido pode levar a mão embora: `HidesDeck` é o que a Slingshot
			colocada faz. A carta saiu para o mapa, não sobrou nada para arrastar até a
			wave seguinte, e a hotbar vazia no canto só continuaria pedindo clique.

			Ela volta sozinha no próximo passo que precisar dela.
		]]
		self:clear(step ~= nil and step.HidesDeck == true)
	end)
end

function TutorialStepController:start()
end

function TutorialStepController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return TutorialStepController
