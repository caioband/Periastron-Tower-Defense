local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))
local Me = require(Vendor.Me)
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

		local track = animator:LoadAnimation(animation)

		--[=[
			`Idle` is lowered to `Movement`, whatever priority it was exported with.

			It is the **base pose**: it loops the whole match and every gesture plays
			on top of it. Two tracks at the same priority do not replace each other,
			they blend by weight, so a unit with both `Idle` and `Attack` at `Action`
			swings with half a hit and half a standing pose. The Berserker and the
			Archer are exported that way; the Sword and the Subspace Tripminer, whose
			`Idle` already comes at `Movement`, are the right behavior the others copy
			from here.

			The rule only lowers `Idle` and does not promote the attack, so the
			priority the animator wrote on each gesture still applies between them
			(the Entrepreneur's `MoneyWave`, the Slasher's `Slash2`), and there is no
			second place where a unit's art is decided.
		]=]
		if animation.Name == "Idle" then
			track.Priority = Enum.AnimationPriority.Movement

			-- The base pose plays the whole match, so it always loops, even when exported
			-- without `Loop` on, as the Archmage's was.
			track.Looped = true
		end

		self.loadedAnimations[animation.Name] = track
	end
end

--[=[
	Puts the unit's animations at match speed.

	`GameClock` speeds up waits, not `AnimationTrack`s. Without this sweep two things
	fall behind the scale: `Idle`, played once in `Unit.new` and never again (it
	would spend the whole match at 1x), and an attack already in the air when the
	player changed step, which would keep the old pace while the windup's
	`GameClock.Wait` already shrank.

	The sweep covers the whole list on purpose, not just the attack track: the
	Entrepreneur's `MoneyWave` runs on the same match time as the wave that paid it.

	`AdjustSpeed` on a stopped track is harmless (the speed is kept and applies when
	it plays), so nothing needs filtering here.

	`animationSpeeds` enters as a **product**, not a replacement: the attack track
	may already be compressed to fit the cooldown (see `playAttackVisual`), and
	writing only the match scale on top would erase the compression on the first
	step change.

	The enemy-side counterpart is `MobController:applyTimeScale`.
]=]
function Unit:applyTimeScale(scale : number)
	self.timeScale = scale

	if not self.loadedAnimations then return end

	for name, track in self.loadedAnimations do
		track:AdjustSpeed(scale * (self.animationSpeeds[name] or 1))
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

--[=[
	Where the projectile starts: the unit's `RootPart`.

	No offset here on purpose: a higher starting point (the bow tip, a barrel) is a
	part in the model, not a number added in code for every unit at once. The root
	is also safer than the model pivot: `GetPivot` follows `WorldPivot`, which only
	matches the root while `PrimaryPart` is set, and a model that loses its
	`PrimaryPart` reports the bounding box center, which moves with the animation
	pose.
]=]
function Unit:projectileOrigin() : Vector3?
	local model = self.model
	if not model or not model.Parent then return nil end

	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		root = model:FindFirstChildWhichIsA("BasePart")
	end

	return if root then root.Position else model:GetPivot().Position
end

function Unit:playAttackVisual(target : Model?, stepIndex : number?, swingWindow : number?)
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

	-- An attack that hits several times within one animation, each hit at its own
	-- instant. See `HitTimes` in `UnitAttackConfig`.
	local hitTimes = step and step.HitTimes

	local track = self.loadedAnimations[animName]
	if track and sequence then
		for _, otherStep in sequence do
			local otherTrack = self.loadedAnimations[otherStep.Animation]
			if otherTrack and otherTrack ~= track and otherTrack.IsPlaying then
				otherTrack:Stop(0.1)
			end
		end
	end

	--[[
		Match speed applies to the animation and the waits here.

		The server decides when damage lands (`UnitService:executeAttack`), where the
		windup and the gap between hits already run on the sped-up clock. This side
		draws the same attack: without the scale, at 2x the tower would hit twice
		while the model is still finishing the first swing.

		In the Lobby the scale is always 1 (there is no `SpeedService`), so this
		changes nothing for menu units.

		The scale is read again here, not inherited from `self.timeScale`, because a
		freshly played track returns to 1x: `applyTimeScale` only reacts to a scale
		*change* and would not see an attack started with the scale unchanged. Hence
		the explicit `AdjustSpeed` below, even with the per-frame sweep on.

		When this read comes before the frame's, the whole sweep answers, not only the
		attack track: advancing `self.timeScale` alone would silence the
		`RenderStepped` comparison and leave `Idle` and `MoneyWave` stuck on the old
		scale forever.
	]]
	local timeScale = GameClock.GetScale()
	if timeScale ~= self.timeScale then
		self:applyTimeScale(timeScale)
	end

	--[=[
		The animation fits inside the attack.

		An animation longer than the cooldown knocked the model out of sync: the next
		request arrived with the track still playing, `Play` here did not restart it,
		and the attack went out with no gesture (one shot animated, the next not,
		alternating). The Rocket is the most visible case (2.667 s of animation for a
		2.5 s cooldown), and the Azure, the Archer, and the Slasher's `Slash1` are in
		the same situation.

		The fix is neither shortening the animation file nor touching `Cooldown` (a
		balance number, not art), but **playing the animation faster** by exactly what
		it needs to fit. The whole gesture shows, squeezed into the time the unit has.

		The window comes from the server with weather, upgrades, cards, and charge
		already in, not from `stats.Cooldown` here: an `AttackSpeed` card shortens
		the cooldown, and the animation must shorten with it. Without the window (a
		unit that has not received the field yet), the factor is 1.

		`track.Length` is zero until the animation finishes loading; the comparison
		with the window already rejects that case.
	]=]
	local fit = 1
	if track and swingWindow and swingWindow > 0 and track.Length > swingWindow then
		fit = track.Length / swingWindow
	end

	if track then
		self.animationSpeeds[animName] = fit
	end

	--[[
		The attack restarts the track even while it is playing.

		With the compression above the slack is milliseconds, enough for the next
		request to arrive before the track closes (network jitter) and the gesture to
		be skipped again. Restarting closes that gap, and for units that already fit
		the cooldown (Sword, Slingshot, Subspace Tripminer) it changes nothing: the
		track had ended by the time the request arrives.

		Since every attack is a new attack, `SwingSound` plays on all of them.

		`TimePosition` rewinds the gesture, not `Play`: `Play` on a playing track does
		nothing. Nor `Stop(0)` then `Play`, as in `playFarmVisual`: that takes the
		track off for an instant and the model flickers to `Idle` before returning.
	]]
	if track then
		if track.IsPlaying then
			track.TimePosition = 0
		else
			track:Play()
		end

		track:AdjustSpeed(timeScale * fit)
	end

	if step and step.SwingSound then
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
			local startPos = self:projectileOrigin()
			if not startPos then return end
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
			GameClock.Delay(interval * (i - 1), fireHit)
		end
	end

	if hitTimes then
		--[[
			One `fireHit` per instant in the list, not `scheduleHits`: this attack's hits
			have their own times, not `HitInterval`'s even spacing. The list counts, not
			`stats.Hits`; the two must stay equal, but the animation's choreography rules
			here.

			The instants are divided by `fit` for the same reason the track is played
			multiplied by it: with the animation squeezed to fit the attack window, the
			`Hit` marker arrives earlier, and the hit must arrive with it. The server
			divides by the same factor (`UnitService:executeAttack`) using the config's
			`Duration`, the copy of the `track.Length` read here.
		]]
		for _, at in ipairs(hitTimes) do
			GameClock.Delay(at / fit, fireHit)
		end
	elseif hitTime > 0 then
		GameClock.Delay(hitTime, scheduleHits)
	elseif track then
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
		GameClock.Delay(safetyDelay, function()
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
	track:AdjustSpeed(self.timeScale)
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
	self.timeScale = GameClock.GetScale()

	-- Each track's own speed, by name, multiplied by the match scale in
	-- `applyTimeScale`. Today only the attack's differs from 1 (see
	-- `playAttackVisual`).
	self.animationSpeeds = {}

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

	-- A unit placed with the match already at 2x starts at the right pace, without
	-- waiting for the next step change to be swept.
	self:applyTimeScale(self.timeScale)

	self.rotationConn = RunService.RenderStepped:Connect(function(dt)
		if not self.model or not self.model.Parent then return end

		--[[
			The scale is read every frame instead of pushed by `SpeedController`: it is a
			comparison, and in exchange the unit does not depend on the order controllers
			start or who notified whom. Same arrangement as
			`MobController:startMovementLoop`, for the same reason.
		]]
		local scale = GameClock.GetScale()
		if scale ~= self.timeScale then
			self:applyTimeScale(scale)
		end

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
