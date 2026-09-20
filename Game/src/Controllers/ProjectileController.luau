local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = Shared:WaitForChild("Assets")

local DEFAULT_SPEED = 60
local MAX_FLIGHT_TIME = 3
local ARRIVE_DISTANCE = 1

--[[
	Quanto o projetil que atravessa segue voando, em studs, quando o
	`Projectile.PierceRange` da unidade nao diz outra coisa.

	Ele nao para no alvo -- e o que "atravessar" quer dizer --, entao precisa de um
	fim proprio. Vale folgado mais que o alcance de qualquer unidade da tabela: a
	flecha sumindo no ar depois de passar pelo ultimo inimigo e o desenho certo, e
	quem decide quem levou dano e o servidor, que corta no alcance de verdade.
]]
local PIERCE_DISTANCE = 24

--- O valor de `Projectile.Subtype` que faz o projetil atravessar.
local PIERCING = "Piercing"

--[[
	O attachment que um projetil pode trazer com o estouro dele dentro.

	E opcional e e do **asset**, nao de config: o projetil que tiver um attachment
	com este nome estoura ao chegar, e o que nao tiver some como sempre. O
	`PyreProjectile` tem dois attachments -- o `Ball`, com os emitters ligados que
	fazem o rastro, e o `Explosion`, com os desligados que so saem no impacto.

	Emitter desligado nao aparece sozinho: quem o faz aparecer e o `Emit`, e por
	isso o artista pode deixar os dois grupos pendurados na mesma part sem um
	atrapalhar o outro.
]]
local IMPACT_ATTACHMENT = "Explosion"

--- Quantas particulas por emitter quando o asset nao disser. O mesmo do `VFXController`.
local DEFAULT_EMIT_COUNT = 25

local ProjectileController = {}
ProjectileController.Library = {}

local function getRoot(instance)
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
	end
	return instance
end

local function setCFrame(instance, cf)
	if instance:IsA("Model") then
		if not instance.PrimaryPart then
			local part = instance:FindFirstChildWhichIsA("BasePart")
			if part then instance.PrimaryPart = part end
		end
		instance:PivotTo(cf)
	else
		instance.CFrame = cf
	end
end

--[=[
	Estoura o projetil onde ele parou, em vez de o apagar na hora.

	Tres coisas ao mesmo tempo: o rastro para de emitir, o estouro sai, e a casca
	some deixando so as particulas no ar. Sem apagar o rastro o projetil continuaria
	cuspindo fogo parado no lugar pelo tempo do estouro; sem sumir a casca ficaria a
	bolinha pairando no meio da explosao.

	Devolve por quanto tempo as particulas ainda vivem, para quem chamou saber
	quando pode destruir de verdade -- destruir junto com o `Emit` mata as
	particulas antes de elas nascerem. Devolve `nil` quando o projetil nao tem
	estouro nenhum, e ai o caminho e o de sempre.

	O prazo e de **tela**, e nao de partida: `ParticleEmitter` nao conhece o
	`GameClock`, entao as particulas duram os mesmos 2 segundos reais no 1x e no 2x
	e o `task.delay` e que acerta com elas.
]=]
local function burstImpact(instance) : number?
	local burst = instance:FindFirstChild(IMPACT_ATTACHMENT, true)
	if not (burst and burst:IsA("Attachment")) then return nil end

	local linger = 0

	for _, descendant in instance:GetDescendants() do
		local inBurst = descendant:IsDescendantOf(burst)

		if descendant:IsA("ParticleEmitter") then
			if inBurst then
				descendant:Emit(descendant:GetAttribute("EmitCount")
					or burst:GetAttribute("EmitCount")
					or DEFAULT_EMIT_COUNT)
				linger = math.max(linger, descendant.Lifetime.Max)
			else
				descendant.Enabled = false
			end
		elseif descendant:IsA("Light") and not inBurst then
			descendant.Enabled = false
		end
	end

	--[[
		A casca sai de cena, e nao o attachment: as particulas ja emitidas vivem
		presas a ele, e destruir a part agora levaria o estouro junto.

		`Anchored` porque o laco de voo acabou de soltar o projetil -- o template vem
		com `Anchored = false` e `CanCollide = true`, e sem isto a bolinha invisivel
		cairia (e esbarraria) durante os dois segundos do estouro.
	]]
	local function hide(part)
		part.Transparency = 1
		part.CanCollide = false
		part.Anchored = true
	end

	if instance:IsA("BasePart") then
		hide(instance)
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			hide(descendant)
		end
	end

	return linger
end

--[=[
	Tira o projetil de cena: com estouro, ele fica ate as particulas morrerem; sem
	estouro, some agora.
]=]
local function retire(instance)
	local linger = burstImpact(instance)
	if not linger then
		instance:Destroy()
		return
	end

	task.delay(linger, function()
		if instance and instance.Parent then
			instance:Destroy()
		end
	end)
end

local function targetPosition(targetModel, fallback)
	if targetModel and targetModel.Parent then
		local root = getRoot(targetModel)
		if root then
			return root.Position
		end
		return targetModel:GetPivot().Position
	end
	return fallback
end

--[=[
	O voo de quem atravessa: reta, sem perseguir, e sem parar no alvo.

	A diferenca para o tiro comum nao e so o fim. O projetil comum **persegue** --
	ele recalcula o alvo a cada quadro e curva atras dele --, e uma flecha que
	atravessa nao pode fazer isso: a direcao e congelada no disparo, na mira que a
	unidade tinha, senao ela curvaria para o primeiro inimigo em vez de riscar a
	linha por onde os outros vao levar dano.

	O `onArrive` sai quando ela **passa** por onde o alvo estava, e nao quando ela
	morre: e ali que o efeito de acerto pertence. Depois disso ela segue mais um
	tanto e some sozinha.

	Quem leva dano nao se decide aqui. O servidor ja resolveu isso no
	`UnitService:executeAttack`, na mesma linha e com o alcance de verdade da
	unidade; daqui sai so o desenho.
]=]
function ProjectileController:_flyThrough(template, startPos, aimPos, config, finish)
	local heading = aimPos - startPos
	if heading.Magnitude < 1e-3 then
		finish(aimPos)
		return
	end

	local direction = heading.Unit
	local speed = config.Speed or DEFAULT_SPEED
	local maxDistance = config.PierceRange or PIERCE_DISTANCE
	local impactAt = heading.Magnitude

	local projectile = template:Clone()
	local pos = startPos
	setCFrame(projectile, CFrame.lookAt(pos, pos + direction))
	projectile.Parent = Workspace

	local travelled = 0
	local elapsed = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt

		local step = speed * dt
		travelled += step
		pos = pos + direction * step
		setCFrame(projectile, CFrame.lookAt(pos, pos + direction))

		if travelled >= impactAt then
			-- O `finish` so passa a primeira vez; as outras chamadas nao fazem nada.
			finish(pos)
		end

		if travelled >= maxDistance or elapsed >= MAX_FLIGHT_TIME then
			conn:Disconnect()
			projectile:Destroy()
			finish(pos)
		end
	end)
end

function ProjectileController:Fire(startPos, targetModel, config, onArrive, fallbackPos)
	config = config or {}

	local fired = false
	local function finish(impactPos)
		if fired then return end
		fired = true
		if onArrive then onArrive(impactPos) end
	end

	local template = self.Library[config.Asset]
	if not template or not startPos then
		finish(fallbackPos or startPos)
		return
	end

	local speed = config.Speed or DEFAULT_SPEED

	local lastTarget = targetPosition(targetModel, fallbackPos or startPos)

	if config.Subtype == PIERCING then
		self:_flyThrough(template, startPos, lastTarget, config, finish)
		return
	end

	local projectile = template:Clone()

	local pos = startPos
	setCFrame(projectile, CFrame.lookAt(pos, lastTarget))
	projectile.Parent = Workspace

	local elapsed = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt

		local goal
		if targetModel and targetModel.Parent then
			goal = targetPosition(targetModel, lastTarget)
		else
			goal = fallbackPos or lastTarget
		end
		lastTarget = goal

		local toGoal = goal - pos
		local distance = toGoal.Magnitude
		local step = speed * dt

		--[[
			Chegar e bater; estourar o prazo e desistir. Sao coisas diferentes, e so a
			primeira merece o estouro -- um projetil que passou 3 segundos no ar sem
			alcancar ninguem nao explodiu em cima de nada.
		]]
		local arrived = distance <= math.max(step, ARRIVE_DISTANCE)

		if arrived or elapsed >= MAX_FLIGHT_TIME then
			conn:Disconnect()
			if projectile then
				if arrived then
					retire(projectile)
				else
					projectile:Destroy()
				end
			end
			finish(goal)
			return
		end

		local direction = toGoal.Unit
		pos = pos + direction * step
		setCFrame(projectile, CFrame.lookAt(pos, pos + direction))
	end)
end

function ProjectileController:buildLibrary()
	local folder = Assets:FindFirstChild("Projectiles")
	if not folder then return end
	for _, asset in folder:GetChildren() do
		self.Library[asset.Name] = asset
	end
end

function ProjectileController:construct()
	self:buildLibrary()
end

function ProjectileController:start()
end

function ProjectileController:init()
	self:construct()
end

return ProjectileController
