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
		    ├── RewardTitle         TextLabel "REWARDS" — entra em fade
		    ├── RewardsContainer    Frame com ClipsDescendants e UIListLayout
		    │   ├── ShardRewardWrapper.ShardAmount   desliza para dentro do quadro
		    │   └── CoinsRewardWrapper.CoinAmount    idem, REWARD_STAGGER depois
		    ├── ExpContainer        Frame da barra de XP
		    │   └── Bar             Size.X.Scale de BAR_MIN (0%) a BAR_MAX (100%)
		    ├── ExpAmount           TextLabel "XP/proximo nivel"
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
local BAR_NAME = "Bar"

local PLAY_AGAIN_NAME = "PlayAgain"
local LOBBY_NAME = "Lobby"
local BUTTON_TEXT_NAME = "TextLabel"

-- De que chave de `info.rewards` sai o numero de cada wrapper. Wrapper fora da
-- lista entra na animacao do mesmo jeito, so nao tem numero para escrever.
local REWARD_KEYS = {
	ShardRewardWrapper = "shards",
	CoinsRewardWrapper = "coins",
}

local LEAVING_TEXT = "LEAVING..."
local LOBBY_TEXT = "BACK TO LOBBY"
local PLAY_AGAIN_TEXT = "PLAY AGAIN (%d/%d)"
local MAX_EXP_TEXT = "MAX"

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
	  5. RewardTitle entra em fade
	  6. RewardsContainer liga e cada label desliza de dentro do wrapper, um a cada
	     REWARD_STAGGER
	  7. ExpContainer e ExpAmount ligam e a barra enche do XP de antes ate o de agora
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
	local expGroup = self:prepareGroup(exp)
	local expTextGroup = self:prepareGroup(expText)
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

		if exp then
			self:playExpAnimation(exp, expText and expText:IsA("TextLabel") and expText or nil, info)
		end

		self:revealGroup(playAgainGroup)
		task.wait(ELEMENT_STAGGER)
		self:revealGroup(lobbyGroup)

		self.revealThread = nil
	end)
end

--[[ API ]]

function ResultController:Show(info)
	local screen = self:getScreen()
	if not screen then return end

	info = info or {}
	self.leaving = false

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

	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	self.leaving = false
	self.playAgainState = nil

	local screen = PlayerGui:FindFirstChild(SCREEN_NAME)
	if screen then
		screen.Enabled = false
	end

	self:setInterfaceEnabled(true)
end

function ResultController:construct()
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
