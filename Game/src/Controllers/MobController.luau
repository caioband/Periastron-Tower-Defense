local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")

local Mobs = Assets:WaitForChild("Entities")

local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)
local MobConfig = require(Configs.SharedConfig.Mob)
local PathUtil = require(Shared.Util.PathUtil)
local PointerUtil = require(Shared.Util.PointerUtil)
local GameClock = require(Shared.Util.GameClock)

local Me = require(Vendor.Me)

local Framework = Me.new()

local HIT_FLASH_COLOR = Color3.fromRGB(255, 50, 50)
local HIT_FLASH_TIME = 0.12

--[[
	O realce de quem levou choque -- o raio do Electro.

	Mesmo amarelo, mesmas transparencias e mesma ideia do realce de unidade atordoada
	(`UnitPlacementController`): "este esta parado". Ele dura exatamente o tranco, que
	e curto -- e o que faz o jogador ver que a fila travou, em vez de so ver o raio
	passar e os inimigos continuarem andando.

	Nome proprio para nao brigar com o `HitFlash` vermelho, que pisca por cima dele a
	cada golpe e some sozinho.
]]
local SHOCK_HIGHLIGHT = "ShockHighlight"
local SHOCK_COLOR = Color3.fromRGB(255, 200, 60)

local SHAKE_DURATION = 0.6
local SHAKE_MAGNITUDE = 0.35
local SHAKE_FREQUENCY = 18

local function shakeScreen()
	local camera = workspace.CurrentCamera
	local elapsed = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= SHAKE_DURATION then
			conn:Disconnect()
			return
		end
		local decay = 1 - (elapsed / SHAKE_DURATION)
		local t = elapsed * SHAKE_FREQUENCY
		local offset = Vector3.new(
			math.sin(t * 1.7) * SHAKE_MAGNITUDE * decay,
			math.sin(t * 2.3) * SHAKE_MAGNITUDE * decay,
			0
		)
		camera.CFrame = camera.CFrame * CFrame.new(offset)
	end)
end

local function getAverageSpeed(mobName)
	local entity = MobConfig.Entities and MobConfig.Entities[mobName]
	if not entity then return nil end

	local startSpeed = (MobConfig.BaseSpeed or 0) * (entity.SpeedMultiplier or 1)
	local endScale = 1
	for _, gimmick in entity.Gimmicks or {} do
		if gimmick.Type == "PerTurnSpeedMultiplier" then
			endScale = math.max(0.1, 1 + ((gimmick.MaxStacks or 0) * (gimmick.Amount or 0)))
			break
		end
	end

	local endSpeed = startSpeed * endScale
	return (startSpeed + endSpeed) / 2
end

local healthBarTweens = {}

local function getHealthBillboard(mob)
	local attachment = mob:FindFirstChild("HealthAttachment")
	if not attachment then return nil end
	return attachment:FindFirstChildOfClass("BillboardGui")
end

local function updateHealthBar(mob, current, max, instant)
	-- A vida vai junto para um atributo do modelo: e por ela que o
	-- `TargetingController` acha o mob mais fraco ou mais forte do alcance sem ter
	-- de perguntar nada ao MobController. Fica antes das saidas abaixo de
	-- proposito -- mob sem barra de vida continua sendo alvo.
	mob:SetAttribute("Health", current)

	local attachment = mob:FindFirstChild("HealthAttachment")
	if not attachment then return end

	local billboard = attachment:FindFirstChildOfClass("BillboardGui")
	if not billboard then return end

	local outerImage = billboard:FindFirstChild("Bar")
	if not outerImage then return end

	local clip = outerImage:FindFirstChild("ScaleThis")
	if not clip then return end

	local ratio = math.clamp(current / math.max(max, 1), 0, 1)
	local targetSize = UDim2.new(ratio, 0, 1, 0)

	local existing = healthBarTweens[clip]
	if existing then
		existing:Cancel()
		healthBarTweens[clip] = nil
	end

	if instant then
		clip.Size = targetSize
	else
		local tween = TweenService:Create(clip, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = targetSize })
		healthBarTweens[clip] = tween
		tween.Completed:Connect(function()
			if healthBarTweens[clip] == tween then
				healthBarTweens[clip] = nil
			end
		end)
		tween:Play()
	end

	local textLabel = outerImage:FindFirstChildOfClass("TextLabel")
	if textLabel then
		textLabel.Text = math.ceil(math.max(current, 0)) .. "/" .. max
	end

	local mobNameLabel = billboard:FindFirstChild("MobName")
	local mobName = mob and mob.Name or ""

	if mobNameLabel then mobNameLabel.Text = mobName end
end


local function flashMob(mob)
	local existing = mob:FindFirstChild("HitFlash")
	if existing then
		existing:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "HitFlash"
	highlight.FillColor = HIT_FLASH_COLOR
	highlight.OutlineColor = HIT_FLASH_COLOR
	highlight.FillTransparency = 0.2
	highlight.OutlineTransparency = 1
	highlight.Parent = mob

	task.delay(HIT_FLASH_TIME, function()
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end)
end

--[=[
	Pinta um inimigo de amarelo enquanto o tranco do choque durar.

	Um realce por inimigo: um choque em cima de outro troca o realce e recomeca o
	prazo, em vez de empilhar dois Highlights brigando pelo mesmo modelo -- e e o
	mesmo que o `MobService:StunMob` faz com o tranco em si, onde o prazo maior manda.

	A espera corre no relogio da **partida**, como a do `StunMob` do outro lado: no 3x
	os 0,3s acabam em um decimo de segundo real, e o realce tem que apagar junto com
	eles, senao ele sobreviveria ao proprio motivo.
]=]
local function shockMob(mob, duration : number)
	local existing = mob:FindFirstChild(SHOCK_HIGHLIGHT)
	if existing then
		existing:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = SHOCK_HIGHLIGHT
	highlight.FillColor = SHOCK_COLOR
	highlight.OutlineColor = SHOCK_COLOR
	highlight.FillTransparency = 0.6
	highlight.OutlineTransparency = 0.2
	highlight.Parent = mob

	GameClock.Delay(duration, function()
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end)
end

local function spawnDamageNumber(mobOrPosition, damage)
	local rootPart = nil
	local worldPos = nil

	if typeof(mobOrPosition) == "Instance" then
		rootPart = mobOrPosition:FindFirstChild("HumanoidRootPart") or mobOrPosition.PrimaryPart
		if rootPart then
			worldPos = rootPart.Position
		end
	elseif typeof(mobOrPosition) == "Vector3" then
		worldPos = mobOrPosition
	end

	if not worldPos then return end

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 60, 0, 30)
	billboard.StudsOffset = Vector3.new(math.random(-10, 10) * 0.1, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0

	if rootPart then
		billboard.Adornee = rootPart
		billboard.Parent = rootPart
	else
		local anchor = Instance.new("Part")
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.1, 0.1, 0.1)
		anchor.Position = worldPos
		anchor.Parent = workspace
		billboard.Adornee = anchor
		billboard.Parent = anchor
		task.delay(2, function()
			if anchor and anchor.Parent then anchor:Destroy() end
		end)
	end

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = tostring(damage)
	label.TextColor3 = Color3.fromRGB(255, 60, 60)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.FontFace = Font.new("rbxassetid://12187371840", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
	label.Parent = billboard

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 2
	stroke.Parent = label

	local startOffset = billboard.StudsOffset
	local floatTarget = startOffset + Vector3.new(0, 2.5, 0)
	local elapsed = 0
	local duration = 0.8
	local WIGGLE_FREQ = 18
	local WIGGLE_AMP = 22

	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t = math.min(elapsed / duration, 1)
		local eased = 1 - (1 - t) ^ 2

		billboard.StudsOffset = startOffset:Lerp(floatTarget, eased)
		local decay = 1 - t
		label.Rotation = math.sin(elapsed * WIGGLE_FREQ) * WIGGLE_AMP * decay
		local alpha = math.clamp((t - 0.4) / 0.6, 0, 1)
		label.TextTransparency = alpha
		label.TextStrokeTransparency = alpha

		if t >= 1 then
			conn:Disconnect()
			billboard:Destroy()
		end
	end)
end

local MobController = {
	Controllers = {
		TargetingController = {},
		VFXController = {}
	}
}
MobController.SpawnedMobs = {}
MobController.MobHealth = {}
MobController.MobMovement = {}
MobController.MobLastPosition = {}

local function checkIsOnGrid(position, size)
	local gridParts = CollectionService:GetTagged("Grid")
	if #gridParts == 0 then
		return true
	end

	local cleanGridParts = {}
	for _, part in ipairs(gridParts) do
		if part:IsA("BasePart") and part:IsDescendantOf(workspace) then
			table.insert(cleanGridParts, part)
		end
	end

	if #cleanGridParts == 0 then
		return true
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = cleanGridParts

	local castCFrame = CFrame.new(position + Vector3.new(0, 5, 0))
	local castSize = Vector3.new(size.X * 0.8, 0.2, size.Z * 0.8)
	local rayDirection = Vector3.new(0, -15, 0)

	local result = workspace:Blockcast(castCFrame, castSize, rayDirection, raycastParams)
	return result ~= nil
end

--[=[
	Rotas do mapa atual, iguaizinhas as do servidor — os dois lados montam a
	partir dos mesmos nodes replicados, entao o indice sorteado la vale aqui.

	Antes o caminho era reconstruido a cada spawn de mob; agora e uma vez so por
	mapa, e o cache cai no restart do round.

	Yield: espera os nodes chegarem inteiros antes do primeiro build. Se nao
	chegarem, monta o que der mas nao cacheia — assim o proximo mob tenta de novo
	em vez de arrastar um caminho truncado pelo round todo.
]=]
function MobController:getRoutes()
	if not self.Routes then
		local nodesFolder = workspace.PathScriptable.Nodes
		local complete = PathUtil.WaitForNodes(nodesFolder)
		local routes = PathUtil.BuildRoutes(nodesFolder)

		if not complete then
			return routes
		end

		self.Routes = routes
	end
	return self.Routes
end

--[=[
	Os nodes do caminho com a distancia de cada um ate o primeiro, para a
	prioridade `Farthest` do `TargetingController`.

	Sai das mesmas rotas do movimento, que e o que faz cliente e servidor medirem
	o avanco do mob na mesma regua. Caminho incompleto nao e cacheado, pela mesma
	razao do `getRoutes`: o proximo pedido tenta de novo.
]=]
function MobController:getNodeDistances()
	if not self.NodeDistances then
		local nodeDistances = PathUtil.BuildNodeDistances(self:getRoutes())

		if not self.Routes then
			return nodeDistances
		end

		self.NodeDistances = nodeDistances
	end
	return self.NodeDistances
end

function MobController:createEntity(entityData)
	local mobName = entityData.Name or "CourageBearer"
	local speed = entityData.Speed or 6
	local mobId = entityData.Id

	local mobModel = Mobs:FindFirstChild(mobName) or Mobs.CourageBearer
	if not mobModel then mobModel = Mobs.EnemyRig end

	local mobClone = mobModel:Clone()
	mobClone:SetAttribute("MobID", mobId)

	self.SpawnedMobs[mobId] = mobClone

	for _, part in ipairs(mobClone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = part.Name == "HumanoidRootPart"
			part.CanCollide = false
		end
	end

	local humanoid = mobClone:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end

	local extentsCFrame, extentsSize = mobClone:GetBoundingBox()
	local localCenter = mobClone:GetPivot():ToObjectSpace(extentsCFrame)
	mobClone:PivotTo(mobClone:GetPivot() * localCenter)

	local HealthBarAttach = Assets.UI.HealthAttachment:Clone()
	HealthBarAttach.Parent = mobClone

	local healthBillboard = HealthBarAttach:FindFirstChildOfClass("BillboardGui")
	if healthBillboard then
		healthBillboard.Enabled = false
	end

	mobClone.Parent = workspace

	self.MobHealth[mobId] = { current = entityData.Health or entityData.MaxHealth or 100, max = entityData.MaxHealth or 100 }
	updateHealthBar(mobClone, self.MobHealth[mobId].current, self.MobHealth[mobId].max, true)

	-- A rota vem do servidor: com bifurcacao, cliente e servidor precisam andar
	-- exatamente pela mesma polilinha, senao as duas simulacoes divergem.
	local routes = self:getRoutes()
	local route = routes[entityData.Route or 1] or routes[1]
	local smooth = route.smooth
	local startPosition = smooth.points[1]

	self.Controllers.TargetingController:RegisterMob(mobClone)

	local _, currentSize = mobClone:GetBoundingBox()
	local currentPivot = mobClone:GetPivot()
	local bottomOffset = currentPivot.Position.Y - (currentSize.Y / 2)
	local targetHeight = startPosition.Y + (currentSize.Y / 2)
	local verticalAdjustment = targetHeight - bottomOffset

	--[[
		Quanto o centro do modelo esta acima do caminho. O `TargetingController`
		desconta isso antes de perguntar em que node o mob esta: o servidor mede a
		partir do ponto do caminho, e sem o desconto os dois escolheriam nodes
		diferentes perto da metade de cada trecho -- a torre olharia para um mob e o
		dano iria para outro.
	]]
	mobClone:SetAttribute("PathOffsetY", currentSize.Y / 2)

	mobClone:PivotTo(currentPivot * CFrame.new(0, verticalAdjustment, 0))
	mobClone:PivotTo(CFrame.new(startPosition.X, targetHeight, startPosition.Z) * mobClone:GetPivot().Rotation)

	self.MobMovement[mobId] = {
		model = mobClone,
		speed = speed,
		pointIndex = 2,
		points = smooth.points,
		-- O caminho inteiro, e nao so os pontos: o `MobTeleported` precisa das
		-- distancias acumuladas para achar onde o mob reaparece.
		smooth = smooth,
		extentsSize = extentsSize,
	}

	local slowWalk = mobModel:FindFirstChild("SlowWalk")
	local fastWalk = mobModel:FindFirstChild("FastWalk")
	local walkAnim = mobModel:FindFirstChild("Walk")

	local animationController = mobClone:FindFirstChild("AnimationController") or Instance.new("AnimationController", mobClone)
	local animator = animationController:FindFirstChildOfClass("Animator") or Instance.new("Animator", animationController)

	if slowWalk and fastWalk then
		local movement = self.MobMovement[mobId]
		movement.slowTrack = animator:LoadAnimation(slowWalk)
		movement.fastTrack = animator:LoadAnimation(fastWalk)
		movement.averageSpeed = getAverageSpeed(mobName) or speed
		self:updateWalkAnimation(mobId)
	elseif walkAnim then
		local track = animator:LoadAnimation(walkAnim)
		track:Play()
		self.MobMovement[mobId].walkTrack = track
		track:AdjustSpeed(self.TimeScale or 1)
	end
end

function MobController:updateWalkAnimation(mobId)
	local movement = self.MobMovement[mobId]
	if not movement or not movement.slowTrack or not movement.fastTrack then return end

	local targetTrack = movement.speed >= movement.averageSpeed and movement.fastTrack or movement.slowTrack
	local otherTrack = targetTrack == movement.fastTrack and movement.slowTrack or movement.fastTrack

	if otherTrack.IsPlaying then
		otherTrack:Stop(0.2)
	end
	if not targetTrack.IsPlaying then
		targetTrack:Play(0.2)
	end

	targetTrack:AdjustSpeed(self.TimeScale or 1)
end

function MobController:playAttackAnimation(mobId)
	local movement = self.MobMovement[mobId]
	local mob = movement and movement.model
	if not mob or not mob.Parent then return end

	if not movement.attackTrack then
		local attackAnim = mob:FindFirstChild("Attack")
		local animationController = mob:FindFirstChild("AnimationController")
		local animator = animationController and animationController:FindFirstChildOfClass("Animator")
		if not attackAnim or not animator then return end
		movement.attackTrack = animator:LoadAnimation(attackAnim)
		movement.attackTrack.Priority = Enum.AnimationPriority.Action
	end

	movement.attackTrack:Play(0.1)
	movement.attackTrack:AdjustSpeed(self.TimeScale or 1)
end

--[=[
	Poe as animacoes dos mobs na velocidade da partida.

	Sem isto o boneco no 2x desliza: ele anda o dobro da distancia por segundo
	com a caminhada tocando no ritmo de sempre. Vale para o ataque pelo mesmo
	motivo -- o servidor bate duas vezes mais rapido.
]=]
function MobController:applyTimeScale(scale : number)
	for _, data in self.MobMovement do
		for _, key in { "slowTrack", "fastTrack", "walkTrack", "attackTrack" } do
			local track = data[key]
			if track then
				track:AdjustSpeed(scale)
			end
		end
	end
end

function MobController:startMovementLoop()
	RunService.Heartbeat:Connect(function(dt)
		--[[
			A escala e lida do relogio a cada quadro em vez de empurrada pelo
			`SpeedController`: sao duas comparacoes, e em troca este laco nao depende
			da ordem em que os controllers ligam nem de quem avisou quem.
		]]
		local scale = GameClock.GetScale()
		if scale ~= self.TimeScale then
			self.TimeScale = scale
			self:applyTimeScale(scale)
		end

		for mobId, data in self.MobMovement do
			local mobClone = data.model
			if not mobClone or not mobClone.Parent then
				self.MobMovement[mobId] = nil
				continue
			end

			local points = data.points
			if data.pointIndex > #points then
				mobClone:Destroy()
				self.SpawnedMobs[mobId] = nil
				self.MobMovement[mobId] = nil
				continue
			end

			local extentsSize = data.extentsSize
			local currentPivot = mobClone:GetPivot()
			local currentPos = currentPivot.Position

			if not checkIsOnGrid(currentPos, extentsSize) then
				mobClone:Destroy()
				self.SpawnedMobs[mobId] = nil
				self.MobMovement[mobId] = nil
				continue
			end

			local posH = Vector3.new(currentPos.X, 0, currentPos.Z)
			local currentHeight = currentPos.Y - (extentsSize.Y / 2)
			-- O mesmo `dt` acelerado que o `MobService` usa para somar a distancia
			-- do lado dele. Os dois tem que andar juntos, senao o mob some da tela
			-- antes de chegar ou chega depois de ja ter batido na base.
			local remaining = data.speed * GameClock.Scaled(dt)
			local lookTargetH = nil

			while remaining > 0 and data.pointIndex <= #points do
				local target = points[data.pointIndex]
				local targetH = Vector3.new(target.X, 0, target.Z)
				local toTarget = targetH - posH
				local d = toTarget.Magnitude
				if d <= 1e-4 then
					currentHeight = target.Y
					data.pointIndex += 1
					continue
				end
				lookTargetH = targetH
				if remaining >= d then
					posH = targetH
					currentHeight = target.Y
					remaining -= d
					data.pointIndex += 1
				else
					local alpha = remaining / d
					posH = posH + toTarget.Unit * remaining
					currentHeight = currentHeight + (target.Y - currentHeight) * alpha
					remaining = 0
				end
			end

			local nextPos = Vector3.new(posH.X, currentHeight + (extentsSize.Y / 2), posH.Z)
			if lookTargetH then
				local lookTarget = Vector3.new(lookTargetH.X, nextPos.Y, lookTargetH.Z)
				if (lookTarget - nextPos).Magnitude > 0.01 then
					mobClone:PivotTo(CFrame.lookAt(nextPos, lookTarget))
				else
					mobClone:PivotTo(CFrame.new(nextPos) * currentPivot.Rotation)
				end
			else
				mobClone:PivotTo(CFrame.new(nextPos) * currentPivot.Rotation)
			end
			self.MobLastPosition[mobId] = nextPos
		end
	end)
end

function MobController:startHoverLoop()
	-- Sem mouse nao existe pairar sobre nada: no celular o loop so gastaria um
	-- raycast a cada 0.05s para nunca encontrar mob nenhum.
	if PointerUtil.isTouchOnly() then return end

	local accum = 0
	RunService.RenderStepped:Connect(function(dt)
		accum += dt
		if accum < 0.05 then return end
		accum = 0

		local pointerPosition = PointerUtil.getScreenPosition()
		if not pointerPosition then return end

		local camera = workspace.CurrentCamera
		local ray = camera:ViewportPointToRay(pointerPosition.X, pointerPosition.Y)

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local character = Players.LocalPlayer.Character
		params.FilterDescendantsInstances = character and {character} or {}

		local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
		local hovered = nil
		if result then
			local inst = result.Instance
			for _, mob in self.SpawnedMobs do
				if mob and mob.Parent and (inst == mob or inst:IsDescendantOf(mob)) then
					hovered = mob
					break
				end
			end
		end

		if hovered ~= self.hoveredMob then
			if self.hoveredMob and self.hoveredMob.Parent then
				local bb = getHealthBillboard(self.hoveredMob)
				if bb then bb.Enabled = false end
			end
			self.hoveredMob = hovered
			if hovered then
				local bb = getHealthBillboard(hovered)
				if bb then bb.Enabled = true end
			end
		end
	end)
end

function MobController:construct()
	Framework:Listen("SpawnClientMob", function(entityData)
		self:createEntity(entityData)
	end)

	--[[
		O Teleport do Archmage jogou o mob para tras no caminho. O servidor manda a
		distancia nova, e daqui o boneco reaparece nela: o laco de movimento persegue
		o `pointIndex`, entao ele passa a ser o primeiro ponto depois dessa distancia.
	]]
	Framework:Listen("MobTeleported", function(mobId, distance)
		local movement = self.MobMovement[mobId]
		local smooth = movement and movement.smooth
		if not smooth or typeof(distance) ~= "number" then return end

		local position = PathUtil.GetPositionAtDistance(smooth, distance)
		if not position then return end

		local nextIndex = #smooth.points + 1
		for index, at in ipairs(smooth.cumulative) do
			if at > distance then
				nextIndex = index
				break
			end
		end
		movement.pointIndex = math.max(2, nextIndex)

		local model = movement.model
		if model and model.Parent then
			local height = position.Y + (movement.extentsSize.Y / 2)
			model:PivotTo(CFrame.new(position.X, height, position.Z) * model:GetPivot().Rotation)
			self.MobLastPosition[mobId] = model:GetPivot().Position
		end
	end)

	Framework:Listen("UpdateMobSpeed", function(mobId, newSpeed)
		local movement = self.MobMovement[mobId]
		if movement then
			movement.speed = newSpeed
			self:updateWalkAnimation(mobId)
		end
	end)

	Framework:Listen("MobPlayAttack", function(mobId)
		self:playAttackAnimation(mobId)
	end)

	Framework:Listen("KillClientMob", function(mobId)
		local mob = self.SpawnedMobs[mobId]
		if mob then
			if self.hoveredMob == mob then
				self.hoveredMob = nil
			end
			if mob.Parent then
				local position = mob:GetPivot().Position
				self.MobLastPosition[mobId] = position

				self.Controllers.VFXController:Play("DeathVFX", position)
			end
			mob:Destroy()
			self.SpawnedMobs[mobId] = nil
		end
		self.MobMovement[mobId] = nil
		self.MobHealth[mobId] = nil
	end)

	Framework:Listen("AttackVisual", function(unitId, unitName, primaryMobId, hits)
		local primaryMob = self.SpawnedMobs[primaryMobId]
		local impactPos = (primaryMob and primaryMob.Parent and primaryMob:GetPivot().Position)
			or self.MobLastPosition[primaryMobId]

	for _, hit in hits do
		local mob = self.SpawnedMobs[hit.mobId]
		if mob and mob.Parent then
			flashMob(mob)
			spawnDamageNumber(mob, hit.damage)
			local hdata = self.MobHealth[hit.mobId]
			if hdata then
				hdata.current = math.max(0, hdata.current - hit.damage)
				updateHealthBar(mob, hdata.current, hdata.max)
			end
		else
			local lastPos = self.MobLastPosition[hit.mobId]
			if lastPos then
				spawnDamageNumber(lastPos, hit.damage)
			end
		end
	end

		if self.Controllers.VFXController then
			self.Controllers.VFXController:Trigger(unitName, "OnHit", {
				mobModel = primaryMob,
				position = impactPos,
				unitId = unitId,
			})
		end
	end)

	--[[
		O raio do Electro: o `VFXController` desenha o arco e daqui sai o realce dos
		inimigos que ele tocou. Os dois escutam o mesmo evento de proposito -- e o
		mesmo par do `UnitStunned`, onde o realce da unidade e o VFX do congelamento
		tambem vem separados.

		Sem `stun` (a unidade nao para ninguem) nao ha realce: ele diz que o inimigo
		esta travado, e nao que ele levou dano -- isso ja e o `HitFlash` vermelho.
	]]
	Framework:Listen("ChainLightning", function(arc)
		if typeof(arc) ~= "table" or typeof(arc.targets) ~= "table" then return end

		local duration = tonumber(arc.stun) or 0
		if duration <= 0 then return end

		for _, target in arc.targets do
			local mob = self.SpawnedMobs[target.mobId]
			if mob and mob.Parent then
				shockMob(mob, duration)
			end
		end
	end)

	Framework:Listen("UpdateBaseHealth", function(current, max)
		if current < (self.lastBaseHealth or max) then
			shakeScreen()
		end
		self.lastBaseHealth = current
	end)

	Framework:Listen("GameOver", function()
		self:clearAllMobs()
	end)

	-- O mapa pode ter mudado entre rounds; as rotas sao remontadas no proximo mob.
	Framework:Listen("RoundRestarted", function()
		self.Routes = nil
		self.NodeDistances = nil
		self:clearAllMobs()
	end)

	Framework:Listen("Win", function()
		self:clearAllMobs()
	end)

	Framework:Listen("RoundReward", function(info)
		self.LastRoundReward = info
	end)
end

function MobController:clearAllMobs()
	for _, mob in self.SpawnedMobs do
		if mob and mob.Parent then
			mob:Destroy()
		end
	end
	table.clear(self.SpawnedMobs)
	table.clear(self.MobMovement)
	table.clear(self.MobHealth)
	table.clear(self.MobLastPosition)
end

function MobController:start()

end

function MobController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:startMovementLoop()
	self:startHoverLoop()
	self:construct()
end

return MobController
