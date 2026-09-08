local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Me = require(Vendor.Me)
local Framework = Me.new()

local SpeedConfig = SharedConfig.SpeedConfig
local GamepassConfig = SharedConfig.GamepassConfig

--[[
	O "pop" do clique, igual ao dos botoes do HUD do Lobby
	(`HUDButtonController`): encolhe enquanto o botao esta apertado e volta com um
	overshoot ao soltar, com o `UIClick` saindo na volta.
]]
local PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local PRESS_SCALE = 0.9

local CLICK_SOUND = "UIClick"

--[[
	A expansao. Cada opcao ocupa um "slot" a partir do original, e o slot vale a
	largura renderizada do botao vezes EXPAND_SPACING -- medida na hora, e nao pelo
	`Size` autorado, porque quem manda no tamanho final e o
	UIAspectRatioConstraint do botao.
]]
local EXPAND_DIRECTION = 1     -- 1 abre para a direita, -1 para a esquerda
local EXPAND_SPACING = 1.2     -- largura do botao + folga, por slot
local EXPAND_FROM_SCALE = 0.4  -- de que tamanho o clone nasce, em cima do original

local EXPAND_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local COLLAPSE_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local EXPAND_STAGGER = 0.04    -- atraso por slot, para as opcoes sairem em cascata

local OPTION_NAME = "SpeedOption"

--[[
	A trava do degrau que pede gamepass: um veu preto por cima da opcao e o cadeado
	no meio dele. Os dois nascem dentro do proprio botao, entao acompanham posicao,
	tamanho e a animacao de abrir sem nada extra.
]]
local LOCK_NAME = "Lock"
local LOCK_COLOR = Color3.new(0, 0, 0)
local LOCK_TRANSPARENCY = 0.5
local LOCK_ICON = "rbxassetid://133112084847088"
local LOCK_ICON_SCALE = 1

-- O degrau que a opcao representa, para reencontrar a trava depois da compra.
local STEP_ATTRIBUTE = "StepIndex"

--[[
	O botao de velocidade da partida (`Interface.Speed`).

	Um clique abre as opcoes em vez de trocar a velocidade: o botao clona a si
	mesmo uma vez por degrau restante do `SpeedConfig`, cada clone com a arte do
	seu degrau, e os clones saem de tras do original no eixo X. Clicar num deles
	pede aquela velocidade e fecha; clicar no original (que e a opcao do degrau
	atual) so fecha.

	A arte do botao so muda quando o servidor confirma. E de proposito: a
	velocidade e da sala, e trocar a imagem na hora mostraria 1,5x para quem clicou
	enquanto os outros ainda estao no 1x -- e o clique de outro jogador tambem troca
	a arte deste aqui, o que so funciona se a unica fonte for o `GameSpeedChanged`.

	Alem da arte, cada confirmacao ajusta o `GameClock` local. Ele e quem faz o
	modelo do mob andar mais rapido na tela (`MobController`) no mesmo ritmo da
	distancia que o servidor esta somando -- sem isso, o servidor entregaria o mob
	na base com o boneco ainda no meio do caminho.
]]

local SpeedController = {
	Controllers = {
		MusicController = {},
		DataController = {},
	},
}

SpeedController.Index = SpeedConfig.DEFAULT_INDEX

-- A escala imposta por fora do botao, quando ha uma. Ver `applyOverride`.
SpeedController.Override = nil

-- As opcoes abertas agora (os clones), do slot 1 em diante.
SpeedController.options = {}

-- Um tween de escala por UIScale. Chaves fracas porque as opcoes sao destruidas
-- ao fechar e o UIScale delas vai junto.
SpeedController.scaleTweens = setmetatable({}, { __mode = "k" })

--[[
	As passes compradas nesta sessao, por chave.

	Ponte entre o `PromptGamePassPurchaseFinished` e o perfil: o servidor recalibra
	o `Gamepasses` na mesma compra, mas isso da a volta pela rede, e ate voltar o
	jogador ja clicou de novo -- e levaria um segundo prompt de uma pass que acabou
	de comprar. Quem manda continua sendo o perfil; isto so cobre a viagem.
]]
SpeedController.purchased = {}

--[[ INTERNAL ]]

--[=[
	A escala de um botao, num tween so por vez.

	O anterior e cancelado em vez de deixado correndo: apertar de novo antes de a
	volta terminar deixaria dois tweens escrevendo na mesma propriedade, e o botao
	pararia num tamanho que nao e nem o apertado nem o normal. Por UIScale, e nao
	um so para o controller inteiro, porque agora existem varios botoes ao mesmo
	tempo -- o original e as opcoes abertas.
]=]
function SpeedController:tweenScale(uiScale : UIScale?, scale : number, info : TweenInfo)
	if not uiScale then return end

	local previous = self.scaleTweens[uiScale]
	if previous then
		previous:Cancel()
	end

	local tween = TweenService:Create(uiScale, info, { Scale = scale })
	self.scaleTweens[uiScale] = tween
	tween:Play()

	return tween
end

--- O UIScale do botao, criado na primeira vez -- o `Interface.Speed` nao traz um.
function SpeedController:getScale(button : GuiButton) : UIScale
	local uiScale = button:FindFirstChildWhichIsA("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = button
	end

	return uiScale
end

--[=[
	Liga o pop do clique. O `UIScale` e criado se o botao nao trouxer um -- o
	`Interface.Speed` de hoje nao traz.

	`MouseButton1Down`/`Up`, e nao `Activated`: quem troca a velocidade continua
	sendo o `MouseButton1Click` logo abaixo, e a animacao nao pode consumir o
	clique dele.
]=]
function SpeedController:bindClickPop(button : GuiButton)
	local uiScale = self:getScale(button)

	button.MouseButton1Down:Connect(function()
		self:tweenScale(uiScale, PRESS_SCALE, PRESS_INFO)
	end)

	button.MouseButton1Up:Connect(function()
		self:tweenScale(uiScale, 1, RELEASE_INFO)

		local music = self.Controllers.MusicController
		if music then
			music:PlaySFX(CLICK_SOUND)
		end
	end)

	-- Soltar o clique fora do botao nao dispara o `MouseButton1Up` dele, e a escala
	-- ficaria presa no apertado.
	button.MouseLeave:Connect(function()
		self:tweenScale(uiScale, 1, RELEASE_INFO)
	end)
end

--[=[
	A escala que o relogio local deve estar: a imposta por fora do botao (a carta
	Time Acceleration), se houver; o degrau da sala, se nao.
]=]
function SpeedController:effectiveScale() : number
	return self.Override or SpeedConfig.GetScale(self.Index)
end

--- Passa a valer o degrau que o servidor mandou: relogio local e arte do botao.
function SpeedController:apply(index : number)
	if not SpeedConfig.IsValid(index) then return end

	self.Index = index
	GameClock.SetScale(self:effectiveScale())

	if self.button then
		self.button.Image = SpeedConfig.GetImage(index)
	end

	-- O degrau mudou (pode ter sido outro jogador): as opcoes abertas sao as do
	-- degrau anterior, entao fecham em vez de mentir.
	self:collapse()
end

--[=[
	A escala imposta por fora do botao. So o relogio muda: a arte continua sendo a
	do degrau que a sala escolheu, porque o 3x da carta nao e um degrau e nao tem
	imagem -- e o botao continua servindo para voltar ao 1x depois.
]=]
function SpeedController:applyOverride(scale : number?)
	self.Override = if typeof(scale) == "number" then scale else nil

	GameClock.SetScale(self:effectiveScale())
end

--[[ GAMEPASS ]]

--- O perfil replicado, ou nil enquanto ele nao chegou.
function SpeedController:profile()
	local replica = self.replica

	return replica and replica.Data or nil
end

--[=[
	Segura a replica para as consultas do clique.

	Guardada de uma vez, e nao pedida na hora: o `GetReplica` cede ate o perfil
	chegar, e ceder dentro do clique atrasaria a abertura do menu. Sem replica
	ainda, `isUnlocked` responde "trancado", que e o lado seguro.
]=]
function SpeedController:watchProfile()
	task.spawn(function()
		local dataController = self.Controllers.DataController
		if not dataController then return end

		self.replica = dataController:GetReplica()
	end)
end

--[=[
	Se o degrau esta liberado para este jogador.

	Degrau sem `Gamepass` no config e de todo mundo. Com pass, vale o que o perfil
	declara -- e perfil que ainda nao chegou conta como "nao tem", igual ao resto
	do jogo (`GamepassConfig.ownedOf`): aparece a trava, e o clique vira o prompt.
]=]
function SpeedController:isUnlocked(stepIndex : number?) : boolean
	local key = SpeedConfig.GetGamepass(stepIndex)
	if not key then return true end

	if self.purchased[key] then return true end

	return GamepassConfig.owns(self:profile(), key)
end

--[=[
	O veu e o cadeado por cima da opcao trancada.

	O veu e um `Frame` comum, e nao um botao: `Frame` nao afunda input, entao o
	clique atravessa e chega no `MouseButton1Click` da opcao embaixo -- que e quem
	decide entre escolher a velocidade e abrir o prompt.
]=]
function SpeedController:createLock(option : GuiButton)
	local veil = Instance.new("Frame")
	veil.Name = LOCK_NAME
	veil.AnchorPoint = Vector2.new(0.5, 0.5)
	veil.Position = UDim2.fromScale(0.5, 0.5)
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = LOCK_COLOR
	veil.BackgroundTransparency = LOCK_TRANSPARENCY
	veil.BorderSizePixel = 0
	veil.ZIndex = option.ZIndex + 1

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(LOCK_ICON_SCALE, LOCK_ICON_SCALE)
	icon.BackgroundTransparency = 1
	icon.Image = LOCK_ICON
	icon.ZIndex = veil.ZIndex + 1
	icon.Parent = veil

	veil.Parent = option

	return veil
end

--[=[
	O clique numa opcao. Trancada, abre o prompt da pass e o menu fica aberto: quem
	comprar ve a trava cair e escolhe no clique seguinte, sem ter de abrir tudo de
	novo. Liberada, escolhe a velocidade e fecha.
]=]
function SpeedController:choose(stepIndex : number)
	if self:isUnlocked(stepIndex) then
		self:select(stepIndex)
		return
	end

	local key = SpeedConfig.GetGamepass(stepIndex)
	local pass = key and GamepassConfig.PASSES[key]

	if not pass then return end

	MarketplaceService:PromptGamePassPurchase(Player, pass.Id)
end

--[=[
	Comprou agora: a trava daquele degrau cai na hora, sem esperar o perfil dar a
	volta pelo servidor (quem recalibra e o `MonetizationService`, no mesmo evento
	do lado de la).
]=]
function SpeedController:bindPurchaseFinished()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player : Player, gamePassId : number, purchased : boolean)
		if player ~= Player or not purchased then return end

		local key = GamepassConfig.keyOfId(gamePassId)
		if not key then return end

		self.purchased[key] = true

		for _, option in self.options do
			if SpeedConfig.GetGamepass(option:GetAttribute(STEP_ATTRIBUTE)) ~= key then continue end

			local lock = option:FindFirstChild(LOCK_NAME)
			if lock then
				lock:Destroy()
			end
		end
	end)
end

--[[ EXPANSAO ]]

--[=[
	O deslocamento de um slot, em scale do eixo X.

	Medido pelo `AbsoluteSize` do botao e nao pelo `Size` autorado: o
	UIAspectRatioConstraint pode ter dado ao botao uma largura diferente da que
	esta escrita ali, e as opcoes precisam acompanhar a largura de verdade. Antes
	do primeiro render o `AbsoluteSize` e zero, e ai o autorado e a melhor
	estimativa que existe.
]=]
function SpeedController:slotOffset() : number
	local button = self.button
	local parent = button and button.Parent

	if not button or not parent then return 0 end

	local width = button.AbsoluteSize.X
	local available = (parent :: any).AbsoluteSize.X

	local ratio = if width > 0 and available > 0
		then width / available
		else button.Size.X.Scale

	return ratio * EXPAND_SPACING * EXPAND_DIRECTION
end

--[=[
	Uma opcao: o clone do proprio botao com a arte do degrau, nascendo em cima do
	original e indo para o seu slot.

	Clonar o botao (e nao montar um do zero) e o que mantem as opcoes iguais ao
	original de graca -- tamanho, aspecto, ZIndex, o que a arte vier a ganhar
	depois. O que precisa ser desfeito no clone e so o estado de animacao que
	veio junto: o UIScale pode ter sido copiado no meio do "pop" do clique que
	acabou de abrir o menu.
]=]
function SpeedController:createOption(stepIndex : number, slot : number)
	local button = self.button
	local parent = button and button.Parent
	if not button or not parent then return nil end

	local option = button:Clone()
	option.Name = OPTION_NAME
	option.Image = SpeedConfig.GetImage(stepIndex)
	option.Visible = true
	option.Position = button.Position
	option:SetAttribute(STEP_ATTRIBUTE, stepIndex)

	local uiScale = self:getScale(option)
	uiScale.Scale = EXPAND_FROM_SCALE

	option.Parent = parent

	if not self:isUnlocked(stepIndex) then
		self:createLock(option)
	end

	self:bindClickPop(option)

	option.MouseButton1Click:Connect(function()
		self:choose(stepIndex)
	end)

	-- O atraso vive no proprio TweenInfo: cascata sem thread nenhuma pendurada,
	-- que teria de ser cancelada se o menu fechasse no meio da abertura.
	local delay = EXPAND_STAGGER * (slot - 1)
	local moveInfo = TweenInfo.new(
		EXPAND_INFO.Time,
		EXPAND_INFO.EasingStyle,
		EXPAND_INFO.EasingDirection,
		0,
		false,
		delay
	)

	local target = button.Position + UDim2.fromScale(self:slotOffset() * slot, 0)

	TweenService:Create(option, moveInfo, { Position = target }):Play()
	self:tweenScale(uiScale, 1, moveInfo)

	return option
end

--[=[
	Abre as opcoes: um clone por degrau que nao e o atual, na ordem do
	`SpeedConfig`. O original fica onde esta e continua sendo a opcao do degrau em
	uso.
]=]
function SpeedController:expand()
	if self.expanded or not self.button then return end

	self.expanded = true

	local slot = 0
	for stepIndex, _ in SpeedConfig.Steps do
		if stepIndex == self.Index then continue end

		slot += 1

		local option = self:createOption(stepIndex, slot)
		if option then
			table.insert(self.options, option)
		end
	end
end

--- Fecha as opcoes: elas voltam para tras do original e somem.
function SpeedController:collapse()
	if not self.expanded then return end

	self.expanded = false

	local origin = self.button and self.button.Position or UDim2.new()

	for _, option in self.options do
		-- Fora do caminho na hora: o clique que fechou nao pode pegar de novo numa
		-- opcao que ainda esta encolhendo.
		option.Interactable = false

		local tween = TweenService:Create(option, COLLAPSE_INFO, { Position = origin })
		tween.Completed:Connect(function()
			option:Destroy()
		end)
		tween:Play()

		self:tweenScale(self:getScale(option), EXPAND_FROM_SCALE, COLLAPSE_INFO)
	end

	table.clear(self.options)
end

--- A opcao escolhida: fecha o menu e pede a velocidade, se ela mudou.
function SpeedController:select(stepIndex : number)
	self:collapse()

	if stepIndex == self.Index then return end

	Framework:Fire("SetGameSpeed", stepIndex)
end

--[=[
	Fecha o menu quando o jogador clica no mundo -- posicionar uma unidade, girar a
	camera -- em vez de deixar as opcoes abertas atras do jogo.

	`processed` verdadeiro quer dizer que o clique caiu em alguma GUI; ai o menu
	fica, porque um desses cliques pode ser justamente o de uma das opcoes, que se
	resolve sozinha no `MouseButton1Click` dela.
]=]
function SpeedController:bindOutsideClick()
	UserInputService.InputBegan:Connect(function(input : InputObject, processed : boolean)
		if not self.expanded or processed then return end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		self:collapse()
	end)
end

--[[ CICLO DE VIDA ]]

function SpeedController:construct()
	Framework:Listen("GameSpeedChanged", function(index : number)
		self:apply(index)
	end)

	Framework:Listen("GameSpeedOverride", function(scale : number?)
		self:applyOverride(scale)
	end)

	local Interface = PlayerGui:WaitForChild("Interface", 60)
	if not Interface then return end

	self.button = Interface:WaitForChild("Speed", 60)
	if not self.button then return end

	-- A arte autorada e a do 1x, mas o botao pode nascer no meio de uma partida
	-- ja acelerada: desenha o que este cliente sabe e pergunta o resto.
	self.button.Image = SpeedConfig.GetImage(self.Index)

	self:bindClickPop(self.button)

	-- Fechado, o clique abre as opcoes; aberto, o original e a opcao do degrau
	-- atual, e clicar nele so fecha.
	self.button.MouseButton1Click:Connect(function()
		if self.expanded then
			self:select(self.Index)
		else
			self:expand()
		end
	end)

	self:bindOutsideClick()
	self:bindPurchaseFinished()

	Framework:Fire("RequestGameSpeed")
end

function SpeedController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	-- Depois do Get: o construct roda no init, quando os controllers ainda nao
	-- foram resolvidos.
	self:watchProfile()
end

function SpeedController:init()
	self:construct()
end

return SpeedController
