local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

--[[
	Modulo de VFX de terceiros (ReplicatedStorage.vfx). Ele mesmo se recusa a rodar
	fora do cliente, e e quem sabe montar o raio a partir dos atributos do asset.
]]
local VFX = require(ReplicatedStorage:WaitForChild("vfx"))

local Me = require(Vendor.Me)
local Framework = Me.new()

local WeatherConfig = SharedConfig.WeatherConfig
local ThunderConfig = WeatherConfig.Thunder
local RoundCardConfig = SharedConfig.RoundCardConfig

local DEFAULT_LIFETIME = 2
local DEFAULT_EMIT_COUNT = 25

-- O dinheirinho da aura do Entrepreneur: o asset em `Assets.VFX` e a Part da
-- unidade onde ele e pendurado.
local MONEY_VFX_NAME = "MoneyEntrepreneur"
local UNIT_ROOT_NAME = "HumanoidRootPart"

-- Prazo de faxina de quando o proprio modulo nao souber dizer quanto o efeito
-- dura (asset sem particula, ou com `EmitDuration` infinito).
local MONEY_VFX_FALLBACK = 3
local FREEZE_VFX_FALLBACK = 2
local FREEZE_AURA_FALLBACK = 2

local VFXController = {
	Controllers = {
		UnitPlacementController = {},
		WeatherController = {}
	}
}
VFXController.Library = {}

local function resolveBaseCFrame(target, offset)
	if typeof(target) == "CFrame" then
		return target * CFrame.new(offset), nil
	end
	if typeof(target) == "Vector3" then
		return CFrame.new(target + offset), nil
	end
	if typeof(target) == "Instance" then
		if target:IsA("Model") then
			return target:GetPivot() * CFrame.new(offset), target
		elseif target:IsA("BasePart") then
			return target.CFrame * CFrame.new(offset), target
		end
	end
	return nil, nil
end

local function setClonePivot(clone, cf)
	if clone:IsA("Model") then
		if not clone.PrimaryPart then
			local part = clone:FindFirstChildWhichIsA("BasePart")
			if part then clone.PrimaryPart = part end
		end
		clone:PivotTo(cf)
	elseif clone:IsA("BasePart") then
		clone.CFrame = cf
	end
end

local function getCloneRoot(clone)
	if clone:IsA("Model") then
		return clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	end
	return clone
end

local function getModelRoot(model)
	return model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
end

function VFXController:Play(effectName, target, options)
	options = options or {}
	local template = self.Library[effectName]
	if not template then return end

	local offset = options.Offset or Vector3.new(0, 0, 0)
	local baseCF, targetModel = resolveBaseCFrame(target, offset)
	if not baseCF then return end

	local clone = template:Clone()
	setClonePivot(clone, baseCF)
	clone.Parent = Workspace

	if options.Attach and (typeof(target) == "Instance" and target:IsA("Model")) then
		local targetRoot = getModelRoot(target)
		local cloneRoot = getCloneRoot(clone)
		if targetRoot and cloneRoot then
			cloneRoot.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = cloneRoot
			weld.Part1 = targetRoot
			weld.Parent = cloneRoot
		end
	end

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			local count = options.EmitCount or descendant:GetAttribute("EmitCount") or DEFAULT_EMIT_COUNT
			descendant:Emit(count)
		elseif descendant:IsA("Sound") then
			descendant:Play()
		elseif descendant:IsA("Light") then
			descendant.Enabled = true
		end
	end

	local lifetime = options.Duration or clone:GetAttribute("Lifetime") or DEFAULT_LIFETIME
	task.delay(lifetime, function()
		if clone and clone.Parent then
			clone:Destroy()
		end
	end)

	return clone
end

function VFXController:Trigger(unitName, eventName, context)
	if not unitName then return end
	context = context or {}

	local config = SharedConfig.UnitVFXConfig and SharedConfig.UnitVFXConfig[unitName]
	if not config then return end

	for _, entry in config do
		if entry.Event ~= eventName then continue end

		local target
		if entry.Target == "Unit" then
			target = context.unitModel
			if not target and context.unitId then
				target = self:resolveUnitModel(context.unitId)
			end
		elseif entry.Target == "Mob" then
			if context.mobModel and context.mobModel.Parent then
				target = context.mobModel
			else
				target = context.position
			end
		end

		if not target then continue end

		self:Play(entry.Effect, target, entry)
	end
end

--[=[
	O dinheiro saindo da unidade que acabou de render a mais dentro da aura de um
	Entrepreneur. Quem manda e o `UnitService`, no servidor -- a caixa e dele, e
	assim todo mundo ve o efeito na mesma unidade.

	O asset e um Attachment, entao ele mora dentro de uma BasePart: a
	`HumanoidRootPart` da unidade. E isso que faz o efeito acompanhar o modelo sem
	weld nenhum, ao contrario do `Play`, que solta o clone no Workspace.

	O emit e do modulo `vfx`: os `EmitCount`/`EmitDelay` vem autorados no
	ParticleEmitter do asset e e ele quem sabe le-los. A faxina tambem -- sem prazo
	explicito, o modulo tira do maior tempo de vida das particulas do proprio
	asset, entao mexer no emitter no Studio nao deixa lixo para tras.
]=]
function VFXController:PlayAuraBonus(unitId : string)
	local template = self.Library[MONEY_VFX_NAME]
	if not template then
		warn(`[VFXController]: nao achei o VFX "{MONEY_VFX_NAME}" em Assets.VFX.`)
		return
	end

	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	local root = model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart
	if not root or not root:IsA("BasePart") then return end

	local clone = template:Clone()
	clone.Parent = root

	VFX.emit(clone)
	VFX.destroyAfter(clone, VFX.maxLifetime(clone) or MONEY_VFX_FALLBACK)
end

local function disarmPart(part : BasePart)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

--[=[
	Pendura um asset de VFX dentro da `HumanoidRootPart` da unidade, pronto para
	tocar. Devolve o clone.

	Duas coisas que parentear sozinho nao resolve:

	**Posicionar.** Part filha de Part nao herda posicao — a do asset e a de quando
	ele foi autorado, do outro lado do mapa. O `PlayAuraBonus` nao precisa disto
	porque o asset dele e um Attachment, que herda.

	**Desarmar.** Os assets vem do plugin com `CanCollide`, `CanQuery` e `CanTouch`
	ligados (o `FrozenAuraVFX` vem assim). Dentro de uma unidade isso vira uma caixa
	invisivel que empurra quem passa e, pior, aparece nos `GetPartsInPart` do
	posicionamento — recusando um lugar vazio para todo mundo que tentar construir
	do lado. Nao da para depender de o asset vir certo do Studio.
]=]
local function attachVFX(template : Instance, root : BasePart) : Instance
	local clone = template:Clone()
	clone.Parent = root

	if clone:IsA("BasePart") then
		clone.CFrame = root.CFrame
		disarmPart(clone)
	elseif clone:IsA("Attachment") then
		--[[
			**Zerar o deslocamento.** Attachment herda a posicao do pai, mas nao zera a
			propria: a que vem autorada e onde o asset estava no mapa quando o plugin o
			salvou. O `PlayerStopTime` veio com Y = 22,25 -- a altura do lugar onde ele
			foi montado --, e pendurado no jogador isso punha as particulas 22 studs
			acima da cabeca dele: o efeito tocava, so que fora da tela.

			A rotacao fica, que essa o autor escolhe de verdade (e dela sai a direcao
			das particulas); o deslocamento some, que e resto de montagem. O
			`MoneyEntrepreneur` nunca precisou disto so porque veio salvo em 0, 0, 0.
		]]
		clone.CFrame = clone.CFrame.Rotation
	end

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			disarmPart(descendant)
		end
	end

	return clone
end

--[=[
	Pendura um asset de `Assets.VFX` numa Part e devolve o clone, **sem estourar**.

	E a metade da frente do `playFreezeBurst`, separada porque nem todo efeito nasce
	e estoura no mesmo instante: o da carta de round e pendurado no jogador na hora
	em que ela e usada e so estoura quando a animacao chega no marcador. Quem separa
	os dois fica devendo o `EmitAttached` -- ou a destruicao do clone, se o estouro
	nunca vier.
]=]
function VFXController:AttachAsset(assetName : string?, root : BasePart) : Instance?
	if not assetName then return nil end

	local template = self.Library[assetName]
	if not template then
		warn(`[VFXController]: nao achei o VFX "{assetName}" em Assets.VFX.`)
		return nil
	end

	return attachVFX(template, root)
end

--[=[
	O estouro de um asset ja pendurado.

	Um `emit` so, que e o que emissor de rajada pede. A faxina sai do maior tempo de
	vida das particulas do proprio asset -- `fallback` so entra quando o modulo nao
	sabe dizer (asset sem particula, ou com `EmitDuration` infinito) --, entao mexer
	no emitter no Studio nao deixa lixo para tras.
]=]
function VFXController:EmitAttached(clone : Instance?, fallback : number?)
	if not clone or not clone.Parent then return end

	VFX.emit(clone)
	VFX.destroyAfter(clone, VFX.maxLifetime(clone) or fallback or DEFAULT_LIFETIME)
end

--- O estouro do congelamento: o instante em que a unidade trava.
function VFXController:playFreezeBurst(assetName : string?, root : BasePart)
	self:EmitAttached(self:AttachAsset(assetName, root), FREEZE_VFX_FALLBACK)
end

--[=[
	A aura do congelamento: o estado, enquanto ele durar.

	`enable`/`disable` em vez de `emit` porque os emissores sao continuos e nascem
	desligados — quem manda neles e o `Enabled`, nao um numero de particulas. O
	`disable` e o desligar, e a destruicao vem so depois do rabo das ultimas
	particulas, senao a aura sumiria com um corte no fim de cada congelamento.

	`duration` e o que o servidor de fato aplicou, e nao o `Freeze.Duration` do
	config: o atordoamento pode ter vindo mais longo (o prazo maior manda, em
	`UnitService:StunUnit`), e a aura tem que acompanhar o que a unidade esta
	sentindo.

	O clone mantem o nome do asset, e e por ele que uma aura anterior e achada e
	desfeita: congelar de novo quem ja esta congelado troca a aura em vez de
	empilhar duas. Achar pelo nome tambem faz a unidade levar `Destroy` (venda,
	recomeco de round) limpar tudo sozinha, sem bookkeeping para desencontrar.
]=]
function VFXController:playFreezeAura(assetName : string?, root : BasePart, duration : number)
	if not assetName or duration <= 0 then return end

	local template = self.Library[assetName]
	if not template then
		warn(`[VFXController]: nao achei o VFX "{assetName}" em Assets.VFX.`)
		return
	end

	local previous = root:FindFirstChild(assetName)
	if previous then
		previous:Destroy()
	end

	local clone = attachVFX(template, root)

	VFX.enable(clone)

	-- A `duration` e o prazo do congelamento, que corre no relogio da partida: a
	-- aura tem que apagar quando a unidade descongela, e nao segundos depois.
	GameClock.Delay(duration, function()
		-- A unidade pode ter sido vendida, ou uma aura nova pode ter substituido
		-- esta: nos dois casos o clone ja saiu do Workspace e nao ha o que desligar.
		if not clone.Parent then return end

		VFX.disable(clone)
		VFX.destroyAfter(clone, VFX.maxLifetime(clone) or FREEZE_AURA_FALLBACK)
	end)
end

--[=[
	O congelamento da neve, na unidade que acabou de travar: o estouro e a aura.

	Nada aqui e escrito em cima do nome "Snow": o desenho sai do `Freeze` do clima
	que o servidor mandou como causa do atordoamento. Clima sem `Freeze` (o raio) e
	atordoamento sem clima nenhum (o gimmick de mob) caem fora sozinhos, e ficam so
	com o realce amarelo que o `UnitPlacementController` desenha.
]=]
function VFXController:PlayFreeze(unitId : string, weatherName : string?, duration : number?)
	local effects = WeatherConfig.GetEffects(weatherName)
	local freeze = effects and effects.Freeze
	if not freeze then return end

	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	local root = model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart
	if not root or not root:IsA("BasePart") then return end

	self:playFreezeBurst(freeze.Asset, root)
	self:playFreezeAura(freeze.Aura, root, duration or 0)
end

--[=[
	Apaga a aura de congelamento de uma unidade antes da hora dela.

	E o Staff of Healing: ele tira o atordoamento no meio, e a aura tem prazo proprio
	-- um `GameClock.Delay` que nasceu junto com ela e nao tem como saber que o
	congelamento acabou mais cedo. Sem isto a unidade voltaria a atacar envolvida numa
	nevasca que ja nao existe.

	As auras sao procuradas pelo nome do asset, que e o mesmo do clone (ver
	`playFreezeAura`), e os nomes saem do config: um clima novo com `Freeze` proprio
	entra nesta limpeza sem passar por aqui.

	O desligar e o mesmo do fim normal -- `disable` e destruicao so depois do rabo das
	ultimas particulas --, senao a aura sumiria com um corte.
]=]
function VFXController:StopFreeze(unitId : string)
	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	local root = model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart
	if not root then return end

	for _, effects in WeatherConfig.Effects do
		local aura = effects.Freeze and effects.Freeze.Aura
		local clone = aura and root:FindFirstChild(aura)

		if clone then
			VFX.disable(clone)
			VFX.destroyAfter(clone, VFX.maxLifetime(clone) or FREEZE_AURA_FALLBACK)
		end
	end
end

--[=[
	O estouro de uma carta de round de alvo unico encostando numa torre.

	Quem manda e o `CardShopService`, no servidor, e ele manda para **todos**: a carta
	e comprada por uma pessoa, mas o efeito e da sala, e o estouro tem que aparecer na
	mesma torre para todo mundo -- como o raio e o dinheiro da aura.

	O caminho e o mesmo do estouro do congelamento: o asset e pendurado dentro da
	`HumanoidRootPart` da torre (e por isso ele acompanha o modelo sem weld nenhum) e
	estourado de uma vez. Os `EmitCount` de cada emissor vem autorados no asset, e a
	faxina sai do maior tempo de vida das particulas dele -- mexer no emitter no
	Studio nao deixa lixo para tras.
]=]
function VFXController:PlayUnitApplied(unitId : string)
	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	local root = model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart
	if not root or not root:IsA("BasePart") then return end

	self:EmitAttached(self:AttachAsset(RoundCardConfig.AppliedVFX, root))
end

function VFXController:resolveUnitModel(unitId)
	local placement = self.Controllers.UnitPlacementController
	if not placement or not placement.createdClasses then return nil end
	for model, class in placement.createdClasses do
		if class and class.unitId == unitId then
			return model
		end
	end
	return nil
end

--[=[
	Pe da unidade: o centro da base da caixa dela.

	`GetPivot` devolveria o meio do corpo, e o raio tem que bater no chao.
]=]
local function footOf(model : Model) : Vector3
	local cf, size = model:GetBoundingBox()
	return Vector3.new(cf.Position.X, cf.Position.Y - size.Y / 2, cf.Position.Z)
end

--[=[
	De onde o raio desce.

	O certo e sair da propria nuvem, entao a altura vem da Part do clima que o
	`WeatherService` deixou em `workspace.Weather`. Sem clima ligado (o raio pode
	ser disparado por outra coisa um dia), cai para uma altura fixa acima do pe.
]=]
local function strikeOrigin(foot : Vector3) : Vector3
	local container = Workspace:FindFirstChild("Weather")
	local cloud = container and container:FindFirstChildWhichIsA("BasePart", true)

	local height = cloud and cloud.Position.Y or (foot.Y + ThunderConfig.StrikeHeight)
	return Vector3.new(foot.X, math.max(height, foot.Y + 1), foot.Z)
end

--[=[
	Um arco entre dois pontos do mundo. Devolve o Attachment da ponta, para quem
	chamou poder pendurar som nele.

	O asset e um Attachment (o comeco do raio) com um Attachment filho de letra
	unica (o fim). Posicionar os dois pelo `WorldPosition` e o suficiente: a posicao
	relativa do filho se recalcula sozinha, e como nenhum dos dois tem BasePart de
	ancestral, o mundo e o proprio referencial.

	Vale tanto para o raio que desce da nuvem quanto para o salto de uma unidade
	para outra — a unica diferenca entre os dois e onde ficam as pontas.
]=]
function VFXController:spawnBeam(from : Vector3, to : Vector3) : Attachment?
	local asset = self.Library[ThunderConfig.Asset]
	if not asset then
		warn(`[VFXController]: nao achei o VFX "{ThunderConfig.Asset}" em Assets.VFX.`)
		return nil
	end

	local beam = asset:Clone()
	local tip = beam:FindFirstChildWhichIsA("Attachment")
	if not tip then
		warn(`[VFXController]: "{ThunderConfig.Asset}" nao tem o Attachment filho que marca o fim do raio.`)
		beam:Destroy()
		return nil
	end

	-- Precisa estar no DataModel antes do emit: o modulo ignora o que esta solto.
	beam.Parent = VFX.temp

	beam.WorldPosition = from
	tip.WorldPosition = to

	--[[
		O asset vem com `EmitRepeat = -1`, que e como o plugin marca a previa em
		loop. Na pratica o `emit` trata -1 como "nao repete", mas depender disso e
		fragil — aqui o tiro unico e dito na mao, e o resto dos atributos autorados
		segue valendo.
	]]
	local attrs = beam:GetAttributes()
	attrs.EmitRepeat = 0

	VFX.emit(beam, attrs)

	-- O asset nao tem ParticleEmitter proprio (o addon cria os dele em runtime),
	-- entao o `maxLifetime` do modulo daria zero: a vida sai do `Duration` dele.
	local duration = VFX.num(beam:GetAttribute("Duration"), 5)
	VFX.destroyAfter(beam, duration + ThunderConfig.Cleanup)

	return tip
end

--[=[
	Raio caindo num ponto do mapa.

	`unitId` e opcional: vindo, o pe do modelo manda, porque o servidor so conhece o
	CFrame de posicionamento e o cliente mede a caixa real da unidade. A `position`
	e o alvo quando o raio cai no chao, e o fallback de quando a unidade ainda nao
	replicou.
]=]
function VFXController:PlayLightningStrike(position : Vector3, unitId : string?)
	if typeof(position) ~= "Vector3" then return end

	local foot = position
	if unitId then
		local model = self:resolveUnitModel(unitId)
		if model and model.Parent then
			foot = footOf(model)
		end
	end

	local tip = self:spawnBeam(strikeOrigin(foot), foot)
	if not tip then return end

	--[[
		Depois de posicionar, nunca antes: o Sound vira filho do Attachment da ponta,
		entao ele sai de onde o raio bateu. O clone do som morre junto com o beam, e o
		beam so e destruido bem depois de o estouro acabar.
	]]
	local weather = self.Controllers.WeatherController
	if weather then
		weather:PlayStrikeSound(tip)
	end
end

--[=[
	Meio do corpo da unidade, ou a posicao que o servidor mandou quando o modelo
	ainda nao chegou.
]=]
function VFXController:chainPoint(unitId : string?, fallback : Vector3?) : Vector3?
	if unitId then
		local model = self:resolveUnitModel(unitId)
		if model and model.Parent then
			return model:GetPivot().Position
		end
	end

	return if typeof(fallback) == "Vector3" then fallback else nil
end

--[=[
	O salto do raio de uma unidade para outra.

	Cada link vem do `ThunderService` com o par de unidades e o par de posicoes. O
	modelo manda quando ele ja replicou — a posicao do servidor e o CFrame de
	posicionamento, que fica no pe da unidade, e um arco horizontal saindo do chao
	parece um risco no piso. Sem modelo, a posicao serve de reserva.

	Sem estouro proprio de proposito: o do raio principal ja esta tocando, e um
	clone por arco encheria de trovao sobreposto uma coisa que dura meio segundo.
]=]
function VFXController:PlayLightningChain(links)
	if typeof(links) ~= "table" then return end

	for _, link in links do
		local from = self:chainPoint(link.fromId, link.from)
		local to = self:chainPoint(link.toId, link.to)

		if from and to then
			self:spawnBeam(from, to)
		end
	end
end

function VFXController:buildLibrary()
	local folder = Assets:FindFirstChild("VFX")
	if not folder then return end
	for _, effect in folder:GetChildren() do
		self.Library[effect.Name] = effect
	end
end

function VFXController:construct()
	self:buildLibrary()

	-- Quem sorteia o alvo e o compasso e o ThunderService, no servidor: assim todo
	-- mundo ve o mesmo raio na mesma unidade.
	Framework:Listen("LightningStrike", function(position : Vector3, unitId : string?)
		self:PlayLightningStrike(position, unitId)
	end)

	Framework:Listen("LightningChain", function(links)
		self:PlayLightningChain(links)
	end)

	Framework:Listen("AuraBonusVFX", function(unitId : string)
		self:PlayAuraBonus(unitId)
	end)

	Framework:Listen("RoundCardApplied", function(unitId : string)
		self:PlayUnitApplied(unitId)
	end)

	--[[
		O mesmo evento que acende o realce amarelo no `UnitPlacementController`. Os
		dois escutam de proposito: o realce vale para qualquer atordoamento, e o VFX
		so para o clima que tiver um.
	]]
	Framework:Listen("UnitStunned", function(unitId : string, duration : number, source : string?)
		self:PlayFreeze(unitId, source, duration)
	end)
end

function VFXController:start()
end

function VFXController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return VFXController
