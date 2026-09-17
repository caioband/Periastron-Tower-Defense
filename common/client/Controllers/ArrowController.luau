local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.IndicatorArrowConfig

local TAU = math.pi * 2

--[[
	A seta que aponta um lugar no mundo.

		local Arrow = Framework:Get("ArrowController")

		local seta = Arrow:Point(unidade.Position)
		seta:MoveTo(outraPosicao)
		seta:Destroy()

	O modelo é o `Shared.Assets.VFX.IndicatorArrow`: uma seta apontando para baixo,
	montada no place (o `Shared.Assets` não é sincronizado pelo Rojo) e já
	configurada lá — partes ancoradas, soldadas e sem colisão, consulta ou toque.

	**A altura é medida, não presumida.** O controller mede, uma vez, a distância do
	pivô do modelo até a ponta de baixo dele, e é essa medida que faz `Height`
	significar "folga entre a ponta e o alvo" — e não "folga até um pivô que por
	acaso está em tal lugar". Hoje o pivô está na ponta e a seta inteira fica acima
	dele; amanhã alguém define um `PrimaryPart` (o que muda o pivô para o meio da
	peça escolhida) ou arrasta o pivô no Studio, e a seta continua apontando o mesmo
	lugar.

	A seta **gira** em torno do próprio eixo e **sobe e desce** numa senoide. Cada
	uma nasce com uma fase diferente: duas setas na tela subindo e descendo em
	sincronia parecem uma coisa só piscando, e desencontradas parecem duas.

	**Uma conexão para todas.** O laço de animação liga quando a primeira seta
	aparece e desliga quando a última sai — não existe um `RenderStepped` por seta,
	e não existe um rodando à toa com a tela vazia.

	**O molde é conferido, não consertado.** As propriedades que uma seta de
	indicação precisa ter (ancorada, sem colisão, sem consulta, sem toque) já estão
	no modelo; o controller as reescreve **uma vez** num molde guardado fora da
	árvore, porque um modelo que volte do Studio sem elas derrubaria a seta no chão
	ou a poria num `Raycast` de mira — e o custo de garantir isso é quatro escritas
	na vida da sessão, não quatro por seta.

	Fica em `common/` porque as duas places têm o modelo — e as duas têm coisa para
	apontar.
]]

local ArrowController = {
	Controllers = {}
}

-- O molde já preparado, fora da árvore. Nil até a primeira seta.
ArrowController.Template = nil :: Model?

-- A distância do pivô do molde até a ponta de baixo dele, medida uma vez. Ver
-- `measureBottom`.
ArrowController.PivotToBottom = 0

ArrowController.Container = nil :: Folder?

-- As setas vivas. É esta lista que liga e desliga o laço de animação.
ArrowController.Arrows = {}

ArrowController.Connection = nil :: RBXScriptConnection?

-- Uma fase por seta, para elas não subirem e descerem juntas.
ArrowController.Spawned = 0

ArrowController.Warned = false

--[[ HANDLE ]]

--[=[
	Uma seta no mundo. Quem pediu segura isto e manda embora quando não precisar
	mais.
]=]
local Arrow = {}
Arrow.__index = Arrow

export type Options = {
	-- Folga entre a ponta da seta e o alvo, em studs.
	Height : number?,

	-- Voltas por segundo.
	Spin : number?,

	-- Studs para cima e para baixo, e ciclos por segundo.
	Amplitude : number?,
	BobSpeed : number?,

	-- Tamanho em cima do autorado.
	Scale : number?,
}

export type Arrow = typeof(setmetatable(
	{} :: {
		Model : Model,
		Target : Vector3,
		Options : Options,
		PivotToBottom : number,
		Phase : number,
		Alive : boolean,
	},
	Arrow
))

--[=[
	Manda a seta para outro lugar. É o que uma seta que segue alguma coisa chama a
	cada passo — a animação continua de onde estava, sem recomeçar o giro.
]=]
function Arrow:MoveTo(position : Vector3) : Arrow
	if self.Alive then
		self.Target = position
	end

	return self
end

function Arrow:GetPosition() : Vector3
	return self.Target
end

function Arrow:IsAlive() : boolean
	return self.Alive
end

function Arrow:Destroy()
	if not self.Alive then return end

	self.Alive = false
	ArrowController:forget(self)

	self.Model:Destroy()
end

--[[ INTERNAL ]]

--[=[
	O modelo original, se esta place o tiver.

	O `warn` é uma vez só: uma seta pedida num laço não pode virar mil linhas no
	output por causa de um modelo que não está lá.
]=]
function ArrowController:source() : Model?
	local current : Instance = Shared

	for _, name in Config.Asset.Path do
		local found = current:FindFirstChild(name)
		if not found then
			self:warnMissing()

			return nil
		end

		current = found
	end

	local model = current:FindFirstChild(Config.Asset.Name)
	if not model or not model:IsA("Model") then
		self:warnMissing()

		return nil
	end

	return model
end

function ArrowController:warnMissing()
	if self.Warned then return end

	self.Warned = true
	warn(`[ArrowController]: nao achei o modelo "{Config.Asset.Name}" em Shared.{table.concat(Config.Asset.Path, ".")}.`)
end

--[=[
	O molde: uma cópia conferida, guardada fora da árvore.

	O modelo já vem com tudo isto ligado do jeito certo. A reescrita continua aqui
	porque ela é a diferença entre "a seta funciona" e "a seta cai no chão": o
	modelo é autorado no Studio, fora do git, e uma cópia nova que chegue sem âncora
	ou com colisão vira defeito em runtime — parte solta caindo, seta aparecendo num
	`Raycast` de mira, `Touched` de armadilha disparando à toa.

	`pivotToBottom` é a medida que faz o `Height` do config querer dizer o que ele
	diz: a distância vertical do pivô até a ponta de baixo, seja ela qual for.
]=]
function ArrowController:template() : Model?
	local template = self.Template
	if template then
		return template
	end

	local source = self:source()
	if not source then
		return nil
	end

	template = source:Clone()

	for _, descendant in template:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end

	self.Template = template
	self.PivotToBottom = self:measureBottom(template)

	return template
end

--[=[
	Quanto o pivô do modelo está acima da ponta de baixo dele.

	Hoje dá **negativo**: o pivô foi deixado na ponta e a seta inteira fica acima
	dele, então a ponta está cerca de um stud *acima* do pivô. Definir um
	`PrimaryPart` mudaria isso de uma vez (o pivô passaria a ser o centro da peça
	escolhida, seis studs acima da ponta), e é justamente por isso que este número é
	medido e não escrito no config.

	Medido com o modelo em repouso, sem rotação: a seta só gira em torno do próprio
	eixo Y, e giro em Y não mexe em altura.
]=]
function ArrowController:measureBottom(model : Model) : number
	local center, size = model:GetBoundingBox()

	return model:GetPivot().Position.Y - (center.Position.Y - size.Y / 2)
end

--[=[
	A pasta onde as setas vivem, criada na primeira.

	Fora do `Workspace.Map`, que o `MapService` troca entre partidas — seta
	pendurada lá sumiria no meio de um apontamento sem ninguém pedir.
]=]
function ArrowController:container() : Folder
	local container = self.Container
	if container and container.Parent then
		return container
	end

	local existing = workspace:FindFirstChild(Config.Container)
	if existing and existing:IsA("Folder") then
		self.Container = existing

		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = Config.Container
	folder.Parent = workspace

	self.Container = folder

	return folder
end

--[=[
	Põe uma seta onde ela tem de estar **neste instante**.

	`PivotTo` porque o modelo não tem `PrimaryPart` — e não precisa ter: o pivô é
	levado até onde a **ponta** tem de ficar, usando a medida do molde. É o que faz
	`Height` significar "esta folga entre a ponta e o alvo", em studs, doa a quem
	doer o pivô.
]=]
function ArrowController:place(arrow : Arrow, clock : number)
	local options = arrow.Options
	local motion = Config.Motion

	local height = options.Height or motion.Height
	local amplitude = options.Amplitude or motion.Bob.Amplitude
	local bobSpeed = options.BobSpeed or motion.Bob.Speed
	local spin = options.Spin or motion.Spin

	local time = clock + arrow.Phase
	local bob = math.sin(time * bobSpeed * TAU) * amplitude

	arrow.Model:PivotTo(
		CFrame.new(arrow.Target + Vector3.new(0, height + bob + arrow.PivotToBottom, 0))
			* CFrame.Angles(0, time * spin * TAU, 0)
	)
end

--[=[
	Liga o laço de animação, se ele ainda não estiver ligado.
]=]
function ArrowController:play()
	if self.Connection then return end

	self.Connection = RunService.RenderStepped:Connect(function()
		local clock = os.clock()

		for arrow in self.Arrows do
			self:place(arrow, clock)
		end
	end)
end

--[=[
	Tira a seta da lista e desliga o laço quando a última sai. Um `RenderStepped`
	rodando para uma tela sem seta nenhuma é o tipo de coisa que ninguém vê e todo
	mundo paga.
]=]
function ArrowController:forget(arrow : Arrow)
	self.Arrows[arrow] = nil

	if next(self.Arrows) then return end

	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end
end

--[[ API ]]

--[=[
	Aponta uma posição do mundo. Devolve a seta, ou `nil` se o modelo não existir
	nesta place.

	Cada chamada é uma seta nova: apontar dois lugares ao mesmo tempo é pedir duas.
	Para mover a que já existe, `seta:MoveTo(outraPosicao)`.
]=]
function ArrowController:Point(position : Vector3, options : Options?) : Arrow?
	local template = self:template()
	if not template then
		return nil
	end

	local model = template:Clone()

	local scale = (options and options.Scale) or Config.Scale
	if scale ~= 1 then
		model:ScaleTo(scale)
	end

	-- A medida do molde vale para o tamanho do molde: seta menor tem a ponta mais
	-- perto do pivô, na mesma proporção.
	local pivotToBottom = self.PivotToBottom * scale

	self.Spawned += 1

	local arrow = setmetatable({
		Model = model,
		Target = position,
		Options = options or {},
		PivotToBottom = pivotToBottom,

		-- Meia volta de defasagem entre uma seta e a seguinte: duas subindo juntas
		-- parecem uma coisa só piscando.
		Phase = self.Spawned * 0.5,

		Alive = true,
	}, Arrow)

	-- Posta antes de entrar na tela: sem isto ela aparece no lugar em que o modelo
	-- foi salvo, e só no quadro seguinte pula para o alvo.
	self:place(arrow, os.clock())
	model.Parent = self:container()

	self.Arrows[arrow] = true
	self:play()

	return arrow
end

--[=[
	Apaga todas as setas de uma vez. É o que uma troca de round ou o fim de um
	tutorial chama sem precisar guardar quem apontou o quê.
]=]
function ArrowController:ClearAll()
	for arrow in self.Arrows do
		arrow.Alive = false
		arrow.Model:Destroy()
	end

	table.clear(self.Arrows)

	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end
end

function ArrowController:Count() : number
	local count = 0

	for _ in self.Arrows do
		count += 1
	end

	return count
end

--[[ CICLO DE VIDA ]]

function ArrowController:construct()
	-- O servidor aponta por posição; sem posição, apaga. Um evento só para os dois
	-- lados evita um segundo identificador para declarar e manter.
	Framework:Listen("ArrowPoint", function(position : any, options : any)
		if typeof(position) ~= "Vector3" then
			self:ClearAll()

			return
		end

		self:ClearAll()
		self:Point(position, if type(options) == "table" then options else nil)
	end)
end

function ArrowController:start()
end

function ArrowController:init()
	self:construct()
end

return ArrowController
