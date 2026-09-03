local Lighting = game:GetService("Lighting")
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
local UIUtil = require(Util.UIUtil)

local ShopConfig = SharedConfig.ShopConfig
local RarityConfig = SharedConfig.RarityConfig
local LightingConfig = SharedConfig.LightingConfig

-- Cascade lives only in the place (see Lobby/README.md), so it is reached by name
-- instead of through the Rojo tree.
local CascadeRuntime = ReplicatedStorage:WaitForChild("CascadeRuntimeEngine")
local AnimationService = require(CascadeRuntime:WaitForChild("AnimationService"))

local Framework = Me.new()

--[[ CONSTANTS ]]
local SHOP_UI_NAME = "ShopUI"

--[[
	O caminho do painel: `ShopUI.Frame.ImageLabel`.

	O `Frame` de fora carrega o `UIAspectRatioConstraint`, e o `ImageLabel` de dentro
	e a moldura desenhada -- e nele que a `OpenShop` escreve. Os dois nascem
	`Visible = false` no StarterGui, entao o bind acende os dois e quem manda em ver
	ou nao ver a loja passa a ser o `Enabled` da ScreenGui.
]]
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

-- O X mora no `Frame` de fora, e nao no painel. O contador de shards ainda nao
-- existe no painel novo -- a loja nao depende de nenhum dos dois para funcionar,
-- porque ela abre e fecha por proximidade.
local SHARDS_LABEL_NAME = "CurrentShards"
local CLOSE_BUTTON_NAME = "Close"

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
	O blur do fundo enquanto a loja esta aberta.

	Reaproveita o `UIBlur` que o `UILibraryController` ja usa nos paineis dele, em vez
	de pendurar um segundo `BlurEffect` no Lighting: dois blurs somam, e o fundo
	sairia com o dobro do borrao quando os dois estivessem abertos.

	Ele nasce com o `LightingKeep` do `LightingConfig`. Sem essa marca ele e um filho
	do Lighting que nao pertence a preset nenhum: o `LightingService` o varreria na
	troca de preset, e o `LightingController` o trataria como efeito de saida. A marca
	e exatamente para isto -- ver o comentario do `KeepAttribute` la.

	O tempo sai da propria `OpenShop` (`track.Duration`), entao o borrao entra e sai
	junto com o painel mesmo que o designer re-cronometre a animacao.
]=]
local BLUR_NAME = "UIBlur"
local BLUR_SIZE = 24
local BLUR_FALLBACK_TIME = 0.25
local BLUR_EASING_STYLE = Enum.EasingStyle.Quad
local BLUR_EASING_DIRECTION = Enum.EasingDirection.Out

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

--[=[
	O feedback do botao `Buy`: ele cresce com o ponteiro em cima e afunda enquanto
	esta apertado, no `UIScale` autorado dentro do proprio botao.

	O tempo e a curva sao os mesmos dos botoes da HUD (ver o `HUDButtonController`):
	a entrada e circular, e a volta e um `Back` que passa um pouco do ponto e volta
	-- e o que faz o botao parecer que tem peso em vez de so mudar de tamanho.

	O aperto e mais suave que o `0.9` da HUD de proposito. La o botao e um icone
	quadrado e pequeno, e aqui ele e uma barra larga: o mesmo fator moveria as duas
	bordas muito mais longe, e a barra pareceria saltar em vez de afundar.
]=]
local BUY_HOVER_SCALE = 1.05
local BUY_PRESS_SCALE = 0.93

local BUY_HOVER_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local BUY_PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local BUY_RELEASE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

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
]=]
local ShopController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},
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
	Leva o `UIScale` para o tamanho que o estado do botao pede, cancelando o tween
	anterior.

	O alvo sai do estado inteiro, e nao do evento que acabou de chegar: apertado
	vence pousado, que vence parado. Sem isso, soltar o clique com o mouse ainda em
	cima devolveria o botao ao tamanho normal em vez do tamanho de hover, e a
	proxima saida do mouse nao teria nada para desfazer.

	`Tween:Cancel()` para o tween sem devolver a propriedade -- a escala fica onde
	chegou e o tween novo parte dali, que e o que faz duas animacoes emendarem em vez
	de saltarem.
]=]
local function applyButtonScale(maid, scale : UIScale, state)
	maid:DoCleaning()

	local target, info

	if state.Pressed then
		target, info = BUY_PRESS_SCALE, BUY_PRESS_INFO
	elseif state.Hovered then
		target, info = BUY_HOVER_SCALE, BUY_HOVER_INFO
	else
		target, info = 1, BUY_RELEASE_INFO
	end

	local tween = TweenService:Create(scale, info, { Scale = target })

	maid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
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
	Liga o crescer e o afundar do botao `Buy` de um container.

	O aperto e o soltar sao `InputBegan`/`InputEnded`, e nao `MouseButton1Down/Up`,
	porque a loja e jogada no celular tambem: filtrando `MouseButton1` **e** `Touch`,
	o mesmo par de eventos cobre o clique e o toque. Nenhum dos dois consome o
	input, entao o `Activated` que faz a compra continua saindo normalmente.

	Duas coisas que o par de eventos sozinho nao cobre:

	* **Soltar fora do botao.** Arrastar para fora e soltar la nao dispara o
	  `InputEnded` daqui, e a escala ficaria presa no apertado para sempre -- por
	  isso o `MouseLeave` tambem desfaz o aperto.
	* **Toque nao tem hover.** A Roblox manda `MouseEnter` no toque como se fosse um
	  mouse, entao soltar o dedo devolveria o botao ao tamanho de hover por um quadro
	  antes do `MouseLeave` chegar. Um toque que termina limpa os dois estados de uma
	  vez.

	Vai no `ItemMaid`, junto do resto do bind do container: um `_render` novo
	desconecta tudo e cancela o tween que estiver no meio.
]=]
function ShopController:_bindBuyFeedback(button : GuiButton)
	local scale = button:FindFirstChildWhichIsA("UIScale")
	if not scale then
		return
	end

	local state = { Hovered = false, Pressed = false }

	local tweenMaid = Maid.new()
	self.ItemMaid:GiveTask(tweenMaid)

	local function refresh()
		applyButtonScale(tweenMaid, scale, state)
	end

	self.ItemMaid:GiveTask(button.MouseEnter:Connect(function()
		state.Hovered = true
		refresh()
	end))

	self.ItemMaid:GiveTask(button.MouseLeave:Connect(function()
		state.Hovered = false
		state.Pressed = false
		refresh()
	end))

	self.ItemMaid:GiveTask(button.InputBegan:Connect(function(input : InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		state.Pressed = true
		refresh()
	end))

	self.ItemMaid:GiveTask(button.InputEnded:Connect(function(input : InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		state.Pressed = false

		if input.UserInputType == Enum.UserInputType.Touch then
			state.Hovered = false
		end

		refresh()
	end))

	-- A escala autorada e a de parado. Um container que ficou grande porque o painel
	-- fechou com o mouse em cima dele volta ao normal no bind seguinte.
	scale.Scale = 1
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

	local priceLabel = buy:FindFirstChildWhichIsA("TextLabel")
	if priceLabel then
		priceLabel.Text = string.format(ShopConfig.PRICE_FORMAT, UIUtil.formatCommas(item.Price))
	end

	styleBuyButton(buy, item.Currency)

	if buy:IsA("GuiButton") then
		self.ItemMaid:GiveTask(buy.Activated:Connect(function()
			self:_requestPurchase(item)
		end))

		self:_bindBuyFeedback(buy)
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

--[=[
	Liga e desliga a `ShopUI`.

	Sempre pelo `InterfaceController` quando ele existe: e ele quem guarda o que o
	dono de cada GUI queria, e escrever no `Enabled` direto no meio de um pedido
	(o dele, ou o da cutscene) faria o valor certo ser lido tarde demais. Ver o
	comentario do `SetEnabled` la.
]=]
function ShopController:_setShopEnabled(enabled : boolean)
	local screenGui = self.ScreenGui
	if not screenGui or not screenGui.Parent then
		return
	end

	local interface = self.Controllers.InterfaceController

	if interface then
		interface:SetEnabled(screenGui, enabled)
	else
		screenGui.Enabled = enabled
	end
end

--[=[
	O `BlurEffect` do fundo, criado na primeira vez que a loja abre.

	Procurado pelo nome antes de ser criado: o `UILibraryController` cria o mesmo
	`UIBlur` para os paineis dele, e quem chegar primeiro ganha. A marca do
	`LightingKeep` e (re)escrita sempre, porque a instancia pode ter vindo de la sem
	ela.
]=]
function ShopController:_getBlur() : BlurEffect
	local blur = Lighting:FindFirstChild(BLUR_NAME)

	if not blur or not blur:IsA("BlurEffect") then
		blur = Instance.new("BlurEffect")
		blur.Name = BLUR_NAME
		blur.Size = 0
		blur.Parent = Lighting
	end

	blur:SetAttribute(LightingConfig.KeepAttribute, true)

	return blur
end

--[=[
	Leva o borrao a `BLUR_SIZE` na abertura e de volta a zero no fechamento.

	Um tween por vez, no `BlurMaid`: fechar no meio da abertura cancela a subida e
	desce a partir de onde ela chegou, em vez de as duas escreverem no mesmo `Size` ao
	mesmo tempo.

	`Tween:Cancel()` nao devolve a propriedade -- e o que faz as duas emendarem.
]=]
function ShopController:_playBlur(open : boolean)
	-- Fechar sem nunca ter aberto nao cria efeito nenhum: o `_releaseScreen` roda no
	-- bind de toda copia da `ShopUI`, e um `BlurEffect` por jogador que nunca chegou
	-- perto da loja e lixo no Lighting.
	if not open and not Lighting:FindFirstChild(BLUR_NAME) then
		return
	end

	local blur = self:_getBlur()

	self.BlurMaid:DoCleaning()

	local duration = (self.PanelTrack and self.PanelTrack.Duration) or BLUR_FALLBACK_TIME
	local info = TweenInfo.new(duration, BLUR_EASING_STYLE, BLUR_EASING_DIRECTION)
	local tween = TweenService:Create(blur, info, { Size = if open then BLUR_SIZE else 0 })

	self.BlurMaid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
end

--[=[
	Devolve a tela: o resto da UI volta e o borrao sai.

	Chamado no `Close` e tambem no bind de uma copia nova da `ShopUI` -- morrer com a
	loja aberta traz uma `ScreenGui` nova e zera o `IsOpenState`, e sem isto o pedido
	de esconder ficaria de pe com a loja fechada, deixando o jogador sem HUD.

	`Show` e `_playBlur(false)` sao idempotentes, entao chamar com a loja ja fechada
	nao faz nada.
]=]
function ShopController:_releaseScreen()
	local interface = self.Controllers.InterfaceController
	if interface then
		interface:Show(HIDE_REASON)
	end

	self:_playBlur(false)
end

--[=[
	Drives the panel through OpenShop. The track is created once per ShopUI and kept,
	so opening and closing is a direction change on the same animation -- closing
	mid-open picks up from wherever the panel got to instead of snapping.
]=]
function ShopController:_playPanel(reverse : boolean)
	local track = self.PanelTrack
	if not track then
		return
	end

	if track.State ~= "Playing" then
		track:Scrub(reverse and track.Duration or 0)
	end

	track:SetSpeed(reverse and -1 or 1)
	track:Play()
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

function ShopController:_watchShards()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_updateShards()

		-- DataService writes the whole Stats key, but listen through OnChange so any
		-- deeper write (Stats.Shards, ...) refreshes the counter too.
		local connection = replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
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
]=]
function ShopController:_getMapPart(partName : string) : Instance?
	local cached = self.MapParts[partName]
	if cached and cached.Parent then
		return cached
	end

	local parent = workspace:FindFirstChild(ShopConfig.REFERENCE_PARENT_NAME)
	local part = parent and parent:FindFirstChild(partName)

	if not part and not self.WarnedMissing[partName] then
		self.WarnedMissing[partName] = true
		warn(`[ShopController]: no Workspace.{ShopConfig.REFERENCE_PARENT_NAME}.{partName}.`)
	end

	self.MapParts[partName] = part
	return part
end

--[=[
	Where a marker part sits, whether it is a bare part or a model.
]=]
local function getPivot(part : Instance?) : CFrame?
	if not part then
		return nil
	end

	if part:IsA("BasePart") then
		return part.CFrame
	elseif part:IsA("Model") then
		return part:GetPivot()
	end

	return nil
end

function ShopController:_getReferencePosition() : Vector3?
	local pivot = getPivot(self:_getMapPart(ShopConfig.REFERENCE_PART_NAME))
	return pivot and pivot.Position or nil
end

--[=[
	Opens the shop when the player walks up to the part and closes it when they walk
	away. Only the crossing acts, so closing the panel by hand while still standing
	there does not fight the player by reopening it every check.
]=]
function ShopController:_updateProximity()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = root and self:_getReferencePosition()

	local inRange = false
	if position and root then
		inRange = (root.Position - position).Magnitude <= ShopConfig.OPEN_RADIUS
	end

	if inRange == self.InRange then
		return
	end

	self.InRange = inRange

	if inRange then
		self:Open()
	else
		self:Close()
	end
end

function ShopController:_watchProximity()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.ProximityClock += deltaTime

		if self.ProximityClock < ShopConfig.PROXIMITY_INTERVAL then
			return
		end

		self.ProximityClock = 0
		self:_updateProximity()
	end))
end

--[=[
	Binds to a ShopUI instance. ShopUI has ResetOnSpawn enabled, so this runs again
	for every fresh copy the engine parents into PlayerGui.
]=]
function ShopController:_bindUI(screenGui : ScreenGui)
	local wrapper = screenGui:WaitForChild(WRAPPER_NAME, 10)
	local panel = wrapper and wrapper:WaitForChild(PANEL_NAME, 10)
	local list = panel and panel:WaitForChild(LIST_NAME, 10)

	if not wrapper or not panel or not list then
		warn(`[ShopController]: could not find {SHOP_UI_NAME}.{WRAPPER_NAME}.{PANEL_NAME}.{LIST_NAME}.`)
		return
	end

	self.UIMaid:DoCleaning()
	self.ItemMaid:DoCleaning()

	self.ScreenGui = screenGui
	self.Panel = panel
	self.List = list

	--[[
		O painel e a moldura de fora nascem `Visible = false` no StarterGui. Quem
		manda em ver ou nao ver a loja e o `Enabled` da ScreenGui, entao os dois sobem
		acesos e ficam assim -- a `OpenShop` cuida da entrada pela escala e pela
		transparencia.
	]]
	wrapper.Visible = true
	panel.Visible = true

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

	--[[
		O X da loja.

		Procurado a partir do `Frame` de fora e **em profundidade**: hoje ele e filho
		direto dele, pendurado no canto de cima, e nao do painel desenhado. Buscar so
		no painel deixaria o botao mudo. A busca comeca no wrapper e nao na ScreenGui
		para nao alcancar o `Close` do painel antigo (`ShopUI.ImageLabel`), que e irmao
		dele e continua na arvore.

		Fechar na mão não desliga a proximidade: o `_updateProximity` só age na
		**travessia**, então o painel não é reaberto no tick seguinte só porque o
		jogador continua parado ali. Ele volta quando o jogador sair do raio e
		voltar — que é o que "fechei porque não quero agora" quer dizer.

		Vai no `UIMaid`, junto com o resto do bind: a `ShopUI` é `ResetOnSpawn`, e a
		cópia nova traz um botão novo.
	]]
	local closeButton = wrapper:FindFirstChild(CLOSE_BUTTON_NAME, true)

	if closeButton and closeButton:IsA("GuiButton") then
		self.UIMaid:GiveTask(closeButton.Activated:Connect(function()
			self:Close()
		end))
	else
		warn(`[ShopController]: no {CLOSE_BUTTON_NAME} under {SHOP_UI_NAME}.{WRAPPER_NAME} -- the shop only closes by walking away.`)
	end

	--[[
		A `OpenShop` escreve em `UIScale/Scale` e em `ImageTransparency`. O painel novo
		nao traz um `UIScale` autorado, e sem ele a primeira faixa nao teria onde
		escrever -- a loja apareceria por fade, sem crescer. Criar aqui e inofensivo
		para um painel que ja tenha o seu: o `FindFirstChildWhichIsA` acha o autorado
		primeiro.
	]]
	if not panel:FindFirstChildWhichIsA("UIScale") then
		local scale = Instance.new("UIScale")
		scale.Name = "PanelScale"
		scale.Parent = panel
	end

	self.PanelTrack = AnimationService.CreateTrack(panel, ShopConfig.OPEN_ANIMATION)

	if self.PanelTrack then
		local connection = self.PanelTrack.Completed:Connect(function()
			-- Only the closing pass ends with the panel hidden.
			if not self.IsOpenState and screenGui.Parent then
				self:_setShopEnabled(false)
			end
		end)

		self.UIMaid:GiveTask(function()
			connection.Disconnect()
		end)
	end

	self.Entries = {}
	self.IsOpenState = false
	self.OpenToken += 1

	--[[
		A copia nova nasce apagada, e o que a copia velha tinha pedido e devolvido.

		A `ShopUI` e `ResetOnSpawn`: morrer com a loja aberta traz uma `ScreenGui` nova
		e zera o `IsOpenState` aqui. Sem devolver a tela, o pedido de esconder ficaria
		de pe com a loja fechada -- o jogador renasceria sem HUD e com o fundo borrado.
	]]
	self:_setShopEnabled(false)
	self:_releaseScreen()

	-- A fresh copy means a respawn: the player may well still be standing next to
	-- the part, and the next check has to open the new panel.
	self.InRange = false

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

function ShopController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if not child:IsA("ScreenGui") then
			return
		end

		if child.Name == SHOP_UI_NAME then
			self:_bindUI(child)
		elseif child.Name == HUD_UI_NAME then
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
	return self.IsOpenState == true
end

function ShopController:Open()
	if not self.ScreenGui or not self.ScreenGui.Parent or self.IsOpenState then
		return
	end

	self.IsOpenState = true
	self.OpenToken += 1

	--[[
		A loja e a unica coisa na tela enquanto esta aberta: o HUD, o portal e o que
		mais a lobby tiver saem, e voltam ao que o dono deles queria no fechamento.

		O `Except` e a propria `ShopUI`, senao o pedido esconderia o painel que ele
		esta abrindo.
	]]
	local interface = self.Controllers.InterfaceController
	if interface then
		interface:Hide(HIDE_REASON, { Except = { SHOP_UI_NAME } })
	end

	--[[
		Pelo `_setShopEnabled`, e nao no `Enabled` direto: o aviso de `Enabled` chega
		no fim do quadro, e a loja acende no **mesmo** instante em que o pedido varre
		as GUIs. Escrevendo direto, o pedido ainda leria o `false` de antes como o que
		o dono queria e apagaria o painel de volta no mesmo quadro.
	]]
	self:_setShopEnabled(true)

	self:_playPanel(false)
	self:_playBlur(true)

	self.Signals.OpenChanged:Fire(true)
end

function ShopController:Close()
	if not self.ScreenGui or not self.IsOpenState then
		return
	end

	self.IsOpenState = false
	self.OpenToken += 1

	-- Devolvida no comeco do fechamento, e nao no fim dele: o resto da UI e o fundo
	-- voltam **atras** do painel, em vez de aparecerem de uma vez depois que ele sai.
	self:_releaseScreen()

	if self.PanelTrack then
		-- The panel hides when the reversed animation completes, in _bindUI.
		self:_playPanel(true)
	else
		self:_setShopEnabled(false)
	end

	self.Signals.OpenChanged:Fire(false)
end

--[=[
	Drops the player on the teleport marker next to the shop. The marker sits inside
	OPEN_RADIUS, so the proximity check opens the panel right after the landing --
	the button does not open it by hand.

	The client owns its own character, so moving it here is enough; the server sees
	the new position through the usual replication.
]=]
function ShopController:TeleportToShop() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not root then
		return false
	end

	local pivot = getPivot(self:_getMapPart(ShopConfig.TELEPORT_PART_NAME))
	if not pivot then
		return false
	end

	local part = self.MapParts[ShopConfig.TELEPORT_PART_NAME]
	local halfHeight = (part and part:IsA("BasePart")) and (part.Size.Y / 2) or 0

	character:PivotTo(pivot * CFrame.new(0, halfHeight + ShopConfig.TELEPORT_HEIGHT_OFFSET, 0))

	-- Without this the player keeps whatever momentum they had and slides off.
	root.AssemblyLinearVelocity = Vector3.zero

	-- The landing is inside OPEN_RADIUS, so proximity would open the panel on its
	-- own -- except for a player who was already in range and had closed it by hand.
	-- Opening here makes the button behave the same either way.
	self:Open()

	return true
end

function ShopController:Toggle()
	if self.IsOpenState then
		self:Close()
	else
		self:Open()
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

	self:_observeUI()
	self:_watchShards()
	self:_watchProximity()
end

function ShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function ShopController:init()
	self.Maid = Maid.new()
	self.UIMaid = Maid.new()
	self.ItemMaid = Maid.new()
	self.HudMaid = Maid.new()

	-- O tween do borrao vive fora do bind da UI: ele e do Lighting, e nao da
	-- `ScreenGui` que a engine refaz a cada respawn.
	self.BlurMaid = Maid.new()

	self.Maid:GiveTask(self.UIMaid)
	self.Maid:GiveTask(self.ItemMaid)
	self.Maid:GiveTask(self.HudMaid)
	self.Maid:GiveTask(self.BlurMaid)

	-- Uma entrada por caixa desenhada: o item, o container dela e as linhas de
	-- raridade que estao na tela agora.
	self.Entries = {}
	self.IsOpenState = false

	-- As chances por item, vindas do servidor -- nil enquanto a resposta nao chega.
	self.CrateOdds = nil
	self.OddsRequested = false

	-- Marker parts in the map, by name, and the names already warned about. O mesmo
	-- mapa guarda o container que faltou, pela mesma razao: avisar uma vez.
	self.MapParts = {}
	self.WarnedMissing = {}

	-- Bumped on every open, close and rebind, so a delayed batch that belongs to a
	-- previous open does not fire over the current one.
	self.OpenToken = 0

	self.InRange = false
	self.ProximityClock = 0
end

return ShopController
