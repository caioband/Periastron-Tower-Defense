local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local WeatherConfig = SharedConfig.WeatherConfig
local Config = WeatherConfig.Warning

--[[
	O aviso de clima na tela: `Interface.WeatherWarning`.

	O servidor manda `WeatherWarning` com o nome do clima e quantas waves faltam; o
	texto desce do alto até a posição autorada enquanto a transparência do texto e
	do UIStroke cai de 1 para 0 — a impressão é a de a frase estar se formando no
	lugar. Passados `Hold` segundos ela sobe de volta e some.

	Toda a animação é montada a partir da posição que o designer deixou no
	StarterGui: ela é o destino, e o começo é ela menos `SlideOffset`. Assim mover o
	label no Studio não exige tocar em nada aqui.

	Um aviso novo derruba o que estiver na tela em vez de esperar a vez — o segundo
	aviso é sempre mais atual que o primeiro. Na prática isso quase não acontece: o
	servidor não agenda um clima enquanto houver outro agendado ou no ar.
]]

local WeatherWarningController = {
	Controllers = {}
}

WeatherWarningController.Label = nil :: TextLabel?
WeatherWarningController.BasePosition = nil :: UDim2?
WeatherWarningController.Token = 0

--[=[
	O TextLabel do aviso, na primeira vez em que ele for preciso.

	Resolvido tarde e guardado depois: a Interface pode ainda não ter replicado
	quando o controller carrega, e um `WaitForChild` no `init` seguraria o boot do
	cliente por causa de um label que só aparece lá pela wave 4.
]=]
function WeatherWarningController:getLabel() : TextLabel?
	local label = self.Label
	if label and label.Parent then
		return label
	end

	local interface = PlayerGui:FindFirstChild("Interface")
	local found = interface and interface:FindFirstChild(Config.Name)
	if not found or not found:IsA("TextLabel") then
		return nil
	end

	self.Label = found
	self.BasePosition = found.Position

	return found
end

--[=[
	Transparência do texto e do stroke de uma vez.

	O stroke entra junto de propósito: só o texto aparecendo deixaria o contorno
	sólido por trás de uma letra invisível, que é exatamente o efeito contrário do
	pretendido.
]=]
function WeatherWarningController:tweenTo(label : TextLabel, position : UDim2, transparency : number, time : number)
	local info = TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	TweenService:Create(label, info, {
		Position = position,
		TextTransparency = transparency,
	}):Play()

	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		TweenService:Create(stroke, info, { Transparency = transparency }):Play()
	end
end

--[=[
	Mostra o aviso de um clima.

	`wavesAhead` vem do servidor porque é ele que vai cumprir o prazo; o cliente só
	escolhe entre a frase no plural e a de uma wave só.
]=]
function WeatherWarningController:Show(weatherName : string, wavesAhead : number)
	local label = self:getLabel()
	if not label then
		warn(`[WeatherWarningController]: nao achei o TextLabel "{Config.Name}" em PlayerGui.Interface.`)
		return
	end

	local displayName = WeatherConfig.GetDisplayName(weatherName)
	label.Text = if wavesAhead <= 1
		then string.format(Config.TextOne, displayName)
		else string.format(Config.Text, displayName, wavesAhead)

	local basePosition = self.BasePosition or label.Position
	local hiddenPosition = UDim2.new(
		basePosition.X.Scale,
		basePosition.X.Offset,
		basePosition.Y.Scale - Config.SlideOffset,
		basePosition.Y.Offset
	)

	-- Um token por aviso: o `task.delay` da saida so vale se ninguem tiver pedido
	-- outro aviso no meio, senao ele apagaria o texto que acabou de entrar.
	self.Token += 1
	local token = self.Token

	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	label.Position = hiddenPosition
	label.TextTransparency = 1
	if stroke then
		stroke.Transparency = 1
	end
	label.Visible = true

	self:tweenTo(label, basePosition, 0, Config.FadeIn)

	task.delay(Config.FadeIn + Config.Hold, function()
		if self.Token ~= token then return end
		if not label.Parent then return end

		self:tweenTo(label, hiddenPosition, 1, Config.FadeOut)

		task.delay(Config.FadeOut, function()
			if self.Token ~= token then return end
			if not label.Parent then return end

			label.Visible = false
			label.Position = basePosition
		end)
	end)
end

--[=[
	Esconde o aviso na hora, sem animação. É o que o recomeço de round precisa: o
	aviso do round anterior não pode continuar na tela.
]=]
function WeatherWarningController:Hide()
	self.Token += 1

	local label = self.Label
	if not label or not label.Parent then return end

	label.Visible = false
	if self.BasePosition then
		label.Position = self.BasePosition
	end
end

function WeatherWarningController:construct()
	Framework:Listen("WeatherWarning", function(weatherName : string, wavesAhead : number)
		if typeof(weatherName) ~= "string" then return end
		self:Show(weatherName, tonumber(wavesAhead) or WeatherConfig.Round.LeadWaves)
	end)

	Framework:Listen("RoundRestarted", function()
		self:Hide()
	end)

	-- Quem entra no meio da partida com um clima ja avisado precisa ver o aviso.
	Framework:Fire("RequestWeatherWarning")
end

function WeatherWarningController:start()
end

function WeatherWarningController:init()
	self:construct()
end

return WeatherWarningController
