local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local UIAssets = Assets:WaitForChild("UI")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local WeatherConfig = SharedConfig.WeatherConfig
local CardModifier = SharedConfig.CardModifier

--[[
	A cor da torre que uma carta de alvo único está prestes a pegar. Vem do
	`RoundCardConfig` porque é a mesma que a mira usa no realce da carta que não mexe
	em estatística nenhuma (ver `RoundCardShopController:_hoverUnit`): um amarelo só
	para "é esta aqui", venha ele de onde vier.
]]
local PREVIEW_COLOR = SharedConfig.RoundCardConfig.Targeting.Colors.Unit

--[[
	O vocabulário da billboard: o asset, o nome do Highlight, as cores e a lista de
	ícones. Mora no `WeatherConfig` por herança -- o clima foi a primeira coisa a
	desenhar nela --, mas ele vale para as duas fontes. Ver o cabeçalho.
]]
local Config = WeatherConfig.Feedback

local IS_STUDIO = RunService:IsStudio()

--[[
	O que está mexendo com a unidade, em cima dela.

	Toda unidade afetada ganha duas coisas:

	- um **Highlight** no modelo, azul claro quando estão ajudando e vermelho quando
	  estão atrapalhando;
	- uma **billboard na cabeça** com um ícone por estatística mexida — dano,
	  alcance, cooldown e dinheiro.

	## São três camadas, e elas se multiplicam

	1. **O clima**, que é de onde tudo isto veio (`WeatherConfig.GetUnitMultiplier`);
	2. **as cartas de round** já usadas, que deixaram regras no campo
	   (`CardModifier`, a lista que o `CardModifierController` guarda);
	3. **a prévia**, que é uma carta que o jogador está mirando *agora* e ainda não
	   usou (`SetPreview`).

	As três entram na mesma conta por estatística, e o ícone que acende é o do
	**efeito líquido**: um clima que dá +30% de dano com uma carta que tira 20%
	acende o ícone de buff, e não os dois ao mesmo tempo. Somar listas de ícones em
	vez de multiplicar números faria a unidade mostrar buff e debuff da mesma coisa
	lado a lado, que não quer dizer nada.

	A ordem dos ícones e o nome de cada um saem de `WeatherConfig.Feedback.Stats`,
	que é o vocabulário da billboard — e não uma lista do clima. É a mesma tabela que
	o clima usa, justamente para as duas fontes falarem a mesma língua na mesma
	cabeça.

	Daqui sai só o desenho: as contas são as mesmas funções compartilhadas que o
	servidor usa para aplicar o efeito de verdade. O que o jogador vê e o que ele
	leva no combate saem da mesma linha de config.

	Tudo mora **dentro do modelo da unidade** (o Attachment na cabeça, o Highlight no
	próprio modelo), então vender a unidade ou recomeçar o round limpa junto, sem
	este controller precisar saber. É também por isso que ele procura o que já
	desenhou pelo nome em vez de guardar numa tabela: não existe estado para
	desencontrar do que está no Workspace.

	É cliente puro. Nenhum evento novo trafega — a troca de clima chega em
	`WeatherChanged`, a lista de cartas em `RoundCardModifiers`, e o resto é config
	compartilhada.
]]

local WeatherFeedbackController = {
	Controllers = {
		WeatherController = {},

		-- Quem guarda a lista de cartas valendo no campo e monta o `world` que as
		-- condições de vizinhança precisam.
		CardModifierController = {},

		-- A vida da base, para a carta que só vale abaixo de 20% dela.
		BaseHealthController = {},
	}
}

--[[
	As unidades no mapa, para a troca de clima alcançar todas.

	Registro próprio em vez de ler o `createdClasses` do `UnitPlacementController`:
	é ele quem chama o `Apply` daqui, e pedir o controller dele de volta fecharia um
	ciclo no `Framework:Get` — os dois esperariam o outro carregar.

	Modelo destruído sai na próxima varredura (`Parent == nil`), então venda e
	recomeço de round não precisam avisar nada.
]]
WeatherFeedbackController.Units = {} :: { Model }

-- Aviso de ícone faltando, uma vez por nome: a varredura roda por unidade e por
-- troca de clima, e sem isso um label ausente entupiria o output.
WeatherFeedbackController.Warned = {}

--[[
	O `unitId` de cada modelo, entregue pelo `Register`.

	Vem de fora em vez de ser lido do `createdClasses` pelo mesmo motivo da lista
	acima: quem chama o `Register` é o `UnitPlacementController`, e pedir o
	controller dele de volta fecharia um ciclo. Ele já tem o id na mão no momento em
	que registra.

	Serve para uma coisa só, mas essencial: uma carta de alvo único (o Bloxiade numa
	torre) só acende na torre certa se der para dizer qual torre é qual.
]]
WeatherFeedbackController.UnitIds = {} :: { [Model] : string }

--[[
	O último desenho de cada unidade, como texto.

	A prévia é refeita **a cada quadro** enquanto o jogador arrasta o anel de uma
	carta de área pelo mapa, e quase todo quadro não muda nada: a torre que estava
	dentro do anel continua dentro. Comparar a assinatura antes de escrever é o que
	transforma "reescrever a billboard de todas as torres 60 vezes por segundo" em
	"escrever quando alguma de fato entra ou sai".

	Modelo destruído sai daqui na mesma varredura que o tira de `Units`.
]]
WeatherFeedbackController.Signatures = {} :: { [Model] : string }

--[[
	A carta que o jogador está mirando agora, se ela mexer em alguma unidade.

	`Records` é a lista de modificadores que a carta *criaria* se fosse usada onde o
	cursor está -- os mesmos registros do `RoundCardConfig`, com a zona já preenchida
	com o ponto do mapa. `Unit` restringe a prévia a um modelo só, que é o caso da
	carta de alvo único: sem ele, um registro de `Target` (que ainda não tem `UnitId`
	nenhum) valeria para o mapa inteiro.

	Nil quando ninguém está mirando.
]]
WeatherFeedbackController.Preview = nil

--[[ BILLBOARD ]]

--[=[
	A billboard da unidade, criando-a na primeira vez.

	Devolve `nil` para unidade sem cabeça ou sem o asset — nenhum dos dois deveria
	acontecer, e nos dois casos o Highlight ainda entra sozinho.
]=]
function WeatherFeedbackController:getBillboard(unitModel : Model) : Instance?
	local head = unitModel:FindFirstChild(Config.HeadName)
	if not head then return nil end

	local existing = head:FindFirstChild(Config.Asset)
	if existing then
		return existing
	end

	local asset = UIAssets:FindFirstChild(Config.Asset)
	if not asset then
		if IS_STUDIO and not self.Warned[Config.Asset] then
			self.Warned[Config.Asset] = true
			warn(string.format("[WeatherFeedbackController]: nao achei '%s' em Assets.UI.", Config.Asset))
		end
		return nil
	end

	local clone = asset:Clone()

	--[[
		O `Adornee` autorado aponta para uma cabeça que não veio no clone, e um
		Adornee morto deixa a billboard sem âncora. Zerar devolve a BillboardGui para
		o Attachment que a carrega, que é o encaixe que o asset já traz pronto.
	]]
	local gui = clone:FindFirstChildWhichIsA("BillboardGui")
	if gui then
		gui.Adornee = nil
	end

	clone.Parent = head

	return clone
end

--[=[
	Acende exatamente os ícones de `icons` e apaga o resto.

	A ordem da lista vira `LayoutOrder`: os labels do asset nascem todos em 0, e com
	empate o `UIListLayout` cai na ordem alfabética — que colocaria o dano depois do
	cooldown. Escrever a ordem aqui faz a billboard sempre ler dano, alcance e
	cooldown na mesma sequência, tenha a unidade um ícone ou três.
]=]
function WeatherFeedbackController:setIcons(billboard : Instance, icons : { string })
	local gui = billboard:FindFirstChildWhichIsA("BillboardGui")
	local frame = gui and gui:FindFirstChildWhichIsA("Frame")
	if not frame then return end

	local wanted = {}
	for index, name in icons do
		wanted[name] = index
	end

	for _, label in frame:GetChildren() do
		if not label:IsA("ImageLabel") then continue end

		local order = wanted[label.Name]
		label.Visible = order ~= nil
		if order then
			label.LayoutOrder = order
			wanted[label.Name] = nil
		end
	end

	-- Sobrou pedido sem label: o ícone ainda não foi desenhado no asset. A unidade
	-- continua com o Highlight e com os outros ícones.
	if not IS_STUDIO then return end

	for name in wanted do
		if self.Warned[name] then continue end
		self.Warned[name] = true
		warn(string.format("[WeatherFeedbackController]: o asset '%s' nao tem o ImageLabel '%s'; esse icone nao vai aparecer.",
			Config.Asset, name))
	end
end

function WeatherFeedbackController:clearBillboard(unitModel : Model)
	local head = unitModel:FindFirstChild(Config.HeadName)
	local billboard = head and head:FindFirstChild(Config.Asset)
	if billboard then
		billboard:Destroy()
	end
end

--[[ HIGHLIGHT ]]

--[=[
	Pinta o modelo com a cor do estado, criando o Highlight na primeira vez.

	Um Highlight só, recolorido nas trocas: destruir e recriar a cada clima piscaria
	a unidade, e é o mesmo Highlight que passa de azul para vermelho quando o clima
	troca de um que ajudava para um que atrapalha.
]=]
function WeatherFeedbackController:setHighlight(unitModel : Model, kind : string)
	-- `Preview` não é um estado da unidade, é a mira em cima dela: a cor vem do
	-- `RoundCardConfig`, e não da paleta de buff/debuff do clima.
	local color = if kind == "Preview" then PREVIEW_COLOR else Config.Highlight[kind]
	if not color then return end

	local highlight = unitModel:FindFirstChild(Config.HighlightName)
	if not highlight then
		highlight = Instance.new("Highlight")
		highlight.Name = Config.HighlightName
		highlight.FillTransparency = Config.Highlight.Transparency
		highlight.OutlineTransparency = Config.Highlight.Transparency
		highlight.Parent = unitModel
	end

	highlight.FillColor = color
	highlight.OutlineColor = color
end

function WeatherFeedbackController:clearHighlight(unitModel : Model)
	local highlight = unitModel:FindFirstChild(Config.HighlightName)
	if highlight then
		highlight:Destroy()
	end
end

--[[ A CONTA ]]

--[=[
	Tudo que a conta de uma unidade precisa, montado uma vez por varredura.

	O `world` (a lista de unidades do mapa e a vida da base) é caro de montar e é o
	mesmo para todas elas, e a lista de cartas também. Montá-los por unidade seria
	refazer o mapa inteiro uma vez por torre — que é exatamente o laço quadrático que
	a prévia, rodando a cada quadro, não pode pagar.
]=]
function WeatherFeedbackController:_context()
	local weatherController = self.Controllers.WeatherController
	local cards = self.Controllers.CardModifierController

	return {
		Weather = weatherController and weatherController:GetCurrent() or nil,
		Modifiers = cards and cards.Modifiers or nil,
		World = cards and cards:GetWorld() or nil,
		Preview = self.Preview,
	}
end

--[=[
	O que a billboard e o Highlight desta unidade deveriam mostrar: `Icons` e `Kind`,
	ou `nil` quando nada a está afetando.

	O clima entra pela função dele, as cartas pela delas, e a prévia pela mesma
	função das cartas -- as três por estatística, multiplicadas. Ver o cabeçalho.

	`Icons` sai na ordem de `Feedback.Stats`, que é a mesma ordem em que a billboard
	os mostra. Só entram estatísticas cujo multiplicador líquido saiu de 1 -- um
	clima que mexe só no alcance acende um ícone só.

	`Kind` é **`Debuff` sempre que houver um debuff**, mesmo com buff junto: o buff o
	jogador descobre no card, a perda ele precisa perceber de longe para reagir a
	tempo. Uma unidade dentro do anel de um cajado é justamente o caso -- ela ganha
	numa estatística e paga em outra.
]=]
function WeatherFeedbackController:_feedback(unitModel : Model, context)
	local unitName = unitModel.Name
	local weather = context.Weather

	--[[
		Unidade desligada pelo clima tem resposta própria, e curta: o que ela precisa
		comunicar é "esta não está atacando". Carta nenhuma muda isso -- dobrar o dano
		de uma torre parada continua dando zero --, então a conta para aqui.
	]]
	if weather
		and not WeatherConfig.IsImmune(weather, unitName)
		and WeatherConfig.IsDisabled(weather, unitName)
	then
		return { Icons = { Config.Disabled }, Kind = "Debuff" }
	end

	local unit = {
		UnitId = self.UnitIds[unitModel],
		UnitName = unitName,
		Position = unitModel:GetPivot().Position,
	}

	local preview = context.Preview
	local previewApplies = preview ~= nil and (preview.Unit == nil or preview.Unit == unitModel)

	-- A torre que o ponteiro escolheu numa carta de alvo único: o realce dela é o
	-- amarelo da mira, e não o azul/vermelho do que ela vai sentir. Ver o `Kind`
	-- devolvido no fim.
	local isPreviewTarget = preview ~= nil and preview.Unit == unitModel

	local icons = {}
	local hasDebuff = false

	for _, entry in Config.Stats do
		local multiplier = 1

		for _, stat in entry.Stats do
			multiplier *= WeatherConfig.GetUnitMultiplier(weather, unitName, stat)
			multiplier *= CardModifier.Multiplier(context.Modifiers, stat, unit, context.World)

			if previewApplies then
				multiplier *= CardModifier.Multiplier(preview.Records, stat, unit, context.World)
			end
		end

		if multiplier == 1 then continue end

		if multiplier > 1 then
			table.insert(icons, entry.Buff)
		else
			table.insert(icons, entry.Debuff)
			hasDebuff = true
		end
	end

	--[=[
		A torre sob o ponteiro fica amarela mesmo sem ícone nenhum.

		O amarelo aqui não é "o que ela está sentindo", é "é esta que a carta vai
		pegar" -- e isso precisa aparecer antes de a carta ser usada, inclusive numa
		carta que não mexa em nenhuma das estatísticas da billboard. Os ícones, quando
		houver, continuam mostrando o que vem pela frente.

		Um realce só na torre, e não dois: o `RoundCardShopController` não desenha o
		dele quando a carta tem prévia, justamente para as duas cores não brigarem no
		mesmo modelo.
	]=]
	if isPreviewTarget then
		return {
			Icons = icons,
			Kind = "Preview",
		}
	end

	if #icons == 0 then
		return nil
	end

	return {
		Icons = icons,
		Kind = if hasDebuff then "Debuff" else "Buff",
	}
end

--[[ API ]]

--[=[
	Põe (ou tira) o feedback de uma unidade.

	`context` vem do `Refresh` quando a varredura é do mapa inteiro; sem ele, é
	montado aqui -- o caso de uma unidade só.

	A assinatura é comparada antes de qualquer escrita: reescrever a billboard com o
	mesmo conteúdo não muda nada na tela e custa uma varredura de labels por unidade
	por quadro enquanto a prévia estiver aberta.
]=]
function WeatherFeedbackController:Apply(unitModel : Model, context)
	if not unitModel or not unitModel.Parent then return end

	local feedback = self:_feedback(unitModel, context or self:_context())

	local signature = if feedback
		then feedback.Kind .. "|" .. table.concat(feedback.Icons, ",")
		else ""

	if self.Signatures[unitModel] == signature then
		return
	end

	self.Signatures[unitModel] = signature

	if not feedback then
		self:clearBillboard(unitModel)
		self:clearHighlight(unitModel)
		return
	end

	local billboard = self:getBillboard(unitModel)
	if billboard then
		self:setIcons(billboard, feedback.Icons)
	end

	self:setHighlight(unitModel, feedback.Kind)
end

--[=[
	Registra uma unidade recém-colocada e já a pinta.

	Chamado pelo `UnitPlacementController` no fim de `replicatePlacedUnit` — quem
	coloca uma unidade no meio da tempestade (ou dentro do anel de um cajado) tem que
	vê-la afetada na hora, e não só na próxima troca de clima.

	O mapa inteiro é repintado junto, e não só ela: duas cartas medem a **vizinhança**
	(o Iceolated premia a torre sozinha, o Ice to Meet You castiga quem está perto do
	gelo), então uma torre nova muda o que as vizinhas dela estão sentindo.
]=]
function WeatherFeedbackController:Register(unitModel : Model, unitId : string?)
	if not unitModel then return end

	table.insert(self.Units, unitModel)
	self.UnitIds[unitModel] = unitId

	self:Refresh()
end

--[=[
	Repinta o mapa inteiro. É o passo da troca de clima, da carta usada e de cada
	quadro da prévia.

	A varredura aproveita para soltar as unidades que já saíram do Workspace, que é
	o que faz a venda e o recomeço de round não precisarem avisar nada.
]=]
function WeatherFeedbackController:Refresh()
	local context = self:_context()

	for index = #self.Units, 1, -1 do
		local unitModel = self.Units[index]

		if not unitModel or not unitModel.Parent then
			table.remove(self.Units, index)

			if unitModel then
				self.UnitIds[unitModel] = nil
				self.Signatures[unitModel] = nil
			end

			continue
		end

		self:Apply(unitModel, context)
	end
end

--[=[
	Mostra nas unidades o que uma carta **ainda não usada** faria com elas.

	`records` são os modificadores que a carta criaria, com a zona já preenchida com
	o ponto do mapa onde o cursor está; `unitModel` restringe a prévia a uma torre só,
	que é o caso da carta de alvo único.

	É o mesmo desenho do efeito de verdade, de propósito: o jogador arrasta o anel
	pelo mapa e lê, nas cabeças das torres, exatamente o que vai acontecer com elas se
	ele soltar ali. Um segundo desenho para "o que vai acontecer" o obrigaria a
	aprender duas linguagens para a mesma informação.

	Chamado a cada quadro enquanto a mira estiver aberta -- o `Apply` compara a
	assinatura antes de escrever, então quadro que não muda nada não custa nada.
]=]
function WeatherFeedbackController:SetPreview(records : { any }?, unitModel : Model?)
	if not records or #records == 0 then
		self:ClearPreview()
		return
	end

	self.Preview = { Records = records, Unit = unitModel }
	self:Refresh()
end

--- Tira a prévia e devolve as unidades ao que elas de fato estão sentindo.
function WeatherFeedbackController:ClearPreview()
	if not self.Preview then return end

	self.Preview = nil
	self:Refresh()
end

--[[ CICLO DE VIDA ]]

function WeatherFeedbackController:construct()
	--[[
		O `WeatherController` também escuta este evento para guardar o clima atual, e
		a ordem entre os dois não é garantida. Um passo de espera é o suficiente: o
		`GetCurrent` já responde o clima novo quando o `Refresh` roda.
	]]
	Framework:Listen("WeatherChanged", function()
		task.defer(function()
			self:Refresh()
		end)
	end)

	--[[
		Uma carta entrou no campo, ou uma venceu. O `task.defer` é pelo mesmo motivo do
		clima: o `CardModifierController` também escuta este evento para guardar a
		lista, e a ordem entre os dois não é promessa de lugar nenhum.
	]]
	Framework:Listen("RoundCardModifiers", function()
		task.defer(function()
			self:Refresh()
		end)
	end)

	--[[
		A vida da base cruzou algum limite: o No Pain, No Gain só vale abaixo de 20%
		dela, e é a única coisa que liga e desliga um buff sem ninguém clicar em nada.

		Sem filtro de "cruzou ou não": a base só muda quando um inimigo vaza, e o
		`Apply` já sai fora sozinho quando o desenho não mudou.
	]]
	Framework:Listen("UpdateBaseHealth", function()
		task.defer(function()
			self:Refresh()
		end)
	end)
end

function WeatherFeedbackController:start()
end

function WeatherFeedbackController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WeatherFeedbackController
