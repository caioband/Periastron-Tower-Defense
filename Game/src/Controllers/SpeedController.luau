local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Me = require(Vendor.Me)
local Framework = Me.new()

local SpeedConfig = SharedConfig.SpeedConfig

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
	O botao de velocidade da partida (`Interface.Speed`).

	Um clique pede o proximo degrau do `SpeedConfig`; a arte do botao so muda
	quando o servidor confirma. E de proposito: a velocidade e da sala, e trocar a
	imagem na hora mostraria 2x para quem clicou enquanto os outros ainda estao no
	1x -- e o clique de outro jogador tambem troca a arte deste aqui, o que so
	funciona se a unica fonte for o `GameSpeedChanged`.

	Alem da arte, cada confirmacao ajusta o `GameClock` local. Ele e quem faz o
	modelo do mob andar mais rapido na tela (`MobController`) no mesmo ritmo da
	distancia que o servidor esta somando -- sem isso, o servidor entregaria o mob
	na base com o boneco ainda no meio do caminho.
]]

local SpeedController = {
	Controllers = {
		MusicController = {},
	},
}

SpeedController.Index = SpeedConfig.DEFAULT_INDEX

--[[ INTERNAL ]]

--[=[
	A escala do botao, num tween so por vez.

	O anterior e cancelado em vez de deixado correndo: apertar de novo antes de a
	volta terminar deixaria dois tweens escrevendo na mesma propriedade, e o botao
	pararia num tamanho que nao e nem o apertado nem o normal.
]=]
function SpeedController:tweenScale(scale : number, info : TweenInfo)
	local uiScale = self.scale
	if not uiScale then return end

	if self.scaleTween then
		self.scaleTween:Cancel()
	end

	self.scaleTween = TweenService:Create(uiScale, info, { Scale = scale })
	self.scaleTween:Play()
end

--[=[
	Liga o pop do clique. O `UIScale` e criado se o botao nao trouxer um -- o
	`Interface.Speed` de hoje nao traz.

	`MouseButton1Down`/`Up`, e nao `Activated`: quem troca a velocidade continua
	sendo o `MouseButton1Click` logo abaixo, e a animacao nao pode consumir o
	clique dele.
]=]
function SpeedController:bindClickPop(button : GuiButton)
	local uiScale = button:FindFirstChildWhichIsA("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = button
	end

	self.scale = uiScale

	button.MouseButton1Down:Connect(function()
		self:tweenScale(PRESS_SCALE, PRESS_INFO)
	end)

	button.MouseButton1Up:Connect(function()
		self:tweenScale(1, RELEASE_INFO)

		local music = self.Controllers.MusicController
		if music then
			music:PlaySFX(CLICK_SOUND)
		end
	end)

	-- Soltar o clique fora do botao nao dispara o `MouseButton1Up` dele, e a escala
	-- ficaria presa no apertado.
	button.MouseLeave:Connect(function()
		self:tweenScale(1, RELEASE_INFO)
	end)
end

--- Passa a valer o degrau que o servidor mandou: relogio local e arte do botao.
function SpeedController:apply(index : number)
	if not SpeedConfig.IsValid(index) then return end

	self.Index = index
	GameClock.SetScale(SpeedConfig.GetScale(index))

	if self.button then
		self.button.Image = SpeedConfig.GetImage(index)
	end
end

--[[ CICLO DE VIDA ]]

function SpeedController:construct()
	Framework:Listen("GameSpeedChanged", function(index : number)
		self:apply(index)
	end)

	local Interface = PlayerGui:WaitForChild("Interface", 60)
	if not Interface then return end

	self.button = Interface:WaitForChild("Speed", 60)
	if not self.button then return end

	-- A arte autorada e a do 1x, mas o botao pode nascer no meio de uma partida
	-- ja acelerada: desenha o que este cliente sabe e pergunta o resto.
	self.button.Image = SpeedConfig.GetImage(self.Index)

	self:bindClickPop(self.button)

	self.button.MouseButton1Click:Connect(function()
		Framework:Fire("SetGameSpeed", SpeedConfig.Next(self.Index))
	end)

	Framework:Fire("RequestGameSpeed")
end

function SpeedController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end
end

function SpeedController:init()
	self:construct()
end

return SpeedController
