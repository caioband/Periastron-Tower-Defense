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

		if distance <= math.max(step, ARRIVE_DISTANCE) or elapsed >= MAX_FLIGHT_TIME then
			conn:Disconnect()
			if projectile then projectile:Destroy() end
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
