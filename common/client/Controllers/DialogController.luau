local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local LightingUtil = require(Util.LightingUtil)
local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.DialogConfig

-- Quadros de paciência com o layout da caixa antes da primeira linha. Ver
-- `waitForLayout`.
local LAYOUT_FRAMES = 4

-- O que o `:Play()` entende e o `RichTextController` não: são da conversa, não do
-- texto, e por isso não descem para o render.
local DIALOG_ONLY_OPTIONS = {
	Auto = true,
	Buttons = true,
	ButtonsAtEnd = true,
	HideUI = true,
	Blur = true,
	Duck = true,
}

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

	**Os dois botões da caixa** (`Button1` à direita, `Button2` à esquerda) recebem
	texto, aparecem, somem e chamam o que quem pediu a fala mandar:

		Dialog:Play("Aceita o contrato?", {
			Buttons = {
				{ Text = "ACEITAR", OnClick = function() Contracts:Accept() end },
				{ Text = "AGORA NAO", OnClick = function() Dialog:Close() end },
			},
		})

	Fora do `:Play()` eles se mexem por `:SetButton(indice, spec)`, `:SetButtons`,
	`:ClearButtons` e `:GetButton` — este último devolve o ImageButton para quem
	quiser trocar imagem, animar ou pôr um ícone dentro. Botão **sem** `OnClick`
	avança a fala, que é o gesto mais provável de quem apertou um botão numa
	conversa. Fala que não pede botão nenhum começa sem botão: escolha de conversa
	velha na tela da nova é defeito que só aparece na mão do jogador.

	**Atrás da fala**, a tela sai do caminho: o resto da UI some (pelo
	`InterfaceController`, o mesmo "some com o resto" da cutscene e dos painéis), o
	fundo borra (o `UIBlur` compartilhado, com tween de entrada e de saída) e a
	música abaixa (`MusicController:Duck`, que não mexe no volume que o jogador
	escolheu). Os três são ligados por `DialogConfig.Background` e desligáveis por
	fala — `Dialog:Play(texto, { Blur = false })`.

	**A tela mora no place, não no git** — `StarterGui` não é sincronizado pelo
	Rojo. Por isso o caminho é por nome (`DialogConfig.Gui`) e resolvido tarde: a
	`SharedUIs` pode não ter replicado quando o controller carrega, e um
	`WaitForChild` no `init` seguraria o boot do cliente por causa de uma caixa que
	talvez nem seja usada nesta sessão.

	Fica em `common/` porque as duas places têm a `SharedUIs`.
]]

local DialogController = {
	Controllers = {
		RichTextController = {},

		-- O fundo da fala: quem esconde o resto da UI e quem abaixa a musica. Os
		-- dois ja existiam para a cutscene e para os paineis; aqui so sao pedidos.
		InterfaceController = {},
		MusicController = {},
	}
}

DialogController.Container = nil :: GuiObject?
DialogController.Screen = nil :: ScreenGui?

--[[
	A caixa já apareceu alguma vez nesta sessão?

	É o que separa "esta place não tem caixa de fala" de "a caixa morreu e está
	voltando". Sem a diferença, o `getContainer` teria de escolher entre nunca esperar
	(e perder toda fala pedida logo depois de um respawn) e sempre esperar (e travar
	por dez segundos cada `Play` de uma place que não tem a `SharedUIs`).
]]
DialogController.Existed = false
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

--[[
	As opções da fala no ar, guardadas para ela poder voltar igual depois de um
	respawn (ver `Respawn` em `DialogConfig` e o `Destroying` do `:Play`).
]]
DialogController.Options = nil :: any

--[[
	A fala esperando a caixa nova, quando o jogador morreu no meio dela. `nil`
	quando não há nada voltando.

	`IsOpen()` responde `false` nesse intervalo — a caixa de fato não está na tela —,
	então quem precisa saber que ainda vem fala pergunta por `IsResuming()`.
]]
DialogController.Resume = nil :: any

-- Sobe a cada volta marcada e a cada `:Play()`. É o que faz uma fala nova cancelar
-- a volta da anterior em vez de as duas disputarem a caixa.
DialogController.ResumeToken = 0

-- Quem quer saber quando a caixa fechou. Ver `:OnClosed`.
DialogController.ClosedListeners = {}
DialogController.Warned = false

-- [índice] = { Instance, Label, OnClick }. Preenchido na primeira vez que o botão
-- é usado e esvaziado junto com o container (ver `getContainer`).
DialogController.ButtonSlots = {}

-- Os botões que esperam a última frase acabar (`ButtonsAtEnd`). Nil quando não há
-- escolha pendente.
DialogController.PendingButtons = nil :: { any }?

-- O que a fala tomou da tela agora: o resto da UI escondido, o borrão no ar, a
-- música abafada. Guardado para o fechamento devolver exatamente o que a abertura
-- tomou — nem mais (borrão de um painel que não é nosso) nem menos.
DialogController.Background = { UI = false, Blur = false, Duck = false }
DialogController.BlurTween = nil :: Tween?

--[[ INTERNAL ]]

--[=[
	A caixa, na primeira vez em que ela for precisa.

	Guardada depois de achada, e reachada quando o `Parent` some — a `PlayerGui` é
	remontada a cada respawn e a referência velha vira lixo.

	**Se ela já existiu e sumiu, esperamos por ela.** A `DialogGUI` tem
	`ResetOnSpawn`: renascer destrói a tela e a nova só chega alguns quadros depois,
	quando o clone da `StarterGui` acontece. Uma fala pedida nesse intervalo — que é
	exatamente o caso do fluxo do tutorial recomeçando no `CharacterAdded` — não
	achava caixa nenhuma, o `:Play()` devolvia `false` e quem esperava o `OnClosed`
	ficava esperando para sempre: nenhuma fala na tela e o roteiro parado.

	A espera é **só** para quem já viu a caixa uma vez (ver `Existed`). Place que não
	tem a `SharedUIs` continua respondendo `nil` na hora, como sempre respondeu — lá
	não há o que esperar.
]=]
function DialogController:getContainer() : GuiObject?
	local container = self.Container
	if container and container.Parent then
		return container
	end

	local gui = Config.Gui
	local respawn = Config.Respawn or {}

	local function look() : GuiObject?
		local folder = PlayerGui:FindFirstChild(gui.Folder)
		local screen = folder and folder:FindFirstChild(gui.Screen)
		local found = screen and screen:FindFirstChild(gui.Container)

		return if found and found:IsA("GuiObject") then found :: GuiObject else nil
	end

	local found = look()

	if not found and self.Existed then
		local deadline = os.clock() + (respawn.Timeout or 10)

		repeat
			task.wait(respawn.Interval or 0.2)

			found = look()
		until found or os.clock() > deadline

		if not found then
			warn("[DialogController]: a caixa de fala nao voltou depois do respawn.")
		end
	end

	if not found then
		self:warnMissing()

		return nil
	end

	local screen = found.Parent

	self.Existed = true
	self.Container = found
	self.Screen = if screen and screen:IsA("ScreenGui") then screen else nil

	-- O handle é do container: container novo (respawn, tela recriada) pede handle
	-- novo, senão escreveríamos num frame que não está mais na tela. Os botões são
	-- filhos dele e morrem junto — o cache deles vai embora pelo mesmo motivo.
	self.Handle = nil
	table.clear(self.ButtonSlots)

	return found
end

--[=[
	O botão do índice, pronto para uso: achado dentro do container, com o label de
	texto criado e o clique já ligado.

	O label é criado aqui, e não autorado no Studio, porque o botão é um ImageButton
	— ele não tem texto próprio. Nascendo daqui, botão novo que o designer coloque
	na caixa ganha texto centrado sem ninguém precisar lembrar de nada.

	`nil` quando não existe botão nesse índice: a caixa é do place, e uma place que
	tenha só um botão (ou nenhum) não é erro, é outra tela.
]=]
function DialogController:getButton(index : number) : any
	local slot = self.ButtonSlots[index]
	if slot and slot.Instance.Parent then
		return slot
	end

	local container = self:getContainer()
	local name = Config.Buttons.Names[index]
	if not container or not name then
		return nil
	end

	local instance = container:FindFirstChild(name)
	if not instance or not instance:IsA("GuiButton") then
		return nil
	end

	local labelConfig = Config.Buttons.Label

	local label = instance:FindFirstChild(labelConfig.Name)
	if not label or not label:IsA("TextLabel") then
		label = Instance.new("TextLabel")
		label.Name = labelConfig.Name
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = ""
		label.TextColor3 = labelConfig.Color
		label.Font = labelConfig.Font
		label.TextScaled = true
		label.TextWrapped = true

		-- O clique é do botão, não do label: sem isso o label comeria o toque no
		-- meio do botão, que é justamente onde o dedo cai.
		label.Active = false

		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, labelConfig.Padding)
		padding.PaddingBottom = UDim.new(0, labelConfig.Padding)
		padding.PaddingLeft = UDim.new(0, labelConfig.Padding)
		padding.PaddingRight = UDim.new(0, labelConfig.Padding)
		padding.Parent = label

		-- `TextScaled` sozinho transformaria "OK" numa letra de cartaz.
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = labelConfig.MaxTextSize
		constraint.Parent = label

		label.Parent = instance
	end

	slot = {
		Instance = instance,
		Label = label,
		OnClick = nil,
	}

	self.ButtonSlots[index] = slot

	-- Uma conexão por botão, para sempre: ela chama o callback que **estiver** no
	-- slot na hora do clique. Reconectar a cada `:SetButton()` seria a receita para
	-- um clique disparar três vezes.
	instance.Activated:Connect(function()
		local current = self.ButtonSlots[index]
		if not current then return end

		if current.OnClick then
			task.spawn(current.OnClick, index)

			return
		end

		-- Botão sem callback é um "continuar": o gesto mais provável de quem
		-- apertou um botão numa fala é querer a próxima linha.
		self:Advance(true)
	end)

	return slot
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
	Põe o fundo no estado pedido: o resto da UI, o borrão e a música.

	Trabalha por diferença em vez de "aplica tudo": fala nova começando por cima de
	outra não pode devolver o borrão para zero e subi-lo de novo — seria um piscar
	no meio de uma conversa que, para o jogador, nem parou.

	Cada peça é opcional porque cada uma pode não existir na place: sem
	`InterfaceController` a fala aparece com a UI toda atrás, o que é feio, não
	quebrado.
]=]
function DialogController:applyBackground(wanted : { UI : boolean, Blur : boolean, Duck : boolean })
	local active = self.Background
	local background = Config.Background

	if wanted.UI ~= active.UI then
		local interface = self.Controllers.InterfaceController

		if interface then
			if wanted.UI then
				-- O `Except` é por garantia: a `DialogGUI` mora dentro da pasta
				-- `SharedUIs`, e o `InterfaceController` só acompanha filho direto da
				-- PlayerGui — hoje ela nem entra na conta. Alguém movendo a tela para
				-- fora da pasta amanhã não deve descobrir isso pela fala sumindo.
				interface:Hide(background.HideReason, { Except = { Config.Gui.Screen } })
			else
				interface:Show(background.HideReason)
			end
		end
	end

	if wanted.Blur ~= active.Blur then
		local blur = background.Blur

		-- Um tween por vez: `Cancel` não devolve a propriedade, então fechar no meio
		-- da abertura desce a partir de onde a subida chegou.
		if self.BlurTween then
			self.BlurTween:Cancel()
			self.BlurTween = nil
		end

		local info = TweenInfo.new(
			if wanted.Blur then blur.TweenIn else blur.TweenOut,
			blur.EasingStyle,
			blur.EasingDirection
		)

		self.BlurTween = LightingUtil.TweenUIBlur(if wanted.Blur then blur.Size else 0, info)
	end

	if wanted.Duck ~= active.Duck then
		local music = self.Controllers.MusicController

		if music then
			if wanted.Duck then
				music:Duck(background.Duck.Scale, background.Duck.FadeIn)
			else
				music:Unduck(background.Duck.FadeOut)
			end
		end
	end

	self.Background = wanted
end

--[=[
	Devolve tudo o que a fala tomou. É o que o fechamento chama, e é seguro chamar
	duas vezes: o `applyBackground` só mexe no que está diferente.
]=]
function DialogController:releaseBackground()
	self:applyBackground({ UI = false, Blur = false, Duck = false })
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

	local isLast = self.Index >= #self.Lines

	handle:Write(line)

	if not self.Auto and not (isLast and self.PendingButtons) then return end

	-- Uma inscrição por linha, desfeita no primeiro disparo: a linha seguinte
	-- inscreve a dela, e sem isso a terceira frase chamaria três callbacks.
	local disconnect
	disconnect = handle:OnFinished(function()
		if disconnect then
			disconnect()
		end

		if self.Session ~= session then return end

		-- A escolha só aparece quando a última frase terminou de ser escrita —
		-- botão no ar enquanto o texto ainda está chegando convida o jogador a
		-- responder uma pergunta que ele ainda não leu. Pular a digitação também
		-- chega aqui, que é o que faz quem tem pressa não ficar sem os botões.
		if isLast and self.PendingButtons then
			self:SetButtons(self.PendingButtons)
			self.PendingButtons = nil
		end

		if not self.Auto then return end

		task.delay(Config.AutoHold, function()
			if self.Session ~= session then return end
			if not self.Open then return end

			self:Advance(true)
		end)
	end)
end

--[=[
	Tem escolha no ar? É botão visível **com** callback próprio.

	Botão sem callback é um "continuar" e não segura nada; botão com callback é uma
	pergunta, e enquanto ela está na tela o clique no vazio não pode fechar a caixa
	— senão a resposta se perde no primeiro clique distraído.
]=]
function DialogController:hasChoice() : boolean
	for index in Config.Buttons.Names do
		local slot = self.ButtonSlots[index]

		if slot and slot.OnClick and slot.Instance.Visible then
			return true
		end
	end

	return false
end

--[[ API ]]

export type ButtonSpec = {
	Text : string?,
	Visible : boolean?,
	OnClick : ((index : number) -> ())?,

	-- Caminho de família de fonte (`rbxasset://fonts/families/....json`) para este
	-- botão. Sem isso vale o `DialogConfig.Buttons.Label.Font`.
	Font : string?,
}

export type PlayOptions = {
	Auto : boolean?,
	Preset : string?,
	Speed : number?,
	Font : string?,
	Buttons : { ButtonSpec }?,

	-- `true` segura os botões até a última frase terminar de ser escrita. É o que
	-- uma pergunta quer: a escolha aparece depois de o jogador ler o que foi
	-- perguntado.
	ButtonsAtEnd : boolean?,

	-- O fundo: esconder o resto da UI, borrar a tela, abafar a música. Sem valor,
	-- vale o `DialogConfig.Background`.
	HideUI : boolean?,
	Blur : boolean?,
	Duck : boolean?,
}

--[=[
	Mexe num dos botões da caixa. Só o que vier no `spec` muda:

		Dialog:SetButton(1, {
			Text = "ACEITAR",
			OnClick = function()
				Contracts:Accept()
				Dialog:Close()
			end,
		})

		Dialog:SetButton(2, { Text = "AGORA NAO", Visible = true })

	`Text` vai centrado num label dentro do botão. `Visible` liga e desliga o botão.
	`OnClick` é o callback, e é livre: recebe o índice e não precisa devolver nada.
	Botão **sem** callback funciona como "continuar" — o clique avança a fala.

	Passar `Text` acende o botão sozinho, porque escrever num botão invisível é
	sempre engano. Para escrever e deixar apagado, mande `Visible = false` junto.

	Devolve `false` se não existe botão nesse índice nesta place.
]=]
function DialogController:SetButton(index : number, spec : ButtonSpec) : boolean
	local slot = self:getButton(index)
	if not slot then
		return false
	end

	if spec.Font ~= nil then
		local success, font = pcall(Font.new, spec.Font)
		if success then
			slot.Label.FontFace = font
		else
			warn(`[DialogController]: fonte invalida no botao {index}: {spec.Font}`)
		end
	end

	if spec.Text ~= nil then
		slot.Label.Text = spec.Text
		slot.Instance.Visible = true
	end

	if spec.Visible ~= nil then
		slot.Instance.Visible = spec.Visible
	end

	if spec.OnClick ~= nil then
		slot.OnClick = spec.OnClick
	end

	return true
end

--[=[
	Os dois de uma vez, na ordem de `DialogConfig.Buttons.Names`. Índice sem spec
	na lista é apagado — é o que faz `{ {...} }` deixar só o primeiro na tela.
]=]
function DialogController:SetButtons(specs : { ButtonSpec })
	for index in Config.Buttons.Names do
		local spec = specs[index]

		if spec then
			self:SetButton(index, spec)
		else
			self:SetButton(index, { Visible = false, Text = "" })
		end
	end
end

--[=[
	Apaga os dois e esquece os callbacks.

	É o que roda quando uma fala começa sem pedir botão e quando a caixa fecha: as
	escolhas de uma conversa não podem sobreviver a ela. Callback de uma fala
	antiga num botão da fala nova é o tipo de defeito que só aparece na mão do
	jogador.
]=]
function DialogController:ClearButtons()
	for index in Config.Buttons.Names do
		local slot = self:getButton(index)
		if not slot then continue end

		slot.OnClick = nil
		slot.Label.Text = ""
		slot.Instance.Visible = false
	end
end

--[=[
	O botão em si, para quem quiser fazer o que esta API não faz — trocar a imagem,
	animar, pôr um ícone dentro. É a saída para "customizado de qualquer jeito".
]=]
function DialogController:GetButton(index : number) : GuiButton?
	local slot = self:getButton(index)

	return slot and slot.Instance
end

--[=[
	A caixa morreu com a fala aberta: guarda o que falta dizer e larga o que está
	fora dela.

	O que sobra é de `Index` em diante, e não a fala inteira: o jogador já leu o que
	leu, e recomeçar do zero é fazê-lo ler duas vezes a mesma coisa para ser punido
	por ter morrido. As opções são as mesmas — o mesmo fundo, os mesmos botões, o
	mesmo modo automático —, porque a fala é a mesma; só a caixa é outra.

	O fundo é devolvido **agora**, e não na volta: o borrão e a UI escondida são da
	tela que acabou de morrer, e deixá-los de pé enquanto a caixa nova não chega é
	exatamente a tela travada que este bloco existe para evitar. A volta os pede de
	novo, porque ela passa pelo `:Play()` inteiro.
]=]
function DialogController:noteDestroyed()
	local remaining = {}
	for index = math.max(1, self.Index), #self.Lines do
		table.insert(remaining, self.Lines[index])
	end

	self.Session += 1
	self.Open = false
	self.Lines = {}
	self.Index = 0
	self.PendingButtons = nil

	self:releaseBackground()

	if #remaining == 0 then
		-- Nada por dizer: a fala tinha acabado, e isto é um fechamento como outro
		-- qualquer.
		self:fireClosed()

		return
	end

	self.ResumeToken += 1
	local token = self.ResumeToken

	self.Resume = { Lines = remaining, Options = self.Options }

	task.spawn(function()
		self:awaitResume(token)
	end)
end

--[=[
	Espera a caixa nova aparecer e reescreve nela o que faltava.

	A caixa não volta no mesmo quadro em que a antiga morre: o `ResetOnSpawn` só
	reclona a `StarterGui` quando o personagem novo entra, e entre uma coisa e outra
	há o tempo de respawn do servidor. Por isso é espera, e não uma tentativa só.

	Desistindo (ver `Respawn.Timeout`), quem esperava o `:OnClosed()` **é avisado**.
	É essa linha que impede um passo de tutorial de ficar parado para sempre
	esperando uma fala que não volta mais — melhor o passo seguir sem a instrução que
	o jogador preso numa tela que não responde.
]=]
function DialogController:awaitResume(token : number)
	local respawn = Config.Respawn or {}
	local deadline = os.clock() + (respawn.Timeout or 10)

	while os.clock() < deadline do
		if self.ResumeToken ~= token then return end

		local container = self:getContainer()

		if container and container.Parent then
			local resume = self.Resume

			self.Resume = nil

			if resume then
				self:Play(resume.Lines, resume.Options)
			end

			return
		end

		task.wait(respawn.Interval or 0.2)
	end

	if self.ResumeToken ~= token then return end

	warn("[DialogController]: a caixa de fala nao voltou depois do respawn; a fala foi perdida.")

	self.Resume = nil
	self:fireClosed()
end

--[=[
	Avisa quem pediu `:OnClosed()`. Em `task.spawn` porque o callback é de fora: um
	erro nele não pode derrubar quem está fechando a caixa.
]=]
function DialogController:fireClosed()
	for _, listener in self.ClosedListeners do
		task.spawn(listener)
	end
end

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
			-- Opção da conversa não é opção do texto: mandá-la para o
			-- `RichTextController` só viraria opção desconhecida lá dentro.
			if DIALOG_ONLY_OPTIONS[key] then continue end

			resolved[key] = value
		end
	end

	local handle = self:getHandle(resolved)
	if not handle then
		return false
	end

	self.Session += 1
	local session = self.Session

	-- Volta marcada de uma fala anterior não pode escrever por cima desta.
	self.ResumeToken += 1
	self.Resume = nil

	-- Guardadas para a fala poder voltar igual depois de um respawn (ver o
	-- `Destroying` mais abaixo).
	self.Options = options

	self.Lines = list
	self.Index = 1
	self.Auto = options and options.Auto or false
	self.Open = true
	self.LastAdvance = os.clock()

	-- Fala que não pediu botão nenhum entra sem botão: as escolhas da conversa
	-- anterior não podem continuar na tela por cima desta. Pedidos com
	-- `ButtonsAtEnd` ficam guardados até a última frase acabar (ver `write`).
	self:ClearButtons()
	self.PendingButtons = nil

	if options and options.Buttons then
		if options.ButtonsAtEnd then
			self.PendingButtons = options.Buttons
		else
			self:SetButtons(options.Buttons)
		end
	end

	--[=[
		A `DialogGUI` tem `ResetOnSpawn`: morrer com a fala aberta **destrói a caixa**.

		Sem isto o fechamento nunca chegaria — o borrão ficaria na tela e o resto da UI,
		escondido, até o jogador sair do servidor. E pior que o borrão: quem espera o
		`:OnClosed()` (o passo do tutorial, o fluxo do lobby) ficaria esperando para
		sempre por um aviso que não vem.

		Não é um `:Close()` de propósito: a caixa e os botões já não existem, e
		limpá-los seria escrever em instância destruída. Aqui só se desfaz o que está
		**fora** da tela que morreu, e se marca a volta da fala (ver `awaitResume`).
	]=]
	local container = self.Container
	if container then
		container.Destroying:Once(function()
			if not self.Open or self.Session ~= session then return end

			self:noteDestroyed()
		end)
	end

	local background = Config.Background
	local function wanted(option : any, default : boolean) : boolean
		if option == nil then
			return default
		end

		return option == true
	end

	self:applyBackground({
		UI = wanted(options and options.HideUI, background.HideOtherUIs),
		Blur = wanted(options and options.Blur, background.Blur.Enabled),
		Duck = wanted(options and options.Duck, background.Duck.Enabled),
	})

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
		-- Última frase com escolha na tela: a caixa fica. Quem fecha é o botão, e é
		-- por isso que a pergunta não morre num clique distraído no cenário.
		if self:hasChoice() then
			return false
		end

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

	self.PendingButtons = nil
	self:ClearButtons()
	self:releaseBackground()
	self:setVisible(false)

	-- Fechamento por gesto cancela a volta de uma fala que estivesse esperando caixa.
	self.ResumeToken += 1
	self.Resume = nil

	self:fireClosed()
end

--[=[
	Ainda vem fala?

	`true` no intervalo entre a caixa morrer com o jogador e a caixa nova chegar. É o
	que separa "a fala acabou" de "a fala está voltando" para quem decide o que pôr na
	tela agora — o passo do tutorial não pode acender o destaque por cima de uma
	instrução que está a um segundo de reaparecer.
]=]
function DialogController:IsResuming() : boolean
	return self.Resume ~= nil
end

function DialogController:IsOpen() : boolean
	return self.Open
end

--[=[
	Chama de volta quando a caixa fecha — por gesto do jogador, por botão ou pelo
	fim de uma fala automática. Devolve a função que desinscreve.

	É o que permite encadear: quem quiser mostrar alguma coisa **depois** da fala
	espera aqui em vez de chutar um `task.wait`.
]=]
function DialogController:OnClosed(callback : () -> ()) : () -> ()
	table.insert(self.ClosedListeners, callback)

	return function()
		local index = table.find(self.ClosedListeners, callback)
		if index then
			table.remove(self.ClosedListeners, index)
		end
	end
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
	-- autora a `DialogGUI` visível para poder vê-la no Studio. Os botões entram na
	-- mesma conta — eles nascem visíveis lá, com o texto de teste que estiver neles.
	if self:getContainer() then
		self:ClearButtons()
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
