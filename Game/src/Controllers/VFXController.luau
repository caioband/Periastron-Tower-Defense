local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")

local SharedConfig = require(Configs.SharedConfig)

--[[
	Modulo de VFX de terceiros (ReplicatedStorage.vfx). Ele mesmo se recusa a rodar
	fora do cliente, e e quem sabe montar o raio a partir dos atributos do asset.
]]
local VFX = require(ReplicatedStorage:WaitForChild("vfx"))

local Me = require(Vendor.Me)
local Framework = Me.new()

local ThunderConfig = SharedConfig.WeatherConfig.Thunder

local DEFAULT_LIFETIME = 2
local DEFAULT_EMIT_COUNT = 25

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
