local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local MapConfig = SharedConfig.MapConfig
local PortalConfig = SharedConfig.PortalConfig

local Framework = Me.new()

--[[ CONSTANTS ]]
local CHOOSE_MAPS_UI_NAME = "ChooseMaps"

local PANEL_NAME = "Lobby"
local BACKGROUND_NAME = "Background"
local SCROLL_NAME = "Scroll"
local TEMPLATE_NAME = "Map"
local ICON_NAME = "Icon"

local COUNT_LABEL_NAME = "MaxPlrs"
local INCREASE_NAME = "IncreasePlrs"
local LOWER_NAME = "LowerPlrs"
local ACTIONS_NAME = "Frame"
local CLOSE_NAME = "Exit"
local CONFIRM_NAME = "Confirm"

local ENTRY_NAME_PREFIX = "Map_"
local CHECKMARK_NAME = "CheckMark"
local ENTRY_SCALE_NAME = "SelectionScale"

--[[
	O cadeado do template: o `Frame` que cobre a carta e o rotulo de dentro dele que
	diz quantas vitorias faltam.

	O rotulo se chama `MaxPlrs` como o contador de jogadores do painel, e os dois nao
	se confundem porque este e procurado **dentro do `Locked`** e o outro direto no
	painel -- nenhuma das duas buscas e recursiva.
]]
local LOCKED_NAME = "Locked"
local LOCKED_LABEL_NAME = "MaxPlrs"

-- O texto do cadeado. O `%d` e quantas vitorias ainda faltam, e nao quantas o mapa
-- pede: "faltam 2" e o que o jogador precisa saber, e o total ele descobre sozinho.
local LOCKED_FORMAT = "%d MORE WINS REQUIRED"

-- Same curves the crate panel uses, so both panels read as the same UI.
local OPEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FADE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SELECT_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local OPEN_FROM_SCALE = 0.85
local CLOSE_TO_SCALE = 0.9

local SELECTED_SCALE = 1.05

-- The panel takes the screen for itself while it is open; the rest of the lobby UI
-- comes back on close. Named so the cutscene can hide things over it without the two
-- undoing each other.
local HIDE_REASON = "ChooseMaps"

--[=[
	Owns the ChooseMaps panel: the map list, the player-count stepper and the open /
	close animation.

	Picking a card only selects it -- its CheckMark shows up and so does Confirm, and
	the map is not sent anywhere until Confirm is pressed. It does not talk to the
	server either: PortalController is the one that opens the panel, and it hears back
	through MapChosen.
]=]
local ChooseMapsController = {
	Controllers = {
		InterfaceController = {},

		-- De onde saem as vitorias que destrancam os mapas. Ver `_watchWins`.
		DataController = {},
	},

	Signals = {
		-- (mapName : string, maxPlayers : number) -- fired by Confirm, not by the card
		MapChosen = Signal.new(),
		-- (mapName : string?)
		SelectionChanged = Signal.new(),
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

function ChooseMapsController:_playTween(object : Instance, info : TweenInfo, goal : { [string]: any }, maid) : Tween
	local tween = TweenService:Create(object, info, goal)

	;(maid or self.TweenMaid):GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
	return tween
end

--[=[
	The ImageLabel a map thumbnail goes into. The template nests it as
	Map.ImageLabel.Icon.ImageLabel, and it falls back to the button itself so a
	simpler template still shows something.
]=]
function ChooseMapsController:_findIcon(entry : Instance) : ImageLabel?
	local icon = entry:FindFirstChild(ICON_NAME, true)
	local target = icon and icon:FindFirstChildWhichIsA("ImageLabel")

	if target then
		return target
	end

	return entry:IsA("ImageButton") and entry or nil
end

--[=[
	The mark that says "this is the one": the CheckMark frame the template already
	carries. It is authored art, not something built here -- a template without one
	still works, it just has nothing to light up.
]=]
function ChooseMapsController:_findCheckMark(entry : Instance) : GuiObject?
	local checkMark = entry:FindFirstChild(CHECKMARK_NAME, true)
	if not checkMark or not checkMark:IsA("GuiObject") then
		return nil
	end

	checkMark.Visible = false
	return checkMark
end

--[=[
	O cadeado da carta: o `Frame` autorado que a cobre, e o rotulo de dentro onde as
	vitorias que faltam sao escritas.

	Como o `CheckMark`, ele e arte do template e nao e construido aqui -- um template
	sem ele continua funcionando, o mapa so nunca parece trancado. Nasce escondido:
	quem o acende e o `_renderLocks`, ja sabendo quantas vitorias o jogador tem.
]=]
function ChooseMapsController:_findLock(entry : Instance) : (GuiObject?, TextLabel?)
	local locked = entry:FindFirstChild(LOCKED_NAME, true)
	if not locked or not locked:IsA("GuiObject") then
		return nil, nil
	end

	locked.Visible = false

	local label = locked:FindFirstChild(LOCKED_LABEL_NAME)

	return locked, (label and label:IsA("TextLabel")) and label or nil
end

--[=[
	Rebuilds one entry per configured map, using the first template inside Scroll as
	the source. The extra copies the designer left in there are dropped: the list is
	whatever MapConfig says it is.
]=]
function ChooseMapsController:_buildEntries(scroll : Instance, template : Instance)
	for _, child in scroll:GetChildren() do
		if child ~= template and child.Name == TEMPLATE_NAME then
			child:Destroy()
		end
	end

	template.Visible = false
	self.Entries = {}

	for index, mapName in MapConfig.getOrderedMaps() do
		local info = MapConfig.MAPS[mapName]

		local entry = template:Clone()
		entry.Name = ENTRY_NAME_PREFIX .. mapName

		-- A posicao na lista **e** a ordem: o `getOrderedMaps` ja devolve os mapas do
		-- mais barato para o mais caro em vitorias, e nao ha um segundo numero no
		-- config para desencontrar deste.
		entry.LayoutOrder = index
		entry.Visible = true

		local icon = self:_findIcon(entry)
		if icon and info.Image and info.Image ~= "" then
			icon.Image = info.Image
		end

		-- Optional: a template that grows a label named MapName gets it filled in.
		local nameLabel = entry:FindFirstChild("MapName", true)
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = info.DisplayName or mapName
		end

		local scale = Instance.new("UIScale")
		scale.Name = ENTRY_SCALE_NAME
		scale.Parent = entry

		if entry:IsA("GuiButton") then
			self.UiMaid:GiveTask(entry.Activated:Connect(function()
				self:Select(mapName)
			end))
		end

		entry.Parent = scroll

		local locked, lockedLabel = self:_findLock(entry)

		self.Entries[mapName] = {
			Button = entry,
			CheckMark = self:_findCheckMark(entry),
			Scale = scale,
			Locked = locked,
			LockedLabel = lockedLabel,

			--[[
				O estado autorado do botao, lido e nao presumido: destrancar devolve o
				que o template trazia, e nao um `true` escrito na mao aqui. E a mesma
				razao do `wasAnchored` do gesto das cartas -- devolver um valor inventado
				e mexer no que nao era nosso para mexer.
			]]
			WasActive = entry:IsA("GuiButton") and entry.Active,
			WasAutoButtonColor = entry:IsA("GuiButton") and entry.AutoButtonColor,
		}

		self.UiMaid:GiveTask(entry)
	end

	self:_renderLocks()
end

--[=[
	Quantas vitorias o jogador tem, ou zero enquanto a replica nao chegou.

	Zero e o chute seguro: com ele so o que e livre aparece livre. Errar para o outro
	lado abriria um mapa por um instante e o fecharia na cara do jogador quando o
	perfil chegasse.
]=]
function ChooseMapsController:_getWins() : number
	local replica = self.Replica
	local stats = replica and replica.Data and replica.Data.Stats

	return typeof(stats) == "table" and tonumber(stats.Wins) or 0
end

--[=[
	Pinta o cadeado de cada carta a partir das vitorias de agora.

	Tres coisas mudam juntas, e por isso moram na mesma funcao: o `Locked` aparece, o
	botao para de responder e o rotulo diz quanto falta. Deixar o botao vivo por baixo
	de um cadeado desenhado seria um mapa que parece trancado e abre no clique.

	`Active = false` ja e o bastante para o `Activated` nao disparar -- o `Select`
	confere de novo mesmo assim, porque ele tambem e chamado de fora.
]=]
function ChooseMapsController:_renderLocks()
	local wins = self:_getWins()

	for mapName, entry in self.Entries do
		local unlocked = MapConfig.isUnlocked(mapName, wins)

		if entry.Locked then
			entry.Locked.Visible = not unlocked
		end

		if entry.LockedLabel and not unlocked then
			entry.LockedLabel.Text = string.format(LOCKED_FORMAT, MapConfig.winsMissing(mapName, wins))
		end

		local button = entry.Button
		if button:IsA("GuiButton") then
			button.Active = unlocked and entry.WasActive
			button.AutoButtonColor = unlocked and entry.WasAutoButtonColor
		end
	end

	--[[
		Uma vitoria nao tranca mapa nenhum -- o numero so sobe --, entao a selecao nunca
		fica presa num mapa que fechou. A rede existe para o caso de o `WinsRequired`
		subir num patch com o painel aberto: o `Confirm` some junto com a selecao, em vez
		de mandar ao servidor um mapa que ele vai recusar.
	]]
	if self.Selected and not MapConfig.isUnlocked(self.Selected, wins) then
		self.Selected = nil
		self:_renderSelection()
		self.Signals.SelectionChanged:Fire(nil)
	end
end

--[=[
	Segura a replica do jogador e repinta os cadeados a cada mudanca em `Stats`.

	Mesmo formato do contador do HUD e do da loja: o `DataService` escreve a chave
	`Stats` inteira, mas a escuta e o `OnChange` para que qualquer escrita mais funda
	(`Stats.Wins`) tambem conte. O jogador volta da partida com uma vitoria a mais e o
	mapa destranca sem ele reabrir o painel.
]=]
function ChooseMapsController:_watchWins()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_renderLocks()

		local connection = replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
				return
			end

			self:_renderLocks()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	Paints the selection: the picked card wears its CheckMark and stands a little proud
	of the others, and Confirm only exists once there is something to confirm.
]=]
function ChooseMapsController:_renderSelection(immediate : boolean?)
	self.SelectionMaid:DoCleaning()

	for mapName, entry in self.Entries do
		local isSelected = mapName == self.Selected

		if entry.CheckMark then
			entry.CheckMark.Visible = isSelected
		end

		local goal = isSelected and SELECTED_SCALE or 1
		if immediate then
			entry.Scale.Scale = goal
		elseif entry.Scale.Scale ~= goal then
			self:_playTween(entry.Scale, SELECT_INFO, { Scale = goal }, self.SelectionMaid)
		end
	end

	if self.ConfirmButton then
		self.ConfirmButton.Visible = self.Selected ~= nil
	end
end

function ChooseMapsController:_renderCount()
	local count = self.PlayerCount

	if self.CountLabel and self.CountLabel:IsA("TextLabel") then
		self.CountLabel.Text = tostring(count)
	end

	-- At either end the step that cannot happen is not greyed out, it is gone.
	if self.IncreaseButton then
		self.IncreaseButton.Visible = count < PortalConfig.MAX_PLAYERS
	end

	if self.LowerButton then
		self.LowerButton.Visible = count > PortalConfig.MIN_PLAYERS
	end
end

function ChooseMapsController:_step(delta : number)
	local count = math.clamp(self.PlayerCount + delta, PortalConfig.MIN_PLAYERS, PortalConfig.MAX_PLAYERS)
	if count == self.PlayerCount then
		return
	end

	self.PlayerCount = count
	self:_renderCount()
end

function ChooseMapsController:_setOpen(open : boolean)
	local panel = self.Panel
	if not panel or not panel.Parent or not self.PanelScale then
		return
	end

	if open == self.IsOpenState then
		return
	end

	self.IsOpenState = open
	self.TweenMaid:DoCleaning()

	if open then
		-- Every opening starts over at one player and no map picked, like the panel
		-- was never used.
		self.PlayerCount = PortalConfig.MIN_PLAYERS
		self.Selected = nil

		self:_renderCount()
		self:_renderSelection(true)

		-- The panel is the only thing on screen while it is up: the HUD, the shop and
		-- whatever else the lobby has go away, and come back on close.
		self.Controllers.InterfaceController:Hide(HIDE_REASON, { Except = { CHOOSE_MAPS_UI_NAME } })

		self.Controllers.InterfaceController:SetEnabled(self.ScreenGui, true)

		self.PanelScale.Scale = OPEN_FROM_SCALE
		panel.Visible = true

		self:_playTween(self.PanelScale, OPEN_INFO, { Scale = 1 })

		if self.Background then
			self.Background.ImageTransparency = 1
			self:_playTween(self.Background, FADE_INFO, { ImageTransparency = 0 })
		end
	else
		-- Given back at the top of the close, not at the end of it: the rest of the UI
		-- fades in behind the panel instead of popping in after it is gone.
		self.Controllers.InterfaceController:Show(HIDE_REASON)

		self:_playTween(self.PanelScale, CLOSE_INFO, { Scale = CLOSE_TO_SCALE })

		local fade = self.Background and self:_playTween(self.Background, CLOSE_INFO, { ImageTransparency = 1 })
		local function finish(state : Enum.PlaybackState)
			-- Reopened mid-fade: the open tween owns the panel now.
			if state == Enum.PlaybackState.Completed and not self.IsOpenState then
				panel.Visible = false
				--[[
					Pelo `SetEnabled`, e não no `Enabled` direto: o painel fecha em 0.18s, e
					nesse intervalo o portal pode pedir a tela para a contagem regressiva.
					Escrevendo direto, o pedido já teria desligado a `ScreenGui` antes, esta
					linha não mudaria nada — e o controller continuaria achando que o dono a
					queria ligada, reacendendo um painel vazio quando o pedido saísse.
				]]
				self.Controllers.InterfaceController:SetEnabled(self.ScreenGui, false)
			end
		end

		if fade then
			fade.Completed:Once(finish)
		else
			task.delay(CLOSE_INFO.Time, finish, Enum.PlaybackState.Completed)
		end
	end

	self.Signals.OpenChanged:Fire(open)
end

--[=[
	Binds to a ChooseMaps instance. The ScreenGui has ResetOnSpawn enabled, so this
	runs again for every fresh copy the engine parents into PlayerGui.
]=]
function ChooseMapsController:_bindUI(screenGui : ScreenGui)
	self.UiMaid:DoCleaning()
	self.TweenMaid:DoCleaning()

	local panel = screenGui:WaitForChild(PANEL_NAME, 10)
	local scroll = panel and panel:WaitForChild(SCROLL_NAME, 10)
	local template = scroll and scroll:WaitForChild(TEMPLATE_NAME, 10)

	if not panel or not scroll or not template then
		warn(`[ChooseMapsController]: Could not find {CHOOSE_MAPS_UI_NAME}.{PANEL_NAME}.{SCROLL_NAME}.{TEMPLATE_NAME}.`)
		return
	end

	local panelScale = panel:FindFirstChildWhichIsA("UIScale")
	if not panelScale then
		panelScale = Instance.new("UIScale")
		panelScale.Name = "PanelScale"
		panelScale.Parent = panel
	end

	self.ScreenGui = screenGui
	self.Panel = panel
	self.PanelScale = panelScale
	self.Background = panel:FindFirstChild(BACKGROUND_NAME)

	self.CountLabel = panel:FindFirstChild(COUNT_LABEL_NAME)
	self.IncreaseButton = panel:FindFirstChild(INCREASE_NAME)
	self.LowerButton = panel:FindFirstChild(LOWER_NAME)

	if self.IncreaseButton and self.IncreaseButton:IsA("GuiButton") then
		self.UiMaid:GiveTask(self.IncreaseButton.Activated:Connect(function()
			self:_step(1)
		end))
	end

	if self.LowerButton and self.LowerButton:IsA("GuiButton") then
		self.UiMaid:GiveTask(self.LowerButton.Activated:Connect(function()
			self:_step(-1)
		end))
	end

	local actions = panel:FindFirstChild(ACTIONS_NAME)
	local closeButton = actions and actions:FindFirstChild(CLOSE_NAME)
	if closeButton and closeButton:IsA("GuiButton") then
		self.UiMaid:GiveTask(closeButton.Activated:Connect(function()
			self:Close()
		end))
	end

	self.ConfirmButton = actions and actions:FindFirstChild(CONFIRM_NAME)
	if self.ConfirmButton and self.ConfirmButton:IsA("GuiButton") then
		self.UiMaid:GiveTask(self.ConfirmButton.Activated:Connect(function()
			self:Confirm()
		end))
	end

	self:_buildEntries(scroll, template)

	-- The panel starts closed: the portal is what opens it. A respawn lands here with
	-- the panel open (ResetOnSpawn), so the screen is handed back too -- otherwise the
	-- rest of the UI would stay hidden with nothing left to close.
	self.IsOpenState = false
	self.PlayerCount = PortalConfig.MIN_PLAYERS
	self.Selected = nil

	self.Controllers.InterfaceController:Show(HIDE_REASON)

	self:_renderCount()
	self:_renderSelection(true)

	panel.Visible = false
	screenGui.Enabled = false
end

function ChooseMapsController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child.Name ~= CHOOSE_MAPS_UI_NAME or not child:IsA("ScreenGui") then
			return
		end

		self:_bindUI(child)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

function ChooseMapsController:IsOpen() : boolean
	return self.IsOpenState == true
end

--[=[
	How many players the panel is currently set to bring along.
]=]
function ChooseMapsController:GetPlayerCount() : number
	return self.PlayerCount or PortalConfig.MIN_PLAYERS
end

--[=[
	The map the player picked, or nil while nothing is picked.
]=]
function ChooseMapsController:GetSelected() : string?
	return self.Selected
end

--[=[
	Picks a map. Nothing is sent yet -- Confirm is what closes the deal.

	Mapa trancado nao e escolhido: o botao dele ja esta morto (`_renderLocks`), e a
	conferencia aqui e para quem chama de fora -- o `Select` e API publica, e o
	`PortalController` pode pedir um mapa por nome.
]=]
function ChooseMapsController:Select(mapName : string?)
	local resolvedMap = MapConfig.resolveMap(mapName)
	if resolvedMap == self.Selected then
		return
	end

	if resolvedMap and not MapConfig.isUnlocked(resolvedMap, self:_getWins()) then
		return
	end

	self.Selected = resolvedMap
	self:_renderSelection()

	self.Signals.SelectionChanged:Fire(resolvedMap)
end

--[=[
	Sends the picked map off. Does nothing while no map is picked -- which is also
	when Confirm is not on screen.
]=]
function ChooseMapsController:Confirm() : boolean
	if not self.Selected then
		return false
	end

	self.Signals.MapChosen:Fire(self.Selected, self.PlayerCount)
	return true
end

function ChooseMapsController:Open()
	self:_setOpen(true)
end

function ChooseMapsController:Close()
	self:_setOpen(false)
end

function ChooseMapsController:Toggle()
	self:_setOpen(not self.IsOpenState)
end

function ChooseMapsController:construct()
	self:_observeUI()
	self:_watchWins()
end

function ChooseMapsController:start()

end

function ChooseMapsController:init()
	self.Maid = Maid.new()
	self.UiMaid = Maid.new()
	self.TweenMaid = Maid.new()
	self.SelectionMaid = Maid.new()

	self.Maid:GiveTask(self.UiMaid)
	self.Maid:GiveTask(self.TweenMaid)
	self.Maid:GiveTask(self.SelectionMaid)

	self.IsOpenState = false
	self.PlayerCount = PortalConfig.MIN_PLAYERS
	self.Entries = {}
	self.Selected = nil

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return ChooseMapsController
