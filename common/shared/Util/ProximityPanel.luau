local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Signal = require(Packages.Signal)
local LightingUtil = require(script.Parent.LightingUtil)

--[[
	Um painel do lobby que abre quando o jogador chega perto de um ponto do mapa e
	fecha quando ele sai: a loja de caixas, a de cartas e o quadro de contratos.

	Era o mesmo bloco copiado em cada controller -- a proximidade, a `OpenShop` do
	Cascade, o borrao do fundo, o pedido de tela ao `InterfaceController`, o X e o
	cuidado com o `ResetOnSpawn`. Aqui fica **so** isso; o que o painel mostra
	continua sendo do controller dele, que entra pelos ganchos:

	  - `OnBind(screenGui, wrapper, panel, maid)` -- cada copia nova da ScreenGui. O
	    `maid` e limpo no proximo bind, entao e onde vao as conexoes do conteudo.
	  - `BeforeOpen()` -- logo antes de o painel entrar, com ele ja aceso.

	**Proximidade: so a travessia age.** Entrar no raio abre e sair fecha; fechar no
	X parado ali nao reabre no tick seguinte, porque nada cruzou nada. O painel volta
	quando o jogador sai e entra de novo -- que e o que "fechei porque nao quero
	agora" quer dizer. `EnterRange` e para quem leva o jogador ate la por fora
	(o teleporte da HUD): marca a entrada e abre, senao a saida nunca aconteceria e o
	painel ficaria pendurado na tela.

	**A moldura de fora (`Wrapper`) e quem vai e vem**, e nao a ScreenGui: a `ShopUI`
	carrega duas lojas, e cada uma acende a sua moldura. O painel de dentro sobe
	aceso e fica assim -- a `OpenShop` cuida da entrada dele pela escala e pela
	transparencia. `CanDisable` e o outro lado disso: enquanto ele devolver false, o
	fechamento apaga so a moldura e deixa a ScreenGui para a vizinha.

	**Uma copia nova nasce apagada e devolve a tela.** Morrer com o painel aberto traz
	uma ScreenGui nova e zera o estado aqui; sem devolver, o pedido de esconder
	ficaria de pe com o painel fechado e o jogador renasceria sem HUD e com o fundo
	borrado.

	O Cascade mora so no place do Lobby (ver Lobby/README.md), e por isso e
	procurado na primeira vez que um painel liga, e nao no topo do arquivo: a Game
	tambem monta este modulo e nao tem o runtime.
]]

local CHARACTER_ROOT = "HumanoidRootPart"
local CLOSE_BUTTON_NAME = "Close"
local WAIT_TIMEOUT = 10

-- O borrao do fundo: o `UIBlur` compartilhado (`LightingUtil.GetUIBlur`), o mesmo
-- do `UILibraryController`. Dois borroes somariam, e o fundo sairia com o dobro.
local BLUR_SIZE = 24
local BLUR_FALLBACK_TIME = 0.25
local BLUR_EASING_STYLE = Enum.EasingStyle.Quad
local BLUR_EASING_DIRECTION = Enum.EasingDirection.Out

local DEFAULT_INTERVAL = 0.2

export type Options = {
	-- O nome que aparece nos avisos.
	Name : string,

	-- `PlayerGui.<ScreenGui>.<Wrapper>.<Panel>`. O `Panel` e a arte que a animacao
	-- escreve (`UIScale/Scale` e `ImageTransparency`).
	ScreenGui : string,
	Wrapper : string,
	Panel : string,

	-- O nome da animacao do Cascade. Sem ela o painel so acende e apaga.
	Animation : string?,

	-- O nome do pedido ao `InterfaceController`. Proprio por painel: dividir o nome
	-- faria um devolver a tela que o outro pediu.
	HideReason : string,

	-- O centro do raio, relido a cada medida (o mapa pode trocar a peca).
	GetReference : () -> Vector3?,
	Radius : number,
	Interval : number?,

	InterfaceController : any?,

	-- Se a ScreenGui pode apagar no fechamento. So faz falta quando ela e dividida.
	CanDisable : (() -> boolean)?,

	OnBind : ((screenGui : ScreenGui, wrapper : GuiObject, panel : GuiObject, maid : any) -> ())?,
	BeforeOpen : (() -> ())?,
}

local ProximityPanel = {}
ProximityPanel.__index = ProximityPanel

local AnimationService = nil

local function getAnimationService()
	if AnimationService == nil then
		local runtime = ReplicatedStorage:WaitForChild("CascadeRuntimeEngine")
		AnimationService = require(runtime:WaitForChild("AnimationService"))
	end

	return AnimationService
end

function ProximityPanel.new(options : Options)
	local self = setmetatable({}, ProximityPanel)

	self.Options = options

	self.Maid = Maid.new()

	-- O bind da copia atual da ScreenGui. Limpo a cada copia nova.
	self.BindMaid = Maid.new()

	-- O tween do borrao vive fora do bind: ele e do Lighting, e nao da ScreenGui.
	self.BlurMaid = Maid.new()

	self.Maid:GiveTask(self.BindMaid)
	self.Maid:GiveTask(self.BlurMaid)

	self.Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),
	}

	self.ScreenGui = nil
	self.Wrapper = nil
	self.Panel = nil
	self.Track = nil

	self.IsOpenState = false
	self.InRange = false
	self.ProximityClock = 0

	return self
end

--[[ INTERNAL ]]

--[=[
	Liga e desliga a ScreenGui, sempre pelo `InterfaceController` quando ele existe:
	e ele quem guarda o que o dono de cada GUI queria, e escrever no `Enabled` direto
	no meio de um pedido faria o valor certo ser lido tarde demais.
]=]
function ProximityPanel:_setEnabled(enabled : boolean)
	local screenGui = self.ScreenGui
	if not screenGui or not screenGui.Parent then
		return
	end

	if not enabled and self.Options.CanDisable and not self.Options.CanDisable() then
		return
	end

	local interface = self.Options.InterfaceController
	if interface then
		interface:SetEnabled(screenGui, enabled)
	else
		screenGui.Enabled = enabled
	end
end

--- O fim do fechamento: a moldura apaga, e a ScreenGui vai junto se puder.
function ProximityPanel:_hide()
	if self.Wrapper and self.Wrapper.Parent then
		self.Wrapper.Visible = false
	end

	self:_setEnabled(false)
end

--[=[
	O borrao sobe na abertura e desce no fechamento, no tempo da propria animacao --
	re-cronometrar a `OpenShop` no plugin leva o borrao junto. Um tween por vez:
	fechar no meio da abertura desce a partir de onde a subida chegou.
]=]
function ProximityPanel:_playBlur(open : boolean)
	self.BlurMaid:DoCleaning()

	local duration = (self.Track and self.Track.Duration) or BLUR_FALLBACK_TIME
	local info = TweenInfo.new(duration, BLUR_EASING_STYLE, BLUR_EASING_DIRECTION)

	local tween = LightingUtil.TweenUIBlur(if open then BLUR_SIZE else 0, info)
	if not tween then
		return
	end

	self.BlurMaid:GiveTask(function()
		tween:Cancel()
	end)
end

--- Devolve a tela: o resto da UI volta e o borrao sai. Idempotente.
function ProximityPanel:_releaseScreen()
	local interface = self.Options.InterfaceController
	if interface then
		interface:Show(self.Options.HideReason)
	end

	self:_playBlur(false)
end

--[=[
	A track e criada uma vez por copia e guardada: abrir e fechar e trocar a direcao
	da mesma animacao, entao fechar no meio da abertura continua de onde o painel
	chegou em vez de saltar.
]=]
function ProximityPanel:_playTrack(reverse : boolean)
	local track = self.Track
	if not track then
		return
	end

	if track.State ~= "Playing" then
		track:Scrub(reverse and track.Duration or 0)
	end

	track:SetSpeed(reverse and -1 or 1)
	track:Play()
end

function ProximityPanel:_bind(screenGui : ScreenGui)
	local options = self.Options

	local wrapper = screenGui:WaitForChild(options.Wrapper, WAIT_TIMEOUT)
	local panel = wrapper and wrapper:WaitForChild(options.Panel, WAIT_TIMEOUT)

	if not wrapper or not panel then
		warn(`[{options.Name}]: nao achei {options.ScreenGui}.{options.Wrapper}.{options.Panel}.`)
		return
	end

	self.BindMaid:DoCleaning()

	self.ScreenGui = screenGui
	self.Wrapper = wrapper
	self.Panel = panel

	wrapper.Visible = false
	panel.Visible = true

	--[[
		O X, se o designer autorou um. Procurado em profundidade a partir da moldura,
		e nao da ScreenGui: na `ShopUI` isso alcancaria o X da loja vizinha.
	]]
	local closeButton = wrapper:FindFirstChild(CLOSE_BUTTON_NAME, true)
	if closeButton and closeButton:IsA("GuiButton") then
		self.BindMaid:GiveTask(closeButton.Activated:Connect(function()
			self:Close()
		end))
	end

	self.Track = nil

	if options.Animation then
		--[[
			A `OpenShop` escreve em `UIScale/Scale`. Painel sem `UIScale` autorado
			apareceria por fade, sem crescer; criar um e inofensivo para quem ja tem o
			seu, porque a animacao acha o autorado primeiro.
		]]
		if not panel:FindFirstChildWhichIsA("UIScale") then
			local scale = Instance.new("UIScale")
			scale.Name = "PanelScale"
			scale.Parent = panel
		end

		self.Track = getAnimationService().CreateTrack(panel, options.Animation)

		if self.Track then
			local connection = self.Track.Completed:Connect(function()
				-- So a passada de fechamento termina com o painel fora da tela.
				if not self.IsOpenState and screenGui.Parent then
					self:_hide()
				end
			end)

			self.BindMaid:GiveTask(function()
				connection.Disconnect()
			end)
		end
	end

	self.IsOpenState = false
	self:_hide()
	self:_releaseScreen()

	-- Copia nova quer dizer respawn: o jogador pode continuar parado no ponto, e a
	-- proxima medida tem de abrir o painel novo.
	self.InRange = false

	if options.OnBind then
		options.OnBind(screenGui, wrapper, panel, self.BindMaid)
	end
end

function ProximityPanel:_updateProximity()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)
	local position = root and self.Options.GetReference()

	local inRange = false
	if position and root then
		inRange = (root.Position - position).Magnitude <= self.Options.Radius
	end

	if inRange == self.InRange then
		return
	end

	self.InRange = inRange

	if inRange then
		self:Open()
	else
		self:Close()
	end
end

--[[ API ]]

--- Comeca a seguir o `PlayerGui` e a distancia. Chamar uma vez, no `construct`.
function ProximityPanel:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenName = self.Options.ScreenGui

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == screenName then
			self:_bind(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end

	local interval = self.Options.Interval or DEFAULT_INTERVAL

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.ProximityClock += deltaTime

		if self.ProximityClock < interval then
			return
		end

		self.ProximityClock = 0
		self:_updateProximity()
	end))
end

function ProximityPanel:IsOpen() : boolean
	return self.IsOpenState == true
end

function ProximityPanel:Open()
	if not self.ScreenGui or not self.ScreenGui.Parent or self.IsOpenState then
		return
	end

	self.IsOpenState = true

	--[[
		O painel e a unica coisa na tela enquanto esta aberto. O `Except` e a propria
		ScreenGui, senao o pedido esconderia o painel que ele esta abrindo.
	]]
	local interface = self.Options.InterfaceController
	if interface then
		interface:Hide(self.Options.HideReason, { Except = { self.Options.ScreenGui } })
	end

	--[[
		Pelo `_setEnabled`, e nao no `Enabled` direto: o aviso de `Enabled` chega no fim
		do quadro, e o painel acende no **mesmo** instante em que o pedido varre as GUIs.
		Escrevendo direto, o pedido leria o `false` de antes como o que o dono queria.
	]]
	self:_setEnabled(true)

	-- A moldura acende **antes** da animacao, senao ela rodaria com o painel fora da
	-- tela e ele apareceria pronto no fim.
	if self.Wrapper and self.Wrapper.Parent then
		self.Wrapper.Visible = true
	end

	if self.Options.BeforeOpen then
		self.Options.BeforeOpen()
	end

	if self.Track then
		self:_playTrack(false)
	end

	self:_playBlur(true)

	self.Signals.OpenChanged:Fire(true)
end

function ProximityPanel:Close()
	if not self.ScreenGui or not self.IsOpenState then
		return
	end

	self.IsOpenState = false

	-- Devolvida no comeco do fechamento: o resto da UI volta **atras** do painel, em
	-- vez de aparecer de uma vez depois que ele sai.
	self:_releaseScreen()

	if self.Track then
		-- O painel sai quando a animacao invertida termina (ver `_bind`).
		self:_playTrack(true)
	else
		self:_hide()
	end

	self.Signals.OpenChanged:Fire(false)
end

function ProximityPanel:Toggle()
	if self.IsOpenState then
		self:Close()
	else
		self:Open()
	end
end

--[=[
	Para quem poe o jogador no ponto por fora da caminhada (o teleporte da HUD):
	marca a entrada e abre. Sem a marca, a travessia de saida nunca aconteceria e o
	painel ficaria na tela por mais longe que ele andasse.
]=]
function ProximityPanel:EnterRange()
	self.InRange = true
	self:Open()
end

function ProximityPanel:Destroy()
	self.Maid:DoCleaning()
end

return ProximityPanel
