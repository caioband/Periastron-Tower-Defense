local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local SkipConfig = SharedConfig.SkipConfig

local INTERFACE_NAME = "Interface"
local WAIT_TIMEOUT = 60

local TWEEN_STYLE = Enum.EasingStyle.Quad
local TWEEN_DIRECTION = Enum.EasingDirection.Out

--[=[
	O prompt de pular a wave: `Interface.SkipPrompt`.

	Quem decide quando ele aparece e o `SkipService`; daqui sai so a tela. O
	servidor manda `SkipState` a cada mudanca (votos, quantos faltam, se este
	jogador ja votou) e o prompt entra ou sai conforme o `active`.

	**A animacao e a do `WeatherWarning`**: o prompt desce de `SlideOffset` acima do
	lugar autorado enquanto a transparencia sobe de 1 ate o valor autorado. Sobe ate
	o valor autorado, e nao ate zero, porque o prompt tem fundo transparente, sombra
	a 20% e imagem opaca no mesmo galho — animar todo mundo para zero pintaria uma
	caixa solida por tras da arte. Os valores sao lidos uma vez, no bind, antes de
	qualquer animacao, entao repintar no Studio basta.

	**Cancel esconde, mas nao vota contra.** O clique tira o voto de quem tinha
	votado e some com o prompt so para ele, ate a proxima votacao — cada abertura
	vem com um `token` novo do servidor, e um token que este cliente ainda nao
	dispensou volta a aparecer normalmente.
]=]
local SkipPromptController = {}

--[[ INTERNAL ]]

--[=[
	Todo par (instancia, propriedade de transparencia) do prompt, com o valor que o
	designer deixou. E a lista que a animacao percorre nas duas direcoes.

	`GuiObject.Transparency` fica de fora de proposito: e um apelido de
	`BackgroundTransparency`, e animar os dois deixaria dois tweens brigando pela
	mesma propriedade.
]=]
function SkipPromptController:_collectFades(root : Instance)
	local fades = {}

	local function add(instance : Instance, property : string)
		table.insert(fades, {
			Instance = instance,
			Property = property,
			Target = (instance :: any)[property],
		})
	end

	local function collect(instance : Instance)
		if instance:IsA("GuiObject") then
			add(instance, "BackgroundTransparency")

			if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
				add(instance, "TextTransparency")
				add(instance, "TextStrokeTransparency")
			end

			if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
				add(instance, "ImageTransparency")
			end
		elseif instance:IsA("UIStroke") or instance:IsA("UIShadow") then
			add(instance, "Transparency")
		end
	end

	collect(root)
	for _, descendant in root:GetDescendants() do
		collect(descendant)
	end

	return fades
end

--[=[
	A transparencia de tudo de uma vez. `progress` e 0 para escondido e 1 para o
	prompt como o designer o pintou.

	Sem tween quando `time` e nil: e assim que o estado inicial e armado, antes da
	animacao de entrada.
]=]
function SkipPromptController:_applyFade(progress : number, time : number?)
	local info = time and TweenInfo.new(time, TWEEN_STYLE, TWEEN_DIRECTION)

	for _, fade in self.Fades do
		local instance = fade.Instance :: any
		if not instance.Parent then continue end

		local value = 1 + (fade.Target - 1) * progress
		local tweened = false

		-- Propriedade que o TweenService recusa (uma classe nova de UI que ainda
		-- nao anima) salta direto para o valor em vez de derrubar a animacao dos
		-- outros. Marcado na lista para nao tentar de novo a cada quadro de tela.
		if info and not fade.NoTween then
			tweened = pcall(function()
				TweenService:Create(instance, info, { [fade.Property] = value }):Play()
			end)

			fade.NoTween = not tweened
		end

		if not tweened then
			instance[fade.Property] = value
		end
	end
end

function SkipPromptController:_hiddenPosition() : UDim2
	local base = self.BasePosition

	return UDim2.new(
		base.X.Scale,
		base.X.Offset,
		base.Y.Scale - SkipConfig.SlideOffset,
		base.Y.Offset
	)
end

function SkipPromptController:_show()
	local prompt = self.Prompt
	if not prompt or self.Shown then return end

	self.Shown = true
	self.AnimToken += 1

	-- Os filhos vem desligados do Studio (o prompt inteiro nasce escondido); a
	-- transparencia e que faz a entrada, entao aqui eles so precisam existir na
	-- tela.
	for _, descendant in prompt:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.Visible = true
		end
	end

	prompt.Position = self:_hiddenPosition()
	self:_applyFade(0)
	prompt.Visible = true

	TweenService:Create(prompt, TweenInfo.new(SkipConfig.FadeIn, TWEEN_STYLE, TWEEN_DIRECTION), {
		Position = self.BasePosition,
	}):Play()

	self:_applyFade(1, SkipConfig.FadeIn)
end

function SkipPromptController:_hide()
	local prompt = self.Prompt
	if not prompt or not self.Shown then return end

	self.Shown = false
	self.AnimToken += 1
	local token = self.AnimToken

	TweenService:Create(prompt, TweenInfo.new(SkipConfig.FadeOut, TWEEN_STYLE, TWEEN_DIRECTION), {
		Position = self:_hiddenPosition(),
	}):Play()

	self:_applyFade(0, SkipConfig.FadeOut)

	task.delay(SkipConfig.FadeOut, function()
		-- Um `_show` no meio da saida manda: o prompt que esta na tela agora e o
		-- dele, e desligar aqui apagaria uma votacao nova.
		if self.AnimToken ~= token then return end
		if not prompt.Parent then return end

		prompt.Visible = false
		prompt.Position = self.BasePosition
	end)
end

function SkipPromptController:_updateCount()
	local state = self.State
	local label = self.CountLabel
	if not state or not label then return end

	label.Text = string.format(SkipConfig.CountText, state.votes or 0, state.required or 0)
end

--[=[
	O ultimo estado que veio do servidor, na tela.

	O prompt so aparece se o jogador nao tiver dispensado **esta** votacao: o
	`token` muda a cada abertura, entao o Cancel vale para a votacao em que foi
	clicado e nao para as proximas.
]=]
function SkipPromptController:_apply()
	local state = self.State
	if not state or not self.Prompt then return end

	self:_updateCount()

	if state.active and self.DismissedToken ~= state.token then
		self:_show()
	else
		self:_hide()
	end
end

function SkipPromptController:_bind() : boolean
	local interface = PlayerGui:WaitForChild(INTERFACE_NAME, WAIT_TIMEOUT)
	local prompt = interface and interface:WaitForChild(SkipConfig.Name, WAIT_TIMEOUT)

	if not prompt or not prompt:IsA("GuiObject") then
		warn(`[SkipPromptController]: nao achei {INTERFACE_NAME}.{SkipConfig.Name}.`)
		return false
	end

	self.Prompt = prompt
	self.BasePosition = prompt.Position
	self.Fades = self:_collectFades(prompt)
	self.CountLabel = prompt:FindFirstChild(SkipConfig.CountName)

	prompt.Visible = false

	local confirm = prompt:FindFirstChild(SkipConfig.ConfirmName)
	if confirm and confirm:IsA("GuiButton") then
		confirm.MouseButton1Click:Connect(function()
			Framework:Fire("VoteSkip", true)
		end)
	end

	local cancel = prompt:FindFirstChild(SkipConfig.CancelName)
	if cancel and cancel:IsA("GuiButton") then
		cancel.MouseButton1Click:Connect(function()
			self.DismissedToken = self.State and self.State.token
			Framework:Fire("VoteSkip", false)
			self:_hide()
		end)
	end

	return true
end

--[[ CICLO DE VIDA ]]

function SkipPromptController:construct()
	--[[
		O `Listen` entra antes do `_bind` porque o bind espera a Interface replicar:
		um estado que chegasse durante a espera se perderia, e o prompt so voltaria
		a aparecer na proxima mudanca de voto.
	]]
	Framework:Listen("SkipState", function(state)
		if typeof(state) ~= "table" then return end

		self.State = state
		self:_apply()
	end)

	task.spawn(function()
		if not self:_bind() then
			return
		end

		-- O estado que ja estava no ar quando este cliente carregou. Quem entra no
		-- meio de uma votacao aberta precisa ve-la; o `SkipState` so sai sozinho
		-- quando algo muda.
		Framework:Fire("RequestSkipState")

		self:_apply()
	end)
end

function SkipPromptController:start()
end

function SkipPromptController:init()
	self.Shown = false
	self.AnimToken = 0
	self.DismissedToken = nil
	self.State = nil
	self.Fades = {}

	self:construct()
end

return SkipPromptController
