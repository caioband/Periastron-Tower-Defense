local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

local RoundCardConfig = SharedConfig.RoundCardConfig

local GUI = RoundCardConfig.Gui
local ANIM = RoundCardConfig.Animation

local WAIT_TIMEOUT = 60

-- O som de carta, o mesmo do painel de deck e da hotbar.
local CARD_SOUND = "CardFlip"

--[=[
	A loja de cartas de round, do lado da tela.

	Quem decide **quando** ela abre, **quais** cartas saem e **se** a compra vale e
	o `CardShopService`. Daqui sai so o desenho: o botao que entra pela beirada, o
	escurecido de tela cheia, as tres cartas caindo e a carta comprada indo parar
	na hotbar.

	O caminho de uma oferta:

		1. o servidor manda `RoundCardState` com um `token` e tres ids de carta; o
		   botao `RCSFrame` entra pela direita;
		2. o clique no `CardShop` escurece a tela, apaga a hotbar e desenha as tres
		   cartas, uma a cada `CardStagger`;
		3. o clique numa carta pede a compra e recolhe a loja na hora; a carta so
		   entra na hotbar quando o `RoundCardBought` confirma;
		4. o clique na carta da hotbar pede o uso, e ela some quando o
		   `RoundCardUsed` confirma.

	**Nada e desenhado por conta propria.** A carta nao entra no deck no clique e
	nao sai dele no uso: as duas coisas esperam a confirmacao do servidor, que e
	quem tem o dinheiro e o estoque. Recusado, o `RoundCardState` que chega em
	seguida devolve a tela ao que o servidor sabe -- e a oferta reaparece.

	**A carta e um clone do molde autorado**, e o molde e tirado da tela na primeira
	vez que ele e preciso (como o `Components/Card` faz com o `CardWrapper` da
	hotbar). As transparencias de destino sao lidas de cada clone recem-feito, antes
	de qualquer animacao: "voltar ao original" e literal, e repintar no Studio basta.
]=]
local RoundCardShopController = {
	Controllers = {
		MusicController = {},
		UILibraryController = {},
	},
}

--[[ INTERNAL ]]

--[=[
	Que propriedades de transparencia cada peca tem.

	`GuiObject.Transparency` fica de fora de proposito: e apelido de
	`BackgroundTransparency`, e os dois tweens brigariam pela mesma propriedade.
]=]
local function fadeProperties(object : Instance) : { string }?
	if object:IsA("UIStroke") then
		return { "Transparency" }
	elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
		return { "BackgroundTransparency", "ImageTransparency" }
	elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
		return { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" }
	elseif object:IsA("GuiObject") then
		return { "BackgroundTransparency" }
	end

	--[[
		O `UIShadow` nao aparece na lista de classes acima porque nao e `GuiObject`
		nem `UIStroke`; ele entra por aqui, e junto com ele qualquer componente de UI
		novo que tenha um `Transparency` proprio.

		So vale se o `Transparency` for **numero**: o do `UIGradient` e uma
		`NumberSequence`, e tweenar aquilo como se fosse um numero derrubaria o
		gradiente inteiro da carta.
	]]
	local ok, value = pcall(function()
		return (object :: any).Transparency
	end)

	return if ok and typeof(value) == "number" then { "Transparency" } else nil
end

--[=[
	Todo par (peca, propriedade) com o valor que o designer deixou, varrendo os
	**descendentes** de `root` -- o proprio `root` fica de fora porque quem cuida
	dele e a primeira metade da animacao (a queda com a imagem aparecendo).
]=]
local function captureFades(root : Instance)
	local fades = {}

	for _, descendant in root:GetDescendants() do
		local properties = fadeProperties(descendant)
		if not properties then
			continue
		end

		local values = {}
		for _, property in properties do
			values[property] = (descendant :: any)[property]
		end

		table.insert(fades, { Object = descendant, Values = values })
	end

	return fades
end

--- Escreve a transparencia de todos os descendentes de uma vez.
local function applyFades(fades, progress : number, time : number?)
	local info = time and TweenInfo.new(time, ANIM.CardEasing, ANIM.CardDirection)

	for _, fade in fades do
		local object = fade.Object :: any
		if not object.Parent then continue end

		local goal = {}
		for property, authored in fade.Values do
			goal[property] = 1 + (authored - 1) * progress
		end

		if not info then
			for property, value in goal do
				object[property] = value
			end
			continue
		end

		-- Propriedade que o TweenService recusa salta direto, em vez de derrubar a
		-- animacao das outras pecas junto.
		local ok = pcall(function()
			TweenService:Create(object, info, goal):Play()
		end)

		if not ok then
			for property, value in goal do
				object[property] = value
			end
		end
	end
end

function RoundCardShopController:_playSound(name : string)
	local music = self.Controllers.MusicController
	if music then
		music:PlaySFX(name)
	end
end

--[=[
	Fala com a hotbar.

	Quem desenha a mao do jogador e o componente `Card`
	(`UILibraryController/Components/Card.luau`), e e ele quem cuida do arco, da
	escala e da ordem da fila -- inclusive das cartas de round, depois que elas
	entram por `addRound`. Daqui so saem as tres ordens: poe, tira e esconde.
]=]
function RoundCardShopController:_deck(func : string, ...)
	local library = self.Controllers.UILibraryController
	if not library then return end

	library:doComponent("Card", func, ...)
end

--[[ O BOTAO DA BEIRADA ]]

--- Onde o `RCSFrame` fica quando esta fora da tela.
function RoundCardShopController:_hiddenPosition() : UDim2
	local base = self.BasePosition

	return UDim2.new(ANIM.HiddenX, base.X.Offset, base.Y.Scale, base.Y.Offset)
end

--[=[
	Poe o botao na tela: ele nasce em `HiddenX` e corre ate o X autorado.

	O `Circular` chega devagar no fim -- e o que da o encaixe na beirada, em vez de
	o botao parar seco no lugar.
]=]
function RoundCardShopController:_showFrame()
	local frame = self.Frame
	if not frame or self.FrameShown then return end

	self.FrameShown = true
	self.FrameToken += 1

	self.FrameMaid:DoCleaning()

	frame.Position = self:_hiddenPosition()
	frame.Visible = true

	local tween = TweenService:Create(
		frame,
		TweenInfo.new(ANIM.SlideIn, ANIM.SlideEasing, Enum.EasingDirection.Out),
		{ Position = self.BasePosition }
	)

	self.FrameMaid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
end

--- Recolhe o botao para fora da tela e o desliga quando ele termina de sair.
function RoundCardShopController:_hideFrame()
	local frame = self.Frame
	if not frame or not self.FrameShown then return end

	self.FrameShown = false
	self.FrameToken += 1
	local token = self.FrameToken

	self.FrameMaid:DoCleaning()

	local tween = TweenService:Create(
		frame,
		TweenInfo.new(ANIM.SlideOut, ANIM.SlideEasing, Enum.EasingDirection.In),
		{ Position = self:_hiddenPosition() }
	)

	self.FrameMaid:GiveTask(function()
		tween:Cancel()
	end)

	tween.Completed:Connect(function(state : Enum.PlaybackState)
		-- Uma oferta nova durante a saida manda: o botao que esta na tela agora e o
		-- dela, e desligar aqui apagaria uma loja que acabou de abrir.
		if state ~= Enum.PlaybackState.Completed or self.FrameToken ~= token then return end

		frame.Visible = false
	end)

	tween:Play()
end

--[[ A HOTBAR DO JOGADOR ]]

--[=[
	Apaga (ou devolve) as cartas do jogador enquanto a loja esta aberta.

	Quem esconde e o proprio componente `Card`, e nao um `Visible` escrito daqui: o
	`Visible` de cada wrapper ja tem dono la (carta sem unidade sobrando fica fora
	da tela por conta propria), e apagar por fora acenderia de volta, na saida da
	loja, uma carta que o deck tinha derrubado.

	Some por dentro, e nao pelo `Visible` do `TowerContainer`: quem manda no
	container e o `DifficultyController` (a hotbar so aparece com a dificuldade
	decidida), e duas maos no mesmo interruptor acabariam com a hotbar sumindo no
	meio da partida.
]=]
function RoundCardShopController:_setDeckHidden(hidden : boolean)
	self:_deck("setHidden", hidden)
end

--[[ AS CARTAS DA LOJA ]]

--[=[
	O molde de uma carta, tirado da tela na primeira vez que alguem precisa dele.

	O `CardWrapper` que veio autorado na fileira nao e uma carta: e o desenho de
	uma. Ele sai de la junto, entao o que fica na tela e sempre o que o servidor
	sorteou.
]=]
function RoundCardShopController:_template() : Frame?
	if self.Template then
		return self.Template
	end

	local authored = self.Row and self.Row:FindFirstChild(GUI.Wrapper)
	if not authored then
		warn(`[RoundCardShopController]: nao achei o {GUI.Wrapper} autorado em {GUI.Row}.`)
		return nil
	end

	self.Template = authored:Clone()
	authored:Destroy()

	return self.Template
end

--[=[
	Escreve os textos e a arte de uma carta no clone. `showPrice` e false para a
	carta que ja foi paga e esta indo para a hotbar.
]=]
function RoundCardShopController:_writeCard(card : GuiObject, definition, showPrice : boolean)
	local title = card:FindFirstChild(GUI.Title)
	if title and title:IsA("TextLabel") then
		title.Text = definition.Title or definition.Id
	end

	local description = card:FindFirstChild(GUI.Description)
	if description and description:IsA("TextLabel") then
		description.Text = definition.Description or ""
	end

	local price = card:FindFirstChild(GUI.Price)
	if price then
		price.Visible = showPrice

		local label = price:FindFirstChild(GUI.PriceLabel)
		if label and label:IsA("TextLabel") then
			label.Text = "$" .. tostring(definition.Price or 0)
		end
	end

	-- Carta sem arte propria fica com a autorada no molde: carta com a arte errada
	-- e melhor do que carta invisivel.
	if definition.Image and (card:IsA("ImageLabel") or card:IsA("ImageButton")) then
		card.Image = definition.Image
	end
end

--- Tira as cartas que estao na fileira. A da compra ja foi clonada antes disto.
function RoundCardShopController:_clearRow()
	self.RowMaid:DoCleaning()
end

--[=[
	Desenha as tres cartas da oferta.

	Cada carta tem duas metades, nesta ordem: ela **cai** de `DropOffset` alturas
	acima do lugar dela enquanto a imagem sai de transparente (`CardDrop`), e so
	quando isso termina o conteudo -- titulo, descricao, preco, contornos, sombra --
	sobe de 1 ate o valor autorado (`CardReveal`).

	As tres nao saem juntas: a segunda comeca `CardStagger` depois da primeira, e a
	terceira `CardStagger` depois da segunda. O atraso e um `task.delay` guardado no
	maid da fileira, entao fechar a loja no meio cancela o que ainda nao comecou.
]=]
function RoundCardShopController:_renderCards()
	local row = self.Row
	local offer = self.Offer
	if not row or not offer then return end

	local template = self:_template()
	if not template then return end

	self:_clearRow()

	for index, cardId in offer.cards do
		local definition = RoundCardConfig.Get(cardId)
		if not definition then
			warn(`[RoundCardShopController]: a oferta trouxe a carta '{tostring(cardId)}', que nao esta no config.`)
			continue
		end

		local wrapper = template:Clone()
		wrapper.Name = cardId
		wrapper.LayoutOrder = index

		local card = wrapper:FindFirstChild(GUI.Card)
		if not card or not card:IsA("GuiObject") then
			wrapper:Destroy()
			continue
		end

		self:_writeCard(card, definition, true)

		--[[
			Lido do clone intocado: e para ca que a segunda metade da animacao leva
			tudo de volta. Precisa vir **antes** de qualquer escrita de transparencia,
			senao o alvo seria o estado escondido.
		]]
		local fades = captureFades(card)
		local basePosition = card.Position

		-- Estado de partida: a carta acima do lugar dela, a imagem e o conteudo
		-- transparentes.
		card.Position = UDim2.new(
			basePosition.X.Scale, basePosition.X.Offset,
			basePosition.Y.Scale - ANIM.DropOffset, basePosition.Y.Offset
		)

		if card:IsA("ImageLabel") or card:IsA("ImageButton") then
			card.ImageTransparency = 1
		end

		applyFades(fades, 0)

		wrapper.Parent = row
		self.RowMaid:GiveTask(wrapper)

		--[[
			A carta so aceita clique depois de comecar a cair. Ela ja existe na tela
			desde o `Parent`, transparente e fora do lugar, e sem isto a terceira carta
			-- que so entra um segundo depois -- poderia ser comprada enquanto ainda
			nao ha nada para o jogador ver.
		]]
		local ready = false

		if card:IsA("GuiButton") then
			self.RowMaid:GiveTask(card.Activated:Connect(function()
				if not ready then return end

				self:_buy(cardId)
			end))
		end

		local delayed = task.delay((index - 1) * ANIM.CardStagger, function()
			if not wrapper.Parent then return end

			ready = true

			local dropInfo = TweenInfo.new(ANIM.CardDrop, ANIM.CardEasing, ANIM.CardDirection)
			local goal : { [string] : any } = { Position = basePosition }

			if card:IsA("ImageLabel") or card:IsA("ImageButton") then
				goal.ImageTransparency = 0
			end

			local drop = TweenService:Create(card, dropInfo, goal)

			drop.Completed:Connect(function(state : Enum.PlaybackState)
				if state ~= Enum.PlaybackState.Completed or not wrapper.Parent then return end

				applyFades(fades, 1, ANIM.CardReveal)
			end)

			drop:Play()
		end)

		self.RowMaid:GiveTask(function()
			pcall(task.cancel, delayed)
		end)
	end
end

--[[ ABRIR E FECHAR ]]

--[=[
	Abre a aba da loja: a tela escurece, a hotbar apaga e, quando o escurecido
	termina, as cartas comecam a cair.

	As cartas so entram depois do fundo de proposito -- a queda delas e contra o
	escuro, e desenha-las durante o fade as poria aparecendo por cima da partida.
]=]
function RoundCardShopController:_openShop()
	local background = self.Background
	if not background or self.ShopOpen or not self.Offer then return end

	self.ShopOpen = true
	self.OpenToken += 1
	local token = self.OpenToken

	self:_setDeckHidden(true)
	self:_clearRow()

	background.BackgroundTransparency = 1
	background.Visible = true

	local tween = TweenService:Create(
		background,
		TweenInfo.new(ANIM.BackgroundFade, ANIM.CardEasing, ANIM.CardDirection),
		{ BackgroundTransparency = self.BackgroundTarget }
	)

	tween.Completed:Connect(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed or self.OpenToken ~= token then return end

		self:_renderCards()
	end)

	tween:Play()
end

--[=[
	Fecha a aba: o escurecido some na hora (e o que a compra pede) e a hotbar volta.

	Sem tween de saida de proposito: a compra ja tem a animacao dela, que e o botao
	da beirada recolhendo, e um segundo fade por cima disso so atrasaria o jogador
	de voltar a partida.
]=]
function RoundCardShopController:_closeShop()
	if not self.ShopOpen then return end

	self.ShopOpen = false
	self.OpenToken += 1

	self:_clearRow()

	if self.Background then
		self.Background.Visible = false
	end

	self:_setDeckHidden(false)
end

--[[ COMPRAR E USAR ]]

--[=[
	Pede a compra de uma carta.

	Sem dinheiro, o clique nao vira pedido: o servidor recusaria do mesmo jeito
	(ele e quem tem o caixa de verdade), e o que se evita e a loja fechar e
	reabrir sozinha por causa de um clique que nunca ia dar certo.

	Dando certo, a loja recolhe **na hora** -- e a resposta ao clique, e ela nao
	pode esperar a rede. A carta, essa sim, so entra na hotbar quando o
	`RoundCardBought` confirma: quem tem o estoque e o servidor.
]=]
function RoundCardShopController:_buy(cardId : string)
	local offer = self.Offer
	if not offer then return end

	local definition = RoundCardConfig.Get(cardId)
	if not definition then return end

	if self.Cash < (definition.Price or 0) then return end

	Framework:Fire("BuyRoundCard", offer.token, cardId)

	self:_playSound(CARD_SOUND)

	self.Offer = nil
	self:_closeShop()
	self:_hideFrame()
end

--[=[
	Poe na hotbar a carta que o servidor confirmou.

	Daqui sai so a **aparencia**: um clone do mesmo molde da loja, no tamanho da
	hotbar e sem a placa de preco -- no deck a carta ja foi paga. O que ela faz na
	mao e do componente `Card`: a partir do `addRound` ela e uma carta da hotbar
	como qualquer outra, cai no arco, cresce no hover, e empurrada pelas vizinhas e
	apaga quando outra carta e escolhida.
]=]
function RoundCardShopController:_addToDeck(uid : string, cardId : string)
	if typeof(uid) ~= "string" or self.DeckCards[uid] then return end

	local template = self:_template()
	if not template then return end

	local definition = RoundCardConfig.Get(cardId)
	if not definition then return end

	local wrapper = template:Clone()
	wrapper.Name = "RoundCard_" .. cardId
	wrapper.Size = RoundCardConfig.DeckCardSize

	local card = wrapper:FindFirstChild(GUI.Card)
	if not card or not card:IsA("GuiObject") then
		wrapper:Destroy()
		return
	end

	self:_writeCard(card, definition, false)

	self.DeckCards[uid] = true

	self:_deck("addRound", uid, wrapper, function()
		--[[
			Um uso por carta, e quem gasta e o servidor. O trinco local existe para o
			clique duplo nao virar dois pedidos: o segundo seria recusado, mas o
			primeiro ja teria sumido com a carta e o jogador veria um erro no log por
			algo que ele nao fez de errado.
		]]
		if self.UsePending[uid] then return end
		self.UsePending[uid] = true

		Framework:Fire("UseRoundCard", uid)
		self:_playSound(CARD_SOUND)
	end)
end

--[=[
	Tira da hotbar a carta que o servidor deu por usada (ou por perdida). Quem faz a
	carta cair para fora e fecha a vaga e o componente.
]=]
function RoundCardShopController:_removeFromDeck(uid : string)
	if not self.DeckCards[uid] then return end

	self.DeckCards[uid] = nil
	self.UsePending[uid] = nil

	self:_deck("removeRound", uid)
end

--[[ ESTADO DO SERVIDOR ]]

--[=[
	O estado inteiro da loja, do jeito que o servidor o ve: a oferta aberta e as
	cartas na mao.

	E ele quem reconstroi a tela de quem entrou no meio da partida, de quem
	recarregou a interface e de quem teve uma compra recusada. Por isso a hotbar e
	reconciliada nos dois sentidos -- o que o servidor tem e nao esta na tela entra,
	e o que esta na tela e o servidor nao tem sai.
]=]
function RoundCardShopController:_applyState(state)
	if typeof(state) ~= "table" then return end

	local owned = {}
	for _, entry in (state.owned or {}) do
		if typeof(entry) == "table" and typeof(entry.Uid) == "string" then
			owned[entry.Uid] = entry.Id
			self:_addToDeck(entry.Uid, entry.Id)
		end
	end

	for uid, _ in self.DeckCards do
		if not owned[uid] then
			self:_removeFromDeck(uid)
		end
	end

	local offer = if state.token and state.cards then { token = state.token, cards = state.cards } else nil
	local sameOffer = self.Offer and offer and self.Offer.token == offer.token

	self.Offer = offer

	if not offer then
		self:_closeShop()
		self:_hideFrame()
		return
	end

	self:_showFrame()

	-- Oferta nova com a aba ja aberta (a wave virou enquanto o jogador olhava as
	-- cartas): as cartas na tela sao da oferta velha e precisam ser redesenhadas.
	if self.ShopOpen and not sameOffer then
		self:_renderCards()
	end
end

--[[ BIND ]]

function RoundCardShopController:_bind() : boolean
	local screen = PlayerGui:WaitForChild(GUI.ScreenGui, WAIT_TIMEOUT)
	if not screen then
		warn(`[RoundCardShopController]: nao achei a {GUI.ScreenGui}.`)
		return false
	end

	local frame = screen:WaitForChild(GUI.Frame, WAIT_TIMEOUT)
	local background = screen:WaitForChild(GUI.Background, WAIT_TIMEOUT)

	if not frame or not background then
		warn(`[RoundCardShopController]: a {GUI.ScreenGui} nao tem {GUI.Frame} e {GUI.Background}.`)
		return false
	end

	self.Frame = frame
	self.BasePosition = frame.Position
	self.Background = background
	self.BackgroundTarget = background.BackgroundTransparency
	self.Row = background:WaitForChild(GUI.Row, WAIT_TIMEOUT)

	frame.Visible = false
	frame.Position = self:_hiddenPosition()
	background.Visible = false

	local button = frame:FindFirstChild(GUI.Button)
	if button and button:IsA("GuiButton") then
		button.Activated:Connect(function()
			if self.ShopOpen then
				self:_closeShop()
				return
			end

			self:_openShop()
		end)
	else
		warn(`[RoundCardShopController]: o {GUI.Frame} nao tem o botao {GUI.Button}.`)
	end

	return true
end

--[[ CICLO DE VIDA ]]

function RoundCardShopController:construct()
	--[[
		Os `Listen` entram antes do bind porque o bind espera a GUI replicar: um
		estado que chegasse durante a espera se perderia, e a loja so voltaria a
		aparecer na proxima wave de loja.
	]]
	Framework:Listen("RoundCardState", function(state)
		self:_applyState(state)
	end)

	Framework:Listen("RoundCardBought", function(payload)
		if typeof(payload) ~= "table" then return end

		self.Offer = nil
		self:_closeShop()
		self:_hideFrame()
		self:_addToDeck(payload.uid, payload.id)
	end)

	Framework:Listen("RoundCardUsed", function(payload)
		if typeof(payload) ~= "table" then return end

		self:_removeFromDeck(payload.uid)
	end)

	-- O preco esta escrito na carta e o caixa da partida e quem paga: sem isto o
	-- clique viraria um pedido que o servidor recusa.
	Framework:Listen("UpdateCash", function(amount : number)
		self.Cash = amount or 0
	end)
	Framework:Fire("RequestCash")

	task.spawn(function()
		if not self:_bind() then
			return
		end

		-- A oferta que ja estava aberta quando este cliente carregou, e as cartas
		-- que ele ja tinha comprado.
		Framework:Fire("RequestRoundCardState")
	end)
end

function RoundCardShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end
end

function RoundCardShopController:init()
	self.Offer = nil
	self.Cash = 0
	self.ShopOpen = false
	self.FrameShown = false
	self.OpenToken = 0
	self.FrameToken = 0

	-- [uid] = Maid do wrapper que esta na hotbar.
	self.DeckCards = {}
	self.UsePending = {}

	self.RowMaid = Maid.new()
	self.FrameMaid = Maid.new()

	self:construct()
end

return RoundCardShopController
