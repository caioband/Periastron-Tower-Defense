local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local Me = require(Shared.Me)
local Framework = Me.new()

local ROTATION_SPEED = 8
local NO_TARGET_RESET_DELAY = 1.5

local Unit = {}
Unit.__index = Unit

function Unit:createAOE()
end

function Unit:loadAnimations()
	self.loadedAnimations = {}

	local animationController = self.model:FindFirstChildWhichIsA("AnimationController") or Instance.new("AnimationController")
	animationController.Parent = self.model

	local animator = animationController:FindFirstChildWhichIsA("Animator") or Instance.new("Animator", animationController)

	for _, animation : Animation in self.model:GetChildren() do
		if not animation:IsA("Animation") then continue end
		self.loadedAnimations[animation.Name] = animator:LoadAnimation(animation)
	end
end

function Unit:playSound(soundName, cutAfter)
	if not self.model then return nil end
	local soundsFolder = self.model:FindFirstChild("Sounds")
	if not soundsFolder then return nil end
	local template = soundsFolder:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then return nil end

	local parent = self.model.PrimaryPart or self.model:FindFirstChildWhichIsA("BasePart")
	if not parent then return nil end

	local sound = template:Clone()
	sound.Parent = parent
	sound:Play()

	if cutAfter then
		task.delay(cutAfter, function()
			if sound and sound.Parent then
				sound:Stop()
				sound:Destroy()
			end
		end)
	else
		sound.Ended:Once(function()
			if sound and sound.Parent then sound:Destroy() end
		end)
		task.delay(15, function()
			if sound and sound.Parent then sound:Destroy() end
		end)
	end

	return sound
end

function Unit:playAttackVisual(target : Model?, stepIndex : number?)
	if not self.model or not self.model.Parent then return end

	local sequence = self.attackConfig and self.attackConfig.AttackSequence
	local step = nil
	if sequence and #sequence > 0 then
		if stepIndex and sequence[stepIndex] then
			self.attackSequenceIndex = stepIndex
		else
			self.attackSequenceIndex = ((self.attackSequenceIndex or 0) % #sequence) + 1
		end
		step = sequence[self.attackSequenceIndex]
	end

	local animName = step and step.Animation or "Attack"
	local hitTime = step and step.HitTime or 0

	local track = self.loadedAnimations[animName]
	if track and sequence then
		for _, otherStep in sequence do
			local otherTrack = self.loadedAnimations[otherStep.Animation]
			if otherTrack and otherTrack ~= track and otherTrack.IsPlaying then
				otherTrack:Stop(0.1)
			end
		end
	end

	local freshSwing = false
	if track and not track.IsPlaying then
		track:Play()
		freshSwing = true
	end

	if freshSwing and step and step.SwingSound then
		self:playSound(step.SwingSound)
	end

	local lastTargetPos = (target and target.Parent) and target:GetPivot().Position or nil

	local function fireHit()
		if not self.model or not self.model.Parent then return end
		self:playSound("Lunge")
		local projController = Framework:Get("ProjectileController")
		local stats = self.stats
		local liveTarget = (target and target.Parent) and target or nil
		if liveTarget then
			lastTargetPos = liveTarget:GetPivot().Position
		end
		if projController and stats and stats.Projectile then
			if not liveTarget and not lastTargetPos then return end
			local startPos = self.model:GetPivot().Position + Vector3.new(0, 2, 0)
			local launchSound = self:playSound("Launch")
			self:playSound("Shot", 2)
			projController:Fire(startPos, liveTarget, stats.Projectile, function(impactPos)
				if launchSound and launchSound.Parent then
					launchSound:Stop()
					launchSound:Destroy()
				end
				local vfx = Framework:Get("VFXController")
				if vfx then
					vfx:Trigger(self.name, "OnAttack", { unitModel = self.model, mobModel = liveTarget, position = impactPos })
				end
			end, lastTargetPos)
		elseif liveTarget then
			local vfx = Framework:Get("VFXController")
			if vfx then
				vfx:Trigger(self.name, "OnAttack", { unitModel = self.model, mobModel = liveTarget })
			end
		end
	end

	local function scheduleHits()
		local totalHits = self.stats.Hits or 1
		local interval = self.stats.HitInterval or 0
		fireHit()
		for i = 2, totalHits do
			task.delay(interval * (i - 1), fireHit)
		end
	end

	if hitTime > 0 then
		task.delay(hitTime, scheduleHits)
	elseif track and freshSwing then
		local fired = false
		local function once()
			if fired then return end
			fired = true
			scheduleHits()
		end
		local markerConn
		markerConn = track:GetMarkerReachedSignal("Hit"):Connect(function()
			markerConn:Disconnect()
			once()
		end)
		local safetyDelay = track.Length > 0 and track.Length or (self.stats.Cooldown or 3)
		task.delay(safetyDelay, function()
			markerConn:Disconnect()
			once()
		end)
	else
		scheduleHits()
	end
end

function Unit:playFarmVisual()
	if not self.model or not self.model.Parent then return end
	if not self.loadedAnimations then return end
	local track = self.loadedAnimations.MoneyWave or self.loadedAnimations.Money or self.loadedAnimations.money
	if not track then return end
	if track.IsPlaying then
		track:Stop(0)
	end
	track:Play()
end

function Unit:setCF()
	local mob = self.target :: Model
	local currentPosition = self.defaultCF.Position + Vector3.new(0, self.heightOffset or 0, 0)

	if mob and mob.Parent then
		self.noTargetSince = nil
		local cf = mob:GetPivot()
		local lookTarget = Vector3.new(cf.Position.X, currentPosition.Y, cf.Position.Z)
		self.targetLookCF = CFrame.lookAt(currentPosition, lookTarget)
	else
		if not self.noTargetSince then
			self.noTargetSince = os.clock()
		end
		if os.clock() - self.noTargetSince >= NO_TARGET_RESET_DELAY then
			self.targetLookCF = CFrame.new(currentPosition) * self.defaultCF.Rotation
		end
	end
end

function Unit:setTarget(mob : Model)
	self.target = mob
	self:setCF()
end

function Unit:findTargets()
end

function Unit.new(name : string, model : Model)
	local self = setmetatable({}, Unit)
	self.name = name
	self.unitId = model:GetAttribute("UnitID")
	self.isOwner = false
	self.model = model
	self.defaultCF = model:GetPivot()
	self.heightOffset = 0
	self.attackSequenceIndex = 0
	self.targetLookCF = model:GetPivot()
	self.noTargetSince = nil

	self.parameters = {
		availableToAttack = true,
	}

	self.stats = SharedConfig.UnitStats[name] or {
		Damage = 10,
		Range = 10,
		Cooldown = 1,
		AttackType = "Single"
	}

	self.attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[name]

	self:loadAnimations()
	self.loadedAnimations.Idle:Play()

	self.rotationConn = RunService.RenderStepped:Connect(function(dt)
		if not self.model or not self.model.Parent then return end
		local currentCF = self.model:GetPivot()
		local smoothed = currentCF:Lerp(self.targetLookCF, math.min(1, dt * ROTATION_SPEED))
		self.model:PivotTo(smoothed)
	end)

	return self
end

function Unit:Destroy()
	if self.rotationConn then
		self.rotationConn:Disconnect()
		self.rotationConn = nil
	end
	if self.loadedAnimations then
		for _, track in self.loadedAnimations do
			if track then
				track:Stop()
				track:Destroy()
			end
		end
		self.loadedAnimations = nil
	end
	self.target = nil
	self.model = nil
end

return Unit
