local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local PhysicsService = game:GetService("PhysicsService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Classes = Shared:WaitForChild("Classes")
local Utils = Shared:WaitForChild("Util")

local UIAssets = Assets:WaitForChild("UI")

local Units = Assets:WaitForChild("Units")

local UnitClass = require(Classes.Unit)

local SharedConfig = require(Configs.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local ClientConfig = require(Configs.Client)
local PointerUtil = require(Utils.PointerUtil)
local PlacementUtil = require(Utils.PlacementUtil)
local GameClock = require(Utils.GameClock)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()
local Player = Players.LocalPlayer

local LERP_SPEED = 14
-- Teto do encosta-no-chao de `replicatePlacedUnit`. Um stud cobre a diferenca de
-- escala entre o fantasma e a unidade de verdade; acima disso o "acerto" seria a
-- unidade mudando de lugar por conta propria.
local MAX_GROUND_SNAP = 1
local VALID_COLOR = Color3.fromRGB(0, 255, 0)
local INVALID_COLOR = Color3.fromRGB(255, 0, 0)
local COLOR_LERP_SPEED = 10

-- Log de posicionamento: so no Studio, para nao poluir o console de producao.
local IS_STUDIO = RunService:IsStudio()

local function placementPrint(...)
	if not IS_STUDIO then return end
	print("[UnitPlacement]", ...)
end

local function formatVector(v : Vector3?)
	if not v then return "nil" end
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

--[=[
	A superficie que o raycast do posicionamento acertou, para o log: caminho
	completo e classe.

	A classe vai junto porque `GetFullName` sozinho nao distingue uma Part de um
	MeshPart nem, principalmente, avisa que o alvo e o proprio `Terrain` -- que e
	um acerto comum, ja que boa parte dos mapas tem chao esculpido, e que aparece
	como uma instancia so para o mapa inteiro.
]=]
local function describeSurface(instance : Instance?) : string
	if not instance then
		return "nada (o ponteiro nao acertou superficie nenhuma)"
	end

	return string.format("%s (%s)", instance:GetFullName(), instance.ClassName)
end

--[=[
	`base` mais o personagem de todo jogador que estiver no servidor.

	E a lista de exclusao do teste generico de obstrucao: personagem nao entra nele,
	porque quem responde por personagem e o `FindBlockingCharacter` -- com a caixa da
	unidade inteira e com a regra de pular acessorio, que e o que o servidor tambem
	faz. Duas listas em vez de uma porque o raycast do chao continua excluindo so o
	fantasma e o proprio jogador: mirar em cima de outro jogador ainda apoia o
	fantasma nele, e e o `FindBlockingCharacter` que pinta aquilo de vermelho.
]=]
local function characterFilter(base : { Instance }) : { Instance }
	local list = table.clone(base)

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character and not table.find(list, character) then
			table.insert(list, character)
		end
	end

	return list
end

--[=[
	O grupo de colisao do fantasma, ou `nil` se ele ainda nao existir aqui.

	Quem registra e o `CollisionService`, no servidor, e o registro replica. Perguntar
	antes de escrever e o que separa "o servico nao subiu" de um erro no meio do
	posicionamento: `CollisionGroup` com nome nao registrado estoura, e estourar aqui
	levaria o fantasma inteiro junto.
]=]
local function getGhostCollisionGroup() : string?
	local group = PlacementUtil.GhostCollisionGroup

	local ok, registered = pcall(function()
		return PhysicsService:IsCollisionGroupRegistered(group)
	end)

	if ok and registered then
		return group
	end

	placementPrint("grupo de colisao", group, "nao registrado; fantasma so com CanCollide = false")

	return nil
end

--[=[
	O Humanoid do fantasma, injetado na hora quando o rig nao traz um.

	Os rigs das unidades sao R6 montados a mao -- MeshParts penduradas por Motor6D
	numa HumanoidRootPart ancorada -- e nenhum deles guarda um Humanoid: quem toca a
	animacao da unidade de verdade e o `AnimationController` que a classe `Unit`
	cria, e o rig parado nao precisa de nada alem das juntas.

	O fantasma precisa. Por um bug antigo da engine, Highlight nao renderiza em part
	transparente quando o modelo nao tem Humanoid -- e o fantasma e meio transparente
	por natureza. Sem ele o modelo aparece nas cores normais e some justamente o
	verde/vermelho que diz se da para colocar ali.

	Entao ele entra calado. `EvaluateStateMachine = false` porque e a maquina de
	estado quem manda na colisao de um personagem: ao entrar num estado novo
	(Running, Landed...) ela religa o `CanCollide` do torso e desfaz o laco de
	`visualize`. E os dois displays saem para o nome do modelo e a barra de vida nao
	flutuarem sobre o fantasma, que e o unico rastro que um Humanoid recem-criado
	deixaria na tela.
]=]
local function prepareGhostHumanoid(ghost : Model) : Humanoid
	local humanoid = ghost:FindFirstChildOfClass("Humanoid") or Instance.new("Humanoid")

	-- Tudo configurado antes de parentear: e o parenteamento no workspace que
	-- dispara a primeira avaliacao, e ela ja tem que achar a maquina desligada.
	humanoid.EvaluateStateMachine = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	-- O rig nao e personagem: nao ha pescoco a vigiar nem morte a encenar, e um
	-- Humanoid que se der por morto desmonta as juntas e derruba o fantasma.
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = ghost

	return humanoid
end

local TILT_MAX = math.rad(16)
local TILT_PER_STUD = 0.08
local TILT_LERP_SPEED = 10

local RING_SPIN_SPEED = 40
local DOTTED_LINE_SPIN_SPEED = 25
local SELECT_SCALE = 1.3

-- Como o caminho fica marcado enquanto o jogador posiciona uma unidade.
local GRID_PREVIEW_COLOR = Color3.fromRGB(255, 0, 0)
local GRID_PREVIEW_MATERIAL = Enum.Material.Neon

--[[
	A entrada e em cascata, e o que se configura e o TEMPO TOTAL dela — nao o
	intervalo entre parts. O intervalo sai da divisao pela quantidade de parts do
	mapa carregado, entao a animacao dura o mesmo no Default (5 parts) e no
	Mountain (206), em vez de esticar de 0.25s para 10s conforme o mapa.

	GRID_PAINT_TOTAL_TIME conta do inicio ate a ultima part terminar de ficar
	vermelha, ou seja, ja inclui o tween final.
]]
local GRID_PAINT_TOTAL_TIME = 0.75
local GRID_PAINT_TIME = 0.25

local function getPaintStagger(count : number)
	if count <= 1 then
		return 0
	end
	return math.max(0, GRID_PAINT_TOTAL_TIME - GRID_PAINT_TIME) / (count - 1)
end

--[[
	Aparencia original das parts do caminho, guardada na primeira vez que cada uma
	e pintada e devolvida quando o posicionamento acaba.

	Chaves fracas: o mapa pode ser trocado entre rounds, e as parts do mapa antigo
	nao devem ficar presas aqui.
]]
local gridOriginals = setmetatable({}, { __mode = "k" })

local cachedGridParts = nil

local function invalidateGridParts()
	cachedGridParts = nil
end

--[[
	Parts do caminho do mapa que esta carregado, e so dele.

	O escopo e o clone que o MapService coloca em `workspace.Map`. `GetTagged("Grid")`
	sozinho devolve tambem as parts dos outros mapas, que seguem em
	ReplicatedStorage — hoje sao mais de 500 no total, de cinco mapas.

	O resultado e calculado uma vez por mapa e reaproveitado em todo
	posicionamento; o cache cai no RoundRestarted, quando o mapa pode ter mudado.
]]
local function getWorldGridParts()
	if cachedGridParts then
		return cachedGridParts
	end

	local mapRoot = workspace:FindFirstChild("Map")

	local parts = {}
	for _, part in CollectionService:GetTagged("Grid") do
		if part:IsA("BasePart") and part:IsDescendantOf(mapRoot or workspace) then
			table.insert(parts, part)
		end
	end

	-- Sem o mapa em workspace a lista pode estar incompleta (replicacao a caminho),
	-- entao ela nao e guardada — senao um vazio ficaria congelado para sempre.
	if mapRoot then
		cachedGridParts = parts
	end

	return parts
end

-- Cascata em andamento e os tweens de cor vivos, para poder cortar os dois na
-- hora em que o jogador larga a unidade.
local gridPaintThread = nil
local gridTweens = {}

local function stopGridPaint()
	if gridPaintThread then
		pcall(task.cancel, gridPaintThread)
		gridPaintThread = nil
	end

	for part, tween in gridTweens do
		tween:Cancel()
		gridTweens[part] = nil
	end
end

-- Acende uma part: Material de uma vez, cor por tween.
local function paintOneGridPart(part)
	if not part.Parent then
		return
	end

	-- Capturado no momento em que a part entra: quem a cascata ainda nao
	-- alcancou continua intocado e sem snapshot.
	if not gridOriginals[part] then
		gridOriginals[part] = { material = part.Material, color = part.Color }
	end

	part.Material = GRID_PREVIEW_MATERIAL

	local tween = TweenService:Create(
		part,
		TweenInfo.new(GRID_PAINT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Color = GRID_PREVIEW_COLOR }
	)

	gridTweens[part] = tween
	tween.Completed:Once(function()
		if gridTweens[part] == tween then
			gridTweens[part] = nil
		end
	end)
	tween:Play()
end

--[[
	Acende o caminho em cascata: cada part troca para Neon e puxa a cor ate o
	vermelho por tween, escalonadas para caber em GRID_PAINT_TOTAL_TIME.

	O avanco e por tempo decorrido, e nao um `task.wait(intervalo)` por part. Com
	107 parts em 0.75s o intervalo da ~0.005s, bem abaixo de um frame — e
	`task.wait` sempre gasta um frame inteiro, o que faria a cascata levar 107
	frames (~1.8s) em vez dos 0.75s pedidos. Aqui cada frame pinta todas as parts
	cujo horario ja chegou, o que tambem e o que produz a sensacao de batch.

	O Material nao da para interpolar (e enum), entao ele troca de uma vez no
	instante em que a part entra — e isso que a faz "acender". So a cor anda.
]]
local function paintGridParts(parts)
	stopGridPaint()

	local total = #parts
	if total == 0 then
		return
	end

	local stagger = getPaintStagger(total)

	gridPaintThread = task.spawn(function()
		local startedAt = os.clock()
		local nextIndex = 1

		while nextIndex <= total do
			local elapsed = os.clock() - startedAt

			while nextIndex <= total and (nextIndex - 1) * stagger <= elapsed do
				paintOneGridPart(parts[nextIndex])
				nextIndex += 1
			end

			if nextIndex <= total then
				RunService.Heartbeat:Wait()
			end
		end

		gridPaintThread = nil
	end)
end

--[[
	Volta tudo de uma vez, sem tween.

	A cascata e os tweens de cor sao cortados primeiro: um tween sobrevivente
	continuaria escrevendo Color depois da restauracao e deixaria a part vermelha.
]]
local function restoreGridParts(parts)
	stopGridPaint()

	for _, part in parts do
		local original = gridOriginals[part]
		if original then
			if part.Parent then
				part.Material = original.material
				part.Color = original.color
			end
			gridOriginals[part] = nil
		end
	end
end

local TILT_MAX = math.rad(16)
local TILT_PER_STUD = 0.08
local TILT_LERP_SPEED = 10

local function setDottedLineVisible(dottedLine, visible)
	if not dottedLine then return end
	for _, child in dottedLine:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "BlueCircle" then
			child.Transparency = visible and 0 or 1
		end
		if child.Name == "BlueCircle" then
			local gui = child:FindFirstChild("SurfaceGUI")
			if gui then
				local star = gui:FindFirstChild("Star")
				if star then star.Visible = visible end
			end
		end
	end
end

local function tweenRingOut(ring)
	if not ring or not ring.Parent then return end
	local currentScale = ring:GetScale()
	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = currentScale
	scaleVal.Changed:Connect(function(v)
		if ring and ring.Parent then ring:ScaleTo(v) end
	end)
	local tween = TweenService:Create(
		scaleVal,
		TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Value = 0.001 }
	)
	tween:Play()
	tween.Completed:Connect(function()
		scaleVal:Destroy()
		if ring and ring.Parent then ring:Destroy() end
	end)
end

--[[
	Altura do chao debaixo de um ponto.

	As parts do caminho contam como chao aqui, e nao sao filtradas: elas sao o piso
	visivel da trilha. Ignora-las fazia o raio atravessar o trilho e parar no bloco
	de baixo — uma unidade aceita no ar (na quina de uma ponte, na face de uma
	pedra) era entao DESENHADA de pe em cima do caminho, longe do CFrame que o
	servidor guardou e usa para mirar.
]]
local function raycastGroundY(position : Vector3, excludeInstances : {Instance}?)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = excludeInstances or {}

	-- O raio parte do proprio ponto, nao de um ponto acima dele: o que interessa e
	-- o chao EMBAIXO da unidade. Comecando la em cima, a primeira coisa atingida
	-- passa a ser qualquer coisa que estiver por cima — a copa de uma arvore, uma
	-- saliencia de rocha — e a unidade era erguida ate la.
	local result = workspace:Raycast(position, Vector3.new(0, -1000, 0), raycastParams)
	if result then
		return result.Position.Y
	end

	return nil
end

--[[
	Controles de posicionamento para quem joga no toque.

	No PC o fluxo inteiro cabe no mouse: o fantasma segue o cursor, R gira e o
	clique confirma. No celular nao ha cursor para seguir nem tecla para girar, e
	confirmar no proprio toque seria pior ainda -- o dedo tapa justamente o ponto
	onde a unidade vai nascer, e o jogador colocaria a torre sem ver o circulo de
	alcance nem a cor do fantasma.

	Entao o toque no mapa so MOVE o fantasma, e a confirmacao vem daqui. Os botoes
	ficam no canto direito: o canto esquerdo de baixo e o direcional de movimento
	do Roblox e o centro de baixo e a barra de cartas.

	Tudo aqui e em escala, nao em pixel: a mesma medida em offset que da um botao
	confortavel num tablet vira um alvo minusculo num celular estreito. Os limites
	de tamanho existem so para os extremos -- um alvo de toque nao pode encolher
	abaixo do dedo nem virar um cartaz numa tela grande.
]]
local TOUCH_PANEL_SIZE = UDim2.fromScale(0.2, 0.46)
local TOUCH_PANEL_POSITION = UDim2.fromScale(0.98, 0.78)
-- O minimo sai de tras para frente: 190px de altura e o que faz cada botao passar
-- de ~49px, que e o alvo de toque confortavel numa tela de celular deitado.
local TOUCH_PANEL_MIN_SIZE = Vector2.new(140, 190)
local TOUCH_PANEL_MAX_SIZE = Vector2.new(280, 320)

local TOUCH_BUTTON_SIZE = UDim2.fromScale(1, 0.26)
local TOUCH_BUTTON_MAX_TEXT = 22
local TOUCH_HINT_SIZE = UDim2.fromScale(1, 0.16)
local TOUCH_HINT_MAX_TEXT = 15

local TOUCH_CONFIRM_COLOR = Color3.fromRGB(60, 175, 85)
local TOUCH_CONFIRM_BLOCKED_COLOR = Color3.fromRGB(95, 100, 105)
local TOUCH_ROTATE_COLOR = Color3.fromRGB(55, 105, 190)
local TOUCH_CANCEL_COLOR = Color3.fromRGB(185, 60, 60)

local function createTouchButton(text : string, color : Color3, order : number)
	local button = Instance.new("TextButton")
	button.Name = text
	button.Size = TOUCH_BUTTON_SIZE
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Text = text
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextScaled = true
	button.Font = Enum.Font.GothamBold
	button.LayoutOrder = order

	-- TextScaled sozinho estica a fonte ate encostar nas bordas; o teto segura o
	-- texto num tamanho de leitura e deixa a sobra virar respiro.
	local textSize = Instance.new("UITextSizeConstraint")
	textSize.MaxTextSize = TOUCH_BUTTON_MAX_TEXT
	textSize.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0.08, 0)
	padding.PaddingRight = UDim.new(0.08, 0)
	padding.Parent = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.18, 0)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(15, 15, 20)
	stroke.Thickness = 2
	stroke.Transparency = 0.35
	stroke.Parent = button

	return button
end

--[=[
	Monta o painel e devolve a ScreenGui junto do botao de confirmar, que o loop de
	posicionamento apaga e acende conforme o lugar aceita a unidade ou nao.
]=]
local function createTouchControls(onRotate : () -> (), onConfirm : () -> (), onCancel : () -> ())
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "UnitPlacementTouch"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	-- Acima da HUD: o painel so existe enquanto ha unidade em mao, e nesse momento
	-- ele e o que o jogador precisa alcancar.
	screenGui.DisplayOrder = 100
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local container = Instance.new("Frame")
	container.Name = "Buttons"
	container.AnchorPoint = Vector2.new(1, 1)
	container.Position = TOUCH_PANEL_POSITION
	container.Size = TOUCH_PANEL_SIZE
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	local sizeLimits = Instance.new("UISizeConstraint")
	sizeLimits.MinSize = TOUCH_PANEL_MIN_SIZE
	sizeLimits.MaxSize = TOUCH_PANEL_MAX_SIZE
	sizeLimits.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.02, 0)
	layout.Parent = container

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.Size = TOUCH_HINT_SIZE
	hint.BackgroundTransparency = 1
	hint.Text = "Tap the map\nto move"
	hint.TextColor3 = Color3.fromRGB(255, 255, 255)
	hint.TextScaled = true
	hint.Font = Enum.Font.GothamMedium
	hint.LayoutOrder = 0
	hint.Parent = container

	local hintTextSize = Instance.new("UITextSizeConstraint")
	hintTextSize.MaxTextSize = TOUCH_HINT_MAX_TEXT
	hintTextSize.Parent = hint

	local hintStroke = Instance.new("UIStroke")
	hintStroke.Color = Color3.fromRGB(0, 0, 0)
	hintStroke.Thickness = 2
	hintStroke.Transparency = 0.2
	hintStroke.Parent = hint

	local rotateButton = createTouchButton("ROTATE", TOUCH_ROTATE_COLOR, 1)
	rotateButton.Parent = container
	rotateButton.Activated:Connect(onRotate)

	local confirmButton = createTouchButton("PLACE", TOUCH_CONFIRM_COLOR, 2)
	confirmButton.Parent = container
	confirmButton.Activated:Connect(onConfirm)

	local cancelButton = createTouchButton("CANCEL", TOUCH_CANCEL_COLOR, 3)
	cancelButton.Parent = container
	cancelButton.Activated:Connect(onCancel)

	screenGui.Parent = Player:WaitForChild("PlayerGui")

	return screenGui, confirmButton
end

local UnitPlacementController = {
	Controllers = {
		TargetingController = {},
		UILibraryController = {},
		CardController = {},
		VFXController = {},
		MobController = {},
		MusicController = {},
		WeatherController = {},
		WeatherFeedbackController = {}
	},
	selectedUnit = nil,
	selectionHighlight = nil,
	selectionData = nil
}
UnitPlacementController.createdClasses = {}
UnitPlacementController.classesById = {}
UnitPlacementController.unitDottedLines = {}
UnitPlacementController.dottedLineData = {}
UnitPlacementController.scaleTweens = {}
UnitPlacementController.isPlacing = false
-- Dano total por unitId. Guardado fora do modelo porque o lote do servidor pode
-- chegar antes de `ReplicateUnit` criar a unidade.
UnitPlacementController.damageDoneById = {}

function UnitPlacementController:getGroundExcludeList(extra)
	local list = {}
	for unitModel, _ in pairs(self.createdClasses) do
		table.insert(list, unitModel)
	end
	if extra then
		for _, inst in extra do
			table.insert(list, inst)
		end
	end
	return list
end

function UnitPlacementController:tweenUnitScale(unitModel, targetScale, easingDirection)
	local existing = self.scaleTweens[unitModel]
	if existing then
		existing.tween:Cancel()
		existing.value:Destroy()
		self.scaleTweens[unitModel] = nil
	end

	if not unitModel or not unitModel.Parent then return end

	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = unitModel:GetScale()
	scaleVal.Changed:Connect(function(v)
		if unitModel and unitModel.Parent then unitModel:ScaleTo(v) end
	end)

	local tween = TweenService:Create(scaleVal, TweenInfo.new(0.18, Enum.EasingStyle.Back, easingDirection), { Value = targetScale })
	self.scaleTweens[unitModel] = { tween = tween, value = scaleVal }
	tween.Completed:Connect(function()
		local current = self.scaleTweens[unitModel]
		if current and current.tween == tween then
			self.scaleTweens[unitModel] = nil
		end
		scaleVal:Destroy()
	end)
	tween:Play()
end

function UnitPlacementController:deselectCurrent()
	if self.selectedUnit and self.selectedOriginalScale and self.selectedUnit.Parent then
		self:tweenUnitScale(self.selectedUnit, self.selectedOriginalScale, Enum.EasingDirection.In)
	end
	self.selectedOriginalScale = nil

	if self.selectionHighlight then
		self.selectionHighlight:Destroy()
		self.selectionHighlight = nil
	end

	if self.selectionRingTween then
		self.selectionRingTween.tween:Cancel()
		self.selectionRingTween.value:Destroy()
		self.selectionRingTween = nil
	end
	self.selectionRing = nil
	self.selectionRingBase = nil

	if self.ringSpinConn then
		self.ringSpinConn:Disconnect()
		self.ringSpinConn = nil
	end

	if self.dottedLineSpinConn then
		self.dottedLineSpinConn:Disconnect()
		self.dottedLineSpinConn = nil
	end

	if self.AOE then
		for _, inst in self.AOE do
			tweenRingOut(inst)
		end
		table.clear(self.AOE)
	end

	if self.selectedUnit then
		local dottedLine = self.unitDottedLines[self.selectedUnit]
		setDottedLineVisible(dottedLine, false)
	end

	self.selectedUnit = nil

	self.Controllers.UILibraryController:doComponent("ToggleTower", "destroy")
end

--[=[
	Alcance de uma unidade com o clima do momento aplicado.

	O circulo no chao tem que mostrar o alcance de verdade: durante a neblina a
	unidade procura alvo num raio menor, e um circulo desenhado no alcance seco
	prometeria uma cobertura que ela nao tem. E a mesma funcao que o servidor usa,
	so que com o clima que este cliente esta vendo.
]=]
function UnitPlacementController:getUnitRange(unitName : string, upgrades : number) : number
	local weatherController = self.Controllers.WeatherController
	local weather = weatherController and weatherController:GetCurrent() or nil

	return SharedConfig.UnitUpgradeConfig:GetRange(unitName, upgrades, weather)
end

--[=[
	Refaz o circulo da unidade selecionada a partir do alcance atual dela.

	Chamado quando o alcance muda por baixo do jogador — um upgrade comprado ou uma
	troca de clima. Sem unidade selecionada (ou sem circulo na tela) nao faz nada.
]=]
function UnitPlacementController:resizeSelectionRing()
	local unitModel = self.selectedUnit
	if not unitModel or not unitModel.Parent then return end
	if not self.selectionRing or not self.selectionRing.Parent then return end
	if not self.selectionRingBase then return end

	local range = self:getUnitRange(unitModel.Name, unitModel:GetAttribute("Upgrades") or 0)
	local scale = self.selectionRingBase.scale * (range * 2) / self.selectionRingBase.diameter

	self:tweenSelectionRing(scale)
end

function UnitPlacementController:tweenSelectionRing(targetScale)
	local ring = self.selectionRing
	if not ring or not ring.Parent then return end

	if self.selectionRingTween then
		self.selectionRingTween.tween:Cancel()
		self.selectionRingTween.value:Destroy()
		self.selectionRingTween = nil
	end

	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = ring:GetScale()
	scaleVal.Changed:Connect(function(v)
		if ring and ring.Parent then ring:ScaleTo(v) end
	end)

	local tween = TweenService:Create(scaleVal, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = targetScale })
	self.selectionRingTween = { tween = tween, value = scaleVal }
	tween.Completed:Connect(function()
		local current = self.selectionRingTween
		if current and current.tween == tween then
			self.selectionRingTween = nil
		end
		scaleVal:Destroy()
	end)
	tween:Play()
end

function UnitPlacementController:selectUnit(unitModel)
	if self.selectedUnit == unitModel then
		self:deselectCurrent()
		return
	end

	self:deselectCurrent()

	self.selectedUnit = unitModel

	local baseScale = unitModel:GetAttribute("BaseScale")
	if not baseScale then
		baseScale = unitModel:GetScale()
		unitModel:SetAttribute("BaseScale", baseScale)
	end
	self.selectedOriginalScale = baseScale
	self:tweenUnitScale(unitModel, baseScale * SELECT_SCALE, Enum.EasingDirection.Out)

	local dottedLine = self.unitDottedLines[unitModel]
	setDottedLineVisible(dottedLine, true)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(0, 255, 0)
	highlight.OutlineColor = Color3.fromRGB(0, 255, 0)
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.6
	highlight.Parent = unitModel
	self.selectionHighlight = highlight

	self.Controllers.UILibraryController:doComponent("ToggleTower", "create", unitModel)

	self.AOE = {}

	local unitPos = unitModel:GetPivot().Position
	local groundSurfaceY = raycastGroundY(unitPos, self:getGroundExcludeList({unitModel})) or unitPos.Y

	local Ring = UIAssets.AOE.Ring:Clone()
	local ringPartSel = Ring:FindFirstChild("Renge")
	local targetScale = Ring:GetScale()

	if ringPartSel then
		local upgrades = unitModel:GetAttribute("Upgrades") or 0
		local unitRange = self:getUnitRange(unitModel.Name, upgrades)
		local currentDiameter = ringPartSel.Size.X
		local scaleFactor = (unitRange * 2) / currentDiameter
		targetScale = Ring:GetScale() * scaleFactor
		self.selectionRingBase = { scale = Ring:GetScale(), diameter = currentDiameter }
	end

	Ring:ScaleTo(0.001)
	Ring:PivotTo(CFrame.new(unitPos.X, groundSurfaceY + Ring:GetExtentsSize().Y / 2, unitPos.Z))
	Ring.Parent = workspace.CurrentCamera
	self.selectionRing = Ring

	self:tweenSelectionRing(targetScale)

	local ringYAngle = 0
	self.ringSpinConn = RunService.Heartbeat:Connect(function(dt)
		if not Ring or not Ring.Parent then return end
		ringYAngle = ringYAngle + RING_SPIN_SPEED * dt
		Ring:PivotTo(CFrame.new(unitPos.X, groundSurfaceY + Ring:GetExtentsSize().Y / 2, unitPos.Z) * CFrame.Angles(0, math.rad(ringYAngle), 0))
	end)

	local data = self.dottedLineData[unitModel]
	if dottedLine and data then
		self.dottedLineSpinConn = RunService.Heartbeat:Connect(function(dt)
			if not dottedLine or not dottedLine.Parent then return end
			data.angle += DOTTED_LINE_SPIN_SPEED * dt
			local rot = CFrame.Angles(0, math.rad(data.angle), 0)
			for _, entry in data.dotParts do
				local rotatedOffset = rot * entry.offset
				entry.part.CFrame = CFrame.new(data.centerPos + rotatedOffset) * entry.baseCF * rot
			end
			if data.blueCircle and data.blueCircleCF then
				data.blueCircle.CFrame = data.blueCircleCF
			end
		end)
	end

	table.insert(self.AOE, Ring)

	self.Controllers.MusicController:PlaySFX("SelectSound")
end

function UnitPlacementController:replicatePlacedUnit(unitName : string, CF : CFrame, ownerUserId : number, unitId : string, upgrades : number, priority : string?)
	local unitModel = Units:FindFirstChild(unitName)
	if not unitModel then return end

	local unit = unitModel:Clone()

	for _, descendant in unit:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end

	local humanoid = unit:FindFirstChild("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end

	unit:PivotTo(CF or CFrame.new())
	unit.Parent = workspace

	--[[
		Encosta a unidade no chao. O ajuste e de acerto fino: o cliente calcula a
		altura do fantasma com o modelo em escala reduzida, entao a unidade de
		tamanho cheio nasce uns 20 cm enterrada.

		Dai o teto: quem manda na posicao e o servidor, e um "acerto" de metros nao
		e acerto nenhum — e a unidade indo parar em outro lugar. Acontecia quando o
		raio saia de dentro de alguma geometria (a quina da ponte em que a unidade
		foi largada): sem nada para acertar por perto, ele descia ate o chao la
		embaixo e a unidade era desenhada de pe no meio do caminho, enquanto o
		servidor continuava mirando a partir de onde ela foi largada de verdade.
	]]
	local boundsCF, boundsSize = unit:GetBoundingBox()
	local bottomY = boundsCF.Position.Y - boundsSize.Y / 2
	local groundSurfaceY = raycastGroundY(boundsCF.Position, self:getGroundExcludeList({unit}))
	if groundSurfaceY then
		local lift = groundSurfaceY - bottomY
		if math.abs(lift) > MAX_GROUND_SNAP then
			placementPrint(unitName, "correcao de chao ignorada:", string.format("%.2f studs", lift),
				"maior que o limite de", string.format("%.2f", MAX_GROUND_SNAP))
			groundSurfaceY = bottomY
		elseif math.abs(lift) > 0.001 then
			unit:PivotTo((CF or CFrame.new()) + Vector3.new(0, lift, 0))
		end
	else
		groundSurfaceY = bottomY
	end

	local unitPos = unit:GetPivot().Position

	placementPrint(unitName, "unidade posicionada em", formatVector(unitPos),
		"(CFrame do servidor:", formatVector(CF and CF.Position) .. ")",
		"dono", ownerUserId, "unitId", unitId)

	local DottedLine = UIAssets.AOE.DottedLine:Clone()
	local dottedPivot = DottedLine:GetPivot()
	DottedLine:PivotTo(CFrame.new(unitPos.X, groundSurfaceY, unitPos.Z) * dottedPivot.Rotation)
	local isOwner = ownerUserId == Player.UserId

	local blueCircle = DottedLine:FindFirstChild("BlueCircle")
	if blueCircle then
		blueCircle.CFrame = CFrame.new(unitPos.X, groundSurfaceY + blueCircle.Size.X / 2, unitPos.Z) * CFrame.Angles(0, 0, math.pi / 2)

		--[[
			O disco azul e a marca de "esta e sua": ele fica aceso o tempo todo, fora
			do liga-desliga que a linha pontilhada leva na selecao. So faz sentido
			embaixo das unidades deste jogador — no chao de uma partida cheia, um
			disco embaixo de cada unidade de cada um vira ruido e some com a marca.
		]]
		if not isOwner then
			blueCircle.Transparency = 1
		end
	end
	DottedLine.Parent = workspace.CurrentCamera
	setDottedLineVisible(DottedLine, false)
	self.unitDottedLines[unit] = DottedLine

	local centerPos = Vector3.new(unitPos.X, groundSurfaceY, unitPos.Z)
	local dotParts = {}
	for _, child in DottedLine:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "BlueCircle" then
			local offset = child.CFrame.Position - centerPos
			table.insert(dotParts, { part = child, offset = offset, baseCF = child.CFrame - child.CFrame.Position })
		end
	end
	self.dottedLineData[unit] = {
		angle = 0,
		blueCircleCF = blueCircle and blueCircle.CFrame or nil,
		blueCircle = blueCircle,
		centerPos = centerPos,
		dotParts = dotParts,
	}

	local class = UnitClass.new(unitName, unit)
	class.unitId = unitId
	class.isOwner = isOwner
	class.upgrades = upgrades or 0
	unit:SetAttribute("UnitID", unitId)
	unit:SetAttribute("Upgrades", upgrades or 0)
	-- A prioridade viaja em atributo pelo mesmo motivo que o nivel: quem precisa
	-- dela — o card, que escreve o nome no botao, e o TargetingController, que gira
	-- a unidade — le do modelo, sem passar por controller nenhum.
	unit:SetAttribute("TargetPriority", TargetPriority.Get(priority))
	unit:SetAttribute("Owned", class.isOwner)
	-- Total de dano da unidade; o servidor atualiza por `UnitDamageStats` e o card
	-- de upgrade escuta o atributo.
	unit:SetAttribute("DamageDone", self.damageDoneById[unitId] or 0)
	self.createdClasses[unit] = class
	self.classesById[unitId] = class

	local unitStats = SharedConfig.UnitStats[unitName]
	local skipTargeting = unitStats and (unitStats.Farm ~= nil or unitStats.Tripmine ~= nil)
	if not skipTargeting and self.Controllers.TargetingController and self.Controllers.TargetingController.RegisterUnit then
		self.Controllers.TargetingController:RegisterUnit(class)
	end

	if self.Controllers.VFXController then
		self.Controllers.VFXController:Trigger(unitName, "OnPlace", { unitModel = unit })
	end

	-- Quem nasce no meio de um clima ja nasce com o realce e a billboard dele.
	if self.Controllers.WeatherFeedbackController then
		self.Controllers.WeatherFeedbackController:Register(unit)
	end

	self.Controllers.MusicController:PlaySFX("UnitPlace")
end

function UnitPlacementController:visualize(unitName : string)
	if self.isPlacing then
		placementPrint(unitName, "nao pode posicionar: ja existe um fantasma ativo")
		return
	end
	local unitModel = Units:FindFirstChild(unitName)
	if not unitModel then
		placementPrint(unitName, "nao pode posicionar: modelo nao existe em Assets.Units")
		return
	end
	self.isPlacing = true

	local maid = Maid.new()
	self._maid = maid
	local ghost = unitModel:Clone()
	local currentRotation = 0
	local currentColor = VALID_COLOR
	local canPlace = false
	-- Guardado so para o log do Studio dizer o motivo do bloqueio.
	local blockReason = "ponteiro fora de qualquer superficie"

	--[[
		A superficie em que o fantasma esta apoiado, so para o log de quando a
		unidade e enviada.

		Anda junto com o `targetCF`: os dois so mudam dentro do `if raycastResult`,
		entao o que o log diz e a superficie daquele CFrame, e nao a ultima que o
		ponteiro tocou por acaso.
	]]
	local groundInstance : Instance? = nil

	--[[
		No toque o fantasma nao segue o dedo: ele fica no ultimo ponto tocado e so
		sai dali no proximo toque, e quem confirma e o botao do painel.

		Ele nasce no centro da tela porque e para la que a camera esta olhando -- o
		jogador ve a unidade e o circulo de alcance de cara, em vez de um fantasma
		perdido na origem do mundo enquanto nao encosta na tela.
	]]
	local isTouch = PointerUtil.isTouchOnly()
	local touchTarget : Vector2? = if isTouch then workspace.CurrentCamera.ViewportSize / 2 else nil
	local touchConfirmButton : TextButton? = nil

	local scale = ghost:GetScale()
	ghost:ScaleTo(scale * 0.8)

	--[[
		O fantasma nao colide com nada, e isso custa tres cuidados.

		**O grupo de colisao** e quem resolve de verdade: part num grupo declarado
		nao-colidivel com todos os outros nao colide, ponto. Quem registra o grupo e o
		`CollisionService`, no servidor -- `RegisterCollisionGroup` nao roda no
		cliente. Registro que nao chegou nao vira erro: o fantasma so fica com os
		outros dois cuidados, que e como ele vinha antes do grupo existir.

		**O `CanCollide = false`** continua sendo feito, como plano B do acima.

		**O Humanoid** e cuidado do `prepareGhostHumanoid`: os rigs de hoje nao trazem
		um, e sem Humanoid o Highlight nao pinta part transparente -- o fantasma
		ficaria sem o verde/vermelho. Ele entra com a maquina de estado desligada,
		antes de o modelo ir para o workspace.

		As perguntas de posicionamento nao mudam de resposta por causa do grupo: elas
		sao feitas com `OverlapParams` no grupo `Default`, e e o grupo do *params* que
		vale, nao o da part consultada.
	]]
	local ghostHumanoid = prepareGhostHumanoid(ghost)

	local ghostGroup = getGhostCollisionGroup()

	for _, descendant in pairs(ghost:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false

			-- Part invisivel continua invisivel. A HumanoidRootPart dos rigs novos e
			-- uma caixa opaca de 0.76 stud que so nao aparece porque esta em
			-- Transparency = 1; pintada de 0.5 ela vira um bloco dentro do fantasma,
			-- estourando pelo torso das unidades mais magras.
			if descendant.Transparency < 1 then
				descendant.Transparency = 0.5
			end

			if ghostGroup then
				descendant.CollisionGroup = ghostGroup
			end
		end
	end

	--[[
		A animacao nao depende da maquina de estado: quem toca a faixa e o Animator,
		e a faixa e pedida na mao aqui.

		O Animator vai no Humanoid injetado, e nao num `AnimationController` como faz
		a classe `Unit`. Os dois tocam igual, e o Humanoid ja esta ali de qualquer
		forma pelo Highlight -- somar um AnimationController seria um segundo dono de
		faixa no mesmo modelo, sem nada em troca.
	]]
	local animator = ghostHumanoid:FindFirstChildWhichIsA("Animator") or Instance.new("Animator")
	animator.Parent = ghostHumanoid

	local idleAnim = ghost:FindFirstChild("Idle")
	if idleAnim and idleAnim:IsA("Animation") then
		local track = animator:LoadAnimation(idleAnim)
		track:Play()
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.3
	highlight.FillColor = VALID_COLOR
	highlight.OutlineColor = VALID_COLOR
	highlight.Parent = ghost
	ghost.Parent = workspace

	local unitStats = SharedConfig.UnitStats[unitName]
	local unitRange = unitStats and unitStats.Range or 10
	local ghostBoundsCF, ghostBoundsSize = unitModel:GetBoundingBox()
	local unitSizeX = ghostBoundsSize.X
	--[[
		Altura do chao antes do primeiro movimento do mouse, so para o anel nascer
		na altura certa -- a partir dai quem manda e o raycast do loop la embaixo.

		Media pelo chao debaixo do proprio jogador em vez de uma part fixa: o mapa
		e clonado em runtime pelo MapService e cada um tem o seu, entao nao existe
		uma `workspace.GroundPart` para ler (era o que estourava aqui).
	]]
	local character = Player.Character
	local characterPosition = character and character:GetPivot().Position
	local groundSurfaceY = 0

	if characterPosition then
		groundSurfaceY = raycastGroundY(characterPosition, self:getGroundExcludeList({ ghost, character }))
			or characterPosition.Y
	end

	local currentGroundY = groundSurfaceY

	local placementRing = UIAssets.AOE.Ring:Clone()
	local ringPart = placementRing:FindFirstChild("Renge")
	if ringPart then
		local currentDiameter = ringPart.Size.X
		local scaleFactor = (unitRange * 2) / currentDiameter
		placementRing:ScaleTo(placementRing:GetScale() * scaleFactor)
	end

	local targetRingScale = placementRing:GetScale()
	placementRing:ScaleTo(0.001)
	-- Nasce debaixo do jogador, nao no centro do mundo: o loop so reposiciona o anel
	-- quando o mouse acerta alguma superficie.
	local ringOrigin = characterPosition or Vector3.zero
	placementRing:PivotTo(CFrame.new(ringOrigin.X, groundSurfaceY + placementRing:GetExtentsSize().Y / 2, ringOrigin.Z))
	placementRing.Parent = workspace.CurrentCamera

	local ringScaleValue = Instance.new("NumberValue")
	ringScaleValue.Value = 0.001
	local ringTween = TweenService:Create(
		ringScaleValue,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Value = targetRingScale }
	)
	ringScaleValue.Changed:Connect(function(v)
		if placementRing and placementRing.Parent then
			placementRing:ScaleTo(v)
		end
	end)
	ringTween:Play()
	ringTween.Completed:Connect(function()
		ringScaleValue:Destroy()
	end)

	-- Nome distinto de proposito: o loop de validacao la embaixo tem o proprio
	-- `gridParts`, que e o resultado de um GetPartsInPart e nao tem relacao.
	local paintedGridParts = getWorldGridParts()
	paintGridParts(paintedGridParts)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local ghostExtentsSize = ghost:GetExtentsSize()
	local halfHeight = ghostExtentsSize.Y / 2

	local gridProbe = Instance.new("Part")
	-- Tamanho vem do `PathProbe`, igual ao do servidor: a caixa da unidade mais a
	-- coluna de ar debaixo dela. O CFrame e reposto a cada teste, la embaixo.
	local _, gridProbeSize = PlacementUtil.PathProbe(CFrame.new(), ghostBoundsSize)
	gridProbe.Size = gridProbeSize
	gridProbe.Anchored = true
	gridProbe.CanCollide = false
	gridProbe.CanQuery = false
	gridProbe.CanTouch = false
	gridProbe.Transparency = 1
	gridProbe.Parent = workspace
	maid:GiveTask(gridProbe)

	local ghostCF = ghost:GetPivot()
	local targetCF = ghostCF
	local smoothLean = Vector3.zero


	local overlapCheckElapsed = 0
	local OVERLAP_CHECK_INTERVAL = 0.05

	maid:GiveTask(RunService.RenderStepped:Connect(function(dt)
		local character = Player.Character
		local filterList = {ghost}
		if character then
			table.insert(filterList, character)
		end
		raycastParams.FilterDescendantsInstances = filterList

		-- No mouse a mira e onde o cursor esta agora; no toque e onde o dedo encostou
		-- por ultimo, que so muda quando o jogador toca de novo.
		local pointerPosition = if isTouch then touchTarget else PointerUtil.getScreenPosition()

		local raycastResult = nil
		if pointerPosition then
			local pointerRay = workspace.CurrentCamera:ViewportPointToRay(pointerPosition.X, pointerPosition.Y)
			raycastResult = workspace:Raycast(pointerRay.Origin, pointerRay.Direction * 1000, raycastParams)
		end

		if raycastResult then
			local position = raycastResult.Position
			currentGroundY = position.Y
			groundInstance = raycastResult.Instance
			local placedPosition = Vector3.new(position.X, position.Y + halfHeight, position.Z)

			targetCF = CFrame.new(placedPosition) * CFrame.Angles(0, math.rad(currentRotation), 0)

			overlapCheckElapsed += dt
			if overlapCheckElapsed >= OVERLAP_CHECK_INTERVAL then
				overlapCheckElapsed = 0

				local ghostCFrameNow = CFrame.new(placedPosition) * CFrame.Angles(0, math.rad(currentRotation), 0)
				local probeCF = PlacementUtil.PathProbe(ghostCFrameNow, ghostBoundsSize)
				gridProbe.CFrame = probeCF

				local gridOverlapParams = OverlapParams.new()
				gridOverlapParams.FilterType = Enum.RaycastFilterType.Include
				gridOverlapParams.FilterDescendantsInstances = CollectionService:GetTagged("Grid")
				local gridParts = workspace:GetPartsInPart(gridProbe, gridOverlapParams)
				local onGrid = #gridParts > 0

				local isObstructed = false
				local reason = ""

				if onGrid then
					reason = string.format("em cima do caminho (%d part(s) de Grid ate %d studs abaixo, primeira: %s)",
						#gridParts, PlacementUtil.PathClearance, gridParts[1]:GetFullName())
				end

				if not onGrid then
					--[[
						Personagem nenhum entra neste teste -- nem o do proprio jogador,
						nem o dos outros. Quem responde por eles e o `FindBlockingCharacter`
						logo abaixo, e a caixa dele e a da unidade inteira: tudo que este
						teste pegaria num corpo, aquele ja pega, e com a regra certa.

						A regra que faltava aqui era a do acessorio. Chapeu e asa saem
						metros fora do corpo e sao parts consultaveis como qualquer outra,
						entao o chapeu de quem passasse perto pintava o fantasma de vermelho
						-- num lugar que o servidor aceitaria, porque la o unico teste de
						personagem e o `FindBlockingCharacter`, que pula acessorio de
						proposito. Fantasma vermelho e servidor aprovando e exatamente a
						divergencia que o `PlacementUtil` existe para evitar.
					]]
					local overlapParams = OverlapParams.new()
					overlapParams.FilterType = Enum.RaycastFilterType.Exclude
					overlapParams.FilterDescendantsInstances = characterFilter(filterList)
					local parts = workspace:GetPartsInPart(ghost.PrimaryPart or ghost:FindFirstChildWhichIsA("BasePart"), overlapParams)
					for _, part in ipairs(parts) do
						if part ~= raycastResult.Instance then
							isObstructed = true
							reason = "obstruido por " .. part:GetFullName()
							break
						end
					end
				end

				--[[
					Personagem e caso a parte porque o teste generico acima nao o pega:
					ele roda so na HumanoidRootPart do fantasma (uns 0,6 stud) e ainda
					pula a part que o raycast acertou -- que, mirando num jogador, e
					justamente o corpo dele. Aqui a caixa e a da unidade inteira, e o
					proprio jogador conta: colocar uma torre dentro de si mesmo tambem
					nao vale.
				]]
				if not onGrid and not isObstructed then
					local blockingCharacter = PlacementUtil.FindBlockingCharacter(ghostCFrameNow, ghostBoundsSize)
					if blockingCharacter then
						isObstructed = true
						reason = "em cima do personagem " .. blockingCharacter:GetFullName()
					end
				end

				if not onGrid and not isObstructed then
					for placedUnit, _ in pairs(self.createdClasses) do
						local placedPos = placedUnit:GetPivot().Position
						local otherTemplate = Units:FindFirstChild(placedUnit.Name)
						local otherSizeX = otherTemplate and select(2, otherTemplate:GetBoundingBox()).X or unitSizeX
						local minDist = (unitSizeX + otherSizeX) / 2
						local dist = (Vector3.new(placedPosition.X, 0, placedPosition.Z) - Vector3.new(placedPos.X, 0, placedPos.Z)).Magnitude
						if dist < minDist then
							isObstructed = true
							reason = string.format("perto demais de %s: %.2f studs (minimo %.2f)", placedUnit.Name, dist, minDist)
							break
						end
					end
				end

				canPlace = not onGrid and not isObstructed
				blockReason = reason
			end
		end

		local targetColor = canPlace and VALID_COLOR or INVALID_COLOR
		currentColor = currentColor:Lerp(targetColor, math.min(1, dt * COLOR_LERP_SPEED))
		highlight.FillColor = currentColor
		highlight.OutlineColor = currentColor

		-- No toque o botao segue a cor do fantasma: sem cursor pairando sobre o
		-- mapa, ele e o unico aviso de que ali nao da para colocar.
		if touchConfirmButton then
			local buttonColor = canPlace and TOUCH_CONFIRM_COLOR or TOUCH_CONFIRM_BLOCKED_COLOR
			if touchConfirmButton.BackgroundColor3 ~= buttonColor then
				touchConfirmButton.BackgroundColor3 = buttonColor
			end
		end

		local alpha = math.min(1, dt * LERP_SPEED)
		ghostCF = ghostCF:Lerp(targetCF, alpha)

		local remaining = targetCF.Position - ghostCF.Position
		local desiredLean = Vector3.new(remaining.X, 0, remaining.Z)
		smoothLean = smoothLean:Lerp(desiredLean, math.min(1, dt * TILT_LERP_SPEED))

		local displayCF = ghostCF
		local leanMagnitude = smoothLean.Magnitude
		if leanMagnitude > 0.001 then
			local tiltAxis = Vector3.yAxis:Cross(smoothLean.Unit)
			if tiltAxis.Magnitude > 0.001 then
				local tiltAngle = math.min(leanMagnitude * TILT_PER_STUD, TILT_MAX)
				displayCF = CFrame.new(ghostCF.Position) * CFrame.fromAxisAngle(tiltAxis.Unit, tiltAngle) * (ghostCF - ghostCF.Position)
			end
		end
		ghost:PivotTo(displayCF)

		local ghostPos = ghostCF.Position
		placementRing:PivotTo(CFrame.new(ghostPos.X, currentGroundY + placementRing:GetExtentsSize().Y / 2, ghostPos.Z))
	end))

	local function rotateGhost()
		currentRotation = (currentRotation + 90) % 360
	end

	--[[
		Larga a unidade onde o fantasma esta. Vive numa funcao propria porque tem
		duas portas de entrada: o clique do mouse no PC e o botao do painel de toque.
	]]
	local function confirmPlacement()
		if not self.isPlacing then return end

		if not canPlace then
			placementPrint(unitName, "nao pode posicionar aqui:", blockReason ~= "" and blockReason or "motivo desconhecido",
				"fantasma em", formatVector(targetCF.Position))
			return
		end

		--[[
			Vai `targetCF`, e nao `ghostCF`: o fantasma persegue o alvo por lerp, entao
			ele quase nunca esta exatamente onde a mira aponta. Quem foi validado pelo
			teste de caminho e de sobreposicao foi o alvo, e e ele que tem que chegar
			ao servidor -- o lerp existe so para a unidade nao teleportar na tela.

			No mouse a diferenca era invisivel porque o cursor fica parado sobre o
			ponto e o fantasma alcanca antes do clique. No toque nao: o dedo toca e ja
			aperta COLOCAR, com o fantasma ainda a caminho, e a unidade nascia no meio
			do trajeto.
		]]
		placementPrint(unitName, "fantasma enviado ao servidor em", formatVector(targetCF.Position),
			"| apoiado em", describeSurface(groundInstance))
		Framework:Fire("PlaceUnit", unitName, targetCF)

		-- A devolucao da aparencia do caminho fica a cargo do maid, logo
		-- abaixo: um dono so para os dois caminhos de saida.
		placementRing:Destroy()
		ringScaleValue:Destroy()
		self.isPlacing = false
		maid:Destroy()
		ghost:Destroy()

		self.Controllers.CardController:setUnequipState()
	end

	--[[
		Desiste da unidade em mao. No PC isso e clicar de novo na carta; no toque a
		carta fica atras do fantasma e do painel, entao o painel tem a propria saida.
	]]
	local function cancelPlacement()
		self.Controllers.CardController:setUnequipState()
		self:unequip()
	end

	maid:GiveTask(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.KeyCode == Enum.KeyCode.R then
			rotateGhost()
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			confirmPlacement()
		end
	end))

	if isTouch then
		-- O toque no mapa so reposiciona: quem confirma e o botao, senao o dedo
		-- taparia a unidade no exato momento de decidir se ela pode ficar ali.
		maid:GiveTask(PointerUtil.onPointerAction(function(screenPosition)
			touchTarget = screenPosition
		end))

		local touchControls, confirmButton = createTouchControls(rotateGhost, confirmPlacement, cancelPlacement)
		touchConfirmButton = confirmButton
		maid:GiveTask(function()
			touchConfirmButton = nil
			touchControls:Destroy()
		end)
	end

	maid:GiveTask(function()
		restoreGridParts(paintedGridParts)
		if placementRing and placementRing.Parent then
			placementRing:Destroy()
		end
		if ghost and ghost.Parent then
			ghost:Destroy()
		end
		self.isPlacing = false
		self._maid = nil
	end)
end

function UnitPlacementController:unequip()
	if not self.isPlacing then return end
	if self._maid then
		self._maid:Destroy()
		self._maid = nil
	end
end

--[=[
	Larga tudo que o jogador tinha em mao: o fantasma que segue o mouse, a unidade
	selecionada (com anel, linha pontilhada e painel de upgrade) e a carta equipada
	na hotbar.

	O fantasma e um Model no workspace, nao GUI — desligar a Interface no fim do
	round nao o faz sumir, ele continuaria seguindo o mouse por cima da tela de
	resultado. Por isso a limpeza e explicita.
]=]
function UnitPlacementController:clearInteraction()
	self:unequip()
	self:deselectCurrent()

	local cardController = self.Controllers.CardController
	if cardController and cardController.setUnequipState then
		cardController:setUnequipState()
	end
end

function UnitPlacementController:flashUpgrade(unitModel)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(120, 255, 140)
	highlight.OutlineColor = Color3.fromRGB(180, 255, 200)
	highlight.FillTransparency = 0.5
	highlight.OutlineTransparency = 0
	highlight.Parent = unitModel
	TweenService:Create(highlight, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()
	task.delay(0.45, function()
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end)
end

function UnitPlacementController:construct()
	--[[
		Clique do mouse no PC, toque curto no celular: nos dois casos o que chega
		aqui e um ponto na tela, e o resto do caminho e o mesmo.

		Com uma unidade em mao esse ponto pertence ao posicionamento (e la que ele
		move o fantasma), entao a selecao sai da frente.
	]]
	PointerUtil.onPointerAction(function(screenPosition)
		if self.isPlacing then return end

		local pointerRay = workspace.CurrentCamera:ViewportPointToRay(screenPosition.X, screenPosition.Y)

		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		if Player.Character then
			raycastParams.FilterDescendantsInstances = {Player.Character}
		end

		local raycastResult = workspace:Raycast(pointerRay.Origin, pointerRay.Direction * 1000, raycastParams)

		if raycastResult then
			local hitInstance = raycastResult.Instance
			local foundUnit = nil

			for unitModel, _ in pairs(self.createdClasses) do
				if hitInstance == unitModel or hitInstance:IsDescendantOf(unitModel) then
					foundUnit = unitModel
					break
				end
			end

			if foundUnit then
				self:selectUnit(foundUnit)
			else
				self:deselectCurrent()
			end
		else
			self:deselectCurrent()
		end
	end)

	-- Rede de seguranca: se o round reiniciar sem passar pela tela de resultado,
	-- o jogador nao fica com fantasma nem carta equipada de uma partida que acabou.
	Framework:Listen("RoundRestarted", function()
		self:clearInteraction()
		-- O mapa pode ter mudado; a lista de parts do caminho e remontada no
		-- proximo posicionamento.
		invalidateGridParts()
	end)

	Framework:Listen("RemoveUnit", function(unitId)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				if self.selectedUnit == unitModel then
					self:deselectCurrent()
				end
				local dottedLine = self.unitDottedLines[unitModel]
				if dottedLine then
					dottedLine:Destroy()
					self.unitDottedLines[unitModel] = nil
					self.dottedLineData[unitModel] = nil
				end
				if self.Controllers.TargetingController and self.Controllers.TargetingController.UnregisterUnit then
					self.Controllers.TargetingController:UnregisterUnit(class)
				end
				if class.Destroy then
					class:Destroy()
				end
				self.createdClasses[unitModel] = nil
				self.classesById[unitId] = nil
				self.damageDoneById[unitId] = nil
				unitModel:Destroy()
				break
				end
			end
	end)

	Framework:Listen("UnitPriorityChanged", function(unitId, priority)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				unitModel:SetAttribute("TargetPriority", TargetPriority.Get(priority))
				break
			end
		end
	end)

	Framework:Listen("UnitUpgraded", function(unitId, newLevel)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				class.upgrades = newLevel
				unitModel:SetAttribute("Upgrades", newLevel)
				self:flashUpgrade(unitModel)

				if self.selectedUnit == unitModel then
					self:resizeSelectionRing()
				end

				self.Controllers.MusicController:PlaySFX("UnitUpgrade")
				break
			end
		end
	end)

	Framework:Listen("UnitDamageStats", function(batch)
		if typeof(batch) ~= "table" then return end

		for unitId, total in batch do
			self.damageDoneById[unitId] = total

			local class = self.classesById[unitId]
			if class and class.model and class.model.Parent then
				class.model:SetAttribute("DamageDone", total)
			end
		end
	end)

	Framework:Listen("ReplicateUnit", function(...)
		return self:replicatePlacedUnit(...)
	end)

	Framework:Listen("UnitSwing", function(unitId, unitName, targetMobId, stepIndex)
		local class = self.classesById[unitId]
		if not class then return end
		local mobController = self.Controllers.MobController
		local target = mobController and mobController.SpawnedMobs and mobController.SpawnedMobs[targetMobId] or nil
		class:playAttackVisual(target, stepIndex)
	end)

	Framework:Listen("FarmPayout", function(unitId, amount)
		local class = self.classesById[unitId]
		if not class or not class.playFarmVisual then return end
		class:playFarmVisual()
	end)

	--[[
		O clima mexe no alcance e nos numeros do card, e nenhum dos dois se redesenha
		sozinho: o circulo so e refeito quando alguem pede, e o card so quando a
		selecao muda. Aqui os dois sao refeitos na troca, para o jogador ver a
		neblina encolher o circulo no mesmo momento em que ela entra.
	]]
	Framework:Listen("WeatherChanged", function()
		self:resizeSelectionRing()
		self.Controllers.UILibraryController:doComponent("ToggleTower", "refresh")
	end)

	--[=[
		Realce temporario numa unidade, para o jogador ver que algo pegou nela.

		Amarelo e atordoamento (a unidade parou), ciano e carga (ela esta melhor que
		o normal). Duas cores porque os dois estados vem do mesmo raio e acontecem
		lado a lado: sem separar, uma unidade Electric carregada pareceria congelada.
	]=]
	local function highlightUnit(unitId, duration, color)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				local highlight = Instance.new("Highlight")
				highlight.FillColor = color
				highlight.OutlineColor = color
				highlight.FillTransparency = 0.6
				highlight.OutlineTransparency = 0.2
				highlight.Parent = unitModel

				--[[
					A duracao vem do servidor em tempo de partida, entao a espera tambem
					corre no relogio da partida: no 2x o atordoamento de 5s acaba em 2,5s
					reais, e o realce tem que apagar junto com ele.
				]]
				GameClock.Delay(duration, function()
					if highlight and highlight.Parent then
						highlight:Destroy()
					end
				end)
				break
			end
		end
	end

	Framework:Listen("UnitStunned", function(unitId, duration)
		highlightUnit(unitId, duration, Color3.fromRGB(255, 200, 60))
	end)

	Framework:Listen("UnitCharged", function(unitId, duration)
		highlightUnit(unitId, duration, Color3.fromRGB(90, 220, 255))
	end)
end



function UnitPlacementController:start()
end

function UnitPlacementController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return UnitPlacementController
