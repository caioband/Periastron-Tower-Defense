local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local Me = require(Vendor.Me)
local Framework = Me.new()

local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local SELECTED_TRANSPARENCY = 0
local IDLE_TRANSPARENCY = 0.4

-- O frame do cadeado dentro do botao, e o rotulo dele. Botao sem `Locked` e um
-- botao que a arte declarou como sempre aberto -- ver `collectLock`.
local LOCK_NAME = "Locked"
local LOCK_LABEL_NAME = "Time"

local DifficultyController = {
	Buttons = {},

	-- O que a partida pede para a hotbar (dificuldade decidida ou não). Ver
	-- `setHotbarVisible`.
	HotbarWanted = false,

	-- Quem está segurando a hotbar fora da tela: `{ [motivo] = true }`. Ver `HoldHotbar`.
	HotbarHolds = {},

	-- { [dificuldade] = { Button, Frame, Label, WasActive, WasAutoButtonColor } }
	Locks = {},
}

local function formatClock(seconds : number)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

function DifficultyController:updateClock(state)
	local clock = self.clock
	if not clock then return end

	clock.Visible = state.active == true
	clock.Time.Text = formatClock(state.timeLeft or 0)
end

--[=[
	A hotbar so aparece com a dificuldade ja decidida. Antes disso nao ha partida
	nenhuma — o servidor esta esperando todo mundo carregar, ou a votacao esta
	aberta — e as cartas nao teriam onde ser colocadas.
]=]
function DifficultyController:setHotbarVisible(visible : boolean)
	self.HotbarWanted = visible == true

	self:applyHotbar()
end

--[=[
	Escreve o `Visible` do `TowerContainer`: a partida pede **e** ninguém segura.

	Continua havendo um dono só do interruptor (este controller); quem precisa da
	hotbar fora da tela por um tempo pede com `HoldHotbar`, em vez de escrever o
	`Visible` por fora — o `DifficultyLocked` ou o próximo estado da votação
	acenderiam a hotbar de volta no meio do pedido.
]=]
function DifficultyController:applyHotbar()
	if self.hotbar then
		self.hotbar.Visible = self.HotbarWanted and next(self.HotbarHolds) == nil
	end
end

--[=[
	Segura (ou solta) a hotbar fora da tela em nome de `reason`. Soltar o último
	pedido devolve a hotbar ao que a partida quer — se a dificuldade ainda não foi
	decidida, ela continua escondida.

	Hoje quem pede é o `TutorialStepController`, no passo do Ready (`HideDeck`).
]=]
function DifficultyController:HoldHotbar(reason : string, held : boolean)
	self.HotbarHolds[reason] = if held then true else nil

	self:applyHotbar()
end

--[=[
	Confere se cada botao do board tem um preset do outro lado.

	O nome da instancia **e** o voto: o controller dispara `SelectDifficulty` com
	ele, e o servidor recusa em silencio o que nao existir no `DifficultyConfig`.
	Um botao com o nome errado nao quebra nada visivelmente -- ele so nunca conta
	voto, e o jogador fica clicando num botao morto sem nenhum aviso em lugar
	nenhum.

	Foi exatamente o que aconteceu: o board tinha `Extreme` escrito "IMPOSSIBLE"
	(voto recusado, dificuldade inalcancavel) e `Impossible` escrito "NIGHTMARE"
	(voto aceito como Impossible, com o jogador lendo Nightmare e recebendo o
	premio da de baixo). Nenhum dos dois deixava rastro.

	A lista de presets so chega do servidor (`state.options`), entao a conferencia
	nao tem como acontecer no bind -- ela mora aqui, na primeira vez que um estado
	chega, e roda uma vez so.
]=]
function DifficultyController:auditButtons(options : { string }?)
	if self.audited or not options then return end
	self.audited = true

	local known = {}
	for _, name in options do
		known[name] = true
	end

	for name in self.Buttons do
		if not known[name] then
			warn(string.format(
				"[DifficultyController]: o botao '%s' do DifficultyBoard nao e uma dificuldade (%s). O voto dele e recusado pelo servidor -- renomeie a instancia para o nome do preset.",
				name, table.concat(options, ", ")))
		end
	end

	for _, name in options do
		if not self.Buttons[name] then
			warn(string.format(
				"[DifficultyController]: a dificuldade '%s' nao tem botao no DifficultyBoard; ninguem consegue votar nela.",
				name))
		end
	end
end

--[=[
	Guarda o cadeado de um botao, se ele tiver um.

	O estado de origem do botao vai junto (`WasActive`, `WasAutoButtonColor`) porque
	destrancar tem de **devolver** o que a arte autorou, e nao chutar `true`: um botao
	que nasceu sem `AutoButtonColor` nao pode ganhar o efeito ao abrir.
]=]
function DifficultyController:collectLock(button : ImageButton)
	local frame = button:FindFirstChild(LOCK_NAME)
	if not frame or not frame:IsA("GuiObject") then return end

	self.Locks[button.Name] = {
		Button = button,
		Frame = frame,
		Label = frame:FindFirstChild(LOCK_LABEL_NAME),
		WasActive = button.Active,
		WasAutoButtonColor = button.AutoButtonColor,
	}
end

--[=[
	As vitorias e o XP deste jogador, ou nil enquanto a replica nao chegou.

	Nil e o chute seguro: sem perfil, `isUnlocked` responde "trancado" e a tela mostra
	tudo travado. Errar para o outro lado abriria o Nightmare por um instante e o
	fecharia na cara do jogador quando o perfil chegasse.
]=]
function DifficultyController:stats() : { [string] : any }?
	local replica = self.replica
	local stats = replica and replica.Data and replica.Data.Stats

	return typeof(stats) == "table" and stats or nil
end

--[=[
	Pinta o cadeado de cada botao a partir do perfil de agora.

	Tres coisas mudam juntas, e por isso moram na mesma funcao: o `Locked` aparece, o
	botao para de responder e o rotulo diz o que falta. Deixar o botao vivo por baixo
	de um cadeado desenhado seria uma dificuldade que parece trancada e vota no clique.

	`Active = false` ja basta para o `MouseButton1Click` nao disparar -- o clique
	confere de novo mesmo assim, porque um botao sem `Locked` na arte nunca passa por
	aqui e continuaria clicavel.
]=]
function DifficultyController:renderLocks()
	local stats = self:stats()

	for name, lock in self.Locks do
		local unlocked = UnlockConfig.isUnlocked(name, stats)

		lock.Frame.Visible = not unlocked

		if lock.Label and not unlocked then
			lock.Label.Text = UnlockConfig.lockText(name, stats)
		end

		lock.Button.Active = unlocked and lock.WasActive
		lock.Button.AutoButtonColor = unlocked and lock.WasAutoButtonColor
	end
end

--[=[
	Segura a replica do jogador e repinta os cadeados a cada escrita em `Stats`.

	Mesmo formato do contador do HUD e do cadeado dos mapas: o `DataService` escreve a
	chave `Stats` inteira, mas a escuta e o `OnChange` para que a escrita mais funda
	(`Stats.DifficultyWins`) tambem conte. Assim a vitoria que abre o Hard aparece no
	board do proximo round sem o jogador trocar de servidor.
]=]
function DifficultyController:watchProfile()
	task.spawn(function()
		--[[
			O `DataController` e pedido aqui, e nao pela tabela `Controllers` que o resto
			dos controllers declara no topo: aquela tabela e preenchida no `start`, e este
			controller monta no `init`. Com a GUI ja na tela o `construct` nao cede em
			nenhum `WaitForChild` e termina inteiro antes de qualquer `start` rodar -- a
			referencia ainda seria o placeholder vazio. O `Get` com yield espera o loader.
		]]
		local dataController = Framework:Get("DataController", false, true)

		local replica = dataController:GetReplica()
		if not replica then return end

		self.replica = replica
		self:renderLocks()

		replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
				return
			end

			self:renderLocks()
		end)
	end)
end

function DifficultyController:updateUI(state)
	self:updateClock(state)
	self:setHotbarVisible(state.locked ~= nil)

	self:auditButtons(state.options)

	local board = self.board
	if not board then return end

	board.Visible = state.active == true

	local countdown = board:FindFirstChild("Countdown")
	if countdown then
		countdown.Text = tostring(state.timeLeft or 0) .. "s"
	end

	local votes = state.votes or {}

	for name, button in self.Buttons do
		local isSelected = state.selected == name

		if not state.selected or isSelected then
			button.ImageTransparency = SELECTED_TRANSPARENCY
		else
			button.ImageTransparency = IDLE_TRANSPARENCY
		end

		local voteLabel = button:FindFirstChild("VoteCount")
		if voteLabel then
			voteLabel.Text = tostring(votes[name] or 0)
		end
	end
end

function DifficultyController:construct()
	local Interface = PlayerGui:WaitForChild("Interface", 60)
	local clock = Interface and Interface:WaitForChild("Clock", 60)
	if clock and clock:FindFirstChild("Time") then
		self.clock = clock
		clock.Visible = false
	end

	local hotbar = Interface and Interface:WaitForChild("TowerContainer", 60)
	if hotbar then
		self.hotbar = hotbar

		-- Escondida de saida: o cliente costuma terminar de carregar antes de o
		-- servidor abrir a votacao, e ate o primeiro estado chegar nao ha partida.
		hotbar.Visible = false
	end

	local screen = PlayerGui:WaitForChild("Difficulty", 60)
	if not screen then return end

	self.board = screen:WaitForChild("DifficultyBoard", 60)
	if not self.board then return end

	self.board.Visible = false

	for _, child in self.board:GetChildren() do
		if child:IsA("ImageButton") then
			self.Buttons[child.Name] = child
			self:collectLock(child)

			child.MouseButton1Click:Connect(function()
				if not UnlockConfig.isUnlocked(child.Name, self:stats()) then return end

				Framework:Fire("SelectDifficulty", child.Name)
			end)
		end
	end

	-- Antes de a replica chegar tudo aparece trancado, e e assim que fica se ela nunca
	-- chegar: o servidor recusaria o voto de qualquer jeito.
	self:renderLocks()
	self:watchProfile()

	Framework:Listen("DifficultySelection", function(state)
		self:updateUI(state)
	end)

	Framework:Listen("DifficultyLocked", function(difficultyName)
		self.Locked = difficultyName
		self.board.Visible = false

		self:setHotbarVisible(true)

		if self.clock then
			self.clock.Visible = false
		end
	end)
end

function DifficultyController:start()
end

function DifficultyController:init()
	self:construct()
end

return DifficultyController
