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

	**O clique é outro assunto, e por padrão o destaque não se mete nele.** Stroke não
	recebe input (é contorno, não superfície), e o bloqueio — quatro frames `Active`
	em volta do buraco, a técnica das quatro máscaras — só entra quando quem chama
	pede: `Show(alvo, { BlockInput = true })`.

	O padrão é não bloquear porque destaque não é modal: apontar uma carta não pode
	impedir o jogador de girar a câmera nem de clicar no chão. Bloquear só faz
	sentido quando o alvo é a única coisa clicável do passo — um botão de UI, nunca
	um lugar do mapa.

	**Ele não some com o "esconda o resto".** A tela nasce com a marca
	`IgnoreInterfaceHide`, que o `InterfaceController` respeita: painel de
	proximidade e loja escondem o HUD ao abrir, e um destaque que sumisse junto
	apontaria só o que já estava na tela — nunca o que está dentro do painel que
	acabou de abrir.

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

--[[
	O caminho de nomes do alvo até a `PlayerGui`, para reencontrá-lo se a tela dele
	for reclonada (respawn). Ver `pathOf` e `rebind`.
]]
HighlightController.Path = nil :: { string }?

-- Sobe a cada `Show` e a cada `Hide`. Uma procura em curso confere o número antes
-- de apontar: alvo novo no meio dela ganha, e o `Hide` a cancela de vez.
HighlightController.RebindToken = 0

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

	--[[
		O destaque não some com os pedidos de "esconda o resto".

		A loja e os painéis de proximidade fazem esse pedido ao abrir, e sem esta
		marca o efeito ficava invertido: com a loja fechada o destaque aparecia, e
		com ela aberta — a hora em que ele precisa apontar o botão de comprar —
		sumia junto com o HUD.
	]]
	if Config.Gui.IgnoreHideAttribute then
		gui:SetAttribute(Config.Gui.IgnoreHideAttribute, true)
	end

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
--[=[
	O caminho de nomes de um alvo até a `PlayerGui`, ou `nil` se ele não estiver lá.

	É a mesma linguagem do `:Find()` — e é de propósito: o que se guarda para
	reencontrar o alvo tem de ser exatamente o que a busca sabe seguir. Nome é também
	a única coisa que sobrevive a um `ResetOnSpawn`, que destrói a instância e clona
	outra igual da `StarterGui`.
]=]
function HighlightController:pathOf(target : Instance) : { string }?
	local names = {}
	local current : Instance? = target

	while current and current ~= PlayerGui do
		table.insert(names, 1, current.Name)
		current = current.Parent
	end

	if current ~= PlayerGui or #names == 0 then
		return nil
	end

	return names
end

--[=[
	O alvo morreu debaixo do destaque: procura o equivalente na tela nova.

	É o caso do respawn — quase toda `ScreenGui` tem `ResetOnSpawn`, e a tela inteira
	é reclonada. A instância antiga é lixo, mas o caminho de nomes continua valendo,
	e é por ele que o destaque reencontra o que estava apontando.

	Não achando dentro do prazo (`Rebind.Timeout`), sai de vez e **calado**: quem
	pediu o destaque é quem sabe se ainda há passo pedindo aquele botão, e um aviso
	aqui apareceria também no caso legítimo de a tela ter sido fechada de vez.
]=]
function HighlightController:rebind()
	local path = self.Path
	local options = self.Options

	if not path then
		self:Hide()

		return
	end

	self.RebindToken += 1
	local token = self.RebindToken

	-- O escuro sai enquanto não há o que apontar: holofote em cima de nada é pior
	-- que holofote nenhum. É `suspend`, e não `Hide`, porque o alvo não foi
	-- esquecido — ele está sendo reencontrado.
	self:suspend(true)

	local rebind = Config.Rebind or {}

	task.spawn(function()
		local deadline = os.clock() + (rebind.Timeout or 10)

		while os.clock() < deadline do
			if self.RebindToken ~= token then return end

			local found = self:Find(path)

			--[[
				O `Show` recusa alvo invisível, e o alvo da tela nova costuma nascer assim:
				o botão de Ready só aparece quando a contagem começa, a caixa da mochila só
				quando ela abre. Recusa não é desistência — a procura continua, e é por isso
				que ela olha o resultado do `Show` em vez de dar o alvo por apontado.

				O `Show` que dá certo sobe o token, e é ele quem encerra esta thread.
			]]
			if found and found:IsDescendantOf(PlayerGui) then
				if self.RebindToken ~= token then return end

				if self:Show(found, options) then
					return
				end
			end

			task.wait(rebind.Interval or 0.2)
		end

		if self.RebindToken ~= token then return end

		self:Hide()
	end)
end

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

	--[[
		Alvo tirado da `PlayerGui` pode ser o fim dele — ou pode ser a tela inteira
		sendo reclonada por um respawn, que é o caso mais comum de todos, porque quase
		toda `ScreenGui` tem `ResetOnSpawn`.

		Os dois são o mesmo evento visto daqui, então o destaque não decide: ele
		procura o mesmo caminho na tela nova e desiste se não achar (ver `rebind`).
	]]
	maid:GiveTask(target.AncestryChanged:Connect(function()
		if not target:IsDescendantOf(PlayerGui) then
			self:rebind()
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

	--[[
		O caminho de nomes fica guardado junto com o alvo: é por ele que o destaque
		reencontra o botão quando a tela dele for reclonada por um respawn (ver
		`rebind`). Alvo sem caminho — o que não está sob a `PlayerGui` — simplesmente
		não volta, e isso é honesto: não há onde procurá-lo.
	]]
	self.Path = self:pathOf(target)

	-- Alvo novo cancela a procura do anterior.
	self.RebindToken += 1

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

	-- Esquecer o caminho é o que separa "sair" de "estar voltando": depois de um
	-- `Hide` não há o que reencontrar, e uma procura em curso morre aqui.
	self.Path = nil
	self.RebindToken += 1

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

	Aceita a lista de nomes já partida, para quem a tem na mão — é o caso do `rebind`,
	que guardou a cadeia do alvo e não pode juntá-la com pontos para partir de novo:
	nome com ponto dentro (`"1.5x"`, que é o tipo de nome que uma arte ganha) viraria
	dois degraus e o alvo não seria achado nunca mais.
]=]
function HighlightController:Find(path : string | { string }) : GuiObject?
	local names = {}

	if type(path) == "table" then
		names = path
	else
		for name in string.gmatch(path, "[^%.]+") do
			table.insert(names, name)
		end
	end

	--[[
		Busca em profundidade, e não um `FindFirstChild` por degrau.

		O HUD tem **vários** irmãos chamados `Wrapper`, um por botão: pegar o primeiro
		e seguir dali acharia o wrapper da mochila e desistiria no `Shop`. Tentando
		cada irmão de mesmo nome até o resto do caminho fechar, `HUDFrame.Wrapper.Shop`
		encontra o wrapper que de fato tem o Shop dentro.
	]]
	local function walk(parent : Instance, index : number) : Instance?
		local name = names[index]
		if not name then
			return parent
		end

		for _, child in parent:GetChildren() do
			if child.Name == name then
				local found = walk(child, index + 1)

				if found then
					return found
				end
			end
		end

		return nil
	end

	local found = walk(PlayerGui, 1)

	return if found and found:IsA("GuiObject") then found else nil
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
