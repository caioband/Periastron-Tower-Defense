local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Tela de fim de partida.

	Entra por `RoundReward`, o unico evento que o servidor dispara nos dois
	desfechos (vitoria e derrota) ja com os dados do resultado.

	Toda a coreografia de entrada vive em `:playRevealAnimation()`. Quem precisa
	mostrar a tela chama `:Show(info)` e nao encosta em tween nenhum; quem quiser
	mudar ritmo, ordem ou easing mexe so nas constantes daqui e naquele metodo.

		StarterGui.ResultScreen
		├── BackgroundFrame     Frame preto de tela cheia (o escurecimento)
		└── ResultBackground    ImageLabel do painel
		    ├── Result          banner
		    │   └── PlayersReady    TextLabel com o texto de vitoria/derrota
		    ├── MVP             TextLabel
		    ├── Rewards         TextLabel — rotulo fixo "REWARDS:"
		    ├── RewardText      TextLabel — os valores
		    ├── PlayAgain       ImageButton
		    └── BackToLobby     ImageButton
]]

-- Escurecimento de fundo.
local BACKDROP_TRANSPARENCY = 0.4
local BACKDROP_TIME = 0.4

-- Painel e conteudo.
local PANEL_DELAY = 0.75      -- espera entre o backdrop e o painel
local ELEMENT_TIME = 0.35     -- duracao do fade de cada elemento
local ELEMENT_STAGGER = 0.3   -- intervalo entre o inicio de um fade e o seguinte

local EASING_STYLE = Enum.EasingStyle.Quad
local EASING_DIRECTION = Enum.EasingDirection.Out

local WIN_TEXT = "YOU WIN!"
local LOSE_TEXT = "YOU LOSE!"

-- Ordem de entrada, por nome do filho direto de ResultBackground. Sem isso a
-- revelacao segue a ordem da arvore, onde os botoes vem antes do banner — o
-- jogador veria "PLAY AGAIN" antes de saber se ganhou. Cada subarvore entra
-- inteira e em sequencia (o UIStroke logo apos o texto que ele contorna).
-- Nome fora da lista entra depois, na ordem da arvore; lista vazia devolve a
-- ordem crua.
local REVEAL_ORDER = {
	"Result",
	"MVP",
	"Rewards",
	"RewardText",
	"PlayAgain",
	"BackToLobby",
}

-- Propriedades de transparencia por classe. So o que estiver aqui entra na
-- sequencia de revelacao; UICorner e UIAspectRatioConstraint ficam de fora
-- porque nao tem nada para animar.
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

local LEAVING_TEXT = "LEAVING..."
local LOBBY_TEXT = "BACK TO LOBBY"
local PLAY_AGAIN_TEXT = "Play Again? (%d/%d)"

local ResultController = {
	Controllers = {
		UnitPlacementController = {},
	},
	connections = {},
}

-- Valores originais de transparencia, por instancia. Chaves fracas porque a
-- ResultScreen tem ResetOnSpawn = true: a ScreenGui e recriada a cada respawn e
-- as instancias antigas precisam poder ser coletadas.
ResultController.snapshots = setmetatable({}, { __mode = "k" })

local function tweenInfo(duration : number)
	return TweenInfo.new(duration, EASING_STYLE, EASING_DIRECTION)
end

--[[ resolucao das instancias ]]

function ResultController:getScreen()
	-- Resolvido na hora de mostrar, e nao guardado no init, porque a ScreenGui
	-- volta do zero a cada respawn.
	local screen = PlayerGui:FindFirstChild("ResultScreen")
	if not screen or not screen:IsA("ScreenGui") then
		warn("ResultController: StarterGui.ResultScreen nao encontrada na PlayerGui.")
		return nil
	end
	return screen
end

function ResultController:setInterfaceEnabled(enabled : boolean)
	local interface = PlayerGui:FindFirstChild("Interface")
	if interface and interface:IsA("ScreenGui") then
		interface.Enabled = enabled
	end
end

--[[ transparencia ]]

-- Guarda (uma vez por instancia) os valores autorais de transparencia. Sao eles
-- os alvos do fade: o banner Result, por exemplo, nasce com ImageTransparency
-- 0.47 e precisa voltar para 0.47, nao para 0.
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

-- Monta a fila de revelacao: os filhos diretos de `root` sao ordenados por
-- REVEAL_ORDER e cada um entra com a propria subarvore em sequencia.
function ResultController:collectTargets(root : Instance)
	local function subtree(instance : Instance)
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

		visit(instance)
		return list
	end

	local priority = {}
	for index, name in REVEAL_ORDER do
		priority[name] = index
	end

	local children = root:GetChildren()

	-- Posicao na arvore, para desempatar quem nao esta na REVEAL_ORDER e manter
	-- a ordenacao estavel.
	local treeIndex = {}
	for index, child in children do
		treeIndex[child] = index
	end

	table.sort(children, function(a, b)
		local rankA = priority[a.Name] or (#REVEAL_ORDER + treeIndex[a])
		local rankB = priority[b.Name] or (#REVEAL_ORDER + treeIndex[b])
		return rankA < rankB
	end)

	local targets = {}
	for _, child in children do
		for _, target in subtree(child) do
			table.insert(targets, target)
		end
	end

	return targets
end

function ResultController:setTransparent(target)
	local instance = target.instance :: any
	for property, _ in target.values do
		instance[property] = 1
	end
end

function ResultController:fadeIn(target, duration : number)
	local goal = {}
	for property, value in target.values do
		goal[property] = value
	end
	TweenService:Create(target.instance, tweenInfo(duration), goal):Play()
end

--[[ dados ]]

function ResultController:formatRewards(info)
	local rewards = info.rewards or {}
	local parts = {}

	-- Recompensa zerada nao vira texto: numa derrota cedo os shards sao 0 e
	-- "0 shards" so ocupa espaco.
	local function add(amount : number?, label : string)
		if not amount or amount <= 0 then return end
		table.insert(parts, string.format("%d %s", amount, label))
	end

	add(rewards.coins, "coins")
	add(rewards.shards, "shards")
	add(rewards.xp, "XP")

	-- Waves so na derrota: quem venceu fez todas, nao ha o que informar.
	if not info.won then
		table.insert(parts, string.format("%d/%d waves", info.wavesSurvived or 0, info.maxWaves or 0))
	end

	if #parts == 0 then
		return "—"
	end

	return table.concat(parts, ", ")
end

function ResultController:applyResult(screen : ScreenGui, info)
	local panel = screen:FindFirstChild("ResultBackground")
	if not panel then return end

	local banner = panel:FindFirstChild("Result")
	local bannerLabel = banner and banner:FindFirstChild("PlayersReady")
	if bannerLabel and bannerLabel:IsA("TextLabel") then
		bannerLabel.Text = info.won and WIN_TEXT or LOSE_TEXT
	end

	local mvpLabel = panel:FindFirstChild("MVP")
	if mvpLabel and mvpLabel:IsA("TextLabel") then
		local mvp = info.mvp
		mvpLabel.Text = mvp and string.format("MVP: %s", mvp.name) or "MVP: —"
	end

	local rewardLabel = panel:FindFirstChild("RewardText")
	if rewardLabel and rewardLabel:IsA("TextLabel") then
		rewardLabel.Text = self:formatRewards(info)
	end

	-- O estado da votacao pode ter chegado antes do RoundReward: a ordem entre os
	-- dois eventos nao e garantida, entao reaplicamos o ultimo que veio.
	self:applyPlayAgainState()
	self:setLobbyButtonText(LOBBY_TEXT)
end

--[[ botoes ]]

function ResultController:findButton(name : string)
	local screen = PlayerGui:FindFirstChild("ResultScreen")
	local panel = screen and screen:FindFirstChild("ResultBackground")
	local button = panel and panel:FindFirstChild(name)
	return button and button:IsA("GuiButton") and button or nil
end

function ResultController:setLobbyButtonText(text : string)
	local button = self:findButton("BackToLobby")
	local label = button and button:FindFirstChild("Text")
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

-- Contador de votos no proprio botao de recomecar.
function ResultController:applyPlayAgainState()
	local state = self.playAgainState
	if not state then return end

	local button = self:findButton("PlayAgain")
	local label = button and button:FindFirstChild("PlayersReady")
	if label and label:IsA("TextLabel") then
		label.Text = string.format(PLAY_AGAIN_TEXT, state.votes or 0, state.total or 0)
	end
end

-- Reconectados a cada Show porque a ResultScreen e recriada no respawn.
function ResultController:bindButtons()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	local playAgain = self:findButton("PlayAgain")
	if playAgain then
		table.insert(self.connections, playAgain.MouseButton1Click:Connect(function()
			Framework:Fire("VotePlayAgain")
		end))
	end

	local backToLobby = self:findButton("BackToLobby")
	if backToLobby then
		table.insert(self.connections, backToLobby.MouseButton1Click:Connect(function()
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

	  1. tudo em transparencia 1, com a ScreenGui ainda desligada (sem flash)
	  2. BackgroundFrame  1 -> BACKDROP_TRANSPARENCY
	  3. PANEL_DELAY de espera
	  4. ResultBackground 1 -> valor original
	  5. cada descendente com transparencia, um a cada ELEMENT_STAGGER

	Mudou o ritmo, o easing ou a ordem? E aqui e nas constantes do topo — nenhum
	outro ponto do codigo conhece esses tweens.
]]
function ResultController:playRevealAnimation(screen : ScreenGui)
	if self.revealThread then
		pcall(task.cancel, self.revealThread)
		self.revealThread = nil
	end

	local backdrop = screen:FindFirstChild("BackgroundFrame")
	local panel = screen:FindFirstChild("ResultBackground")

	-- O backdrop nao usa snapshot: o alvo dele e a constante, nao o valor autoral.
	local backdropTarget = backdrop and {
		instance = backdrop,
		values = { BackgroundTransparency = BACKDROP_TRANSPARENCY },
	} or nil

	local panelValues = panel and self:snapshot(panel)
	local panelTarget = panelValues and { instance = panel, values = panelValues } or nil
	local targets = panel and self:collectTargets(panel) or {}

	-- Passo 1, sincrono: nada pode aparecer no frame em que a GUI liga.
	if backdropTarget then
		self:setTransparent(backdropTarget)
	end
	if panelTarget then
		self:setTransparent(panelTarget)
	end
	for _, target in targets do
		self:setTransparent(target)
	end

	screen.Enabled = true

	self.revealThread = task.spawn(function()
		if backdropTarget then
			self:fadeIn(backdropTarget, BACKDROP_TIME)
		end

		task.wait(PANEL_DELAY)

		if panelTarget then
			self:fadeIn(panelTarget, ELEMENT_TIME)
		end

		for _, target in targets do
			task.wait(ELEMENT_STAGGER)
			self:fadeIn(target, ELEMENT_TIME)
		end

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
	self:applyResult(screen, info)
	self:bindButtons()
	self:playRevealAnimation(screen)
end

function ResultController:Hide()
	if self.revealThread then
		pcall(task.cancel, self.revealThread)
		self.revealThread = nil
	end

	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	self.leaving = false
	self.playAgainState = nil

	local screen = PlayerGui:FindFirstChild("ResultScreen")
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
