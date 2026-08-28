local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

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

-- Os **parametros** do marcador de keyframe do gesto (ver `_playUseVisual`). Vem do
-- config porque o servidor procura pela mesma palavra ao conferir o `EffectDelay`.
local MARKERS = RoundCardConfig.Markers

local CHARACTER_ROOT = "HumanoidRootPart"

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
		5. o clique na carta da hotbar pede o uso, e ela some quando o
		   `RoundCardUsed` confirma -- que e tambem quando o personagem de quem usou
		   faz o gesto da carta, se ela tiver um `Visual` no config.

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

--[=[
	Escreve a transparencia de todos os descendentes de uma vez.

	`direction` existe para a saida: a entrada chega desacelerando (`CardDirection`,
	que e `Out`), e a saida sai acelerando (`In`). Sem isso o sumico das cartas
	arrastaria no comeco e pareceria travamento, e nao resposta ao clique.
]=]
local function applyFades(fades, progress : number, time : number?, direction : Enum.EasingDirection?)
	local info = time and TweenInfo.new(time, ANIM.CardEasing, direction or ANIM.CardDirection)

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

	So quem usou a carta ve isto: o `RoundCardUsed` sai do servidor para ele. A
	animacao em si replica sozinha (ela toca no proprio personagem), mas o som e as
	particulas ficam no cliente de quem usou.
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

	-- O `token` da oferta que o jogador ja abriu: o botao nao se oferece duas vezes
	-- pela mesma. Nil ate a primeira loja da partida.
	self.OpenedToken = nil

	-- [uid] = Maid do wrapper que esta na hotbar.
	self.DeckCards = {}
	self.UsePending = {}

	-- As tres cartas na tela, na ordem em que cairam: e por ela que a saida escalona.
	self.CardEntries = {}

	self.RowMaid = Maid.new()
	self.FrameMaid = Maid.new()
	self.ShopMaid = Maid.new()
	self.IdleMaid = Maid.new()

	self:construct()
end

return RoundCardShopController
