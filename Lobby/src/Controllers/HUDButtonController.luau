local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"

local WAIT_TIMEOUT = 10

--[=[
	As duas colunas do HUD e para onde o hover empurra o botão de cada uma. Com
	AnchorPoint 0.5 dentro do wrapper (e `X.Scale = 0.5` em repouso), 0.3 é um quinto
	da largura para o lado; o Y e os offsets ficam como estão.

	As duas colunas têm a mesma estrutura, e o que muda é só a direção: a da direita
	desliza para a esquerda (0.3) e a da esquerda faz o espelho (0.7) — o botão sempre
	sai **para dentro** da tela, e não pela borda.
]=]
local HUD_FRAMES = {
	{ Name = "HUDFrame", HoverX = 0.3 },
	{ Name = "HUDLeft", HoverX = 0.7 },
}

local SLIDE_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local PRESS_SCALE = 0.9

local HOVER_SOUND = "UIHover"
local CLICK_SOUND = "UIClick"

--[=[
	O feedback dos botões das colunas do `StarterGui.HUD` (`HUDFrame` à direita e
	`HUDLeft` à esquerda): o botão desliza para fora da coluna quando o mouse entra,
	volta quando sai, e encolhe enquanto está apertado.

	Só a parte visual e o som moram aqui. Quem abre a loja, a mochila e o deck
	continua sendo o controller de cada painel, pelo `Activated` do mesmo botão —
	por isso a animação de clique é `MouseButton1Down`/`Up`, que não consome o
	clique de ninguém.

	Pega qualquer `GuiButton` dentro de cada coluna, em qualquer profundidade: cada
	botão hoje está dentro de um `Wrapper`, e um botão novo entra na animação só de
	nascer ali. O HUD tem `ResetOnSpawn` ligado, então o bind roda de novo a cada
	cópia nova que a engine coloca na PlayerGui.
]=]
local HUDButtonController = {
	Controllers = {
		MusicController = {},
	},
}

--[[ INTERNAL ]]

function HUDButtonController:_playSound(name : string)
	local music = self.Controllers.MusicController

	if music then
		music:PlaySFX(name)
	end
end

--[=[
	Toca um tween e deixa o cancelamento com o maid do próprio botão: o hover e o
	clique mexem em coisas diferentes (posição e escala), mas os dois morrem juntos
	quando o HUD é trocado.
]=]
function HUDButtonController:_tween(maid, object : Instance, info : TweenInfo, goal : { [string]: any })
	local tween = TweenService:Create(object, info, goal)

	maid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
end

function HUDButtonController:_bindButton(button : GuiButton, hoverX : number)
	if self.Bound[button] then
		return
	end

	local scale = button:FindFirstChildWhichIsA("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = button
	end

	-- A posição autorada é lida uma vez, antes de qualquer tween: é para ela que o
	-- MouseLeave volta.
	local home = button.Position
	local hovered = UDim2.new(hoverX, home.X.Offset, home.Y.Scale, home.Y.Offset)

	local maid = Maid.new()
	self.Bound[button] = maid
	self.HudMaid:GiveTask(maid)

	local slideMaid = Maid.new()
	local scaleMaid = Maid.new()

	maid:GiveTask(slideMaid)
	maid:GiveTask(scaleMaid)

	maid:GiveTask(button.MouseEnter:Connect(function()
		slideMaid:DoCleaning()
		self:_tween(slideMaid, button, SLIDE_INFO, { Position = hovered })

		self:_playSound(HOVER_SOUND)
	end))

	maid:GiveTask(button.MouseLeave:Connect(function()
		slideMaid:DoCleaning()
		self:_tween(slideMaid, button, SLIDE_INFO, { Position = home })

		-- Soltar o clique fora do botão não dispara o `MouseButton1Up` dele, e a
		-- escala ficaria presa no apertado.
		scaleMaid:DoCleaning()
		self:_tween(scaleMaid, scale, RELEASE_INFO, { Scale = 1 })
	end))

	maid:GiveTask(button.MouseButton1Down:Connect(function()
		scaleMaid:DoCleaning()
		self:_tween(scaleMaid, scale, PRESS_INFO, { Scale = PRESS_SCALE })
	end))

	maid:GiveTask(button.MouseButton1Up:Connect(function()
		scaleMaid:DoCleaning()
		self:_tween(scaleMaid, scale, RELEASE_INFO, { Scale = 1 })

		self:_playSound(CLICK_SOUND)
	end))

	maid:GiveTask(function()
		self.Bound[button] = nil
	end)
end

--[=[
	Liga uma coluna. O `DescendantAdded` fica ligado porque a GUI chega em pedaços:
	varrer uma vez só pegaria os botões que já tivessem replicado.
]=]
function HUDButtonController:_bindFrame(hudFrame : Instance, hoverX : number)
	self.HudMaid:GiveTask(hudFrame.DescendantAdded:Connect(function(descendant : Instance)
		if descendant:IsA("GuiButton") then
			self:_bindButton(descendant, hoverX)
		end
	end))

	for _, descendant in hudFrame:GetDescendants() do
		if descendant:IsA("GuiButton") then
			self:_bindButton(descendant, hoverX)
		end
	end
end

--[=[
	Liga a uma cópia do HUD: as duas colunas, cada uma com a direção dela. Uma coluna
	que não existe nessa cópia só fica de fora — as outras continuam animando.
]=]
function HUDButtonController:_bindHud(screenGui : ScreenGui)
	self.HudMaid:DoCleaning()
	self.Bound = {}

	for _, column in HUD_FRAMES do
		local hudFrame = screenGui:WaitForChild(column.Name, WAIT_TIMEOUT)

		if hudFrame then
			self:_bindFrame(hudFrame, column.HoverX)
		elseif not self.Warned[column.Name] then
			self.Warned[column.Name] = true
			warn(`[HUDButtonController]: não achei {HUD_UI_NAME}.{column.Name}.`)
		end
	end
end

function HUDButtonController:_observeUI()
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

function HUDButtonController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()
end

function HUDButtonController:init()
	self.Maid = Maid.new()
	self.HudMaid = Maid.new()
	self.Bound = {}

	-- O aviso de coluna que falta é por nome, e não por cópia do HUD: o HUD nasce de
	-- novo a cada respawn, e o output encheria.
	self.Warned = {}

	self.Maid:GiveTask(self.HudMaid)
end

return HUDButtonController
