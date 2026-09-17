local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.HighlightConfig

--[[
	O holofote: a tela escurece menos um retângulo em volta de um GuiObject.

		local Highlight = Framework:Get("HighlightController")

		Highlight:Show(shopButton)
		Highlight:Show(deckButton, { Padding = 16 })   -- escorrega do anterior
		Highlight:Hide()

	**A técnica é o `UIStroke` gigante.** Um frame transparente com um `UIStroke` de
	dez mil pixels pinta tudo o que está **fora** dele: o frame é o buraco, o stroke
	é o escuro, o `UICorner` arredonda, e não existe imagem, máscara de quatro
	partes nem `EditableImage` para manter alinhada. É a solução que o DevForum
	converge para este efeito, e a mais barata de todas — uma instância.

	**O clique é outro assunto.** Stroke não recebe input: ele é contorno, não
	superfície. Então o escurecimento sozinho deixaria o jogador comprar uma carta
	no escuro enquanto o tutorial aponta a loja. Para isso, e só para isso, entram
	quatro frames `Active` em volta do buraco (`HighlightConfig.BlockInput`) — a
	técnica das quatro máscaras, usada onde ela ganha do stroke.

	**O alinhamento é medido, não calculado.** `AbsolutePosition` vive no espaço com
	a inset da topbar: numa `ScreenGui` com `IgnoreGuiInset = true` — que é o caso
	desta, para o escuro cobrir a faixa de cima —, um frame no canto superior
	esquerdo reporta `(0, -36)`. É intencional da Roblox, por compatibilidade. Em
	vez de somar 36 na mão (ou chamar `GuiService:GetGuiInset`, que devolve zero nos
	primeiros quadros depois do boot — justo quando um tutorial roda), o controller
	mantém um frame-sonda de tamanho zero na origem da própria tela e lê a posição
	dele. A diferença entre a sonda e o alvo é a resposta, e ela continua certa em
	qualquer aparelho, com ou sem inset, e mesmo que a regra mude.

	**Segue o alvo.** O destaque reage ao `AbsolutePosition` e ao `AbsoluteSize` do
	alvo e ao tamanho do viewport, e não fica varrendo a tela a cada quadro: o
	`RenderStepped` do exemplo de sempre desenha sessenta vezes por segundo para um
	botão de HUD que não sai do lugar.

	**Nada aqui é pixel cravado.** A posição e o tamanho são copiados do alvo, então
	valem em qualquer resolução; a folga e o raio do canto são frações do menor lado
	do alvo, com chão e teto, porque 8px de folga num botão de 200px é um detalhe e
	no mesmo botão a 60px é uma moldura. Alvo dentro de algo que corta
	(`ScrollingFrame`) tem o retângulo cortado junto, e sumindo de vista o destaque
	**suspende** em vez de morrer: o alvo continua apontado e volta a brilhar quando
	o jogador rolar de volta. Só alvo tirado da `PlayerGui` apaga de vez.

	> O que não é coberto: alvo **rotacionado**. `AbsolutePosition`/`AbsoluteSize`
	> descrevem a caixa sem rotação, então o buraco sairia torto — e o `UIStroke` não
	> tem como recortar em diagonal. Rotação de UI aqui hoje não existe.

	Fica em `common/` porque as duas places têm botão para apontar.
]]

local HighlightController = {
	Controllers = {}
}

HighlightController.Gui = nil :: ScreenGui?
HighlightController.Hole = nil :: Frame?
HighlightController.Corner = nil :: UICorner?
HighlightController.Stroke = nil :: UIStroke?
HighlightController.Origin = nil :: Frame?
HighlightController.Blockers = {} :: { Frame }

HighlightController.Target = nil :: GuiObject?
HighlightController.Options = nil :: any

-- O que está ligado ao alvo de agora. Trocar de alvo limpa tudo de uma vez.
HighlightController.TargetMaid = nil :: any

HighlightController.FadeTween = nil :: Tween?
HighlightController.MoveTween = nil :: Tween?

-- Alvo apontado que **agora** não está na tela: rolou para fora do ScrollingFrame,
-- ficou invisível. O destaque sai, o alvo continua sendo seguido, e ele volta
-- quando o alvo voltar. Ver `suspend`.
HighlightController.Suspended = false

--[[ INTERNAL ]]

local function create(className : string, properties : { [string] : any }, parent : Instance?) : any
	local instance = Instance.new(className)

	for property, value in properties do
		(instance :: any)[property] = value
	end

	if parent then
		instance.Parent = parent
	end

	return instance
end

--[=[
	Monta a tela do destaque. Uma vez por sessão.
]=]
function HighlightController:build()
	if self.Gui and self.Gui.Parent then
		return
	end

	local gui = create("ScreenGui", {
		Name = Config.Gui.Name,
		ResetOnSpawn = false,
		IgnoreGuiInset = Config.Gui.IgnoreGuiInset,
		DisplayOrder = Config.Gui.DisplayOrder,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
	}, PlayerGui)

	-- A sonda: tamanho zero, posição zero, invisível. Ela não desenha nada — existe
	-- só para o `AbsolutePosition` dela dizer onde fica a origem desta tela no
	-- mesmo espaço em que o alvo é medido.
	self.Origin = create("Frame", {
		Name = "Origin",
		Size = UDim2.fromOffset(0, 0),
		Position = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Visible = false,
	}, gui)

	local hole = create("Frame", {
		Name = "Hole",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0),
		Position = UDim2.fromOffset(0, 0),
	}, gui)

	self.Corner = create("UICorner", { CornerRadius = UDim.new(0, Config.Hole.Radius.Min) }, hole)

	self.Stroke = create("UIStroke", {
		Thickness = Config.Hole.Thickness,
		Color = Config.Hole.Color,
		Transparency = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, hole)

	-- Os quatro que engolem o clique de fora. Invisíveis: quem escurece é o stroke.
	self.Blockers = {}
	for index = 1, 4 do
		self.Blockers[index] = create("Frame", {
			Name = `Blocker{index}`,
			BackgroundTransparency = 1,
			Active = true,
			Visible = false,
			Size = UDim2.fromOffset(0, 0),
		}, gui)
	end

	self.Gui = gui
	self.Hole = hole
end

--[=[
	Onde fica o canto superior esquerdo desta tela, no espaço em que os alvos são
	medidos. Lido toda vez, e não guardado: a inset muda (topbar some numa cutscene,
	aparece de volta) e o valor de boot não vale para sempre.
]=]
function HighlightController:origin() : Vector2
	local probe = self.Origin

	return if probe then probe.AbsolutePosition else Vector2.zero
end

--[=[
	O retângulo do destaque agora, em coordenadas desta tela: a caixa do alvo mais a
	folga.
]=]
function HighlightController:rect() : (Vector2?, Vector2?)
	local target = self.Target
	if not target or not target.Parent or not target.Visible then
		return nil
	end

	local padding = self:measure(Config.Hole.Padding, target.AbsoluteSize)
	if self.Options and self.Options.Padding then
		padding = self.Options.Padding
	end

	local position = target.AbsolutePosition - Vector2.new(padding, padding)
	local size = target.AbsoluteSize + Vector2.new(padding * 2, padding * 2)

	-- Recorte pelos ancestrais que cortam. Alvo dentro de ScrollingFrame que rolou
	-- para fora não pode ser apontado onde ele não está mais sendo desenhado: ou o
	-- destaque acompanha o pedaço visível, ou some enquanto não houver pedaço
	-- nenhum. Sem isto, rolar a lista deixaria um buraco no escuro apontando para
	-- um botão que o jogador não vê.
	local ancestor = target.Parent
	while ancestor and ancestor:IsA("GuiObject") do
		if ancestor.ClipsDescendants then
			local clipMin = ancestor.AbsolutePosition
			local clipMax = clipMin + ancestor.AbsoluteSize

			local minX = math.max(position.X, clipMin.X)
			local minY = math.max(position.Y, clipMin.Y)
			local maxX = math.min(position.X + size.X, clipMax.X)
			local maxY = math.min(position.Y + size.Y, clipMax.Y)

			if maxX <= minX or maxY <= minY then
				return nil
			end

			position = Vector2.new(minX, minY)
			size = Vector2.new(maxX - minX, maxY - minY)
		end

		ancestor = ancestor.Parent
	end

	return position - self:origin(), size
end

--[=[
	Um número proporcional ao alvo, com chão e teto: a folga e o raio do buraco.

	A referência é o **menor lado** do alvo, e não a tela: o que precisa parecer
	folga é a distância até a borda do botão, e um botão pequeno numa tela grande
	continua sendo um botão pequeno.
]=]
function HighlightController:measure(rule : { Fraction : number, Min : number, Max : number }, size : Vector2) : number
	local reference = math.min(size.X, size.Y)

	return math.clamp(reference * rule.Fraction, rule.Min, rule.Max)
end

--[=[
	Põe os quatro bloqueadores em volta do buraco.

	Eles cobrem a tela inteira menos o miolo: faixa de cima, faixa de baixo, e as
	duas laterais na altura do buraco. Sobra sempre alguma sobreposição nas quinas,
	e tudo bem — dois frames invisíveis empilhados engolem o mesmo clique uma vez.

	As faixas são propositalmente maiores que a tela (o `Size` em escala mais um
	exagero em offset): uma tela que cresce entre um quadro e outro não pode deixar
	uma fresta clicável na borda.
]=]
function HighlightController:layoutBlockers(position : Vector2, size : Vector2)
	local blockers = self.Blockers
	if #blockers < 4 then return end

	local visible = if self.Options and self.Options.BlockInput ~= nil
		then self.Options.BlockInput == true
		else Config.BlockInput

	if not visible then
		for _, blocker in blockers do
			blocker.Visible = false
		end

		return
	end

	local far = 10000

	-- Cima
	blockers[1].Position = UDim2.fromOffset(-far, position.Y - far)
	blockers[1].Size = UDim2.fromOffset(far * 2, far)

	-- Baixo
	blockers[2].Position = UDim2.fromOffset(-far, position.Y + size.Y)
	blockers[2].Size = UDim2.fromOffset(far * 2, far)

	-- Esquerda
	blockers[3].Position = UDim2.fromOffset(position.X - far, position.Y)
	blockers[3].Size = UDim2.fromOffset(far, size.Y)

	-- Direita
	blockers[4].Position = UDim2.fromOffset(position.X + size.X, position.Y)
	blockers[4].Size = UDim2.fromOffset(far, size.Y)

	for _, blocker in blockers do
		blocker.Visible = true
	end
end

--[=[
	Tira (ou devolve) o destaque sem esquecer o alvo.

	É o estado de "o alvo existe, mas agora não está à vista": rolou para fora da
	lista, ficou invisível, o painel dele fechou. Apagar de vez seria perder o
	apontamento — o tutorial continua apontando o mesmo botão, e ele volta a brilhar
	quando o jogador rolar de volta.

	O escurecimento sai rápido, e não no tempo da saída normal: aqui não é o fim de
	um passo, é a tela mudando debaixo dele.
]=]
function HighlightController:suspend(suspended : boolean)
	if self.Suspended == suspended then
		return
	end

	self.Suspended = suspended

	if suspended then
		for _, blocker in self.Blockers do
			blocker.Visible = false
		end

		self:fade(1, Config.Tween.FadeOut)

		return
	end

	local transparency = (self.Options and self.Options.Transparency) or Config.Hole.Transparency
	self:fade(transparency, Config.Tween.FadeIn)
end

--[=[
	Cola o buraco no alvo.

	`animate` é para a troca de alvo: aí o buraco escorrega de um para o outro em
	vez de saltar. Qualquer mexida do alvo no meio do caminho cancela o tween e
	passa a valer a posição de verdade — perseguir o alvo ganha de terminar a
	animação bonita.
]=]
function HighlightController:refresh(animate : boolean?)
	local hole = self.Hole
	if not hole then return end

	local position, size = self:rect()
	if not position or not size then
		self:suspend(true)

		return
	end

	self:suspend(false)

	-- O raio acompanha o tamanho do buraco pelo mesmo motivo da folga: 12px de canto
	-- arredondado num ícone de 40px é quase um círculo, e num painel inteiro não se
	-- vê.
	local corner = self.Corner
	if corner then
		corner.CornerRadius = UDim.new(0, self:measure(Config.Hole.Radius, size))
	end

	if self.MoveTween then
		self.MoveTween:Cancel()
		self.MoveTween = nil
	end

	local goalPosition = UDim2.fromOffset(position.X, position.Y)
	local goalSize = UDim2.fromOffset(size.X, size.Y)

	if animate then
		local info = TweenInfo.new(Config.Tween.Move, Config.Tween.EasingStyle, Config.Tween.EasingDirection)

		self.MoveTween = TweenService:Create(hole, info, {
			Position = goalPosition,
			Size = goalSize,
		})
		self.MoveTween:Play()
	else
		hole.Position = goalPosition
		hole.Size = goalSize
	end

	self:layoutBlockers(position, size)
end

--[=[
	Liga o destaque ao alvo: ele segue o que o alvo fizer e some com ele.

	São avisos, e não uma varredura por quadro. Botão de HUD não anda; ficar
	recalculando sessenta vezes por segundo um retângulo que não muda é o custo que
	o `RenderStepped` do exemplo mais comum cobra sem precisar.
]=]
function HighlightController:track(target : GuiObject)
	local maid = Maid.new()
	self.TargetMaid = maid

	local function onMoved()
		self:refresh(false)
	end

	maid:GiveTask(target:GetPropertyChangedSignal("AbsolutePosition"):Connect(onMoved))
	maid:GiveTask(target:GetPropertyChangedSignal("AbsoluteSize"):Connect(onMoved))

	-- Tela que muda de tamanho (janela, rotação do celular) move tudo junto, e a
	-- sonda da origem muda com ela.
	local camera = workspace.CurrentCamera
	if camera then
		maid:GiveTask(camera:GetPropertyChangedSignal("ViewportSize"):Connect(onMoved))
	end

	-- Alvo que fica invisível tira o destaque da tela, mas não o esquece: painel que
	-- fecha e reabre é o caso normal de um tutorial, e o passo continua sendo o
	-- mesmo.
	maid:GiveTask(target:GetPropertyChangedSignal("Visible"):Connect(function()
		self:refresh(false)
	end))

	-- Alvo tirado da tela de vez é outra história: não há mais o que apontar.
	maid:GiveTask(target.AncestryChanged:Connect(function()
		if not target:IsDescendantOf(PlayerGui) then
			self:Hide()
		end
	end))
end

--[=[
	Leva o escurecimento a uma transparência.
]=]
function HighlightController:fade(transparency : number, duration : number)
	local stroke = self.Stroke
	if not stroke then return end

	if self.FadeTween then
		self.FadeTween:Cancel()
		self.FadeTween = nil
	end

	local info = TweenInfo.new(duration, Config.Tween.EasingStyle, Config.Tween.EasingDirection)

	self.FadeTween = TweenService:Create(stroke, info, { Transparency = transparency })
	self.FadeTween:Play()
end

--[[ API ]]

export type Options = {
	-- Folga em pixels de cada lado do alvo.
	Padding : number?,

	-- Quanto do jogo continua aparecendo no escuro (0 preto, 1 invisível).
	Transparency : number?,

	-- `false` deixa o jogador clicar no que está escurecido.
	BlockInput : boolean?,
}

--[=[
	Aponta um GuiObject: a tela escurece, menos ele.

	Chamar com o destaque já no ar troca o alvo escorregando de um para o outro —
	nenhum piscar no meio de um tutorial.

	Devolve `false` para alvo que não está na tela (destruído, invisível, fora da
	`PlayerGui`): não há o que apontar, e ligar o escuro por cima de nada só tiraria
	o jogo do jogador.
]=]
function HighlightController:Show(target : GuiObject, options : Options?) : boolean
	if not target or not target:IsDescendantOf(PlayerGui) or not target.Visible then
		return false
	end

	self:build()

	local wasShown = self:IsShown()

	if self.TargetMaid then
		self.TargetMaid:DoCleaning()
		self.TargetMaid = nil
	end

	self.Target = target
	self.Options = options
	self.Suspended = false

	local gui = self.Gui
	if gui then
		gui.Enabled = true
	end

	self:refresh(wasShown)
	self:track(target)

	if not wasShown then
		local stroke = self.Stroke
		if stroke then
			stroke.Transparency = 1
		end
	end

	local transparency = (options and options.Transparency) or Config.Hole.Transparency
	self:fade(transparency, if wasShown then Config.Tween.Move else Config.Tween.FadeIn)

	return true
end

--[=[
	Apaga o destaque. Idempotente: apagar o que já está apagado não faz nada.
]=]
function HighlightController:Hide()
	if not self:IsShown() then
		return
	end

	if self.TargetMaid then
		self.TargetMaid:DoCleaning()
		self.TargetMaid = nil
	end

	self.Target = nil
	self.Options = nil
	self.Suspended = false

	for _, blocker in self.Blockers do
		blocker.Visible = false
	end

	self:fade(1, Config.Tween.FadeOut)

	-- A tela só é desligada no fim da saída: desligar junto com o tween cortaria o
	-- escuro pela metade.
	local gui = self.Gui
	task.delay(Config.Tween.FadeOut, function()
		if self.Target then return end
		if gui then
			gui.Enabled = false
		end
	end)
end

function HighlightController:IsShown() : boolean
	return self.Target ~= nil
end

function HighlightController:GetTarget() : GuiObject?
	return self.Target
end

--[=[
	O alvo por caminho de nomes a partir da `PlayerGui` — `"HUD.HUDLeft.Shop"`.

	É o que permite apontar um botão de fora do código que o conhece: o comando
	`highlight` do Cmdr e o passo de tutorial que vier escrito em config, sem
	nenhum dos dois precisar de uma referência à instância.
]=]
function HighlightController:Find(path : string) : GuiObject?
	local current : Instance = PlayerGui

	for name in string.gmatch(path, "[^%.]+") do
		local found = current:FindFirstChild(name)
		if not found then
			return nil
		end

		current = found
	end

	return if current:IsA("GuiObject") then current else nil
end

--[[ CICLO DE VIDA ]]

function HighlightController:construct()
	Framework:Listen("HighlightShow", function(path : any, options : any)
		if type(path) ~= "string" then
			self:Hide()

			return
		end

		local target = self:Find(path)
		if not target then
			warn(`[HighlightController]: nao achei "{path}" na PlayerGui.`)

			return
		end

		self:Show(target, if type(options) == "table" then options else nil)
	end)
end

function HighlightController:start()
end

function HighlightController:init()
	self:construct()
end

return HighlightController
