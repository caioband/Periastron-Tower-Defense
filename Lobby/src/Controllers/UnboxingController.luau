local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Signal = require(Packages.Signal)

local CardConfig = SharedConfig.CardConfig
local CrateConfig = SharedConfig.CrateConfig
local RarityConfig = SharedConfig.RarityConfig
local IndexConfig = SharedConfig.IndexConfig

local RANDOM = Random.new()

local Framework = Me.new()
local log = Log.new("UnboxingController")

--[[ CONSTANTS ]]
local CRATES_FOLDER_NAME = "UnboxingCrates"
local TARGET_PART_NAME = "TargetPart"
local HEAD_PART_NAME = "Head"

--[[
	The burst and aura VFX, and the display above the unit's head.

	The burst is a single Emit that lives only for the requested time; the aura stays on
	while the unit is on stage, painted with its rarity's color.

	See docs/lobby/crates-and-unboxing.md.
]]
local CRATE_OPEN_VFX_NAME = "CrateOpen"
local UNIT_AURA_VFX_NAME = "CrateUnitAura"
local UNIT_DISPLAY_NAME = "UnitCrateDisplay"

-- Above the CrateOpen emitters' longest Lifetime (the "Pixel smoke" goes up to
-- 1s): destroying earlier would kill particles still in mid-flight.
local CRATE_OPEN_LIFETIME = 1

-- How long the crate stays up after the burst. It disappears under the
-- effect, instead of the effect appearing over an already empty spot.
local CRATE_BURST_LEAD = 0.2

-- How many particles each emitter releases in the burst. An emitter can ask for another
-- number with the `EmitCount` attribute, without touching this.
local CRATE_OPEN_EMIT_COUNT = 16

-- Placement: the crate lands this far in front of the character, on whatever ground
-- the down ray finds. Everything else here is the "that spot is taken" recovery.
local SPAWN_DISTANCE = 7
local GROUND_RAY_UP = 8
local GROUND_RAY_DEPTH = 40
local GROUND_OFFSET = 0.05

-- Ground more than this far above/below the player's own floor is another platform,
-- not a spot to drop a crate on.
local MAX_GROUND_STEP = 8

-- The clearance box is the crate's own bounds, shrunk so it does not trip on the
-- floor it is standing on or on a wall it is merely touching.
local CLEARANCE_SHRINK = Vector3.new(0.3, 0.3, 0.3)

-- Ring sweep used when the ideal spot is blocked. Samples are ordered
-- forward-first (0, +45, -45, +90, ...) so the crate stays in view.
local FALLBACK_RINGS = { 3, 5, 7, 9 }
local FALLBACK_SAMPLES = 8

-- A ring that sweeps all the way behind lands right back on the player (radius equal
-- to SPAWN_DISTANCE at 180 degrees is exactly where they stand), so candidates that
-- close to them are dropped.
local MIN_PLAYER_DISTANCE = 4

-- Unboxings run side by side, so a new crate also has to keep its distance from the
-- ones already playing. Measured against the billboard (5 studs wide), not the crate
-- bounds -- two reels overlapping reads worse than two crates touching.
--
-- It applies against the whole Lobby's openings, not only the local player's:
-- two people side by side opening at the same time is the common overlap case.
local MIN_CRATE_SPACING = 6

-- Past this many at once the ring sweep runs out of spots that respect the spacing
-- above, and crates would start landing on top of each other. It counts everyone's
-- openings; the player's own goes over the cap (see :Open).
local MAX_ACTIVE_UNBOXINGS = 5

local CRATE_CAN_COLLIDE = false

-- The crate comes out of the player and flies to the spot the placement resolved,
-- growing on the way. A crate that evolves mid-unboxing does NOT replay this -- it
-- swaps in already grown and already there, so the upgrade reads as the same crate
-- changing rather than a new one dropping in.
local SPAWN_SCALE = 0.01
local SPAWN_TIME = 0.4
local SPAWN_GROW_INFO = TweenInfo.new(SPAWN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Quint rather than Back: an overshoot on the way in would push the crate through the
-- floor it is about to stand on.
local SPAWN_TRAVEL_INFO = TweenInfo.new(SPAWN_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

-- Opening: the crate winds up -- shrinking while it rattles for a couple of seconds --
-- and then bursts past its own size, which is the beat the unit appears on. The rattle
-- runs for as long as the windup tween, so its length is what sets the suspense.
local OPEN_WINDUP_SCALE = 0.85
local OPEN_WINDUP_INFO = TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local OPEN_SHAKE_OFFSET = 0.12
local OPEN_BURST_SCALE = 1.4
local OPEN_BURST_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Reel: REEL_LENGTH entries are cloned out of the authored pool, and the reel stops
-- with WINNER_INDEX centered on the Clipper. The tail after it is what keeps the
-- right half of the billboard filled once it lands.
local REEL_LENGTH = 36
local WINNER_TAIL = 4
local WINNER_INDEX = REEL_LENGTH - WINNER_TAIL

local SPIN_TIME = 4.25
local SPIN_INFO = TweenInfo.new(SPIN_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SETTLE_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

-- How far past the winner the reel rolls before settling back onto it, as a
-- fraction of one entry's width.
local OVERSHOOT_FRACTION = 0.08

-- Played every time a card crosses the Clipper (SoundService, via MusicController).
local REEL_TICK_SOUND = "UIHover"

-- Beat between a reel landing on an upgrade and the next one starting, so the crate
-- evolving in front of the player reads.
local UPGRADE_PAUSE = 0.6

-- Reveal: the reel holds on the result for a beat, then the crate is destroyed and the
-- unit takes its place, spinning where it stood.
local REVEAL_DELAY = 0.6
local UNIT_SPIN_SPEED = math.rad(45)
local IDLE_ANIMATION_NAME = "Idle"

-- How long the revealed unit stays up before the whole session is cleaned up.
local RESULT_HOLD = 4

-- The unit on each reel card: an image over the card art, in the unlocked
-- version or the silhouette, depending on the player's Index (`CardConfig`).
local ENTRY_IMAGE_NAME = "UnitImage"

local UnboxingController = {
	Controllers = {
		-- The player's Index (which units they discovered) lives in the profile.
		DataController = {},
		-- The tick of each card passing the Clipper.
		MusicController = {},
	},

	--[[
		Every server opening plays on every screen, so the signals are about anyone's crate:
		`owner` is who opened it, and it is how a listener separates the local player's
		opening from those they are only watching.
	]]
	Signals = {
		-- (result : UnboxingResult, crate : Model, owner : Player)
		UnboxingStarted = Signal.new(),
		-- (result : UnboxingResult, from : string, to : string, crate : Model, owner : Player)
		CrateUpgraded = Signal.new(),
		-- (result : UnboxingResult, entry : GuiObject, crate : Model, owner : Player)
		UnboxingFinished = Signal.new(),
		-- (result : UnboxingResult, unit : Model, owner : Player)
		UnitRevealed = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	Both VFX parts are authored unanchored and colliding, which is fine sitting in
	ReplicatedStorage but not in the world: a clone would fall, and shove whatever
	it touched on the way. Purely decorative, so it also stops answering queries.
]=]
local function prepareVFXPart(part : BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
end

local function flatten(vector : Vector3, fallback : Vector3) : Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-3 then
		return fallback
	end

	return flat.Unit
end

--[=[
	Horizontal center of a GuiObject, in its parent's scale space.
]=]
local function centerOf(gui : GuiObject) : number
	return gui.Position.X.Scale + (0.5 - gui.AnchorPoint.X) * gui.Size.X.Scale
end

--[=[
	Candidate positions in try order: the ideal spot first, then rings of samples
	around it, each ring sweeping outwards from straight ahead.
]=]
local function buildCandidates(idealPosition : Vector3, forward : Vector3) : { Vector3 }
	local candidates = { idealPosition }

	for _, radius in FALLBACK_RINGS do
		for step = 0, FALLBACK_SAMPLES - 1 do
			local sign = (step % 2 == 0) and 1 or -1
			local angle = sign * math.ceil(step / 2) * (math.pi * 2 / FALLBACK_SAMPLES)
			local direction = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(forward)

			table.insert(candidates, idealPosition + direction * radius)
		end
	end

	return candidates
end

--[=[
	The root of the character of whoever opened the crate, not the local player's.

	The crate comes out of it and lands in front of it, on every screen: watchers see the
	crate born from its owner, not from their own feet.
]=]
function UnboxingController:_getRoot(player : Player) : BasePart?
	local character = player and player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[=[
	True when the spot is too close to an unboxing that is already playing.

	The spawned crates are non-queryable on purpose (they must not get in the way of
	anything else that raycasts the world), so the spatial query below cannot see them
	-- the sessions themselves are what tracks the occupied spots.
]=]
function UnboxingController:_isSpotTaken(position : Vector3, extents : Vector3) : boolean
	for _, session in self.Sessions do
		if not session.Position then
			continue
		end

		local horizontal = (position - session.Position) * Vector3.new(1, 0, 1)
		if horizontal.Magnitude < MIN_CRATE_SPACING and math.abs(position.Y - session.Position.Y) < extents.Y then
			return true
		end
	end

	return false
end

--[=[
	Raycast params that ignore every character and the crates we spawned ourselves,
	which are handled by _isSpotTaken instead.
]=]
function UnboxingController:_buildFilter() : { Instance }
	local filter = { self.CratesFolder }

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(filter, player.Character)
		end
	end

	return filter
end

local function findGround(position : Vector3, params : RaycastParams) : RaycastResult?
	local origin = position + Vector3.yAxis * GROUND_RAY_UP
	local direction = Vector3.yAxis * -(GROUND_RAY_UP + GROUND_RAY_DEPTH)

	return workspace:Raycast(origin, direction, params)
end

--[=[
	Finds where the crate goes: in front of the player, standing on the ground, facing
	back at them. The ideal spot is used whenever its volume is empty; otherwise the
	ring sweep looks for a nearby spot that is.
]=]
function UnboxingController:_resolvePlacement(rootPart : BasePart, extents : Vector3) : CFrame
	local forward = flatten(rootPart.CFrame.LookVector, Vector3.zAxis * -1)
	local idealPosition = rootPart.Position + forward * SPAWN_DISTANCE

	local filter = self:_buildFilter()

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = filter
	rayParams.IgnoreWater = true
	rayParams.RespectCanCollide = true

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = filter
	overlapParams.RespectCanCollide = true

	local playerGround = findGround(rootPart.Position, rayParams)
	local referenceY = playerGround and playerGround.Position.Y or rootPart.Position.Y

	local clearanceSize = extents - CLEARANCE_SHRINK
	local firstGrounded : CFrame? = nil

	for _, candidate in buildCandidates(idealPosition, forward) do
		-- The ray is vertical, so the candidate already has the final XZ.
		if ((candidate - rootPart.Position) * Vector3.new(1, 0, 1)).Magnitude < MIN_PLAYER_DISTANCE then
			continue
		end

		local ground = findGround(candidate, rayParams)
		if not ground then
			continue
		end

		if math.abs(ground.Position.Y - referenceY) > MAX_GROUND_STEP then
			continue
		end

		local position = ground.Position + Vector3.yAxis * (extents.Y * 0.5 + GROUND_OFFSET)

		-- Not even as a fallback: landing on another unboxing is worse than clipping
		-- into the scenery.
		if self:_isSpotTaken(position, extents) then
			continue
		end

		local towardPlayer = flatten(rootPart.Position - position, -forward)

		-- The crate models are authored facing +X (that is where the latch is), so the
		-- right vector -- not the look vector -- is what points at the player.
		local cframe = CFrame.fromMatrix(position, towardPlayer, Vector3.yAxis)

		firstGrounded = firstGrounded or cframe

		if #workspace:GetPartBoundsInBox(cframe, clearanceSize, overlapParams) == 0 then
			return cframe
		end
	end

	-- Everything around is occupied: prefer a spot that at least stands on the floor.
	if firstGrounded then
		return firstGrounded
	end

	-- No ground anywhere nearby either: fall back to the player's own feet height.
	local humanoid = rootPart.Parent and rootPart.Parent:FindFirstChildWhichIsA("Humanoid")
	local feetY = rootPart.Position.Y - rootPart.Size.Y * 0.5 - (humanoid and humanoid.HipHeight or 0)
	local position = Vector3.new(idealPosition.X, feetY + extents.Y * 0.5 + GROUND_OFFSET, idealPosition.Z)

	return CFrame.fromMatrix(position, -forward, Vector3.yAxis)
end

--[=[
	Clones the crate model of a rarity and stands it up in the world.

	`cframe` skips the placement search and drops it exactly there -- that is how a
	crate evolves without moving.
]=]
function UnboxingController:_spawnCrate(session, rarity : string, cframe : CFrame?) : Model?
	local modelName = CrateConfig.getModelName(rarity)
	local template = modelName and self.CrateModels:FindFirstChild(modelName)
	if not template or not template:IsA("Model") then
		log:StudioWarn(string.format("no crate model named %q in Assets.CratesModel.", tostring(modelName)))
		return nil
	end

	local rootPart = if cframe then nil else self:_getRoot(session.Owner)
	if not cframe and not rootPart then
		return nil
	end

	local crate = template:Clone()
	for _, descendant in crate:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = CRATE_CAN_COLLIDE
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	local _, extents = crate:GetBoundingBox()
	crate:PivotTo(cframe or self:_resolvePlacement(rootPart :: BasePart, extents))

	crate.Parent = self.CratesFolder
	session.Maid:GiveTask(crate)

	return crate
end

--[=[
	Models cannot be handed to TweenService, so a value object carries the easing and
	drives the model through `apply`.
]=]
local function tweenDriver(valueClass : string, startValue : any, goal : any, info : TweenInfo, apply : (any) -> (), maid) : Tween
	local driver = Instance.new(valueClass)
	driver.Value = startValue

	local connection = driver:GetPropertyChangedSignal("Value"):Connect(function()
		apply(driver.Value)
	end)

	local function stop()
		connection:Disconnect()
		driver:Destroy()
	end

	local tween = TweenService:Create(driver, info, { Value = goal })
	tween.Completed:Once(stop)

	maid:GiveTask(function()
		tween:Cancel()
		stop()
	end)

	tween:Play()
	return tween
end

function UnboxingController:_tweenScale(model : Model, info : TweenInfo, goal : number, maid) : Tween
	return tweenDriver("NumberValue", model:GetScale(), goal, info, function(value : number)
		if model.Parent then
			-- Back easing undershoots, and ScaleTo will not take zero or less.
			model:ScaleTo(math.max(value, SPAWN_SCALE))
		end
	end, maid)
end

function UnboxingController:_tweenPivot(model : Model, info : TweenInfo, goal : CFrame, maid) : Tween
	return tweenDriver("CFrameValue", model:GetPivot(), goal, info, function(value : CFrame)
		if model.Parent then
			model:PivotTo(value)
		end
	end, maid)
end

--[=[
	The crate opening: it shrinks and rattles in place, then bursts past its own size.
	`onComplete` is where the unit takes over.
]=]
function UnboxingController:_playOpenAnimation(session, onComplete : () -> ())
	local crate = session.Crate
	if not crate or not crate.Parent then
		onComplete()
		return
	end

	local baseCFrame = session.CFrame

	local shakeMaid = Maid.new()
	session.Maid:GiveTask(shakeMaid)

	shakeMaid:GiveTask(RunService.RenderStepped:Connect(function()
		if not crate.Parent then
			return
		end

		local offset = Vector3.new(
			RANDOM:NextNumber(-1, 1),
			RANDOM:NextNumber(-1, 1),
			RANDOM:NextNumber(-1, 1)
		) * OPEN_SHAKE_OFFSET

		crate:PivotTo(baseCFrame + offset)
	end))

	local windup = self:_tweenScale(crate, OPEN_WINDUP_INFO, OPEN_WINDUP_SCALE, session.Maid)
	windup.Completed:Once(function(state : Enum.PlaybackState)
		shakeMaid:DoCleaning()

		if session.Closed or state ~= Enum.PlaybackState.Completed or not crate.Parent then
			return
		end

		crate:PivotTo(baseCFrame)

		-- Together with the start of the swell, not its end: the effect is the burst.
		self:_playCrateBurstVFX(session)

		self:_tweenScale(crate, OPEN_BURST_INFO, OPEN_BURST_SCALE, session.Maid)

		--[[
			The deadline counts from the burst, not the end of the swell: the burst is what
			the crate must outlive. The tween lasts less than `CRATE_BURST_LEAD`, so it ends
			before this anyway, and if the session closes midway, `Closed` holds it.
		]]
		task.delay(CRATE_BURST_LEAD, function()
			if session.Closed then
				return
			end

			onComplete()
		end)
	end)
end

--[=[
	The crate's burst: a single Emit of everything inside CrateOpen, at the crate's CFrame.

	The part goes to the unboxings folder, next to the crate and not inside it: the crate
	is destroyed right after, and would take the effect along too early. It stays loose at
	the crate's CFrame, so it remains in the right place when the crate disappears.
]=]
function UnboxingController:_playCrateBurstVFX(session)
	local crate = session.Crate
	if not crate or not crate.Parent then
		return nil
	end

	local vfx = self.CrateOpenVFX:Clone()
	prepareVFXPart(vfx)
	vfx.CFrame = crate:GetPivot()
	vfx.Parent = self.CratesFolder

	for _, emitter in vfx:GetDescendants() do
		if emitter:IsA("ParticleEmitter") then
			emitter:Emit(emitter:GetAttribute("EmitCount") or CRATE_OPEN_EMIT_COUNT)
		end
	end

	-- In the maid too: closing the session before the deadline must not leave the effect behind.
	session.Maid:GiveTask(vfx)
	task.delay(CRATE_OPEN_LIFETIME, function()
		vfx:Destroy()
	end)

	return vfx
end

--[=[
	The aura that stays on the revealed unit, in its rarity's color.

	It goes in as the unit's child on purpose: the reveal's spin is a `PivotTo` on the
	whole model, so the aura follows with no code of its own, and disappears when the unit
	does.
]=]
function UnboxingController:_attachUnitAura(unit : Model, rarity : string?) : BasePart?
	local rootPart = unit.PrimaryPart or unit:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		log:StudioWarn(string.format("%s has no root part for the aura VFX.", unit.Name))
		return nil
	end

	local aura = self.UnitAuraVFX:Clone()
	prepareVFXPart(aura)
	aura.CFrame = rootPart.CFrame

	local color = RarityConfig.getColor(rarity)
	for _, emitter in aura:GetDescendants() do
		if emitter:IsA("ParticleEmitter") then
			emitter.Enabled = true
			if color then
				emitter.Color = ColorSequence.new(color)
			end
		end
	end

	aura.Parent = unit

	return aura
end

--[=[
	The display above the revealed unit's head.

	The template is an Attachment, so the head is its direct parent and the BillboardGui
	inside anchors itself. Both labels are filled in here: that is what they exist for.
]=]
function UnboxingController:_attachUnitDisplay(unit : Model, unitName : string, rarity : string?) : Attachment?
	local head = unit:FindFirstChild(HEAD_PART_NAME)
	if not head or not head:IsA("BasePart") then
		log:StudioWarn(string.format("%s has no %s for the crate display.", unit.Name, HEAD_PART_NAME))
		return nil
	end

	local display = self.UnitDisplayTemplate:Clone()

	local billboard = display:FindFirstChildWhichIsA("BillboardGui")
	if billboard then
		local nameLabel = billboard:FindFirstChild("UnitName")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = unitName
		end

		local rarityLabel = billboard:FindFirstChild("Rarity")
		if rarityLabel and rarityLabel:IsA("TextLabel") then
			local tier = rarity and RarityConfig.TIERS[rarity]
			rarityLabel.Text = tier and tier.DisplayName or (rarity or "")

			local color = RarityConfig.getColor(rarity)
			local stroke = rarityLabel:FindFirstChildOfClass("UIStroke")
			if stroke and color then
				stroke.Color = color
			end
		end
	end

	display.Parent = head

	return display
end

--[=[
	Evolves the crate: same spot, same billboard, heavier model.
]=]
function UnboxingController:_swapCrate(session, crateRarity : string) : Model?
	local crate = self:_spawnCrate(session, crateRarity, session.CFrame)
	if not crate then
		return nil
	end

	local targetPart = crate:FindFirstChild(TARGET_PART_NAME)
	if not targetPart or not targetPart:IsA("BasePart") then
		log:StudioWarn(string.format("%s has no %s.", crate.Name, TARGET_PART_NAME))
		crate:Destroy()
		return nil
	end

	-- The reel lives under the attachment, so moving it over keeps the spin going.
	session.Attachment.Parent = targetPart
	session.Crate:Destroy()
	session.Crate = crate

	return crate
end

--[=[
	Closes the unboxing on the prize: the crate is destroyed so it is not standing in
	the way, and the unit takes its spot, spinning and playing its idle.

	The crate only comes down once the unit is built and ready to be parented, so a
	missing model never leaves the player looking at nothing.
]=]
function UnboxingController:_revealUnit(session, unitName : string) : Model?
	local template = self.UnitModels:FindFirstChild(unitName)
	if not template or not template:IsA("Model") then
		log:StudioWarn(string.format("no unit model named %q in Assets.Units.", tostring(unitName)))
		return nil
	end

	local unit = template:Clone()

	for _, descendant in unit:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	-- Only the root is anchored, exactly how the models are authored: the limbs hang
	-- off it through their Motor6Ds, which is what lets the idle drive them while the
	-- model itself stays put.
	local rootPart = unit.PrimaryPart or unit:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		rootPart.Anchored = true
	end

	-- Stand it where the crate was: same spot, feet on the same ground, facing the
	-- player the way the crate did (the crate faces them with its +X).
	local boundsCFrame, extents = unit:GetBoundingBox()
	local feetOffset = unit:GetPivot().Position.Y - (boundsCFrame.Position.Y - extents.Y * 0.5)

	local crateCFrame = session.CFrame
	local position = Vector3.new(
		crateCFrame.Position.X,
		session.GroundY + feetOffset,
		crateCFrame.Position.Z
	)

	local facing = CFrame.lookAt(position, position + crateCFrame.RightVector)
	unit:PivotTo(facing)

	if session.Crate then
		session.Crate:Destroy()
		session.Crate = nil
	end

	unit.Parent = self.CratesFolder
	session.Unit = unit
	session.Maid:GiveTask(unit)

	--[[
		The unit models are Motor6D rigs with no Humanoid at all: in the match an
		`AnimationController`, created on the spot by the `Unit` class, plays their tracks.
		Here it is the same: looking for a Humanoid would find nothing and fall into the
		warning, leaving the unit frozen at the end of the unboxing.

		The track only goes in after `unit.Parent`: an Animator outside the DataModel is not
		evaluated, so playing before the unit is on stage would move nothing.
	]]
	local idle = unit:FindFirstChild(IDLE_ANIMATION_NAME)

	if idle and idle:IsA("Animation") then
		local animationController = unit:FindFirstChildWhichIsA("AnimationController")
			or unit:FindFirstChildWhichIsA("Humanoid")

		if not animationController then
			animationController = Instance.new("AnimationController")
			animationController.Parent = unit
		end

		local animator = animationController:FindFirstChildWhichIsA("Animator") or Instance.new("Animator")
		animator.Parent = animationController

		local track = animator:LoadAnimation(idle)
		track.Looped = true
		track:Play()

		session.Maid:GiveTask(function()
			track:Stop()
		end)
	else
		log:StudioWarn(string.format("%s has no %s animation.", unitName, IDLE_ANIMATION_NAME))
	end

	-- The rarity comes from the unit's own catalog, not the roll result: it is its
	-- rarity that the aura and the display announce.
	local stats = SharedConfig.UnitStats[unitName]
	local rarity = RarityConfig.resolve(stats and stats.Rarity)
	if not rarity then
		log:StudioWarn(string.format("%s has no valid Rarity in UnitStats.", unitName))
	end

	self:_attachUnitAura(unit, rarity)

	-- The aura and the spin are the unit appearing, and everyone sees that. Its name and
	-- rarity are the result, and the result belongs to the opener.
	if session.IsOwner then
		self:_attachUnitDisplay(unit, unitName, rarity)
	end

	local spin = 0
	session.Maid:GiveTask(RunService.RenderStepped:Connect(function(deltaTime : number)
		spin += deltaTime * UNIT_SPIN_SPEED
		unit:PivotTo(facing * CFrame.Angles(0, spin, 0))
	end))

	return unit
end

--[=[
	Clones the authored attachment into the crate's TargetPart. The attachment already
	carries its own offset, so it lands above the crate on its own.
]=]
function UnboxingController:_attachBillboard(crate : Model, sessionMaid) : Attachment?
	local targetPart = crate:FindFirstChild(TARGET_PART_NAME)
	if not targetPart or not targetPart:IsA("BasePart") then
		log:StudioWarn(string.format("%s has no %s.", crate.Name, TARGET_PART_NAME))
		return nil
	end

	local attachment = self.AttachmentTemplate:Clone()
	attachment.Parent = targetPart
	sessionMaid:GiveTask(attachment)

	return attachment
end

--[[ UNITS ON THE REEL ]]

--[=[
	What the player already discovered in `Index.Units`, straight from the replica.

	A profile that has not arrived counts as "nothing discovered", the same agreement as
	`IndexConfig`. In practice that does not happen for one's own crate (to open one the
	profile has already loaded), but the reel of someone only watching goes through here
	too.
]=]
function UnboxingController:_discoveredUnits() : { [string]: boolean }
	local dataController = self.Controllers.DataController
	if not dataController or not dataController.GetReplica then return {} end

	local ok, replica = pcall(function()
		return dataController:GetReplica()
	end)

	if not ok or not replica then return {} end

	return IndexConfig.entriesOf(replica.Data, "Units")
end

--[=[
	The card's unit, over its art.

	Two arts per unit in `CardConfig`: the unlocked one and the silhouette. The player's
	Index says which goes in, and since the pair comes ready from the config, "locked" here
	is just picking the other id.

	A unit with no pair in the config gets no image: the card keeps only the frame in the
	rarity's color.
]=]
function UnboxingController:_createEntryImage(entry : GuiObject, unitName : string, discovered : boolean)
	local image = CardConfig.GetIndexImage(unitName, discovered)
	if not image then
		return nil
	end

	local label = Instance.new("ImageLabel")
	label.Name = ENTRY_IMAGE_NAME
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Image = image

	-- The card is not square and the unit art is: `Fit` leaves its proportion
	-- alone, fitting by whichever side is tighter instead of stretching.
	label.ScaleType = Enum.ScaleType.Fit

	-- Pixel art: without `Pixelated` the filter blurs the art when scaling, and the reel
	-- card is small; the rest of the game's UI already uses this mode.
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	label.ZIndex = entry.ZIndex + 1
	label.Parent = entry

	return label
end

--[=[
	A face is what one reel entry shows: either a unit rarity, or the crate upgrading.

	`Upgrade` carries the crate it becomes -- the same thing the server rolls -- so an
	entry can be read back off the reel.

	`Unit` is who appears in 3D on the card. On a filler it is any unit of the drawn
	rarity; on the winning card it is exactly the one the server gave. An upgrade face has
	no unit: there the card is the crate upgrading, not a unit.
]=]
export type ReelFace = {
	Rarity : string?,
	Upgrade : string?,
	Unit : string?,
}

--[=[
	Any unit of the rarity, for a filler card to show.

	Each tier's units come from `UnitStats` itself (`getUnitsOfRarity`), which is what the
	server also uses to draw the prize, so the reel shows the same cast the result comes
	from. A rarity with no unit at all returns nil, and the card keeps only the tier's art
	and color.
]=]
local function rollFillerUnit(rarity : string) : string?
	local units = RarityConfig.getUnitsOfRarity(rarity)

	if not units or #units == 0 then
		return nil
	end

	return units[RANDOM:NextInteger(1, #units)]
end

--[=[
	Picks a face to show as filler, weighted by RarityConfig.ReelWeight and, for the
	upgrade card, CrateConfig.UPGRADE_REEL_WEIGHT.

	Business rule: a crate only ever shows the upgrade it can actually give, so a
	Legendary crate (which upgrades into nothing) never shows one.

	Filler only -- what the player actually gets was rolled by the server, out of the
	crate pool, and lands on WINNER_INDEX.
]=]
local function rollFillerFace(crateRarity : string) : ReelFace
	local upgradesTo = CrateConfig.getNextRarity(crateRarity)
	local upgradeWeight = upgradesTo and CrateConfig.UPGRADE_REEL_WEIGHT or 0

	local total = upgradeWeight
	for _, rarity in RarityConfig.ORDER do
		total += RarityConfig.TIERS[rarity].ReelWeight or 0
	end

	if total <= 0 then
		return { Rarity = RarityConfig.ORDER[1] }
	end

	local roll = RANDOM:NextNumber(0, total)
	local cumulative = upgradeWeight

	if roll < cumulative then
		return { Upgrade = upgradesTo }
	end

	for _, rarity in RarityConfig.ORDER do
		cumulative += RarityConfig.TIERS[rarity].ReelWeight or 0
		if roll < cumulative then
			return { Rarity = rarity, Unit = rollFillerUnit(rarity) }
		end
	end

	local fallback = RarityConfig.ORDER[1]
	return { Rarity = fallback, Unit = rollFillerUnit(fallback) }
end

--[=[
	Rebuilds the ScrollingFrame contents into a long reel for `crateRarity`, landing on
	`winnerFace`. The entries the designer left in the ScrollingFrame are the art pool
	for rarities; the upgrade cards come from UpgradeCrateUnboxingTemplates.

	A pool entry named after a rarity is used as the template for it, so the pool can
	carry per-tier art later; anything else is interchangeable art and the tint does
	the work. The upgrade cards are authored with their own colours, so those are
	left alone.

	Returns a small handle with everything the spin needs: the frame to move, the
	entries, and a mapping from entry index to the frame position that centers it
	on the Clipper.
]=]
function UnboxingController:_buildReel(session, crateRarity : string, winnerFace : ReelFace)
	local billboard = session.Attachment:FindFirstChildWhichIsA("BillboardGui")
	local frame = billboard and billboard:FindFirstChild("Frame")
	local scrollingFrame = frame and frame:FindFirstChild("ScrollingFrame")

	if not scrollingFrame or not scrollingFrame:IsA("ScrollingFrame") then
		log:StudioWarn("UnboxingAttachment.BillboardGui.Frame.ScrollingFrame is missing.")
		return nil
	end

	-- Captured once per session: on a later stage the ScrollingFrame holds the entries
	-- the previous spin left behind, not the art the designer authored.
	local pool = session.Pool

	if not pool then
		pool = {}
		for _, child in scrollingFrame:GetChildren() do
			if child:IsA("GuiObject") then
				table.insert(pool, child)

				-- Out of the layout, but kept alive as a template for the reel entries.
				child.Parent = nil
				session.Maid:GiveTask(child)
			end
		end

		session.Pool = pool
	else
		for _, child in scrollingFrame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	if #pool == 0 then
		log:StudioWarn("ScrollingFrame has no entries to build the reel from.")
		return nil
	end

	local layout = scrollingFrame:FindFirstChildWhichIsA("UIListLayout")
	local clipper = frame:FindFirstChild("Clipper")

	-- Entry widths are authored in scale, relative to the ScrollingFrame, and the list
	-- layout padding is what actually spaces them apart.
	local entryWidth = pool[1].Size.X.Scale
	local step = entryWidth + (layout and layout.Padding.Scale or 0)

	local frameWidth = scrollingFrame.Size.X.Scale
	local anchorX = scrollingFrame.AnchorPoint.X
	local targetCenter = clipper and clipper:IsA("GuiObject") and centerOf(clipper) or 0.5

	-- An entry the designer named after a rarity becomes the template for that tier.
	local templates = {}
	for _, entry in pool do
		local named = RarityConfig.resolve(entry.Name)
		if named then
			templates[named] = entry
		end
	end

	local entries = table.create(REEL_LENGTH)
	for index = 1, REEL_LENGTH do
		local face = index == WINNER_INDEX and winnerFace or rollFillerFace(crateRarity)
		local entry

		if face.Upgrade then
			-- The upgrade cards are authored per destination crate, colour included.
			local template = self.UpgradeTemplates:FindFirstChild(face.Upgrade)
			entry = template and template:Clone()
		end

		if not entry then
			local rarity = face.Rarity or RarityConfig.ORDER[1]
			entry = (templates[rarity] or pool[RANDOM:NextInteger(1, #pool)]):Clone()

			local color = RarityConfig.getColor(rarity)
			if color and entry:IsA("ImageLabel") then
				entry.ImageColor3 = color
			elseif color then
				entry.BackgroundColor3 = color
			end
		end

		entry.Name = string.format("ReelEntry_%02d", index)
		entry.LayoutOrder = index
		entry.Visible = true

		-- Keep the sizing of the pool: an upgrade card authored a hair off would
		-- otherwise break the step the spin maths is built on.
		entry.Size = pool[1].Size

		entry:SetAttribute("Rarity", face.Rarity)
		entry:SetAttribute("Upgrade", face.Upgrade)
		entry:SetAttribute("Unit", face.Unit)
		entry.Parent = scrollingFrame

		-- Only on the opener's screen: on the others the billboard stays off for the whole
		-- spin, and Roblox draws none of it.
		if face.Unit and session.IsOwner then
			self:_createEntryImage(entry, face.Unit, session.Discovered[face.Unit] == true)
		end

		entries[index] = entry
	end

	--[=[
		Frame position (scale) that puts entry `index` right under the Clipper.
	]=]
	local function positionFor(index : number) : number
		local offset = ((index - 1) * step + entryWidth * 0.5) * frameWidth
		return targetCenter + anchorX * frameWidth - offset
	end

	--[=[
		The inverse of `positionFor`: which card is under the Clipper with the frame at `x`.
		It switches at the border between two cards, which is the instant the tick sounds.
	]=]
	local function indexAt(x : number) : number
		local offset = (targetCenter + anchorX * frameWidth - x) / frameWidth
		return math.floor(offset / step) + 1
	end

	return {
		ScrollingFrame = scrollingFrame,
		Entries = entries,
		EntryWidth = entryWidth * frameWidth,
		PositionFor = positionFor,
		IndexAt = indexAt,
	}
end

--[=[
	The reel tick: one sound per card crossing the Clipper, from the spin to the settle.

	At most once per frame: at the start of the spin several cards pass in a single frame,
	and stacking one sound per card would become noise. Only on the opener's screen: on
	the others the reel spins behind a disabled billboard.
]=]
function UnboxingController:_trackReelTicks(reel, maid)
	local scrollingFrame = reel.ScrollingFrame
	local lastIndex = reel.IndexAt(scrollingFrame.Position.X.Scale)

	local connection = RunService.RenderStepped:Connect(function()
		local index = reel.IndexAt(scrollingFrame.Position.X.Scale)
		if index == lastIndex then
			return
		end

		lastIndex = index

		local music = self.Controllers.MusicController
		if music then
			music:PlaySFX(REEL_TICK_SOUND)
		end
	end)

	maid:GiveTask(connection)
	return connection
end

function UnboxingController:_spin(reel, sessionMaid, onFinished : (GuiObject) -> (), withTicks : boolean?)
	local scrollingFrame = reel.ScrollingFrame
	local basePosition = scrollingFrame.Position

	local function positionAt(x : number) : UDim2
		return UDim2.new(x, 0, basePosition.Y.Scale, basePosition.Y.Offset)
	end

	local winnerIndex = math.clamp(WINNER_INDEX, 1, #reel.Entries)
	local winnerEntry = reel.Entries[winnerIndex]
	local winnerPosition = reel.PositionFor(winnerIndex)

	scrollingFrame.Position = positionAt(reel.PositionFor(1))

	-- Roll slightly past the winner, then settle back onto it.
	local spin = TweenService:Create(scrollingFrame, SPIN_INFO, {
		Position = positionAt(winnerPosition - reel.EntryWidth * OVERSHOOT_FRACTION),
	})

	local settle = TweenService:Create(scrollingFrame, SETTLE_INFO, {
		Position = positionAt(winnerPosition),
	})

	sessionMaid:GiveTask(function()
		spin:Cancel()
		settle:Cancel()
	end)

	spin.Completed:Once(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed then
			return
		end

		settle:Play()
	end)

	-- It starts after repositioning onto the first card, so the jump to it
	-- does not count as a card passing.
	local ticks = withTicks and self:_trackReelTicks(reel, sessionMaid)

	settle.Completed:Once(function(state : Enum.PlaybackState)
		if ticks then
			ticks:Disconnect()
		end

		if state ~= Enum.PlaybackState.Completed then
			return
		end

		onFinished(winnerEntry)
	end)

	spin:Play()

	return winnerEntry
end

--[=[
	One unboxing = one session: its own maid, the spot it took, and who opened it.

	`IsOwner` decides what this screen shows: the opener sees the reel and the unit's name,
	watchers see only the crate, the burst, and the prize.
]=]
function UnboxingController:_openSession(owner : Player)
	self.SessionCount += 1

	local session = {
		Id = self.SessionCount,
		Maid = Maid.new(),
		Position = nil :: Vector3?,
		Closed = false,
		Owner = owner,
		IsOwner = owner == Players.LocalPlayer,

		--[[
			The local player's Index, read once: it decides which units appear as
			silhouettes. One read per session, not per card: the crate opened now does not
			change what they already discovered mid-spin (the server writes the winning unit
			to the profile, and its reel is already built).
		]]
		Discovered = {},
	}

	if session.IsOwner then
		session.Discovered = self:_discoveredUnits()
	end

	table.insert(self.Sessions, session)

	-- Hanging the session maid on the controller maid keeps everything cleaned up if
	-- the controller itself goes away mid-roll.
	self.Maid["Session_" .. session.Id] = session.Maid

	session.Maid:GiveTask(function()
		local index = table.find(self.Sessions, session)
		if index then
			table.remove(self.Sessions, index)
		end
	end)

	return session
end

function UnboxingController:_closeSession(session)
	if session.Closed then
		return
	end

	session.Closed = true
	self.Maid["Session_" .. session.Id] = nil
end

--[[ EXTERNAL ]]

export type UnboxingResult = {
	Crate : string,
	Upgrades : { string },
	Rarity : string,
	Unit : string?,
}

--[=[
	Plays one spin of a session, then hands over to the next stage.

	A stage that lands on an upgrade evolves the crate and lets the pool of the crate
	it became take over -- that is the "a crate can upgrade" rule, played out one
	reel at a time. The last stage is always the reward.
]=]
function UnboxingController:_playStage(session, result : UnboxingResult, stages, index : number)
	local stage = stages[index]
	if session.Closed or not stage then
		return
	end

	local reel = self:_buildReel(session, stage.Crate, stage.Face)
	if not reel then
		self:_closeSession(session)
		return
	end

	self:_spin(reel, session.Maid, function(entry : GuiObject)
		if session.Closed then
			return
		end

		if not stage.Face.Upgrade then
			self.Signals.UnboxingFinished:Fire(result, entry, session.Crate, session.Owner)

			-- A beat on the landed reel, the crate cracks open, and the unit takes over.
			task.delay(REVEAL_DELAY, function()
				if session.Closed then
					return
				end

				self:_playOpenAnimation(session, function()
					if session.Closed then
						return
					end

					local unit = result.Unit and self:_revealUnit(session, result.Unit)
					if unit then
						self.Signals.UnitRevealed:Fire(result, unit, session.Owner)
					end

					task.delay(RESULT_HOLD, function()
						self:_closeSession(session)
					end)
				end)
			end)

			return
		end

		task.delay(UPGRADE_PAUSE, function()
			if session.Closed then
				return
			end

			if not self:_swapCrate(session, stage.Face.Upgrade) then
				self:_closeSession(session)
				return
			end

			self.Signals.CrateUpgraded:Fire(result, stage.Crate, stage.Face.Upgrade, session.Crate, session.Owner)
			self:_playStage(session, result, stages, index + 1)
		end)
	end, session.IsOwner)
end

--[=[
	Spawns the crate in front of `owner` and rolls the unboxing reel on top of it,
	landing on `result.Rarity`.

	`result` is what CrateService rolled: the odds live on the server, so this only
	plays what it is told. Unboxings stack -- calling this again while others are
	still rolling starts another one beside them, up to MAX_ACTIVE_UNBOXINGS.

	`owner` is who opened the crate, and the server sends the same opening to everyone: on a
	screen that is not theirs, this runs the same, just without the reel and the unit's
	name. Without `owner` the opening belongs to the local player: that is how the console
	asks for one.

	Each client resolves the crate's spot on its own, from the owner's character. The
	point may come out slightly different from screen to screen (another player's character
	position arrives interpolated), and that is on purpose: what the scene needs to say is
	"the crate belongs to that player over there", not an exact centimeter.

	Returns false when it could not start (bad result, no character, missing asset,
	or too many already playing).
]=]
function UnboxingController:Open(result : UnboxingResult, owner : Player?) : boolean
	if typeof(result) ~= "table" then
		log:StudioWarn("open expects the result table rolled by CrateService.")
		return false
	end

	owner = owner or Players.LocalPlayer
	local isOwner = owner == Players.LocalPlayer

	-- The crate the player opened. If it evolved, the reel lands on the upgrade card
	-- and the crate is swapped mid-unboxing, one stage per step.
	local crateRarity = CrateConfig.resolveRarity(result.Crate)
	if not crateRarity then
		log:StudioWarn(string.format("%q is not a valid crate rarity.", tostring(result.Crate)))
		return false
	end

	local winnerRarity = RarityConfig.resolve(result.Rarity)
	if not winnerRarity then
		log:StudioWarn(string.format("%q is not a valid rarity.", tostring(result.Rarity)))
		return false
	end

	--[[
		The cap applies to other players' crates. The one the local player opened is the one
		they paid to see, so it goes in even with the Lobby full of openings: leaving out
		exactly theirs would be the only case where missing the scene matters.
	]]
	if not isOwner and #self.Sessions >= MAX_ACTIVE_UNBOXINGS then
		return false
	end

	-- The owner's character, not the local one: a watcher may see the crate of someone
	-- still loading in front of them.
	if not self:_getRoot(owner :: Player) then
		log:StudioWarn(string.format("%s has no character spawned yet.", (owner :: Player).Name))
		return false
	end

	local session = self:_openSession(owner :: Player)

	local crate = self:_spawnCrate(session, crateRarity)
	if not crate then
		self:_closeSession(session)
		return false
	end

	-- Where the crate ended up is what the next unboxing has to keep away from, and
	-- where the evolved models are dropped as it upgrades.
	session.Crate = crate
	session.CFrame = crate:GetPivot()
	session.Position = session.CFrame.Position

	-- Where the crate is standing, so the unit that replaces it lands on the same floor.
	local _, crateExtents = crate:GetBoundingBox()
	session.GroundY = session.Position.Y - crateExtents.Y * 0.5

	local attachment = self:_attachBillboard(crate, session.Maid)
	if not attachment then
		self:_closeSession(session)
		return false
	end

	session.Attachment = attachment

	-- One spin per upgrade the crate went through, then the spin for the reward.
	local stages = {}
	local stageCrate = crateRarity

	for _, upgradeTo in result.Upgrades or {} do
		local resolvedUpgrade = CrateConfig.resolveRarity(upgradeTo)
		if not resolvedUpgrade then
			log:StudioWarn(string.format("%q is not a valid crate rarity.", tostring(upgradeTo)))
			continue
		end

		table.insert(stages, { Crate = stageCrate, Face = { Upgrade = resolvedUpgrade } })
		stageCrate = resolvedUpgrade
	end

	table.insert(stages, { Crate = stageCrate, Face = { Rarity = winnerRarity, Unit = result.Unit } })

	--[[
		The reel is hidden while the crate grows in: the attachment offset scales with
		the model, so an enabled billboard would climb up along with it.

		On a screen that is not the owner's it is never turned on. The reel is still built
		and spun the same way (its spin sets the timing of the whole opening, from the swell
		to the prize), just behind a disabled BillboardGui, which Roblox does not draw. A
		single path for both screens, and both finish at the same instant.
	]]
	local billboard = attachment:FindFirstChildWhichIsA("BillboardGui")
	if billboard then
		billboard.Enabled = false
	end

	-- Shrunk and pulled back onto the player before anyone hears about it, so a
	-- listener never catches it full size or already standing on its spot.
	crate:ScaleTo(SPAWN_SCALE)

	-- It leaves the player with the rotation it will land with -- only the position
	-- travels, so it does not spin on the way in and fight the reel that follows.
	local rootPart = self:_getRoot(session.Owner)
	if rootPart then
		crate:PivotTo(session.CFrame.Rotation + rootPart.Position)
		self:_tweenPivot(crate, SPAWN_TRAVEL_INFO, session.CFrame, session.Maid)
	end

	self.Signals.UnboxingStarted:Fire(result, crate, session.Owner)

	local grow = self:_tweenScale(crate, SPAWN_GROW_INFO, 1, session.Maid)
	grow.Completed:Once(function(state : Enum.PlaybackState)
		if session.Closed or state ~= Enum.PlaybackState.Completed then
			return
		end

		-- Both tweens run the same length, but the pivot is snapped so float drift
		-- never leaves the crate a hair off the spot the rest of the flow uses.
		crate:PivotTo(session.CFrame)

		if billboard and session.IsOwner then
			billboard.Enabled = true
		end

		self:_playStage(session, result, stages, 1)
	end)

	return true
end

--[=[
	Tears down every unboxing playing right now: crates, attachments and tweens.
]=]
function UnboxingController:CancelAll()
	for index = #self.Sessions, 1, -1 do
		self:_closeSession(self.Sessions[index])
	end
end

function UnboxingController:construct()
	local Assets = Shared:WaitForChild("Assets")

	local UI = Assets:WaitForChild("UI")

	local VFX = Assets:WaitForChild("VFX")

	self.CrateModels = Assets:WaitForChild("CratesModel")
	self.UnitModels = Assets:WaitForChild("Units")
	self.AttachmentTemplate = UI:WaitForChild("UnboxingAttachment")

	self.CrateOpenVFX = VFX:WaitForChild(CRATE_OPEN_VFX_NAME)
	self.UnitAuraVFX = VFX:WaitForChild(UNIT_AURA_VFX_NAME)
	self.UnitDisplayTemplate = UI:WaitForChild(UNIT_DISPLAY_NAME)

	-- One card per crate an unboxing can evolve into, named after it.
	self.UpgradeTemplates = UI:WaitForChild("UpgradeCrateUnboxingTemplates")

	local folder = Instance.new("Folder")
	folder.Name = CRATES_FOLDER_NAME
	folder.Parent = workspace

	self.CratesFolder = folder
	self.Maid:GiveTask(folder)

	-- The roll itself is server side (CrateService), so this is the only way an
	-- unboxing legitimately starts.
	Framework:Listen("PlayUnboxing", function(result : UnboxingResult, owner : Player)
		self:Open(result, owner)
	end)
end

function UnboxingController:start()

end

function UnboxingController:init()
	self.Maid = Maid.new()

	self.Sessions = {}
	self.SessionCount = 0

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return UnboxingController
