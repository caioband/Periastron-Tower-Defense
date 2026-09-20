local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Run = require(script.Parent.Run)
local Dash = require(script.Parent.Dash)

local Player = Players.LocalPlayer

--[=[
	Os botoes de correr e de dash no celular, desenhados no mesmo idioma do botao de
	pulo do Roblox: um circulo escuro translucido de borda branca, no canto direito,
	ao alcance do mesmo polegar.

	**Tudo sai do botao de pulo.** O tamanho e uma fracao do dele, e a posicao e
	contada a partir do centro dele -- entao quando o Roblox troca o pulo de 70 para
	120 pixels numa tela maior, os dois crescem e se afastam junto. E ele tambem
	decide se os botoes aparecem: sem pulo na tela nao ha controle de toque (PC,
	controle), ou alguem tirou o pulo de proposito (o card de upgrade da Game esconde
	ele), e nos dois casos correr e dash saem junto.

	**Nao colidir com nada.** O lugar nao e fixo: ha uma lista de vagas em volta do
	pulo (esquerda, acima, diagonal, e uma segunda fileira de cada), e cada botao fica
	na primeira que estiver livre. Livre e medido na tela de verdade, com
	`GetGuiObjectsAtPosition` numa grade de pontos da vaga -- vale para qualquer UI
	das duas places, inclusive as que ainda nao existem, sem uma lista de nomes para
	manter. Um painel que abre por cima de uma vaga empurra o botao para a seguinte;
	sem vaga nenhuma o botao some ate abrir espaco.

	`GetGuiObjectsAtPosition` devolve ate o que esta escondido e as molduras vazias
	que so organizam layout, entao cada resultado passa por `isShown` e `hasContent`:
	so conta o que esta de fato na tela e tem alguma coisa desenhada. Os tres
	ScreenGuis de insets diferentes nao atrapalham a conta: o `AbsolutePosition` de
	todos ja sai no mesmo espaco (o inset entra no da propria ScreenGui), e e nesse
	espaco que o `GetGuiObjectsAtPosition` responde.

	---

	**O cluster nao e mais so do movimento.** Correr e dash sao dois inquilinos entre
	outros: qualquer controller registra um botao aqui com `:register(nome, config)` e
	o tira com `:unregister(nome)`. Quem faz isso hoje, alem do `MovementController`,
	e o `UnitPlacementController` -- `ROTATE` e `LOCK` aparecem junto dos outros dois
	enquanto ha uma unidade em mao no celular.

	A razao de eles morarem aqui, e nao numa GUI propria, e o solucionador de vagas:
	quatro circulos em volta do mesmo polegar tem de dividir as seis vagas sem se
	sobrepor nem cair embaixo da HUD, e isso e uma conta so. Duas GUIs independentes
	se resolveriam cada uma por si e se encontrariam na tela.

	Como o `Me` registra **todo** ModuleScript sob `Controllers`, chega-se aqui por
	`Framework:Get("MobileButtons")` de qualquer lugar das duas places.
]=]
local module = {}

--[[ CONSTANTS ]]
local GUI_NAME = "MovementButtons"

-- Fracoes do tamanho do botao de pulo.
local BUTTON_SCALE = 0.78
local GAP_SCALE = 0.12
local MIN_GAP = 6

-- Folga extra em volta da vaga ao medir colisao, em pixels.
local COLLISION_MARGIN = 4

-- Pontos por lado da grade que mede cada vaga (GRID x GRID).
local GRID = 4

-- A cada quanto a posicao e reconferida. Sem vaga, a busca e mais espacada.
local CHECK_INTERVAL = 0.25
local HIDDEN_CHECK_INTERVAL = 0.5

local FONT = Font.new("rbxassetid://12187371840", Enum.FontWeight.Bold, Enum.FontStyle.Normal)

local IDLE_COLOR = Color3.fromRGB(255, 255, 255)
local ACTIVE_COLOR = Color3.fromRGB(255, 200, 60)

--[[ STATE ]]
local gui : ScreenGui? = nil
local buttons = {}

-- As do movimento (Run.Changed), soltas pelo `stop`.
local connections = {}

-- As do cluster (o laco de layout), soltas quando o ultimo botao sai.
local loopConnections = {}

-- Declaradas aqui porque `register` as chama antes de elas serem definidas.
local ensureLoop, stopLoop

--[[ HELPERS ]]

local function getPlayerGui() : PlayerGui?
	return Player:FindFirstChildOfClass("PlayerGui")
end

local function findJumpButton() : GuiObject?
	local playerGui = getPlayerGui()
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	local controlFrame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local button = controlFrame and controlFrame:FindFirstChild("JumpButton")

	return button and button:IsA("GuiObject") and button or nil
end

-- Se o objeto esta de fato na tela: ele e todos os pais visiveis, dentro de um
-- ScreenGui ligado.
local function isShown(object : Instance) : boolean
	local node = object
	while node do
		if node:IsA("GuiObject") then
			if not node.Visible then return false end
			if node:IsA("CanvasGroup") and node.GroupTransparency >= 0.95 then return false end
		elseif node:IsA("LayerCollector") then
			return node.Enabled and node:IsA("ScreenGui")
		else
			return false
		end
		node = node.Parent
	end

	return false
end

-- Se o objeto desenha alguma coisa: moldura vazia de layout nao ocupa espaco.
local function hasContent(object : GuiObject) : boolean
	if object.BackgroundTransparency < 0.95 then return true end

	if object:IsA("ImageLabel") or object:IsA("ImageButton") then
		if object.Image ~= "" and object.ImageTransparency < 0.95 then return true end
	elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
		if object.Text ~= "" and object.TextTransparency < 0.95 then return true end
	elseif object:IsA("ViewportFrame") or object:IsA("VideoFrame") then
		return true
	end

	return false
end

local function makeCircle(parent : Instance, name : string, zIndex : number) : Frame
	local circle = Instance.new("Frame")
	circle.Name = name
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromScale(1, 1)
	circle.BorderSizePixel = 0
	circle.ZIndex = zIndex
	circle.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = circle

	return circle
end

local function createButton(name : string, text : string) : TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Visible = false
	button.Selectable = false

	local scale = Instance.new("UIScale")
	scale.Parent = button

	local circle = makeCircle(button, "Circle", 1)
	circle.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	circle.BackgroundTransparency = 0.55

	local stroke = Instance.new("UIStroke")
	stroke.Color = IDLE_COLOR
	stroke.Transparency = 0.35
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = circle

	-- A recarga do dash: um veu escuro que desce conforme o cooldown acaba.
	local cooldown = makeCircle(button, "Cooldown", 2)
	cooldown.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	cooldown.BackgroundTransparency = 0
	cooldown.Visible = false

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Parent = cooldown

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.72, 0.34)
	label.FontFace = FONT
	label.Text = text
	label.TextColor3 = IDLE_COLOR
	label.TextScaled = true
	label.ZIndex = 3
	label.Parent = button

	-- O aperto responde no toque, e nao no soltar: e o que o botao de pulo faz, e um
	-- dash que so sai quando o dedo levanta chega atrasado.
	button.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if input.UserInputState ~= Enum.UserInputState.Begin then return end

		scale.Scale = 0.9
		local action = buttons[name] and buttons[name].action
		if action then
			action()
		end
	end)

	button.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		scale.Scale = 1
	end)

	return button
end

local function ensureGui() : ScreenGui?
	if gui and gui.Parent then return gui end

	local playerGui = getPlayerGui()
	if not playerGui then return nil end

	gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.Enabled = false

	gui.Parent = playerGui

	return gui
end

--[=[
	O realce de "este botao esta ligado": a mesma cor e o mesmo peso que o `RUN`
	aceso sempre teve, agora disponivel a qualquer registro.

	Quem usa hoje e o `RUN` (correndo) e o `LOCK` (fantasma travado). Sao os dois
	botoes de estado do cluster; `DASH` e `ROTATE` disparam e voltam.
]=]
function module:setActive(name : string, active : boolean)
	local entry = buttons[name]
	if not entry then return end

	local button = entry.instance
	local color = active and ACTIVE_COLOR or IDLE_COLOR

	button.Circle.BackgroundTransparency = active and 0.3 or 0.55
	button.Circle.UIStroke.Color = color
	button.Circle.UIStroke.Transparency = active and 0 or 0.35
	button.Label.TextColor3 = color
end

local lastCooldown = -1
local function updateDashCooldown()
	local entry = buttons.Dash
	if not entry or not entry.instance.Parent then return end

	local alpha = Dash:getCooldownAlpha()
	if math.abs(alpha - lastCooldown) < 0.01 and not (alpha == 0 and lastCooldown ~= 0) then return end
	lastCooldown = alpha

	local veil = entry.instance.Cooldown
	if alpha <= 0 then
		veil.Visible = false
		return
	end

	-- O veu cobre de cima para baixo a fracao que ainda falta.
	local cut = math.clamp(alpha, 0.002, 0.998)
	veil.UIGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(cut, 0.45),
		NumberSequenceKeypoint.new(math.min(1, cut + 0.001), 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	veil.Visible = true
end

--[[ LAYOUT ]]

-- Os botoes sao circulos: dois deles se tocam pela distancia dos centros, e nao
-- pelas caixas -- a vaga diagonal nunca caberia se fossem quadrados.
local function circlesTouch(a : Vector2, aSize : number, b : Vector2, bSize : number, gap : number) : boolean
	return (a - b).Magnitude < (aSize + bSize) / 2 + gap
end

local function makeRect(center : Vector2, size : number, margin : number)
	local half = size / 2 + margin
	return { min = center - Vector2.new(half, half), max = center + Vector2.new(half, half), center = center }
end

--[=[
	Se nada da tela desenha dentro da vaga. `memo` guarda o veredito de cada objeto
	durante uma busca: a mesma moldura aparece em varios pontos da grade.
]=]
local function isAreaFree(rect, memo) : boolean
	local playerGui = getPlayerGui()
	if not playerGui or not gui then return false end

	-- Fora da tela nao e vaga.
	local screenMin = gui.AbsolutePosition
	local screenMax = screenMin + gui.AbsoluteSize
	if rect.min.X < screenMin.X or rect.min.Y < screenMin.Y or rect.max.X > screenMax.X or rect.max.Y > screenMax.Y then
		return false
	end

	local touchGui = playerGui:FindFirstChild("TouchGui")
	local size = rect.max - rect.min

	for ix = 0, GRID - 1 do
		for iy = 0, GRID - 1 do
			local point = rect.min + Vector2.new(size.X * (ix + 0.5) / GRID, size.Y * (iy + 0.5) / GRID)

			for _, object in playerGui:GetGuiObjectsAtPosition(point.X, point.Y) do
				local verdict = memo[object]
				if verdict == nil then
					verdict = not object:IsDescendantOf(gui)
						and not (touchGui and object:IsDescendantOf(touchGui))
						and object.AbsoluteSize.X > 0 and object.AbsoluteSize.Y > 0
						and isShown(object)
						and hasContent(object)
					memo[object] = verdict
				end

				if verdict then return false end
			end
		end
	end

	return true
end

--[[
	As vagas em volta do pulo, em ordem de preferencia de cada botao.

	Cada registro traz a sua; esta e a ordem de quem nao trouxer. As listas dos
	quatro botoes de hoje comecam em vagas diferentes de proposito -- assim o caso
	comum se resolve sem o solucionador ter de desempatar nada.
]]
local DEFAULT_SLOT_ORDER = { "Left", "Up", "Diagonal", "FarLeft", "FarUp", "LeftUp" }

local function buildSlots(jumpCenter : Vector2, jumpSize : number, size : number, gap : number)
	local reach = jumpSize / 2 + gap + size / 2
	local step = size + gap
	local diagonal = reach * math.sqrt(0.5)

	return {
		Left = jumpCenter + Vector2.new(-reach, 0),
		Up = jumpCenter + Vector2.new(0, -reach),
		Diagonal = jumpCenter + Vector2.new(-diagonal, -diagonal),
		FarLeft = jumpCenter + Vector2.new(-reach - step, 0),
		FarUp = jumpCenter + Vector2.new(0, -reach - step),
		LeftUp = jumpCenter + Vector2.new(-reach, -step),
	}
end

local layout = {
	key = nil,
	placed = {}, -- [nome] = centro na tela
	size = 0,
	gap = 0,
}

local function hideAll()
	for _, entry in buttons do
		entry.instance.Visible = false
	end
	table.clear(layout.placed)
end

local function applyPlacement(name : string, center : Vector2?)
	local entry = buttons[name]
	if not entry or not gui then return end

	local button = entry.instance
	if not center then
		button.Visible = false
		layout.placed[name] = nil
		return
	end

	local local_ = center - gui.AbsolutePosition
	button.Size = UDim2.fromOffset(layout.size, layout.size)
	button.Position = UDim2.fromOffset(math.round(local_.X), math.round(local_.Y))
	button.Circle.UIStroke.Thickness = math.max(2, math.round(layout.size * 0.04))
	button.Visible = true

	layout.placed[name] = center
end

--[=[
	Distribui os botoes registrados pelas vagas livres.

	Busca em profundidade, e nao ganancia. A diferenca aparece justamente no caso
	apertado: a primeira vaga da lista do dash pode ser a unica que serve ao `RUN`,
	e um laco ganancioso a tomaria e deixaria o outro botao fora da tela. A busca
	desiste dessa vaga e tenta a seguinte quando isso rende **mais** botoes na tela.

	Cada nivel tem tambem o ramo de **nao** colocar aquele botao -- e o que permite
	uma solucao parcial quando a HUD nao deixa espaco para todos. Como so se troca o
	melhor por um estritamente maior, a primeira solucao encontrada com aquele numero
	e a que vence, e ela e a que respeita a ordem de prioridade e a lista de vagas de
	cada um.

	O espaco e minusculo (seis vagas, um punhado de botoes) e o `free` e memoizado,
	entao a conta inteira custa menos que a medida de tela que a alimenta.
]=]
local function solve(jumpCenter : Vector2, jumpSize : number, slots, order : { string })
	local memo = {}
	local freeCache = {}

	local function free(slotName : string) : boolean
		local cached = freeCache[slotName]
		if cached ~= nil then return cached end

		local center = slots[slotName]
		local result = not circlesTouch(center, layout.size, jumpCenter, jumpSize, layout.gap / 2)
			and isAreaFree(makeRect(center, layout.size, COLLISION_MARGIN), memo)
		freeCache[slotName] = result
		return result
	end

	local taken = {}        -- [vaga] = nome
	local chosen = {}       -- [nome] = vaga
	local best, bestCount = nil, -1

	local function conflicts(slotName : string) : boolean
		for otherSlot in taken do
			if circlesTouch(slots[slotName], layout.size, slots[otherSlot], layout.size, layout.gap / 2) then
				return true
			end
		end
		return false
	end

	local function search(index : number, placed : number)
		-- Todos couberam: nao ha nada melhor a procurar.
		if bestCount == #order then return end

		if index > #order then
			if placed > bestCount then
				best, bestCount = table.clone(chosen), placed
			end
			return
		end

		local name = order[index]
		local entry = buttons[name]
		local preference = (entry and entry.slots) or DEFAULT_SLOT_ORDER

		for _, slotName in preference do
			if slots[slotName] and not taken[slotName] and free(slotName) and not conflicts(slotName) then
				taken[slotName] = name
				chosen[name] = slotName

				search(index + 1, placed + 1)

				taken[slotName] = nil
				chosen[name] = nil

				if bestCount == #order then return end
			end
		end

		-- Este fica de fora; talvez os de baixo caibam.
		search(index + 1, placed)
	end

	search(1, 0)

	return best or {}
end

--- Os nomes registrados, do mais importante para o menos. Empate cai no nome, para
--- a ordem nao depender da iteracao de uma tabela com chave.
local function registeredOrder() : { string }
	local order = {}
	for name in buttons do
		table.insert(order, name)
	end

	table.sort(order, function(a, b)
		local pa, pb = buttons[a].priority, buttons[b].priority
		if pa ~= pb then return pa < pb end
		return a < b
	end)

	return order
end

local function refreshLayout(force : boolean?)
	if not gui then return end

	local order = registeredOrder()

	local jump = findJumpButton()
	if #order == 0 or not jump or not isShown(jump) then
		gui.Enabled = false
		hideAll()
		layout.key = nil
		return
	end

	gui.Enabled = true

	local jumpSize = math.min(jump.AbsoluteSize.X, jump.AbsoluteSize.Y)
	local jumpCenter = jump.AbsolutePosition + jump.AbsoluteSize / 2
	local key = `{math.round(jumpCenter.X)}:{math.round(jumpCenter.Y)}:{jumpSize}:{gui.AbsoluteSize.X}:{gui.AbsoluteSize.Y}:{#order}`

	layout.size = math.round(jumpSize * BUTTON_SCALE)
	layout.gap = math.max(MIN_GAP, math.round(jumpSize * GAP_SCALE))

	--[[
		Nada mudou de tamanho e todo mundo esta na tela: se as vagas de agora
		continuam livres, fica tudo onde esta, sem o botao pular de lugar a toa.

		A contagem entra na chave porque registrar ou tirar um botao muda o problema
		mesmo com a tela igual -- sem ela, o `ROTATE` entrando nao redistribuiria nada.
	]]
	local allPlaced = true
	for _, name in order do
		if not layout.placed[name] then
			allPlaced = false
			break
		end
	end

	if not force and key == layout.key and allPlaced then
		local memo = {}
		local stillFree = true
		for _, center in layout.placed do
			if not isAreaFree(makeRect(center, layout.size, COLLISION_MARGIN), memo) then
				stillFree = false
				break
			end
		end
		if stillFree then return end
	end

	layout.key = key

	local slots = buildSlots(jumpCenter, jumpSize, layout.size, layout.gap)
	local assignment = solve(jumpCenter, jumpSize, slots, order)

	for _, name in order do
		local slotName = assignment[name]
		applyPlacement(name, slotName and slots[slotName] or nil)
	end
end

--[[ REGISTRO ]]

--[=[
	Poe um botao no cluster.

	`config`:
	  - `Text`        rotulo, em caixa alta (`DASH`, `LOCK`)
	  - `OnActivate`  chamada no **toque**, e nao no soltar
	  - `Priority`    menor escolhe vaga primeiro
	  - `Slots`       ordem de preferencia de vagas; sem isto, a padrao
	  - `OnHeartbeat` opcional, por quadro, para quem desenha estado continuo

	Registrar o mesmo nome duas vezes substitui o anterior, o que faz de `register`
	a chamada segura de repetir num `begin` que roda a cada respawn.
]=]
function module:register(name : string, config)
	if not UserInputService.TouchEnabled then return end
	if not ensureGui() then return end

	self:unregister(name)

	local instance = createButton(name, config.Text or name:upper())
	instance.Parent = gui

	buttons[name] = {
		instance = instance,
		action = config.OnActivate,
		priority = config.Priority or 100,
		slots = config.Slots,
		heartbeat = config.OnHeartbeat,
	}

	ensureLoop()
	refreshLayout(true)
end

function module:unregister(name : string)
	local entry = buttons[name]
	if not entry then return end

	buttons[name] = nil
	layout.placed[name] = nil
	entry.instance:Destroy()

	--[[
		Sai da tela **e** devolve a vaga. Sem o `force` o atalho acima veria a chave
		mudada e redistribuiria mesmo assim, mas por um motivo lateral; aqui e
		explicito porque tirar um botao e justamente quando os outros podem subir
		para uma vaga melhor.
	]]
	refreshLayout(true)

	if next(buttons) == nil then
		stopLoop()
		if gui then gui.Enabled = false end
	end
end

--[[ LIFECYCLE ]]

--[=[
	O laco do cluster: pertence a ele, e nao a quem registrou.

	Enquanto houver um botao registrado ele remede a tela de tempos em tempos -- e o
	que faz o botao fugir de um painel que abriu por cima da vaga dele. Liga no
	primeiro registro e desliga no ultimo.
]=]
function ensureLoop()
	if loopConnections[1] then return end

	local elapsed = math.huge
	table.insert(loopConnections, RunService.Heartbeat:Connect(function(dt)
		for _, entry in buttons do
			if entry.heartbeat then
				entry.heartbeat()
			end
		end

		elapsed += dt

		local everyonePlaced = true
		for name in buttons do
			if not layout.placed[name] then
				everyonePlaced = false
				break
			end
		end

		if elapsed < (everyonePlaced and CHECK_INTERVAL or HIDDEN_CHECK_INTERVAL) then return end
		elapsed = 0

		refreshLayout()
	end))

	-- Girar a tela ou trocar o tamanho do pulo pede a busca na hora.
	if gui then
		table.insert(loopConnections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			refreshLayout(true)
		end))
	end
end

function stopLoop()
	for _, connection in loopConnections do
		connection:Disconnect()
	end
	table.clear(loopConnections)
end

--[=[
	Os dois botoes do movimento entram aqui, e nao no `register` de fora, porque sao
	os unicos que dependem do personagem: eles nascem com ele e morrem com ele.
]=]
function module:begin(character)
	-- Aparelho sem toque nunca tem botao de pulo; nao ha o que montar.
	if not UserInputService.TouchEnabled then return end

	self:stop()

	self:register("Dash", {
		Text = "DASH",
		Priority = 1,
		Slots = { "Left", "Up", "Diagonal", "FarLeft", "FarUp", "LeftUp" },
		OnActivate = function() Dash:tryDash() end,
		OnHeartbeat = updateDashCooldown,
	})

	self:register("Run", {
		Text = "RUN",
		Priority = 2,
		Slots = { "Up", "Diagonal", "Left", "FarUp", "LeftUp", "FarLeft" },
		OnActivate = function() Run:toggle() end,
	})

	self:setActive("Run", Run.isRunning)
	table.insert(connections, Run.Changed.Event:Connect(function(running)
		self:setActive("Run", running)
	end))
end

--[=[
	Tira o movimento do cluster. O que outros controllers registraram **fica**: um
	respawn no meio de um posicionamento nao deve levar o `ROTATE` junto.
]=]
function module:stop()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	self:unregister("Dash")
	self:unregister("Run")

	lastCooldown = -1
end

return module
