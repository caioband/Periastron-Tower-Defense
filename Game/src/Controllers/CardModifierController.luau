local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

local CardModifier = SharedConfig.CardModifier
local RoundCardConfig = SharedConfig.RoundCardConfig
local RINGS = RoundCardConfig.Rings

--[=[
	O lado do cliente das regras que as cartas de round deixaram no campo.

	O servidor e quem manda: ele guarda a lista, poda o que venceu e cobra o dano
	por ela. Este controller existe para as duas coisas que **so** aparecem na tela:

	1. **O anel no chao.** Uma carta de area deixa um circulo onde a regra dela vale,
	   e o desenho e a arte daquela carta (`Assets.VFX.Rings`, escolhida pelo `Ring`
	   dela no config). Sem ele, a decisao inteira da carta -- onde por o anel --
	   viraria invisivel um segundo depois de tomada.

	   O anel nasce onde o jogador clicou, com o **mesmo raio** que ele viu na mira, e
	   vive o tempo do efeito: ate o fim do round nos cajados de zona, e os segundos
	   da imunidade no Staff of Healing. Quem manda nos dois e a mesma zona replicada
	   pelo servidor, entao quem entra no meio da partida ve o que ja esta no chao.
	2. **O alcance de verdade.** O Staff of the Winds da 1.2x de alcance a quem tem
	   o arco. O circulo que o jogador ve ao selecionar a torre e o numero no card
	   saem do `UnitUpgradeConfig`, que nao sabe de carta nenhuma -- entao a
	   multiplicacao passa por aqui, pela **mesma** funcao que o servidor usa
	   (`CardModifier`), e nao por uma segunda conta que possa divergir dela.

	Ele nao decide nada. Uma lista que nao chegue (o jogador acabou de entrar) e uma
	lista vazia: a tela mostra o alcance de tabela, que e o que ela sempre mostrou.
]=]
local CardModifierController = {
	Controllers = {
		UnitPlacementController = {},
		UILibraryController = {},
		BaseHealthController = {},
	},

	--- A lista que o servidor mandou por ultimo.
	Modifiers = {},
}

--[[ INTERNAL ]]

--[=[
	O campo como o `CardModifier` o enxerga, montado a partir do que o cliente tem:
	os modelos de unidade que o `UnitPlacementController` desenhou.

	Refeito a cada pergunta, e nao mantido: aqui nao ha estado para invalidar quando
	uma torre entra, sai ou muda de lugar, e a lista e curta.

	> Quem chama numa varredura -- o `WeatherFeedbackController`, que repinta todas as
	> unidades de uma vez -- deve monta-lo **uma vez** e passar adiante. Ele e o mesmo
	> para todas elas, e refaze-lo por torre transformaria a varredura num laco
	> quadratico.
]=]
function CardModifierController:GetWorld()
	local placement = self.Controllers.UnitPlacementController
	local classes = placement and placement.createdClasses

	local units = {}

	if classes then
		for model, class in classes do
			if not model.Parent or not class then continue end

			table.insert(units, {
				UnitId = class.unitId,
				UnitName = model.Name,
				Position = model:GetPivot().Position,
			})
		end
	end

	local base = self.Controllers.BaseHealthController

	return {
		Units = units,

		--[[
			A vida da base como fracao. O `No Pain, No Gain` depende dela, e o cliente
			so a tem depois do primeiro `UpdateBaseHealth`; sem ela o `CardModifier`
			deixa o modificador de fora, que e o lado certo de errar -- mostrar o numero
			sem o bonus e melhor do que prometer um bonus que o servidor nao esta dando.
		]]
		BaseHealthRatio = base and base:GetHealthRatio() or nil,
	}
end

--[[ OS ANEIS NO CHAO ]]

--[=[
	Onde os aneis moram no mundo: uma pasta propria no Workspace.

	Nao na `workspace.CurrentCamera`, que e onde o resto dos desenhos de tela deste
	jogo mora (o circulo de alcance, a linha pontilhada, a mina no ar). Aqueles vivem
	segundos; o anel de um cajado vive o round inteiro, e a Camera nao e um lugar
	seguro para isso -- ela e recriada em algumas situacoes e leva os filhos junto.

	A pasta e local, e nao replicada: cada cliente desenha os seus a partir da lista
	que o servidor manda. Ela nasce na primeira carta de area usada na partida.
]=]
function CardModifierController:_ringContainer() : Instance
	local existing = workspace:FindFirstChild(RINGS.Container)
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = RINGS.Container
	folder.Parent = workspace

	return folder
end

--[=[
	A pasta dos aneis de chao, achada uma vez.

	`false` e "ja procurei e nao achei": sem isso a busca (e o aviso) se repetiriam a
	cada carta usada.
]=]
function CardModifierController:_ringFolder() : Instance?
	if self.RingFolder ~= nil then
		return self.RingFolder or nil
	end

	local current : Instance? = Assets
	for _, name in RINGS.Path do
		current = current and current:FindFirstChild(name)
	end

	if not current then
		warn(`[CardModifierController]: nao achei Assets.{table.concat(RINGS.Path, ".")}; as cartas de area ficam sem anel no chao.`)
		self.RingFolder = false
		return nil
	end

	self.RingFolder = current
	return current
end

--[=[
	O Model do anel desta carta, ou o padrao quando ela nao declara um.

	Carta de area nova aparece no chao sem arte propria, e com um aviso so no Studio:
	um anel generico e melhor do que zona nenhuma desenhada, porque a zona existe do
	mesmo jeito e mexe nas torres que estiverem dentro dela.
]=]
function CardModifierController:_ringTemplate(cardId : any) : Model?
	local folder = self:_ringFolder()
	if not folder then return nil end

	local definition = RoundCardConfig.Get(cardId)
	local name = definition and definition.Ring or RINGS.Default

	local template = folder:FindFirstChild(name) or folder:FindFirstChild(RINGS.Default)

	if not template or not template:IsA("Model") then
		if not self.WarnedRings[name] then
			self.WarnedRings[name] = true
			warn(`[CardModifierController]: nao achei o anel '{name}' (nem o '{RINGS.Default}') em Assets.{table.concat(RINGS.Path, ".")}.`)
		end

		return nil
	end

	return template
end

--[=[
	A escala que poe este anel com o raio pedido.

	A regua e a Part `<nome>_Ring` de dentro do Model, e nao a caixa dele: um Model de
	VFX tem emissor e attachment espalhados, e medir a caixa inteira faria o anel
	encolher so porque alguem arrastou uma faisca para fora dele.
]=]
function CardModifierController:_ringScale(ring : Model, radius : number) : number
	local part = ring:FindFirstChild(ring.Name .. RINGS.PartSuffix, true)

	if not part or not part:IsA("BasePart") or part.Size.X <= 0 then
		if not self.WarnedRings[ring.Name] then
			self.WarnedRings[ring.Name] = true
			warn(`[CardModifierController]: o anel '{ring.Name}' nao tem a Part '{ring.Name}{RINGS.PartSuffix}'; o raio dele vai sair errado.`)
		end

		return ring:GetScale()
	end

	return ring:GetScale() * (radius * 2) / part.Size.X
end

--[=[
	Desenha um anel no chao para cada zona da lista.

	Os aneis sao refeitos por inteiro a cada lista nova, e nao reconciliados um a um.
	Sao poucos (uma partida cheia tem dois ou tres) e a lista chega inteira do
	servidor: casar zona por zona daria um bookkeeping proprio para poupar um clone
	que ninguem sente.

	O anel cresce do nada ate o tamanho dele. E o mesmo gesto do circulo de alcance da
	unidade selecionada, e serve para o mesmo: dizer que aquele desenho **acabou de**
	aparecer, em vez de sempre ter estado ali.

	O raio e o mesmo que o jogador viu na mira -- ele vem do `Zone.Radius` que o
	servidor guardou, que e o `Params.Radius` da carta. O anel que ele mirou e o anel
	que ficou.
]=]
function CardModifierController:_drawZones()
	self.ZoneMaid:DoCleaning()

	for _, modifier in self.Modifiers do
		local zone = modifier.Zone
		if not zone or not zone.Position then continue end

		--[[
			Uma zona por carta usada, e nao por registro: os cajados criam dois
			registros (quem eles favorecem e quem paga o pedagio) na **mesma** zona, e
			dois aneis exatamente sobrepostos so pintariam a borda duas vezes.
		]]
		if self.DrawnZones[modifier.Uid] then continue end
		self.DrawnZones[modifier.Uid] = true

		local template = self:_ringTemplate(modifier.Card)
		if not template then continue end

		local ring = template:Clone()

		--[[
			O anel e cenario, e precisa de tres coisas antes de entrar no mundo.

			**`Anchored` e a que nao pode faltar.** Os Models de `Assets.VFX.Rings` vem
			do Studio com as Parts soltas, e o Workspace simula tudo que esta dentro
			dele -- inclusive o que esta pendurado na Camera. Uma Part solta cai, passa
			do `FallenPartsDestroyHeight` uns dois segundos depois e a **Roblox destroi
			o anel**: ele aparecia no lugar certo e sumia sozinho, sem erro nenhum no
			log. Ancorar aqui, e nao no asset, e o que faz um anel novo desenhado por
			outra pessoa nao trazer o problema de volta.

			As outras duas sao sobre nao atrapalhar: ele nao pode comer o raio que
			procura o chao debaixo do cursor -- senao mirar a proxima carta em cima
			dele acertaria o proprio anel -- nem empurrar nada.
		]]
		for _, descendant in ring:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
			end
		end

		local scale = self:_ringScale(ring, zone.Radius or 0)
		local center = CFrame.new(zone.Position)

		ring:ScaleTo(0.001)
		ring:PivotTo(center)
		ring.Parent = self:_ringContainer()

		self.ZoneMaid:GiveTask(ring)

		local grow = Instance.new("NumberValue")
		grow.Value = 0.001
		grow.Changed:Connect(function(value)
			if ring.Parent then
				ring:ScaleTo(value)
			end
		end)

		local tween = TweenService:Create(
			grow,
			TweenInfo.new(RINGS.Grow, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Value = scale }
		)

		self.ZoneMaid:GiveTask(function()
			tween:Cancel()
			grow:Destroy()
		end)

		tween:Play()
	end
end

--[[ API ]]

--[=[
	O multiplicador de carta de uma estatistica para uma unidade, do jeito que o
	servidor o calcula.

	`unitId` pode ser nil -- uma unidade que ainda nao replicou, o fantasma do
	posicionamento --, e nesse caso so os modificadores que nao dependem de qual
	unidade e (classe, zona, condicao) valem. E o que faz o fantasma ja nascer com o
	alcance que a torre vai ter quando for colocada dentro do anel.
]=]
function CardModifierController:Multiplier(stat : string, unitName : string?, position : Vector3?, unitId : string?) : number
	if #self.Modifiers == 0 then return 1 end

	local unit = { UnitId = unitId, UnitName = unitName, Position = position }

	return CardModifier.Multiplier(self.Modifiers, stat, unit, self:GetWorld())
end

--[=[
	Uma area **deste** jogador que um anel de raio `radius` em `position` encostaria,
	ou `nil` se o lugar esta livre.

	E a mesma conta do `CardModifierService:FindZoneOverlap`, de proposito: o servidor
	recusa o uso pela dele, e a mira pinta de vermelho pela daqui. As duas leem a mesma
	lista replicada, entao o que o jogador ve antes de clicar e o que o servidor vai
	responder -- se elas divergissem, existiria um lugar verde onde o clique nao vale.

	Aqui nao ha poda de prazo: quem vence a zona e o servidor, e a lista chega refeita
	a cada mudanca. Uma zona vencida no ultimo quadro pinta de vermelho por um instante
	a mais, e nunca o contrario -- o erro cai para o lado seguro.
]=]
function CardModifierController:FindZoneOverlap(position : Vector3, radius : number)
	if typeof(position) ~= "Vector3" or typeof(radius) ~= "number" then return nil end

	local userId = Players.LocalPlayer and Players.LocalPlayer.UserId

	for _, modifier in self.Modifiers do
		local zone = modifier.Zone
		if not zone or modifier.OwnerUserId ~= userId then continue end

		local delta = zone.Position - position
		local flat = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)

		if flat < (zone.Radius or 0) + radius then
			return modifier
		end
	end

	return nil
end

--[[ CICLO DE VIDA ]]

function CardModifierController:construct()
	Framework:Listen("RoundCardModifiers", function(list)
		self.Modifiers = if typeof(list) == "table" then list else {}

		table.clear(self.DrawnZones)
		self:_drawZones()

		--[=[
			O alcance mudou por baixo do jogador, e nem o circulo nem o card se
			redesenham sozinhos -- e a mesma dupla que a troca de clima ja refazia
			(ver o `WeatherChanged` no `UnitPlacementController`).
		]=]
		local placement = self.Controllers.UnitPlacementController
		if placement then
			placement:resizeSelectionRing()
		end

		local library = self.Controllers.UILibraryController
		if library then
			library:doComponent("ToggleTower", "refresh")
		end
	end)

	--[[
		O round recomecou: os aneis do round anterior nao podem continuar no chao. O
		servidor manda a lista vazia junto, mas o `RoundRestarted` chega primeiro e
		limpa a tela sem esperar a rede.
	]]
	Framework:Listen("RoundRestarted", function()
		self.Modifiers = {}
		table.clear(self.DrawnZones)
		self.ZoneMaid:DoCleaning()
	end)

end

function CardModifierController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	-- O que ja estava no campo quando este cliente carregou. No `start`, e nao no
	-- `construct`: o pedido so faz sentido depois de os `Listen` estarem de pe, e o
	-- identificador dele nasce no servidor (ver o README da raiz).
	Framework:Fire("RequestRoundCardModifiers")
end

function CardModifierController:init()
	self.ZoneMaid = Maid.new()

	-- Um anel por uso de carta. Ver `_drawZones`.
	self.DrawnZones = {}

	-- Aviso de anel faltando, uma vez por nome: a lista e redesenhada a cada carta
	-- usada, e sem isso um Model ausente entupiria o output.
	self.WarnedRings = {}

	self:construct()
end

return CardModifierController
