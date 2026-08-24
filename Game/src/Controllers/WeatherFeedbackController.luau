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
local Config = WeatherConfig.Feedback

local IS_STUDIO = RunService:IsStudio()

--[[
	O clima em cima da unidade.

	Enquanto um clima estiver no ar, toda unidade que ele mexe ganha duas coisas:

	- um **Highlight** no modelo, azul claro quando o clima está ajudando e vermelho
	  quando está atrapalhando;
	- uma **billboard na cabeça** com um ícone por estatística mexida — dano,
	  alcance e cooldown.

	Quem decide o quê é o `WeatherConfig.GetUnitFeedback`: ele já sabe a classe da
	unidade, a imunidade e a regra de precedência dos multiplicadores. Daqui sai só o
	desenho — e é de propósito, porque o servidor faz a mesma conta com a mesma função
	para aplicar o efeito de verdade. O que o jogador vê e o que ele leva no combate
	saem da mesma linha de config.

	Tudo mora **dentro do modelo da unidade** (o Attachment na cabeça, o Highlight no
	próprio modelo), então vender a unidade ou recomeçar o round limpa junto, sem
	este controller precisar saber. É também por isso que ele procura o que já
	desenhou pelo nome em vez de guardar numa tabela: não existe estado para
	desencontrar do que está no Workspace.

	É cliente puro. Nenhum evento novo trafega — a troca de clima já chega em
	`WeatherChanged`, e o resto é config compartilhada.
]]

local WeatherFeedbackController = {
	Controllers = {
		WeatherController = {}
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
	local color = Config.Highlight[kind]
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

--[[ API ]]

--[=[
	Põe (ou tira) o feedback de uma unidade, conforme o clima do momento.

	O nome do modelo é o nome da unidade: é ele que `UnitStats` indexa, e é dele que
	sai a classe que o clima consulta.
]=]
function WeatherFeedbackController:Apply(unitModel : Model)
	if not unitModel or not unitModel.Parent then return end

	local weatherController = self.Controllers.WeatherController
	local weather = weatherController and weatherController:GetCurrent() or nil

	local feedback = WeatherConfig.GetUnitFeedback(weather, unitModel.Name)

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
	coloca uma unidade no meio da tempestade tem que vê-la afetada na hora, e não só
	na próxima troca de clima.
]=]
function WeatherFeedbackController:Register(unitModel : Model)
	if not unitModel then return end

	table.insert(self.Units, unitModel)
	self:Apply(unitModel)
end

--[=[
	Repinta o mapa inteiro. É o passo da troca de clima.

	A varredura aproveita para soltar as unidades que já saíram do Workspace, que é
	o que faz a venda e o recomeço de round não precisarem avisar nada.
]=]
function WeatherFeedbackController:Refresh()
	for index = #self.Units, 1, -1 do
		local unitModel = self.Units[index]

		if not unitModel or not unitModel.Parent then
			table.remove(self.Units, index)
			continue
		end

		self:Apply(unitModel)
	end
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
