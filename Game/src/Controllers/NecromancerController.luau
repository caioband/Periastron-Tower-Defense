local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Entities = Assets:WaitForChild("Entities")
local Difficulties = Entities:WaitForChild("Difficulties")

local SharedConfig = require(Configs.SharedConfig)
local MobConfig = SharedConfig.Mob
local PathUtil = require(Shared.Util.PathUtil)
local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local DEFAULT_TINT = Color3.fromRGB(120, 255, 140)
local HIGHLIGHT_NAME = "MinionHighlight"

local function resolveModel(entityName : string) : Instance?
	local entity = MobConfig.Entities[entityName]
	local folder = entity and Difficulties:FindFirstChild(entity.Folder or "")
	local model = folder and folder:FindFirstChild(entityName)
	return model or Entities:FindFirstChild("EnemyRig")
end

local function getAnimation(parent : Instance, name : string) : Animation?
	local animation = parent:FindFirstChild(name)
	if animation and animation:IsA("Animation") then
		return animation
	end
	return nil
end

local function getAverageSpeed(entityName : string) : number?
	local entity = MobConfig.Entities and MobConfig.Entities[entityName]
	if not entity then return nil end

	local startSpeed = (MobConfig.BaseSpeed or 0) * (entity.SpeedMultiplier or 1)
	local endScale = 1
	for _, gimmick in entity.Gimmicks or {} do
		if gimmick.Type == "PerTurnSpeedMultiplier" then
			endScale = math.max(0.1, 1 + ((gimmick.MaxStacks or 0) * (gimmick.Amount or 0)))
			break
		end
	end

	return (startSpeed + startSpeed * endScale) / 2
end

local function necromancyOf(unitName : string?)
	local stats = unitName and SharedConfig.UnitStats[unitName]
	return stats and stats.Necromancy or {}
end

local function updateHealthBar(model : Model, current : number, max : number)
	local attachment = model:FindFirstChild("HealthAttachment")
	local billboard = attachment and attachment:FindFirstChildOfClass("BillboardGui")
	if not billboard then return end

	local bar = billboard:FindFirstChild("Bar")
	local clip = bar and bar:FindFirstChild("ScaleThis")
	if clip then
		clip.Size = UDim2.new(math.clamp(current / math.max(max, 1), 0, 1), 0, 1, 0)
	end

	local label = bar and bar:FindFirstChildOfClass("TextLabel")
	if label then
		label.Text = math.ceil(math.max(current, 0)) .. "/" .. max
	end

	local nameLabel = billboard:FindFirstChild("MobName")
	if nameLabel then
		nameLabel.Text = "Risen " .. model.Name
	end
end

local NecromancerController = {
	Controllers = {
		MobController = {},
		VFXController = {},
	},
	Minions = {},
	TimeScale = 1,
}

function NecromancerController:placeMinion(record)
	local position = PathUtil.GetPositionAtDistance(record.smooth, record.distance)
	if not position then return end

	local ahead = PathUtil.GetPositionAtDistance(record.smooth, math.max(0, record.distance - 0.5)) or position
	local center = position + Vector3.new(0, record.height, 0)
	local look = Vector3.new(ahead.X, center.Y, ahead.Z)

	if (look - center).Magnitude > 0.01 then
		record.model:PivotTo(CFrame.lookAt(center, look))
	else
		record.model:PivotTo(CFrame.new(center) * record.model:GetPivot().Rotation)
	end
end

function NecromancerController:createMinion(data)
	if typeof(data) ~= "table" or not data.Id or self.Minions[data.Id] then return end

	local source = resolveModel(data.Name)
	if not source then return end

	local mobController = self.Controllers.MobController
	local routes = mobController and mobController:getRoutes()
	local route = routes and (routes[data.Route or 1] or routes[1])
	if not route then return end

	local model = source:Clone()
	model.Name = data.Name
	model:SetAttribute("MinionID", data.Id)

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = part.Name == "HumanoidRootPart"
			part.CanCollide = false
			part.CanTouch = false
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end

	local extentsCFrame, extentsSize = model:GetBoundingBox()
	local localCenter = model:GetPivot():ToObjectSpace(extentsCFrame)
	model:PivotTo(model:GetPivot() * localCenter)

	local config = necromancyOf(data.UnitName)
	local tint = config.Tint or DEFAULT_TINT

	local highlight = Instance.new("Highlight")
	highlight.Name = HIGHLIGHT_NAME
	highlight.FillColor = tint
	highlight.OutlineColor = tint
	highlight.FillTransparency = 0.55
	highlight.OutlineTransparency = 0.1
	highlight.Parent = model

	local healthAttachment = Assets.UI.HealthAttachment:Clone()
	healthAttachment.Parent = model

	local billboard = healthAttachment:FindFirstChildOfClass("BillboardGui")
	if billboard then
		billboard.Enabled = true
	end

	model.Parent = workspace

	local record = {
		model = model,
		smooth = route.smooth,
		distance = data.Distance or route.smooth.length,
		speed = data.Speed or 0,
		height = extentsSize.Y / 2,
		health = data.Health or data.MaxHealth or 1,
		maxHealth = data.MaxHealth or 1,
	}
	self.Minions[data.Id] = record

	local animationController = model:FindFirstChild("AnimationController") or Instance.new("AnimationController", model)
	local animator = animationController:FindFirstChildOfClass("Animator") or Instance.new("Animator", animationController)
	record.animator = animator

	local slowWalk = getAnimation(source, "SlowWalk")
	local fastWalk = getAnimation(source, "FastWalk")
	local walk

	if slowWalk and fastWalk then
		walk = if record.speed >= (getAverageSpeed(data.Name) or record.speed) then fastWalk else slowWalk
	else
		walk = getAnimation(source, "Walk") or getAnimation(Entities, "Walk")
	end

	if walk then
		local track = animator:LoadAnimation(walk)
		track:Play()
		track:AdjustSpeed(self.TimeScale)
		record.walkTrack = track
	end

	updateHealthBar(model, record.health, record.maxHealth)
	self:placeMinion(record)

	local vfx = self.Controllers.VFXController
	if config.SpawnVFX and vfx then
		vfx:Play(config.SpawnVFX, model:GetPivot().Position)
	end
end

function NecromancerController:playAttack(record)
	if not record.attackTrack then
		local animation = getAnimation(record.model, "Attack")
		if not animation or not record.animator then return end

		record.attackTrack = record.animator:LoadAnimation(animation)
		record.attackTrack.Priority = Enum.AnimationPriority.Action
	end

	record.attackTrack:Play(0.1)
	record.attackTrack:AdjustSpeed(self.TimeScale)
end

function NecromancerController:removeMinion(minionId : string, reason : string?)
	local record = self.Minions[minionId]
	if not record then return end

	self.Minions[minionId] = nil

	local model = record.model
	if model and model.Parent then
		local vfx = self.Controllers.VFXController
		if reason == "Died" and vfx then
			vfx:Play("DeathVFX", model:GetPivot().Position)
		end
		model:Destroy()
	end
end

function NecromancerController:clearAll()
	for minionId in self.Minions do
		self:removeMinion(minionId)
	end
	table.clear(self.Minions)
end

function NecromancerController:applyTimeScale(scale : number)
	for _, record in self.Minions do
		if record.walkTrack then
			record.walkTrack:AdjustSpeed(scale)
		end
		if record.attackTrack then
			record.attackTrack:AdjustSpeed(scale)
		end
	end
end

function NecromancerController:startLoop()
	RunService.Heartbeat:Connect(function(dt)
		local scale = GameClock.GetScale()
		if scale ~= self.TimeScale then
			self.TimeScale = scale
			self:applyTimeScale(scale)
		end

		local step = GameClock.Scaled(dt)

		for minionId, record in self.Minions do
			if not record.model or not record.model.Parent then
				self.Minions[minionId] = nil
				continue
			end

			record.distance = math.max(0, record.distance - record.speed * step)
			self:placeMinion(record)
		end
	end)
end

function NecromancerController:construct()
	Framework:Listen("MinionSpawned", function(data)
		self:createMinion(data)
	end)

	Framework:Listen("MinionHit", function(minionId, health)
		local record = self.Minions[minionId]
		if not record or typeof(health) ~= "number" then return end

		record.health = health
		updateHealthBar(record.model, record.health, record.maxHealth)
		self:playAttack(record)
	end)

	Framework:Listen("MinionRemoved", function(minionId, reason)
		self:removeMinion(minionId, reason)
	end)

	Framework:Listen("RoundRestarted", function()
		self:clearAll()
	end)

	Framework:Listen("GameOver", function()
		self:clearAll()
	end)

	Framework:Listen("Win", function()
		self:clearAll()
	end)
end

function NecromancerController:start()
end

function NecromancerController:init()
	for name in self.Controllers do
		self.Controllers[name] = Framework:Get(name, false, true)
	end

	self:startLoop()
	self:construct()
end

return NecromancerController