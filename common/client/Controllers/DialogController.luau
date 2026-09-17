local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.DialogConfig

-- Quadros de paciência com o layout da caixa antes da primeira linha. Ver
-- `waitForLayout`.
local LAYOUT_FRAMES = 4

--[[
	A caixa de fala: `SharedUIs.DialogGUI.Container`.

	Este controller é o **único** que encosta nela. Quem tem algo a dizer manda as
	linhas prontas:

		local Dialog = Framework:Get("DialogController")

		Dialog:Play({
			"Bem-vindo ao [color=yellow]Periastron[/color].[pause=.6] Sente-se.",
			"A wave 8 traz [shake]NEVASCA[/shake].",
		})

	O texto é escrito pelo `RichTextController`, então a marcação de sempre vale
	aqui — inclusive `[event=nome]`, que chega em quem se inscreveu no `:OnEvent()`
	quando a digitação passa pela marca. É o gancho para sincronizar som, câmera ou
	VFX com um ponto da frase em vez de com um `task.wait` chutado.

	**Uma linha por vez, e o jogador passa.** Clique, toque, `E`, espaço, enter ou o
	A do controle: com a linha ainda sendo escrita, o gesto mostra ela inteira; com
	ela pronta, vai para a próxima; na última, fecha. É o contrato que todo jogo de
	fala tem, e é o que o jogador já sabe antes de a gente explicar. Fala pedida com
	`Auto = true` anda sozinha depois de `DialogConfig.AutoHold` segundos.

	**A tela mora no place, não no git** — `StarterGui` não é sincronizado pelo
	Rojo. Por isso o caminho é por nome (`DialogConfig.Gui`) e resolvido tarde: a
	`SharedUIs` pode não ter replicado quando o controller carrega, e um
	`WaitForChild` no `init` seguraria o boot do cliente por causa de uma caixa que
	talvez nem seja usada nesta sessão.

	Fica em `common/` porque as duas places têm a `SharedUIs`.
]]

local DialogController = {
	Controllers = {
		RichTextController = {}
	}
}

DialogController.Container = nil :: GuiObject?
DialogController.Screen = nil :: ScreenGui?
DialogController.Handle = nil :: any

-- A conversa no ar.
DialogController.Lines = {} :: { string }
DialogController.Index = 0
DialogController.Open = false

-- Fala que anda sozinha, sem o jogador passar.
DialogController.Auto = false

-- Uma sessão por `:Play()`: o `task.delay` do modo automático só vale enquanto
-- ninguém tiver começado outra conversa por cima.
DialogController.Session = 0

DialogController.LastAdvance = 0
DialogController.Listeners = {}
DialogController.Warned = false

--[[ INTERNAL ]]

--[=[
	A caixa, na primeira vez em que ela for precisa.

	Guardada depois de achada, e reachada quando o `Parent` some — a `PlayerGui` é
	remontada a cada respawn e a referência velha vira lixo.
]=]
function DialogController:getContainer() : GuiObject?
	local container = self.Container
	if container and container.Parent then
		return container
	end

	local gui = Config.Gui

	local folder = PlayerGui:FindFirstChild(gui.Folder)
	local screen = folder and folder:FindFirstChild(gui.Screen)
	local found = screen and screen:FindFirstChild(gui.Container)

	if not found or not found:IsA("GuiObject") then
		self:warnMissing()

		return nil
	end

	self.Container = found
	self.Screen = if screen:IsA("ScreenGui") then screen else nil

	-- O handle é do container: container novo (respawn, tela recriada) pede handle
	-- novo, senão escreveríamos num frame que não está mais na tela.
	self.Handle = nil

	return found
end

--[=[
	Barulho quando a caixa não aparece — uma vez só, para uma fala que se repete não
	virar spam.

	Place que não tem a `SharedUIs` não é engano e não merece warn: é a tela não
	existir ali. A `SharedUIs` existindo **sem** a `DialogGUI` é engano, e esse
	merece.
]=]
function DialogController:warnMissing()
	if self.Warned then return end
	if not PlayerGui:FindFirstChild(Config.Gui.Folder) then return end

	self.Warned = true
	warn(`[DialogController]: nao achei {Config.Gui.Folder}.{Config.Gui.Screen}.{Config.Gui.Container} na PlayerGui.`)
end

--[=[
	O handle de texto do container, criado uma vez e reusado.

	É aqui que o `[event=]` da fala vira o `:OnEvent()` de quem se inscreveu: a
	inscrição é no handle, e o handle é um só, então ela não se multiplica a cada
	fala.
]=]
function DialogController:getHandle(options : any) : any
	local container = self:getContainer()
	if not container then
		return nil
	end

	local RichText = self.Controllers.RichTextController

	if self.Handle then
		self.Handle:SetOptions(options)

		return self.Handle
	end

	local handle = RichText:Bind(container, options)
	if not handle then
		return nil
	end

	handle:OnEvent(function(name : string)
		for _, listener in self.Listeners do
			task.spawn(listener, name)
		end
	end)

	self.Handle = handle

	return handle
end

--[=[
	Mostra ou esconde a caixa.

	Mexe no `Enabled` da ScreenGui **e** no `Visible` do frame: o designer pode ter
	deixado qualquer um dos dois ligado no Studio, e a caixa aparecendo vazia no
	spawn é o defeito mais fácil de evitar daqui.
]=]
function DialogController:setVisible(visible : boolean)
	local container = self.Container
	if container then
		container.Visible = visible
	end

	local screen = self.Screen
	if screen then
		screen.Enabled = visible
	end
end

--[=[
	Espera a caixa ter tamanho de verdade antes de escrever nela.

	Duas razões. O renderizador **não desenha nada** num container que mede zero, e
	uma ScreenGui recém-ligada mede zero até o próximo quadro de layout — a fala
	simplesmente não apareceria. E o tamanho do container no instante do render é a
	referência de escala do texto daquela fala: pegá-lo antes do layout (antes do
	`UIAspectRatioConstraint`) fixa a escala num tamanho que nunca existiu na tela.

	O orçamento de quadros existe para o caso de a caixa nunca ganhar tamanho (tela
	desligada por outro controller): isso vira uma fala sem efeito, não uma espera
	infinita.
]=]
function DialogController:waitForLayout(container : GuiObject)
	local previous = container.AbsoluteSize

	for _ = 1, LAYOUT_FRAMES do
		RunService.Heartbeat:Wait()

		local current = container.AbsoluteSize
		if current.Magnitude > 0 and current == previous then
			return
		end

		previous = current
	end
end

--[=[
	Escreve a linha em que a conversa está.
]=]
function DialogController:write(session : number)
	local handle = self.Handle
	local line = self.Lines[self.Index]
	if not handle or not line then return end

	handle:Write(line)

	if not self.Auto then return end

	-- Fala automática: a linha fica `AutoHold` segundos depois de pronta. O
	-- `OnFinished` devolve a desinscrição, e ela é usada na hora — a próxima linha
	-- inscreve de novo, e uma inscrição por linha basta.
	local disconnect
	disconnect = handle:OnFinished(function()
		if disconnect then
			disconnect()
		end

		if self.Session ~= session then return end

		task.delay(Config.AutoHold, function()
			if self.Session ~= session then return end
			if not self.Open then return end

			self:Advance(true)
		end)
	end)
end

--[[ API ]]

export type PlayOptions = {
	Auto : boolean?,
	Preset : string?,
	Speed : number?,
}

--[=[
	Põe uma conversa na tela. `lines` é uma frase ou a lista delas.

	Devolve `false` quando não deu — caixa que não existe nesta place, ou texto rico
	sem backend nenhum. Conversa nova sempre derruba a que estiver no ar: fala é
	interrupção, e enfileirar diálogo velho atrás do novo é como o jogador acaba
	lendo o aviso da wave passada.
]=]
function DialogController:Play(lines : string | { string }, options : PlayOptions?) : boolean
	local list = if type(lines) == "table" then lines else { lines }
	if #list == 0 then
		return false
	end

	local resolved = table.clone(Config.Text)
	if options then
		for key, value in options do
			if key == "Auto" then continue end

			resolved[key] = value
		end
	end

	local handle = self:getHandle(resolved)
	if not handle then
		return false
	end

	self.Session += 1
	local session = self.Session

	self.Lines = list
	self.Index = 1
	self.Auto = options and options.Auto or false
	self.Open = true
	self.LastAdvance = os.clock()

	self:setVisible(true)
	self:waitForLayout(self.Container :: GuiObject)

	-- Outra conversa pode ter começado enquanto esperávamos o layout.
	if self.Session ~= session then
		return true
	end

	self:write(session)

	return true
end

--[=[
	O gesto do jogador: mostra a linha inteira se ela ainda está sendo escrita,
	senão vai para a próxima — e fecha, se era a última.

	`ignoreDebounce` é para quem não é dedo: o modo automático não precisa ser
	protegido de si mesmo.
]=]
function DialogController:Advance(ignoreDebounce : boolean?) : boolean
	if not self.Open then
		return false
	end

	if not ignoreDebounce then
		local now = os.clock()
		if now - self.LastAdvance < Config.Advance.Debounce then
			return false
		end

		self.LastAdvance = now
	end

	local handle = self.Handle
	if not handle then
		self:Close()

		return false
	end

	if handle:IsWriting() then
		handle:Skip()

		return true
	end

	if self.Index >= #self.Lines then
		self:Close()

		return false
	end

	self.Index += 1
	self:write(self.Session)

	return true
end

--[=[
	Fecha a caixa e esquece a conversa.
]=]
function DialogController:Close()
	self.Session += 1
	self.Open = false
	self.Lines = {}
	self.Index = 0

	if self.Handle then
		self.Handle:Clear(true)
	end

	self:setVisible(false)
end

function DialogController:IsOpen() : boolean
	return self.Open
end

--[=[
	Chama de volta quando a digitação passa por um `[event=nome]`. Devolve a função
	que desinscreve.
]=]
function DialogController:OnEvent(callback : (name : string) -> ()) : () -> ()
	table.insert(self.Listeners, callback)

	return function()
		local index = table.find(self.Listeners, callback)
		if index then
			table.remove(self.Listeners, index)
		end
	end
end

--[[ CICLO DE VIDA ]]

function DialogController:construct()
	-- O servidor manda falar. `DialogService` é quem dispara, e o Cmdr entra por
	-- ele para testar.
	Framework:Listen("DialogPlay", function(lines : any, options : any)
		if type(lines) ~= "table" and type(lines) ~= "string" then return end

		self:Play(lines, if type(options) == "table" then options else nil)
	end)

	UserInputService.InputBegan:Connect(function(input : InputObject, gameProcessed : boolean)
		if not self.Open then return end

		-- `gameProcessed` é o jogador digitando no chat ou no Cmdr: a tecla é de lá,
		-- não da fala.
		if gameProcessed then return end

		local advance = Config.Advance
		local kind = input.UserInputType

		local pressed = (advance.Mouse and kind == Enum.UserInputType.MouseButton1)
			or (advance.Touch and kind == Enum.UserInputType.Touch)
			or (kind == Enum.UserInputType.Keyboard or kind == Enum.UserInputType.Gamepad1)
			and table.find(advance.Keys, input.KeyCode) ~= nil

		if not pressed then return end

		self:Advance()
	end)
end

function DialogController:start()
	-- Caixa vazia na tela do spawn é o defeito mais barato de evitar: o designer
	-- autora a `DialogGUI` visível para poder vê-la no Studio.
	if self:getContainer() then
		self:setVisible(false)
	end
end

function DialogController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return DialogController
