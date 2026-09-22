local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.RichTextConfig

--[[
	O tamanho em que a largura de uma frase é medida (ver `measureWidth`).

	A largura de um texto é linear no tamanho da letra, então medir uma vez num tamanho
	grande e escalar dá a largura em qualquer tamanho — com a vantagem de o erro de
	arredondamento de um tamanho pequeno não entrar na conta. Ele não aparece na tela.
]]
local PROBE_SIZE = 100

--[[
	A conta da letra, no output do Studio (ver `FitOptions.Debug`).

	Só no Studio, porque é informação de quem está desenhando a tela e não do jogador.
]]
local IS_STUDIO = RunService:IsStudio()

local function fitPrint(...)
	if not IS_STUDIO then return end
	print("[RichTextController]", ...)
end

--[[
	Texto rico: letra por letra, com cor, tremor, imagem no meio da frase.

	Quem renderiza hoje é o HyperText (`Shared.Vendor.HyperText`, MIT, de @lopjoss),
	mas o jogo não sabe disso. O jogo fala com este controller:

		local RichText = Framework:Get("RichTextController")

		RichText:Write(label, "WARNING! [shake]FOG[/shake] COMING IN 3 ROUNDS", {
			Preset = "Warning",
		})

	Ou, quando o mesmo container vai receber várias frases (uma fala de NPC, um
	tutorial), guarda o handle e reusa:

		local handle = RichText:Bind(dialogueFrame, { Preset = "Dialogue" })

		handle:OnFinished(function()
			prompt.Visible = true
		end)

		handle:Write("Bem-vindo, [color=yellow]comandante[/color].[pause=1] Sente-se.")

	**Por que não requerer o HyperText direto.** Porque ele é a escolha de hoje. O
	que o jogo escreve — a marcação dentro do texto, o nome dos presets, os métodos
	do handle — está descrito em `SharedConfig.RichTextConfig` e aqui, em termos que
	não são de biblioteca nenhuma. Trocar de tecnologia é escrever um backend novo
	ao lado dos dois que existem e mudar uma coluna na tabela de aliases; nenhuma
	tela do jogo muda de linha.

	**O backend.** `Backends/` tem um módulo por tecnologia. Cada um carrega a lib
	dele tarde, dentro de um pcall, e diz se conseguiu — é o que permite ao
	`Backends` do config listar uma ordem de preferência e este controller ficar no
	primeiro que responder. Hoje: `HyperTextBackend` e, de reserva, `PlainBackend`,
	que arranca a marcação e escreve texto puro num TextLabel. A reserva não é
	enfeite: vendor fora do sync, erro de require, mudança de engine — em qualquer
	um desses o aviso continua aparecendo, feio, mas aparecendo.

	Um backend implementa:

		Backend.Name                            string
		Backend.Load() -> boolean               tenta carregar a lib
		Backend.Tag(name, value, closing)       alias -> dialeto (nil = não é alias)
		Backend.Create(container) -> object
		Backend.Apply(object, options)          opções neutras -> ajustes da lib
		Backend.Render(object, text, options)
		Backend.Skip / Pause / Resume (object)
		Backend.Clear(object, instant)
		Backend.Destroy(object)
		Backend.IsRendering(object) -> boolean
		Backend.GetText(object) -> string?
		Backend.OnFinished(object, fn) -> () -> ()
		Backend.OnEvent(object, fn) -> () -> ()

	**O tamanho da letra.** `Size` é em pixels, e pixel não se traduz entre telas.
	Quem quiser a letra saindo da caixa em vez de um número pede `Fit`:

		RichText:Write(label, "WAVE 12 INCOMING", { Fit = true })

	A caixa é medida no instante da escrita, e o tamanho sai dela — ver
	`RichTextConfig.Fit` para as paredes da conta e `:FitSize()` para a caixa que
	precisa de um tamanho só para várias peças irmãs.

	**A marcação.** `[nome]texto[/nome]`, `[nome=valor]`, `[br]`. Só é tag o que
	estiver em `RichTextConfig.Aliases`; qualquer outro colchete é texto comum, que
	é o que faz `[1]` no meio de uma frase continuar sendo `[1]`. `[[` escreve um
	colchete literal — é assim que `:Escape()` neutraliza texto de jogador.

	Fica em `common/` porque as duas places escrevem na tela.
]]

local RichTextController = {
	Controllers = {}
}

-- O backend em uso. Resolvido na primeira vez que alguém escreve, não no `init`:
-- controller que renderiza no próprio `init` não pode depender da ordem em que o
-- `Me:Load()` varreu a pasta.
RichTextController.Backend = nil :: any

RichTextController.Resolved = false

-- [GuiObject] = Handle. Um container tem um handle só — dois renderizadores no
-- mesmo frame escreveriam por cima um do outro.
RichTextController.Handles = {}

--[[
	`[fonte][frase] = largura em PROBE_SIZE`, das que já foram medidas.

	Vale para a sessão inteira: a mesma frase não muda de largura entre duas escritas,
	e a chamada que a mede é assíncrona — sem o cache, toda relançada da mesma tela
	pagaria a viagem de novo.
]]
RichTextController.Widths = {}

--[[ HANDLE ]]

--[=[
	O objeto que o jogo segura: um container mais o render que está nele.

	Todo método devolve `self` quando não tem nada melhor a devolver, então dá para
	encadear. Nenhum deles estoura se o backend tiver morrido no meio do caminho —
	handle de container destruído vira inerte em vez de erro.
]=]
local Handle = {}
Handle.__index = Handle

export type Options = typeof(Config.Defaults)

export type Handle = typeof(setmetatable(
	{} :: {
		Container : GuiObject,
		Options : Options,
		Backend : any,
		Object : any,
		Alive : boolean,
	},
	Handle
))

--[=[
	Escreve.

	Opções passadas aqui entram por cima das que o handle já tinha e **ficam** —
	é um `:SetOptions()` antes do texto, não um ajuste de uma frase só. Voltar
	atrás é passar o valor antigo de novo. É assim porque as opções viram
	configuração do renderizador lá dentro: desfazê-las depois de cada frase
	custaria uma remontagem por frase para um caso que o jogo não tem.

	Com `Fit` ligado a chamada **dorme** antes de escrever: a letra sai da caixa, e
	a caixa só mede depois da passada de layout. Ver `:Fit()`.
]=]
function Handle:Write(text : string, options : Options?) : Handle
	if not self.Alive then return self end

	if options then
		self:SetOptions(options)
	end

	if self.Options.Fit then
		self:Fit(text)

		-- O `:Fit()` dorme, e o container pode ter sido destruído no meio.
		if not self.Alive then return self end
	end

	self.Backend.Render(self.Object, RichTextController:translate(text, self.Backend), self.Options)

	return self
end

--[=[
	Mede a caixa e tira dela o tamanho da letra, daqui para frente.

	É o que `Fit` faz sozinho a cada `:Write()`. Chamar à mão serve para o depois: a
	tela mudou de tamanho e o que está escrito precisa da medida nova.

		container:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			handle:Fit()
		end)

	Sem `text`, a conta usa a última frase escrita — que é o que a tela redimensionada
	quer. Com `text`, usa o que vai ser escrito, que é o que o `:Write()` quer: a frase
	que ainda não está lá é a que tem de caber.

	Uma lista de frases mede pela **mais comprida** e devolve um tamanho só. Ver
	`RichTextController:FitSize`.

	**Dorme**: espera a caixa ter tamanho estável e mede a largura da frase por uma
	chamada assíncrona. Não reescreve o que já está na tela — o renderizador reescala o
	que está desenhado junto com a caixa; o tamanho novo vale para a escrita seguinte.
]=]
function Handle:Fit(text : (string | { string })?) : Handle
	if not self.Alive then return self end

	local sample = text or self.Backend.GetText(self.Object) or ""

	local fit = RichTextController:fitSettings(self.Options.Fit)

	RichTextController:AwaitLayout(self.Container, fit.LayoutTimeout)

	if not self.Alive then return self end

	local size = RichTextController:FitSize(self.Container, sample, self.Options, fit)

	if not self.Alive then return self end

	self.Options.Size = size
	self.Backend.Apply(self.Object, self.Options)

	return self
end

--[=[
	Mostra tudo agora, sem esperar o resto da digitação. É o que o clique do
	jogador no meio de uma fala deve fazer.
]=]
function Handle:Skip() : Handle
	if self.Alive then
		self.Backend.Skip(self.Object)
	end

	return self
end

function Handle:Pause() : Handle
	if self.Alive then
		self.Backend.Pause(self.Object)
	end

	return self
end

function Handle:Resume() : Handle
	if self.Alive then
		self.Backend.Resume(self.Object)
	end

	return self
end

--[=[
	Apaga o que está escrito. `instant` pula a animação de saída.
]=]
function Handle:Clear(instant : boolean?) : Handle
	if self.Alive then
		self.Backend.Clear(self.Object, instant)
	end

	return self
end

--[=[
	Troca as opções do handle daqui para frente. Não reescreve o que já está na
	tela — quem quiser isso chama `:Write()` de novo.
]=]
function Handle:SetOptions(options : Options) : Handle
	if not self.Alive then return self end

	self.Options = RichTextController:resolveOptions(options, self.Options)
	self.Backend.Apply(self.Object, self.Options)

	return self
end

--[=[
	O texto da última frase, sem marcação nenhuma. Serve para medir, comparar ou
	mandar para o log.
]=]
function Handle:GetText() : string?
	if not self.Alive then return nil end

	return self.Backend.GetText(self.Object)
end

--[=[
	`true` enquanto ainda tem letra por aparecer, mesmo pausado.
]=]
function Handle:IsWriting() : boolean
	if not self.Alive then return false end

	return self.Backend.IsRendering(self.Object)
end

--[=[
	Chama de volta quando a frase termina de aparecer. Devolve a função que
	desconecta.

	O argumento é `true` quando o fim veio de um `:Skip()` — uma fala que pulou não
	merece a mesma pausa dramática de uma que foi até o fim.
]=]
function Handle:OnFinished(callback : (skipped : boolean) -> ()) : () -> ()
	if not self.Alive then return function() end end

	return self.Backend.OnFinished(self.Object, callback)
end

--[=[
	Chama de volta quando a digitação passa por um `[event=nome]`. Devolve a função
	que desconecta.

	É o gancho para sincronizar som, câmera ou VFX com um ponto da frase em vez de
	com um `task.wait` chutado.
]=]
function Handle:OnEvent(callback : (name : string) -> ()) : () -> ()
	if not self.Alive then return function() end end

	return self.Backend.OnEvent(self.Object, callback)
end

function Handle:Destroy()
	if not self.Alive then return end

	self.Alive = false
	RichTextController.Handles[self.Container] = nil

	self.Backend.Destroy(self.Object)
end

--[[ INTERNAL ]]

--[=[
	O backend em uso, carregando o primeiro da fila que responder.

	O `warn` do fim é para o caso impossível de nem o `PlainBackend` carregar — que
	só acontece com a pasta `Backends` fora do sync. Devolvendo `nil`, todo `Write`
	vira no-op silencioso em vez de erro em cascata.
]=]
function RichTextController:getBackend() : any
	if self.Resolved then
		return self.Backend
	end

	self.Resolved = true

	for _, name in Config.Backends do
		local module = script.Backends:FindFirstChild(`{name}Backend`)
		if not module or not module:IsA("ModuleScript") then
			warn(`[RichTextController]: backend "{name}" nao existe em Backends/.`)
			continue
		end

		local backend = require(module) :: any
		if backend.Load() then
			self.Backend = backend

			if name ~= Config.Backends[1] then
				warn(`[RichTextController]: usando o backend "{name}" — "{Config.Backends[1]}" nao carregou.`)
			end

			return backend
		end
	end

	warn("[RichTextController]: nenhum backend carregou; o texto rico esta desligado.")

	return nil
end

--[=[
	Junta `Defaults`, o preset e o que veio na chamada, nessa ordem.

	`base` é o que o handle já tinha — é o que faz um `:SetOptions()` com uma opção
	só não jogar fora o resto da configuração do handle.

	O preset só entra quando vem **nesta** chamada. O preset de `base` já está
	dentro de `base`, misturado com os ajustes que quem chamou fez por cima dele;
	reaplicá-lo aqui desfaria justamente esses ajustes.
]=]
function RichTextController:resolveOptions(options : Options?, base : Options?) : Options
	local resolved = {}

	local function merge(source : any?)
		if not source then return end

		for key, value in source do
			if key == "Preset" then continue end

			resolved[key] = value
		end
	end

	merge(Config.Defaults)
	merge(base)

	local presetName = options and options.Preset
	if presetName then
		local preset = Config.Presets[presetName]
		if preset then
			merge(preset)
		else
			warn(`[RichTextController]: preset "{presetName}" nao existe em RichTextConfig.Presets.`)
		end
	end

	merge(options)
	resolved.Preset = presetName or (base and base.Preset)

	return resolved
end

--[=[
	Os ajustes do `Fit` resolvidos contra `RichTextConfig.Fit`.

	`true` (ou qualquer coisa que não seja tabela) é "os padrões"; tabela entra por
	cima deles campo a campo, para quem quer mexer só no `MaxRows` não ter de repetir
	os outros cinco.
]=]
function RichTextController:fitSettings(fit : any) : any
	local resolved = {}

	for key, value in Config.Fit do
		resolved[key] = value
	end

	if type(fit) == "table" then
		for key, value in fit do
			if value ~= nil then
				resolved[key] = value
			end
		end
	end

	return resolved
end

--[=[
	A largura de uma frase em `PROBE_SIZE`, ou `nil` quando não deu para medir.

	Medida de verdade, e não estimada por número de caracteres: a estimativa (ver
	`FitOptions.WidthPerChar`) erra para cada lado — conservadora demais ela encolhe a
	letra sem motivo, e otimista demais deixa a frase estourar a caixa. Como a largura é
	linear no tamanho da letra, uma medida serve para todos os tamanhos.

	Dorme, porque a chamada é assíncrona; quem a usa já está numa thread própria. O
	resultado fica em cache por frase **e por fonte** — a mesma frase em duas fontes são
	duas larguras.

	Falhando (a fonte não existe, a chamada foi recusada), devolve `nil` e quem chamou
	cai na estimativa. É medida melhor, não medida obrigatória.
]=]
function RichTextController:measureWidth(text : string, font : string) : number?
	local byFont = self.Widths[font]
	if not byFont then
		byFont = {}
		self.Widths[font] = byFont
	end

	local cached = byFont[text]
	if cached then
		return cached
	end

	local success, bounds = pcall(function()
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Size = PROBE_SIZE
		params.Font = Font.new(font)

		-- 0 é "sem limite": a largura que queremos é a da frase em uma fileira, e é daí
		-- que sai a conta de quantas fileiras ela precisa.
		params.Width = 0

		return TextService:GetTextBoundsAsync(params)
	end)

	if not success or not bounds or bounds.X <= 0 then
		return nil
	end

	byFont[text] = bounds.X

	return bounds.X
end

--[=[
	A nossa marcação virando o dialeto do backend.

	Varredura à mão em vez de `gsub` por causa do `[[`: um escape precisa ser visto
	antes de o `[` seguinte ser considerado abertura de tag.

	Colchete que não abre um alias conhecido volta para o texto como estava. É o que
	permite escrever "[1]" ou "[SPOILER]" numa frase sem escapar nada — e o que faz
	um alias escrito errado aparecer na tela em vez de sumir calado.
]=]
function RichTextController:translate(text : string, backend : any) : string
	local out = {}
	local index = 1
	local length = #text

	while index <= length do
		local open = string.find(text, "[", index, true)

		if not open then
			table.insert(out, string.sub(text, index))
			break
		end

		table.insert(out, string.sub(text, index, open - 1))

		if string.sub(text, open + 1, open + 1) == "[" then
			table.insert(out, "[")
			index = open + 2
			continue
		end

		local close = string.find(text, "]", open + 1, true)
		if not close then
			table.insert(out, string.sub(text, open))
			break
		end

		local body = string.sub(text, open + 1, close - 1)
		local closing = string.sub(body, 1, 1) == "/"
		if closing then
			body = string.sub(body, 2)
		end

		local name, value = string.match(body, "^([%a][%w_]*)=(.+)$")
		if not name then
			name = string.match(body, "^([%a][%w_]*)$")
		end

		local tag = name and backend.Tag(string.lower(name), value, closing)

		table.insert(out, tag or string.sub(text, open, close))
		index = close + 1
	end

	return table.concat(out)
end

--[[ API ]]

--[=[
	O handle do container, criando um se ainda não houver.

	Chamar duas vezes com o mesmo container devolve o mesmo handle — `options` do
	segundo em diante vale como `:SetOptions()`.
]=]
function RichTextController:Bind(container : GuiObject, options : Options?) : Handle?
	local existing = self.Handles[container]
	if existing then
		if options then
			existing:SetOptions(options)
		end

		return existing
	end

	local backend = self:getBackend()
	if not backend then
		return nil
	end

	local resolved = self:resolveOptions(options)
	local object = backend.Create(container)
	if not object then
		return nil
	end

	backend.Apply(object, resolved)

	local handle = setmetatable({
		Container = container,
		Options = resolved,
		Backend = backend,
		Object = object,
		Alive = true,
	}, Handle)

	self.Handles[container] = handle

	-- O container é do designer, não nosso: ele some quando a tela some, e o handle
	-- some junto em vez de virar entrada morta no cache.
	container.Destroying:Once(function()
		handle:Destroy()
	end)

	return handle
end

--[=[
	Escreve num container, cuidando do handle por quem chama. É a chamada de uma
	linha, para a tela que escreve uma frase e esquece.
]=]
function RichTextController:Write(container : GuiObject, text : string, options : Options?) : Handle?
	local handle = self:Bind(container, options)
	if not handle then
		return nil
	end

	-- `Bind` já aplicou as opções ao criar ou ao reencontrar o handle; passar de
	-- novo faria o backend remontar a mesma configuração à toa.
	handle:Write(text)

	return handle
end

--[=[
	Apaga o que estiver escrito no container. Container sem handle é silêncio, não
	erro — limpar o que nunca foi escrito é uma não-operação legítima.
]=]
function RichTextController:Clear(container : GuiObject, instant : boolean?)
	local handle = self.Handles[container]
	if not handle then return end

	handle:Clear(instant)
end

--[=[
	Solta o container: para o render, apaga e esquece o handle.
]=]
function RichTextController:Release(container : GuiObject)
	local handle = self.Handles[container]
	if not handle then return end

	handle:Destroy()
end

--[=[
	Espera a peça ter tamanho **estável** na tela, e diz se conseguiu.

	Não basta ser diferente de zero. O tamanho medido é o que decide a letra (ver
	`:FitSize()`) e o que o renderizador guarda como referência de escala do que
	desenhou, e um `UIListLayout` que ainda está distribuindo as peças dá um valor
	intermediário — que viraria uma letra de tamanho errado congelada na tela.

	O prazo existe para a caixa que nunca vai ganhar tamanho (tela desligada por outro
	controller, pai apagado, tamanho zero autorado): isso vira uma escrita sem efeito,
	e não uma espera infinita. Escrever no prazo esgotado é de propósito — o backend
	reclama no output dizendo que a caixa mede zero, e é essa a pista do defeito.
	Silêncio aqui viraria uma tela que não aparece e não explica.
]=]
function RichTextController:AwaitLayout(container : GuiObject, timeout : number?) : boolean
	local deadline = os.clock() + (timeout or Config.Fit.LayoutTimeout or 1)
	local previous = container.AbsoluteSize

	while true do
		local current = container.AbsoluteSize

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
	O tamanho da letra que cabe na caixa, em pixels.

	É a conta que o `Fit` faz sozinho (ver `RichTextConfig.Fit` para o porquê de cada
	parede). Chamar direto serve para o caso que o `Fit` não resolve: **várias peças
	irmãs com um tamanho só**. Uma lista de linhas se mede uma vez, na primeira peça, e
	o resultado vale para todas — tipografia por linha pareceria defeito, não
	responsividade:

		local size = RichText:FitSize(firstLine, texts, Config.Text, Config.Fit)

		for _, handle in handles do
			handle:Write(markup(...), { Size = size })
		end

	`text` é uma frase ou uma lista delas; numa lista, manda a **mais comprida**. A
	marcação é arrancada antes de medir — cor e tremor não ocupam largura.

	`options` é de onde sai a fonte em que a largura é medida (e aceita um `Preset`,
	como qualquer chamada). `fit` são os ajustes, e quando não vem usa os de
	`options.Fit`, e depois os padrões do config.

	**Dorme** na primeira vez que vê uma frase (ver `measureWidth`). Não espera o
	layout: a caixa tem de estar medida quando isto é chamado, e quem chama de fora do
	`Fit` pede isso com `:AwaitLayout()` antes.
]=]
function RichTextController:FitSize(
	container : GuiObject,
	text : (string | { string }),
	options : Options?,
	fit : any?
) : number
	local resolved = self:resolveOptions(options)
	local settings = self:fitSettings(fit or resolved.Fit)

	local longest = ""
	if type(text) == "table" then
		for _, entry in text do
			local plain = self:Plain(entry)

			if #plain > #longest then
				longest = plain
			end
		end
	else
		longest = self:Plain(text)
	end

	local font = resolved.Font or settings.Font
	local measured = if #longest > 0 then self:measureWidth(longest, font) else nil

	local box = container.AbsoluteSize

	local best, bestRows, bestWall = settings.MinTextSize, 1, "o PISO (MinTextSize)"

	for rows = 1, math.max(1, settings.MaxRows) do
		local fromHeight = (box.Y * settings.TextRatio) / rows

		local fromWidth = math.huge
		if box.X > 0 and #longest > 0 then
			fromWidth = if measured
				then (box.X * rows * PROBE_SIZE) / measured
				else (box.X * rows) / (#longest * settings.WidthPerChar)
		end

		local size = math.min(fromHeight, fromWidth)

		if size > best then
			best = size
			bestRows = rows
			bestWall = if fromWidth < fromHeight then "a LARGURA da caixa" else "a ALTURA da caixa"
		end
	end

	-- O teto entra depois da escolha, e não dentro do laço: ele é um limite de
	-- legibilidade, não uma parede que deva mudar quantas fileiras ganham.
	best = math.min(best, settings.MaxTextSize)

	if settings.Debug then
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.zero

		fitPrint(string.format(
			-- Tudo em %.0f, e nao %d: `ViewportSize` e `AbsoluteSize` sao floats, e `%d`
			-- com float sem representacao inteira e erro, nao arredondamento.
			"%s | tela %.0fx%.0f | caixa %.0fx%.0f | %.0f chars, largura %s | letra %.1f em %d fileira(s), manda %s",
			container:GetFullName(),
			viewport.X, viewport.Y,
			box.X, box.Y,
			#longest,
			if measured then string.format("medida (%.0f em %d)", measured, PROBE_SIZE) else "estimada",
			best, bestRows, bestWall
		))
	end

	return best
end

--[=[
	Texto que não é nosso — nome de jogador, mensagem de chat, nome de mapa vindo
	do servidor — passa por aqui antes de entrar numa frase.

	Dobra o colchete (o escape que o `:translate()` entende) e troca `<` por `‹`, o
	sinal parecido de largura simples: o HyperText trata `<` como começo de tag e
	engoliria o resto da frase atrás de um `>` que nunca vem.
]=]
function RichTextController:Escape(text : string) : string
	local escaped = string.gsub(text, "%[", "[[")
	escaped = string.gsub(escaped, "<", "‹")

	return escaped
end

--[=[
	A frase sem efeito nenhum: sem a nossa marcação e sem tag crua de biblioteca.

	Serve para o que não renderiza texto rico — um tooltip, um `print`, o nome que
	vai para um BillboardGui simples.
]=]
function RichTextController:Plain(text : string) : string
	local plain = self:translate(text, require(script.Backends.PlainBackend))

	return (string.gsub(plain, "<[^<>]->", ""))
end

--[=[
	Qual tecnologia está desenhando. Só para debug e para o Cmdr.
]=]
function RichTextController:GetBackend() : string?
	local backend = self:getBackend()

	return backend and backend.Name
end

--[[ CICLO DE VIDA ]]

function RichTextController:start()
	-- Resolve o backend fora do caminho do primeiro texto: carregar o vendor custa
	-- alguns milissegundos, e eles não precisam cair em cima do primeiro aviso.
	self:getBackend()
end

function RichTextController:init()
end

return RichTextController
