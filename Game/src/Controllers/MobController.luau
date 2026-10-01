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

--[[
	The highlight for enemies that took a shock: the Electro's bolt.

	The same yellow, the same transparencies, and the same idea as the stunned-unit
	highlight (`UnitPlacementController`): "this one is stopped". It lasts exactly as
	long as the jolt, which is short; it is what lets the player see the queue froze,
	instead of just seeing the bolt go by and the enemies keep walking.

	Its own name so it does not fight the red `HitFlash`, which flashes over it on
	every hit and goes away on its own.
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

--[=[
	The model this enemy wears: the model with the entity's own name, in the folder
	the entity names (`Folder` in `SharedConfig.Mob`).

	A missing model is an art mistake, and the right answer to it is the enemy
	showing up as `EnemyRig` with a warning in the console, not the match stopping.
]=]
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

local healthBarTweens = {}
local alwaysShowHealthBars = false

local function getHealthBillboard(mob)
	local attachment = mob:FindFirstChild("HealthAttachment")
	if not attachment then return nil end
	return attachment:FindFirstChildOfClass("BillboardGui")
end

local function updateHealthBar(mob, current, max, instant)
	-- Health also goes to an attribute on the model: that is how
	-- `TargetingController` finds the weakest or strongest enemy in range without
	-- asking MobController anything. It sits before the exits below on
	-- purpose: an enemy without a health bar is still a target.
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
	Paints an enemy yellow while the shock's jolt lasts.

	One highlight per enemy: a shock on top of another replaces the highlight and
	restarts the timer, instead of stacking two Highlights fighting over the same
	model, which is the same thing `MobService:StunMob` does with the jolt itself,
	where the longer deadline wins.

	The wait runs on the **match** clock, like `StunMob`'s on the other side: at 3x
	the 0.3s end in a tenth of a real second, and the highlight must go off with them,
	or it would outlive its own reason.
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
	-- The player's "Damage Numbers" setting. The health bar still shows the hit.
	local settings = Framework:Get("SettingsController", false, false)
	if settings and not settings:Get("DamageNumbers") then return end

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
	The current map's routes, identical to the server's: both sides build them from
	the same replicated nodes, so the index drawn there is valid here.

	Built once per map rather than on every enemy spawn; the cache drops on round
	restart.

	Yields: waits for the nodes to arrive complete before the first build. If they do
	not, it builds what it can but does not cache, so the next enemy tries again
	instead of dragging a truncated path through the whole round.
]=]
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

--[=[
	The path nodes with each one's distance to the first, for `TargetingController`'s
	`Farthest` priority.

	They come from the same routes as movement, which is what makes client and server
	measure an enemy's progress on the same ruler. An incomplete path is not cached,
	for the same reason as `getRoutes`: the next request tries again.
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

	self.MobHealth[mobId] = { current = entityData.Health or entityData.MaxHealth or 100, max = entityData.MaxHealth or 100 }
	updateHealthBar(mobClone, self.MobHealth[mobId].current, self.MobHealth[mobId].max, true)

	-- The route comes from the server: with a fork, client and server must walk
	-- exactly the same polyline, or the two simulations diverge.
	local routes = self:getRoutes()
	local route = routes[entityData.Route or 1] or routes[1]

	log:Debug(string.format("'%s': %d route(s) built, asked for %s -> %s | nodes in the folder: %d",
		mobName, #routes, tostring(entityData.Route), route and "found" or "NOT FOUND",
		#workspace.PathScriptable.Nodes:GetChildren()))

	--[[
		Without a route there is nowhere to walk, and what came next (`route.smooth`)
		would error mid-setup: the model already cloned and in the Workspace, but with
		no position or movement: an enemy invisible to the player and alive for the
		server, which kept telling towers to shoot at it.
	]]
	if not route then
		log:StudioWarn(string.format("mob '%s' has no route (%d built, %d nodes in the folder); not drawing it.",
			mobName, #routes, #workspace.PathScriptable.Nodes:GetChildren()))

		mobClone:Destroy()
		self.SpawnedMobs[mobId] = nil

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

	--[[
		How far the model's center is above the path. `TargetingController` subtracts
		this before asking which node the enemy is on: the server measures from the path
		point, and without the offset the two would pick different nodes near the middle
		of each segment: the tower would look at one enemy and the damage would go to
		another.
	]]
	mobClone:SetAttribute("PathOffsetY", currentSize.Y / 2)

	mobClone:PivotTo(currentPivot * CFrame.new(0, verticalAdjustment, 0))
	mobClone:PivotTo(CFrame.new(startPosition.X, targetHeight, startPosition.Z) * mobClone:GetPivot().Rotation)

	self.MobMovement[mobId] = {
		model = mobClone,
		speed = speed,
		pointIndex = 2,
		points = smooth.points,
		-- Where the enemy is on the path, on the ground. See the movement loop.
		pathPos = startPosition,
		-- The whole path, not just the points: `MobTeleported` needs the accumulated
		-- distances to find where the enemy reappears.
		smooth = smooth,
		extentsSize = extentsSize,
	}

	local slowWalk = mobModel:FindFirstChild("SlowWalk")
	local fastWalk = mobModel:FindFirstChild("FastWalk")
	--[[
		The generic walk from `Assets.Entities.Walk` closes the ladder.

		The rigs are all R6 with the same part names, so one animation works on any of
		them. What it avoids is the worst possible outcome for a model whose animation
		has not been published yet: the enemy **sliding** across the map in a T-pose.
		Half the Astral cast is in that state today: it has the `KeyframeSequence` in
		Moon Animator's `AnimSaves` and no `Animation`.
	]]
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

--[=[
	Plays a one-off animation of the model, by name, on top of the walk.

	One per name, stored in `oneShotTracks` and never reloaded: asking twice plays the
	same track again, not two overlapping tracks.

	A model without the animation leaves quietly. That is the normal case, not an
	error: the gimmick that asks for `Rush` belongs to the entity whose model has the
	animation (see `SharedConfig.Mob`), and reaching here without it is already the
	path of someone who gave a gimmick to the wrong entity. The `IsA` is there because
	`FindFirstChild` matches by name, and a Part called `Rush` would pass straight
	through until it errored in `LoadAnimation`.
]=]
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

--[=[
	Puts enemy animations at the match speed.

	Without this, the model slides at 2x: it walks twice the distance per second with
	the walk playing at the usual pace. It applies to the attack for the same reason:
	the server hits twice as fast.
]=]
function MobController:applyTimeScale(scale : number)
	for _, data in self.MobMovement do
		for _, key in { "slowTrack", "fastTrack", "walkTrack" } do
			local track = data[key]
			if track then
				track:AdjustSpeed(scale)
			end
		end

		-- One-offs come in here for the same reason as walks: `Rush` lasts
		-- 3.25s of match time, and at 2x it must fit in 1.6s of screen time, or the
		-- burst the server already applied goes out before the animation reaches it.
		for _, track in data.oneShotTracks or {} do
			track:AdjustSpeed(scale)
		end
	end
end

function MobController:startMovementLoop()
	RunService.Heartbeat:Connect(function(dt)
		--[[
			The scale is read from the clock every frame instead of pushed by
			`SpeedController`: it is two comparisons, and in exchange this loop does not
			depend on the order controllers start in or on who notified whom.
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

			--[[
				The path point where the enemy is, stored instead of reread from the model:
				the model is only its drawing, and rebuilding the position from the pivot
				every frame would accumulate `PivotTo`'s rounding error.
			]]
			local pos = data.pathPos or Vector3.new(currentPos.X, currentPos.Y - (extentsSize.Y / 2), currentPos.Z)

			--[[
				The same sped-up `dt` `MobService` uses to add distance on its side, and the
				same ruler: distance is spent in 3D, along the smoothed path's segments,
				which is how `PathUtil`'s `cumulative` measures the server's `mob.Distance`.

				Spending it only on the plane would make the model walk faster than the
				server on a ramp, and the error is never corrected: on Mountain, which rises
				17 studs, the screen would reach the base almost 5 studs ahead, more than a
				melee unit's range.
			]]
			local remaining = data.speed * GameClock.Scaled(dt)
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
			if lookTarget3D then
				local lookTarget = Vector3.new(lookTarget3D.X, nextPos.Y, lookTarget3D.Z)
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
	-- Without a mouse there is no hovering over anything: on mobile the loop would only
	-- spend a raycast every 0.05s to never find any enemy.
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

	--[[
		The Archmage's Teleport threw the enemy back on the path. The server sends the new
		distance, and from here the model reappears there: the movement loop chases
		`pointIndex`, so it becomes the first point after that distance.
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
		movement.pathPos = position

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

	Framework:Listen("MobPlayAnim", function(mobId, animationName)
		self:playOneShotAnimation(mobId, animationName)
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

	--[[
		Damage that did not come from a unit's hit: burn and bleed ticks
		(`MobService:applyDamageOverTime`) and a tripmine explosion
		(`UnitService:stepTripmines`).

		The number and the health bar, like an `AttackVisual` hit just below, but without
		the flash: it would blink over the effect's Highlight on every tick, and the mine
		already has its own explosion.
	]]
	Framework:Listen("MobDamageTick", function(mobId, damage)
		local mob = self.SpawnedMobs[mobId]
		if not mob or not mob.Parent or typeof(damage) ~= "number" then return end

		spawnDamageNumber(mob, damage)

		local hdata = self.MobHealth[mobId]
		if hdata then
			hdata.current = math.max(0, hdata.current - damage)
			updateHealthBar(mob, hdata.current, hdata.max)
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
		The Electro's bolt: `VFXController` draws the arc and the highlight of the enemies
		it touched comes from here. Both listen to the same event on purpose: it is the
		same pair as `UnitStunned`, where the unit highlight and the freeze VFX also come
		separately.

		Without `stun` (the unit stops nobody) there is no highlight: it says the enemy is
		stuck, not that it took damage; that is already the red `HitFlash`.
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

	-- The map may have changed between rounds; the routes are rebuilt on the next enemy.
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

--- Applies the "Always Show Health Bars" setting to every enemy already on the map.
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
