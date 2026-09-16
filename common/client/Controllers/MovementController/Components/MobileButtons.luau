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
local connections = {}

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

	buttons.Dash = { instance = createButton("Dash", "DASH"), action = function() Dash:tryDash() end }
	buttons.Run = { instance = createButton("Run", "RUN"), action = function() Run:toggle() end }

	for _, entry in buttons do
		entry.instance.Parent = gui
	end

	gui.Parent = playerGui

	return gui
end

local function setRunVisual(running : boolean)
	local entry = buttons.Run
	if not entry then return end

	local button = entry.instance
	local color = running and ACTIVE_COLOR or IDLE_COLOR

	button.Circle.BackgroundTransparency = running and 0.3 or 0.55
	button.Circle.UIStroke.Color = color
	button.Circle.UIStroke.Transparency = running and 0 or 0.35
	button.Label.TextColor3 = color
end

local lastCooldown = -1
local function updateDashCooldown()
	local entry = buttons.Dash
	if not entry then return end

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

-- As vagas em volta do pulo, em ordem de preferencia de cada botao.
local SLOT_ORDER = {
	Dash = { "Left", "Up", "Diagonal", "FarLeft", "FarUp", "LeftUp" },
	Run = { "Up", "Diagonal", "Left", "FarUp", "LeftUp", "FarLeft" },
}

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
	Acha a melhor dupla de vagas: o dash tem prioridade (e o botao de reflexo), e
	para cada vaga dele a corrida pega a primeira livre que nao encoste nele. Sem
	dupla, fica o que couber.
]=]
local function solve(jumpCenter : Vector2, jumpSize : number, slots)
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

	local function apart(a : string, b : string) : boolean
		return not circlesTouch(slots[a], layout.size, slots[b], layout.size, layout.gap / 2)
	end

	local dashOnly, runOnly = nil, nil

	for _, dashSlot in SLOT_ORDER.Dash do
		if not free(dashSlot) then continue end
		dashOnly = dashOnly or dashSlot

		for _, runSlot in SLOT_ORDER.Run do
			if runSlot ~= dashSlot and free(runSlot) and apart(dashSlot, runSlot) then
				return slots[dashSlot], slots[runSlot]
			end
		end
	end

	if dashOnly then
		return slots[dashOnly], nil
	end

	for _, runSlot in SLOT_ORDER.Run do
		if free(runSlot) then
			runOnly = runSlot
			break
		end
	end

	return nil, runOnly and slots[runOnly] or nil
end

local function refreshLayout(force : boolean?)
	if not gui then return end

	local jump = findJumpButton()
	if not jump or not isShown(jump) or not Run.humanoid then
		gui.Enabled = false
		hideAll()
		layout.key = nil
		return
	end

	gui.Enabled = true

	local jumpSize = math.min(jump.AbsoluteSize.X, jump.AbsoluteSize.Y)
	local jumpCenter = jump.AbsolutePosition + jump.AbsoluteSize / 2
	local key = `{math.round(jumpCenter.X)}:{math.round(jumpCenter.Y)}:{jumpSize}:{gui.AbsoluteSize.X}:{gui.AbsoluteSize.Y}`

	layout.size = math.round(jumpSize * BUTTON_SCALE)
	layout.gap = math.max(MIN_GAP, math.round(jumpSize * GAP_SCALE))

	-- Nada mudou de tamanho: se as vagas atuais continuam livres, fica tudo onde esta,
	-- sem o botao pular de lugar a toa.
	if not force and key == layout.key and layout.placed.Dash and layout.placed.Run then
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

	local dashCenter, runCenter = solve(jumpCenter, jumpSize, buildSlots(jumpCenter, jumpSize, layout.size, layout.gap))
	applyPlacement("Dash", dashCenter)
	applyPlacement("Run", runCenter)
end

--[[ LIFECYCLE ]]

function module:begin(character)
	-- Aparelho sem toque nunca tem botao de pulo; nao ha o que montar.
	if not UserInputService.TouchEnabled then return end

	self:stop()

	if not ensureGui() then return end

	setRunVisual(Run.isRunning)
	table.insert(connections, Run.Changed.Event:Connect(setRunVisual))

	local elapsed = math.huge
	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		updateDashCooldown()

		elapsed += dt
		local interval = (layout.placed.Dash and layout.placed.Run) and CHECK_INTERVAL or HIDDEN_CHECK_INTERVAL
		if elapsed < interval then return end
		elapsed = 0

		refreshLayout()
	end))

	-- Girar a tela ou trocar o tamanho do pulo pede a busca na hora.
	table.insert(connections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		refreshLayout(true)
	end))
end

function module:stop()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	if gui then
		gui.Enabled = false
		hideAll()
		layout.key = nil
	end
end

return module
