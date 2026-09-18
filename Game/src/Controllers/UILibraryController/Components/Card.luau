local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)
local TowerContainer = Interface:WaitForChild("TowerContainer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

--[[ CONSTANTS ]]
local WRAPPER_NAME = "CardWrapper"
local CARD_NAME = "Card"
local BUTTON_NAME = "Button"

-- A carta dentro do wrapper que a loja de round entrega. Ela e o proprio botao,
-- ao contrario da carta de unidade, que tem um `Button` por dentro.
local ROUND_CARD_NAME = "CardTemplate"
local COUNT_NAME = "Count"
local COST_NAME = "Cost"
local UNIT_NAME_NAME = "UnitName"

local COUNT_LAYER_NAME = "CountLayer"

--[[
	O arco.

	A carta cai pelo **quadrado** da distancia ate o vertice, e a queda e medida em
	alturas de carta -- por isso mexer no tamanho da carta no Studio abre ou fecha o
	arco inteiro sozinho, sem numero nenhum para acertar aqui.

	A curva e normalizada pela distancia da carta mais longe: a que esta na ponta
	sempre cai `ARC_SPREAD` e sempre inclina `ARC_TILT`, seja qual for o tamanho do
	deck e onde esteja o vertice. Sem isso, escolher a primeira carta de um deck de
	seis jogaria a ultima quase uma altura inteira para baixo (o quadrado de 5),
	para fora do container.

	A inclinacao acompanha o lado do arco: quem esta a esquerda do vertice tomba
	para a esquerda, quem esta a direita tomba para a direita, e o vertice fica em
	pe. Os oito graus da ponta sao os mesmos do leque que estava autorado antes.
]]
local ARC_SPREAD = 0.23
local ARC_TILT = 8

--[[
	A reacomodacao inteira dura `ARC_TOTAL_TIME`, do primeiro movimento ao ultimo.

	As cartas nao saem todas juntas: uma fatia do tempo (`ARC_STAGGER_SHARE`) e
	gasta escalonando as saidas, e o que sobra e a duracao de cada uma. Como o
	intervalo total e sempre a mesma fatia, o deck de duas cartas e o de seis
	terminam no mesmo instante -- o que muda e so o quao apertado fica o intervalo
	entre uma e outra.

	O atraso vai no proprio `TweenInfo`, e nao num `task.delay`: enquanto ele nao
	vence, o tween nao escreve nada, e cancelar o tween cancela a espera junto.
]]
local ARC_TOTAL_TIME = 0.3
local ARC_STAGGER_SHARE = 0.4
local ARC_EASING = Enum.EasingStyle.Quad
local ARC_DIRECTION = Enum.EasingDirection.Out

--[[
	A escala de cada carta sai de duas coisas que se **multiplicam**: onde ela
	descansa (1, ou `SELECTED_SCALE` se ela e a escolhida) vezes `HOVER_SCALE`
	enquanto o mouse esta em cima dela.

	Os dois eram alternativas, e o maior ganhava. Como `HOVER_SCALE` e o maior dos
	dois, escolher uma carta **com o mouse em cima dela** -- que e como todo clique
	de mouse acontece -- ia de 1.2 para 1.2: a carta era escolhida e nao mexia um
	pixel, e o unico momento em que a escolha aparecia era ao tirar o mouse dali. No
	celular, onde nao ha hover, a mesma escolha animava normalmente.

	Multiplicados, a carta escolhida sob o mouse vai a 1.32 e o clique responde na
	hora; hover em carta nao escolhida continua exatamente em 1.2, e escolhida sem
	mouse em cima continua em 1.1. Toda troca e o mesmo tween, entao nenhuma delas
	salta.

	As cartas se sobrepoem bastante, entao a que cresce tambem vem para a frente --
	senao ela cresceria por baixo da vizinha.
]]
local HOVER_SCALE = 1.2
local SELECTED_SCALE = 1.1
local SCALE_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[[
	Quanto da largura que uma carta ganha ao crescer e devolvido em espaco para as
	vizinhas. Em 1, a carta que cresce empurra o vizinho exatamente o quanto ela
	invadiu; abaixo disso, parte do crescimento e absorvida pela sobreposicao que o
	leque ja tem.

	O empurrao e simetrico -- metade para cada lado --, entao a mao continua
	centrada por mais que uma carta no meio dela cresca.
]]
local PUSH_SHARE = 1

local BASE_ZINDEX = 1
local SELECTED_ZINDEX = 5
local HOVER_ZINDEX = 10

--[[
	Sem unidade sobrando, a carta nao fica na mao: ela cai para fora do deck, e a
	mao so fecha a vaga quando ela termina de sair. Quando a unidade volta a
	existir, o caminho e o mesmo ao contrario -- a vaga reabre e a carta sobe de
	volta para o arco.

	A queda e medida em alturas de carta, como o resto do arco, entao ela continua
	saindo inteira da tela se o tamanho da carta mudar.
]]
local EXIT_DROP = 1.2
local EXIT_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local RESTORE_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[[
	Com uma carta escolhida, **as outras** apagam um pouco -- elas e tudo o que tem
	dentro, mais o contador delas, que mora fora da carta mas e parte dela.

	O valor e uma fracao do caminho que falta ate a transparencia total, e nao um
	valor fixo: assim ele se compoe com o que a peca ja tinha (uma carta sem estoque
	ja esta em 0.25) sem nunca passar de 1, e o estado normal de cada peca continua
	sendo o que o designer deixou.
]]
local DIM_AMOUNT = 0.35

--[[
	O quanto uma carta **trancada** apaga. Mais forte que o `DIM_AMOUNT` de propósito:
	apagar por não estar escolhida é dizer "essa não é a da vez"; apagar por estar
	trancada é dizer "essa não dá para usar agora", e as duas não podem parecer a
	mesma coisa.
]]
local LOCKED_AMOUNT = 0.6

-- Sem dinheiro para o custo: carta em vermelho, mas sem apagar.
local NO_CASH_COLOR = Color3.fromRGB(255, 70, 70)

-- Uma tecla por carta da hotbar.
local KEYBINDS = {
	One = 1,
	Two = 2,
	Three = 3,
	Four = 4,
	Five = 5,
	Six = 6,
}

--[=[
	A hotbar da partida: uma carta por unidade do deck, clonadas do `CardWrapper`
	que o designer deixou autorado no `TowerContainer`.

	O `UIListLayout` do container e quem espalha os **wrappers** na horizontal; o
	que este modulo desenha e a posicao **Y da carta dentro do wrapper** e a
	inclinacao dela, e e dai que sai o arco. Separar os dois e o que deixa o arco
	existir sem brigar com o layout.

	Quem alimenta este modulo e o `CardController`, pelo `doComponent`.

	**Nem toda carta da mao vem do deck.** As cartas compradas na loja de round
	(`RoundCardShopController`) entram por `addRound` e ficam em `self.entries` do
	mesmo jeito que as outras: elas caem no arco, crescem no hover, sao empurradas
	pelas vizinhas e apagam quando outra carta e escolhida. O que muda e so a
	origem -- o wrapper delas vem pronto de outro molde, e quem sabe o que o clique
	faz e quem as entregou.

	A diferenca fica em dois campos do `entry`:

	| Campo | Carta de unidade | Carta de round |
	| --- | --- | --- |
	| `Kind` | `"Unit"` | `"Round"` |
	| `Unit` | o nome da unidade | `nil` |

	`Unit` vazio e o que tira a carta de round de tudo que e do deck: preco, clima,
	contador, estoque e a nocao de "carta escolhida". Todo o resto -- o arco, a
	escala, a apagada, a saida -- e o mesmo codigo.
]=]
local module = {}

module.entries = {}
module.byUnit = {}

-- As cartas de round que estao na mao agora, por `uid` da compra.
module.byRound = {}

module.counts = {}
module.cash = 0
module.selected = nil

--[[
	A carta de **round** escolhida, pelo `uid` da compra.

	Ela e um estado separado do `selected` porque as duas nao se identificam do
	mesmo jeito -- uma carta de unidade e um nome de unidade, e uma de round e uma
	compra --, mas as duas sao a mesma ideia: o que esta na mao do jogador agora. Por
	isso so uma das duas pode estar valendo (ver `setSelected`), e as duas passam
	pelo mesmo crescer e pela mesma apagada das vizinhas.
]]
module.selectedRound = nil

--[[
	A mao inteira escondida sem ninguem perder o lugar. Quem liga e desliga e o
	`RoundCardShopController`, enquanto a aba da loja esta aberta -- as cartas do
	jogador saem da tela e voltam exatamente como estavam.

	E um estado do componente, e nao um `Visible` escrito de fora, justamente
	porque o `Visible` de cada wrapper ja tem dono aqui (`_setPresence`): carta sem
	unidade sobrando fica fora da tela por conta propria, e devolver "tudo aceso"
	na volta a poria de volta na mao.
]]
module.hidden = false

--[[ INTERNAL ]]

--[=[
	O molde, tirado da tela na primeira vez que alguem precisa dele.

	O `CardWrapper` que veio autorado nao e uma carta: e o desenho de uma. Ele sai
	do container junto, entao a hotbar na tela e sempre 100% deck.

	As cores "normais" de cada peca sao lidas do molde, e nao escritas aqui: se o
	designer trocar o roxo do contorno, o estado normal acompanha. O mesmo vale para
	onde o contador mora dentro da carta, que e o que o `_followCounts` reproduz
	depois de tirar o contador de dentro dela.
]=]
local template : Frame? = nil
local defaults = {}

local function getTemplate() : Frame?
	if template then
		return template
	end

	local authored = TowerContainer:FindFirstChild(WRAPPER_NAME)
	if not authored then
		warn(`[Card]: nao achei o {WRAPPER_NAME} autorado no TowerContainer.`)
		return nil
	end

	template = authored:Clone()
	authored:Destroy()

	local card = (template :: Frame):FindFirstChild(CARD_NAME)
	local cost = card and card:FindFirstChild(COST_NAME)
	local countHolder = card and card:FindFirstChild(COUNT_NAME)
	local countLabel = countHolder and countHolder:FindFirstChild(COUNT_NAME)

	defaults = {
		CostStroke = cost and cost:FindFirstChildOfClass("UIStroke") and cost:FindFirstChildOfClass("UIStroke").Color,
		CountImage = countHolder and countHolder.ImageColor3,
		CountStroke = countLabel and countLabel:FindFirstChildOfClass("UIStroke") and countLabel:FindFirstChildOfClass("UIStroke").Color,

		-- Onde o contador fica dentro da carta, em escala dela. E o que sobra do
		-- vinculo depois que ele sai de dentro do card.
		CountCenter = countHolder and Vector2.new(
			countHolder.Position.X.Scale + countHolder.Size.X.Scale * (0.5 - countHolder.AnchorPoint.X),
			countHolder.Position.Y.Scale + countHolder.Size.Y.Scale * (0.5 - countHolder.AnchorPoint.Y)
		) or Vector2.new(0.5, 0.5),

		CountSize = countHolder and Vector2.new(countHolder.Size.X.Scale, countHolder.Size.Y.Scale)
			or Vector2.new(0.4, 0.4),
	}

	return template
end

--[=[
	A camada onde moram os contadores.

	Eles precisam ficar num plano so, na frente de **todas** as cartas: como as
	cartas se sobrepoem, um contador que continuasse dentro do proprio card sumiria
	atras do card vizinho -- a `Interface` e `ZIndexBehavior.Sibling`, entao um
	descendente nunca desenha acima de um irmao do pai dele.

	A camada e o ultimo filho do `TowerContainer` e desenha por cima dos wrappers.
	Ela tambem entra no `UIListLayout`, entao a largura dela e escolhida para
	**anular a propria vaga**: com o espacamento negativo que o layout tem, uma
	celula de +12px seguida de -12px de padding soma zero, e as cartas continuam
	centradas exatamente onde estavam.
]=]
local function ensureCountLayer() : Frame?
	local existing = TowerContainer:FindFirstChild(COUNT_LAYER_NAME)
	if existing then
		return existing
	end

	local layout = TowerContainer:FindFirstChildOfClass("UIListLayout")
	local padding = layout and layout.Padding or UDim.new()
	local width = -(padding.Scale * TowerContainer.AbsoluteSize.X + padding.Offset)

	local layer = Instance.new("Frame")
	layer.Name = COUNT_LAYER_NAME
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.Size = UDim2.fromOffset(math.max(width, 0), 0)
	layer.ZIndex = HOVER_ZINDEX + 1

	-- Ultimo da fila: assim ele desenha depois de todo wrapper. (`LayoutOrder` e
	-- inteiro, entao o "infinito" aqui e so um numero grande.)
	layer.LayoutOrder = 1e6
	layer.Parent = TowerContainer

	return layer
end

--[=[
	Onde a carta descansa quando ela e o vertice, e o quanto o arco derruba as
	outras. A altura sai do tamanho da propria carta, em escala do wrapper.
]=]
local function cardHeightScale(card : GuiObject) : number
	local height = card.Size.Y.Scale

	return if height > 0 then height else 1
end

--[=[
	Que propriedades de transparencia cada tipo de peca tem.
]=]
local function fadeProperties(object : Instance) : { string }?
	if object:IsA("UIStroke") then
		return { "Transparency" }
	elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
		return { "BackgroundTransparency", "ImageTransparency" }
	elseif object:IsA("TextLabel") or object:IsA("TextButton") then
		return { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" }
	elseif object:IsA("GuiObject") then
		return { "BackgroundTransparency" }
	end

	return nil
end

--[=[
	As transparencias que a carta tem **antes** de qualquer coisa mexer nela, uma
	entrada por peca -- a carta, os textos, os contornos e o contador.

	Sao lidas do clone recem-feito, entao "voltar ao estado original" e literal: o
	alvo do fade e sempre o que o designer deixou no molde, e nao um valor escrito
	aqui.
]=]
local function captureFades(roots : { Instance? })
	local fades = {}

	local function add(object : Instance)
		local properties = fadeProperties(object)
		if not properties then
			return
		end

		local values = {}
		for _, property in properties do
			values[property] = (object :: any)[property]
		end

		table.insert(fades, { Object = object, Values = values })
	end

	for _, root in roots do
		if not root then
			continue
		end

		add(root)
		for _, descendant in root:GetDescendants() do
			add(descendant)
		end
	end

	return fades
end

--[=[
	A largura autorada da carta em pixels, **sem** a escala.

	E lida do `Size` contra o wrapper, e nao do `AbsoluteSize`: durante o tween do
	hover o absoluto esta no meio do caminho, e o empurrao ficaria perseguindo o
	proprio efeito. Lida na hora, ela tambem acompanha a janela mudando de tamanho.
]=]
function module:_cardWidth(entry) : number
	local size = entry.Card.Size

	return size.X.Scale * entry.Wrapper.AbsoluteSize.X + size.X.Offset
end

--[=[
	As cartas que estao na mao agora. Carta sem unidade sobrando saiu do deck, entao
	ela nao conta para o arco nem para os atalhos -- a mao fecha a vaga dela.
]=]
function module:_liveEntries()
	local live = {}

	for _, entry in self.entries do
		if entry.Available ~= false then
			table.insert(live, entry)
		end
	end

	return live
end

--[=[
	Onde a carta descansa quando ela esta fora da mao: reta abaixo do lugar dela,
	longe o bastante para sair inteira da tela.
]=]
function module:_exitGoal(entry) : UDim2
	local base = entry.BasePosition

	return UDim2.new(
		base.X.Scale, base.X.Offset,
		base.Y.Scale + EXIT_DROP * entry.Height, base.Y.Offset
	)
end

--[=[
	Tira (ou devolve) a carta da tela.

	Sao duas metades: o wrapper, que e quem ocupa a vaga na fila, e o contador, que
	mora na camada de cima e por isso **nao** some junto com ele. Esquecer o segundo
	deixaria o numero de uma carta que ja saiu boiando na hotbar.

	`present` e guardado no proprio entry porque ele e a **intencao** ("esta carta
	deveria estar na mao?"), e a mao inteira pode estar escondida por cima disso
	(`setHidden`). Sem separar os dois, sair da aba da loja acenderia de volta
	tambem as cartas que estavam fora da tela por nao ter unidade sobrando.
]=]
function module:_setPresence(entry, present : boolean)
	entry.Present = present

	local visible = present and not self.hidden

	entry.Wrapper.Visible = visible

	if entry.Badge then
		entry.Badge.Visible = visible
	end
end

--[=[
	Poe ou tira a carta da mao.

	**Tirar** e uma queda de meio segundo, e a vaga dela so fecha quando ela termina
	de cair -- por isso o `_layout` sai do `Completed`, e nao daqui. **Por de volta**
	e o contrario: a vaga reabre na hora e a carta sobe do lugar onde parou.

	`instant` e para a montagem da mao, onde uma carta que ja nasce sem unidade nao
	tem de onde cair; quem chama assim tambem cuida do `_layout`.
]=]
function module:_setAvailable(entry, available : boolean, instant : boolean?) : boolean
	if entry.Available == available then
		return false
	end

	entry.Available = available

	-- Enquanto a carta entra ou sai, quem manda na posicao dela e este tween.
	entry.ExitMaid:DoCleaning()
	entry.ArcMaid:DoCleaning()

	if not available then
		if instant then
			entry.Card.Position = self:_exitGoal(entry)
			self:_setPresence(entry, false)

			return true
		end

		local tween = TweenService:Create(entry.Card, EXIT_INFO, { Position = self:_exitGoal(entry) })

		entry.ExitMaid:GiveTask(function()
			tween:Cancel()
		end)

		tween.Completed:Connect(function(state : Enum.PlaybackState)
			-- Cancelado e o caminho de quem voltou no meio da queda.
			if state ~= Enum.PlaybackState.Completed or entry.Available then
				return
			end

			self:_setPresence(entry, false)
			self:_layout()
		end)

		tween:Play()

		return true
	end

	self:_setPresence(entry, true)

	if instant then
		return true
	end

	-- O `_layout` leva a carta de onde ela parou ate a vaga dela, no tempo da volta.
	entry.Returning = true
	self:_layout()

	return true
end

--[=[
	O indice do vertice do arco: o meio do deck.

	A carta do meio quando o numero e impar, e as **duas** do meio quando e par --
	as duas ficam a mesma distancia de `(n+1)/2`, entao as duas sobem juntas.

	A carta escolhida nao mexe no vertice: quem mostra que ela esta escolhida e a
	escala dela (`SELECTED_SCALE`), nao a posicao.
]=]
function module:_vertex(count : number) : number
	return (count + 1) / 2
end

--[=[
	Reposiciona e inclina **todas** as cartas. Roda quando o deck muda de tamanho e
	quando o vertice muda de lugar.

	A carta (ou as duas) que esta no vertice fica exatamente na posicao que o
	designer deixou no molde e em pe; a que esta mais longe dele cai `ARC_SPREAD` e
	inclina `ARC_TILT`, e o resto se distribui entre esses dois extremos -- a queda
	pelo quadrado da distancia, a inclinacao pela distancia com sinal.

	Medir contra o menor e o maior quadrado da lista e o que resolve os dois casos de
	uma vez: com numero par e sem selecao, as **duas** do meio empatam na menor
	distancia e sobem juntas; com o vertice numa ponta, a carta do outro extremo para
	no mesmo lugar de sempre em vez de sair pela base do container.

	As cartas saem escalonadas, da esquerda para a direita, e a ultima termina em
	`ARC_TOTAL_TIME` contado do inicio de tudo.
]=]
function module:_layout(instant : boolean?)
	local live = self:_liveEntries()
	local count = #live

	if count == 0 then
		return
	end

	local vertex = self:_vertex(count)

	local closest, farthest = math.huge, 0
	for index = 1, count do
		local square = (index - vertex) ^ 2

		closest = math.min(closest, square)
		farthest = math.max(farthest, square)
	end

	-- Deck de uma carta so (ou de duas, sem selecao): todas empatam, e o arco e uma
	-- linha reta na altura do molde.
	local span = farthest - closest
	local reach = math.sqrt(farthest)

	-- O escalonamento: a ultima carta comeca em `spread` e termina junto com o
	-- total, porque `spread + duration` e exatamente `ARC_TOTAL_TIME`.
	-- Carta sozinha nao tem entre quem escalonar, entao o tempo todo vira duracao.
	local spread = if count > 1 then ARC_TOTAL_TIME * ARC_STAGGER_SHARE else 0
	local duration = ARC_TOTAL_TIME - spread
	local step = if count > 1 then spread / (count - 1) else 0

	--[[
		O quanto cada carta pede de espaco a mais por estar crescida.

		A largura sai do tamanho autorado da carta na hora (`_cardWidth`), e nao de
		um numero guardado: assim mexer no `Size` da carta tambem reacomoda o deck,
		e nao so mexer na escala dela.
	]]
	local extra = {}
	for index, entry in live do
		extra[index] = ((entry.ScaleTarget or 1) - 1) * self:_cardWidth(entry) * PUSH_SHARE
	end

	for index, entry in live do
		local distance = index - vertex
		local square = distance * distance

		local ratio = if span > 0 then (square - closest) / span else 0
		local drop = ARC_SPREAD * entry.Height * ratio
		local tilt = if reach > 0 then ARC_TILT * (distance / reach) else 0

		-- Quem esta a esquerda de uma carta crescida sai para a esquerda, quem esta a
		-- direita sai para a direita, e ela mesma nao anda.
		local shift = 0
		for other = 1, count do
			if other < index then
				shift += extra[other] / 2
			elseif other > index then
				shift -= extra[other] / 2
			end
		end

		local base = entry.BasePosition
		local goal = {
			Position = UDim2.new(base.X.Scale, base.X.Offset + shift, base.Y.Scale + drop, base.Y.Offset),
			Rotation = entry.BaseRotation + tilt,
		}

		entry.ArcMaid:DoCleaning()

		if instant then
			entry.Card.Position = goal.Position
			entry.Card.Rotation = goal.Rotation
			continue
		end

		-- Carta voltando para a mao faz o caminho inteiro no tempo da volta; o resto
		-- do deck se acomoda no escalonado de sempre.
		local info = if entry.Returning
			then RESTORE_INFO
			else TweenInfo.new(duration, ARC_EASING, ARC_DIRECTION, 0, false, (index - 1) * step)

		entry.Returning = false

		local tween = TweenService:Create(entry.Card, info, goal)
		entry.ArcMaid:GiveTask(function()
			tween:Cancel()
		end)

		tween:Play()
	end
end

--[=[
	Cola cada contador na carta dele.

	O contador saiu de dentro do card para poder desenhar na frente de todos eles,
	entao o vinculo que era de parentesco virou esta conta, refeita a cada quadro: o
	centro sai da posicao que ele tinha dentro da carta, girado pela inclinacao dela
	e medido em cima do tamanho **absoluto** do card -- que ja inclui o `UIScale` do
	hover. Passar o mouse cresce a carta e o contador junto.
]=]
function module:_followCounts()
	local layerPosition = self.CountLayer and self.CountLayer.AbsolutePosition
	if not layerPosition then
		return
	end

	for _, entry in self.entries do
		local badge = entry.Badge
		if not badge or not badge.Visible then
			continue
		end

		local card = entry.Card
		local size = card.AbsoluteSize
		local center = card.AbsolutePosition + size / 2

		local offset = Vector2.new(
			(defaults.CountCenter.X - 0.5) * size.X,
			(defaults.CountCenter.Y - 0.5) * size.Y
		)

		local radians = math.rad(card.Rotation)
		local sin, cos = math.sin(radians), math.cos(radians)

		local rotated = Vector2.new(
			offset.X * cos - offset.Y * sin,
			offset.X * sin + offset.Y * cos
		)

		local badgeCenter = center + rotated - layerPosition

		badge.Position = UDim2.fromOffset(badgeCenter.X, badgeCenter.Y)
		badge.Size = UDim2.fromOffset(size.X * defaults.CountSize.X, size.Y * defaults.CountSize.Y)
		badge.Rotation = card.Rotation
	end
end

local function getParts(card : GuiObject, badge : GuiObject?)
	local countLabel = badge and badge:FindFirstChild(COUNT_NAME)
	local costLabel = card:FindFirstChild(COST_NAME)

	return {
		Card = card,
		Cost = costLabel,
		CostStroke = costLabel and costLabel:FindFirstChildOfClass("UIStroke"),
		CountHolder = badge,
		CountLabel = countLabel,
		CountStroke = countLabel and countLabel:FindFirstChildOfClass("UIStroke"),
		UnitName = card:FindFirstChild(UNIT_NAME_NAME),
	}
end

--[=[
	O clima no ceu, do jeito que o `ToggleTower` tambem pergunta.

	Pedido na hora em vez de guardado: o preco da carta e reescrito em dois momentos
	so (quando a carta nasce e quando o clima troca), e nos dois a resposta certa e a
	de agora.
]=]
local function getWeather()
	local weatherController = Framework:Get("WeatherController", false, false)
	return weatherController and weatherController:GetCurrent() or nil
end

--[=[
	O que custa colocar a unidade agora -- com o desconto do clima, se houver (a
	chuva tira 25% do Ice).

	Mesma funcao que o servidor cobra em `PlaceUnit`, de proposito: e o que impede a
	carta de mostrar um preco e a colocacao descontar outro.
]=]
local function placeCost(unitName : string?) : number
	if not unitName then return 0 end

	return SharedConfig.UnitUpgradeConfig:GetPlaceCost(unitName, getWeather())
end

-- Estado visual da carta: sem estoque tem prioridade sobre falta de dinheiro, ja
-- que sem unidade a carta nao pode ser usada de jeito nenhum.
function module:_resolveState(unitName : string?) : string
	if unitName and SharedConfig.UnitStats[unitName] and self.cash < placeCost(unitName) then
		return "NoCash"
	end

	return "Available"
end

--[=[
	Escreve o preco na carta. Fica numa funcao propria porque ele nao e mais fixo:
	entrar ou sair um clima que mexe em `Cost` reescreve todos.
]=]
function module:_writeCost(entry)
	if not entry.Parts.Cost then return end

	entry.Parts.Cost.Text = "$" .. placeCost(entry.Unit)
end

--[=[
	Escreve a transparencia de cada peca da carta.

	Hoje so existe um motivo para uma peca apagar: o `Dimmed`, que e "tem outra carta
	escolhida". A conta parte sempre do valor autorado, entao desfaze-lo devolve
	exatamente o original.
]=]
function module:_applyTransparency(entry)
	entry.FadeMaid:DoCleaning()

	-- Trancada manda em apagada: as duas são o mesmo canal, e a mais forte é a que
	-- o jogador precisa entender primeiro.
	local dim = if entry.Locked then LOCKED_AMOUNT elseif entry.Dimmed then DIM_AMOUNT else 0

	for _, fade in entry.Fades do
		local goal = {}

		for property, authored in fade.Values do
			goal[property] = authored + (1 - authored) * dim
		end

		local tween = TweenService:Create(fade.Object, SCALE_INFO, goal)
		entry.FadeMaid:GiveTask(function()
			tween:Cancel()
		end)

		tween:Play()
	end
end

function module:_applyState(entry)
	local state = self:_resolveState(entry.Unit)
	if entry.State == state then
		return
	end

	entry.State = state

	local parts = entry.Parts

	self:_applyTransparency(entry)

	local costStroke = defaults.CostStroke
	local countImage = defaults.CountImage
	local countStroke = defaults.CountStroke

	if state == "NoCash" then
		costStroke = NO_CASH_COLOR
		countImage = NO_CASH_COLOR
		countStroke = NO_CASH_COLOR
	end

	if parts.CostStroke and costStroke then
		parts.CostStroke.Color = costStroke
	end

	if parts.CountHolder and countImage then
		parts.CountHolder.ImageColor3 = countImage
	end

	if parts.CountStroke and countStroke then
		parts.CountStroke.Color = countStroke
	end
end

--[=[
	Escreve o contador e decide se a carta continua na mao: zerou, ela cai para fora;
	voltou a ter unidade, ela sobe de volta.
]=]
function module:_writeCount(entry, instant : boolean?)
	if entry.Parts.CountLabel then
		entry.Parts.CountLabel.Text = tostring(self.counts[entry.Unit] or 0) .. "x"
	end

	self:_setAvailable(entry, (self.counts[entry.Unit] or 0) > 0, instant)
	self:_applyState(entry)
end

--[=[
	Com alguma carta escolhida, todas as outras apagam um pouco. Sem escolha nenhuma
	-- ou nela mesma --, nada apaga.
]=]
function module:_setDimmed(entry)
	local hasSelection = self.selected ~= nil or self.selectedRound ~= nil
	local dimmed = hasSelection and not self:_isSelected(entry)

	if entry.Dimmed == dimmed then
		return
	end

	entry.Dimmed = dimmed
	self:_applyTransparency(entry)
end

--[=[
	Se esta e a carta que esta na mao do jogador agora.

	Carta de round se identifica pelo `uid` da compra e carta de unidade pelo nome
	da unidade, entao a pergunta e uma so mas a chave e outra. O `~= nil` dos dois
	lados nao e detalhe: sem ele, `nil == nil` daria "escolhida" para **todas** as
	cartas de round sempre que nao houvesse unidade equipada.
]=]
function module:_isSelected(entry) : boolean
	if entry.Uid ~= nil then
		return entry.Uid == self.selectedRound
	end

	return entry.Unit ~= nil and entry.Unit == self.selected
end

--[=[
	Onde a escala da carta descansa quando o mouse nao esta em cima dela: 1.1 se ela
	e a escolhida, 1 no resto do tempo.
]=]
function module:_restScale(entry) : number
	return if self:_isSelected(entry) then SELECTED_SCALE else 1
end

--[=[
	Leva a escala da carta ao estado em que ela deveria estar. Um tween so para
	todas as trocas -- entrar e sair do mouse, ser escolhida, deixar de ser --,
	entao nenhuma delas salta.

	Sai fora quando o alvo nao mudou: sem isso, um `setSelected` que nao mexe nesta
	carta reiniciaria a animacao dela do meio do caminho. Devolve se mexeu, porque
	carta que muda de tamanho reacomoda o deck -- e quem chama e que sabe se isso e
	uma carta so ou varias de uma vez.
]=]
function module:_applyScale(entry) : boolean
	local target = self:_restScale(entry)
	if entry.Hovered then
		target *= HOVER_SCALE
	end

	if entry.ScaleTarget == target then
		return false
	end

	entry.ScaleTarget = target
	entry.ScaleMaid:DoCleaning()

	local tween = TweenService:Create(entry.Scale, SCALE_INFO, { Scale = target })
	entry.ScaleMaid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()

	return true
end

function module:_setHovered(entry, hovered : boolean)
	entry.Hovered = hovered

	self:_refreshDepth(entry)

	if self:_applyScale(entry) then
		self:_layout()
	end
end

--[=[
	Quem esta na frente de quem. A carta debaixo do mouse ganha de todas; a
	escolhida fica na frente das vizinhas, porque ela esta maior que elas e nao pode
	crescer por baixo.
]=]
function module:_refreshDepth(entry)
	if entry.Hovered then
		entry.Wrapper.ZIndex = HOVER_ZINDEX
		return
	end

	entry.Wrapper.ZIndex = if self:_isSelected(entry) then SELECTED_ZINDEX else BASE_ZINDEX
end

--[=[
	Monta o `entry` de uma carta ja desenhada e a poe na mao.

	Tudo que e do arco mora aqui, e nada disto sabe de onde a carta veio: a escala,
	a posicao e a rotacao de descanso, a lista de transparencias para a apagada, os
	maids e os tres eventos do botao. E o que faz uma carta comprada na loja se
	comportar exatamente como uma carta de unidade -- ela cai no arco, cresce no
	hover, empurra as vizinhas e apaga quando outra e escolhida, pelo mesmo codigo.

	Quem chama diz o que e especifico da origem:

	| Campo | O que e |
	| --- | --- |
	| `Wrapper` / `Card` | as duas pecas: o wrapper ocupa a vaga na fila, a carta e que anima |
	| `Button` | quem recebe o clique; a carta de unidade tem um `Button` dentro, a de round e o proprio botao |
	| `Badge` | o contador, que ja saiu para a camada de cima (so a carta de unidade tem) |
	| `Activate` | o que o clique (e o atalho de teclado) faz |
]=]
function module:_buildEntry(config)
	local wrapper = config.Wrapper
	local card = config.Card
	local badge = config.Badge

	local scale = card:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = card
	end

	wrapper.LayoutOrder = config.Index
	wrapper.ZIndex = BASE_ZINDEX

	local entry = {
		Kind = config.Kind,
		Unit = config.Unit,

		-- So a carta de round tem: e o `uid` da compra, e e por ele que ela e a
		-- escolhida (ver `_isSelected`).
		Uid = config.Uid,

		Activate = config.Activate,

		Index = config.Index,
		Wrapper = wrapper,
		Card = card,
		Badge = badge,
		Scale = scale,
		Parts = getParts(card, badge),
		Height = cardHeightScale(card),

		-- A posicao e a rotacao que o molde tem sao as do vertice: e delas que o
		-- arco desce e inclina.
		BasePosition = card.Position,
		BaseRotation = card.Rotation,

		Hovered = false,
		Dimmed = false,
		ScaleTarget = 1,
		Present = true,

		-- Lido do clone intocado: e para ca que qualquer apagada volta.
		Fades = captureFades({ card, badge }),

		Maid = Maid.new(),
		ArcMaid = Maid.new(),
		ScaleMaid = Maid.new(),
		FadeMaid = Maid.new(),
		ExitMaid = Maid.new(),
	}

	entry.Maid:GiveTask(wrapper)
	entry.Maid:GiveTask(entry.ArcMaid)
	entry.Maid:GiveTask(entry.ScaleMaid)
	entry.Maid:GiveTask(entry.FadeMaid)
	entry.Maid:GiveTask(entry.ExitMaid)

	-- O contador nao mora mais no wrapper, entao ele nao morre junto com ele.
	if badge then
		entry.Maid:GiveTask(badge)
	end

	-- Mexer no tamanho da carta (no Studio, ou em tempo de execucao) reacomoda o
	-- deck pelo mesmo caminho que a escala.
	entry.Maid:GiveTask(card:GetPropertyChangedSignal("Size"):Connect(function()
		self:_layout()
	end))

	local button = config.Button
	if button and button:IsA("GuiButton") then
		entry.Maid:GiveTask(button.Activated:Connect(function()
			entry.Activate()
		end))

		entry.Maid:GiveTask(button.MouseEnter:Connect(function()
			self:_setHovered(entry, true)
		end))

		entry.Maid:GiveTask(button.MouseLeave:Connect(function()
			self:_setHovered(entry, false)
		end))
	end

	wrapper.Parent = TowerContainer

	return entry
end

--[=[
	A ordem da fila e o que decide o arco: `_vertex` conta a partir dela, e o
	`UIListLayout` espalha os wrappers por ela.

	Corre `self.entries` inteiro em vez de guardar um contador porque a lista muda
	pelos dois lados -- o deck e reconstruido do zero a cada troca, e as cartas de
	round entram e saem no meio de tudo isso.
]=]
function module:_reindex()
	for index, entry in self.entries do
		entry.Index = index
		entry.Wrapper.LayoutOrder = index
	end
end

function module:_createEntry(unitName : string, index : number, callbackDo : (string) -> ())
	local wrapper = (getTemplate() :: Frame):Clone()
	local card = wrapper:FindFirstChild(CARD_NAME)

	if not card or not card:IsA("GuiObject") then
		wrapper:Destroy()
		return nil
	end

	wrapper.Name = unitName

	-- O contador sai da carta e vai para a camada de cima, onde ele nao some atras
	-- do card vizinho. Quem o mantem colado na carta e o `_followCounts`.
	local badge = card:FindFirstChild(COUNT_NAME)
	if badge and self.CountLayer then
		badge.AnchorPoint = Vector2.new(0.5, 0.5)
		badge.Parent = self.CountLayer
	end

	local entry = self:_buildEntry({
		Kind = "Unit",
		Unit = unitName,
		Index = index,
		Wrapper = wrapper,
		Card = card,
		Badge = badge,
		Button = card:FindFirstChild(BUTTON_NAME),
		Activate = function()
			callbackDo(unitName)
		end,
	})

	if entry.Parts.UnitName then
		entry.Parts.UnitName.Text = unitName
	end

	self:_writeCost(entry)

	--[[
		A arte da carta e por unidade, e e a carta inteira: o `Card` e um ImageLabel,
		nao uma moldura com a ilustracao dentro.

		Unidade sem id no `CardConfig` fica com a arte que o `CardWrapper` trouxe
		autorada -- carta com a arte errada e melhor do que carta invisivel na hotbar,
		e o config diz quais unidades ainda estao nesse caso.
	]]
	local cardImage = SharedConfig.CardConfig.GetImage(unitName)
	if cardImage and (card:IsA("ImageLabel") or card:IsA("ImageButton")) then
		card.Image = cardImage
	end

	return entry
end

--[[ EXTERNAL ]]

--[=[
	Derruba as cartas de unidade. As de round **ficam**.

	`clean` e a primeira coisa que o `set` faz, e `set` e "redesenhe a hotbar a
	partir do deck". Uma carta comprada na loja nao veio do deck e nao tem como ser
	reconstruida a partir dele: destrui-la aqui faria trocar de unidade no meio da
	partida evaporar uma carta que o jogador pagou.

	Quem quer a mao inteira vazia chama `destroy`.
]=]
function module:clean()
	local kept = {}

	for _, entry in self.entries do
		if entry.Kind == "Round" then
			table.insert(kept, entry)
		else
			entry.Maid:DoCleaning()
		end
	end

	self.entries = kept
	self.byUnit = {}

	if self.maid then
		self.maid:DoCleaning()
		self.maid = nil
	end

	return true
end

--- Derruba as cartas de round. So o `destroy` passa por aqui.
function module:_cleanRound()
	for _, entry in self.entries do
		if entry.Kind == "Round" then
			entry.Maid:DoCleaning()
		end
	end

	self.entries = {}
	self.byRound = {}

	-- A carta escolhida saiu da mao junto com todas as outras.
	self.selectedRound = nil
	self.roundCleared = nil
end

--[=[
	Desenha a hotbar a partir do deck.

	`Cards` e a lista de unidades na ordem dos slots (ver `DeckConfig.unitList`).
	Cada uma vira um clone do molde, e no fim todas sao acomodadas no arco de uma
	vez -- e por isso que tirar ou por uma carta reposiciona o deck inteiro.

	As cartas de round que o jogador ja tinha comprado sobrevivem a isto e voltam
	para a fila **depois** das de unidade: elas nao vem do deck, e a ordem dos
	slots e a do deck.
]=]
--[=[
	Tranca a hotbar em algumas cartas.

	`allowed` é `{ [unidade] = true }`; `nil` destranca tudo. A carta trancada fica
	com `Active = false` (o clique não é aceito nem pelo botão) e apaga mais que uma
	carta simplesmente não escolhida.

	A lista fica **guardada no componente**, e não aplicada uma vez: a hotbar é
	remontada a cada troca de deck e a cada recomeço de round, e a tranca tem de
	sobreviver a isso — senão vencer a partida e jogar de novo devolveria todas as
	cartas no primeiro passo do tutorial.
]=]
function module:setAllowed(allowed : { [string] : boolean }?)
	self.allowed = allowed

	for _, entry in self.entries do
		self:_applyAllowed(entry)
	end
end

--[=[
	Aplica a tranca a uma carta. Carta de round (sem `Unit`) nunca é trancada por
	aqui: quem cuida dela é o `TutorialStepController`, no pedido de uso.
]=]
function module:_applyAllowed(entry)
	local allowed = self.allowed == nil
		or entry.Unit == nil
		or self.allowed[entry.Unit] == true

	if entry.Locked == (not allowed) then
		return
	end

	entry.Locked = not allowed

	local card = entry.Card
	if card then
		card.Active = allowed

		if card:IsA("GuiButton") then
			card.AutoButtonColor = allowed
			card.Selectable = allowed
		end
	end

	self:_applyTransparency(entry)
end

--[=[
	A carta desta unidade na hotbar, ou `nil` se ela não está lá agora.

	Devolve a **carta**, e não o wrapper que a embala: o wrapper é a vaga no
	`UIListLayout` — ele tem a folga do arco, o espaço do contador e o que mais o
	layout precisar —, e um destaque desenhado em cima dele abraça esse vazio em vez
	da arte. Quem aponta quer a carta.

	Existe para quem precisa apontar uma carta e não desenhá-la: hoje o
	`TutorialStepController`. É leitura — quem chama não mexe no que recebe.
]=]
function module:getCard(unitName : string) : GuiObject?
	local entry = self.byUnit[unitName]

	return entry and (entry.Card or entry.Wrapper)
end

function module:set(Cards : { string }, Counts : {}, callbackDo : (string) -> ())
	-- Primeira montagem nasce pronta; troca de deck com a hotbar ja na tela entra
	-- animada, que e o unico momento em que uma carta e de fato posta ou tirada.
	local hadCards = #self.entries > 0

	self:clean()

	if not getTemplate() then
		return false
	end

	self.CountLayer = ensureCountLayer()
	self.counts = Counts or {}
	self.maid = Maid.new()

	-- O que o `clean` deixou de pe sao as cartas de round; as de unidade entram na
	-- frente delas.
	local rounds = self.entries
	self.entries = {}

	for index, unitName in Cards do
		local entry = self:_createEntry(unitName, index, callbackDo)

		if entry then
			table.insert(self.entries, entry)
			self.byUnit[unitName] = entry

			self:_writeCount(entry, true)
			self:_refreshDepth(entry)
			self:_applyAllowed(entry)

			-- A carta escolhida pode ter sobrevivido a troca de deck: os clones sao
			-- novos, entao a escala e a apagada precisam ser reaplicadas aqui -- o
			-- `setSelected` sairia fora, porque o nome escolhido nao mudou.
			self:_applyScale(entry)
			self:_setDimmed(entry)
		end
	end

	for _, entry in rounds do
		table.insert(self.entries, entry)
		self:_setDimmed(entry)
	end

	self:_reindex()
	self:_layout(not hadCards)
	self:_followCounts()

	-- Os contadores seguem a carta a cada quadro: e assim que eles acompanham o
	-- tween do arco e o crescer do hover sem um frame de atraso.
	self.maid:GiveTask(RunService.RenderStepped:Connect(function()
		self:_followCounts()
	end))

	self.maid:GiveTask(UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end

		-- Hotbar fora da tela e hotbar que nao responde: quem esconde o
		-- TowerContainer (o DifficultyController, antes da partida comecar) e quem
		-- esconde a mao inteira (a aba da loja de round) nao precisam se lembrar de
		-- desligar os atalhos tambem.
		if not TowerContainer.Visible or self.hidden then return end

		-- O numero segue o que esta na tela: carta que caiu para fora nao ocupa
		-- tecla, do mesmo jeito que nao ocupa vaga. E o `Activate` de cada uma sabe
		-- o que fazer -- equipar a unidade, ou gastar a carta de round.
		local index = KEYBINDS[input.KeyCode.Name]
		local entry = index and self:_liveEntries()[index]

		if entry then
			entry.Activate()
		end
	end))

	return true
end

function module:setCount(unitName : string, count : number)
	self.counts[unitName] = count

	local entry = self.byUnit[unitName]
	if entry then
		self:_writeCount(entry)
	end
end

--[[ CARTAS DE ROUND ]]

--[=[
	Poe na mao uma carta comprada na loja de round.

	O `wrapper` chega **pronto** -- o `RoundCardShopController` clonou o molde dele,
	escreveu titulo, descricao e arte e tirou a placa de preco. Deste lado ela vira
	uma carta da hotbar como qualquer outra: entra na fila, cai no arco, cresce no
	hover e apaga quando outra e escolhida.

	Duas normalizacoes acontecem aqui, e as duas sao sobre o **molde de origem** ser
	outro. A carta da loja e ancorada no canto (`0, 0`) e a da hotbar no centro: sem
	trocar isso, a inclinacao do arco giraria a carta em torno do canto superior
	esquerdo dela, e o crescer do hover a empurraria para o lado em vez de crescer no
	lugar.

	A entrada e a mesma de uma carta que volta a ter estoque: ela nasce fora da mao
	e **sobe** para a vaga, empurrando as vizinhas no caminho.

	`uid` e por compra, e nao por carta: a mesma carta comprada duas vezes sao duas
	cartas na mao, e usar uma nao pode mexer na outra.
]=]
function module:addRound(uid : string, wrapper : Frame, activate : () -> ()) : boolean
	if not uid or not wrapper or self.byRound[uid] then
		return false
	end

	local card = wrapper:FindFirstChild(ROUND_CARD_NAME)
	if not card or not card:IsA("GuiObject") then
		warn(`[Card]: a carta de round '{uid}' veio sem o {ROUND_CARD_NAME}.`)
		wrapper:Destroy()
		return false
	end

	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)

	local entry = self:_buildEntry({
		Kind = "Round",
		Unit = nil,
		Uid = uid,
		Index = #self.entries + 1,
		Wrapper = wrapper,
		Card = card,

		-- A carta da loja e o proprio botao; a de unidade tem um `Button` dentro.
		Button = if card:IsA("GuiButton") then card else card:FindFirstChild(BUTTON_NAME),
		Activate = activate,
	})

	table.insert(self.entries, entry)
	self.byRound[uid] = entry

	-- Fora da mao para poder entrar nela: o `_setAvailable` logo abaixo e que faz a
	-- carta subir para a vaga e o resto do deck abrir espaco.
	entry.Available = false
	entry.Card.Position = self:_exitGoal(entry)
	self:_setPresence(entry, false)

	self:_reindex()
	self:_setDimmed(entry)
	self:_refreshDepth(entry)
	self:_setAvailable(entry, true)

	return true
end

--[=[
	Tira da mao a carta de round que foi usada.

	Ela sai como qualquer outra carta que deixa o deck: cai para fora da tela, e a
	vaga so fecha quando ela termina de cair (`EXIT_INFO`). O `entry` sai da lista no
	fim da queda, e nao no comeco, porque enquanto ela esta caindo ela ainda ocupa a
	vaga dela -- fechar antes faria o deck se reacomodar por baixo da carta que ainda
	esta na tela.
]=]
function module:removeRound(uid : string) : boolean
	local entry = self.byRound[uid]
	if not entry then
		return false
	end

	self.byRound[uid] = nil

	--[[
		A carta escolhida esta saindo da mao (foi usada, ou o servidor a devolveu):
		sem largar a escolha aqui, as vizinhas ficariam apagadas para sempre em volta
		de uma carta que ja nao existe.
	]]
	if self.selectedRound == uid then
		self.selectedRound = nil
		self.roundCleared = nil

		for _, other in self.entries do
			if other ~= entry then
				self:_applyScale(other)
				self:_refreshDepth(other)
				self:_setDimmed(other)
			end
		end
	end

	self:_setAvailable(entry, false)

	task.delay(EXIT_INFO.Time, function()
		local index = table.find(self.entries, entry)
		if index then
			table.remove(self.entries, index)
		end

		entry.Maid:DoCleaning()

		self:_reindex()
		self:_layout()
	end)

	return true
end

--[=[
	Esconde (ou devolve) a mao inteira, sem ninguem perder o lugar.

	Quem liga e o `RoundCardShopController`, enquanto a aba da loja esta aberta. A
	volta devolve cada carta ao estado que ela tinha (`entry.Present`), e nao um
	"tudo aceso": carta sem unidade sobrando continua fora da tela.
]=]
function module:setHidden(hidden : boolean)
	hidden = hidden == true

	if self.hidden == hidden then
		return
	end

	self.hidden = hidden

	for _, entry in self.entries do
		self:_setPresence(entry, entry.Present ~= false)
	end
end

function module:setCash(cash : number)
	self.cash = cash or 0

	for _, entry in self.entries do
		self:_applyState(entry)
	end
end

--[=[
	O clima entrou ou saiu: reescreve o preco de cada carta e reavalia quem cabe no
	bolso.

	As duas coisas juntas, e nesta ordem, porque sao a mesma mudanca vista de dois
	lugares -- a carta que ficou 25% mais barata pode ter deixado de estar em
	vermelho no mesmo instante.
]=]
function module:refreshWeather()
	for _, entry in self.entries do
		self:_writeCost(entry)
		self:_applyState(entry)
	end
end

--[=[
	Qual carta esta escolhida. Ela descansa em `SELECTED_SCALE` e fica na frente das
	vizinhas; o arco nao se mexe. `nil` devolve todas ao tamanho normal.
]=]
function module:setSelected(unitName : string?)
	if self.selected == unitName then
		return
	end

	self.selected = unitName

	--[[
		So uma coisa por vez na mao. Por uma unidade na mao com uma carta de round
		esperando alvo deixaria as duas em pe: o fantasma da unidade e a mira da
		carta disputando o mesmo clique no mapa. Quem escolheu a carta e avisado pelo
		`onCleared` do `setSelectedRound`, e desiste da mira do lado dele.
	]]
	if unitName and self.selectedRound then
		local cleared = self.roundCleared

		self.selectedRound = nil
		self.roundCleared = nil

		if cleared then
			task.spawn(cleared)
		end
	end

	local changed = false
	for _, entry in self.entries do
		changed = self:_applyScale(entry) or changed
		self:_refreshDepth(entry)
		self:_setDimmed(entry)
	end

	-- Trocar de carta escolhida mexe em duas, mas o deck se reacomoda uma vez so.
	if changed then
		self:_layout()
	end
end

--[=[
	Qual carta de **round** esta escolhida, pelo `uid` da compra.

	E o gemeo do `setSelected`, e faz exatamente a mesma coisa: a carta cresce, vem
	para a frente e apaga as vizinhas. E o que faz uma carta de round que pede alvo
	se comportar como uma carta de unidade equipada -- ela fica "na mao" enquanto o
	jogador escolhe onde usa-la.

	`onCleared` e chamado quando **outra coisa** toma a mao (o jogador equipou uma
	unidade). Quem escolheu a carta precisa saber disso para desistir da mira, e nao
	ha como ele descobrir sozinho: o clique que trocou de mao foi na hotbar, e nao no
	mapa. Ele nao e chamado quando o proprio dono desfaz a escolha -- ali ele ja
	sabe.

	> Quem chama deve **largar a unidade antes** (`UnitPlacementController:clearInteraction`).
	> O `selected` daqui e so o desenho; o fantasma que segue o mouse e a nocao de
	> unidade equipada sao de outros dois donos, e apaga-lo por aqui os deixaria
	> discordando da tela.
]=]
function module:setSelectedRound(uid : string?, onCleared : (() -> ())?)
	if self.selectedRound == uid then
		return
	end

	self.selectedRound = uid
	self.roundCleared = if uid then onCleared else nil

	local changed = false
	for _, entry in self.entries do
		changed = self:_applyScale(entry) or changed
		self:_refreshDepth(entry)
		self:_setDimmed(entry)
	end

	if changed then
		self:_layout()
	end
end

function module:destroy()
	self:clean()

	-- O `clean` poupa as cartas de round de proposito (ele e a reconstrucao do
	-- deck); aqui a mao vai embora inteira.
	self:_cleanRound()

	self.selected = nil
	self.hidden = false
end

return module
