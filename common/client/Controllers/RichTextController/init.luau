local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.RichTextConfig

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
]=]
function Handle:Write(text : string, options : Options?) : Handle
	if not self.Alive then return self end

	if options then
		self:SetOptions(options)
	end

	self.Backend.Render(self.Object, RichTextController:translate(text, self.Backend), self.Options)

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
