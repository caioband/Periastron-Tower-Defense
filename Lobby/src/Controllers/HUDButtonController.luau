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
local HUD_FRAME_NAME = "HUDFrame"

local WAIT_TIMEOUT = 10

-- O hover joga o botão para `X.Scale = 0.3` — com AnchorPoint 0.5 dentro do wrapper,
-- é um quinto da largura para fora da coluna do HUD. O Y e os offsets ficam como
-- estão.
local HOVER_X_SCALE = 0.3

local SLIDE_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local PRESS_SCALE = 0.9

local HOVER_SOUND = "UIHover"
local CLICK_SOUND = "UIClick"

--[=[
	O feedback dos botões do `StarterGui.HUD.HUDFrame` (Loja, Backpack e Deck): o
	botão desliza para fora da coluna quando o mouse entra, volta quando sai, e
	encolhe enquanto está apertado.

	Só a parte visual e o som moram aqui. Quem abre a loja, a mochila e o deck
	continua sendo o controller de cada painel, pelo `Activated` do mesmo botão —
	por isso a animação de clique é `MouseButton1Down`/`Up`, que não consome o
	clique de ninguém.

	Pega qualquer `GuiButton` dentro do `HUDFrame`, em qualquer profundidade: cada
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

function HUDButtonController:_bindButton(button : GuiButton)
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
	local hovered = UDim2.new(HOVER_X_SCALE, home.X.Offset, home.Y.Scale, home.Y.Offset)

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
	Liga a uma cópia do HUD. O `DescendantAdded` fica ligado porque a GUI chega em
	pedaços: varrer uma vez só pegaria os botões que já tivessem replicado.
]=]
function HUDButtonController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)

	if not hudFrame then
		warn(`[HUDButtonController]: não achei {HUD_UI_NAME}.{HUD_FRAME_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.Bound = {}

	self.HudMaid:GiveTask(hudFrame.DescendantAdded:Connect(function(descendant : Instance)
		if descendant:IsA("GuiButton") then
			self:_bindButton(descendant)
		end
	end))

	for _, descendant in hudFrame:GetDescendants() do
		if descendant:IsA("GuiButton") then
			self:_bindButton(descendant)
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

	self.Maid:GiveTask(self.HudMaid)
end

return HUDButtonController
