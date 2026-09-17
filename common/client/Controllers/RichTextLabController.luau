local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.RichTextConfig

--[[
	A bancada do texto rico: escreva a marcação, aperte DISPLAY, veja.

	Abre pelo Cmdr (`richtext`) e serve para uma coisa só — experimentar marcação
	sem editar config, sem dar Play de novo e sem inventar um NPC para falar. É
	onde se descobre que `amp=.3` no wiggle sacode demais antes de o efeito ir
	parar numa tela do jogo.

	Três partes, que é o que a bancada precisa ter:

		PREVIEW   o container onde o texto é desenhado (é ele que vai ao
		          `RichTextController:Bind`, igual a qualquer tela do jogo)
		INPUT     a caixa onde se escreve a marcação
		DISPLAY   o botão que manda desenhar; CLEAR apaga e PRESET troca o preset

	**A tela é feita em código, de propósito.** O `StarterGui` não é sincronizado
	pelo Rojo — uma tela autorada no Studio não estaria no git, e uma ferramenta de
	dev que depende de alguém ter o place aberto na versão certa não serve para
	nada. Aqui ela nasce do arquivo, igual nas duas places.

	**Trocar de preset recria o handle** em vez de só reajustar o que existe. As
	opções de um handle se acumulam (é o contrato do `RichTextController`: o que
	você pede continua valendo), e numa bancada isso mentiria — o contorno do
	`Warning` sobreviveria ao `Instant` e você estaria olhando para uma mistura que
	nenhuma tela do jogo teria.

	Fica em `common/` porque marcação é a mesma coisa nas duas places.
]]

local RichTextLabController = {
	Controllers = {
		RichTextController = {}
	}
}

RichTextLabController.Gui = nil :: ScreenGui?
RichTextLabController.Preview = nil :: Frame?
RichTextLabController.Input = nil :: TextBox?
RichTextLabController.PresetButton = nil :: TextButton?
RichTextLabController.Handle = nil :: any

-- Índice em `Presets`, a lista de nomes que o botão PRESET percorre.
RichTextLabController.Presets = {}
RichTextLabController.PresetIndex = 1

local COLORS = {
	Panel = Color3.fromRGB(24, 24, 30),
	Preview = Color3.fromRGB(14, 14, 18),
	Input = Color3.fromRGB(34, 34, 42),
	Button = Color3.fromRGB(46, 46, 58),
	Accent = Color3.fromRGB(64, 132, 96),
	Stroke = Color3.fromRGB(70, 70, 86),
	Text = Color3.fromRGB(235, 235, 240),
	Faded = Color3.fromRGB(150, 150, 165),
}

local PLACEHOLDER = "[color=yellow]texto[/color] com [shake]efeito[/shake][pause=0.5] e [wiggle]onda[/wiggle]"

--[[ INTERNAL ]]

--[=[
	`Instance.new` com propriedades e pai numa chamada só. A tela inteira é feita
	daqui para baixo, e sem isso ela seria três vezes mais linhas de atribuição.
]=]
local function create(className : string, properties : { [string] : any }, parent : Instance?) : any
	local instance = Instance.new(className)

	for property, value in properties do
		(instance :: any)[property] = value
	end

	if parent then
		instance.Parent = parent
	end

	return instance
end

--[=[
	Um botão da barra de baixo.
]=]
local function createButton(text : string, color : Color3, layoutOrder : number, parent : Instance) : TextButton
	local button = create("TextButton", {
		Name = text,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = COLORS.Text,
		TextSize = 14,
		Font = Enum.Font.GothamMedium,
		AutoButtonColor = true,
		LayoutOrder = layoutOrder,
	}, parent)

	create("UICorner", { CornerRadius = UDim.new(0, 6) }, button)
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
	}, button)

	return button
end

--[=[
	Monta a tela. Uma vez por sessão: fechar só esconde.
]=]
function RichTextLabController:build()
	if self.Gui and self.Gui.Parent then
		return
	end

	local gui = create("ScreenGui", {
		Name = "RichTextLab",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 50,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, PlayerGui)

	local panel = create("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.52, 0.66),
		BackgroundColor3 = COLORS.Panel,
		BorderSizePixel = 0,
	}, gui)

	create("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
	create("UIStroke", { Color = COLORS.Stroke, Thickness = 1 }, panel)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, panel)
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, panel)

	--[[ TÍTULO ]]

	local header = create("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0.08, 0),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
	}, panel)

	create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "RICH TEXT LAB",
		TextColor3 = COLORS.Faded,
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)

	local close = create("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = COLORS.Button,
		BorderSizePixel = 0,
		Text = "X",
		TextColor3 = COLORS.Text,
		TextSize = 14,
		Font = Enum.Font.GothamBold,
	}, header)

	create("UICorner", { CornerRadius = UDim.new(0, 6) }, close)

	--[[ PREVIEW — o container do render ]]

	local preview = create("Frame", {
		Name = "Preview",
		Size = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = COLORS.Preview,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = 2,
	}, panel)

	create("UICorner", { CornerRadius = UDim.new(0, 8) }, preview)

	--[[ INPUT ]]

	local input = create("TextBox", {
		Name = "Input",
		Size = UDim2.new(1, 0, 0.26, 0),
		BackgroundColor3 = COLORS.Input,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		MultiLine = true,
		Text = PLACEHOLDER,
		PlaceholderText = PLACEHOLDER,
		PlaceholderColor3 = COLORS.Faded,
		TextColor3 = COLORS.Text,
		TextSize = 15,
		Font = Enum.Font.Code,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 3,
	}, panel)

	create("UICorner", { CornerRadius = UDim.new(0, 8) }, input)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
	}, input)

	--[[ BOTÕES ]]

	local bar = create("Frame", {
		Name = "Actions",
		Size = UDim2.new(1, 0, 0.1, 0),
		BackgroundTransparency = 1,
		LayoutOrder = 4,
	}, panel)

	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, bar)

	local display = createButton("DISPLAY", COLORS.Accent, 1, bar)
	local clear = createButton("CLEAR", COLORS.Button, 2, bar)
	local preset = createButton("PRESET", COLORS.Button, 3, bar)

	self.Gui = gui
	self.Preview = preview
	self.Input = input
	self.PresetButton = preset

	self:refreshPresetButton()

	display.Activated:Connect(function()
		self:Display()
	end)

	clear.Activated:Connect(function()
		self:Clear()
	end)

	preset.Activated:Connect(function()
		self:CyclePreset()
	end)

	close.Activated:Connect(function()
		self:Close()
	end)
end

--[=[
	A lista de presets que o botão percorre: os do config mais o `Defaults`
	sozinho, que é o que uma tela sem preset nenhum recebe — e por isso também
	precisa ser testável aqui.

	Ordenada por nome para o botão não trocar de ordem entre sessões: a ordem de um
	`pairs` sobre o config não é a mesma duas vezes.
]=]
function RichTextLabController:buildPresetList()
	local names = { "Defaults" }

	for name in Config.Presets do
		table.insert(names, name)
	end

	table.sort(names, function(a, b)
		if a == "Defaults" then return true end
		if b == "Defaults" then return false end

		return a < b
	end)

	self.Presets = names
end

function RichTextLabController:currentPreset() : string?
	local name = self.Presets[self.PresetIndex]

	return if name == "Defaults" then nil else name
end

function RichTextLabController:refreshPresetButton()
	local button = self.PresetButton
	if not button then return end

	button.Text = `PRESET: {self.Presets[self.PresetIndex]}`
end

--[=[
	O handle do preview, criado com o preset em uso.
]=]
function RichTextLabController:getHandle() : any
	if self.Handle then
		return self.Handle
	end

	local preview = self.Preview
	if not preview then
		return nil
	end

	self.Handle = self.Controllers.RichTextController:Bind(preview, {
		Preset = self:currentPreset(),
	})

	return self.Handle
end

--[[ API ]]

--[=[
	Desenha o que estiver na caixa.
]=]
function RichTextLabController:Display()
	local input = self.Input
	local handle = self:getHandle()
	if not input or not handle then return end

	handle:Write(input.Text)
end

--[=[
	Apaga o preview sem fechar a bancada.
]=]
function RichTextLabController:Clear()
	local handle = self.Handle
	if not handle then return end

	handle:Clear(true)
end

--[=[
	Próximo preset da lista.

	Solta o handle antigo em vez de reaproveitá-lo: preset novo tem de chegar numa
	configuração limpa, senão o que o preset anterior pediu continuaria valendo por
	baixo (ver o cabeçalho).
]=]
function RichTextLabController:CyclePreset()
	self.PresetIndex += 1
	if self.PresetIndex > #self.Presets then
		self.PresetIndex = 1
	end

	self:refreshPresetButton()

	local preview = self.Preview
	if preview then
		self.Controllers.RichTextController:Release(preview)
		self.Handle = nil
	end

	self:Display()
end

function RichTextLabController:Open()
	self:build()

	local gui = self.Gui
	if gui then
		gui.Enabled = true
	end
end

function RichTextLabController:Close()
	local gui = self.Gui
	if gui then
		gui.Enabled = false
	end
end

function RichTextLabController:Toggle() : boolean
	local gui = self.Gui

	if gui and gui.Enabled then
		self:Close()

		return false
	end

	self:Open()

	return true
end

function RichTextLabController:IsOpen() : boolean
	local gui = self.Gui

	return gui ~= nil and gui.Enabled
end

--[[ CICLO DE VIDA ]]

function RichTextLabController:construct()
	self:buildPresetList()

	-- Quem abre é o comando `richtext` do Cmdr, pelo servidor: a permissão de rodar
	-- comando é de lá, e uma bancada que o cliente abrisse sozinho seria uma tela
	-- de dev na mão de qualquer jogador.
	Framework:Listen("RichTextLabToggle", function()
		self:Toggle()
	end)
end

function RichTextLabController:start()
end

function RichTextLabController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return RichTextLabController
