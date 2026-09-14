local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Me = require(Vendor.Me)

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Util.UIUtil)

local LevelConfig = SharedConfig.LevelConfig

local Framework = Me.new()

--[[
	Tela de fim de partida.

	Entra por `RoundReward`, o unico evento que o servidor dispara nos dois
	desfechos (vitoria e derrota) ja com os dados do resultado.

	Toda a coreografia de entrada vive em `:playRevealAnimation()`. Quem precisa
	mostrar a tela chama `:Show(info)` e nao encosta em tween nenhum; quem quiser
	mudar ritmo, ordem ou easing mexe so nas constantes daqui e naquele metodo.

		StarterGui.ResultScreen
		├── BackgroundFrame         Frame preto de tela cheia (o escurecimento)
		└── MainScreen              ImageLabel do painel
		    ├── ViewportFrame       o MVP em 3D
		    │   └── WorldModel      onde o clone do personagem entra
		    ├── MVPText             TextLabel "MVP: <nome>"
		    ├── RewardTitle         TextLabel "REWARDS" — entra em fade
		    ├── RewardsContainer    Frame com ClipsDescendants e UIListLayout
		    │   ├── ShardRewardWrapper.ShardAmount   desliza para dentro do quadro
		    │   └── CoinsRewardWrapper.CoinAmount    idem, REWARD_STAGGER depois
		    ├── ExpContainer        Frame da barra de XP
		    │   └── Bar             Size.X.Scale de BAR_MIN (0%) a BAR_MAX (100%)
		    ├── ExpAmount           TextLabel "XP/proximo nivel"
		    ├── ExpOrnament         ImageLabel decorativo, entra junto com o ExpContainer
		    ├── PlayAgain           ImageButton
		    └── Lobby               ImageButton

	Tudo dentro de MainScreen nasce com `Visible = false` na GUI autorada: e a
	revelacao que liga cada peca na hora certa. O painel antigo
	(`ResultBackground`) nao e mais usado; se ainda estiver na arvore, ele so e
	mantido desligado.
]]

-- Escurecimento de fundo.
local BACKDROP_TRANSPARENCY = 0.4
local BACKDROP_TIME = 0.4

-- Painel e fades.
local PANEL_DELAY = 0.75      -- espera entre o backdrop e o painel
local ELEMENT_TIME = 0.35     -- duracao de cada fade
local ELEMENT_STAGGER = 0.3   -- intervalo entre o inicio de um fade e o seguinte

-- Recompensas: cada label entra deslizando de REWARD_SLIDE_FROM ate a posicao
-- autorada (0 -> 0.5 no X.Scale, com a arte de hoje).
local REWARD_SLIDE_FROM = 0
local REWARD_SLIDE_TIME = 0.4
local REWARD_STAGGER = 0.4    -- do inicio de um wrapper ao inicio do proximo
local REWARD_DELAY = 0.15     -- espera entre o titulo e o primeiro wrapper

-- Barra de XP.
local EXP_DELAY = 0.35
local EXP_FILL_TIME = 1.1
local BAR_MIN = 0.05          -- 0% de progresso
local BAR_MAX = 1             -- 100%

local EASING_STYLE = Enum.EasingStyle.Quad
local EASING_DIRECTION = Enum.EasingDirection.Out

--[[ nomes na arvore ]]

local SCREEN_NAME = "ResultScreen"
local PANEL_NAME = "MainScreen"
local LEGACY_PANEL_NAME = "ResultBackground"
local BACKDROP_NAME = "BackgroundFrame"

local TITLE_NAME = "RewardTitle"
local REWARDS_NAME = "RewardsContainer"
local EXP_NAME = "ExpContainer"
local EXP_TEXT_NAME = "ExpAmount"
local EXP_ORNAMENT_NAME = "ExpOrnament"
local BAR_NAME = "Bar"

local VIEWPORT_NAME = "ViewportFrame"
local WORLD_MODEL_NAME = "WorldModel"
local MVP_TEXT_NAME = "MVPText"
local MVP_MODEL_NAME = "MVPCharacter"

local PLAY_AGAIN_NAME = "PlayAgain"
local LOBBY_NAME = "Lobby"
local BUTTON_TEXT_NAME = "TextLabel"

-- De que chave de `info.rewards` sai o numero de cada wrapper. Wrapper fora da
-- lista entra na animacao do mesmo jeito, so nao tem numero para escrever.
local REWARD_KEYS = {
	ShardRewardWrapper = "shards",
	CoinsRewardWrapper = "coins",
}

-- Enquadramento do MVP no ViewportFrame.
local VIEWPORT_FOV = 30            -- FOV fechado: menos distorcao de lente no retrato
local VIEWPORT_PADDING = 1.12      -- folga em volta do personagem
local VIEWPORT_YAW = 15            -- graus de giro; 0 e de frente, positivo vira o ombro
local VIEWPORT_HEIGHT_BIAS = 0     -- fracao da altura; sobe o alvo da camera e desce o corpo no quadro

local LEAVING_TEXT = "LEAVING..."
local LOBBY_TEXT = "BACK TO LOBBY"
local PLAY_AGAIN_TEXT = "PLAY AGAIN (%d/%d)"
local MAX_EXP_TEXT = "MAX"
local MVP_TEXT = "MVP: %s"
local MVP_EMPTY_TEXT = "MVP: —"

-- Propriedades de transparencia por classe. So o que estiver aqui entra nos
-- fades; UICorner e UIAspectRatioConstraint ficam de fora porque nao tem nada
-- para animar.
local TRANSPARENCY_PROPERTIES = {
	Frame = { "BackgroundTransparency" },
	ScrollingFrame = { "BackgroundTransparency" },
	CanvasGroup = { "BackgroundTransparency", "GroupTransparency" },
	ViewportFrame = { "BackgroundTransparency", "ImageTransparency" },
	ImageLabel = { "BackgroundTransparency", "ImageTransparency" },
	ImageButton = { "BackgroundTransparency", "ImageTransparency" },
	TextLabel = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" },
	TextButton = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" },
	TextBox = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" },
	UIStroke = { "Transparency" },
}

local ResultController = {
	Controllers = {
		UnitPlacementController = {},
		DataController = {},
	},
	connections = {},
	tweens = {},
}

-- Valores autorais de transparencia e de posicao, por instancia. Chaves fracas
-- porque a ResultScreen tem ResetOnSpawn = true: a ScreenGui e recriada a cada
-- respawn e as instancias antigas precisam poder ser coletadas.
ResultController.snapshots = setmetatable({}, { __mode = "k" })
ResultController.positions = setmetatable({}, { __mode = "k" })

local function tweenInfo(duration : number)
	return TweenInfo.new(duration, EASING_STYLE, EASING_DIRECTION)
end

--[[ resolucao das instancias ]]

function ResultController:getScreen()
	-- Resolvido na hora de mostrar, e nao guardado no init, porque a ScreenGui
	-- volta do zero a cada respawn.
	local screen = PlayerGui:FindFirstChild(SCREEN_NAME)
	if not screen or not screen:IsA("ScreenGui") then
		warn(`ResultController: StarterGui.{SCREEN_NAME} nao encontrada na PlayerGui.`)
		return nil
	end
	return screen
end

function ResultController:getPanel()
	local screen = PlayerGui:FindFirstChild(SCREEN_NAME)
	local panel = screen and screen:FindFirstChild(PANEL_NAME)
	return panel
end

function ResultController:setInterfaceEnabled(enabled : boolean)
	local interface = PlayerGui:FindFirstChild("Interface")
	if interface and interface:IsA("ScreenGui") then
		interface.Enabled = enabled
	end
end

--[[ transparencia ]]

-- Guarda (uma vez por instancia) os valores autorais de transparencia. Sao eles
-- os alvos do fade: um elemento que nasce com ImageTransparency 0.47 precisa
-- voltar para 0.47, e nao para 0.
function ResultController:snapshot(instance : Instance)
	local properties = TRANSPARENCY_PROPERTIES[instance.ClassName]
	if not properties then return nil end

	local cached = self.snapshots[instance]
	if cached then return cached end

	local values = {}
	for _, property in properties do
		values[property] = (instance :: any)[property]
	end

	self.snapshots[instance] = values
	return values
end

-- A subarvore de `root`, ela inclusa, na ordem da arvore.
function ResultController:collectTargets(root : Instance)
	local list = {}

	local function visit(current : Instance)
		local values = self:snapshot(current)
		if values then
			table.insert(list, { instance = current, values = values })
		end
		for _, child in current:GetChildren() do
			visit(child)
		end
	end

	visit(root)
	return list
end

function ResultController:setTransparent(target)
	local instance = target.instance :: any
	for property, _ in target.values do
		instance[property] = 1
	end
end

--[=[
	Todo tween da tela passa por aqui: um `Show` novo cancela o que ficou rodando
	do anterior antes de reposicionar as pecas, senao o tween antigo continua
	escrevendo por cima do estado inicial da revelacao nova.
]=]
function ResultController:playTween(instance : Instance, duration : number, goal)
	local tween = TweenService:Create(instance, tweenInfo(duration), goal)

	table.insert(self.tweens, tween)
	tween:Play()

	return tween
end

function ResultController:cancelTweens()
	for _, tween in self.tweens do
		pcall(function()
			tween:Cancel()
		end)
	end

	table.clear(self.tweens)
end

function ResultController:fadeIn(target, duration : number)
	local goal = {}
	for property, value in target.values do
		goal[property] = value
	end
	self:playTween(target.instance, duration, goal)
end

--[=[
	Prepara um grupo para entrar: guarda os valores autorais, poe tudo em
	transparencia 1 e desliga o `Visible`. Devolve os alvos para o fade.
]=]
function ResultController:prepareGroup(root : Instance?)
	if not root then return nil end

	local targets = self:collectTargets(root)
	for _, target in targets do
		self:setTransparent(target)
	end

	if root:IsA("GuiObject") then
		root.Visible = false
	end

	return { root = root, targets = targets }
end

--[=[
	Liga o grupo e roda o fade dele inteiro de uma vez. Diferente da revelacao
	antiga, que escalonava elemento a elemento: aqui o escalonamento e entre
	grupos, e cada grupo entra junto.
]=]
function ResultController:revealGroup(group, duration : number?)
	if not group then return end

	if group.root:IsA("GuiObject") then
		group.root.Visible = true
	end

	for _, target in group.targets do
		self:fadeIn(target, duration or ELEMENT_TIME)
	end
end

--[[ recompensas ]]

--[=[
	Escreve os numeros dos wrappers e devolve, na ordem do UIListLayout, os labels
	que vao deslizar. Wrapper com recompensa zerada fica de fora: numa derrota cedo
	os shards sao 0 e uma linha "0" so ocupa espaco — o layout fecha o buraco.
]=]
function ResultController:collectRewardWrappers(container : Instance, info)
	local rewards = info.rewards or {}
	local wrappers = {}

	for index, child in container:GetChildren() do
		if not child:IsA("GuiObject") then continue end

		local key = REWARD_KEYS[child.Name]
		local amount = key and tonumber(rewards[key]) or nil

		if key and (amount or 0) <= 0 then
			child.Visible = false
			continue
		end

		-- O label e o unico filho GuiObject do wrapper; e ele que desliza.
		local label = nil
		for _, candidate in child:GetChildren() do
			if candidate:IsA("GuiObject") then
				label = candidate
				break
			end
		end

		if not label then continue end

		if amount then
			for _, text in label:GetDescendants() do
				if text:IsA("TextLabel") then
					text.Text = UIUtil.formatCommas(amount)
					break
				end
			end
		end

		child.Visible = true
		table.insert(wrappers, {
			label = label,
			order = child.LayoutOrder,
			index = index,
		})
	end

	table.sort(wrappers, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.index < b.index
	end)

	return wrappers
end

--[=[
	Manda o label para o comeco do slide. A posicao autorada e o alvo, entao e
	guardada antes de qualquer escrita — e ela que o `slideIn` devolve.
]=]
function ResultController:setSlideStart(label : GuiObject)
	local original = self.positions[label]
	if not original then
		original = label.Position
		self.positions[label] = original
	end

	label.Position = UDim2.new(REWARD_SLIDE_FROM, original.X.Offset, original.Y.Scale, original.Y.Offset)
end

function ResultController:slideIn(label : GuiObject)
	local original = self.positions[label]
	if not original then return end

	self:playTween(label, REWARD_SLIDE_TIME, { Position = original })
end

--[[ barra de XP ]]

--[=[
	O XP acumulado do perfil, direto da replica. `nil` enquanto ela nao chegou.
]=]
function ResultController:getTotalXP() : number?
	local dataController = self.Controllers.DataController
	if not dataController or not dataController.GetReplica then return nil end

	local ok, replica = pcall(function()
		return dataController:GetReplica()
	end)

	if not ok or not replica then return nil end

	local data = replica.Data
	local stats = typeof(data) == "table" and data.Stats or nil

	return typeof(stats) == "table" and tonumber(stats.XP) or nil
end

function ResultController:applyExpState(bar : GuiObject, label : TextLabel?, totalXP : number)
	local state = LevelConfig:Resolve(totalXP)
	local size = bar.Size

	bar.Size = UDim2.new(BAR_MIN + (BAR_MAX - BAR_MIN) * state.Progress, size.X.Offset, size.Y.Scale, size.Y.Offset)

	if label then
		label.Text = if state.IsMax
			then MAX_EXP_TEXT
			else `{UIUtil.formatCommas(state.XP)}/{UIUtil.formatCommas(state.Required)}`
	end
end

--[=[
	Enche a barra do XP que o jogador tinha antes da partida ate o que ele tem
	agora.

	O ponto de partida e deduzido: quando a animacao chega aqui a replica ja veio
	somada (o servidor credita antes de disparar o `RoundReward`, e a barra so
	entra depois do titulo e das recompensas), entao o "antes" e o total menos o
	ganho da partida. Como cada quadro reresolve o total pelo `LevelConfig`, subir
	de nivel no meio do enchimento sai de graca: a barra chega a 100%, volta para
	0% e continua — inclusive mais de uma vez.
]=]
function ResultController:playExpAnimation(container : Instance, label : TextLabel?, info)
	local bar = container:FindFirstChild(BAR_NAME)
	if not bar or not bar:IsA("GuiObject") then
		warn(`ResultController: {PANEL_NAME}.{EXP_NAME}.{BAR_NAME} nao encontrado.`)
		return
	end

	-- Zera a barra antes de qualquer coisa que possa ceder: a replica so demora se
	-- ainda nao tiver chegado, e ate la o container ja esta ligado — sem isto ele
	-- apareceria com o tamanho que sobrou do round anterior.
	local size = bar.Size
	bar.Size = UDim2.new(BAR_MIN, size.X.Offset, size.Y.Scale, size.Y.Offset)

	local gained = math.max(0, tonumber((info.rewards or {}).xp) or 0)
	local total = self:getTotalXP()

	-- Sem replica, o unico numero confiavel e o ganho da partida: a barra sobe de
	-- zero ate ele em vez de mentir um nivel.
	local finish = total or gained
	local start = math.max(0, finish - gained)

	self:applyExpState(bar, label, start)

	if finish <= start then return end

	local began = os.clock()

	while true do
		local alpha = math.clamp((os.clock() - began) / EXP_FILL_TIME, 0, 1)
		local eased = TweenService:GetValue(alpha, EASING_STYLE, EASING_DIRECTION)

		self:applyExpState(bar, label, start + (finish - start) * eased)

		if alpha >= 1 then break end
		RunService.Heartbeat:Wait()
	end
end

--[[ mvp ]]

--[=[
	Por que o personagem e copiado, e nao referenciado.

	Um ViewportFrame renderiza so os proprios descendentes, e uma Instance tem um
	Parent so: nao existe apontar para o personagem vivo daqui: so existe levar o
	personagem de verdade para dentro do WorldModel, o que o tiraria do mundo (e,
	sendo o personagem de outro jogador, ainda brigaria com a replicacao do
	servidor, que o poe de volta). Entao a copia e obrigatoria.

	O que da para evitar e o acoplamento, e e o que estas funcoes fazem: o clone
	entra sem script, sem som, com a raiz ancorada e tocando o proprio idle. Depois
	de montado ele nunca mais olha para o personagem original — nao ha nada
	sincronizando quadro a quadro com o mundo.
]=]
function ResultController:getMVPCharacter(mvp) : Model?
	if not mvp then return nil end

	local userId = tonumber(mvp.userId)

	for _, player in Players:GetPlayers() do
		local matches = if userId then player.UserId == userId else player.Name == mvp.name
		if matches then
			return player.Character
		end
	end

	return nil
end

-- O idle sai do `Animate` do proprio personagem: e ele que sabe se o rig e R6 ou
-- R15, entao nenhum id de animacao precisa ficar escrito aqui.
function ResultController:getIdleAnimationId(character : Model) : string?
	local animate = character:FindFirstChild("Animate")
	local idle = animate and animate:FindFirstChild("idle")
	if not idle then return nil end

	local animation = idle:FindFirstChild("Animation1") or idle:FindFirstChildWhichIsA("Animation")
	if animation and animation:IsA("Animation") and animation.AnimationId ~= "" then
		return animation.AnimationId
	end

	return nil
end

--[=[
	Tira do clone tudo que so daria trabalho dentro de uma ScreenGui — script (que
	rodaria de verdade, por estar na PlayerGui), som, efeito, nameplate. Sobra o
	rig, e so a raiz fica ancorada: ancorar o resto travaria os Motor6D e a
	animacao junto.
]=]
function ResultController:sanitizeMVPModel(model : Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BaseScript")
			or descendant:IsA("Sound")
			or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("Fire")
			or descendant:IsA("Smoke")
			or descendant:IsA("Sparkles")
			or descendant:IsA("LayerCollector")
			or descendant:IsA("Highlight")
			or descendant:IsA("ForceField")
		then
			descendant:Destroy()
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local any = humanoid :: any
		pcall(function()
			any.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end)
		pcall(function()
			any.EvaluateStateMachine = false
		end)
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
end

--[=[
	Copia o personagem contornando o `Archivable`.

	A engine marca o personagem do jogador com `Archivable = false` (o avatar nao
	sai copiado por ai), e `Clone` devolve nil nesse caso — foi por isso que o
	quadro nascia vazio. `Clone` tambem pula descendente marcado, entao a flag e
	ligada no modelo e em quem estiver com ela desligada, e devolvida logo depois:
	a janela e de uma linha e so existe neste cliente.
]=]
function ResultController:cloneCharacter(character : Model) : Model?
	local restore = {}

	if not character.Archivable then
		character.Archivable = true
		table.insert(restore, character)
	end

	for _, descendant in character:GetDescendants() do
		if not descendant.Archivable then
			descendant.Archivable = true
			table.insert(restore, descendant)
		end
	end

	local ok, clone = pcall(function()
		return character:Clone()
	end)

	for _, instance in restore do
		instance.Archivable = false
	end

	if not ok or not clone then
		warn(`ResultController: nao consegui copiar o personagem do MVP — {tostring(clone)}`)
		return nil
	end

	return clone
end

--[=[
	Enquadra o personagem inteiro no quadro que a GUI tem. Recalculado depois que o
	painel aparece porque `AbsoluteSize` so vale quando a GUI ja renderizou uma vez
	— antes disso ele e zero e o aspecto sairia errado.
]=]
function ResultController:frameMVPCamera()
	local viewport = self.mvpViewport
	local model = self.mvpModel
	local camera = self.mvpCamera

	if not viewport or not camera or not model or not model.Parent then return end

	local bounds, size = model:GetBoundingBox()

	local absolute = viewport.AbsoluteSize
	local aspect = if absolute.Y > 0 then absolute.X / absolute.Y else 1

	local fit = math.max(size.Y, size.X / math.max(aspect, 0.01))
	local distance = (fit * 0.5 * VIEWPORT_PADDING) / math.tan(math.rad(VIEWPORT_FOV * 0.5)) + size.Z * 0.5
	local focus = bounds.Position + Vector3.new(0, size.Y * VIEWPORT_HEIGHT_BIAS, 0)

	camera.FieldOfView = VIEWPORT_FOV
	camera.CFrame = CFrame.lookAt(focus + Vector3.new(0, 0, distance), focus)
end

function ResultController:clearMVPModel()
	if self.mvpStep then
		self.mvpStep:Disconnect()
		self.mvpStep = nil
	end

	if self.mvpModel then
		self.mvpModel:Destroy()
		self.mvpModel = nil
	end
end

--[=[
	Escreve o nome do MVP e monta o retrato dele. Devolve `true` quando o
	ViewportFrame tem alguem para mostrar — sem personagem (MVP saiu no fim da
	partida, ou esta respawnando) o quadro nao entra na revelacao, em vez de
	aparecer vazio.
]=]
function ResultController:populateMVP(panel : Instance, info) : boolean
	local mvp = info.mvp

	local label = panel:FindFirstChild(MVP_TEXT_NAME)
	if label and label:IsA("TextLabel") then
		label.Text = if mvp and mvp.name then string.format(MVP_TEXT, mvp.name) else MVP_EMPTY_TEXT
	end

	self:clearMVPModel()

	local viewport = panel:FindFirstChild(VIEWPORT_NAME)
	if not viewport or not viewport:IsA("ViewportFrame") then return false end

	self.mvpViewport = viewport

	local world = viewport:FindFirstChildOfClass("WorldModel")
	if not world then
		world = Instance.new("WorldModel")
		world.Name = WORLD_MODEL_NAME
		world.Parent = viewport
	end

	local camera = viewport:FindFirstChildOfClass("Camera")
	if not camera then
		camera = Instance.new("Camera")
		camera.Parent = viewport
	end

	viewport.CurrentCamera = camera
	self.mvpCamera = camera

	local character = self:getMVPCharacter(mvp)
	if not character then return false end

	local animationId = self:getIdleAnimationId(character)

	local clone = self:cloneCharacter(character)
	if not clone then return false end

	clone.Name = MVP_MODEL_NAME
	self:sanitizeMVPModel(clone)

	-- Identidade encara -Z, entao 180 graus poe o personagem de frente para a
	-- camera; o VIEWPORT_YAW e so o tempero do angulo.
	clone:PivotTo(CFrame.Angles(0, math.rad(180 + VIEWPORT_YAW), 0))
	clone.Parent = world

	self.mvpModel = clone

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")

	if animationId and animator then
		local animation = Instance.new("Animation")
		animation.AnimationId = animationId
		animation.Parent = animator

		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)

		if ok and track then
			track.Looped = true
			track:Play(0)

			-- Animator fora do Workspace nao anda sozinho: quem o avanca e o
			-- `StepAnimations`. O passo zero ja aplica a primeira pose do idle, entao
			-- mesmo sem o loop o retrato fica numa pose de pe, e nao na pose congelada
			-- do instante em que o round acabou.
			pcall(function()
				animator:StepAnimations(0)
			end)

			self.mvpStep = RunService.RenderStepped:Connect(function(delta)
				if not clone.Parent then return end
				animator:StepAnimations(delta)
			end)
		end
	end

	self:frameMVPCamera()

	return true
end

--[[ botoes ]]

function ResultController:findButton(name : string)
	local panel = self:getPanel()
	local button = panel and panel:FindFirstChild(name)
	return button and button:IsA("GuiButton") and button or nil
end

function ResultController:setButtonText(name : string, text : string)
	local button = self:findButton(name)
	local label = button and button:FindFirstChild(BUTTON_TEXT_NAME)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

function ResultController:setLobbyButtonText(text : string)
	self:setButtonText(LOBBY_NAME, text)
end

-- Contador de votos no proprio botao de recomecar.
function ResultController:applyPlayAgainState()
	local state = self.playAgainState
	if not state then return end

	self:setButtonText(PLAY_AGAIN_NAME, string.format(PLAY_AGAIN_TEXT, state.votes or 0, state.total or 0))
end

-- Reconectados a cada Show porque a ResultScreen e recriada no respawn.
function ResultController:bindButtons()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	local playAgain = self:findButton(PLAY_AGAIN_NAME)
	if playAgain then
		table.insert(self.connections, playAgain.MouseButton1Click:Connect(function()
			Framework:Fire("VotePlayAgain")
		end))
	end

	local lobby = self:findButton(LOBBY_NAME)
	if lobby then
		table.insert(self.connections, lobby.MouseButton1Click:Connect(function()
			if self.leaving then return end
			self.leaving = true
			self:setLobbyButtonText(LEAVING_TEXT)
			Framework:Fire("RequestLobbyTeleport")
		end))
	end
end

--[[ animacao ]]

--[[
	Ponto unico da entrada da tela. A sequencia:

	  1. tudo escondido, com a ScreenGui ainda desligada (sem flash)
	  2. BackgroundFrame  1 -> BACKDROP_TRANSPARENCY
	  3. PANEL_DELAY de espera
	  4. MainScreen       1 -> valor autoral
	  5. RewardTitle, MVPText e o ViewportFrame do MVP entram em fade juntos
	  6. RewardsContainer liga e cada label desliza de dentro do wrapper, um a cada
	     REWARD_STAGGER
	  7. ExpContainer, ExpAmount e ExpOrnament ligam e a barra enche do XP de antes ate o de agora
	  8. PlayAgain e Lobby entram em fade

	Mudou o ritmo, o easing ou a ordem? E aqui e nas constantes do topo — nenhum
	outro ponto do codigo conhece esses tweens.
]]
function ResultController:playRevealAnimation(screen : ScreenGui, info)
	if self.revealThread then
		pcall(task.cancel, self.revealThread)
		self.revealThread = nil
	end

	self:cancelTweens()

	local backdrop = screen:FindFirstChild(BACKDROP_NAME)
	local panel = screen:FindFirstChild(PANEL_NAME)

	if not panel then
		warn(`ResultController: {SCREEN_NAME}.{PANEL_NAME} nao encontrado.`)
	end

	-- Antes do snapshot e de a GUI ligar: o painel ja entra com a arte do resultado.
	self:applyPanelImage(panel, info.won ~= false)

	-- A tela antiga nao participa de nada; se ainda existir, fica fora do caminho.
	local legacy = screen:FindFirstChild(LEGACY_PANEL_NAME)
	if legacy and legacy:IsA("GuiObject") then
		legacy.Visible = false
	end

	-- O backdrop nao usa snapshot: o alvo dele e a constante, e nao o valor autoral.
	local backdropTarget = nil
	if backdrop and backdrop:IsA("GuiObject") then
		backdropTarget = {
			instance = backdrop,
			values = { BackgroundTransparency = BACKDROP_TRANSPARENCY },
		}
	end

	local panelValues = panel and self:snapshot(panel)
	local panelTarget = panelValues and { instance = panel, values = panelValues } or nil

	local title = panel and panel:FindFirstChild(TITLE_NAME)
	local mvpText = panel and panel:FindFirstChild(MVP_TEXT_NAME)
	local viewport = panel and panel:FindFirstChild(VIEWPORT_NAME)
	local rewards = panel and panel:FindFirstChild(REWARDS_NAME)
	local exp = panel and panel:FindFirstChild(EXP_NAME)
	local expText = panel and panel:FindFirstChild(EXP_TEXT_NAME)
	local playAgain = panel and panel:FindFirstChild(PLAY_AGAIN_NAME)
	local lobby = panel and panel:FindFirstChild(LOBBY_NAME)

	-- Passo 1, sincrono: nada pode aparecer no frame em que a GUI liga.
	if backdropTarget then
		self:setTransparent(backdropTarget)
		backdropTarget.instance.Visible = false
	end
	if panelTarget then
		self:setTransparent(panelTarget)
		if panel:IsA("GuiObject") then
			panel.Visible = false
		end
	end

	local titleGroup = self:prepareGroup(title)
	local mvpTextGroup = self:prepareGroup(mvpText)

	-- O retrato e montado antes de a GUI ligar, para entrar junto com o fade e nao
	-- pipocar depois. Sem MVP para mostrar, o quadro so fica fora da revelacao.
	local viewportGroup = nil
	if panel and self:populateMVP(panel, info) then
		viewportGroup = self:prepareGroup(viewport)
	elseif viewport and viewport:IsA("GuiObject") then
		viewport.Visible = false
	end

	local expGroup = self:prepareGroup(exp)
	local expTextGroup = self:prepareGroup(expText)
	local expOrnamentGroup = self:prepareGroup(panel and panel:FindFirstChild(EXP_ORNAMENT_NAME))
	local playAgainGroup = self:prepareGroup(playAgain)
	local lobbyGroup = self:prepareGroup(lobby)

	local wrappers = {}
	if rewards then
		if rewards:IsA("GuiObject") then
			rewards.Visible = false
		end

		wrappers = self:collectRewardWrappers(rewards, info)
		for _, wrapper in wrappers do
			self:setSlideStart(wrapper.label)
		end
	end

	screen.Enabled = true

	self.revealThread = task.spawn(function()
		if backdropTarget then
			backdropTarget.instance.Visible = true
			self:fadeIn(backdropTarget, BACKDROP_TIME)
		end

		task.wait(PANEL_DELAY)

		if panelTarget then
			if panel:IsA("GuiObject") then
				panel.Visible = true
			end
			self:fadeIn(panelTarget, ELEMENT_TIME)
		end

		task.wait(ELEMENT_STAGGER)
		self:revealGroup(titleGroup)
		self:revealGroup(mvpTextGroup)
		self:revealGroup(viewportGroup)

		-- Agora a GUI ja renderizou: o AbsoluteSize do quadro vale, e o enquadramento
		-- pode ser refeito com o aspecto de verdade.
		self:frameMVPCamera()

		task.wait(ELEMENT_TIME + REWARD_DELAY)

		if rewards and rewards:IsA("GuiObject") then
			rewards.Visible = true
		end

		for index, wrapper in wrappers do
			if index > 1 then
				task.wait(REWARD_STAGGER)
			end
			self:slideIn(wrapper.label)
		end

		task.wait(REWARD_SLIDE_TIME + EXP_DELAY)

		self:revealGroup(expGroup)
		self:revealGroup(expTextGroup)
		self:revealGroup(expOrnamentGroup)

		if exp then
			self:playExpAnimation(exp, expText and expText:IsA("TextLabel") and expText or nil, info)
		end

		self:revealGroup(playAgainGroup)
		task.wait(ELEMENT_STAGGER)
		self:revealGroup(lobbyGroup)

		self.revealThread = nil
	end)
end

-- A arte do painel na derrota. A da vitoria e a que veio autorada no Studio.
local DEFEAT_PANEL_IMAGE = "rbxassetid://132074829939960"
local AUTHORED_IMAGE_ATTRIBUTE = "AuthoredImage"

--[=[
	Troca a arte do `MainScreen` conforme o resultado: derrota usa
	`DEFEAT_PANEL_IMAGE`, vitoria a autorada.

	A autorada e guardada num atributo do proprio painel na primeira vez que a tela
	abre. A mesma copia da ScreenGui atravessa um "jogar de novo" sem respawn, e uma
	vitoria depois de uma derrota precisa ter para onde voltar.
]=]
function ResultController:applyPanelImage(panel : Instance?, won : boolean)
	if not panel or not panel:IsA("ImageLabel") then return end

	local authored = panel:GetAttribute(AUTHORED_IMAGE_ATTRIBUTE)
	if typeof(authored) ~= "string" then
		authored = panel.Image
		panel:SetAttribute(AUTHORED_IMAGE_ATTRIBUTE, authored)
	end

	panel.Image = if won then authored else DEFEAT_PANEL_IMAGE
end

--[[ API ]]

function ResultController:Show(info)
	local screen = self:getScreen()
	if not screen then return end

	info = info or {}
	self.leaving = false
	self.showing = true

	-- Nada de fantasma de posicionamento nem anel de selecao por cima da tela.
	local placement = self.Controllers.UnitPlacementController
	if placement and placement.clearInteraction then
		placement:clearInteraction()
	end

	self:setInterfaceEnabled(false)
	self:bindButtons()

	-- O estado da votacao pode ter chegado antes do RoundReward: a ordem entre os
	-- dois eventos nao e garantida, entao reaplicamos o ultimo que veio.
	self:applyPlayAgainState()
	self:setLobbyButtonText(LOBBY_TEXT)

	self:playRevealAnimation(screen, info)
end

function ResultController:Hide()
	if self.revealThread then
		pcall(task.cancel, self.revealThread)
		self.revealThread = nil
	end

	self:cancelTweens()
	self:clearMVPModel()

	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	self.leaving = false
	self.showing = false
	self.playAgainState = nil

	local screen = PlayerGui:FindFirstChild(SCREEN_NAME)
	if screen then
		screen.Enabled = false
	end

	self:setInterfaceEnabled(true)
end

--[=[
	Toda copia nova da ScreenGui nasce desligada.

	A ResultScreen tem `ResetOnSpawn`, entao a engine devolve a cada respawn uma
	copia com o estado autorado -- e basta alguem deixar o `MainScreen.Visible`
	ligado no Studio (para olhar a arte, por exemplo) para o painel aparecer por
	cima da partida ate o fim do round. Desligar a copia na entrada tira a tela
	dessa dependencia: quem a mostra e o `Show`, e mais ninguem.
]=]
function ResultController:watchScreen()
	local function hide(child : Instance)
		if self.showing then return end
		if child:IsA("ScreenGui") and child.Name == SCREEN_NAME then
			child.Enabled = false
		end
	end

	PlayerGui.ChildAdded:Connect(hide)

	for _, child in PlayerGui:GetChildren() do
		hide(child)
	end
end

function ResultController:construct()
	self:watchScreen()

	Framework:Listen("RoundReward", function(info)
		self:Show(info)
	end)

	Framework:Listen("PlayAgainState", function(state)
		self.playAgainState = state
		self:applyPlayAgainState()
	end)

	-- O round recomecou: a tela sai e o HUD volta.
	Framework:Listen("RoundRestarted", function()
		self:Hide()
	end)

	Framework:Listen("LobbyTeleportFailed", function()
		self.leaving = false
		self:setLobbyButtonText(LOBBY_TEXT)
	end)
end

function ResultController:start()
end

function ResultController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return ResultController
