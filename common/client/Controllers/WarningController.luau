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

local WarningConfig = SharedConfig.WarningConfig
local Config = WarningConfig.Label

--[[
	O aviso grande no meio da tela: `Interface.WeatherWarning`.

	Este controller é o **único** que encosta no label. Quem tem algo a avisar manda
	a frase pronta:

		local Warning = Framework:Get("WarningController")

		Warning:Show("WARNING! FOG COMING IN 3 ROUNDS", {
			Priority = WarningConfig.Priority.Weather,
		})

	O texto desce do alto até a posição autorada enquanto a transparência do texto e
	do UIStroke cai de 1 para 0 — a impressão é a de a frase estar se formando no
	lugar. Passados `Hold` segundos ela sobe de volta e some.

	Toda a animação é montada a partir da posição que o designer deixou no
	StarterGui: ela é o destino, e o começo é ela menos `SlideOffset`. Assim mover o
	label no Studio não exige tocar em nada aqui.

	**Prioridade.** Um aviso novo derrota o que estiver na tela quando a prioridade
	dele empata ou ganha — o segundo aviso do mesmo dono é sempre mais atual que o
	primeiro. Aviso de prioridade menor é recusado (o `Show` devolve `false`) em vez
	de entrar na fila: quando o restart do servidor está na tela, o clima da wave 8
	não é notícia.

	Fica em `common/` porque as duas places avisam.
]]

local WarningController = {
	Controllers = {}
}

WarningController.Label = nil :: TextLabel?
WarningController.BasePosition = nil :: UDim2?
WarningController.Token = 0

-- Prioridade do aviso no ar. Zero é tela livre.
WarningController.Priority = 0

WarningController.Warned = false

--[[ INTERNAL ]]

--[=[
	O TextLabel do aviso, na primeira vez em que ele for preciso.

	Resolvido tarde e guardado depois: a Interface pode ainda não ter replicado
	quando o controller carrega, e um `WaitForChild` no `init` seguraria o boot do
	cliente por causa de um label que só aparece lá pela wave 4.
]=]
function WarningController:getLabel() : TextLabel?
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
function WarningController:tweenTo(label : TextLabel, position : UDim2, transparency : number, time : number)
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
	Barulho quando o label não aparece.

	Place sem `Interface` nenhuma (o Lobby, hoje) não tem aviso na tela por desenho
	— não é engano, e um `warn` ali só ensinaria a ignorar warns. `Interface`
	existindo **sem** o label é engano, e esse merece barulho: uma vez, para um
	aviso que volta (o do restart) não virar spam.
]=]
function WarningController:warnMissing()
	if self.Warned then return end
	if not PlayerGui:FindFirstChild("Interface") then return end

	self.Warned = true
	warn(`[WarningController]: nao achei o TextLabel "{Config.Name}" em PlayerGui.Interface.`)
end

--[[ API ]]

export type ShowOptions = {
	Priority : number?,
	Hold : number?,
}

--[=[
	Coloca uma frase na tela.

	Devolve `false` quando o aviso foi recusado — label que ainda não existe nesta
	place, ou prioridade menor que a do aviso que está no ar.
]=]
function WarningController:Show(text : string, options : ShowOptions?) : boolean
	local priority = (options and options.Priority) or 0
	if priority < self.Priority then
		return false
	end

	local label = self:getLabel()
	if not label then
		self:warnMissing()
		return false
	end

	label.Text = text

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
	self.Priority = priority

	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	label.Position = hiddenPosition
	label.TextTransparency = 1
	if stroke then
		stroke.Transparency = 1
	end
	label.Visible = true

	self:tweenTo(label, basePosition, 0, Config.FadeIn)

	local hold = (options and options.Hold) or Config.Hold

	task.delay(Config.FadeIn + hold, function()
		if self.Token ~= token then return end
		if not label.Parent then return end

		self:tweenTo(label, hiddenPosition, 1, Config.FadeOut)

		task.delay(Config.FadeOut, function()
			if self.Token ~= token then return end
			if not label.Parent then return end

			label.Visible = false
			label.Position = basePosition
			self.Priority = 0
		end)
	end)

	return true
end

--[=[
	Esconde o aviso na hora, sem animação. É o que o recomeço de round precisa: o
	aviso do round anterior não pode continuar na tela.

	`maxPriority` é o "limpe só o que for meu": passando a própria prioridade, quem
	chama não apaga um aviso mais importante que o dele. Sem argumento, limpa o que
	estiver lá.
]=]
function WarningController:Hide(maxPriority : number?)
	if maxPriority and self.Priority > maxPriority then return end

	self.Token += 1
	self.Priority = 0

	local label = self.Label
	if not label or not label.Parent then return end

	label.Visible = false
	if self.BasePosition then
		label.Position = self.BasePosition
	end
end

--[[ CICLO DE VIDA ]]

function WarningController:start()
end

function WarningController:init()
end

return WarningController
