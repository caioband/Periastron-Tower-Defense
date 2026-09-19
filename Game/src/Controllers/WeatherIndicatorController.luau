local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
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

local WeatherConfig = SharedConfig.WeatherConfig
local Config = WeatherConfig.Indicator

-- Quão perto do repouso a escala precisa estar para a lista poder ser escrita. Um
-- tween que termina não cai exatamente no alvo em toda máquina, e a diferença que
-- importa aqui é a de uma animação em curso, que é ordens de grandeza maior.
local SCALE_EPSILON = 0.001

--[[
	O tamanho em que a largura de uma frase é medida.

	A largura de um texto é linear no tamanho da letra, então medir uma vez num tamanho
	grande e escalar dá a largura em qualquer tamanho — com a vantagem de o erro de
	arredondamento de um tamanho pequeno não entrar na conta. Ele não aparece na tela.
]]
local PROBE_SIZE = 100

--[[
	As medidas da lista, no output do Studio.

	É o único jeito de saber **qual das duas contas** está mandando no tamanho da letra
	(ver `lineTextSize`), e sem isso ajustar o painel é tentativa e erro: mexer na
	proporção da altura não faz nada quando é a largura que limita, e mexer no fator da
	tela não faz nada quando ele está preso no piso.

	Mesmo motivo do `roundPrint` do `WeatherRoundService`: só no Studio, porque é
	informação de quem está desenhando a tela, e não do jogador.
]]
local IS_STUDIO = RunService:IsStudio()

local function indicatorPrint(...)
	if not IS_STUDIO then return end
	print("[WeatherIndicatorController]", ...)
end

--[[
	O indicador de clima do HUD: o botão no canto e o painel que ele abre.

	Duas peças irmãs na `Interface` (ver `WeatherConfig.Indicator.Gui`):

	  1. `WeatherButton` — o ícone do clima que está no ar, e o **interruptor** do
	     painel. Aperta e ele entra, aperta de novo e ele sai;
	  2. `IndicatorWeather` — o painel: o ícone outra vez, o nome do clima, quantas
	     waves ele ainda vale e a lista do que ele faz.

	**Sem clima no ar não há indicador.** O botão some e o painel fecha, mesmo estando
	aberto — "céu limpo" não é um estado que valha um canto da tela ocupado.

	**A animação é no `UIScale`** do painel, o autorado quando existe. Escala, e não
	posição, para a entrada funcionar em qualquer canto em que o designer ancore o
	painel.

	**As linhas são texto rico**, escritas uma depois da outra pelo
	`RichTextController`. A cor dentro delas é montada aqui (ver `markup`): o número
	entra na cor do que ele faz com o jogador e o tipo de unidade na cor do tipo.

	**De onde vem o que ele diz.** O clima de agora é do `WeatherController`
	(`WeatherChanged`); até que wave ele vale é do `WeatherDuration`, que o
	`WeatherRoundService` manda com o nome junto; a wave de agora é do `SetWave`.

	Os três chegam em eventos diferentes e **a ordem entre eles não é garantida**, por
	isso nada aqui é calculado na chegada de um deles: cada aviso só guarda o que
	trouxe e manda redesenhar, e a conta das waves restantes sai do estado inteiro. É
	também por isso que o `WeatherDuration` traz o nome do clima — prazo cujo nome não
	é o do clima no ar é prazo de outro clima, e não aparece.

	Fica na Game: clima de partida só existe aqui.
]]

local WeatherIndicatorController = {
	Controllers = {
		RichTextController = {},
		WeatherController = {},
	}
}

-- As peças da tela.
WeatherIndicatorController.Button = nil :: GuiButton?
WeatherIndicatorController.ButtonImage = nil :: ImageLabel?
WeatherIndicatorController.Panel = nil :: GuiObject?
WeatherIndicatorController.Scale = nil :: UIScale?
WeatherIndicatorController.Image = nil :: ImageLabel?
WeatherIndicatorController.NameLabel = nil :: TextLabel?
WeatherIndicatorController.DurationLabel = nil :: TextLabel?
WeatherIndicatorController.Container = nil :: GuiObject?

--[[
	A escala que o designer desenhou, quando ele escreveu uma. `Scale.Open` do config
	cobre o `UIScale` que nasce em zero (ou o que este controller cria).

	É lida no `bind`, antes de a animação escrever a primeira vez no `UIScale` — depois
	disso o valor de lá é o da animação, e não o do designer.

	A escala de repouso **não** é esta: é esta vezes o fator da tela. Ver `openScale`.
]]
WeatherIndicatorController.AuthoredScale = 1

-- O molde de uma linha, quando o designer desenhou um. Ver `lineFrame`.
WeatherIndicatorController.Template = nil :: GuiObject?

-- Uma entrada por linha da lista, reusada entre climas: `{ Frame, Handle }`.
WeatherIndicatorController.Lines = {}

-- O painel está aberto? É o estado do interruptor, e não o do tween.
WeatherIndicatorController.IsOpen = false

-- A wave de agora, e o prazo que o servidor mandou: o nome do clima e a última wave
-- em que ele vale.
WeatherIndicatorController.Wave = 0
WeatherIndicatorController.EndsName = nil :: string?
WeatherIndicatorController.EndsWave = nil :: number?

--[[
	Sobe a cada abertura e a cada fechamento.

	Duas coisas conferem se ainda são da vez delas antes de mexer na tela: a escrita
	das linhas, que dorme entre uma e outra, e o fim do tween de saída, que apaga o
	painel. Sem isto, um clima que trocasse no meio da escrita escreveria por cima da
	lista nova, e uma reabertura rápida seria apagada pelo fim da saída anterior.
]]
WeatherIndicatorController.Token = 0

-- O tween de escala em curso, para o clique seguinte emendar nele em vez de brigar.
WeatherIndicatorController.ScaleTween = nil :: Tween?

-- Sobe a cada mudança de tela, para só a última do lote reescrever a lista. Ver
-- `onViewportChanged`.
WeatherIndicatorController.ViewportToken = 0

--[[
	Largura de cada frase já medida, em `PROBE_SIZE`. As frases são as sete listas do
	config, então a tabela nasce pequena e para de crescer — e medir custa uma chamada
	que dorme, que não vale repetir a cada abertura do painel.
]]
WeatherIndicatorController.Widths = {}

--[[ TELA ]]

--[=[
	Acha as peças na `PlayerGui`.

	Devolve `false` quando o botão ou o painel não existem nesta place (ou ainda não
	replicaram) — o controller então não faz nada, em vez de estourar em cima de um
	`nil`. O que é opcional (os labels, o molde de linha) só avisa e segue.
]=]
function WeatherIndicatorController:bind() : boolean
	local screen = PlayerGui:WaitForChild(Config.Gui.Screen, 60)
	local button = screen and screen:WaitForChild(Config.Gui.Button, 60)
	local panel = screen and screen:WaitForChild(Config.Gui.Frame, 60)

	if not button or not button:IsA("GuiButton") then
		warn(`[WeatherIndicatorController]: nao achei o botao {Config.Gui.Screen}.{Config.Gui.Button} na PlayerGui.`)

		return false
	end

	if not panel or not panel:IsA("GuiObject") then
		warn(`[WeatherIndicatorController]: nao achei o painel {Config.Gui.Screen}.{Config.Gui.Frame} na PlayerGui.`)

		return false
	end

	self.Button = button
	self.Panel = panel

	--[[
		Onde o ícone do botão é escrito.

		Normalmente é o próprio botão, que é um `ImageButton`. Botão que não seja de
		imagem continua servindo: vale a filha com o mesmo nome da imagem do painel
		(`Gui.Image`), que é onde um botão desenhado como moldura guarda o ícone dele.
	]]
	if button:IsA("ImageButton") then
		self.ButtonImage = button :: any
	else
		local inner = button:FindFirstChild(Config.Gui.Image)

		if inner and (inner:IsA("ImageLabel") or inner:IsA("ImageButton")) then
			self.ButtonImage = inner :: any
		else
			warn(`[WeatherIndicatorController]: o {Config.Gui.Button} nao e um ImageButton nem tem uma {Config.Gui.Image} dentro; o icone dele nao vai mudar.`)
		end
	end

	--[[
		O `UIScale` é o autorado, quando existe: assim o designer decide a escala de
		repouso do painel e a animação só escreve nela. Sem um, criar é inofensivo — um
		`UIScale` de escala 1 não muda nada do que está desenhado.
	]]
	local scale = panel:FindFirstChildWhichIsA("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "PanelScale"
		scale.Parent = panel
	end

	self.Scale = scale

	local authored = scale.Scale
	self.AuthoredScale = if authored > Config.Scale.Closed then authored else Config.Scale.Open

	local image = panel:FindFirstChild(Config.Gui.Image)
	if image and (image:IsA("ImageLabel") or image:IsA("ImageButton")) then
		self.Image = image :: any
	else
		warn(`[WeatherIndicatorController]: o {Config.Gui.Frame} nao tem a imagem {Config.Gui.Image}.`)
	end

	local nameLabel = panel:FindFirstChild(Config.Gui.Name)
	if nameLabel and nameLabel:IsA("TextLabel") then
		self.NameLabel = nameLabel
		self:makeResponsive(nameLabel)
	else
		warn(`[WeatherIndicatorController]: o {Config.Gui.Frame} nao tem o label {Config.Gui.Name}.`)
	end

	local durationLabel = panel:FindFirstChild(Config.Gui.Duration)
	if durationLabel and durationLabel:IsA("TextLabel") then
		self.DurationLabel = durationLabel
		self:makeResponsive(durationLabel)
	else
		warn(`[WeatherIndicatorController]: o {Config.Gui.Frame} nao tem o label {Config.Gui.Duration}.`)
	end

	local container = panel:FindFirstChild(Config.Gui.Container)
	if container and container:IsA("GuiObject") then
		self.Container = container

		--[[
			O molde de linha, se o designer desenhou um. Ele próprio nunca aparece: o que
			entra na lista são os clones, e o original fica apagado como referência de
			tamanho e margem.
		]]
		local template = container:FindFirstChild(Config.Gui.Line)
		if template and template:IsA("GuiObject") then
			template.Visible = false
			self.Template = template
		end
	else
		warn(`[WeatherIndicatorController]: o {Config.Gui.Frame} nao tem o {Config.Gui.Container}; a lista de efeitos nao vai aparecer.`)
	end

	-- O painel nasce fechado, de qualquer jeito que o designer o tenha deixado no
	-- Studio: quem o abre é o botão.
	panel.Visible = false
	scale.Scale = Config.Scale.Closed

	return true
end

--[=[
	O fator da tela: quanto o painel cresce acima da resolução de referência.

	O painel é desenhado em pixels, e pixel não cresce com a tela — o mesmo painel numa
	tela de 1440 ocupa a mesma área de pixels que numa de 1080, e por isso parece menor
	nela. Este fator devolve a proporção, e tudo dentro do painel vem junto: a letra das
	linhas é medida da caixa **depois** de o fator estar aplicado.

	A referência é uma **altura** de tela, em pixels (1080 num monitor 1080p, e não 1920):
	referência grande demais joga o fator abaixo de 1 em qualquer tela, o `Min` o prende
	em 1 e os dois números do config param de fazer efeito, sem erro nenhum aparecer.

	`Min` segura o celular no lugar: tela menor que a referência não encolhe o painel,
	porque lá ele já ocupa a fração certa da tela. `Max` fecha o teto, para o painel não
	dobrar de tamanho num 4K e passar a competir com o jogo.

	Sem câmera (o quadro entre o join e o primeiro `CurrentCamera`) o fator é 1: o painel
	abre no tamanho desenhado, e a primeira mudança de tela corrige.
]=]
function WeatherIndicatorController:viewportFactor() : number
	local camera = workspace.CurrentCamera
	if not camera then
		return 1
	end

	local height = camera.ViewportSize.Y
	local responsive = Config.Responsive

	if height <= 0 or responsive.ReferenceHeight <= 0 then
		return 1
	end

	return math.clamp(height / responsive.ReferenceHeight, responsive.Min, responsive.Max)
end

--[=[
	A escala de repouso do painel: a autorada, corrigida pela tela.

	É calculada a cada uso em vez de guardada porque a tela muda no meio da partida —
	girar o celular, arrastar a janela — e uma cópia guardada seria a escala da tela
	anterior. Ver `onViewportChanged`.
]=]
function WeatherIndicatorController:openScale() : number
	return self.AuthoredScale * self:viewportFactor()
end

--[=[
	Faz um label do designer encolher com a tela.

	`TextScaled` sozinho resolveria o celular e estragaria o monitor: o texto passaria a
	ocupar o label inteiro, maior do que foi desenhado. Ligar o `TextScaled` **com** um
	teto no tamanho autorado dá as duas coisas — o desenho original onde há espaço, e a
	letra encolhendo onde não há.

	Label que já chega com `TextScaled` ligado fica como está: o `TextSize` dele não
	significa mais nada, e virar teto cravaria a letra num número que ninguém escolheu.
]=]
function WeatherIndicatorController:makeResponsive(label : TextLabel)
	if not Config.Labels.Scale or label.TextScaled then return end

	local authored = label.TextSize

	label.TextScaled = true

	local constraint = label:FindFirstChildWhichIsA("UITextSizeConstraint")
	if not constraint then
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Name = "LabelTextSize"
		constraint.Parent = label
	end

	-- A ordem importa: o `MaxTextSize` não pode ficar abaixo do `MinTextSize` que está
	-- lá, nem o contrário, senão a propriedade é recusada.
	constraint.MinTextSize = 1
	constraint.MaxTextSize = math.max(authored, Config.Labels.MinTextSize)
	constraint.MinTextSize = math.min(Config.Labels.MinTextSize, constraint.MaxTextSize)
end

--[=[
	O clima que está no ar agora, ou `nil`.
]=]
function WeatherIndicatorController:current() : string?
	local weather = self.Controllers.WeatherController

	return weather and weather:GetCurrent() or nil
end

--[[ CONTEÚDO ]]

--[=[
	As linhas do clima, cada uma como `{ Text, Kind }`.

	O config aceita string ou tabela (ver `Indicator.Details`), e é aqui que as duas
	formas viram uma só, para quem escreve não ter de conferir o tipo a cada linha.
]=]
function WeatherIndicatorController:details(weatherName : string) : { { Text : string, Kind : string? } }
	local lines = Config.Details[weatherName] or Config.UnknownDetails
	local out = {}

	for _, line in lines do
		if typeof(line) == "string" then
			table.insert(out, { Text = line })
		elseif typeof(line) == "table" and line.Text then
			table.insert(out, { Text = line.Text, Kind = line.Kind })
		end
	end

	return out
end

--[=[
	A linha com as cores dentro dela.

	Duas passadas, e as duas só pintam pedaços:

	  1. **o número** — `+10%`, `-60%`, `20s`. O sinal escolhe a cor, e `kind` manda
	     quando o sinal engana (`+40% ENEMY HP` cresce e é péssimo). Número sem sinal
	     é debuff, que é o que os stuns de hoje são;
	  2. **o tipo de unidade** — `FIRE`, `ICE`, `ELEC`... na cor do tipo, para o
	     jogador achar o que é dele sem ler a linha inteira.

	A ordem das duas não importa: o que a primeira insere é `[color=85,170,255]`, e
	nenhum nome de tipo é escrito em minúsculas nem com dígitos. A fronteira `%f` na
	segunda é o que impede o nome de ser achado no meio de outra palavra.
]=]
function WeatherIndicatorController:markup(text : string, kind : string?) : string
	local colors = Config.Colors

	local forced = if kind then (if kind == "Buff" then colors.Buff else colors.Debuff) else nil

	local function paint(token : string) : string
		local color = forced or (if string.sub(token, 1, 1) == "+" then colors.Buff else colors.Debuff)

		return `[color={color}]{token}[/color]`
	end

	-- Duas chamadas em vez de uma: `[%%s]` num conjunto seria "porcento ou espaço",
	-- porque `%s` lá dentro continua sendo a classe de espaço em branco.
	local painted = string.gsub(text, "[%+%-]?%d+%%", paint)
	painted = string.gsub(painted, "[%+%-]?%d+s", paint)

	for word, color in colors.Classes do
		painted = string.gsub(painted, `%f[%a]{word}%f[%A]`, `[color={color}]{word}[/color]`)
	end

	return painted
end

--[=[
	A frase do prazo, ou `nil` quando não há um.

	A conta é feita **agora**, e não na chegada do aviso: o prazo é uma wave-alvo e o
	jogador joga waves inteiras com o painel fechado. A wave que está rodando conta,
	então um clima de 4 waves que acabou de entrar diz "ENDS IN 4 WAVES" e o último
	diz "ENDS IN 1 WAVE".

	Sem prazo nenhum — clima ligado na mão pelo comando `weather` — não há frase, e o
	label simplesmente não aparece.
]=]
function WeatherIndicatorController:endsText() : string?
	local current = self:current()
	if not current or self.EndsName ~= current or not self.EndsWave then
		return nil
	end

	if self.Wave <= 0 then
		return nil
	end

	local remaining = (self.EndsWave :: number) - self.Wave + 1
	if remaining <= 0 then
		return nil
	end

	return if remaining == 1
		then Config.EndsOne
		else string.format(Config.Ends, remaining)
end

--[=[
	O ícone do clima de agora, no botão e no painel.
]=]
function WeatherIndicatorController:refreshIcon(weatherName : string)
	local icon = Config.Icons[weatherName]
	if not icon then
		warn(`[WeatherIndicatorController]: o clima "{weatherName}" nao tem icone em WeatherConfig.Indicator.Icons.`)

		return
	end

	if self.ButtonImage then
		self.ButtonImage.Image = icon
	end

	if self.Image then
		self.Image.Image = icon
	end
end

--[=[
	O botão: ele existe enquanto houver clima no ar, e só.
]=]
function WeatherIndicatorController:refreshButton()
	local button = self.Button
	if not button then return end

	local current = self:current()

	button.Visible = current ~= nil

	if current then
		self:refreshIcon(current)
	end
end

--[=[
	O topo do painel: ícone, nome e prazo. Sem prazo, o label do prazo se apaga em vez
	de mostrar uma frase pela metade.
]=]
function WeatherIndicatorController:refreshHeader()
	local current = self:current()
	if not current then return end

	self:refreshIcon(current)

	if self.NameLabel then
		self.NameLabel.Text = WeatherConfig.GetDisplayName(current)
	end

	local duration = self.DurationLabel
	if duration then
		local text = self:endsText()

		duration.Text = text or ""
		duration.Visible = text ~= nil
	end
end

--[[ LINHAS ]]

--[=[
	A peça da linha `index`, criando-a na primeira vez.

	As peças são reusadas entre climas: a lista muda de conteúdo muitas vezes por
	partida e destruir para recriar jogaria fora o render de texto de cada uma junto.
	Sobra do clima anterior fica apagada, não destruída (ver `refreshLines`).

	Com molde no Studio, a peça é um clone dele; sem molde, um Frame de
	`Line.HeightScale` da altura do `Container` — fração, e não pixel, para a peça
	encolher junto com o painel no celular. Nos dois casos o `LayoutOrder` é o índice,
	para a ordem na tela ser a ordem escrita no config.
]=]
function WeatherIndicatorController:lineFrame(index : number) : GuiObject?
	local container = self.Container
	if not container then return nil end

	local frame : GuiObject

	if self.Template then
		frame = (self.Template :: GuiObject):Clone()
	else
		local created = Instance.new("Frame")
		created.Size = UDim2.new(1, 0, Config.Line.HeightScale, 0)
		created.BackgroundTransparency = 1
		created.BorderSizePixel = 0

		frame = created
	end

	frame.Name = `{Config.Gui.Line}{index}`
	frame.LayoutOrder = index
	frame.Visible = true
	frame.Parent = container

	return frame
end

--[=[
	O handle de texto rico da linha `index`, com a peça dela criada se preciso.
]=]
function WeatherIndicatorController:lineEntry(index : number) : { Frame : GuiObject, Handle : any }?
	local existing = self.Lines[index]
	if existing then
		return existing
	end

	local richText = self.Controllers.RichTextController
	if not richText then return nil end

	local frame = self:lineFrame(index)
	if not frame then return nil end

	local handle = richText:Bind(frame, Config.Text)
	if not handle then
		frame:Destroy()

		return nil
	end

	local entry = { Frame = frame, Handle = handle }
	self.Lines[index] = entry

	return entry
end

--[=[
	Espera a peça ter tamanho **estável** na tela, e diz se conseguiu.

	Não basta ser diferente de zero: o tamanho medido é o que decide a letra (ver
	`lineTextSize`) e o que o renderizador guarda como referência de escala, e um
	`UIListLayout` que ainda está distribuindo as peças dá um valor intermediário — que
	viraria uma letra de tamanho errado congelada na lista. Dois quadros com a mesma
	medida é o sinal de que o layout acabou, e é a mesma espera que o
	`DialogController` faz antes de escrever a fala.

	Escrever no prazo esgotado é de propósito: o renderizador reclama no output dizendo
	que a caixa mede zero, e é essa a pista de que a tela está com um pai apagado ou um
	tamanho de zero autorado. Silêncio aqui viraria uma lista que não aparece e não
	explica.
]=]
function WeatherIndicatorController:awaitMeasured(frame : GuiObject) : boolean
	local deadline = os.clock() + Config.Line.MeasureTimeout
	local previous = frame.AbsoluteSize

	while true do
		local current = frame.AbsoluteSize

		if current.Magnitude > 0 and current == previous then
			return true
		end

		if os.clock() > deadline then
			return false
		end

		previous = current

		task.wait()
	end
end

--[=[
	A largura de uma frase em `PROBE_SIZE`, ou `nil` quando não deu para medir.

	Medida de verdade, e não estimada por número de caracteres: a estimativa (ver
	`Line.WidthPerChar`) erra para cada lado — conservadora demais ela encolhe a letra
	sem motivo, e otimista demais deixa a frase estourar a caixa. Como a largura é linear
	no tamanho da letra, uma medida serve para todos os tamanhos.

	Dorme, porque a chamada é assíncrona; quem a usa já está numa thread própria. O
	resultado fica em cache: são sete listas no config, e a mesma frase não muda de
	largura entre aberturas.

	Falhando (a fonte não carregou, a chamada foi recusada), devolve `nil` e quem chamou
	cai na estimativa. É medida melhor, não medida obrigatória.
]=]
function WeatherIndicatorController:measureWidth(text : string) : number?
	local cached = self.Widths[text]
	if cached then
		return cached
	end

	local params = Instance.new("GetTextBoundsParams")
	params.Text = text
	params.Size = PROBE_SIZE
	params.Font = Font.new(Config.Text.Font)

	-- 0 é "sem limite": a largura que queremos é a da frase em uma fileira, e é daí que
	-- sai a conta de quantas fileiras ela precisa.
	params.Width = 0

	local ok, bounds = pcall(function()
		return TextService:GetTextBoundsAsync(params)
	end)

	if not ok or not bounds or bounds.X <= 0 then
		return nil
	end

	self.Widths[text] = bounds.X

	return bounds.X
end

--[=[
	O tamanho da letra da lista, medido da caixa de uma linha.

	É o que faz o painel ser responsivo **e** o que decide se a letra é grande ou
	pequena. O renderizador escreve em pixels, e pixel não se traduz entre telas: 12px
	ocupam um quinto da linha num monitor e metade dela num celular. Então o número não
	é escrito no config — ele sai da caixa que está na tela agora.

	São duas paredes:

	  1. **a altura** da caixa, dividida pelas fileiras que o texto vai ocupar;
	  2. **a largura** da caixa, contra a largura real da frase mais comprida (ver
	     `measureWidth`), também dividida pelas fileiras.

	E é por isso que as **fileiras** entram na conta. Uma frase de 32 caracteres numa
	caixa estreita fica minúscula se tiver de caber em uma fileira só — a largura manda, e
	manda pouco. Deixando-a usar duas, a largura disponível dobra e a altura de cada
	fileira cai à metade: onde a caixa é larga e baixa a primeira opção ganha, e onde ela
	é estreita e alta ganha a segunda. O laço experimenta de 1 a `MaxRows` e fica com a
	que der a letra maior, que é a definição do que se quer aqui.

	A conta usa a frase mais comprida da lista e o tamanho vale para todas: tipografia
	por linha pareceria defeito, não responsividade. O texto medido é o do config, sem
	marcação — as cores entram depois e não ocupam largura.

	Sem medida real, a largura vem da estimativa por caractere. Sem largura de caixa,
	só a altura manda: melhor uma letra proporcional que um zero.
]=]
function WeatherIndicatorController:lineTextSize(frame : GuiObject, lines : { { Text : string, Kind : string? } }) : number
	local line = Config.Line
	local box = frame.AbsoluteSize

	local longest = ""
	for _, entry in lines do
		if #entry.Text > #longest then
			longest = entry.Text
		end
	end

	local measured = if #longest > 0 then self:measureWidth(longest) else nil

	local best, bestRows, bestWall = line.MinTextSize, 1, "o PISO (MinTextSize)"

	for rows = 1, math.max(1, line.MaxRows) do
		local fromHeight = (box.Y * line.TextRatio) / rows

		local fromWidth = math.huge
		if box.X > 0 and #longest > 0 then
			fromWidth = if measured
				then (box.X * rows * PROBE_SIZE) / measured
				else (box.X * rows) / (#longest * line.WidthPerChar)
		end

		local size = math.min(fromHeight, fromWidth)

		if size > best then
			best = size
			bestRows = rows
			bestWall = if fromWidth < fromHeight then "a LARGURA da caixa" else "a ALTURA da caixa"
		end
	end

	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.zero

	indicatorPrint(string.format(
		-- Tudo em %.0f, e nao %d: `ViewportSize` e `AbsoluteSize` sao floats, e `%d` com
		-- float sem representacao inteira e erro, nao arredondamento.
		"tela %.0fx%.0f | escala %.2f | linha %.0fx%.0f | %.0f chars, largura %s | letra %.1f em %d fileira(s), manda %s",
		viewport.X, viewport.Y,
		(self.Scale and self.Scale.Scale) or 1,
		box.X, box.Y,
		#longest,
		if measured then string.format("medida (%.0f em %d)", measured, PROBE_SIZE) else "estimada",
		best, bestRows, bestWall
	))

	return best
end

--[=[
	Apaga o que estiver escrito nas linhas, sem desfazer o pool.
]=]
function WeatherIndicatorController:clearLines()
	for _, entry in self.Lines do
		entry.Handle:Clear(true)
	end
end

--[=[
	Escreve a lista do clima que está no ar, uma linha depois da outra.

	O `Stagger` é o que dá o efeito de lista se montando em vez de aparecer pronta, e
	é por isso que a escrita mora numa thread própria: ela dorme entre uma linha e a
	seguinte, e o clique que a começou não pode esperar por isso.

	Sobra do clima anterior é **apagada**, e não destruída: a peça fica no pool para a
	próxima lista mais comprida reusá-la.
]=]
function WeatherIndicatorController:refreshLines()
	local current = self:current()
	if not current or not self.Container then return end

	self.Token += 1
	local token = self.Token

	local lines = self:details(current)

	for index, entry in self.Lines do
		if index > #lines then
			entry.Handle:Clear(true)
			entry.Frame.Visible = false
		end
	end

	local entries = {}

	for index, line in lines do
		local entry = self:lineEntry(index)
		if not entry then continue end

		entry.Frame.Visible = true
		entry.Handle:Clear(true)

		entries[index] = { Entry = entry, Line = line }
	end

	task.spawn(function()
		local size : number? = nil

		for index = 1, #lines do
			if self.Token ~= token then return end

			local queued = entries[index]
			if queued then
				-- Peça criada agora só mede depois da passada de layout.
				self:awaitMeasured(queued.Entry.Frame)

				if self.Token ~= token then return end

				--[[
					O tamanho sai da primeira peça medida e vale para a lista inteira: as peças
					são todas do mesmo tamanho, e medir de novo a cada linha só abriria a chance
					de duas linhas saírem com letras diferentes.

					A conta dorme na primeira vez (a largura da frase é medida por uma chamada
					assíncrona), então o token é conferido de novo depois dela.
				]]
				if not size then
					size = self:lineTextSize(queued.Entry.Frame, lines)

					if self.Token ~= token then return end
				end

				queued.Entry.Handle:Write(
					self:markup(queued.Line.Text, queued.Line.Kind),
					{ Size = size }
				)
			end

			if index < #lines then
				task.wait(Config.Line.Stagger)
			end
		end
	end)
end

--[=[
	A tela mudou de tamanho: o painel volta à escala de repouso da tela nova e a lista é
	reescrita na medida nova.

	Girar o celular ou arrastar a janela muda duas coisas: o fator da tela (e com ele a
	escala de repouso do painel) e a caixa de cada linha, e com ela as duas contas da
	letra — a proporção da altura e o que a linha mais comprida precisa de largura. O
	renderizador reescala o que já está escrito junto com a caixa, o que salva a
	proporção, mas não desfaz uma quebra de linha que a largura nova não pede mais.

	Quem escreve a escala nova é o próprio `writeLinesWhenSettled`: ele já existe para
	não escrever em painel fora do repouso, e painel fora do repouso sem tween nenhum é
	exatamente o que uma tela nova deixa.

	Só vale com o painel aberto, e o compasso é de quem chegou por último: um arraste de
	janela dispara isto a cada quadro, e reescrever a lista em cada um deles seria a
	animação de digitação recomeçando sem parar.

	É a **tela** que é escutada, e não o tamanho do painel: o painel muda de tamanho a
	cada quadro da própria animação de entrada, e essa mudança não é uma tela nova.
]=]
function WeatherIndicatorController:onViewportChanged()
	if not self.IsOpen then return end

	self.ViewportToken += 1
	local token = self.ViewportToken

	task.delay(Config.Line.ResizeDebounce, function()
		if self.ViewportToken ~= token or not self.IsOpen then return end

		self:writeLinesWhenSettled()
	end)
end

--[=[
	Escreve a lista com o painel na escala de repouso, e não antes.

	É a única porta pela qual a lista entra, e existe por causa de como o texto rico se
	dimensiona: ele guarda o tamanho da caixa no instante do render e escala o texto
	pela razão entre o tamanho de agora e aquele. Como o `AbsoluteSize` de um filho já
	vem multiplicado pelo `UIScale` do painel, escrever no meio da entrada mede a caixa
	quase fechada — e a linha termina do tamanho da tela quando o painel chega ao fim,
	ou não aparece, quando a escala ainda estava em zero e o render foi descartado por
	medir zero.

	Quem decide não é o estado do tween, é a **escala**: painel já no repouso escreve na
	hora, painel fora dele espera. Esperar o tween é o caminho normal; o `else` cobre o
	painel que ficou fora do repouso sem tween nenhum (um `Cancel` no meio), e aí a
	escala é escrita na mão e a lista sai um quadro depois, o tempo de o layout medir.

	A lista anterior é apagada enquanto se espera: ela não pode ficar na tela por baixo
	da animação de uma abertura que ainda não escreveu.

	`Cancelled` não escreve: é o fechamento (ou outra abertura) tendo derrubado o tween,
	e quem o derrubou já decidiu o que a tela mostra.
]=]
function WeatherIndicatorController:writeLinesWhenSettled()
	local uiScale = self.Scale
	local rest = self:openScale()

	if not uiScale or math.abs(uiScale.Scale - rest) <= SCALE_EPSILON then
		self:refreshLines()

		return
	end

	self:clearLines()

	self.Token += 1
	local token = self.Token

	local tween = self.ScaleTween

	if tween and tween.PlaybackState == Enum.PlaybackState.Playing then
		tween.Completed:Once(function(state : Enum.PlaybackState)
			if state ~= Enum.PlaybackState.Completed then return end
			if self.Token ~= token or not self.IsOpen then return end

			self:refreshLines()
		end)

		return
	end

	uiScale.Scale = rest

	task.spawn(function()
		task.wait()

		if self.Token ~= token or not self.IsOpen then return end

		self:refreshLines()
	end)
end

--[[ ABRIR E FECHAR ]]

--[=[
	Leva o `UIScale` a uma escala, cancelando o tween anterior.

	`Cancel` para o tween sem devolver a propriedade: a escala fica onde chegou e o
	novo parte dali, que é o que faz o clique no meio da animação emendar em vez de
	saltar.
]=]
function WeatherIndicatorController:tweenScale(scale : number, info : TweenInfo) : Tween?
	local uiScale = self.Scale
	if not uiScale then return nil end

	if self.ScaleTween then
		self.ScaleTween:Cancel()
	end

	local tween = TweenService:Create(uiScale, info, { Scale = scale })
	self.ScaleTween = tween
	tween:Play()

	return tween
end

--[=[
	Abre o painel: cresce, e a lista entra quando ele para de crescer (ver
	`writeLinesWhenSettled`).

	A escala de chegada é a **autorada** no `UIScale` corrigida pela tela (ver
	`openScale`): painel desenhado em 0.8 abre em 0.8 na tela de referência, e maior que
	isso numa tela maior.

	Sem clima no ar não abre — o botão nem está lá, mas o `Toggle` é público e o estado
	da tela não pode depender de quem o chama.
]=]
function WeatherIndicatorController:Open()
	local panel = self.Panel
	if not panel or not self:current() then return end

	self.IsOpen = true

	panel.Visible = true

	self:refreshHeader()
	self:tweenScale(self:openScale(), Config.Scale.OpenInfo)
	self:writeLinesWhenSettled()
end

--[=[
	Fecha o painel. `instant` pula a animação — é o que o clima acabando e o round
	recomeçando precisam.

	O texto é apagado junto: a lista tem de entrar escrevendo na próxima abertura, e
	não já pronta por baixo da animação de entrada.
]=]
function WeatherIndicatorController:Close(instant : boolean?)
	local panel = self.Panel
	if not panel then return end

	self.IsOpen = false

	-- Derruba a escrita que ainda estiver em curso, e marca esta saída.
	self.Token += 1
	local token = self.Token

	self:clearLines()

	if instant then
		if self.ScaleTween then
			self.ScaleTween:Cancel()
			self.ScaleTween = nil
		end

		local scale = self.Scale
		if scale then
			scale.Scale = Config.Scale.Closed
		end

		panel.Visible = false

		return
	end

	local tween = self:tweenScale(Config.Scale.Closed, Config.Scale.CloseInfo)
	if not tween then
		panel.Visible = false

		return
	end

	tween.Completed:Once(function()
		-- Só apaga se esta saída ainda é a da vez: reabrir antes do fim da animação
		-- deixa o painel aberto, e quem chegou depois manda.
		if self.Token ~= token or self.IsOpen then return end

		panel.Visible = false
	end)
end

--[=[
	O interruptor do botão.
]=]
function WeatherIndicatorController:Toggle()
	if self.IsOpen then
		self:Close()
	else
		self:Open()
	end
end

--[=[
	O clima mudou: o botão acompanha, e o painel aberto se refaz — ou fecha, quando o
	céu limpou.
]=]
function WeatherIndicatorController:refresh()
	self:refreshButton()

	if not self:current() then
		if self.IsOpen then
			self:Close(true)
		end

		return
	end

	if self.IsOpen then
		self:refreshHeader()

		-- Pode ser um clima que trocou no meio da animação de entrada, e aí a lista nova
		-- espera pelo mesmo motivo que a primeira esperou.
		self:writeLinesWhenSettled()
	end
end

--[[ CICLO DE VIDA ]]

function WeatherIndicatorController:construct()
	if not self:bind() then return end

	self:refreshButton()

	local button = self.Button :: GuiButton

	button.MouseButton1Click:Connect(function()
		self:Toggle()
	end)

	Framework:Listen("WeatherChanged", function()
		--[[
			O `WeatherController` é quem guarda o clima de agora, e ele escuta o mesmo
			aviso. Ler dele um quadro depois dispensa manter uma segunda cópia do mesmo
			estado aqui — e uma cópia a menos é uma chance a menos de as duas
			discordarem.
		]]
		task.defer(function()
			self:refresh()
		end)
	end)

	--[[
		O prazo do clima no ar, com o nome junto: o nome é o que separa este prazo do
		prazo de um clima que já saiu, já que a ordem entre este aviso e o
		`WeatherChanged` não é garantida.
	]]
	Framework:Listen("WeatherDuration", function(weatherName : any, untilWave : any)
		self.EndsName = if typeof(weatherName) == "string" then weatherName else nil
		self.EndsWave = tonumber(untilWave)

		self:refreshHeader()
	end)

	Framework:Listen("SetWave", function(wave : any)
		self.Wave = tonumber(wave) or self.Wave

		-- A frase do prazo conta a wave que está rodando, então ela envelhece a cada
		-- wave mesmo sem o clima mudar.
		self:refreshHeader()
	end)

	--[[
		Round novo não herda o prazo do anterior, nem o painel aberto do jogador que
		estava lendo quando a partida virou.
	]]
	Framework:Listen("RoundRestarted", function()
		self.Wave = 0
		self.EndsName = nil
		self.EndsWave = nil

		self:Close(true)
		self:refreshButton()
	end)

	--[[
		Tela que muda de tamanho (janela, rotação do celular) muda a conta da letra, e a
		lista aberta é reescrita na medida nova. Ver `onViewportChanged`.
	]]
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			self:onViewportChanged()
		end)
	end

	-- Quem entra no meio de uma tempestade precisa do prazo dela.
	Framework:Fire("RequestWeatherDuration")
end

--[=[
	O clima com que este cliente entrou.

	O `WeatherChanged` de quem chega no meio da tempestade é pedido pelo
	`WeatherController`, no `construct` dele, e pode ter ido e voltado antes de o
	`Listen` daqui existir. Ler o estado dele aqui — depois de todos os `init` — é o que
	garante o botão certo na tela mesmo nessa ordem.
]=]
function WeatherIndicatorController:start()
	if not self.Button then return end

	self:refresh()
end

function WeatherIndicatorController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WeatherIndicatorController
