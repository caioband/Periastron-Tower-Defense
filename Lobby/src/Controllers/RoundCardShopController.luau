local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local MarkerUtil = require(Util.MarkerUtil)
local ProximityPanel = require(Util.ProximityPanel)
local UIUtil = require(Util.UIUtil)

local RoundCardConfig = SharedConfig.RoundCardConfig
local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

local Framework = Me.new()

local GUI = RoundCardShopConfig.Gui
local ANIM = RoundCardConfig.Animation

--[[ CONSTANTS ]]

local CHARACTER_ROOT = "HumanoidRootPart"

-- Quantas vezes a vitrine e pedida ao servidor antes de desistir, e de quanto em
-- quanto tempo. Ver o `_requestStock`.
local STOCK_REQUEST_ATTEMPTS = 5
local STOCK_REQUEST_INTERVAL = 2

--[=[
	O nome do pedido ao `InterfaceController`: enquanto a loja esta aberta, a tela e
	so dela.

	Pedido com nome, e nao um interruptor global: a loja de caixas, a cutscene e o
	painel de mapas pedem a mesma coisa, e uma GUI so volta quando o **ultimo** pedido
	sai. Nome proprio, e nao o `"Shop"` da loja de caixas -- as duas nunca estao
	abertas juntas, mas dividir o nome faria uma devolver a tela que a outra pediu.
]=]
local HIDE_REASON = "CardShop"

--[=[
	O som da compra: o mesmo `Shards` da loja de caixas, em `SoundService.BuySFX`.

	Toca no **resultado** do servidor, e nao no clique: o preco e a carteira sao
	conferidos la, e um clique sem saldo nao comprou nada.

	A `Key` e propria, e nao a da loja de caixas: as duas nunca tocam ao mesmo tempo,
	e uma `Key` compartilhada faria uma cortar o som da outra sem razao nenhuma.
]=]
local BUY_SOUND = "Shards"
local BUY_SOUND_KEY = "RoundCardShopBuy"

-- De quanto em quanto tempo o `ResetText` e reescrito. Um segundo porque a contagem
-- e em segundos: reescrever mais rapido escreveria o mesmo texto.
local COUNTDOWN_INTERVAL = 1

--[=[
	O botao da HUD que leva o jogador ate a vitrine.

	Ele mora no proprio `Wrapper` dentro do `HUDFrame`, ao lado do `Shop` (que faz o
	mesmo pela loja de caixas), e por isso e procurado **em profundidade**: a HUD muda
	de forma com o tempo, e um botao que hoje esta dentro de um wrapper pode estar
	solto no frame amanha.

	O nome nao colide com o `Shop` do vizinho: `FindFirstChild` casa o nome inteiro, e
	nao um pedaco dele. E o `CardShop` do `RoundCardConfig.Gui` (o botao da beirada da
	tela, na Game) e outra `ScreenGui` de outra place -- a busca daqui comeca no
	`HUDFrame` do Lobby e nunca alcanca aquele.

	**O crescer e o afundar dele nao sao daqui.** Quem cuida disso e o
	`HUDButtonController`, que liga todo `GuiButton` debaixo do `HUDFrame` -- o botao
	novo entra na animacao dos outros sem uma linha de codigo. Daqui sai so o clique.
]=]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDFrame"
local HUD_BUTTON_NAME = "CardShop"

--[=[
	A loja de cartas do lobby: `StarterGui.ShopUI.RCSS`.

	Ela vende **acesso** as cartas de round. A carta comprada aqui nao vai para mao
	nenhuma: ela entra no `RoundCards` do perfil e passa a poder ser sorteada na oferta
	de round dentro da partida. E por isso que a carta que este jogador ja destravou
	aparece com o veu de `SOLD` em vez de sair da vitrine -- a vitrine e a mesma para
	todo mundo (tres cartas por bloco de quatro horas), e o que muda de jogador para
	jogador e o que ele ja tem.

	**Este controller nao sorteia nada.** As tres cartas chegam do
	`RoundCardShopService` ja sorteadas e com preco, ele desenha, e o clique manda
	"quero a carta X". Quem confere que X esta na vitrine de agora, que o jogador nao a
	tem e que os shards dao e o servidor.

	**O reroll tambem nao e creditado aqui.** O dado (`RerollDice`) abre o prompt do
	developer product e para por ai: quem credita e o `ProcessReceipt` do servidor, e o
	que volta e a prateleira nova pelo `RoundCardStock` -- que este controller desenha
	como desenharia uma rotacao. Cancelar o prompt nao produz nada, que e o certo.

	Cada carta e um clone do `CardWrapper` autorado, e a carta dentro do wrapper e que
	anima: ela cai de cima com a imagem aparecendo e, quando isso termina, o conteudo
	(titulo, descricao, preco, contornos) sobe de transparente ate o valor autorado. O
	wrapper existe justamente para isso -- ele e quem ocupa a vaga no `UIListLayout`,
	entao a carta se mexe a vontade sem o layout arrasta-la de volta a cada quadro. Os
	tempos sao os da loja de round (`RoundCardConfig.Animation`), porque e a mesma carta
	entrando na tela pelo mesmo gesto.

	Andar a menos de `RoundCardShopConfig.OPEN_RADIUS` do marcador abre, e sair fecha.
	O botao `CardShop` da HUD leva o jogador ate la (`TeleportToShop`), do mesmo jeito
	que o `Shop` ao lado dele leva ate a loja de caixas. `Open`/`Close`/`Toggle` sao
	publicos, entao qualquer outra coisa (um comando do Cmdr, por exemplo) move o mesmo
	painel.

	**A `ShopUI` e dividida com a loja de caixas e a de Robux.** As tres sao irmas
	dentro dela, e nenhuma manda no `Enabled` sozinha: quem diz qual painel esta na
	tela e o `Visible` do wrapper de cada uma. O painel (moldura, animacao, borrao,
	proximidade) e do `ProximityPanel`; ver o `CanDisable` no `construct`.
]=]
local RoundCardShopController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},

		-- As outras lojas da mesma `ScreenGui`. So para saber se alguma esta aberta
		-- antes de apagar a ScreenGui das tres -- ver o `CanDisable` no `construct`.
		ShopController = {},
		RobuxShopController = {},

		-- O selo `New` do botao da HUD: quem o apaga e a vitrine ser aberta. Ver o
		-- `BeforeOpen` no `construct`.
		HUDBadgeController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),

		-- (cardId : string) -- disparado junto com o `RequestBuyRoundCard`, para o que
		-- for do cliente poder reagir ao clique.
		PurchaseRequested = Signal.new(),

		-- () -- o prompt do reroll foi aberto. Nao quer dizer que ele foi pago: quem
		-- confirma isso e a prateleira nova chegando pelo `RoundCardStock`.
		RerollRequested = Signal.new(),

		-- (cardId : string, success : boolean, reason : string?) -- o que o
		-- `RoundCardShopService` decidiu. `reason` e um de NotLoaded, NotInStock,
		-- AlreadyOwned, NotEnoughCurrency, GrantFailed.
		PurchaseResult = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	As cartas que este jogador ja destravou, lidas da propria replica.

	Vem da replica e nao do servidor de propósito: o `RoundCards` do perfil ja e
	replicado para o dono dele, e mandar a lista junto com a vitrine daria ao cliente
	uma segunda versao de uma coisa que ele ja tem -- e que ficaria velha na primeira
	compra.
]=]
function RoundCardShopController:_unlocked() : { [string] : boolean }
	local replica = self.Replica

	return RoundCardShopConfig.unlockedOf(replica and replica.Data or nil)
end

--[=[
	O molde de uma carta: o `CardWrapper` autorado sai da fileira e volta clonado, um
	por carta da vitrine.

	Ele e clonado **e** destruido porque o autorado e a primeira vaga do
	`UIListLayout`: deixa-lo la daria uma quarta carta parada, com o texto de exemplo
	que o designer escreveu.
]=]
function RoundCardShopController:_template() : Frame?
	if self.Template then
		return self.Template
	end

	local authored = self.Row and self.Row:FindFirstChild(GUI.Wrapper_Card)
	if not authored then
		warn(`[RoundCardShopController]: nao achei o {GUI.Wrapper_Card} autorado em {GUI.Row}.`)
		return nil
	end

	self.Template = authored:Clone()
	authored:Destroy()

	return self.Template
end

--[=[
	Escreve o que muda numa carta: titulo, descricao, arte e preco.

	Carta sem arte propria fica com a autorada no molde -- carta com a arte errada e
	melhor do que carta invisivel. O icone da shard e a cor do contorno do preco ja
	estao autorados no botao, porque esta loja cobra numa moeda so.
]=]
function RoundCardShopController:_writeCard(card : GuiObject, definition, price : number)
	local title = card:FindFirstChild(GUI.Title)
	if title and title:IsA("TextLabel") then
		title.Text = definition.Title or definition.Id
	end

	local description = card:FindFirstChild(GUI.Description)
	if description and description:IsA("TextLabel") then
		description.Text = definition.Description or ""
	end

	local buy = card:FindFirstChild(GUI.Buy)
	local label = buy and buy:FindFirstChild(GUI.BuyLabel)

	if label and label:IsA("TextLabel") then
		label.Text = string.format(RoundCardShopConfig.PRICE_FORMAT, UIUtil.formatCommas(price))
	end

	if definition.Image and (card:IsA("ImageLabel") or card:IsA("ImageButton")) then
		card.Image = definition.Image
	end
end

--[=[
	Acende ou apaga o veu de `SOLD` de uma carta, e liga ou desliga o botao dela.

	Chamado no desenho e a cada mudanca do `RoundCards` na replica. **Nao redesenha a
	carta**: comprar com a loja aberta so acende o veu, e refazer a fileira faria as
	tres cartas caírem de novo na frente de quem acabou de clicar numa delas.
]=]
function RoundCardShopController:_applySold(entry)
	local sold = self:_unlocked()[entry.Id] == true

	entry.Sold = sold

	if entry.Veil and entry.Veil:IsA("GuiObject") then
		entry.Veil.Visible = sold
	end

	--[[
		Titulo e descricao somem debaixo do veu.

		O veu e um escurecido com `SOLD` escrito por cima, e o texto da carta atravessava
		os dois -- a descricao encavalava no `SOLD` e o painel virava um borrao de letras.
		Uma carta ja destravada nao precisa se explicar: o que ela e o jogador ja sabe, e
		o que importa ali e que ela nao esta a venda.

		E `Visible`, e nao transparencia: a revelacao da carta (`UIUtil.applyFades`)
		escreve nas transparencias destas mesmas labels, e as duas brigariam pela mesma
		propriedade. `Visible` esconde por fora e deixa a animacao rodar por baixo sem
		saber de nada.

		Escrito nos **dois** sentidos porque o clone nasce com os textos acesos: sem o
		`not sold`, uma carta que deixasse de estar vendida (um `_render` novo reusando o
		molde) ficaria muda.
	]]
	if entry.Title and entry.Title:IsA("GuiObject") then
		entry.Title.Visible = not sold
	end

	if entry.Description and entry.Description:IsA("GuiObject") then
		entry.Description.Visible = not sold
	end

	--[[
		O botao apagado, e nao escondido: a carta ja destravada continua mostrando o
		preco que ela custou. O clique nela nao faz nada de qualquer jeito -- o servidor
		recusa com `AlreadyOwned` --, e o `Active` e o que impede o jogador de descobrir
		isso clicando.
	]]
	local button = entry.Button
	if button and button:IsA("GuiButton") then
		button.Active = not sold
		button.AutoButtonColor = not sold
	end
end

--- Passa o veu de `SOLD` por todas as cartas na tela.
function RoundCardShopController:_refreshSold()
	for _, entry in self.CardEntries do
		self:_applySold(entry)
	end

	self:_refreshReroll()
end

--[=[
	Liga ou desliga o dado do reroll.

	Ele so faz sentido enquanto sobrar carta para destravar: o reroll pago sorteia do
	que **falta** (ver `REROLL_EXCLUDES_UNLOCKED`), entao para quem ja tem o catalogo
	inteiro ele nao teria o que oferecer. Deixa-lo clicavel ali seria vender Robux por
	nada -- e a Roblox ja cobrou quando o recibo chega, entao a hora de impedir e antes
	do prompt.

	Roda junto com o veu de `SOLD` porque as duas coisas respondem a mesma pergunta: o
	que este jogador ja destravou. A ultima compra do catalogo apaga o botao no mesmo
	instante em que acende o ultimo `SOLD`.
]=]
function RoundCardShopController:_refreshReroll()
	local button = self.RerollButton
	if not button or not button.Parent then
		return
	end

	local unlocked = self:_unlocked()
	local remaining = 0

	for _, card in RoundCardConfig.Cards do
		if not unlocked[card.Id] then
			remaining += 1
		end
	end

	local available = remaining > 0

	button.Active = available
	button.AutoButtonColor = available
end

--[=[
	Abre o prompt do developer product do reroll.

	O cliente **abre** a compra, e nao a credita: quem credita e o `ProcessReceipt` do
	servidor, e o que chega de volta e a prateleira nova pelo `RoundCardStock`. Nao ha
	resposta a esperar aqui -- se o jogador cancelar, nada acontece, que e exatamente o
	certo.

	Sem debounce: `PromptProductPurchase` nao empilha janelas, e clicar de novo com a
	janela aberta nao faz nada. Um debounce so criaria um estado para destravar quando
	o jogador fechasse o prompt por fora.
]=]
function RoundCardShopController:_promptReroll()
	local button = self.RerollButton

	-- Desligado quer dizer que nao ha carta para sortear (ver `_refreshReroll`). O
	-- `Active = false` ja engole o clique; isto e a rede para quem chamar na mao.
	if button and not button.Active then
		return
	end

	self.Signals.RerollRequested:Fire()

	MarketplaceService:PromptProductPurchase(
		Players.LocalPlayer,
		RoundCardShopConfig.REROLL_PRODUCT_ID
	)
end

--[=[
	Desenha as tres cartas da vitrine.

	Cada carta tem duas metades, nesta ordem: ela **cai** de `DropOffset` alturas acima
	do lugar dela enquanto a imagem sai de transparente (`CardDrop`), e so quando isso
	termina o conteudo -- titulo, descricao, preco, contornos, sombra -- sobe de 1 ate o
	valor autorado (`CardReveal`). Revelar tudo junto faria o texto aparecer boiando
	antes de a carta existir por tras dele.

	As tres nao saem juntas: a segunda comeca `CardStagger` depois da primeira. O atraso
	e um `task.delay` guardado no maid da fileira, entao fechar a loja no meio cancela o
	que ainda nao comecou.
]=]
function RoundCardShopController:_render()
	local row = self.Row
	local stock = self.Stock

	if not row or not stock then
		return
	end

	local template = self:_template()
	if not template then
		return
	end

	self.CardEntries = {}
	self.RowMaid:DoCleaning()

	for index, offer in stock.Cards do
		local definition = RoundCardConfig.Get(offer.Id)
		if not definition then
			warn(`[RoundCardShopController]: a vitrine trouxe a carta '{tostring(offer.Id)}', que nao esta no config.`)
			continue
		end

		local wrapper = template:Clone()
		wrapper.Name = offer.Id
		wrapper.LayoutOrder = index

		local card = wrapper:FindFirstChild(GUI.Card)
		if not card or not card:IsA("GuiObject") then
			warn(`[RoundCardShopController]: o molde nao tem um {GUI.Card} dentro do {GUI.Wrapper_Card}.`)
			wrapper:Destroy()
			continue
		end

		self:_writeCard(card, definition, offer.Price)

		local entry = {
			Id = offer.Id,
			Price = offer.Price,
			Wrapper = wrapper,
			Card = card,
			Veil = card:FindFirstChild(GUI.Sold),
			Button = card:FindFirstChild(GUI.Buy),

			-- Os dois textos apagam debaixo do véu de `SOLD`. Guardados na entry porque o
			-- `_applySold` roda de novo a cada compra, e procurá-los toda vez seria uma
			-- busca por nome por carta por escrita na replica.
			Title = card:FindFirstChild(GUI.Title),
			Description = card:FindFirstChild(GUI.Description),

			Ready = false,
		}

		--[[
			O veu entra **antes** do `captureFades`: ele e a unica peca cujo estado
			depende do jogador, e capturar com ele apagado guardaria o `SOLD` como uma
			coisa que a revelacao tem de acender.
		]]
		self:_applySold(entry)

		-- Lido do clone intocado: e para ca que a revelacao leva tudo de volta. Precisa
		-- vir antes de qualquer escrita de transparencia.
		local fades = UIUtil.captureFades(card)
		local basePosition = card.Position

		entry.Fades = fades
		entry.BasePosition = basePosition

		table.insert(self.CardEntries, entry)

		-- Estado de partida: a carta acima do lugar dela, a imagem e o conteudo
		-- transparentes.
		card.Position = UDim2.new(
			basePosition.X.Scale, basePosition.X.Offset,
			basePosition.Y.Scale - ANIM.DropOffset, basePosition.Y.Offset
		)

		if card:IsA("ImageLabel") or card:IsA("ImageButton") then
			card.ImageTransparency = 1
		end

		UIUtil.applyFades(fades, 0)

		wrapper.Parent = row
		self.RowMaid:GiveTask(wrapper)

		local button = entry.Button

		if button and button:IsA("GuiButton") then
			self.RowMaid:GiveTask(button.Activated:Connect(function()
				--[[
					A carta so aceita clique depois de comecar a cair. Ela existe na tela
					desde o `Parent`, transparente e fora do lugar, e sem isto a terceira
					carta -- que so entra um segundo depois -- poderia ser comprada enquanto
					ainda nao ha nada para o jogador ver.
				]]
				if not entry.Ready or entry.Sold then
					return
				end

				self:_requestPurchase(offer.Id)
			end))

			ButtonUtil.bindFeedback(button, self.RowMaid)
		end

		local delayed = task.delay((index - 1) * ANIM.CardStagger, function()
			if not wrapper.Parent then
				return
			end

			entry.Ready = true

			local dropInfo = TweenInfo.new(ANIM.CardDrop, ANIM.CardEasing, ANIM.CardDirection)
			local goal : { [string] : any } = { Position = basePosition }

			if card:IsA("ImageLabel") or card:IsA("ImageButton") then
				goal.ImageTransparency = 0
			end

			local drop = TweenService:Create(card, dropInfo, goal)

			drop.Completed:Connect(function(state : Enum.PlaybackState)
				if state ~= Enum.PlaybackState.Completed or not wrapper.Parent then
					return
				end

				UIUtil.applyFades(fades, 1, TweenInfo.new(ANIM.CardReveal, ANIM.CardEasing, ANIM.CardDirection))
			end)

			drop:Play()

			self.RowMaid:GiveTask(function()
				drop:Cancel()
			end)
		end)

		self.RowMaid:GiveTask(function()
			pcall(task.cancel, delayed)
		end)
	end
end

--[=[
	Escreve quanto falta para a vitrine trocar.

	A conta e contra o `ResetsAt` que o **servidor** mandou, e nao contra o relogio
	local: os dois sao segundos de UTC, mas so o do servidor concorda com o bloco em
	que a vitrine foi sorteada.

	Chegar a zero pede a vitrine nova. O servidor tambem a empurra sozinho na troca
	(ver `_watchRotation` la), e as duas coisas juntas sao de proposito: o empurrao
	cobre quem esta com a loja aberta, e este pedido cobre a diferenca de relogio entre
	as duas pontas -- sem ele, um cliente meio minuto adiantado ficaria com a contagem
	parada em `0:00:00` esperando um evento que, para ele, ja devia ter chegado.
]=]
function RoundCardShopController:_updateCountdown()
	local label = self.ResetLabel
	if not label or not label.Parent then
		return
	end

	local stock = self.Stock
	if not stock then
		return
	end

	local remaining = math.max((stock.ResetsAt or 0) - os.time(), 0)

	label.Text = string.format(
		RoundCardShopConfig.RESET_FORMAT,
		RoundCardShopConfig.formatCountdown(remaining)
	)

	if remaining <= 0 then
		self:_requestStock(true)
	end
end

--[=[
	Pede a vitrine ao servidor, e insiste ate ela chegar.

	A insistencia existe porque o **identificador do evento nasce no servidor** (ver a
	nota sobre eventos no README da raiz): o cliente pode ligar a loja antes de o
	`RoundCardShopService` ter registrado o `Listen` do `RequestRoundCardStock`, e um
	pedido feito nessa janela se perde. Sem repetir, a loja ficaria sem carta nenhuma
	pelo resto da sessao por causa de meio segundo de ordem de boot.

	`renew` e o pedido da contagem que chegou a zero, e nao o do boot: ele passa mesmo
	com vitrine na mao, porque o que ele quer e a **proxima**. Ele existe para o caso de
	o relogio do cliente estar adiantado em relacao ao do servidor -- o servidor empurra
	a vitrine nova sozinho na troca (ver o `_watchRotation` la), e sem este pedido um
	cliente meio minuto na frente ficaria parado em `0:00:00` esperando um evento que,
	para ele, ja devia ter chegado.

	O laco desiste depois de `STOCK_REQUEST_ATTEMPTS` e **libera a marca**: quem
	desistiu foi esta tentativa, e nao a loja. Uma vitrine que continua vencida tenta de
	novo no segundo seguinte, e o aviso sai so no caso do boot -- na renovacao ele viria
	a cada dez segundos e enterraria o output.
]=]
function RoundCardShopController:_requestStock(renew : boolean?)
	if self.StockRequested then
		return
	end

	if self.Stock and not renew then
		return
	end

	self.StockRequested = true

	task.spawn(function()
		-- A vitrine que ja esta na mao. Chegar uma com outro indice e o que encerra o
		-- laco: no boot ela e nil, e qualquer resposta serve.
		local before = self.Stock and self.Stock.Index or nil

		for _ = 1, STOCK_REQUEST_ATTEMPTS do
			if (self.Stock and self.Stock.Index or nil) ~= before then
				return
			end

			Framework:Fire("RequestRoundCardStock")
			task.wait(STOCK_REQUEST_INTERVAL)
		end

		self.StockRequested = false

		if not self.Stock then
			warn("[RoundCardShopController]: nenhuma vitrine veio do servidor -- a loja de cartas fica vazia.")
		end
	end)
end

function RoundCardShopController:_requestPurchase(cardId : string)
	self.Signals.PurchaseRequested:Fire(cardId)

	-- O servidor confere a vitrine e a carteira e escreve no perfil -- o cliente so
	-- pede.
	Framework:Fire("RequestBuyRoundCard", cardId)
end

--[=[
	Segue a replica: o veu de `SOLD` acompanha o `RoundCards` do perfil.

	Escutado pelo `OnChange` inteiro, e nao so pela chave: a compra escreve
	`RoundCards`, e qualquer escrita mais funda ali dentro tambem tem de reacender o
	veu.
]=]
function RoundCardShopController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_refreshSold()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]

			if key ~= nil and key ~= "RoundCards" then
				return
			end

			self:_refreshSold()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	Um dos marcadores da loja no mapa, guardado ate ele sair do mundo. Ver o
	`MarkerUtil` -- a busca e recursiva dentro do mapa, porque os dois marcadores vivem
	dentro do modelo da casa e nao soltos na raiz dele.
]=]
function RoundCardShopController:_getMapPart(partName : string) : Instance?
	return MarkerUtil.find(
		RoundCardShopConfig.REFERENCE_PARENT_NAME,
		partName,
		self.MapParts,
		self.WarnedMissing,
		"RoundCardShopController"
	)
end

--- Onde a loja fica, para quem precisa medir contra o mesmo centro que a proximidade.
function RoundCardShopController:GetReferencePosition() : Vector3?
	local pivot = MarkerUtil.pivotOf(self:_getMapPart(RoundCardShopConfig.REFERENCE_PART_NAME))

	return pivot and pivot.Position or nil
end

--- A contagem do `ResetText`, reescrita de segundo em segundo enquanto o cliente vive.
function RoundCardShopController:_watchCountdown()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.CountdownClock += deltaTime

		if self.CountdownClock < COUNTDOWN_INTERVAL then
			return
		end

		self.CountdownClock = 0
		self:_updateCountdown()
	end))
end

--[=[
	O conteudo da loja numa copia nova da `ShopUI`. O painel em si -- a moldura, a
	`OpenShop`, o X, o borrao e o pedido de tela -- e do `ProximityPanel`, que chama
	isto no fim do bind dele. A `ShopUI` e `ResetOnSpawn`, entao roda de novo a cada
	respawn. `maid` e o do bind: limpo na proxima copia.
]=]
function RoundCardShopController:_onBind(panel : GuiObject, maid : any)
	local row = panel:WaitForChild(GUI.Row, 10)

	if not row then
		warn(`[RoundCardShopController]: nao achei {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.Row}.`)
		return
	end

	self.RowMaid:DoCleaning()

	self.Row = row

	--[[
		O molde e por copia da `ShopUI`: a anterior foi destruida com a ScreenGui dela, e
		guardar o clone velho poria cartas orfas na fileira nova.
	]]
	self.Template = nil
	self.CardEntries = {}

	--[[
		Filho **direto** do painel, e nao em profundidade: a contagem tem lugar fixo na
		arte, e o botao de reroll carrega uma legenda propria dentro dele. Uma busca
		recursiva escolheria entre labels pela ordem da arvore, e a contagem poderia
		acabar escrita por cima da legenda de outra peca. Ver o comentario do
		`Gui.ResetText`.
	]]
	self.ResetLabel = panel:FindFirstChild(GUI.ResetText)

	if not self.ResetLabel or not self.ResetLabel:IsA("TextLabel") then
		self.ResetLabel = nil
		warn(`[RoundCardShopController]: nao achei o {GUI.ResetText} como filho de {GUI.Panel} -- a loja abre sem a contagem.`)
	end

	--[[
		O dado do reroll. O `UIScale` dele foi autorado para isto, e quem anima e o
		`ButtonUtil` -- o mesmo peso do botao `Buy` das cartas e do da loja de caixas.

		Vai no maid do bind porque ele e parte do painel: a `ShopUI` e `ResetOnSpawn`, e
		a copia nova traz um botao novo.
	]]
	local reroll = panel:FindFirstChild(GUI.Reroll)

	if reroll and reroll:IsA("GuiButton") then
		self.RerollButton = reroll

		maid:GiveTask(reroll.Activated:Connect(function()
			self:_promptReroll()
		end))

		ButtonUtil.bindFeedback(reroll, maid)
	else
		self.RerollButton = nil
		warn(`[RoundCardShopController]: nao achei o {GUI.Reroll} em {GUI.Panel} -- a loja abre sem o reroll.`)
	end

	self:_render()
	self:_refreshReroll()
	self:_updateCountdown()
	self:_requestStock()
end

--[=[
	Liga o botao da HUD, que leva o jogador ate a vitrine.

	Maid proprio: a `HUD` e a `ShopUI` sao `ScreenGui` diferentes e a engine as refaz
	em momentos diferentes, entao o bind de uma nao pode desconectar o da outra.
]=]
function RoundCardShopController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, 10)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, HUD_BUTTON_NAME, 10)

	if not button or not button:IsA("GuiButton") then
		warn(`[RoundCardShopController]: nao achei {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:TeleportToShop()
	end))
end

--- A HUD, pelo botao que leva ate a vitrine. A `ShopUI` e seguida pelo `ProximityPanel`.
function RoundCardShopController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

function RoundCardShopController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

--- A vitrine de agora como o cliente a conhece, ou nil enquanto ela nao chegou.
function RoundCardShopController:GetStock()
	return self.Stock
end

function RoundCardShopController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function RoundCardShopController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

--[=[
	Larga o jogador no marcador de pouso ao lado da loja.

	O pouso fica a 18,8 studs da referencia, ou seja **fora** do `OPEN_RADIUS` (que sao
	5, o balcao). Entao o teleporte abre a loja na mao, pelo `EnterRange` -- que marca
	a entrada junto, senao a travessia de saida nunca aconteceria e a loja aberta pelo
	teleporte ficaria pendurada na tela por mais longe que ele andasse.

	Quem chama e o botao `CardShop` da HUD (ver `_bindHud`), do mesmo jeito que o
	`Shop` ao lado dele chama o teleporte da loja de caixas.
]=]
function RoundCardShopController:TeleportToShop() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)

	if not root then
		return false
	end

	local part = self:_getMapPart(RoundCardShopConfig.TELEPORT_PART_NAME)
	local pivot = MarkerUtil.pivotOf(part)

	if not pivot then
		return false
	end

	local halfHeight = MarkerUtil.halfHeightOf(part)

	character:PivotTo(pivot * CFrame.new(0, halfHeight + RoundCardShopConfig.TELEPORT_HEIGHT_OFFSET, 0))

	-- Sem isto o jogador mantem a velocidade que tinha e escorrega para fora do
	-- marcador.
	root.AssemblyLinearVelocity = Vector3.zero

	if self.Proximity then
		self.Proximity:EnterRange()
	end

	return true
end

function RoundCardShopController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function RoundCardShopController:construct()
	--[[
		A vitrine e ouvida antes de a UI ser observada de proposito: a resposta pode
		chegar antes de o primeiro bind terminar, e o `_render` desenha do zero -- chegar
		cedo demais so significa que a loja ja abre com as cartas prontas.
	]]
	Framework:Listen("RoundCardStock", function(stock)
		if typeof(stock) ~= "table" or typeof(stock.Cards) ~= "table" then
			return
		end

		--[[
			`Index` **e** `Rolls`: a rotacao troca o bloco, e o reroll troca a prateleira
			dentro do mesmo bloco. Comparando so o indice, as cartas pagas chegariam e nao
			seriam desenhadas -- que e exatamente o que o jogador acabou de comprar.
		]]
		local rotated = self.Stock == nil
			or self.Stock.Index ~= stock.Index
			or (self.Stock.Rolls or 0) ~= (stock.Rolls or 0)

		self.Stock = stock

		-- Liberado para o proximo pedido: o `_updateCountdown` volta a poder insistir
		-- quando **esta** vitrine vencer.
		self.StockRequested = false

		--[[
			A vitrine nova so redesenha a fileira se ela for outra. A troca de bloco pode
			cair com a loja aberta na frente do jogador, e ai as cartas novas caem por
			cima das velhas -- que e o que a troca quer dizer. Uma vitrine repetida (o
			pedido que o boot repetiu) nao pode fazer as tres cartas caírem de novo.
		]]
		if rotated then
			self:_render()
		end

		self:_updateCountdown()
	end)

	Framework:Listen("RoundCardPurchaseResult", function(cardId : string, success : boolean, reason : string?)
		if success then
			--[[
				O som e a primeira coisa que acontece com a resposta: o `PurchaseResult` sai
				depois, porque quem escuta o sinal pode fazer qualquer coisa, e nada disso
				pode entrar na frente do som.

				O veu de `SOLD` nao e aceso aqui -- ele acompanha o `RoundCards` da replica
				(ver `_watchProfile`), que e a mesma escrita que o servidor acabou de fazer.
				Acender nos dois lugares so daria duas fontes para o mesmo estado.
			]]
			local music = self.Controllers.MusicController
			if music then
				music:PlaySFX(BUY_SOUND, { Key = BUY_SOUND_KEY })
			end
		end

		self.Signals.PurchaseResult:Fire(cardId, success, reason)
	end)

	--[[
		O som da compra baixa agora, e nao no primeiro clique: `Sound:Play()` num asset
		que ainda nao chegou espera o download, e num som que confirma uma acao essa
		espera e a resposta inteira.
	]]
	local music = self.Controllers.MusicController
	if music then
		music:PreloadSFX({ BUY_SOUND })
	end

	--[[
		O painel: a moldura, a `OpenShop`, o borrao, o pedido de tela e a proximidade
		do marcador. O que esta loja tem de proprio entra pelo `OnBind` e pelo
		`BeforeOpen`.
	]]
	self.Proximity = ProximityPanel.new({
		Name = "RoundCardShopController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = RoundCardShopConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		GetReference = function()
			return self:GetReferencePosition()
		end,
		Radius = RoundCardShopConfig.OPEN_RADIUS,
		Interval = RoundCardShopConfig.PROXIMITY_INTERVAL,
		InterfaceController = self.Controllers.InterfaceController,

		-- A `ShopUI` e dividida com a loja de caixas e a de Robux: fechar esta com
		-- uma delas aberta nao pode apagar a ScreenGui das tres.
		CanDisable = function()
			local crateShop = self.Controllers.ShopController
			local robuxShop = self.Controllers.RobuxShopController

			return not ((crateShop and crateShop:IsOpen()) or (robuxShop and robuxShop:IsOpen()))
		end,

		OnBind = function(_screenGui, _wrapper, panel, maid)
			self:_onBind(panel, maid)
		end,

		--[[
			As cartas caem a cada abertura, e nao uma vez por vitrine: a queda e a
			apresentacao da oferta, e um painel que abrisse com as tres cartas ja paradas
			pareceria uma tela que estava aberta o tempo todo.
		]]
		BeforeOpen = function()
			self:_render()
			self:_updateCountdown()

			-- A vitrine foi vista: o selo de "a loja resetou" se encerra, e volta quando o
			-- bloco de quatro horas virar de novo.
			local badges = self.Controllers.HUDBadgeController
			if badges then
				badges:NoteSeen(HUD_BUTTON_NAME)
			end
		end,
	})

	local openChanged = self.Proximity.Signals.OpenChanged:Connect(function(isOpen : boolean)
		self.Signals.OpenChanged:Fire(isOpen)
	end)

	self.Maid:GiveTask(function()
		openChanged:Disconnect()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_observeUI()
	self:_watchProfile()
	self:_watchCountdown()
end

function RoundCardShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function RoundCardShopController:init()
	self.Maid = Maid.new()

	-- O botao da HUD, que vive numa `ScreenGui` propria e e refeito em outro momento
	-- que o painel.
	self.HudMaid = Maid.new()

	-- A fileira das cartas: os clones, os cliques deles e os atrasos da entrada.
	self.RowMaid = Maid.new()

	self.Maid:GiveTask(self.HudMaid)
	self.Maid:GiveTask(self.RowMaid)

	-- O `ProximityPanel` desta loja, criado no `construct`.
	self.Proximity = nil

	-- A vitrine vinda do servidor -- nil enquanto a resposta nao chega.
	self.Stock = nil
	self.StockRequested = false

	-- Uma entrada por carta desenhada: o `Id`, o clone dela e o que a revelacao precisa
	-- saber para levar as transparencias de volta.
	self.CardEntries = {}

	-- O molde clonado do `CardWrapper` autorado, por copia da `ShopUI`.
	self.Template = nil

	-- O dado do reroll, por copia da `ShopUI`. Desligado quando nao sobrou carta para
	-- destravar (ver `_refreshReroll`).
	self.RerollButton = nil

	-- Os marcadores do mapa, por nome, e os nomes de que ja se avisou a falta.
	self.MapParts = {}
	self.WarnedMissing = {}

	self.CountdownClock = 0
end

return RoundCardShopController
