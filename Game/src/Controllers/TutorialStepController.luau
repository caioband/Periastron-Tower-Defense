local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

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

-- Quanto esperar a carta do passo aparecer na tela, em décimos de segundo. Ver
-- `awaitCard`.
local CARD_WAIT_FRAMES = 50

local TutorialStepController = {
	Controllers = {
		DialogController = {},
		HighlightController = {},
		ArrowController = {},
		RoundCardShopController = {},
	}
}

TutorialStepController.Step = nil :: any

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

			self:setCardsHidden(false)

			-- Outro passo pode ter aberto enquanto a fala corria.
			if self.Step ~= step then return end

			print(`[DEBUG/Tutorial] passo "{step.Id}": fala fechou, mostrando destaque e seta.`)
			self:showVisuals(step)
		end)

		dialog:Play(step.Lines, {
			-- A UI fica: o passo pede para usar o HUD.
			HideUI = false,
			Blur = false,
			Duck = false,
			Auto = true,
		})

		return
	end

	self:showVisuals(step)
end

--[=[
	O destaque e a seta do passo. Separado do `show` porque eles entram **depois**
	da fala, e não junto dela.
]=]
function TutorialStepController:showVisuals(step : any)
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

		if target then
			highlight:Show(target)
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
		for _ = 1, CARD_WAIT_FRAMES do
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
function TutorialStepController:clear()
	self.Step = nil

	-- Passo que morre com a fala ainda aberta não pode levar a hotbar junto. A
	-- **trança do deck**, ao contrário, fica: ela é da partida e não do passo, e
	-- destravar aqui devolveria as cartas no intervalo entre uma wave e outra.
	self:setCardsHidden(false)

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
	A loja de cartas de round pode ser fechada com um clique fora agora?

	Não, enquanto o passo pede uma compra: o `RoundCardShopController` pergunta isto
	antes de dispensar a loja. É a mesma divisão de sempre — aqui é educação de
	interface, e quem recusa a compra errada é o servidor.
]=]
function TutorialStepController:AllowsShopDismiss() : boolean
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

		if type(step.Locked) == "table" then
			self.LockedCards = step.Locked
		end

		self:clear()
		self:show(step)
	end)

	Framework:Listen("TutorialStepDone", function(id : any)
		-- Passo cumprido destranca a carta dele: daí para a frente ela é uma carta
		-- como outra qualquer.
		local step = self.Step
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

	self:construct()
end

return TutorialStepController
