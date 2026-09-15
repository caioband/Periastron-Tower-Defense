local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Utils = Shared:WaitForChild("Util")

local UIAssets = Assets:WaitForChild("UI")

local SharedConfig = require(Configs.SharedConfig)
local PointerUtil = require(Utils.PointerUtil)
local UIUtil = require(Utils.UIUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

local RoundCardConfig = SharedConfig.RoundCardConfig

local GUI = RoundCardConfig.Gui
local ANIM = RoundCardConfig.Animation
local USE = RoundCardConfig.Use
local TARGETING = RoundCardConfig.Targeting

local WAIT_TIMEOUT = 60

-- O som de carta, o mesmo do painel de deck e da hotbar.
local CARD_SOUND = "CardFlip"

-- Os **parametros** do marcador de keyframe do gesto (ver `_playUseVisual`). Vem do
-- config porque o servidor procura pela mesma palavra ao conferir o `EffectDelay`.
local MARKERS = RoundCardConfig.Markers

local CHARACTER_ROOT = "HumanoidRootPart"

--[[
	Quanto o anel de uma carta de area precisa andar para a previa ser refeita, em
	studs.

	A previa e uma varredura por todas as unidades do mapa, e o cursor parado manda o
	mesmo ponto sessenta vezes por segundo. Um decimo de stud e menor do que qualquer
	movimento que mude quem esta dentro do anel, e corta a varredura inteira nos
	quadros em que o jogador nao mexeu a mao.
]]
local PREVIEW_STEP = 0.1

-- Quanto o jogador pode ficar ancorado, no maximo, esperando a animacao terminar.
-- E rede de seguranca, e nao a duracao do gesto: ver o `task.delay` no fim do
-- `_playUseVisual`.
local ANCHOR_TIMEOUT = 8

--[=[
	A loja de cartas de round, do lado da tela.

	Quem decide **quando** ela abre, **quais** cartas saem e **se** a compra vale e
	o `CardShopService`. Daqui sai so o desenho: o botao que entra pela beirada, o
	escurecido de tela cheia, as tres cartas caindo e a carta comprada indo parar
	na hotbar.

	O caminho de uma oferta:

		1. o servidor manda `RoundCardState` com um `token` e tres ids de carta; o
		   botao `RCSFrame` entra pela direita e fica balancando na beirada;
		2. o clique no `CardShop` recolhe o proprio botao, escurece a tela, apaga a
		   hotbar e desenha as tres cartas, uma a cada `CardStagger`;
		3. o clique numa carta pede a compra e recolhe a loja na hora; a carta so
		   entra na hotbar quando o `RoundCardBought` confirma;
		4. o clique (ou toque) **fora** das cartas toca a entrada delas ao contrario e
		   fecha a loja; o botao **nao** volta -- ele foi gasto no clique de abrir, e
		   so a proxima oferta (outro `token`, na proxima wave de loja) o traz de
		   volta para a beirada;
		5. o clique na carta da hotbar pede o uso -- na hora, se a carta for
		   instantanea, ou depois da **mira**, se ela pedir alvo. A carta some quando o
		   `RoundCardUsed` confirma, que e tambem quando o personagem de quem usou faz
		   o gesto dela, se ela tiver um `Visual` no config. O gesto e da **sala**: a
		   animacao replica sozinha, e o som e as particulas chegam nas outras telas
		   pelo `RoundCardVisual` (ver `_playRemoteUseVisual`).

	## A mira

	Nem toda carta age sozinha. O `Use` do `RoundCardConfig` diz o que ela pede antes
	de agir: nada (`Instant`), uma torre (`Unit`), um lugar (`Area`) ou os dois em
	fila (`Move`, que e o Zippers). Pedindo alvo, o clique na hotbar nao vira pedido
	-- ele entra na mira, e quem vira pedido e o clique **seguinte**, o que escolhe.

	**Uma carta em mira e uma carta na mao**, e a hotbar a desenha como desenha uma
	unidade equipada: ela cresce e as vizinhas apagam (`Card:setSelectedRound`). Nao
	ha painel nem botao de cancelar -- o aviso e a propria carta, do mesmo jeito que
	nao ha aviso nenhum quando o jogador poe uma unidade na mao. Desistir e clicar
	nela de novo, igual a largar a unidade; no PC o Esc tambem serve.

	Enquanto a mira dura, o clique no mundo pertence a carta: o
	`UnitPlacementController` larga a mao inteira (o fantasma, a torre selecionada e
	a carta de unidade equipada) e para de selecionar torre. Sem isso o mesmo clique
	faria as duas coisas, e o fantasma de uma unidade equipada disputaria o mesmo
	ponto do mapa. Ele volta ao normal quando a mira acaba, de que jeito for --
	confirmada, cancelada, ou com a carta saindo da mao por baixo dela.

	Desistir nao custa nada: a carta so e gasta quando o servidor confirma o uso, e
	escolher um lugar e depois mudar de ideia nao e usar a carta. Quem confere o alvo
	e o servidor, como tudo o mais -- daqui sai a escolha, e nao a permissao.

	**Nada e desenhado por conta propria.** A carta nao entra no deck no clique e
	nao sai dele no uso: as duas coisas esperam a confirmacao do servidor, que e
	quem tem o dinheiro e o estoque. Recusado, o `RoundCardState` que chega em
	seguida devolve a tela ao que o servidor sabe -- a carta nao aparece na hotbar,
	e o botao da beirada continua recolhido: ele e gasto na abertura, e nao na
	compra.

	**A carta e um clone do molde autorado**, e o molde e tirado da tela na primeira
	vez que ele e preciso (como o `Components/Card` faz com o `CardWrapper` da
	hotbar). As transparencias de destino sao lidas de cada clone recem-feito, antes
	de qualquer animacao: "voltar ao original" e literal, e repintar no Studio basta.
]=]
local RoundCardShopController = {
	Controllers = {
		MusicController = {},
		UILibraryController = {},
		VFXController = {},

		-- Quem sabe que torre esta debaixo do ponteiro, e quem tranca o clique no
		-- mundo enquanto uma carta esta pedindo alvo. Ver `_beginTargeting`.
		UnitPlacementController = {},

		-- Quem desenha o buff e o debuff em cima das unidades. E ele quem mostra, na
		-- cabeca de cada torre, o que a carta que esta sendo mirada faria com ela.
		WeatherFeedbackController = {},

		-- Quem tem a lista das areas que ja estao no chao. E ele quem diz se o anel
		-- debaixo do cursor encosta numa area deste jogador. Ver `_updateTargeting`.
		CardModifierController = {},
	},
}

--[[ INTERNAL ]]

--[=[
	As duas metades da revelacao de uma carta, do `UIUtil`: o `captureFades` le o que
	o designer deixou no clone intocado e o `applyFades` leva tudo de transparente
	ate lá.

	Elas moram no `UIUtil` porque a **loja de cartas do lobby** desenha a mesma carta
	pelo mesmo caminho (ver o `RoundCardShopController` do Lobby): uma segunda copia
	aqui seria a mesma varredura de propriedades para manter em dois lugares.

	Este embrulho e so a curva. A entrada chega desacelerando (`CardDirection`, que e
	`Out`) e a saida sai acelerando (`In`): sem isso o sumico das cartas arrastaria no
	comeco e pareceria travamento, e nao resposta ao clique.
]=]
local captureFades = UIUtil.captureFades

local function applyFades(fades, progress : number, time : number?, direction : Enum.EasingDirection?)
	local info = time and TweenInfo.new(time, ANIM.CardEasing, direction or ANIM.CardDirection)

	UIUtil.applyFades(fades, progress, info)
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
	local token = self.FrameToken

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

	-- O balanco so comeca com o botao ja encaixado na beirada: gingar durante a
	-- entrada brigaria com o proprio deslize e faria o botao chegar torto.
	tween.Completed:Connect(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed or self.FrameToken ~= token then return end

		self:_startIdle()
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
	self:_stopIdle()

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

--[=[
	Poe o botao para balancar enquanto ninguem clica nele.

	Sao dois movimentos ao mesmo tempo: ele sobe `IdleLift` pixels e fica gingando
	entre `+IdleSwing` e `-IdleSwing` graus, para sempre. O vai-e-vem infinito e um
	tween so, com `repeatCount = -1` e `reverses = true` -- o `swingIn` existe
	porque o balanco comeca no meio (na rotacao autorada) e o loop precisa partir
	de uma das pontas, senao a primeira travessia sairia pela metade.

	**A altura e a rotacao de volta sao lidas do Studio**, e nao escritas aqui: e o
	`ButtonPosition` / `ButtonRotation` que o bind guardou antes de qualquer
	animacao tocar.
]=]
function RoundCardShopController:_startIdle()
	local button = self.Button
	if not button then return end

	self.IdleMaid:DoCleaning()

	local base = self.ButtonPosition
	local rotation = self.ButtonRotation

	local lift = TweenService:Create(
		button,
		TweenInfo.new(ANIM.IdleLiftTime, ANIM.IdleEasing, Enum.EasingDirection.Out),
		{ Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset - ANIM.IdleLift) }
	)

	local swingIn = TweenService:Create(
		button,
		TweenInfo.new(ANIM.IdleSwingTime / 2, ANIM.IdleEasing, Enum.EasingDirection.Out),
		{ Rotation = rotation + ANIM.IdleSwing }
	)

	local swing = TweenService:Create(
		button,
		TweenInfo.new(ANIM.IdleSwingTime, ANIM.IdleEasing, Enum.EasingDirection.InOut, -1, true),
		{ Rotation = rotation - ANIM.IdleSwing }
	)

	self.IdleMaid:GiveTask(function()
		lift:Cancel()
		swingIn:Cancel()
		swing:Cancel()
	end)

	self.IdleMaid:GiveTask(swingIn.Completed:Connect(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed then return end

		swing:Play()
	end))

	lift:Play()
	swingIn:Play()
end

--[=[
	Desliga o balanco e devolve o botao ao estado autorado.

	A volta e um tween, e nao uma escrita seca: o botao pode estar em qualquer
	ponto da ginga na hora do clique, e cortar para a rotacao zero no mesmo quadro
	daria um solavanco bem na resposta ao clique.
]=]
function RoundCardShopController:_stopIdle()
	local button = self.Button
	if not button then return end

	self.IdleMaid:DoCleaning()

	local tween = TweenService:Create(
		button,
		TweenInfo.new(ANIM.IdleReturn, ANIM.CardEasing, Enum.EasingDirection.Out),
		{ Position = self.ButtonPosition, Rotation = self.ButtonRotation }
	)

	self.IdleMaid:GiveTask(function()
		tween:Cancel()
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

--[=[
	Tira as cartas que estao na fileira. A da compra ja foi clonada antes disto.

	O `DismissToken` sobe junto: uma saida em andamento nao pode continuar mexendo
	em cartas que acabaram de ser destruidas -- e a oferta nova, que chega quando a
	wave vira com a loja aberta, faz exatamente isso.
]=]
function RoundCardShopController:_clearRow()
	self.CardEntries = {}
	self.Dismissing = false
	self.DismissToken += 1

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

		--[[
			O que a saida precisa saber para tocar esta mesma animacao ao contrario:
			onde a carta mora, para onde as transparencias voltam e o que ainda esta
			no ar (o atraso da entrada e o tween da queda) e precisa ser cancelado.
		]]
		local entry = {
			Wrapper = wrapper,
			Card = card,
			Fades = fades,
			BasePosition = basePosition,
			Ready = false,
		}

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

		applyFades(fades, 0)

		wrapper.Parent = row
		self.RowMaid:GiveTask(wrapper)

		--[[
			A carta so aceita clique depois de comecar a cair. Ela ja existe na tela
			desde o `Parent`, transparente e fora do lugar, e sem isto a terceira carta
			-- que so entra um segundo depois -- poderia ser comprada enquanto ainda
			nao ha nada para o jogador ver.
		]]
		if card:IsA("GuiButton") then
			self.RowMaid:GiveTask(card.Activated:Connect(function()
				if not entry.Ready or self.Dismissing then return end

				self:_buy(cardId)
			end))

			--[[
				A marca do clique que **foi** numa carta.

				Quem escuta o clique-fora e o `UserInputService`, que ve **todo** clique,
				inclusive o que caiu numa carta. Esta marca e o que diz a ele que aquele
				input ja tinha dono -- ver o `InputBegan` em `_openShop`.
			]]
			self.RowMaid:GiveTask(card.InputBegan:Connect(function(input : InputObject)
				self.CardInput = input
			end))
		end

		local delayed = task.delay((index - 1) * ANIM.CardStagger, function()
			if not wrapper.Parent then return end

			entry.Ready = true

			local dropInfo = TweenInfo.new(ANIM.CardDrop, ANIM.CardEasing, ANIM.CardDirection)
			local goal : { [string] : any } = { Position = basePosition }

			if card:IsA("ImageLabel") or card:IsA("ImageButton") then
				goal.ImageTransparency = 0
			end

			local drop = TweenService:Create(card, dropInfo, goal)
			entry.Drop = drop

			drop.Completed:Connect(function(state : Enum.PlaybackState)
				if state ~= Enum.PlaybackState.Completed or not wrapper.Parent then return end

				applyFades(fades, 1, ANIM.CardReveal)
			end)

			drop:Play()
		end)

		entry.Delayed = delayed

		self.RowMaid:GiveTask(function()
			pcall(task.cancel, delayed)
		end)
	end
end

--[[ ABRIR E FECHAR ]]

--[=[
	Abre a aba da loja: o botao da beirada recolhe, a tela escurece, a hotbar apaga
	e, quando o escurecido termina, as cartas comecam a cair.

	As cartas so entram depois do fundo de proposito -- a queda delas e contra o
	escuro, e desenha-las durante o fade as poria aparecendo por cima da partida.

	O botao sai junto com a abertura e **nao volta nesta oferta**. Ele e o convite de
	uma wave de loja, e o clique e a resposta: sair sem comprar continua sendo uma
	escolha, e nao um engano a desfazer. O `OpenedToken` e o que guarda isso -- a
	beirada so acende de novo com um `token` diferente, ou seja, na proxima wave de
	loja da dificuldade.
]=]
function RoundCardShopController:_openShop()
	local background = self.Background
	if not background or self.ShopOpen or not self.Offer then return end

	self.ShopOpen = true
	self.OpenToken += 1
	local token = self.OpenToken

	self.OpenedToken = self.Offer.token

	self:_hideFrame()
	self:_setDeckHidden(true)
	self:_clearRow()

	--[=[
		O clique (ou toque) fora das cartas desfaz a oferta na tela.

		Quem escuta e o `UserInputService`, e nao o escurecido. O fundo parecia o
		dono natural do assunto -- ele cobre a tela -- mas ele so recebe o clique que
		ninguem mais quis: **qualquer** `ScreenGui` com `DisplayOrder` maior (o HUD,
		o container da hotbar) come o clique antes dele, e ali a loja ficava aberta
		sem jeito de sair a nao ser comprando. O `UserInputService` ve o clique
		independentemente de quem o consumiu, e a loja e modal: clique em lugar
		nenhum e clique em qualquer outra coisa fecham igual.

		O que **nao** fecha e o clique numa das tres cartas, e e o `CardInput` que
		diz isso: a carta marca o proprio `InputObject`, e a conferencia sai num
		`task.defer` porque a ordem entre os dois handlers do mesmo evento nao e
		promessa de lugar nenhum -- um quadro depois os dois ja rodaram. Comparar
		objeto de input dispensa medir retangulo na tela, e medir seria pior: a
		conta entre `InputObject.Position` e `AbsolutePosition` muda com o
		`IgnoreGuiInset` da tela e com a barra do topo no celular.
	]=]
	self.ShopMaid:GiveTask(UserInputService.InputBegan:Connect(function(input : InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		task.defer(function()
			if input == self.CardInput then return end

			self:_dismissShop()
		end)
	end))

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
	Fecha a aba e devolve a hotbar.

	Sem `fade`, o escurecido some na hora -- e o que a compra pede: ela ja tem a
	animacao dela, que e o botao da beirada recolhendo, e um segundo fade por cima
	disso so atrasaria o jogador de voltar a partida.

	Com `fade`, o escurecido sai em `fade` segundos. E o caminho do clique fora das
	cartas, onde nao houve compra nenhuma: ali a tela some sozinha, e cortar o
	escuro de uma vez pareceria erro em vez de recuo.
]=]
function RoundCardShopController:_closeShop(fade : number?)
	if not self.ShopOpen then return end

	self.ShopOpen = false
	self.OpenToken += 1
	local token = self.OpenToken

	self.ShopMaid:DoCleaning()
	self:_clearRow()

	local background = self.Background
	if background then
		if fade then
			local tween = TweenService:Create(
				background,
				TweenInfo.new(fade, ANIM.CardEasing, Enum.EasingDirection.In),
				{ BackgroundTransparency = 1 }
			)

			-- Reabrir durante o fade manda: o escurecido que esta na tela agora e o da
			-- loja nova, e desliga-lo aqui apagaria uma aba que acabou de abrir.
			tween.Completed:Connect(function(state : Enum.PlaybackState)
				if state ~= Enum.PlaybackState.Completed or self.OpenToken ~= token then return end

				background.Visible = false
				background.BackgroundTransparency = self.BackgroundTarget
			end)

			tween:Play()
		else
			background.Visible = false
			background.BackgroundTransparency = self.BackgroundTarget
		end
	end

	self:_setDeckHidden(false)
end

--[=[
	Toca a entrada das cartas ao contrario e chama `onFinished` quando a ultima
	termina.

	A ordem e o espelho da entrada: o conteudo desce de volta ao transparente
	(`CardReveal`) e so entao a carta sobe apagando a imagem (`CardDrop`) -- se as
	duas metades saissem juntas, o texto ficaria boiando sozinho no ar depois que a
	carta ja tivesse subido.

	Carta que ainda estava caindo entra na saida do mesmo jeito: o atraso que nao
	comecou e cancelado e a queda em andamento e cortada, entao ela sobe do ponto
	onde estava, em vez de continuar descendo enquanto o resto some.
]=]
function RoundCardShopController:_dismissCards(onFinished : (() -> ())?)
	self.DismissToken += 1
	local token = self.DismissToken
	self.Dismissing = true

	local longest = 0

	for index, entry in self.CardEntries do
		local stagger = (index - 1) * ANIM.CardExitStagger
		longest = math.max(longest, stagger + ANIM.CardReveal + ANIM.CardDrop)

		local dismiss = task.delay(stagger, function()
			local card = entry.Card
			if self.DismissToken ~= token or not card.Parent then return end

			entry.Ready = false

			if entry.Delayed then
				pcall(task.cancel, entry.Delayed)
			end

			if entry.Drop then
				entry.Drop:Cancel()
			end

			applyFades(entry.Fades, 0, ANIM.CardReveal, Enum.EasingDirection.In)

			task.wait(ANIM.CardReveal)
			if self.DismissToken ~= token or not card.Parent then return end

			local base = entry.BasePosition
			local goal : { [string] : any } = {
				Position = UDim2.new(
					base.X.Scale, base.X.Offset,
					base.Y.Scale - ANIM.DropOffset, base.Y.Offset
				),
			}

			if card:IsA("ImageLabel") or card:IsA("ImageButton") then
				goal.ImageTransparency = 1
			end

			TweenService:Create(
				card,
				TweenInfo.new(ANIM.CardDrop, ANIM.CardEasing, Enum.EasingDirection.In),
				goal
			):Play()
		end)

		self.RowMaid:GiveTask(function()
			pcall(task.cancel, dismiss)
		end)
	end

	--[[
		Este e o unico atraso que **nao** entra no maid da fileira: e ele quem fecha a
		loja, e fechar a loja limpa o maid -- ele se cancelaria no meio da propria
		chamada, e a hotbar nunca voltaria. O `DismissToken` ja faz o servico: uma
		oferta nova que chegue antes da hora derruba este fim quando ele acordar.
	]]
	task.delay(longest, function()
		if self.DismissToken ~= token then return end

		self.Dismissing = false

		if onFinished then
			onFinished()
		end
	end)
end

--[=[
	A saida sem compra: as cartas somem ao contrario e o escurecido apaga.

	O botao **nao** volta, e e de proposito: ele foi gasto no clique que abriu a
	loja, e quem o traz de volta e a proxima oferta -- ver o `OpenedToken` em
	`_openShop`. A oferta em si continua de pe no servidor (quem a tira e a compra
	ou a virada do round), entao a carta segue comprável se o estado for redesenhado
	por outro caminho; o que acabou foi o convite na beirada.
]=]
function RoundCardShopController:_dismissShop()
	if not self.ShopOpen or self.Dismissing then return end

	self:_dismissCards(function()
		self:_closeShop(ANIM.BackgroundFadeOut)
	end)
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
		self:_requestUse(uid, cardId)
	end)
end

--[=[
	O clique numa carta da hotbar.

	Carta instantanea vira pedido na hora, como sempre foi. Carta que pede alvo
	entra na mira, e so vira pedido no clique seguinte -- o que escolhe a torre ou o
	lugar.

	Clicar de novo na carta que **ja** esta mirando desiste dela. E o par natural do
	clique que comecou: quem clicou por engano procura o mesmo lugar para desfazer, e
	nao o botao de cancelar.
]=]
function RoundCardShopController:_requestUse(uid : string, cardId : string)
	if self.UsePending[uid] then return end

	if self.Targeting and self.Targeting.Uid == uid then
		self:_cancelTargeting()
		return
	end

	local use = RoundCardConfig.GetUse(cardId)

	if use == USE.Instant then
		self:_sendUse(uid, nil)
		return
	end

	self:_beginTargeting(uid, cardId, use)
end

--[=[
	Manda o uso para o servidor.

	`target` e o que a mira escolheu -- a torre, o lugar, ou os dois --, e vai como
	tabela porque o servidor confere campo por campo contra o tipo da carta.

	**Um uso por carta, e quem gasta e o servidor.** O trinco local existe para o
	clique duplo nao virar dois pedidos: o segundo seria recusado, mas o primeiro ja
	teria sumido com a carta e o jogador veria um erro no log por algo que ele nao fez
	de errado.
]=]
function RoundCardShopController:_sendUse(uid : string, target : any?)
	if self.UsePending[uid] then return end
	self.UsePending[uid] = true

	self:_stopTargeting()

	Framework:Fire("UseRoundCard", uid, target)
	self:_playSound(CARD_SOUND)
end

--[=[
	Tira da hotbar a carta que o servidor deu por usada (ou por perdida). Quem faz a
	carta cair para fora e fecha a vaga e o componente.
]=]
function RoundCardShopController:_removeFromDeck(uid : string)
	if not self.DeckCards[uid] then return end

	self.DeckCards[uid] = nil
	self.UsePending[uid] = nil

	--[[
		A carta que estava mirando saiu da mao: ou o servidor a gastou, ou ele a
		recusou e devolveu o estado. Nos dois casos nao ha mais o que mirar, e uma mira
		orfa deixaria o clique do jogador trancado num alvo que nao vai a lugar nenhum.
	]]
	if self.Targeting and self.Targeting.Uid == uid then
		self:_stopTargeting()
	end

	self:_deck("removeRound", uid)
end

--[=[
	O gesto de usar a carta: a animacao no personagem de quem usou, e o som e as
	particulas que ela dispara.

	**Quem manda no tempo e a animacao.** O `Marker` do config e um marcador de
	keyframe so, e o que separa as duas metades e o **parametro** dele: `Sound` toca
	o som, `VFX` estoura as particulas. Reanimar a carta no Moon Animator remarca as
	duas sem passar por aqui -- que e o que um `task.delay` com o tempo escrito no
	codigo nao daria.

	O clone do VFX nasce **agora**, no uso, e nao no marcador: pendurado na
	`HumanoidRootPart` ele acompanha o jogador, e fazer isso no meio da animacao
	arriscaria o quadro do estouro chegar antes de o asset estar no lugar. Em troca,
	quem pendura deve o estouro **ou** a faxina -- e por isso a animacao que termina
	sem passar pelo marcador leva o clone junto.

	Isto e o gesto **de quem usou**, na tela dele: o `RoundCardUsed` sai do servidor
	so para ele. Quem esta assistindo recebe `RoundCardVisual` e cai no
	`_playRemoteUseVisual` logo abaixo, que e a metade que falta na tela dos outros --
	a animacao e a trava ja chegam la sozinhas.
]=]
function RoundCardShopController:_playUseVisual(cardId : any)
	local definition = RoundCardConfig.Get(cardId)
	local visual = definition and definition.Visual
	if not visual then return end

	local character = Player.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)
	if not root or not root:IsA("BasePart") then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator or not visual.Animation then
		warn(`[RoundCardShopController]: a carta '{tostring(cardId)}' tem Visual, mas o personagem nao tem Animator (ou falta o AnimationId).`)
		return
	end

	local vfx = self.Controllers.VFXController
	local clone = vfx and vfx:AttachAsset(visual.VFX, root)

	--[[
		A `Animation` fica solta de proposito: quem a segura viva e a propria track,
		e as duas somem juntas quando a animacao termina e ninguem mais aponta para
		ela. Destrui-la aqui seria arrancar a referencia debaixo da track que acabou
		de nascer dela.
	]]
	local animation = Instance.new("Animation")
	animation.AnimationId = visual.Animation

	local track = animator:LoadAnimation(animation)

	--[[
		`Action` para o gesto passar por cima da idle do personagem. A prioridade vem
		assada no asset, e uma exportada como `Idle` ou `Core` empataria com a
		animacao que o `Animate` padrao ja esta tocando -- a carta seria usada e o
		boneco nao faria nada.
	]]
	track.Priority = Enum.AnimationPriority.Action

	local maid = Maid.new()
	local emitted = false

	--[[
		O jogador trava no lugar enquanto o gesto acontece: a carta para o tempo, e um
		personagem andando por baixo da propria pose entregaria que nada parou.
		Ancorar a `HumanoidRootPart` basta -- o resto do corpo vem pendurado nela.

		O estado anterior e lido, e nao presumido: ancorado ele ja podia estar por
		outro motivo, e devolver um `false` escrito na mao destravaria o que nao era
		nosso para destravar.
	]]
	local wasAnchored = root.Anchored
	root.Anchored = true

	--[=[
		O fim do gesto, de onde quer que ele venha: destrava o jogador, recolhe o que
		sobrou e desliga as escutas.

		Ele existe como funcao unica de proposito. Sao tres fins possiveis -- a
		animacao terminou, a animacao foi cortada, a animacao nunca tocou -- e o
		jogador **precisa** ser destravado nos tres. Deixar o `Anchored = false` em
		um caminho so era a maneira de a partida dele acabar ali.
	]=]
	local done = false
	local function finish()
		if done then return end
		done = true

		-- O personagem pode ter morrido no meio: a peca ja nao esta em lugar nenhum,
		-- e o proximo `Character` vem com a `HumanoidRootPart` dele, solta.
		if root.Parent then
			root.Anchored = wasAnchored
		end

		if not emitted and clone and clone.Parent then
			clone:Destroy()
		end

		maid:DoCleaning()
	end

	maid:GiveTask(track:GetMarkerReachedSignal(visual.Marker):Connect(function(parameter : string?)
		if parameter == MARKERS.Sound then
			local sound = visual.Sound and SoundService:FindFirstChild(visual.Sound)
			if sound and sound:IsA("Sound") then
				sound:Play()
			end
		elseif parameter == MARKERS.VFX then
			emitted = true

			-- Daqui em diante a vida do clone e do proprio asset: o modulo tira o
			-- prazo do tempo de vida das particulas dele.
			if vfx then
				vfx:EmitAttached(clone)
			end
		end
	end))

	-- O fim normal: a animacao acabou, o jogador anda de novo.
	maid:GiveTask(track.Stopped:Connect(finish))

	track:Play()

	--[=[
		A rede de seguranca.

		Uma animacao que nao carrega (id errado, asset sem permissao) nunca toca e,
		por isso, nunca **para**: o `Stopped` nao vem, e sem prazo maximo o jogador
		ficaria ancorado no lugar ate morrer. Preso alguns segundos e um defeito;
		preso para sempre acaba a partida dele.

		O prazo e folgado de proposito -- ele so precisa ser maior que a animacao
		mais longa que uma carta venha a ter, e nunca cortar um gesto legitimo. Ele
		tambem nao e cancelado quando a animacao termina antes: acordar e ver que o
		`done` ja passou nao custa nada, e cancelar o fio de dentro dele mesmo seria
		mata-lo no meio da propria faxina.
	]=]
	task.delay(ANCHOR_TIMEOUT, finish)
end

--[=[
	O mesmo gesto, visto de fora: o som e as particulas da carta que **outro** jogador
	usou, no personagem dele.

	Duas metades chegam aqui sozinhas e nao sao refeitas. A **animacao** toca no
	personagem de quem usou, e o `Animator` a replica para todo mundo -- carrega-la de
	novo aqui poria duas tracks iguais no mesmo corpo. A **trava** e o mesmo caso: o
	dono ancora a `HumanoidRootPart` que ele controla, e o personagem para de andar em
	todas as telas por consequencia. O que nao atravessa e o som (que e local) e o VFX
	(que e um clone feito no cliente), e e so isso que este caminho faz.

	**O relogio aqui e o config, e nao o marcador.** O marcador de keyframe so chega
	em quem carregou a track, e esta tela nao carregou nenhuma -- ela esta olhando uma
	animacao replicada. `SoundDelay` e `EffectDelay` sao as copias dos instantes dos
	dois marcadores, e o `CardShopService` as confere contra a animacao de verdade
	quando sobe: e o mesmo numero que o servidor usa para cronometrar o congelamento,
	entao as particulas caem no quadro em que os inimigos param, aqui como la.

	O clone nasce agora e nao no estouro, pelo mesmo motivo do gesto do dono: pendurado
	na raiz ele acompanha o jogador, e cria-lo no ultimo instante arriscaria o asset
	chegar depois da hora.
]=]
function RoundCardShopController:_playRemoteUseVisual(cardId : any, user : Player?)
	if not user or user == Player then return end

	local definition = RoundCardConfig.Get(cardId)
	local visual = definition and definition.Visual
	if not visual then return end

	local character = user.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)
	if not root or not root:IsA("BasePart") then return end

	--[[
		O som e da **sala**, e nao do personagem: ele toca em `SoundService`, sem
		posicao. A carta congela os inimigos de todo mundo, e um som que sumisse com a
		distancia diria que o efeito e de la, e nao daqui.

		Por isso ele nao depende do clone nem do personagem continuar de pe: quem usou
		pode morrer no meio do gesto, e o congelamento acontece do mesmo jeito.
	]]
	if visual.Sound then
		task.delay(visual.SoundDelay or visual.EffectDelay or 0, function()
			local sound = SoundService:FindFirstChild(visual.Sound)
			if sound and sound:IsA("Sound") then
				sound:Play()
			end
		end)
	end

	local vfx = self.Controllers.VFXController
	local clone = vfx and vfx:AttachAsset(visual.VFX, root)
	if not clone then return end

	task.delay(visual.EffectDelay or 0, function()
		-- O personagem pode ter saido de cena no meio da espera, e o clone vai junto
		-- com ele: nao ha onde estourar, e nao ha o que limpar.
		if not clone.Parent then return end

		vfx:EmitAttached(clone)
	end)
end

--[[ A MIRA ]]

--[=[
	O anel que segue o ponteiro enquanto a carta pede um lugar.

	E o mesmo modelo do circulo de alcance de uma torre selecionada, de proposito: o
	jogador ja aprendeu que aquele desenho quer dizer "esta area". A escala sai do
	diametro da part de dentro dele, do mesmo jeito que o `UnitPlacementController`
	faz -- assim mexer no anel no Studio nao deixa o raio mentindo.
]=]
function RoundCardShopController:_buildRing(radius : number, color : Color3?) : Model?
	local template : Instance? = UIAssets
	for _, name in TARGETING.RingAsset do
		template = template and template:FindFirstChild(name)
	end

	if not template or not template:IsA("Model") then
		warn(`[RoundCardShopController]: nao achei o anel {table.concat(TARGETING.RingAsset, ".")} em Assets.UI; a mira fica sem circulo.`)
		return nil
	end

	local ring = template:Clone()
	local part = ring:FindFirstChild(TARGETING.RingPart)

	if part and part:IsA("BasePart") and part.Size.X > 0 then
		ring:ScaleTo(ring:GetScale() * (radius * 2) / part.Size.X)
	end

	for _, descendant in ring:GetDescendants() do
		if descendant:IsA("BasePart") then
			--[[
				`Anchored` pelo mesmo motivo do anel de chao (ver
				`CardModifierController:_drawZones`): o Workspace simula o que esta
				pendurado na Camera, e uma Part solta cai e some sozinha. Este anel e
				reposicionado a cada quadro, entao a queda seria menos visivel -- e mais
				dificil de achar.
			]]
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	if color then
		self:_paintRing(ring, color)
	end

	ring.Parent = workspace.CurrentCamera
	self.TargetMaid:GiveTask(ring)

	return ring
end

--[=[
	Pinta o anel da mira.

	E uma funcao a parte porque a cor do anel de area **muda no meio da mira**: ela
	vira vermelha onde o lugar esta ocupado por outra area do mesmo jogador e volta ao
	verde quando o cursor sai de la (ver `_updateTargeting`).

	A cor pedida e guardada no proprio Model, e a pintura sai fora quando ela nao mudou:
	percorrer os descendentes do anel sessenta vezes por segundo para escrever a mesma
	cor e trabalho que nao aparece na tela.
]=]
function RoundCardShopController:_paintRing(ring : Model, color : Color3)
	if ring:GetAttribute("PaintedColor") == color then return end
	ring:SetAttribute("PaintedColor", color)

	for _, descendant in ring:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Color = color
		end
	end
end

--[=[
	Este lugar esta ocupado por outra area do **mesmo jogador**?

	Vale so para o `Use.Area`: o segundo passo do Zippers tambem anda pelo chao, mas o
	que decide o destino dele e o fantasma da torre, e nem ele nem a torre desenham
	area nenhuma.

	Quem responde e o `CardModifierController`, pela mesma conta que o servidor faz no
	`FindZoneOverlap`. Sem ele (a lista ainda nao chegou), o lugar conta como livre: o
	servidor confere de novo, e travar a carta por causa de um controller que nao subiu
	seria pior do que um clique recusado.

	Perguntado nos dois lugares que precisam da resposta -- a cor do anel, a cada
	quadro, e o clique -- em vez de o clique reaproveitar o ultimo quadro desenhado: no
	celular o primeiro toque **e** o primeiro quadro em que existe "onde o dedo esta", e
	ali nao ha quadro anterior nenhum para consultar.
]=]
function RoundCardShopController:_blockedAt(cardId : string, ground : Vector3?) : boolean
	if not ground then return false end

	local modifiers = self.Controllers.CardModifierController
	if not modifiers then return false end

	return modifiers:FindZoneOverlap(ground, RoundCardConfig.GetRadius(cardId)) ~= nil
end

--[=[
	O chao debaixo do ponteiro.

	Devolve o ponto do mundo, ou nil quando o raio nao encosta em nada -- o ceu, a
	beirada do mapa. Quem raia e o `UnitPlacementController`, que ja filtra o
	personagem do proprio jogador: ele anda pelo mapa e taparia o chao atras dele.
]=]
function RoundCardShopController:_groundAt(screenPosition : Vector2) : Vector3?
	local placement = self.Controllers.UnitPlacementController
	if not placement then return nil end

	local hit = placement:raycastFromPointer(screenPosition)

	return hit and hit.Position or nil
end

--[=[
	Os modificadores que esta carta **criaria** se fosse usada agora, para a previa.

	Sao os mesmos registros do `RoundCardConfig` que o servidor poria no campo, com a
	zona ja preenchida com o ponto do mapa onde o cursor esta -- e e de proposito que
	seja a mesma lista: quem desenha o feedback e a mesma funcao que desenha o efeito
	de verdade, entao o que o jogador le antes de soltar a carta e exatamente o que
	ele vai ver depois.

	Os registros sao **copiados** antes de ganhar a zona: os do config sao a
	declaracao da carta, e escrever a posicao do cursor neles deixaria o proximo uso
	daquela carta nascendo com a zona da mira anterior.

	Carta sem `Modifiers` (o Zippers, o Staff of Healing) devolve nil: nao ha buff nem
	debuff para antecipar, e a mira dela continua so com o anel e o realce.
]=]
function RoundCardShopController:_previewRecords(cardId : string, position : Vector3?)
	local definition = RoundCardConfig.Get(cardId)
	local records = definition and definition.Params and definition.Params.Modifiers

	if not records or #records == 0 then
		return nil
	end

	local preview = {}

	for _, record in records do
		local copy = table.clone(record)

		if record.Zone then
			-- Registro que pede zona e ainda nao tem ponto nenhum viraria um buff
			-- global na previa, que e o oposto do que um cajado de area promete.
			if not position then
				return nil
			end

			copy.Zone = { Position = position, Radius = RoundCardConfig.GetRadius(cardId) }
		end

		table.insert(preview, copy)
	end

	return preview
end

--- Larga a previa, se houver uma no ar.
function RoundCardShopController:_clearPreview()
	local feedback = self.Controllers.WeatherFeedbackController
	if feedback then
		feedback:ClearPreview()
	end

	if self.Targeting then
		self.Targeting.PreviewAt = nil
		self.Targeting.PreviewUnit = nil
	end
end

--[=[
	Realca a torre debaixo do ponteiro, enquanto a carta espera uma.

	O realce e trocado, e nao redesenhado: passar o ponteiro por uma fileira de
	torres criaria e destruiria um Highlight por quadro.
]=]
function RoundCardShopController:_hoverUnit(unitModel : Model?)
	if self.HoverModel == unitModel then return end

	self.HoverModel = unitModel
	self.HoverMaid:DoCleaning()

	if not unitModel then return end

	--[[
		Carta que mexe em estatistica nao ganha realce proprio: quem pinta a torre
		debaixo do ponteiro nela e o `WeatherFeedbackController`, com **este mesmo
		amarelo** (`Targeting.Colors.Unit`) mais os icones do que ela vai sentir. Dois
		Highlights no mesmo modelo deixariam as duas cores brigando, e o dele diz mais.

		Sobra o realce daqui para quem nao tem o que antecipar: o Zippers, que so muda
		a torre de lugar.
	]]
	if self.Targeting and self.Targeting.PreviewRecords then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "RoundCardHover"
	highlight.FillColor = TARGETING.Colors.Unit
	highlight.OutlineColor = TARGETING.Colors.Unit
	highlight.FillTransparency = 0.65
	highlight.OutlineTransparency = 0.1
	highlight.Parent = unitModel

	self.HoverMaid:GiveTask(highlight)
end

--[=[
	Comeca a mira de uma carta que pede alvo.

	Enquanto ela dura, o clique no mundo pertence a carta: o
	`UnitPlacementController` para de selecionar torre (senao o mesmo clique faria
	as duas coisas) e volta a selecionar quando a mira acaba, de que jeito for.

	`Move` (o Zippers) e os dois passos em fila: primeiro a torre, depois o destino.
	Ele nao e um terceiro modo -- ele **e** os outros dois, um depois do outro, e por
	isso o `Stage` e que manda no que a tela desenha, e nao o `Use` da carta.
]=]
function RoundCardShopController:_beginTargeting(uid : string, cardId : string, use : string)
	self:_stopTargeting()

	local stage = if use == USE.Move then USE.Unit else use

	self.Targeting = {
		Uid = uid,
		CardId = cardId,
		Use = use,
		Stage = stage,
	}

	--[[
		A tranca sobe agora e so cai no quadro seguinte ao fim da mira -- ver
		`_stopTargeting`. O token e o que impede que a queda de uma mira anterior
		destranque esta, que acabou de comecar.
	]]
	self.LockToken += 1

	local placement = self.Controllers.UnitPlacementController
	if placement then
		placement:setPointerLocked(true)
	end

	--[[
		A carta passa a estar **na mao**, e a hotbar a desenha como desenha uma carta
		de unidade equipada: ela cresce e as outras apagam. E o unico aviso de que a
		mira esta aberta -- nao ha painel nem botao de cancelar, do mesmo jeito que
		nao ha nenhum quando o jogador poe uma unidade na mao.

		O `onCleared` e o caso em que a mao muda por fora daqui: o jogador clicou numa
		carta de unidade, e a mira daquela carta de round nao tem mais dono.
	]]
	self:_deck("setSelectedRound", uid, function()
		self:_stopTargeting()
	end)

	self:_playSound(CARD_SOUND)

	--[[
		A lista da previa e montada uma vez aqui, e o que muda a cada quadro e so a
		posicao da zona dentro dela. Carta sem modificador (o Zippers) fica com nil, e
		a mira dela nao antecipa nada -- nao ha o que antecipar.
	]]
	self.Targeting.PreviewRecords = self:_previewRecords(cardId, Vector3.zero)

	if stage == USE.Area then
		self.Targeting.Ring = self:_buildRing(RoundCardConfig.GetRadius(cardId), TARGETING.Colors.Area)
	end

	self.TargetMaid:GiveTask(RunService.RenderStepped:Connect(function()
		self:_updateTargeting()
	end))

	self.TargetMaid:GiveTask(PointerUtil.onPointerAction(function(screenPosition : Vector2)
		self:_confirmTarget(screenPosition)
	end))

	--[=[
		Desistir pelo teclado.

		O botao direito ficou de fora de proposito: no celular ele nao existe, e no PC
		ele e a camera -- quem gira a tela olhando onde por o anel cancelaria a carta
		sem querer. A saida que vale em qualquer aparelho e clicar de novo na carta,
		que e como se larga uma unidade equipada (ver `_requestUse`).

		O `gameProcessedEvent` **nao** e filtrado no Esc de proposito: ele pode chegar
		marcado como processado (o Roblox usa a mesma tecla), e uma mira da qual nao
		se sai e pior do que uma mira que sai uma vez a mais.
	]=]
	self.TargetMaid:GiveTask(UserInputService.InputBegan:Connect(function(input : InputObject)
		if input.KeyCode == Enum.KeyCode.Escape then
			self:_cancelTargeting()
		end
	end))
end

--- Redesenha o que a mira mostra, no quadro: o anel no chao ou o realce na torre.
function RoundCardShopController:_updateTargeting()
	local targeting = self.Targeting
	if not targeting then return end

	--[[
		O segundo passo do Zippers e desenhado pelo `UnitPlacementController`: o
		fantasma, o anel de alcance e o caminho pintado sao dele. Daqui nao sai mais
		nada enquanto ele estiver no ar, senao seriam dois desenhos disputando o
		mesmo ponteiro.
	]]
	if targeting.Placement then return end

	local screenPosition = PointerUtil.getScreenPosition()

	-- No celular, antes do primeiro toque, nao existe "onde o dedo esta": a mira
	-- fica esperando em vez de desenhar no canto da tela.
	if not screenPosition then return end

	local feedback = self.Controllers.WeatherFeedbackController

	if targeting.Stage == USE.Unit then
		local placement = self.Controllers.UnitPlacementController
		local unitModel = placement and placement:getUnitAtPointer(screenPosition) or nil

		self:_hoverUnit(unitModel)

		--[[
			A torre debaixo do ponteiro mostra, na propria cabeca, o que a carta faria
			com ela. So na troca de torre: enquanto o ponteiro fica na mesma, nao ha nada
			de novo para desenhar.
		]]
		if feedback and targeting.PreviewUnit ~= unitModel then
			targeting.PreviewUnit = unitModel

			feedback:SetPreview(if unitModel then targeting.PreviewRecords else nil, unitModel)
		end

		return
	end

	local ground = self:_groundAt(screenPosition)
	if not ground then return end

	-- Vermelho onde o anel encostaria numa area que este jogador ja desenhou. Ver
	-- `_blockedAt`, que o clique pergunta de novo.
	local blocked = targeting.Stage == USE.Area and self:_blockedAt(targeting.CardId, ground)

	--[[
		O anel segue o chao debaixo do cursor. Ele pode nao existir (asset faltando), e
		a previa continua valendo do mesmo jeito: o que decide onde a carta cai e o
		ponto, e nao o desenho dele.
	]]
	local ring = targeting.Ring
	if ring and ring.Parent then
		ring:PivotTo(CFrame.new(ground.X, ground.Y + ring:GetExtentsSize().Y / 2, ground.Z))
		self:_paintRing(ring, if blocked then TARGETING.Colors.Blocked else TARGETING.Colors.Area)
	end

	--[[
		Toda torre que o anel alcanca acende com o que ela vai sentir, e apaga quando o
		anel sai de cima dela. E o que faz a decisao "onde por o cajado" ser tomada
		olhando o mapa, e nao lendo a descricao da carta.

		O `PREVIEW_STEP` e o freio: o cursor parado manda o mesmo ponto sessenta vezes
		por segundo, e cada previa e uma varredura por todas as torres. Movimento menor
		que ele nao muda quem esta dentro do anel.
	]]
	if not feedback then return end

	local records = targeting.PreviewRecords
	if not records then return end

	local last = targeting.PreviewAt
	if last and (last - ground).Magnitude <= PREVIEW_STEP then return end

	targeting.PreviewAt = ground

	--[[
		A zona e reescrita **no lugar**, e nao remontada: a lista foi clonada uma vez no
		comeco da mira (ver `_beginTargeting`), e refaze-la a cada quadro alocaria uma
		copia da carta inteira sessenta vezes por segundo para mudar tres numeros.
	]]
	for _, record in records do
		if record.Zone then
			record.Zone.Position = ground
		end
	end

	feedback:SetPreview(records)
end

--[=[
	O clique que escolhe.

	Clique que nao acerta nada (o ceu, um lugar sem chao) **nao** cancela: ele
	simplesmente nao vale. Cancelar ali faria um clique torto custar a carta -- e a
	saida ja tem tres portas proprias (botao direito, Esc e o botao de cancelar).
]=]
function RoundCardShopController:_confirmTarget(screenPosition : Vector2)
	local targeting = self.Targeting
	if not targeting then return end

	-- Quem confirma o destino do Zippers e o proprio fantasma, pelo `OnConfirm` do
	-- `_beginMovePlacement`. Este clique e o mesmo, e valeria duas vezes.
	if targeting.Placement then return end

	if targeting.Stage == USE.Unit then
		local placement = self.Controllers.UnitPlacementController
		if not placement then return end

		local unitModel, unitId = placement:getUnitAtPointer(screenPosition)
		if not unitModel or not unitId then return end

		if targeting.Use == USE.Unit then
			self:_sendUse(targeting.Uid, { UnitId = unitId })
			return
		end

		-- A torre escolhida: o segundo passo do Zippers e o posicionamento inteiro,
		-- e nao um anel no chao. Ver `_beginMovePlacement`.
		targeting.UnitId = unitId
		targeting.Stage = USE.Move

		self:_hoverUnit(nil)
		self:_clearPreview()

		self:_beginMovePlacement(unitModel, unitId)
		return
	end

	local ground = self:_groundAt(screenPosition)
	if not ground then return end

	--[[
		Clique no vermelho nao vale, e nao cancela: e a mesma regra do clique no ceu logo
		acima. A carta continua na mao e a mira aberta, e o jogador move o cursor para
		fora da area que ja esta no chao.

		O servidor confere isto de novo por conta dele (ver `CardShopService:_checkTarget`).
		Aqui e feedback, e nao a regra -- o que esta em jogo e a viagem de ida e volta de um
		clique que ja se sabe recusado.
	]]
	if targeting.Stage == USE.Area and self:_blockedAt(targeting.CardId, ground) then
		return
	end

	self:_sendUse(targeting.Uid, { Position = ground })
end

--[=[
	O segundo passo do Zippers: escolher para onde a torre vai.

	Ele **e** o posicionamento de uma unidade, e nao uma mira parecida com ele. Quem
	desenha e quem decide se o lugar serve e o `UnitPlacementController:visualize`,
	o mesmo que larga uma torre nova -- o jogador ve o modelo da propria torre em
	meio-tom, verde onde ela pode ficar e vermelho onde nao pode, com o anel do
	alcance dela e o caminho pintado, e no celular o mesmo painel de confirmar.

	Reaproveitar aquilo, em vez de repetir as conferencias aqui, e o ponto: o
	destino do Zippers passa pelas mesmas regras de um posicionamento novo (fora do
	caminho, sem obstaculo, longe das outras torres, sem ninguem em cima), e uma
	segunda copia dessas regras divergiria da primeira no dia em que uma delas
	mudasse -- que e o mesmo motivo de o `PlacementUtil` existir entre o cliente e o
	servidor.

	**A propria torre sai das contas** (`IgnoreModel`): ela continua de pe no lugar
	velho durante a escolha, e sem isso ela obstruiria o proprio destino. E o que o
	`ignoreEntry` do `UnitService:isSpotFree` ja faz do lado do servidor.

	**O giro vale**, como em qualquer posicionamento: o R gira o fantasma e o angulo
	viaja junto com o destino. O fantasma comeca no giro que a torre ja tem, entao
	quem so quer muda-la de lugar nao precisa fazer nada -- e quem quer virar a torre
	para o outro lado do caminho consegue, sem vender e recomprar.
]=]
function RoundCardShopController:_beginMovePlacement(unitModel : Model, unitId : string)
	local targeting = self.Targeting
	if not targeting then return end

	local placement = self.Controllers.UnitPlacementController
	if not placement then return end

	local uid = targeting.Uid
	local unitName = unitModel.Name
	local pivot = unitModel:GetPivot()
	local _, yaw = pivot:ToEulerAnglesYXZ()

	placement:visualize(unitName, {
		IgnoreModel = unitModel,
		Range = placement:getUnitRange(unitName, unitModel:GetAttribute("Upgrades") or 0, pivot.Position, unitId),
		Rotation = math.deg(yaw),
		ConfirmText = "MOVE",

		--[[
			Vai o CFrame que o fantasma validou, aberto em ponto e angulo.

			O ponto e o do CFrame, e nao o chao debaixo do cursor: aquele ja e a altura
			em que a unidade fica apoiada, medida da mesma forma que o `PlaceUnit` mede
			para uma torre nova. O angulo e so o Y, em radianos, porque e o unico que o
			fantasma gira -- mandar o CFrame inteiro daria ao cliente doze numeros para
			mentir onde bastam um.
		]]
		OnConfirm = function(cf : CFrame)
			local _, spin = cf:ToEulerAnglesYXZ()

			self:_sendUse(uid, { UnitId = unitId, Position = cf.Position, Rotation = spin })
		end,

		OnCancel = function()
			self:_cancelTargeting()
		end,
	})

	--[[
		O passo so vira "posicionamento" se o fantasma de fato subiu.

		`visualize` desiste em silencio em dois casos -- ja existe um fantasma no ar,
		ou o modelo nao esta em `Assets.Units` --, e marcar o passo antes de saber
		disso deixaria a carta num limbo: nada desenhado na tela, o clique sem dono
		(o `_confirmTarget` ja teria saido pela porta do `Placement`) e so o Esc
		como saida. Sem fantasma, a mira e desfeita e a carta volta inteira para a
		mao -- ela so e gasta quando o servidor confirma.
	]]
	targeting.Placement = placement.isPlacing == true

	if not targeting.Placement then
		self:_cancelTargeting()
	end
end

--- Recolhe o que a mira desenhou e devolve o clique ao posicionamento.
function RoundCardShopController:_stopTargeting()
	if not self.Targeting then return end

	local hadPlacement = self.Targeting.Placement == true

	self.Targeting = nil

	self.TargetMaid:DoCleaning()
	self:_hoverUnit(nil)

	-- As unidades voltam a mostrar o que elas de fato estao sentindo.
	self:_clearPreview()

	-- A carta sai da mao: ela volta ao tamanho normal e as vizinhas acendem de volta.
	self:_deck("setSelectedRound", nil)

	local placement = self.Controllers.UnitPlacementController
	if not placement then return end

	--[[
		O fantasma do Zippers cai junto com a mira, seja qual for a saida: o destino
		confirmado, o Esc, a carta clicada de novo ou a carta que o servidor tirou da
		mao. `unequip` numa mao vazia nao faz nada, mas o teste evita derrubar um
		fantasma que nao e nosso.
	]]
	if hadPlacement then
		placement:unequip()
	end

	--[=[
		A tranca do clique cai no **quadro seguinte**, e nao agora.

		O clique que escolheu o alvo e o mesmo `InputBegan` que o `UnitPlacementController`
		escuta para selecionar torre, e os dois sao escutas separadas do mesmo evento:
		a ordem entre elas nao e promessa de lugar nenhum. Destrancando aqui, na
		metade do processamento daquele clique, o handler do posicionamento podia
		rodar depois -- e ai o mesmo clique que gastou a carta abria o card de upgrade
		da torre escolhida.

		Um quadro de atraso resolve porque ele e sempre depois de **todas** as escutas
		daquele input. E o mesmo remedio do clique-fora da loja, que compara o
		`InputObject` num `task.defer` pelo mesmo motivo.

		O token e a corrida do outro lado: uma carta nova mirada no mesmo quadro em que
		a anterior terminou nao pode ser destrancada pela queda da anterior.
	]=]
	self.LockToken += 1
	local token = self.LockToken

	task.defer(function()
		if self.LockToken ~= token then return end

		placement:setPointerLocked(false)
	end)
end

--[=[
	Desistir da mira. A carta **continua na mao**: ela so e gasta quando o servidor
	confirma o uso, e desistir de escolher um lugar nao e usar a carta.
]=]
function RoundCardShopController:_cancelTargeting()
	self:_stopTargeting()
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

			--[[
				A carta continua na mao do servidor, entao o uso que estava no ar nao
				aconteceu: ele foi recusado (a torre escolhida foi vendida no meio, o
				lugar nao servia) e o trinco tem que sair, senao aquela carta ficaria
				para sempre sem responder ao clique.

				O preco disso e uma corrida estreita: um estado que chegue por outro
				motivo (a loja abrindo numa wave nova) entre o pedido e a confirmacao
				solta o trinco cedo, e um clique duplo bem no meio disso vira um segundo
				pedido -- que o servidor recusa com uma linha no log. Uma carta morta na
				mao e bem pior do que isso.
			]]
			self.UsePending[entry.Uid] = nil
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

	--[[
		O botao so acende para uma oferta que este jogador ainda nao abriu.

		Sao duas recusas em uma. Com a aba aberta ele esta recolhido de proposito, e
		um estado que chegue do servidor no meio disso nao pode traze-lo de volta por
		cima do escurecido. E, aberta a loja uma vez, o `token` daquela oferta fica
		marcado no `OpenedToken`: os estados que o servidor reenvia depois (uma compra
		recusada, um uso recusado, a interface recarregando) redesenham a hotbar sem
		fazer o convite de novo. Quem acende a beirada e `token` diferente -- a
		proxima wave de loja da dificuldade.
	]]
	if not self.ShopOpen and offer.token ~= self.OpenedToken then
		self:_showFrame()
	end

	-- Oferta nova com a aba ja aberta (a wave virou enquanto o jogador olhava as
	-- cartas): as cartas na tela sao da oferta velha e precisam ser redesenhadas, e
	-- e esta oferta, e nao mais a anterior, que a aba esta gastando.
	if self.ShopOpen and not sameOffer then
		self.OpenedToken = offer.token

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

	--[[
		O escurecido passa a comer input: e o que impede que o clique dado com a loja
		aberta atravesse a tela e vire uma torre colocada no chao atras dela. Quem
		**escuta** o clique fora e o `UserInputService` (ver `_openShop`); isto aqui
		e so a barreira. So vale enquanto ele esta visivel -- fechado, ele nao come
		clique de ninguem.
	]]
	background.Active = true

	local button = frame:FindFirstChild(GUI.Button)
	if button and button:IsA("GuiButton") then
		self.Button = button

		-- Lidos antes de qualquer animacao tocar: e para ca que o balanco volta.
		self.ButtonPosition = button.Position
		self.ButtonRotation = button.Rotation

		button.Activated:Connect(function()
			if self.ShopOpen then
				self:_dismissShop()
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

		-- O gesto sai na confirmacao, e nao no clique: quem gasta a carta e o
		-- servidor, e um uso recusado nao pode deixar o personagem posando.
		self:_playUseVisual(payload.id)
	end)

	-- A mesma carta, usada por outra pessoa. O servidor so manda isto para quem **nao**
	-- usou; quem usou ja esta no `RoundCardUsed` acima.
	Framework:Listen("RoundCardVisual", function(payload)
		if typeof(payload) ~= "table" then return end

		self:_playRemoteUseVisual(payload.id, payload.user)
	end)

	--[[
		Rede de seguranca: o round reiniciou com uma mira aberta. Sem isto o clique do
		jogador ficaria trancado no posicionamento de uma partida que ja acabou.
	]]
	Framework:Listen("RoundRestarted", function()
		self:_stopTargeting()
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
	self.Dismissing = false
	self.OpenToken = 0
	self.FrameToken = 0
	self.DismissToken = 0

	-- Sobe a cada tranca e a cada destranca do clique no mundo. Ver `_stopTargeting`.
	self.LockToken = 0

	-- O `token` da oferta que o jogador ja abriu: o botao nao se oferece duas vezes
	-- pela mesma. Nil ate a primeira loja da partida.
	self.OpenedToken = nil

	-- [uid] = Maid do wrapper que esta na hotbar.
	self.DeckCards = {}
	self.UsePending = {}

	-- As tres cartas na tela, na ordem em que cairam: e por ela que a saida escalona.
	self.CardEntries = {}

	--[[
		A mira de uma carta que pede alvo: qual carta, em que passo e o que ela ja
		escolheu. Nil quando ninguem esta mirando.
	]]
	self.Targeting = nil

	self.RowMaid = Maid.new()
	self.FrameMaid = Maid.new()
	self.ShopMaid = Maid.new()
	self.IdleMaid = Maid.new()

	-- O que a mira desenhou (o anel, as escutas) e o realce da torre sob o ponteiro.
	-- Separados porque o realce troca a cada torre, e o resto so no fim da mira.
	self.TargetMaid = Maid.new()
	self.HoverMaid = Maid.new()

	self:construct()
end

return RoundCardShopController
