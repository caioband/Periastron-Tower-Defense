local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = Shared:WaitForChild("Assets")

local DEFAULT_SPEED = 60
local MAX_FLIGHT_TIME = 3
local ARRIVE_DISTANCE = 1

--[[
	How far a piercing projectile keeps flying, in studs, when the unit's
	`Projectile.PierceRange` does not say otherwise.

	It does not stop at the target (that is what "piercing" means), so it needs its
	own end. It is comfortably more than any unit's range in the table: the arrow
	vanishing in the air after passing the last enemy is the right drawing, and the
	server decides who took damage, cutting at the real range.
]]
local PIERCE_DISTANCE = 24

--- The `Projectile.Subtype` value that makes the projectile pierce.
local PIERCING = "Piercing"

--[[
	The attachment a projectile can carry with its burst inside.

	It is optional and belongs to the **asset**, not config: a projectile with an
	attachment by this name bursts on arrival, and one without it vanishes as usual.
	`PyreProjectile` has two attachments: `Ball`, with the enabled emitters that make
	the trail, and `Explosion`, with the disabled ones that only fire on impact.

	A disabled emitter does not appear on its own: `Emit` makes it appear, so the
	artist can leave both groups on the same part without one getting in the other's
	way.
]]
local IMPACT_ATTACHMENT = "Explosion"

--- How many particles per emitter when the asset does not say. The same as `VFXController`.
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
	Bursts the projectile where it stopped, instead of removing it right away.

	Three things at once: the trail stops emitting, the burst fires, and the shell
	vanishes, leaving only the particles in the air. Without stopping the trail the
	projectile would keep spitting fire in place during the burst; without hiding the
	shell the little ball would hover in the middle of the explosion.

	Returns how long the particles still live, so the caller knows when it can really
	destroy it: destroying along with `Emit` kills the particles before they are born.
	Returns `nil` when the projectile has no burst, and then it takes the usual path.

	The deadline is **screen** time, not match time: `ParticleEmitter` does not know
	`GameClock`, so the particles last the same 2 real seconds at 1x and 2x, and
	`task.delay` matches them.
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
		The shell leaves the scene, not the attachment: the already-emitted particles
		live attached to it, and destroying the part now would take the burst with it.

		`Anchored` because the flight loop just released the projectile: the template
		comes with `Anchored = false` and `CanCollide = true`, and without this the
		invisible ball would fall (and bump into things) during the two-second burst.
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
	Removes the projectile from the scene: with a burst, it stays until the particles
	die; without one, it goes now.
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
	A piercing projectile's flight: straight, no homing, and no stopping at the target.

	The difference from a regular shot is not only the end. A regular projectile
	**homes**: it recomputes the target every frame and curves after it, and a piercing
	arrow cannot do that: the direction is frozen at firing, at the unit's aim, or it
	would curve toward the first enemy instead of drawing the line along which the
	others take damage.

	`onArrive` fires when it **passes** where the target was, not when it dies: that
	is where the hit effect belongs. After that it continues a bit more and vanishes
	on its own.

	Who takes damage is not decided here. The server already resolved that in
	`UnitService:executeAttack`, on the same line and with the unit's real range; only
	the drawing comes from here.
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
			-- `finish` only goes through the first time; later calls do nothing.
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
			Arriving is hitting; running out the clock is giving up. They are different,
			and only the first deserves the burst: a projectile that spent 3 seconds in
			the air without reaching anyone did not explode on anything.
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
