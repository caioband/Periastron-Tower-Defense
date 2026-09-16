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

-- Os estados desenhados num modelo inteiro (`playModelStatus`): o congelamento --
-- do Frostione nos inimigos e do clima nas unidades -- e a queimadura do Pyre. O
-- asset em `Assets.VFX`, o nome do Highlight dele depois de mudar para o modelo, e
-- a faxina de quando o modulo `vfx` nao souber dizer quanto as particulas duram.
local ICED_VFX_NAME = "IcedVFX"
local ICED_HIGHLIGHT_NAME = "IcedHighlight"
local BURNING_VFX_NAME = "BurningVFX"
local BURNING_HIGHLIGHT_NAME = "BurningHighlight"
local STATUS_VFX_FALLBACK = 2

--[=[
	O impacto da ponta do raio do Electro, bem mais baixo que o do raio do clima.

	O asset e o mesmo (`LightningBeam`), e e no Attachment da **ponta** dele que o
	addon guarda o que acontece onde o raio bate: a tag `CraterVFX` com `Count = 40`
	de detritos, mais os atributos `CameraShake` e `ImpactFrames`. Autorado assim, ele
	e um raio caindo do ceu -- e e isso que o clima quer.

	O `Size` daqui e pouco mais da metade do autorado (1,8 contra 3 de comprimento), e
	nao um terco como na primeira versao: com detrito miudo demais a marca no chao
	sumia no meio da wave e o raio parecia nao ter encostado em nada.

	Numa corrente aquilo sai **por elo**: quatro pontas no mesmo quadro sao quatro
	tremores de camera, quatro impact frames e 160 detritos a cada golpe. O golpe de
	uma torre nao pode sequestrar a tela do jogador desse jeito, ainda mais um que se
	repete a partida inteira. A cratera fica, pequena: ela e o que marca no chao onde
	o raio encostou.

	O raio do trovao continua com tudo, e nao passa por aqui -- ele cai uma vez a cada
	cinco segundos e e um acontecimento da wave, nao um ataque.

	`Clear` **apaga** o atributo em vez de zera-lo porque e assim que o addon desliga:
	ele le `attrs.X` e sai fora quando nao acha nada (`if not attr then return end`).
	Um zero ali continuaria ligando o efeito, so que com numero zerado.
]=]
local CHAIN_IMPACT = {
	Attributes = {
		Count = 6,
		Radius = 3,
		Variance = 1,
		Size = Vector3.new(1.8, 0.7, 1.2),
	},

	Clear = { "CameraShake", "ImpactFrames" },
}

local VFXController = {
	Controllers = {
		UnitPlacementController = {},
		WeatherController = {},

		-- De onde saem os modelos dos inimigos, para o raio do Electro terminar em
		-- cada um deles. Ver `mobPoint`.
		MobController = {}
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

		-- O asset vai para dentro do inimigo, soldado nele, e estoura uma vez so. Ver
		-- `attachToMob`.
		if entry.Target == "MobRoot" then
			local mob = context.mobModel
			if mob and mob.Parent then
				self:EmitAttached(self:attachToMob(entry.Effect, mob, entry.WeldTo), entry.Duration)
			end
			continue
		end

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

--[=[
	Baixa o impacto da ponta de um raio: cratera menor, sem impact frame e sem tremor
	de camera. Ver o `CHAIN_IMPACT`.

	Mexe no **clone**, e nunca no asset -- o raio do clima sai do mesmo template e tem
	de continuar chegando inteiro.
]=]
local function tuneBeamImpact(tip : Instance, impact)
	for name, value in impact.Attributes do
		tip:SetAttribute(name, value)
	end

	for _, name in impact.Clear do
		tip:SetAttribute(name, nil)
	end
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
	ligados (o `FrozenVFX` vem assim). Dentro de uma unidade isso vira uma caixa
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

	E a metade da frente do `EmitAttached`, separada porque nem todo efeito nasce
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

--[=[
	O congelamento de clima na unidade que acabou de travar: o mesmo `IcedVFX` do
	congelamento do Frostione nos inimigos, pelo `playModelStatus` -- particulas
	soldadas no `Torso` e o Highlight dele na raiz do modelo da unidade.

	Nada aqui e escrito em cima do nome "Snow": o asset sai do `Freeze` do clima que
	o servidor mandou como causa do atordoamento. Clima sem `Freeze` (o raio) e
	atordoamento sem clima nenhum (o gimmick de mob) caem fora sozinhos, e ficam so
	com o realce amarelo que o `UnitPlacementController` desenha.

	`duration` e o que o servidor de fato aplicou, e nao o `Freeze.Duration` do
	config: o prazo maior manda em `UnitService:StunUnit`.
]=]
function VFXController:PlayFreeze(unitId : string, weatherName : string?, duration : number?)
	local effects = WeatherConfig.GetEffects(weatherName)
	local freeze = effects and effects.Freeze
	if not freeze or not freeze.Asset then return end

	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	self:playModelStatus(model, freeze.Asset, ICED_HIGHLIGHT_NAME, duration)
end

--[=[
	Apaga o congelamento de uma unidade antes da hora dele.

	E o Staff of Healing: ele tira o atordoamento no meio, e o desenho tem prazo
	proprio -- um `GameClock.Delay` que nasceu junto com ele e nao tem como saber que
	o congelamento acabou mais cedo. Sem isto a unidade voltaria a atacar ainda
	coberta de gelo.

	Os nomes saem do config: um clima novo com `Freeze` proprio entra nesta limpeza
	sem passar por aqui.
]=]
function VFXController:StopFreeze(unitId : string)
	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	for _, effects in WeatherConfig.Effects do
		local asset = effects.Freeze and effects.Freeze.Asset
		if asset then
			self:stopModelStatus(model, asset, ICED_HIGHLIGHT_NAME)
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

	`impact` e opcional e so o raio do Electro manda um (`CHAIN_IMPACT`): sem ele, a
	ponta chega com o que veio autorado no asset, que e o raio cheio do clima.
]=]
function VFXController:spawnBeam(from : Vector3, to : Vector3, impact : { [string] : any }?) : Attachment?
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

	-- Antes do emit, e no clone: o addon le os atributos da ponta na hora em que ela
	-- e emitida, entao mudar depois nao mudaria nada.
	if impact then
		tuneBeamImpact(tip, impact)
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

--[=[
	Meio do corpo de um inimigo, ou a posicao que o servidor mandou quando o modelo
	nao esta mais la.

	O par do `chainPoint`, que faz o mesmo com unidades -- e separado dele porque as
	duas coisas vivem em controllers diferentes: unidade e do
	`UnitPlacementController`, inimigo e do `MobController`.

	O modelo manda quando existe. O cliente simula o andar dos inimigos por conta
	propria, entao a posicao que veio no evento ja e de alguns quadros atras na hora
	em que o raio e desenhado -- em cima de um inimigo rapido isso e um arco terminando
	visivelmente atras dele.
]=]
function VFXController:mobPoint(mobId : string?, fallback : Vector3?) : Vector3?
	local mobs = self.Controllers.MobController
	local model = mobId and mobs and mobs.SpawnedMobs and mobs.SpawnedMobs[mobId]

	if model and model.Parent then
		return model:GetPivot().Position
	end

	return if typeof(fallback) == "Vector3" then fallback else nil
end

--[=[
	O raio do Electro: um arco da unidade ate o primeiro inimigo, e dai de um para o
	seguinte na ordem em que a corrente saltou.

	O asset e o mesmo do raio do clima (`ThunderConfig.Asset`, pelo `spawnBeam`) --
	e o mesmo addon desenhando a mesma coisa, e por isso o raio do trovao e o da
	unidade se parecem de proposito.

	Quem escolheu os alvos foi o servidor, no instante do marcador `Hit`
	(`UnitService:executeAttack`): daqui nao sai nenhuma decisao, so o desenho da
	corrente que ja cobrou dano.

	Inimigo que ja saiu da tela e nao mandou posicao nenhuma nao interrompe a
	corrente: o arco seguinte sai do ultimo ponto que deu para desenhar, em vez de o
	raio morrer no meio.
]=]
function VFXController:PlayChainLightning(arc)
	if typeof(arc) ~= "table" or typeof(arc.targets) ~= "table" then return end

	local from = self:chainPoint(arc.unitId, arc.origin)
	if not from then return end

	for _, target in arc.targets do
		local to = self:mobPoint(target.mobId, target.position)
		if not to then continue end

		self:spawnBeam(from, to, CHAIN_IMPACT)
		from = to
	end
end

-- As tags com que o modulo `vfx` liga e desliga um asset sozinho. Ver `attachToMob`.
local AUTO_VFX_TAGS = { "EnabledVFX", "SequencedVFX" }

--[=[
	Pendura um asset de `Assets.VFX` no `HumanoidRootPart` de um inimigo, soldado,
	e devolve o clone.

	O par do `attachVFX`, que faz o mesmo em unidades -- e separado dele por duas
	diferencas:

	**Seguir quem anda.** Unidade fica parada, inimigo nao. A Part do asset sai da
	ancora e e soldada em `weldTo` (o proprio root quando nao vier nome), e o
	`PivotTo` com que o `MobController` move o inimigo leva ela junto.

	**Tirar as tags do modulo `vfx`.** O `IcedVFX` vem com `EnabledVFX`, e o
	Highlight dele com `SequencedVFX`: o modulo liga e desliga quem tem essas tags
	por conta propria, um quadro depois de entrar no Workspace, e passaria por cima
	de quem acendeu os emissores na mao. Elas saem **antes** de parentear -- tirar
	depois ainda dispararia o liga-desliga atrasado.
]=]
function VFXController:attachToMob(assetName : string?, mob : Model, weldTo : string?) : Instance?
	if not assetName then return nil end

	local root = mob:FindFirstChild(UNIT_ROOT_NAME) or mob.PrimaryPart
	if not root or not root:IsA("BasePart") then return nil end

	local template = self.Library[assetName]
	if not template then
		warn(`[VFXController]: nao achei o VFX "{assetName}" em Assets.VFX.`)
		return nil
	end

	local clone = template:Clone()

	for _, instance in { clone, unpack(clone:GetDescendants()) } do
		for _, tag in AUTO_VFX_TAGS do
			instance:RemoveTag(tag)
		end
		if instance:IsA("BasePart") then
			disarmPart(instance)
			instance.Massless = true
		end
	end

	if clone:IsA("BasePart") then
		clone.CFrame = root.CFrame

		local anchor = weldTo and mob:FindFirstChild(weldTo)
		if not anchor or not anchor:IsA("BasePart") then
			anchor = root
		end

		clone.Anchored = false

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = clone
		weld.Part1 = anchor
		weld.Parent = clone
	elseif clone:IsA("Attachment") then
		-- Attachment herda a posicao do pai; so o deslocamento de montagem sai.
		clone.CFrame = clone.CFrame.Rotation
	end

	clone.Parent = root

	return clone
end

--[=[
	Um estado que o servidor pos num modelo -- inimigo ou unidade: congelado,
	queimando --, desenhado pelos `duration` segundos que ele aplicou.

	O asset vai para o `HumanoidRootPart` soldado no `Torso`, com os emissores
	ligados, e o Highlight dele muda para a raiz do modelo, que e o que ele precisa
	para pintar o corpo inteiro. No fim os emissores desligam, o Highlight sai na
	hora e a Part so e destruida depois do rabo das ultimas particulas.

	O mesmo estado em cima de outro troca o anterior em vez de empilhar dois. O
	modelo sair no meio (inimigo morto, unidade vendida) limpa tudo sozinho: os dois
	vivem dentro dele. Estados diferentes convivem -- cada um tem o nome do asset e
	do Highlight dele.
]=]
function VFXController:playModelStatus(mob : Model, assetName : string, highlightName : string, duration : number?)
	duration = tonumber(duration) or 0
	if duration <= 0 or not mob.Parent then return end

	local root = mob:FindFirstChild(UNIT_ROOT_NAME) or mob.PrimaryPart
	local previous = root and root:FindFirstChild(assetName)
	if previous then
		previous:Destroy()
	end

	local previousHighlight = mob:FindFirstChild(highlightName)
	if previousHighlight then
		previousHighlight:Destroy()
	end

	local clone = self:attachToMob(assetName, mob, "Torso")
	if not clone then return end

	local highlight = clone:FindFirstChildWhichIsA("Highlight")
	if highlight then
		highlight.Name = highlightName
		highlight.Adornee = nil
		highlight.Parent = mob
	end

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
		end
	end

	-- Tempo de partida, como o `StunMob` do outro lado: no 3x o estado acaba antes
	-- em segundos reais, e o desenho tem que sair junto.
	GameClock.Delay(duration, function()
		if highlight and highlight.Parent then
			highlight:Destroy()
		end

		if not clone.Parent then return end

		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end

		VFX.destroyAfter(clone, VFX.maxLifetime(clone) or STATUS_VFX_FALLBACK)
	end)
end

--[=[
	Apaga um estado do `playModelStatus` antes da hora: o Highlight sai na hora, e a
	Part so depois do rabo das ultimas particulas, como no fim normal. O `Delay` que
	nasceu com o estado ainda dispara depois, e nao acha mais nada para mexer.
]=]
function VFXController:stopModelStatus(mob : Model, assetName : string, highlightName : string)
	local highlight = mob:FindFirstChild(highlightName)
	if highlight then
		highlight:Destroy()
	end

	local root = mob:FindFirstChild(UNIT_ROOT_NAME) or mob.PrimaryPart
	local clone = root and root:FindFirstChild(assetName)
	if not clone then return end

	-- Sai do nome para um estado novo logo em seguida nao destruir este no meio do
	-- rabo das particulas.
	clone.Name = assetName .. "Ending"

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		end
	end

	VFX.destroyAfter(clone, VFX.maxLifetime(clone) or STATUS_VFX_FALLBACK)
end

-- Um estado num inimigo, pelo id: o modelo mora no `MobController`.
function VFXController:playMobStatus(mobId : string, assetName : string, highlightName : string, duration : number?)
	local mobs = self.Controllers.MobController
	local mob = mobs and mobs.SpawnedMobs and mobs.SpawnedMobs[mobId]
	if not mob then return end

	self:playModelStatus(mob, assetName, highlightName, duration)
end

-- O congelamento do Frostione (`IcedVFX`). Ver `playModelStatus`.
function VFXController:PlayIced(mobId : string, duration : number?)
	self:playMobStatus(mobId, ICED_VFX_NAME, ICED_HIGHLIGHT_NAME, duration)
end

-- A queimadura do Pyre (`BurningVFX`). Ver `playModelStatus`.
function VFXController:PlayBurning(mobId : string, duration : number?)
	self:playMobStatus(mobId, BURNING_VFX_NAME, BURNING_HIGHLIGHT_NAME, duration)
end

-- Os dois ataques do Archmage que tem desenho: os assets em `Assets.VFX`, o
-- Attachment da explosao dentro do meteoro, e a faxina de reserva.
local METEOR_VFX_NAME = "Meteor"
local METEOR_EXPLOSION_NAME = "EXPLOSION"
local ARCHMAGE_LIGHTNING_NAME = "ArchmageLightning"
local ARCHMAGE_VFX_FALLBACK = 2

--[=[
	Um clone solto no mundo, pronto para ser movido na mao: sem as tags com que o
	modulo `vfx` liga e desliga um asset sozinho (ver `attachToMob`), e com toda
	Part ancorada e desarmada -- os assets vem do plugin colidindo, e um meteoro
	solido caindo empurraria unidade e apareceria no raycast do posicionamento.
]=]
local function looseVFXClone(template : Instance) : Instance
	local clone = template:Clone()

	for _, instance in { clone, unpack(clone:GetDescendants()) } do
		for _, tag in AUTO_VFX_TAGS do
			instance:RemoveTag(tag)
		end
		if instance:IsA("BasePart") then
			disarmPart(instance)
			instance.Anchored = true
		end
	end

	return clone
end

-- Liga ou desliga os efeitos continuos de um asset, pulando o que estiver dentro de
-- `skip` (a explosao do meteoro, que so estoura no fim).
local function setEffectsEnabled(root : Instance, enabled : boolean, skip : Instance?)
	for _, descendant in root:GetDescendants() do
		if skip and descendant:IsDescendantOf(skip) then continue end

		if descendant:IsA("ParticleEmitter") or descendant:IsA("Light") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = enabled
		end
	end
end

--[=[
	O meteoro do Archmage.

	Nasce `height` studs acima do `HumanoidRootPart` da unidade e cai em linha reta
	ate `aimPos` -- onde o alvo estava quando o ataque comecou, decidido pelo
	servidor --, em `fallTime` segundos de partida. Os emissores fora do Attachment
	`EXPLOSION` sao o rastro e ficam ligados durante a queda; no fim eles desligam, a
	pedra some e o `EXPLOSION` estoura uma vez.

	A queda e contada no relogio da partida, e nao num Tween: o servidor cobra o dano
	depois do mesmo `fallTime` no `GameClock`, e no 2x um Tween em tempo real
	explodiria depois de o inimigo ja ter levado o dano.
]=]
function VFXController:PlayMeteor(unitId : string, aimPos : Vector3, fallTime : number?, height : number?)
	if typeof(aimPos) ~= "Vector3" then return end

	local template = self.Library[METEOR_VFX_NAME]
	if not template then
		warn(`[VFXController]: nao achei o VFX "{METEOR_VFX_NAME}" em Assets.VFX.`)
		return
	end

	local model = self:resolveUnitModel(unitId)
	local root = model and (model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart)
	local origin = (root and root.Position or aimPos) + Vector3.new(0, tonumber(height) or 15, 0)

	local meteor = looseVFXClone(template)
	local explosion = meteor:FindFirstChild(METEOR_EXPLOSION_NAME)

	local heading = aimPos - origin
	local rotation = if heading.Magnitude > 1e-3 then CFrame.lookAt(Vector3.zero, heading) else CFrame.identity

	setClonePivot(meteor, CFrame.new(origin) * rotation)
	meteor.Parent = VFX.temp

	setEffectsEnabled(meteor, true, explosion)

	local duration = math.max(0.05, tonumber(fallTime) or 1)
	local elapsed = 0
	local connection
	connection = game:GetService("RunService").Heartbeat:Connect(function(dt)
		if not meteor.Parent then
			connection:Disconnect()
			return
		end

		elapsed += GameClock.Scaled(dt)
		local alpha = math.min(1, elapsed / duration)
		setClonePivot(meteor, CFrame.new(origin:Lerp(aimPos, alpha)) * rotation)

		if alpha < 1 then return end
		connection:Disconnect()

		setEffectsEnabled(meteor, false, explosion)
		if meteor:IsA("BasePart") then
			meteor.Transparency = 1
		end

		if explosion then
			VFX.emit(explosion)
		end

		VFX.destroyAfter(meteor, VFX.maxLifetime(meteor) or ARCHMAGE_VFX_FALLBACK)
	end)
end

--[=[
	O raio em linha do Archmage, ligado pelos `duration` segundos de dano.

	O asset e comprido no eixo X, com a ponta (o Attachment) no +X. Ele comeca no
	`HumanoidRootPart` da unidade e aponta, na horizontal, para `throughPos` -- a
	mesma mira com que o servidor traca a linha que leva dano. Fica no mundo, e nao
	dentro do modelo, para o giro suave da unidade nao entortar o desenho para fora
	da linha de verdade.

	A `SpotLight` vem com a tag do addon `Sequencer`, que nao roda em partida (falta
	capability); por isso as tags saem no clone e tudo e ligado e desligado na mao.
]=]
function VFXController:PlayArchmageLightning(unitId : string, throughPos : Vector3, duration : number?)
	if typeof(throughPos) ~= "Vector3" then return end

	local template = self.Library[ARCHMAGE_LIGHTNING_NAME]
	if not template then
		warn(`[VFXController]: nao achei o VFX "{ARCHMAGE_LIGHTNING_NAME}" em Assets.VFX.`)
		return
	end

	local model = self:resolveUnitModel(unitId)
	local root = model and (model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart)
	if not root then return end

	local start = root.Position
	local heading = Vector3.new(throughPos.X - start.X, 0, throughPos.Z - start.Z)
	if heading.Magnitude < 1e-3 then return end

	local direction = heading.Unit
	local beam = looseVFXClone(template)
	local length = if beam:IsA("BasePart") then beam.Size.X else 0

	setClonePivot(beam, CFrame.fromMatrix(start + direction * (length / 2), direction, Vector3.yAxis))
	beam.Parent = VFX.temp

	setEffectsEnabled(beam, true)

	GameClock.Delay(math.max(0, tonumber(duration) or 0), function()
		if not beam.Parent then return end

		setEffectsEnabled(beam, false)
		VFX.destroyAfter(beam, VFX.maxLifetime(beam) or ARCHMAGE_VFX_FALLBACK)
	end)
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

	--[[
		O raio do Electro. O `MobController` escuta o mesmo evento para pintar os
		inimigos de amarelo -- aqui e so o arco, la e so o realce, e os dois chegam
		no mesmo quadro.
	]]
	Framework:Listen("ChainLightning", function(arc)
		self:PlayChainLightning(arc)
	end)

	-- O congelamento do Frostione: so o servidor sabe quando os acumulos fecharam a
	-- conta, entao o aviso vem dele (`MobService:ApplyFrost`).
	Framework:Listen("MobFrozen", function(mobId : string, duration : number)
		self:PlayIced(mobId, duration)
	end)

	-- A queimadura do Pyre: so o servidor sabe se o acerto acendeu fogo novo ou caiu
	-- em quem ja queimava (`MobService:ApplyBurn`).
	Framework:Listen("MobBurning", function(mobId : string, duration : number)
		self:PlayBurning(mobId, duration)
	end)

	-- Os ataques do Archmage que tem desenho. Quem decide a mira e o tempo e o
	-- servidor (`UnitService:executeCombo`); daqui sai so o desenho.
	Framework:Listen("ArchmageMeteor", function(unitId : string, aimPos : Vector3, fallTime : number, height : number)
		self:PlayMeteor(unitId, aimPos, fallTime, height)
	end)

	Framework:Listen("ArchmageLightning", function(unitId : string, throughPos : Vector3, duration : number)
		self:PlayArchmageLightning(unitId, throughPos, duration)
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
