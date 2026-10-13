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
local MobSets = Mobs:WaitForChild("Difficulties")

local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)
local MobConfig = require(Configs.SharedConfig.Mob)
local PathUtil = require(Shared.Util.PathUtil)
local PointerUtil = require(Shared.Util.PointerUtil)
local GameClock = require(Shared.Util.GameClock)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("MobController")

local HIT_FLASH_COLOR = Color3.fromRGB(255, 50, 50)
local HIT_FLASH_TIME = 0.12

local SHOCK_HIGHLIGHT = "ShockHighlight"
local SHOCK_COLOR = Color3.fromRGB(255, 200, 60)

local KNOCKBACK_KIND = "Knockback"
local BOUNCE_DURATION = 0.35
local BOUNCE_HEIGHT_PER_STUD = 0.35
local BOUNCE_MIN_HEIGHT = 0.3
local BOUNCE_MAX_HEIGHT = 1.2

local SHAKE_DURATION = 0.6
local SHAKE_MAGNITUDE = 0.35
local SHAKE_FREQUENCY = 18

local GRID_REFRESH_INTERVAL = 1
local GRID_CHECK_INTERVAL = 0.2
local GRID_CAST_LIFT = Vector3.new(0, 5, 0)
local GRID_CAST_DIRECTION = Vector3.new(0, -15, 0)

local LAST_POSITION_TTL = 2

local MAX_DAMAGE_NUMBERS = 40
local DAMAGE_NUMBER_DURATION = 0.8
local DAMAGE_WIGGLE_FREQ = 18
local DAMAGE_WIGGLE_AMP = 22
local DAMAGE_FLOAT_RISE = Vector3.new(0, 2.5, 0)
local DAMAGE_FONT = Font.new("rbxassetid://12187371840", Enum.FontWeight.Medium, Enum.FontStyle.Normal)

local HEALTH_TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TRACK_KEYS = { "slowTrack", "fastTrack", "walkTrack" }

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

local function effectsOn() : boolean
	local settings = Framework:Get("SettingsController", false, false)
	return settings == nil or settings:Get("VFX")
end

local function resolveMobModel(entityName : string) : Instance?
	local entity = MobConfig.Entities[entityName]
	local folder = entity and MobSets:FindFirstChild(entity.Folder or "")
	local model = folder and folder:FindFirstChild(entityName)
	if model then return model end

	log:StudioWarn(string.format("'%s' has no model in Difficulties.%s; using EnemyRig.",
		entityName, tostring(entity and entity.Folder)))

	return Mobs:FindFirstChild("EnemyRig")
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

local alwaysShowHealthBars = false

local function getHealthBillboard(mob)
	local attachment = mob:FindFirstChild("HealthAttachment")
	if not attachment then return nil end
	return attachment:FindFirstChildOfClass("BillboardGui")
end

local function resolveHealthUi(mob)
	local billboard = getHealthBillboard(mob)
	local bar = billboard and billboard:FindFirstChild("Bar")

	return {
		billboard = billboard,
		clip = bar and bar:FindFirstChild("ScaleThis"),
		text = bar and bar:FindFirstChildOfClass("TextLabel"),
		name = billboard and billboard:FindFirstChild("MobName"),
		tween = nil,
	}
end

local function updateHealthBar(mob, hdata, instant)
	local current, max = hdata.current, hdata.max
	mob:SetAttribute("Health", current)

	local ui = hdata.ui
	local clip = ui and ui.clip
	if not clip then return end

	local targetSize = UDim2.new(math.clamp(current / math.max(max, 1), 0, 1), 0, 1, 0)

	if ui.tween then
		ui.tween:Cancel()
		ui.tween = nil
	end

	if instant then
		clip.Size = targetSize
	else
		local tween = TweenService:Create(clip, HEALTH_TWEEN_INFO, { Size = targetSize })
		ui.tween = tween
		tween:Play()
	end

	if ui.text then
		ui.text.Text = math.ceil(math.max(current, 0)) .. "/" .. max
	end
end

local flashTokens = {}

local function flashMob(mob)
	if not effectsOn() then return end

	local highlight = mob:FindFirstChild("HitFlash")
	if not highlight then
		highlight = Instance.new("Highlight")
		highlight.Name = "HitFlash"
		highlight.FillColor = HIT_FLASH_COLOR
		highlight.OutlineColor = HIT_FLASH_COLOR
		highlight.FillTransparency = 0.2
		highlight.OutlineTransparency = 1
		highlight.Parent = mob
	end

	highlight.Enabled = true

	local token = (flashTokens[mob] or 0) + 1
	flashTokens[mob] = token

	task.delay(HIT_FLASH_TIME, function()
		if flashTokens[mob] == token and highlight.Parent then
			highlight.Enabled = false
		end
	end)
end

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

local damageNumbers = {}
local damageNumberLoop = nil
local damageNumberTemplate = nil

local function getDamageNumberTemplate()
	if damageNumberTemplate then
		return damageNumberTemplate
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 60, 0, 30)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 60, 60)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.FontFace = DAMAGE_FONT
	label.Parent = billboard

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 2
	stroke.Parent = label

	damageNumberTemplate = billboard
	return billboard
end

local function stepDamageNumbers(dt)
	for index = #damageNumbers, 1, -1 do
		local entry = damageNumbers[index]
		entry.elapsed += dt

		local t = math.min(entry.elapsed / DAMAGE_NUMBER_DURATION, 1)
		local billboard = entry.billboard

		if t >= 1 or not billboard.Parent then
			billboard:Destroy()
			local last = #damageNumbers
			damageNumbers[index] = damageNumbers[last]
			damageNumbers[last] = nil
			continue
		end

		local eased = 1 - (1 - t) ^ 2
		billboard.StudsOffset = entry.start:Lerp(entry.target, eased)

		local label = entry.label
		label.Rotation = math.sin(entry.elapsed * DAMAGE_WIGGLE_FREQ) * DAMAGE_WIGGLE_AMP * (1 - t)

		local alpha = math.clamp((t - 0.4) / 0.6, 0, 1)
		label.TextTransparency = alpha
		label.TextStrokeTransparency = alpha
	end

	if #damageNumbers == 0 and damageNumberLoop then
		damageNumberLoop:Disconnect()
		damageNumberLoop = nil
	end
end

local function spawnDamageNumber(mobOrPosition, damage)
	local settings = Framework:Get("SettingsController", false, false)
	if settings and not settings:Get("DamageNumbers") then return end
	if #damageNumbers >= MAX_DAMAGE_NUMBERS then return end

	local rootPart = nil
	local worldPos = nil

	if typeof(mobOrPosition) == "Instance" then
		rootPart = mobOrPosition:FindFirstChild("HumanoidRootPart") or mobOrPosition.PrimaryPart
		if not rootPart then return end
	elseif typeof(mobOrPosition) == "Vector3" then
		worldPos = mobOrPosition
	else
		return
	end

	local billboard = getDamageNumberTemplate():Clone()
	local start = Vector3.new(math.random(-10, 10) * 0.1, 2.5, 0)
	billboard.StudsOffset = start

	if rootPart then
		billboard.Adornee = rootPart
		billboard.Parent = rootPart
	else
		billboard.Adornee = workspace.Terrain
		billboard.StudsOffsetWorldSpace = worldPos
		billboard.Parent = workspace.Terrain
	end

	local label = billboard.Label
	label.Text = tostring(damage)

	table.insert(damageNumbers, {
		billboard = billboard,
		label = label,
		start = start,
		target = start + DAMAGE_FLOAT_RISE,
		elapsed = 0,
	})

	if not damageNumberLoop then
		damageNumberLoop = RunService.RenderStepped:Connect(stepDamageNumbers)
	end
end

local gridParams = RaycastParams.new()
gridParams.FilterType = Enum.RaycastFilterType.Include
local gridEmpty = true
local gridDirty = true
local gridRefreshedAt = 0

local function markGridDirty()
	gridDirty = true
end

CollectionService:GetInstanceAddedSignal("Grid"):Connect(markGridDirty)
CollectionService:GetInstanceRemovedSignal("Grid"):Connect(markGridDirty)

local function refreshGrid(now : number)
	gridDirty = false
	gridRefreshedAt = now

	local parts = {}
	for _, part in CollectionService:GetTagged("Grid") do
		if part:IsA("BasePart") and part:IsDescendantOf(workspace) then
			table.insert(parts, part)
		end
	end

	gridParams.FilterDescendantsInstances = parts
	gridEmpty = #parts == 0
end

local function checkIsOnGrid(position : Vector3, castSize : Vector3) : boolean
	local now = os.clock()
	if gridDirty or now - gridRefreshedAt >= GRID_REFRESH_INTERVAL then
		refreshGrid(now)
	end

	if gridEmpty then
		return true
	end

	return workspace:Blockcast(CFrame.new(position + GRID_CAST_LIFT), castSize, GRID_CAST_DIRECTION, gridParams) ~= nil
end

local function stepBounce(data, scaledDt : number) : Vector3
	local bounce = data.bounce
	if not bounce then return Vector3.zero end

	bounce.elapsed += scaledDt
	local t = math.clamp(bounce.elapsed / BOUNCE_DURATION, 0, 1)

	if t >= 1 then
		data.bounce = nil
		return Vector3.zero
	end

	local eased = 1 - (1 - t) ^ 2
	local lift = math.sin(math.pi * t) * bounce.height

	return bounce.slide * (1 - eased) + Vector3.new(0, lift, 0)
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

function MobController:getRoutes()
	if not self.Routes then
		local nodesFolder = workspace.PathScriptable.Nodes
		local complete = PathUtil.WaitForNodes(nodesFolder)
		local routes = PathUtil.BuildRoutes(nodesFolder)

		log:Debug(string.format("building routes: complete=%s nodes=%d (expected=%s) routes=%d",
			tostring(complete), #nodesFolder:GetChildren(),
			tostring(nodesFolder:GetAttribute("NodeCount") or nodesFolder:GetAttribute("Nodes") or "?"), #routes))

		if not complete then
			return routes
		end

		self.Routes = routes
	end
	return self.Routes
end

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

function MobController:GetPathDistance(mobModel : Instance) : number?
	local mobId = mobModel:GetAttribute("MobID")
	local movement = mobId and self.MobMovement[mobId]
	if not movement then return nil end

	local smooth = movement.smooth
	local previous = movement.pointIndex - 1
	local from = smooth.points[previous]

	if not from then
		return smooth.length
	end

	local pathPos = movement.pathPos or from

	return (smooth.cumulative[previous] or 0) + (pathPos - from).Magnitude
end

function MobController:removeMob(mobId, playDeath : boolean?)
	local mob = self.SpawnedMobs[mobId]

	local hdata = self.MobHealth[mobId]
	if hdata and hdata.ui and hdata.ui.tween then
		hdata.ui.tween:Cancel()
		hdata.ui.tween = nil
	end

	if mob then
		if self.hoveredMob == mob then
			self.hoveredMob = nil
		end

		if mob.Parent then
			local position = mob:GetPivot().Position
			self.MobLastPosition[mobId] = position

			if playDeath and self.Controllers.VFXController then
				self.Controllers.VFXController:Play("DeathVFX", position)
			end
		end

		local targeting = self.Controllers.TargetingController
		if targeting and targeting.UnregisterMob then
			targeting:UnregisterMob(mob)
		end

		flashTokens[mob] = nil
		mob:Destroy()
	end

	self.SpawnedMobs[mobId] = nil
	self.MobMovement[mobId] = nil
	self.MobHealth[mobId] = nil

	if self.MobLastPosition[mobId] then
		task.delay(LAST_POSITION_TTL, function()
			if not self.SpawnedMobs[mobId] then
				self.MobLastPosition[mobId] = nil
			end
		end)
	end
end

function MobController:createEntity(entityData)
	local mobName = entityData.Name or "CourageBearer"
	local speed = entityData.Speed or 6
	local mobId = entityData.Id

	local mobModel = resolveMobModel(mobName)
	if not mobModel then
		log:StudioWarn(string.format("no model at all for '%s'; not drawing it.", mobName))
		return
	end

	local mobClone = mobModel:Clone()
	mobClone:SetAttribute("MobID", mobId)

	self.SpawnedMobs[mobId] = mobClone

	for _, part in ipairs(mobClone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = part.Name == "HumanoidRootPart"
			part.CanCollide = false
			part.CanTouch = false
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
		healthBillboard.Enabled = alwaysShowHealthBars
	end

	mobClone.Parent = workspace

	local hdata = {
		current = entityData.Health or entityData.MaxHealth or 100,
		max = entityData.MaxHealth or 100,
		ui = resolveHealthUi(mobClone),
	}
	self.MobHealth[mobId] = hdata

	if hdata.ui.name then
		hdata.ui.name.Text = mobClone.Name
	end

	updateHealthBar(mobClone, hdata, true)

	local routes = self:getRoutes()
	local route = routes[entityData.Route or 1] or routes[1]

	log:Debug(string.format("'%s': %d route(s) built, asked for %s -> %s | nodes in the folder: %d",
		mobName, #routes, tostring(entityData.Route), route and "found" or "NOT FOUND",
		#workspace.PathScriptable.Nodes:GetChildren()))

	if not route then
		log:StudioWarn(string.format("mob '%s' has no route (%d built, %d nodes in the folder); not drawing it.",
			mobName, #routes, #workspace.PathScriptable.Nodes:GetChildren()))

		self:removeMob(mobId, false)
		return
	end

	local smooth = route.smooth
	local startPosition = smooth.points[1]

	self.Controllers.TargetingController:RegisterMob(mobClone)

	local _, currentSize = mobClone:GetBoundingBox()
	local currentPivot = mobClone:GetPivot()
	local bottomOffset = currentPivot.Position.Y - (currentSize.Y / 2)
	local targetHeight = startPosition.Y + (currentSize.Y / 2)
	local verticalAdjustment = targetHeight - bottomOffset

	mobClone:SetAttribute("PathOffsetY", currentSize.Y / 2)

	mobClone:PivotTo(currentPivot * CFrame.new(0, verticalAdjustment, 0))
	mobClone:PivotTo(CFrame.new(startPosition.X, targetHeight, startPosition.Z) * mobClone:GetPivot().Rotation)

	self.MobMovement[mobId] = {
		model = mobClone,
		speed = speed,
		pointIndex = 2,
		points = smooth.points,
		pathPos = startPosition,
		smooth = smooth,
		extentsSize = extentsSize,
		rotation = mobClone:GetPivot().Rotation,
		gridCastSize = Vector3.new(extentsSize.X * 0.8, 0.2, extentsSize.Z * 0.8),
		gridIndex = 0,
		gridCheckAt = 0,
	}

	local slowWalk = mobModel:FindFirstChild("SlowWalk")
	local fastWalk = mobModel:FindFirstChild("FastWalk")
	local walkAnim = mobModel:FindFirstChild("Walk") or Mobs:FindFirstChild("Walk")

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

function MobController:playOneShotAnimation(mobId : string, animationName : string)
	local movement = self.MobMovement[mobId]
	local mob = movement and movement.model
	if not mob or not mob.Parent then return end

	movement.oneShotTracks = movement.oneShotTracks or {}
	local track = movement.oneShotTracks[animationName]

	if not track then
		local animation = mob:FindFirstChild(animationName)
		if not (animation and animation:IsA("Animation")) then return end

		local animationController = mob:FindFirstChild("AnimationController")
		local animator = animationController and animationController:FindFirstChildOfClass("Animator")
		if not animator then return end

		track = animator:LoadAnimation(animation)
		track.Priority = Enum.AnimationPriority.Action
		movement.oneShotTracks[animationName] = track
	end

	track:Play(0.1)
	track:AdjustSpeed(self.TimeScale or 1)
end

function MobController:playAttackAnimation(mobId)
	self:playOneShotAnimation(mobId, "Attack")
end

function MobController:applyTimeScale(scale : number)
	for _, data in self.MobMovement do
		for _, key in TRACK_KEYS do
			local track = data[key]
			if track then
				track:AdjustSpeed(scale)
			end
		end

		if data.oneShotTracks then
			for _, track in data.oneShotTracks do
				track:AdjustSpeed(scale)
			end
		end
	end
end

function MobController:startMovementLoop()
	RunService.Heartbeat:Connect(function(dt)
		local scale = GameClock.GetScale()
		if scale ~= self.TimeScale then
			self.TimeScale = scale
			self:applyTimeScale(scale)
		end

		local scaledDt = GameClock.Scaled(dt)
		local clock = os.clock()

		for mobId, data in self.MobMovement do
			local mobClone = data.model
			if not mobClone or not mobClone.Parent then
				self:removeMob(mobId, false)
				continue
			end

			local points = data.points
			if data.pointIndex > #points then
				self:removeMob(mobId, false)
				continue
			end

			local extentsSize = data.extentsSize
			local pos = data.pathPos
			if not pos then
				local currentPos = mobClone:GetPivot().Position
				pos = Vector3.new(currentPos.X, currentPos.Y - (extentsSize.Y / 2), currentPos.Z)
			end

			local remaining = data.speed * scaledDt
			local lookTarget3D = nil

			while remaining > 0 and data.pointIndex <= #points do
				local target = points[data.pointIndex]
				local toTarget = target - pos
				local d = toTarget.Magnitude
				if d <= 1e-4 then
					pos = target
					data.pointIndex += 1
					continue
				end
				lookTarget3D = target
				if remaining >= d then
					pos = target
					remaining -= d
					data.pointIndex += 1
				else
					pos += toTarget.Unit * remaining
					remaining = 0
				end
			end

			data.pathPos = pos

			local nextPos = pos + Vector3.new(0, extentsSize.Y / 2, 0)

			if data.pointIndex ~= data.gridIndex or clock >= data.gridCheckAt then
				data.gridIndex = data.pointIndex
				data.gridCheckAt = clock + GRID_CHECK_INTERVAL

				if not checkIsOnGrid(nextPos, data.gridCastSize) then
					self:removeMob(mobId, false)
					continue
				end
			end

			local drawCFrame
			if lookTarget3D then
				local lookTarget = Vector3.new(lookTarget3D.X, nextPos.Y, lookTarget3D.Z)
				if (lookTarget - nextPos).Magnitude > 0.01 then
					drawCFrame = CFrame.lookAt(nextPos, lookTarget)
				else
					drawCFrame = CFrame.new(nextPos) * data.rotation
				end
			else
				drawCFrame = CFrame.new(nextPos) * data.rotation
			end

			data.rotation = drawCFrame.Rotation

			local offset = stepBounce(data, scaledDt)
			mobClone:PivotTo(CFrame.new(offset) * drawCFrame)

			self.MobLastPosition[mobId] = nextPos
		end
	end)
end

function MobController:startHoverLoop()
	if PointerUtil.isTouchOnly() then return end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local accum = 0
	RunService.RenderStepped:Connect(function(dt)
		accum += dt
		if accum < 0.05 then return end
		accum = 0

		local pointerPosition = PointerUtil.getScreenPosition()
		if not pointerPosition then return end

		local camera = workspace.CurrentCamera
		local ray = camera:ViewportPointToRay(pointerPosition.X, pointerPosition.Y)

		local character = Players.LocalPlayer.Character
		params.FilterDescendantsInstances = character and { character } or {}

		local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
		local hovered = nil
		if result then
			local model = result.Instance:FindFirstAncestorOfClass("Model")
			while model do
				local id = model:GetAttribute("MobID")
				if id then
					if self.SpawnedMobs[id] == model then
						hovered = model
					end
					break
				end
				model = model:FindFirstAncestorOfClass("Model")
			end
		end

		if hovered ~= self.hoveredMob then
			if self.hoveredMob and self.hoveredMob.Parent then
				local bb = getHealthBillboard(self.hoveredMob)
				if bb then bb.Enabled = alwaysShowHealthBars end
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
		log:Debug(string.format("received mob '%s' id=%s route=%s",
			tostring(entityData and entityData.Name), tostring(entityData and entityData.Id), tostring(entityData and entityData.Route)))

		self:createEntity(entityData)
	end)

	Framework:Listen("MobTeleported", function(mobId, distance, kind)
		local movement = self.MobMovement[mobId]
		local smooth = movement and movement.smooth
		if not smooth or typeof(distance) ~= "number" then return end

		local position = PathUtil.GetPositionAtDistance(smooth, distance)
		if not position then return end

		local model = movement.model
		local halfHeight = movement.extentsSize.Y / 2
		local drawnGround = (model and model.Parent) and (model:GetPivot().Position - Vector3.new(0, halfHeight, 0)) or nil

		local nextIndex = #smooth.points + 1
		for index, at in ipairs(smooth.cumulative) do
			if at > distance then
				nextIndex = index
				break
			end
		end
		movement.pointIndex = math.max(2, nextIndex)
		movement.pathPos = position

		if kind == KNOCKBACK_KIND and drawnGround then
			local slide = drawnGround - position
			local push = Vector3.new(slide.X, 0, slide.Z).Magnitude
			local height = math.clamp(push * BOUNCE_HEIGHT_PER_STUD, BOUNCE_MIN_HEIGHT, BOUNCE_MAX_HEIGHT)

			movement.bounce = { elapsed = 0, slide = slide, height = height }
			self.MobLastPosition[mobId] = position + Vector3.new(0, halfHeight, 0)
			return
		end

		movement.bounce = nil

		if model and model.Parent then
			local height = position.Y + halfHeight
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

	Framework:Listen("MobPlayAnim", function(mobId, animationName)
		self:playOneShotAnimation(mobId, animationName)
	end)

	Framework:Listen("KillClientMob", function(mobId)
		self:removeMob(mobId, true)
	end)

	Framework:Listen("MobDamageTick", function(mobId, damage)
		local mob = self.SpawnedMobs[mobId]
		if not mob or not mob.Parent or typeof(damage) ~= "number" then return end

		spawnDamageNumber(mob, damage)

		local hdata = self.MobHealth[mobId]
		if hdata then
			hdata.current = math.max(0, hdata.current - damage)
			updateHealthBar(mob, hdata)
		end
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
					updateHealthBar(mob, hdata)
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

	Framework:Listen("ChainLightning", function(arc)
		if typeof(arc) ~= "table" or typeof(arc.targets) ~= "table" then return end

		local duration = tonumber(arc.stun) or 0
		if duration <= 0 then return end

		for _, target in arc.targets do
			local mob = self.SpawnedMobs[target.mobId]
			if mob and mob.Parent then
				shockMob(mob, tonumber(target.stun) or duration)
			end
		end
	end)

	Framework:Listen("UpdateBaseHealth", function(current, max)
		if current < (self.lastBaseHealth or max) and effectsOn() then
			shakeScreen()
		end
		self.lastBaseHealth = current
	end)

	Framework:Listen("GameOver", function()
		self:clearAllMobs()
	end)

	Framework:Listen("RoundRestarted", function()
		self.Routes = nil
		self.NodeDistances = nil
		gridDirty = true
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
	for _, hdata in self.MobHealth do
		if hdata.ui and hdata.ui.tween then
			hdata.ui.tween:Cancel()
		end
	end

	for _, mob in self.SpawnedMobs do
		if mob and mob.Parent then
			mob:Destroy()
		end
	end

	local targeting = self.Controllers.TargetingController
	if targeting and targeting.ClearMobs then
		targeting:ClearMobs()
	end

	self.hoveredMob = nil
	table.clear(flashTokens)
	table.clear(self.SpawnedMobs)
	table.clear(self.MobMovement)
	table.clear(self.MobHealth)
	table.clear(self.MobLastPosition)
end

function MobController:setAlwaysShowHealthBars(enabled : boolean)
	alwaysShowHealthBars = enabled

	for _, mob in self.SpawnedMobs do
		if mob and mob.Parent and mob ~= self.hoveredMob then
			local bb = getHealthBillboard(mob)
			if bb then bb.Enabled = enabled end
		end
	end
end

function MobController:start()
	local settings = Framework:Get("SettingsController", false, false)
	if settings then
		settings:Observe("HealthBars", function(enabled : boolean)
			self:setAlwaysShowHealthBars(enabled)
		end)
	end
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