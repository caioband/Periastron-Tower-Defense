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
local Config = WeatherConfig.Indicator

--[[
	O indicador de clima do HUD.

	Duas coisas na mesma peça de tela, e a segunda é a razão de a primeira ser um
	botão:

	  1. o **ícone** (`Interface.WeatherIndicator.Details`) é sempre o clima que está
	     no ar agora. Sem clima nenhum ele não some nem apaga: mostra o ícone de céu
	     limpo, porque "não está chovendo" é uma informação, e não a ausência de uma;
	  2. os **detalhes** saem no clique: uma frase curta escrita letra a letra dentro
	     do próprio frame, que fica um tempo na tela e sai sozinha.

	**O botão trava enquanto a frase está viva** — escrita, leitura e saída —, e é
	isso que impede o clique repetido de reescrever por cima de si mesmo. Ele volta
	quando a caixa já está vazia, e não antes: botão livre com texto sumindo convida
	o clique que começaria a frase nova no meio da saída da anterior.

	**De onde vem o que ele diz.** O clima de agora é do `WeatherController`
	(`WeatherChanged`); o que vem por aí é do `WeatherWarning`, que traz a wave-alvo
	junto — e a wave de agora é do `SetWave`. Guardar o alvo, e não o "faltam
	quantas", é o que permite a conta certa no instante do clique, que é sempre
	depois do aviso.

	Fica na Game: clima de partida só existe aqui.
]]

local WeatherIndicatorController = {
	Controllers = {
		RichTextController = {},
		WeatherController = {},
	}
}

-- A caixa do texto e o render que está nela.
WeatherIndicatorController.Group = nil :: CanvasGroup?
WeatherIndicatorController.Handle = nil :: any
WeatherIndicatorController.Button = nil :: ImageButton?

-- A wave de agora, e o que o servidor avisou que vem: o nome e a wave em que ele
-- cai. `Wave` sobe pelo `SetWave`, como em todo lugar.
WeatherIndicatorController.Wave = 0
WeatherIndicatorController.ScheduledName = nil :: string?
WeatherIndicatorController.ScheduledWave = nil :: number?

-- O clique está em curso? É o mesmo estado que tranca o botão. Ver `open`.
WeatherIndicatorController.Busy = false

-- Sobe a cada abertura: a saída de uma confere se ainda é a dela antes de apagar
-- a tela. Sem isto, um round reiniciado no meio da leitura apagaria a frase que o
-- clique seguinte tinha acabado de escrever.
WeatherIndicatorController.Token = 0

--[[ INTERNAL ]]

--[=[
	O frame do indicador e o botão dentro dele.

	Devolve `false` quando a tela não existe nesta place ou ainda não replicou — o
	controller então não faz nada, em vez de estourar em cima de um `nil`.
]=]
function WeatherIndicatorController:bind() : boolean
	local screen = PlayerGui:WaitForChild(Config.Gui.Screen, 60)
	local frame = screen and screen:WaitForChild(Config.Gui.Frame, 60)
	local button = frame and frame:WaitForChild(Config.Gui.Button, 60)

	if not frame or not frame:IsA("GuiObject") then
		warn(`[WeatherIndicatorController]: nao achei {Config.Gui.Screen}.{Config.Gui.Frame} na PlayerGui.`)

		return false
	end

	if not button or not button:IsA("ImageButton") then
		warn(`[WeatherIndicatorController]: o {Config.Gui.Frame} nao tem o botao {Config.Gui.Button}.`)

		return false
	end

	self.Button = button

	--[[
		A caixa do texto é uma `CanvasGroup` do tamanho do frame, criada aqui.

		Ela não é uma caixa nova na tela: não tem fundo, não tem margem e ocupa
		exatamente o frame que o designer desenhou — o texto sai onde sairia se fosse
		escrito direto nele. O que ela dá é o `GroupTransparency`, e com ele a saída
		inteira some num tween só, em vez de um por letra.

		Escrever direto no frame não daria isso: quem está lá dentro é o botão, que
		não pode desaparecer junto com a frase.
	]]
	local group = frame:FindFirstChild(Config.Gui.Text)

	-- Nome nosso ocupado por outra coisa: o designer pôs algo com este nome no
	-- Studio. O nome é do controller (está documentado no config), então ele fica com
	-- ele — mas não em silêncio.
	if group and not group:IsA("CanvasGroup") then
		warn(`[WeatherIndicatorController]: {Config.Gui.Frame}.{Config.Gui.Text} existe e nao e uma CanvasGroup; trocando pela caixa do texto.`)

		group:Destroy()
		group = nil
	end

	if not group then
		group = Instance.new("CanvasGroup")
		group.Name = Config.Gui.Text
		group.Size = UDim2.fromScale(1, 1)
		group.BackgroundTransparency = 1
		group.BorderSizePixel = 0
		group.GroupTransparency = 1

		-- Não come clique: o botão está por baixo dela na área do frame, e uma caixa
		-- de texto que engole o clique do próprio botão que a abriu seria uma caixa
		-- que só abre uma vez.
		group.Active = false
		group.Interactable = false

		group.Parent = frame
	end

	self.Group = group :: CanvasGroup

	return true
end

--[=[
	O clima que está no ar agora, ou `nil`.
]=]
function WeatherIndicatorController:current() : string?
	local weather = self.Controllers.WeatherController

	return weather and weather:GetCurrent() or nil
end

--[=[
	Quantas waves faltam para o clima agendado, ou `nil` quando não há um.

	A conta é feita **agora**, e não na hora do aviso: entre um e outro o jogador
	jogou waves inteiras. Alvo que já passou não é agendamento — é um aviso que o
	servidor cumpriu (ou que a carta Weather Report apagou) e que ninguém veio
	desdizer.
]=]
function WeatherIndicatorController:wavesAhead() : number?
	if not self.ScheduledName or not self.ScheduledWave then
		return nil
	end

	local ahead = self.ScheduledWave - self.Wave

	return if ahead > 0 then ahead else nil
end

--[=[
	A linha do que vem por aí, ou `nil` quando não vem nada.
]=]
function WeatherIndicatorController:warningLine() : string?
	local ahead = self:wavesAhead()
	if not ahead then
		return nil
	end

	local name = WeatherConfig.GetDisplayName(self.ScheduledName :: string)

	return if ahead == 1
		then string.format(Config.WarningOne, name)
		else string.format(Config.Warning, name, ahead)
end

--[=[
	O que a caixa diz agora: o clima no ar (ou a falta dele) e, embaixo, o que vem.
]=]
function WeatherIndicatorController:describe() : string
	local current = self:current()

	local title = if current
		then WeatherConfig.GetDisplayName(current)
		else Config.NoneTitle

	local body = if current
		then (Config.Descriptions[current] or Config.UnknownDescription)
		else Config.NoneDescription

	local lines = {
		string.format(Config.Title, title),
		body,
	}

	local warning = self:warningLine()
	if warning then
		table.insert(lines, warning)
	end

	return table.concat(lines, "[br]")
end

--[=[
	Põe no botão o ícone do clima de agora.

	Clima sem ícone na lista cai no de céu limpo, com um aviso no output: melhor o
	botão continuar legível que mostrar um vazio.
]=]
function WeatherIndicatorController:refreshIcon()
	local button = self.Button
	if not button then return end

	local current = self:current()

	if current and not Config.Icons[current] then
		warn(`[WeatherIndicatorController]: o clima "{current}" nao tem icone em WeatherConfig.Indicator.Icons.`)
	end

	button.Image = (current and Config.Icons[current]) or Config.NoneIcon
end

--[=[
	Leva a caixa a uma transparência e devolve quando o tween acaba.
]=]
function WeatherIndicatorController:fade(transparency : number, duration : number)
	local group = self.Group
	if not group then return end

	if duration <= 0 then
		group.GroupTransparency = transparency

		return
	end

	local tween = TweenService:Create(
		group,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ GroupTransparency = transparency }
	)

	tween:Play()
	tween.Completed:Wait()
end

--[=[
	O render da caixa, criado na primeira vez que alguém clica.
]=]
function WeatherIndicatorController:handle() : any
	if self.Handle then
		return self.Handle
	end

	local richText = self.Controllers.RichTextController
	local group = self.Group

	if not richText or not group then
		return nil
	end

	self.Handle = richText:Bind(group, Config.Text)

	return self.Handle
end

--[=[
	Espera a escrita terminar.

	O fim vem do renderizador, mas não se aposta a destrava do botão nele: um texto
	vazio, o backend de reserva ou a tela sumindo no meio deixariam o aviso sem
	chegar, e o botão trancado para sempre. Passado o `WriteTimeout`, segue assim
	mesmo.
]=]
function WeatherIndicatorController:awaitWrite(handle : any)
	local finished = false

	local disconnect
	disconnect = handle:OnFinished(function()
		finished = true
	end)

	local deadline = os.clock() + Config.WriteTimeout

	while not finished and os.clock() < deadline do
		task.wait(0.05)
	end

	if disconnect then
		disconnect()
	end
end

--[=[
	O clique: escreve, deixa ler e apaga.

	Roda numa thread própria porque espera três vezes (a escrita, a leitura e a
	saída), e o clique não pode segurar o input do jogador enquanto isso.
]=]
function WeatherIndicatorController:open()
	if self.Busy then return end

	local handle = self:handle()
	if not handle then return end

	self.Busy = true
	self.Token += 1
	local token = self.Token

	local button = self.Button
	if button then
		-- `Active = false` é o que recusa o clique; o resto é para ele parecer
		-- trancado em vez de parecer quebrado.
		button.Active = false
		button.AutoButtonColor = false
	end

	task.spawn(function()
		local text = self:describe()

		handle:Clear(true)
		self:fade(0, Config.FadeIn)

		if self.Token ~= token then return end

		handle:Write(text)
		self:awaitWrite(handle)

		if self.Token ~= token then return end

		-- O tempo de ler o que acabou de ser escrito.
		task.wait(Config.Hold)

		if self.Token ~= token then return end

		self:fade(1, Config.FadeOut)

		if self.Token ~= token then return end

		self:close()
	end)
end

--[=[
	Apaga a caixa e devolve o botão. Idempotente.
]=]
function WeatherIndicatorController:close()
	local handle = self.Handle
	if handle then
		handle:Clear(true)
	end

	local group = self.Group
	if group then
		group.GroupTransparency = 1
	end

	local button = self.Button
	if button then
		button.Active = true
		button.AutoButtonColor = true
	end

	self.Busy = false
end

--[[ CICLO DE VIDA ]]

function WeatherIndicatorController:construct()
	if not self:bind() then return end

	self:refreshIcon()

	local button = self.Button :: ImageButton

	button.MouseButton1Click:Connect(function()
		self:open()
	end)

	Framework:Listen("WeatherChanged", function()
		--[[
			O `WeatherController` é quem guarda o clima de agora, e ele escuta o mesmo
			aviso. Ler dele um quadro depois dispensa manter uma segunda cópia do mesmo
			estado aqui — e uma cópia a menos é uma chance a menos de as duas
			discordarem.
		]]
		task.defer(function()
			self:refreshIcon()
		end)
	end)

	Framework:Listen("SetWave", function(wave : any)
		self.Wave = tonumber(wave) or self.Wave
	end)

	Framework:Listen("WeatherWarning", function(weatherName : any, _wavesAhead : any, scheduledWave : any)
		if typeof(weatherName) ~= "string" then return end

		self.ScheduledName = weatherName
		self.ScheduledWave = tonumber(scheduledWave)
	end)

	--[[
		Round novo não herda o agendamento do anterior, nem a caixa aberta do jogador
		que estava lendo quando a partida virou.
	]]
	Framework:Listen("RoundRestarted", function()
		self.Wave = 0
		self.ScheduledName = nil
		self.ScheduledWave = nil

		self.Token += 1
		self:close()
		self:refreshIcon()
	end)
end

function WeatherIndicatorController:start()
end

function WeatherIndicatorController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WeatherIndicatorController
