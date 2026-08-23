local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)
local CardUpgrade = Interface:WaitForChild("CardUpgrade")

--[=[
	O card nao entra mais deslizando de fora da tela: ele cresce no lugar.

	A animacao de posicao brigava com a mecanica de arrastar logo abaixo -- se o
	card nasce fora da tela e volta para um ponto fixo, o lugar que o jogador
	escolheu com o dedo seria desfeito toda vez que ele trocasse de unidade.
	Escalando a partir do proprio ponto, o card aparece onde quer que ele esteja.

	O `UIScale` vem do StarterGui; se algum dia sumir de la, um novo e criado aqui
	para o modulo nao quebrar.
]=]
local CardScale = CardUpgrade:FindFirstChildOfClass("UIScale")
if not CardScale then
	CardScale = Instance.new("UIScale")
	CardScale.Parent = CardUpgrade
end

-- O tamanho "aberto" e o que o designer deixou na Studio, lido antes de qualquer
-- animacao mexer no valor.
local SHOWN_SCALE : number = CardScale.Scale > 0 and CardScale.Scale or 1
CardScale.Scale = 0

--[[
	Elastic dos dois lados, mas com direcoes opostas: abrindo, o exagero acontece
	no fim (o card passa um pouco do tamanho e assenta); fechando, no comeco (ele
	da uma esticada e some). O fechamento e mais curto porque ninguem quer esperar
	a animacao do card que acabou de usar.

	Elastic nunca leva a escala abaixo de zero: o excesso e sempre para o lado de
	onde a animacao esta saindo.
]]
local SHOW_TWEEN = TweenInfo.new(0.55, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Elastic, Enum.EasingDirection.In)

local scaleTween : Tween? = nil

--[=[
	Leva a escala do card ate `target`. O `from` opcional reinicia a animacao do
	zero -- e o que da o "pop" toda vez que uma unidade e selecionada, mesmo que o
	card ja estivesse na tela por causa da unidade anterior.

	A animacao anterior e cancelada, e `Cancel` faz o `Completed` chegar como
	`Cancelled`: por isso o `onComplete` de um fechamento interrompido no meio nao
	esconde o card que uma nova selecao acabou de abrir.
]=]
local function playScale(from : number?, target : number, tweenInfo : TweenInfo, onComplete : (() -> ())?)
	if scaleTween then
		scaleTween:Cancel()
		scaleTween = nil
	end

	if from then
		CardScale.Scale = from
	end

	local tween = TweenService:Create(CardScale, tweenInfo, { Scale = target })
	scaleTween = tween

	tween.Completed:Connect(function(state)
		if scaleTween == tween then
			scaleTween = nil
		end

		if state == Enum.PlaybackState.Completed and onComplete then
			onComplete()
		end
	end)

	tween:Play()
end

--[[
	Arrastar o card.

	O jogador pega o card em qualquer ponto -- fundo, textos ou os proprios botoes
	-- e larga onde quiser, no mouse ou no dedo. O ponto escolhido fica guardado
	aqui em `cachedPosition` e vale para o resto da sessao: toda unidade que ele
	selecionar depois abre o card no mesmo lugar.

	O cache guarda a posicao em escala, e nao em pixels: assim o card continua no
	mesmo canto da tela se a janela mudar de tamanho ou o aparelho girar.
]]
local cachedPosition : UDim2 = CardUpgrade.Position

-- Quanto o ponteiro precisa andar para aquilo virar um arrasto. Abaixo disso e
-- clique: dedo nenhum fica perfeitamente parado, e o botao VENDER nao pode falhar
-- porque o toque escorregou dois pixels.
local DRAG_THRESHOLD = 6

-- Depois de largar o card, o clique que fechou o arrasto ainda chega nos botoes.
-- Essa janela curta engole esse clique -- arrastar o card pelo VENDER nao pode
-- vender a unidade.
local CLICK_BLOCK_TIME = 0.15

local dragInput : InputObject? = nil
local dragStart : Vector2? = nil
local dragOrigin : Vector2? = nil
local dragMoved = false
local clickBlockedUntil = 0

local function isClickSuppressed() : boolean
	return dragMoved or os.clock() < clickBlockedUntil
end

--[=[
	O retangulo onde o card pode andar: o proprio ScreenGui.
]=]
local function getParentRect() : (Vector2?, Vector2?)
	local parent = CardUpgrade.Parent
	if not parent or not parent:IsA("GuiBase2d") then
		return nil, nil
	end

	local gui = parent :: GuiBase2d
	return gui.AbsolutePosition, gui.AbsoluteSize
end

--[=[
	Move o card seguindo o ponteiro, sem deixar ele sair da tela.

	A conta e toda em pixels (`AbsolutePosition` ja e o canto de cima do card,
	porque o `AnchorPoint` e 0,0) e so no fim vira escala -- que e o formato que o
	cache guarda.
]=]
local function moveCardTo(pointer : Vector2)
	if not dragStart or not dragOrigin then return end

	local parentPosition, parentSize = getParentRect()
	if not parentPosition or not parentSize then return end
	if parentSize.X <= 0 or parentSize.Y <= 0 then return end

	local cardSize = CardUpgrade.AbsoluteSize
	local maxX = math.max(parentSize.X - cardSize.X, 0)
	local maxY = math.max(parentSize.Y - cardSize.Y, 0)

	local delta = pointer - dragStart
	local x = math.clamp(dragOrigin.X + delta.X, 0, maxX)
	local y = math.clamp(dragOrigin.Y + delta.Y, 0, maxY)

	CardUpgrade.Position = UDim2.fromScale(x / parentSize.X, y / parentSize.Y)
end

local function beginDrag(input : InputObject)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end

	local parentPosition = getParentRect()
	if not parentPosition then return end

	dragInput = input
	dragStart = Vector2.new(input.Position.X, input.Position.Y)
	dragOrigin = CardUpgrade.AbsolutePosition - parentPosition
	dragMoved = false
end

local function endDrag()
	if not dragInput then return end

	dragInput = nil
	dragStart = nil
	dragOrigin = nil

	if dragMoved then
		cachedPosition = CardUpgrade.Position
		clickBlockedUntil = os.clock() + CLICK_BLOCK_TIME
	end

	dragMoved = false
end

--[=[
	Liga o inicio do arrasto num pedaco do card.

	Os botoes tambem entram: eles engolem a entrada antes de ela chegar ao card, e
	sem isso boa parte da area do card nao seria agarravel. Quem separa clique de
	arrasto e o `DRAG_THRESHOLD`.
]=]
local function attachDragSource(instance : Instance)
	if not instance:IsA("GuiObject") then return end
	instance.InputBegan:Connect(beginDrag)
end

-- Um `ImageLabel` so recebe entrada com `Active` ligado. De quebra, isso faz o
-- card engolir o clique: apertar nele nao vaza mais para o mundo atras, que era o
-- que desmarcava a unidade no meio de um arrasto.
CardUpgrade.Active = true
attachDragSource(CardUpgrade)

for _, descendant in CardUpgrade:GetDescendants() do
	if descendant:IsA("GuiButton") then
		attachDragSource(descendant)
	end
end

CardUpgrade.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("GuiButton") then
		attachDragSource(descendant)
	end
end)

--[[
	O movimento e o fim do arrasto sao ouvidos no `UserInputService`, e nao no
	card: o dedo (ou o mouse) sai de cima do card o tempo todo enquanto arrasta, e
	os eventos do proprio card parariam de chegar exatamente ai.

	No toque, o objeto de entrada e o mesmo do comeco ao fim -- comparar por
	identidade e o que impede um segundo dedo na tela de sequestrar o arrasto. No
	mouse, o movimento chega como `MouseMovement`, um objeto diferente do botao
	que esta segurando o card.
]]
UserInputService.InputChanged:Connect(function(input)
	if not dragInput or not dragStart then return end

	local isDragMove = input == dragInput
		or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement)

	if not isDragMove then return end

	local pointer = Vector2.new(input.Position.X, input.Position.Y)
	if not dragMoved and (pointer - dragStart).Magnitude < DRAG_THRESHOLD then return end

	dragMoved = true
	moveCardTo(pointer)
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragInput then return end

	-- No toque, so o proprio dedo termina o arrasto: outro dedo saindo da tela nao
	-- pode largar o card no meio do caminho. No mouse basta o tipo bater, porque o
	-- botao que solta e sempre o mesmo que apertou.
	local endsDrag = input == dragInput
		or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1)

	if endsDrag then
		endDrag()
	end
end)

-- Alt-tab no meio do arrasto: o `InputEnded` do botao nunca chega, e sem isso o
-- card ficaria colado no ponteiro quando o jogador voltasse.
UserInputService.WindowFocusReleased:Connect(endDrag)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local ClassConfig = SharedConfig.ClassConfig
local UIUtil = require(Utils.UIUtil)
local PointerUtil = require(Utils.PointerUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

local module = {}
module.currentUnit = nil

--[=[
	Numero com no maximo `decimals` casas e sem zeros sobrando: 12.00 -> "12",
	0.75 -> "0.75". So mexe na parte decimal, entao 100 continua "100".
]=]
local function formatNumber(value : number, decimals : number?) : string
	local text = string.format("%." .. (decimals or 0) .. "f", value)

	if text:find("%.") then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end

	return text
end

--[=[
	Stats do card sao numeros pequenos (dano, alcance); acima de mil
	vale mais abreviar do que mostrar a casa decimal.
]=]
local function formatStat(value : number) : string
	if value >= 1000 then
		return UIUtil.formatAbbreviated(math.floor(value + 0.5))
	end

	return formatNumber(value, 1)
end

--[=[
	Cada label de stat do card tem um irmao menor logo abaixo, deixado no
	StarterGui, que mostra o valor que a unidade vai ter depois do proximo upgrade.
	A ordem aqui e {label que ja existia, previa dele}.
]=]
local PREVIEW_LABELS = {
	{ stat = "DamagePerSecond", preview = "DamagePerSecondUpgrade" },
	{ stat = "AttackSpeed", preview = "CooldownUpgrade" },
	{ stat = "Range", preview = "RangeUpgrade" },
}

local function getPreviewLabel(entry) : TextLabel?
	local stat = CardUpgrade:FindFirstChild(entry.stat)
	return stat and stat:FindFirstChild(entry.preview)
end

local function hidePreviewLabels()
	for _, entry in PREVIEW_LABELS do
		local label = getPreviewLabel(entry)
		if label then
			label.Visible = false
		end
	end
end

--[[
	O clima entra nos numeros de combate do card.

	E o mesmo motivo do circulo de alcance no chao: durante a neblina a unidade
	procura alvo num raio menor, e um card que continuasse mostrando o alcance
	seco estaria mentindo sobre a unidade que o jogador esta olhando. Quem
	redesenha o card na troca de clima e o `UnitPlacementController`.
]]
local function getWeather()
	local weatherController = Framework:Get("WeatherController", false, false)
	return weatherController and weatherController:GetCurrent() or nil
end

--[=[
	Dano por golpe, ou a renda por wave quando a unidade e uma Farm -- que nao
	ataca. Mesma conta para o nivel atual e para a previa do proximo.
]=]
local function formatDamageOrIncome(unitName : string, level : number, weather) : string
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local unitStats = SharedConfig.UnitStats[unitName]
	local farm = unitStats and unitStats.Farm

	if farm then
		local income = math.floor((farm.Income or 0) * upgradeConfig:GetDamageMultiplier(unitName, level) + 0.5)
		return "$" .. UIUtil.formatAbbreviated(income) .. " INCOME"
	end

	return formatStat(upgradeConfig:GetDamage(unitName, level, weather)) .. " DMG"
end

--[=[
	O botao de pulo do Roblox no celular, se estiver na tela. `TouchGui` so existe
	em aparelho de toque, e nasce de novo a cada respawn -- por isso ele e
	procurado na hora, e nunca guardado.
]=]
local function findJumpButton() : GuiObject?
	local touchGui = PlayerGui:FindFirstChild("TouchGui")
	local controlFrame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local button = controlFrame and controlFrame:FindFirstChild("JumpButton")

	return button and button:IsA("GuiObject") and button or nil
end

function module:create(unitModel, ...)
	if self.maid then
		self.maid:Destroy()
		self.maid = nil
	end

	self.maid = Maid.new()
	self.currentUnit = unitModel

	local sellButton = CardUpgrade:FindFirstChild("Sell")
	if sellButton and self.sellConnection then
		self.sellConnection:Disconnect()
		self.sellConnection = nil
	end

	if sellButton and unitModel then
		-- `Activated` e nao `MouseButton1Up`: no toque, se o dedo escorrega para fora
		-- do botao antes de soltar, o MouseButton1Up nao chega e a venda se perde.
		self.sellConnection = sellButton.Activated:Connect(function()
			-- Quem acabou de arrastar o card pelo botao nao quis vender nada.
			if isClickSuppressed() then return end

			local unitId = unitModel:GetAttribute("UnitID")
			Framework:Fire("SellUnit", unitId)
			self:destroy()
		end)
		self.maid:GiveTask(function()
			if self.sellConnection then
				self.sellConnection:Disconnect()
				self.sellConnection = nil
			end
		end)
	end

	local upgradeButton = CardUpgrade:FindFirstChild("UpgradeCost")
	if self.upgradeConnection then
		self.upgradeConnection:Disconnect()
		self.upgradeConnection = nil
	end

	if upgradeButton and unitModel then
		self.upgradeConnection = upgradeButton.Activated:Connect(function()
			if isClickSuppressed() then return end

			local level = unitModel:GetAttribute("Upgrades") or 0
			if SharedConfig.UnitUpgradeConfig:IsMaxed(level) then return end
			local unitId = unitModel:GetAttribute("UnitID")
			Framework:Fire("UpgradeUnit", unitId)
		end)
		self.maid:GiveTask(function()
			if self.upgradeConnection then
				self.upgradeConnection:Disconnect()
				self.upgradeConnection = nil
			end
		end)
	end

	--[[
		Previa do proximo nivel.

		No PC ela so aparece com o mouse em cima do custo de upgrade: o jogador ve
		o que o dinheiro compra antes de gastar, e o card fica limpo no resto do
		tempo. No celular nao existe "pairar por cima" -- o dedo ou esta apertando
		ou nao esta na tela --, entao la os numeros ficam sempre visiveis.
	]]
	self.previewHovered = false

	if upgradeButton and not PointerUtil.isTouchOnly() then
		self.maid:GiveTask(upgradeButton.MouseEnter:Connect(function()
			self.previewHovered = true
			self:refreshPreview()
		end))
		self.maid:GiveTask(upgradeButton.MouseLeave:Connect(function()
			self.previewHovered = false
			self:refreshPreview()
		end))
	end

	local priorityButton = CardUpgrade:FindFirstChild("Priority")
	if self.priorityConnection then
		self.priorityConnection:Disconnect()
		self.priorityConnection = nil
	end

	if priorityButton and unitModel then
		--[[
			Um clique anda uma casa no ciclo do `TargetPriority`. O que vai para o
			servidor e o modo de destino, nao "o proximo": o botao le o estado do
			atributo, que e o que o servidor confirmou por ultimo, entao dois cliques
			seguidos nao se atropelam.

			O texto do botao nao muda aqui -- ele muda quando a confirmacao volta e
			mexe no atributo. Assim o card nunca mostra uma prioridade que o servidor
			recusou (unidade de outro jogador, por exemplo).
		]]
		self.priorityConnection = priorityButton.Activated:Connect(function()
			if isClickSuppressed() then return end

			local unitId = unitModel:GetAttribute("UnitID")
			if not unitId then return end

			Framework:Fire("SetUnitPriority", unitId, TargetPriority.Next(unitModel:GetAttribute("TargetPriority")))
		end)
		self.maid:GiveTask(function()
			if self.priorityConnection then
				self.priorityConnection:Disconnect()
				self.priorityConnection = nil
			end
		end)
	end

	if unitModel then
		-- Upgrade muda dano/alcance/cooldown e o custo do proximo nivel; o dano total
		-- chega em lote do servidor algumas vezes por segundo.
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("Upgrades"):Connect(function()
			self:refresh()
		end))
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("TargetPriority"):Connect(function()
			self:refreshPriority()
		end))
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("DamageDone"):Connect(function()
			self:refreshDamageDone()
		end))
	end

	self:refresh()

	--[[
		O card abre no lugar em que o jogador o deixou da ultima vez -- ou onde o
		layout o colocou, se ele nunca tiver arrastado nada.

		A posicao so e reescrita quando ninguem esta com o card na mao: trocar de
		unidade no meio de um arrasto nao pode arrancar o card do dedo.
	]]
	if not dragInput then
		CardUpgrade.Position = cachedPosition
	end

	CardUpgrade.Visible = true
	playScale(0, SHOWN_SCALE, SHOW_TWEEN)

	self:setJumpButtonHidden(true)
end

--[=[
	Tira o botao de pulo da tela enquanto o card estiver aberto, e devolve depois.

	No celular o card abre exatamente por cima do canto onde o Roblox desenha o
	botao de pulo: os dois disputam o mesmo dedo, e o jogador que ia apertar
	VENDER pula. So no toque -- num PC o botao nem existe.

	Nao e `controls:Disable()`: isso levaria junto o direcional, e o jogador
	continua podendo andar com o card aberto. O que sai e so o botao.

	A escondida fica vigiada porque o `TouchGui` nao e nosso: o modulo TouchJump do
	Roblox reescreve `Visible` sozinho (ao renascer, ao sentar, ao voltar a poder
	pular) e um respawn troca o botao por um novo. Enquanto o card estiver aberto,
	qualquer botao de pulo que aparecer volta a ficar escondido -- e o que o
	TouchJump quis nesse meio tempo e o que se devolve no fim, para nao acender um
	botao que o Roblox tinha apagado de proposito.
]=]
function module:setJumpButtonHidden(hidden : boolean)
	if self.jumpMaid then
		self.jumpMaid:Destroy()
		self.jumpMaid = nil
	end

	if not hidden or not PointerUtil.isTouchOnly() then return end

	local maid = Maid.new()
	self.jumpMaid = maid

	local active = true
	local wanted = true

	local function hide(button : GuiObject)
		wanted = button.Visible
		button.Visible = false

		maid:GiveTask(button:GetPropertyChangedSignal("Visible"):Connect(function()
			if not active or not button.Visible then return end
			wanted = true
			button.Visible = false
		end))
	end

	local button = findJumpButton()
	if button then
		hide(button)
	end

	maid:GiveTask(PlayerGui.DescendantAdded:Connect(function(descendant)
		if not active or descendant.Name ~= "JumpButton" then return end
		if descendant ~= findJumpButton() then return end

		hide(descendant)
	end))

	-- Primeiro desliga a vigia, depois devolve: assim a restauracao nao cai no
	-- proprio observador e apaga o botao de novo.
	maid:GiveTask(function()
		active = false

		local current = findJumpButton()
		if current then
			current.Visible = wanted
		end
	end)
end

--[=[
	O icone de classe do card: `Melee`, `Ranged`, `Magic`, `Fire`, `Ice` ou
	`Electric`, pela classe que a unidade declara em `UnitStats`.

	Unidade sem classe (ou classe que ainda nao tem arte) esconde o label em vez de
	mostrar um quadrado vazio -- e ele volta sozinho na proxima unidade que tiver.

	`FindFirstChild` porque o `ClassIcon` e recente no StarterGui: sem ele o card
	inteiro continua funcionando, so sem o icone.
]=]
local function applyClassIcon(unitName : string?)
	local icon = CardUpgrade:FindFirstChild("ClassIcon")
	if not icon or not icon:IsA("ImageLabel") then return end

	local image = ClassConfig.GetIcon(unitName)

	icon.Image = image or ""
	icon.Visible = image ~= nil
end

--[=[
	Preenche todo o card com os dados da unidade selecionada. Cada label leva o
	sufixo que o designer deixou no StarterGui, so o numero e trocado.
]=]
function module:refresh()
	local unitModel = self.currentUnit

	local upgradeLabel = CardUpgrade.UpgradeCost:FindFirstChild("TextLabel")
	local sellLabel = CardUpgrade.Sell:FindFirstChild("TextLabel")

	if not unitModel or not unitModel.Parent then
		if upgradeLabel then upgradeLabel.Text = "" end
		if sellLabel then sellLabel.Text = "SELL" end
		applyClassIcon(nil)
		return
	end

	local unitName = unitModel.Name
	local level = unitModel:GetAttribute("Upgrades") or 0
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local weather = getWeather()

	CardUpgrade.Info.UnitName.Text = unitName
	CardUpgrade.Info.UnitLevel.Text = "LVL." .. level
	applyClassIcon(unitName)

	if upgradeLabel then
		if upgradeConfig:IsMaxed(level) then
			upgradeLabel.Text = "MAX"
		else
			upgradeLabel.Text = "$" .. UIUtil.formatAbbreviated(upgradeConfig:GetCost(unitName, level))
		end
	end

	-- Mesma conta do servidor no `SellUnit`: parte do que foi investido volta.
	if sellLabel then
		local invested = upgradeConfig:GetInvested(unitName, level)
		local refund = math.floor(invested * SharedConfig.SellRefundRatio)
		sellLabel.Text = "SELL $" .. UIUtil.formatAbbreviated(refund)
	end

	--[[
		O label `DamagePerSecond` mostra o dano por golpe, nao o DPS: o numero que
		interessa na hora de comprar um upgrade e o que entra no mob por batida — o
		cooldown ja esta logo abaixo, no proprio card, para quem quiser a conta por
		segundo.

		Farm nao ataca: no lugar do dano, a renda por wave.
	]]
	CardUpgrade.DamagePerSecond.Text = formatDamageOrIncome(unitName, level, weather)

	CardUpgrade.AttackSpeed.Text = formatNumber(upgradeConfig:GetCooldown(unitName, level, weather), 2) .. " COOLDOWN"
	CardUpgrade.Range.Text = formatStat(upgradeConfig:GetRange(unitName, level, weather)) .. " RANGE"

	self:refreshPreview()
	self:refreshPriority()
	self:refreshDamageDone()
end

--[=[
	Escreve nas previas o que a unidade vira depois do proximo upgrade -- os mesmos
	getters do card, so que com `level + 1`, entao dano, cooldown e alcance da
	previa saem da mesma conta que o servidor usa em combate (clima incluido).

	No nivel maximo as previas somem, mesmo no celular: nao ha proximo valor para
	mostrar, e o custo ao lado ja esta escrito "MAX".
]=]
function module:refreshPreview()
	local unitModel = self.currentUnit
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local level = unitModel and unitModel:GetAttribute("Upgrades") or 0

	local shouldShow = self.previewHovered or PointerUtil.isTouchOnly()
	if not unitModel or not unitModel.Parent or upgradeConfig:IsMaxed(level) then
		shouldShow = false
	end

	if not shouldShow then
		hidePreviewLabels()
		return
	end

	local unitName = unitModel.Name
	local weather = getWeather()
	local nextLevel = level + 1

	local texts = {
		DamagePerSecondUpgrade = formatDamageOrIncome(unitName, nextLevel, weather),
		CooldownUpgrade = formatNumber(upgradeConfig:GetCooldown(unitName, nextLevel, weather), 2) .. " COOLDOWN",
		RangeUpgrade = formatStat(upgradeConfig:GetRange(unitName, nextLevel, weather)) .. " RANGE",
	}

	for _, entry in PREVIEW_LABELS do
		local label = getPreviewLabel(entry)
		if label then
			label.Text = texts[entry.preview]
			label.Visible = true
		end
	end
end

--[=[
	Escreve no botao a prioridade de alvo que a unidade esta usando. Sai do
	atributo do modelo, que e o que o servidor mandou -- o botao nunca adivinha.
]=]
function module:refreshPriority()
	local button = CardUpgrade:FindFirstChild("Priority")
	local label = button and button:FindFirstChild("TextLabel")
	if not label then return end

	local unitModel = self.currentUnit
	if not unitModel or not unitModel.Parent then return end

	-- Farm nao mira em ninguem: o botao sai da tela em vez de mostrar uma
	-- prioridade que nao vai ser usada.
	local unitStats = SharedConfig.UnitStats[unitModel.Name]
	button.Visible = not (unitStats and unitStats.Farm)

	label.Text = TargetPriority.Label(unitModel:GetAttribute("TargetPriority"))
end

function module:refreshDamageDone()
	local unitModel = self.currentUnit
	if not unitModel or not unitModel.Parent then return end

	local total = math.floor((unitModel:GetAttribute("DamageDone") or 0) + 0.5)
	CardUpgrade.DmgDone.Text = UIUtil.formatAbbreviated(total) .. " DMG DONE"
end

function module:destroy()
	self.currentUnit = nil
	self.previewHovered = false
	hidePreviewLabels()
	if self.maid then
		self.maid:Destroy()
	end

	self.maid = nil

	-- O card so sai da tela quando a animacao termina de encolher. Se uma nova
	-- unidade for selecionada nesse meio tempo, o `playScale` do `create` cancela
	-- este tween e este `Visible = false` nunca chega a acontecer.
	playScale(nil, 0, HIDE_TWEEN, function()
		CardUpgrade.Visible = false
		self:setJumpButtonHidden(false)
	end)
end

return module
