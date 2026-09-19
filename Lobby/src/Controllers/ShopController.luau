local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local ShopConfig = SharedConfig.ShopConfig
local RarityConfig = SharedConfig.RarityConfig

local Framework = Me.new()

--[[ CONSTANTS ]]
local SHOP_UI_NAME = "ShopUI"

--[=[
	O caminho do painel: `ShopUI.Frame.ImageLabel`.

	O `Frame` de fora carrega o `UIAspectRatioConstraint`, e o `ImageLabel` de dentro
	e a moldura desenhada -- e nele que a `OpenShop` escreve.

	**A `ShopUI` carrega tres lojas.** O `Frame` e esta, a de caixas; o `RCSS` ao lado
	dele e a de cartas (`RoundCardShopController`), e o `RobuxShop` e a de Robux
	(`RobuxShopController`). Quem abre e fecha a moldura e o `ProximityPanel`, e o
	`CanDisable` dele e o que impede esta loja de apagar a ScreenGui com uma vizinha
	aberta.
]=]
local WRAPPER_NAME = "Frame"
local PANEL_NAME = "ImageLabel"
local LIST_NAME = "ScrollingFrame"

-- Dentro do container de cada caixa. `BoxArt` carrega a ilustracao e, dentro dela,
-- o nome; `Frame` carrega a lista de raridades; `Buy` e o botao com o preco.
local BOX_ART_NAME = "BoxArt"
local ODDS_FRAME_NAME = "Frame"
local RARITY_TEMPLATE_NAME = "Rarity"
local RARITY_TEXT_NAME = "RarityTextPercentage"
local BUY_BUTTON_NAME = "Buy"

local RARITY_ROW_PREFIX = "Rarity_"

-- O contador de shards ainda nao existe no painel novo -- a loja nao depende dele
-- para funcionar. O X (`Close`, no `Frame` de fora) e ligado pelo `ProximityPanel`.
local SHARDS_LABEL_NAME = "CurrentShards"

local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDFrame"
local HUD_BUTTON_NAME = "Shop"

-- Quantas vezes as chances sao pedidas ao servidor antes de desistir, e de quanto
-- em quanto tempo. Ver o `_requestOdds`.
local ODDS_REQUEST_ATTEMPTS = 5
local ODDS_REQUEST_INTERVAL = 2

--[=[
	O nome do pedido ao `InterfaceController`: enquanto a loja esta aberta, a tela e
	so dela.

	Pedido com nome, e nao um interruptor global: a cutscene e o painel de mapas
	pedem a mesma coisa, e uma GUI so volta quando o **ultimo** pedido sai. Quem
	esconde nunca escreve no `Enabled` dos outros -- o controller guarda o que o dono
	de cada GUI queria e devolve exatamente aquilo.
]=]
local HIDE_REASON = "Shop"

--[=[
	O som da compra, um por moeda. Toca no **resultado** do servidor, e nao no
	clique: o preco e a carteira sao conferidos la, e um clique sem saldo nao comprou
	nada.

	Os dois moram em `SoundService.BuySFX`, uma pasta solta ao lado do Package
	`SharedSounds` -- e um efeito so do Lobby, e nao vale uma mudanca de package nas
	duas places. O `MusicController` acha som solto e som em pasta solta pelo nome;
	ver o `_findLoose` de la.

	A chave e a moeda do perfil (`ShopConfig.CURRENCIES`) e o valor e o nome do
	`Sound`, que e o nome da tela: a pasta traz `Coins`, e nao `Cash`.

	**Toda compra toca do comeco.** As duas dividem uma `Key`, e o `PlaySFX` para e
	destroi o que estiver tocando nela antes de soltar o clone novo -- comprar de novo
	no meio do som corta e recomeca, em vez de somar uma segunda copia por cima da
	primeira. Sem `Key` os clones se empilhariam, e a terceira compra seguida sairia
	como um borrao em vez de tres confirmacoes.

	Isso **nao e debounce**: nada e engolido, e toda resposta do servidor tem o seu
	som. O corte e a favor do jogador -- o som que ele ouve e sempre o da compra que
	ele acabou de fazer.

	Sem fade, o clone toca no mesmo quadro em que a resposta chega. O que ainda podia
	atrasar era o download do audio no primeiro toque, e por isso os dois sao
	pre-carregados no `construct`.
]=]
local BUY_SOUND_KEY = "ShopBuy"

local BUY_SOUNDS = {
	Shards = "Shards",
	Cash = "Coins",
}

--[[
	O contorno de cada linha de raridade.

	A cor e a do tier no `RarityConfig` -- a mesma que pinta o carretel do unboxing e
	o nome da carta no deck --, e o gradiente e um brilho por cima dela: o `Color` do
	`UIStroke` carrega a cor e o gradiente carrega so a luz, em cinza, para a hora de
	trocar uma cor de raridade ser uma linha no `RarityConfig` e nao quatro aqui.

	Vertical (`Rotation = 90`) porque a linha e um retangulo largo e baixo: um
	gradiente horizontal acenderia uma ponta do texto e apagaria a outra.
]]
local STROKE_GRADIENT_ROTATION = 90
local STROKE_SHEEN_TOP = 1
local STROKE_SHEEN_BOTTOM = 0.45

--[=[
	A cara do botao `Buy` por moeda: a cor do contorno do preco, o icone ao lado dele
	e o tamanho desse icone.

	Fica aqui e nao no `ShopConfig` porque e desenho: o config diz de qual chave de
	`Data.Stats` a caixa cobra (e o servidor cobra dali), e quem traduz isso em cor e
	imagem e a tela. Os containers sao autorados um por caixa, entao sem isto a
	Crate Of Beginnings continuaria com o icone da Shard ao lado de um preco em
	Coins -- a arte foi desenhada quando a loja tinha uma moeda so.

	`IconScale` vai no `UIScale` autorado dentro do `ImageLabel`. As duas artes nao
	pesam o mesmo na mesma caixa: a moeda de Coins e mais cheia que a Shard, e sai
	grande demais no tamanho que a Shard pede. E escrito nas **duas** moedas, e nao
	so na que encolhe, porque o `UIScale` e do container e nao da moeda -- um preco
	que voltasse para Shards ficaria com o icone encolhido do dono anterior.

	A chave e a mesma de `ShopConfig.CURRENCIES`. Moeda sem entrada aqui deixa o
	botao como o designer autorou, que e melhor do que apagar o icone dele.
]=]
local CURRENCY_STYLE = {
	Shards = {
		StrokeColor = Color3.fromRGB(69, 92, 241),
		Icon = "rbxassetid://84637851192567",
		IconScale = 1,
	},

	Cash = {
		StrokeColor = Color3.fromRGB(211, 170, 88),
		Icon = "rbxassetid://94514377432201",
		IconScale = 0.8,
	},
}

--[=[
	Dono da `StarterGui.ShopUI`: acha o container de cada caixa, escreve nele o que
	muda e toca a `OpenShop` no painel.

	**Ele nao cria container nenhum.** Cada caixa tem o container dela autorado na
	`ScrollingFrame`, com ilustracao, moldura e cor proprias, e o codigo so acha pelo
	nome (o `Key` da caixa, ver `CrateConfig`) e preenche tres coisas: o nome na
	`BoxArt`, o preco no `Buy` (com a cor e o icone da moeda dele) e a lista de
	raridades no `Frame`. Antes existia um `ShopItemWrapper` autorado que ele clonava
	por item -- nao serve mais, porque clonar um template so daria tres caixas com a
	cara da primeira.

	Dentro de cada container, a linha de raridade **e um template por caixa**: a
	`Rarity` autorada e a arte daquela caixa, e ela e clonada uma vez por raridade
	que a caixa pode dropar, da mais comum (em cima) para a mais rara (embaixo).

	As **chances** nao estao em config compartilhado: elas sao do servidor, e chegam
	pelo `CrateOdds` depois de um `RequestCrateOdds`. Ate elas chegarem o container
	fica sem linha nenhuma, e nao com o numero autorado -- placeholder de designer na
	tela do jogador e pior do que espaco vazio por meio segundo.

	Andar a menos de `ShopConfig.OPEN_RADIUS` da parte da loja abre, e sair fecha.
	`Open`/`Close`/`Toggle` sao publicos, entao qualquer outra coisa (o botao da HUD,
	um comando do Cmdr) move o mesmo painel.

	Quem reage ao jogador **chegando** e o `ShopKeeperController`, num raio maior em
	volta do mesmo ponto. Ele escuta o `PurchaseResult` daqui para saber se despede o
	jogador bem ou mal, e este controller nao sabe que ele existe.
]=]
local ShopController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},

		-- As outras lojas da mesma `ScreenGui`. So para saber se alguma esta aberta
		-- antes de apagar a ScreenGui das tres -- ver o `CanDisable` no `construct`.
		RoundCardShopController = {},
		RobuxShopController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),

		-- (item : ShopConfig.ShopItem) -- fired alongside the RequestBuyShopItem
		-- event, for anything client side that wants to react to the click.
		PurchaseRequested = Signal.new(),

		-- (itemId : string, success : boolean, reason : string?) -- what ShopService
		-- decided. reason is one of UnknownItem, NotLoaded, NotEnoughCurrency,
		-- GrantFailed.
		PurchaseResult = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	Uma porcentagem como a arte escreve: `40%`, `7.79%`, `1.29%`.

	Duas casas e o suficiente para a menor chance da tabela (a lendaria na caixa mais
	barata, 1,29%) nao virar "1%", e o zero a direita cai fora para o caso redondo
	nao virar "40.00%" ao lado de um "7.79%".
]=]
local function formatPercent(chance : number) : string
	local rounded = math.floor(chance * 100 + 0.5) / 100

	-- Chance que existe mas nao cabe em duas casas vira `<0.01%`, e nao `0%`: a
	-- linha esta ali porque a raridade pode sair, e escrever zero seria mentir.
	-- Nenhum pool de hoje chega perto disso (a menor e 1,29%), mas quem mexer nos
	-- numeros nao vai descobrir esta regra pelo bug.
	if rounded <= 0 then
		return "<0.01%"
	end

	local text = string.format("%.2f", rounded)

	text = string.gsub(text, "%.?0+$", "")

	return text .. "%"
end

--[=[
	Veste o botao `Buy` com a moeda que aquela caixa cobra: o contorno do preco e o
	icone ao lado dele.

	As tres caixas foram autoradas quando a loja so cobrava em Shards, entao as tres
	nascem com o icone e o azul da Shard. Escrever os dois aqui e o que faz uma caixa
	em Coins se ler como Coins sem o designer precisar tocar em container nenhum
	quando um preco mudar de moeda.
]=]
local function styleBuyButton(buy : Instance, currency : string)
	local style = CURRENCY_STYLE[currency]
	if not style then
		return
	end

	local priceLabel = buy:FindFirstChildWhichIsA("TextLabel")
	local stroke = priceLabel and priceLabel:FindFirstChildWhichIsA("UIStroke")

	if stroke then
		stroke.Color = style.StrokeColor
	end

	local icon = buy:FindFirstChildWhichIsA("ImageLabel")
	if not icon then
		return
	end

	icon.Image = style.Icon

	-- O `UIScale` e autorado dentro do icone. Sem ele so o tamanho do designer vale,
	-- que e o que ja acontecia antes de as moedas se separarem.
	local scale = icon:FindFirstChildWhichIsA("UIScale")
	if scale and style.IconScale then
		scale.Scale = style.IconScale
	end
end

--[=[
	Pinta o contorno de uma linha com a cor da raridade dela, com um brilho de cima
	para baixo.

	O `UIStroke` autorado e o da caixa (preto na Crate Of Nature, verde na Fragmented
	Crate), e ele nao diz nada sobre a raridade da linha -- as quatro linhas de uma
	caixa sairiam iguais. Aqui ele passa a ser a cor do tier, e a linha se le sozinha
	antes de o jogador chegar no texto.

	O gradiente e reaproveitado quando ja existe um autorado (o template da Crate Of
	Beginnings tem um) em vez de um segundo ser criado ao lado: dois `UIGradient` no
	mesmo `UIStroke` e a Roblox escolhendo um deles por ordem de arvore.
]=]
local function styleRarityStroke(label : TextLabel, rarity : string)
	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	local color = RarityConfig.getColor(rarity)

	if not stroke or not color then
		return
	end

	stroke.Color = color

	local gradient = stroke:FindFirstChildWhichIsA("UIGradient")
	if not gradient then
		gradient = Instance.new("UIGradient")
		gradient.Parent = stroke
	end

	gradient.Rotation = STROKE_GRADIENT_ROTATION
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(STROKE_SHEEN_TOP, STROKE_SHEEN_TOP, STROKE_SHEEN_TOP)),
		ColorSequenceKeypoint.new(1, Color3.new(STROKE_SHEEN_BOTTOM, STROKE_SHEEN_BOTTOM, STROKE_SHEEN_BOTTOM)),
	})
end

--[=[
	Escreve as linhas de raridade de um container, da mais comum para a mais rara.

	A `Rarity` autorada dentro do container e o template daquela caixa: ela sai da
	tela no bind e volta clonada, uma vez por raridade com chance maior que zero. A
	ordem e a do `RarityConfig`, e nao a da chance -- na caixa lendaria a Epic e a
	Legendary empatam em 40%, e ordenar por numero poria as duas na frente da Rare.

	Sem odds (elas ainda nao chegaram do servidor) o container fica vazio de
	proposito. Ver o comentario da classe.
]=]
function ShopController:_renderOdds(entry)
	local template = entry.RarityTemplate
	local frame = entry.OddsFrame
	if not template or not frame or not frame.Parent then
		return
	end

	for _, row in entry.Rows do
		row:Destroy()
	end

	entry.Rows = {}

	local odds = self.CrateOdds and self.CrateOdds[entry.Item.Id]
	if not odds then
		return
	end

	for _, rarity in RarityConfig.ORDER do
		local chance = odds[rarity]
		if not chance or chance <= 0 then
			continue
		end

		local row = template:Clone()
		row.Name = RARITY_ROW_PREFIX .. rarity
		row.LayoutOrder = RarityConfig.getOrder(rarity) or 0

		local label = row:FindFirstChild(RARITY_TEXT_NAME, true)
		if label and label:IsA("TextLabel") then
			local tier = RarityConfig.TIERS[rarity]
			local name = (tier and tier.DisplayName) or rarity

			label.Text = string.format("%s: %s", string.upper(name), formatPercent(chance))
			styleRarityStroke(label, rarity)
		end

		row.Visible = true
		row.Parent = frame

		table.insert(entry.Rows, row)
	end
end

--[=[
	Liga um container autorado ao item da loja que ele representa.

	Devolve nil quando o container nao tem a estrutura que a arte promete -- e um
	container quebrado some da loja em vez de aparecer sem preco.
]=]
function ShopController:_bindContainer(container : Instance, item)
	local boxArt = container:FindFirstChild(BOX_ART_NAME)
	local oddsFrame = container:FindFirstChild(ODDS_FRAME_NAME)
	local buy = container:FindFirstChild(BUY_BUTTON_NAME)

	if not oddsFrame or not buy then
		warn(`[ShopController]: container '{container.Name}' has no {ODDS_FRAME_NAME}/{BUY_BUTTON_NAME}.`)
		return nil
	end

	container.LayoutOrder = item.Order
	container:SetAttribute("ShopItemId", item.Id)
	container.Visible = true

	-- O nome mora dentro da ilustracao, e nao ao lado dela.
	local nameLabel = boxArt and boxArt:FindFirstChildWhichIsA("TextLabel")
	if nameLabel then
		nameLabel.Text = string.upper(item.DisplayName)
	end

	--[[
		O preco com o desconto do VIP, pela mesma `ShopConfig.priceFor` que o servidor
		usa para cobrar: o numero no botao e o numero que sai da carteira porque e a
		mesma conta, e nao porque alguem lembrou de mexer nos dois.
	]]
	local priceLabel = buy:FindFirstChildWhichIsA("TextLabel")
	if priceLabel then
		priceLabel.Text = string.format(ShopConfig.PRICE_FORMAT, UIUtil.formatCommas(self:_priceOf(item)))
	end

	styleBuyButton(buy, item.Currency)

	if buy:IsA("GuiButton") then
		self.ItemMaid:GiveTask(buy.Activated:Connect(function()
			self:_requestPurchase(item)
		end))

		--[[
			O peso do botao (crescer no hover, afundar no aperto) e do `ButtonUtil`: a
			loja de cartas usa o mesmo, e as duas tem de responder ao toque do mesmo
			jeito. Vai no `ItemMaid`, junto do resto do bind do container -- um `_render`
			novo desconecta tudo e cancela o tween que estiver no meio.
		]]
		ButtonUtil.bindFeedback(buy, self.ItemMaid)
	end

	--[[
		A linha autorada vira template e sai da tela.

		Ela e clonada antes de ser destruida porque a arte dela e a **daquela caixa**:
		nao ha um template unico de linha em lugar nenhum, e o que separa a linha da
		Crate Of Nature da linha da Fragmented Crate e exatamente o que o designer
		autorou aqui dentro.
	]]
	local authored = oddsFrame:FindFirstChild(RARITY_TEMPLATE_NAME)
	local template = nil

	if authored then
		template = authored:Clone()
		authored:Destroy()
	else
		warn(`[ShopController]: container '{container.Name}' has no {RARITY_TEMPLATE_NAME} to clone.`)
	end

	local entry = {
		Item = item,
		Container = container,
		OddsFrame = oddsFrame,
		RarityTemplate = template,
		Rows = {},
	}

	self:_renderOdds(entry)

	return entry
end

--[=[
	Preenche a loja inteira a partir do config.

	Container sem item na tabela fica escondido, e item sem container autorado sai
	da loja com um aviso -- e o caso da lendaria hoje (ver `ShopConfig.ITEMS`). Os
	dois sao avisados uma vez so por nome: um container que falta e um erro de
	autoria, e repetir por respawn so enche o output.
]=]
function ShopController:_render()
	if not self.List then
		return
	end

	self.ItemMaid:DoCleaning()
	self.Entries = {}

	local claimed = {}

	for _, item in ShopConfig.getItems() do
		local container = self.List:FindFirstChild(item.Container)

		if not container or not container:IsA("GuiObject") then
			if not self.WarnedMissing[item.Container] then
				self.WarnedMissing[item.Container] = true
				warn(`[ShopController]: no container '{item.Container}' in {SHOP_UI_NAME}.{WRAPPER_NAME}.{PANEL_NAME}.{LIST_NAME}, skipping '{item.Id}'.`)
			end

			continue
		end

		claimed[container] = true

		local entry = self:_bindContainer(container, item)
		if entry then
			table.insert(self.Entries, entry)
		end
	end

	-- Container que nao e de nenhum item da tabela: escondido, e nao destruido. Ele
	-- e trabalho de designer, e a loja nao e dona dele.
	for _, child in self.List:GetChildren() do
		if child:IsA("GuiObject") and not claimed[child] then
			child.Visible = false
		end
	end
end

--[=[
	Pede as chances ao servidor, e insiste ate elas chegarem.

	A insistencia existe porque o **identificador do evento nasce no servidor** (ver
	a nota sobre eventos no README da raiz): o cliente pode ligar a loja antes de o
	`ShopService` ter registrado o `Listen` do `RequestCrateOdds`, e um pedido feito
	nessa janela se perde. Sem repetir, a loja ficaria sem linha de raridade pelo
	resto da sessao por causa de meio segundo de ordem de boot.

	O laco para no primeiro `CrateOdds` que chegar e tem teto de tentativas: se o
	servidor nao responde depois disso, ele nao vai responder, e ficar pedindo para
	sempre so esconderia o problema.
]=]
function ShopController:_requestOdds()
	if self.CrateOdds or self.OddsRequested then
		return
	end

	self.OddsRequested = true

	task.spawn(function()
		for _ = 1, ODDS_REQUEST_ATTEMPTS do
			if self.CrateOdds then
				return
			end

			Framework:Fire("RequestCrateOdds")
			task.wait(ODDS_REQUEST_INTERVAL)
		end

		if not self.CrateOdds then
			warn("[ShopController]: no CrateOdds from the server -- the crates show no rarity rows.")
		end
	end)
end

function ShopController:_requestPurchase(item)
	self.Signals.PurchaseRequested:Fire(item)

	-- The server prices it against the profile and grants it -- the client only asks.
	Framework:Fire("RequestBuyShopItem", item.Id)
end

function ShopController:_updateShards()
	local label = self.ShardsLabel
	if not label or not label.Parent then
		return
	end

	local replica = self.Replica
	local stats = replica and replica.Data and replica.Data.Stats
	local shards = (stats and stats.Shards) or 0

	label.Text = UIUtil.formatCommas(shards)
end

--[=[
	O preco de um item para este jogador. A gamepass VIP tira 20%, e a conta e a mesma
	do servidor -- o `ShopConfig.priceFor` le a chave `Gamepasses` da propria replica.
]=]
function ShopController:_priceOf(item) : number
	local replica = self.Replica

	return ShopConfig.priceFor(item, replica and replica.Data or nil)
end

function ShopController:_watchShards()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_updateShards()

		-- DataService writes the whole Stats key, but listen through OnChange so any
		-- deeper write (Stats.Shards, ...) refreshes the counter too.
		local connection = replica:OnChange(function(_action, path)
			local key = path[1]

			-- `Gamepasses` entra porque o VIP muda o preco escrito no botao: comprar a
			-- pass com a loja aberta tem de reprecar a tela, e nao esperar a proxima
			-- abertura.
			if key == "Gamepasses" then
				self:_render()
				return
			end

			if key ~= nil and key ~= "Stats" then
				return
			end

			self:_updateShards()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	One of the shop's marker parts in the map, cached until it is taken out of the
	world (a map swap reparents it, so the reference is re-resolved instead of held
	forever). Warns once per marker so a missing one is visible without spamming.

	**A busca e recursiva dentro do mapa, e nao so nos filhos diretos.** Os dois
	marcadores vivem agrupados no modelo da loja (`Map.Shop`), e nao soltos em `Map`:
	procurar so um nivel abaixo achava nada, o botao da HUD nao teleportava e a
	proximidade nunca abria o painel. O nome de cada marcador e unico no mapa, entao
	descer a arvore acha o mesmo part de sempre onde quer que o artista o agrupe.
]=]
function ShopController:_getMapPart(partName : string) : Instance?
	return MarkerUtil.find(
		ShopConfig.REFERENCE_PARENT_NAME,
		partName,
		self.MapParts,
		self.WarnedMissing,
		"ShopController"
	)
end

--[=[
	Onde a loja fica, para quem precisa medir contra o mesmo centro que a proximidade
	mede. Publico por causa do `ShopKeeperController`: o vendedor levanta num raio
	maior em volta **deste** ponto, e nao do corpo dele, para que os dois raios sejam
	concentricos -- chegar ao balcao nunca pode acontecer sem ele ter levantado antes.
]=]
function ShopController:GetReferencePosition() : Vector3?
	local pivot = MarkerUtil.pivotOf(self:_getMapPart(ShopConfig.REFERENCE_PART_NAME))
	return pivot and pivot.Position or nil
end

--[=[
	O conteudo da loja numa copia nova da `ShopUI`. O painel em si -- a moldura, a
	`OpenShop`, o X, o borrao e o pedido de tela -- e do `ProximityPanel`, que chama
	isto no fim do bind dele. A `ShopUI` e `ResetOnSpawn`, entao roda de novo a cada
	respawn.
]=]
function ShopController:_onBind(screenGui : ScreenGui, panel : GuiObject)
	local list = panel:WaitForChild(LIST_NAME, 10)

	if not list then
		warn(`[ShopController]: could not find {SHOP_UI_NAME}.{WRAPPER_NAME}.{PANEL_NAME}.{LIST_NAME}.`)
		return
	end

	self.ItemMaid:DoCleaning()

	self.List = list

	--[[
		O contador de shards e opcional: o painel novo ainda nao traz um, e a loja
		abre e fecha por proximidade sem precisar dele.

		A busca comeca **dentro do painel** e so depois cai para a ScreenGui inteira.
		A ordem importa porque o painel antigo (`ShopUI.ImageLabel`, escondido) ainda
		tem um `CurrentShards`, e ele vem antes na arvore: procurando direto na
		ScreenGui, um contador novo autorado no painel de hoje perderia para o velho e
		nunca seria escrito.
	]]
	self.ShardsLabel = panel:FindFirstChild(SHARDS_LABEL_NAME, true)
		or screenGui:FindFirstChild(SHARDS_LABEL_NAME, true)

	self.Entries = {}

	self:_render()
	self:_updateShards()
	self:_requestOdds()
end

--[=[
	Binds the shop button on the HUD, which walks the player over to the shop. The
	icon lives inside a wrapper frame, so the button is looked up by name anywhere
	under the HUD frame -- and the hover and click animations are the
	HUDButtonController's, shared by every button up there.
]=]
function ShopController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, 10)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, HUD_BUTTON_NAME, 10)

	if not button or not button:IsA("GuiButton") then
		warn(`[ShopController]: could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:TeleportToShop()
	end))
end

--- A HUD, pelo botao que leva ate a loja. A `ShopUI` e seguida pelo `ProximityPanel`.
function ShopController:_observeUI()
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

function ShopController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function ShopController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function ShopController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

--[=[
	Drops the player on the teleport marker next to the shop.

	The client owns its own character, so moving it here is enough; the server sees
	the new position through the usual replication.

	O pouso fica **fora** do `OPEN_RADIUS`, que hoje e o balcao (5 studs) e nao o
	patio inteiro. Entao o botao abre a loja na mao, pelo `EnterRange` -- que marca a
	entrada junto, senao a travessia de saida nunca aconteceria e a loja aberta pelo
	botao ficaria pendurada na tela por mais longe que ele andasse.
]=]
function ShopController:TeleportToShop() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not root then
		return false
	end

	local pivot = MarkerUtil.pivotOf(self:_getMapPart(ShopConfig.TELEPORT_PART_NAME))
	if not pivot then
		return false
	end

	local halfHeight = MarkerUtil.halfHeightOf(self.MapParts[ShopConfig.TELEPORT_PART_NAME])

	character:PivotTo(pivot * CFrame.new(0, halfHeight + ShopConfig.TELEPORT_HEIGHT_OFFSET, 0))

	-- Without this the player keeps whatever momentum they had and slides off.
	root.AssemblyLinearVelocity = Vector3.zero

	if self.Proximity then
		self.Proximity:EnterRange()
	end

	return true
end

function ShopController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

--[=[
	Reescreve os containers a partir do config. So faz falta quando o config muda em
	tempo de execucao.

	Nao pede as odds de novo: elas sao config vezes config no servidor e nao mudam
	durante a sessao.
]=]
function ShopController:Refresh()
	self:_render()
end

function ShopController:construct()
	--[[
		As odds sao ouvidas antes de a UI ser observada de proposito: a resposta pode
		chegar antes de o primeiro bind terminar, e o `_renderOdds` de cada entry
		desenha do zero -- chegar cedo demais so significa que a loja ja abre com as
		linhas prontas.
	]]
	Framework:Listen("CrateOdds", function(odds)
		if typeof(odds) ~= "table" then
			return
		end

		self.CrateOdds = odds

		for _, entry in self.Entries do
			self:_renderOdds(entry)
		end
	end)

	Framework:Listen("ShopPurchaseResult", function(itemId : string, success : boolean, reason : string?)
		if success then
			--[[
				Qual dos dois sons toca sai do config, e nao do servidor: o resultado
				carrega o id do item, e o preco daquele id e publico. Mandar a moeda pela
				rede so daria ao cliente uma segunda versao de uma coisa que ele ja sabe.

				E a primeira coisa que acontece com a resposta: o `PurchaseResult` sai
				depois, porque quem escuta o sinal pode fazer qualquer coisa, e nada disso
				pode entrar na frente do som.
			]]
			local item = ShopConfig.getItem(itemId)
			local sound = item and BUY_SOUNDS[item.Currency]

			local music = self.Controllers.MusicController
			if music and sound then
				music:PlaySFX(sound, { Key = BUY_SOUND_KEY })
			end
		end

		self.Signals.PurchaseResult:Fire(itemId, success, reason)
	end)

	--[[
		Os dois sons da compra baixam agora, e nao no primeiro clique.

		`Sound:Play()` num asset que ainda nao chegou espera o download -- e num som
		que confirma uma acao essa espera e a resposta inteira. O preload roda em
		thread propria dentro do `PreloadSFX`, entao ele nao segura o boot do
		controller.
	]]
	local music = self.Controllers.MusicController
	if music then
		local names = {}
		for _, name in BUY_SOUNDS do
			table.insert(names, name)
		end

		music:PreloadSFX(names)
	end

	--[[
		O painel: a moldura, a `OpenShop`, o borrao, o pedido de tela e a proximidade
		do balcao. O que esta loja tem de proprio entra pelo `OnBind`.
	]]
	self.Proximity = ProximityPanel.new({
		Name = "ShopController",
		ScreenGui = SHOP_UI_NAME,
		Wrapper = WRAPPER_NAME,
		Panel = PANEL_NAME,
		Animation = ShopConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		GetReference = function()
			return self:GetReferencePosition()
		end,
		Radius = ShopConfig.OPEN_RADIUS,
		Interval = ShopConfig.PROXIMITY_INTERVAL,
		InterfaceController = self.Controllers.InterfaceController,

		-- A `ShopUI` e dividida com a loja de cartas e a de Robux: fechar esta com
		-- uma delas aberta nao pode apagar a ScreenGui das tres.
		CanDisable = function()
			local cardShop = self.Controllers.RoundCardShopController
			local robuxShop = self.Controllers.RobuxShopController

			return not ((cardShop and cardShop:IsOpen()) or (robuxShop and robuxShop:IsOpen()))
		end,

		OnBind = function(screenGui, _wrapper, panel)
			self:_onBind(screenGui, panel)
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
	self:_watchShards()
end

function ShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function ShopController:init()
	self.Maid = Maid.new()
	self.ItemMaid = Maid.new()
	self.HudMaid = Maid.new()

	self.Maid:GiveTask(self.ItemMaid)
	self.Maid:GiveTask(self.HudMaid)

	-- O `ProximityPanel` desta loja, criado no `construct`.
	self.Proximity = nil

	-- Uma entrada por caixa desenhada: o item, o container dela e as linhas de
	-- raridade que estao na tela agora.
	self.Entries = {}

	-- As chances por item, vindas do servidor -- nil enquanto a resposta nao chega.
	self.CrateOdds = nil
	self.OddsRequested = false

	-- Marker parts in the map, by name, and the names already warned about. O mesmo
	-- mapa guarda o container que faltou, pela mesma razao: avisar uma vez.
	self.MapParts = {}
	self.WarnedMissing = {}
end

return ShopController
