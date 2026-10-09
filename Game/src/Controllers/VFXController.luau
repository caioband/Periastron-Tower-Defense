local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

--[[
	Third-party VFX module (ReplicatedStorage.vfx). It refuses to run outside the client
	on its own, and it knows how to build the bolt from the asset's attributes.
]]
local VFX = require(ReplicatedStorage:WaitForChild("vfx"))

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Framework = Me.new()
local log = Log.new("VFXController")

local WeatherConfig = SharedConfig.WeatherConfig
local ThunderConfig = WeatherConfig.Thunder
local RoundCardConfig = SharedConfig.RoundCardConfig

local DEFAULT_LIFETIME = 2
local DEFAULT_EMIT_COUNT = 25

-- The Entrepreneur aura's little money burst: the asset in `Assets.VFX` and the
-- unit Part it hangs on.
local MONEY_VFX_NAME = "MoneyEntrepreneur"
local UNIT_ROOT_NAME = "HumanoidRootPart"

-- Cleanup deadline for when the module itself cannot say how long the effect lasts
-- (an asset with no particles, or with an infinite `EmitDuration`).
local MONEY_VFX_FALLBACK = 3

-- States drawn over a whole model (`playModelStatus`): the freeze (the
-- Frostione's on enemies and weather's on units), the Pyre's burn, and the
-- Slasher's and Berserker's bleed. The asset in `Assets.VFX`, its Highlight's name after
-- moving to the model, and the cleanup for when the `vfx` module cannot say
-- how long the particles last.
local ICED_VFX_NAME = "IcedVFX"
local ICED_HIGHLIGHT_NAME = "IcedHighlight"
local BURNING_VFX_NAME = "BurningVFX"
local BURNING_HIGHLIGHT_NAME = "BurningHighlight"
local BLEED_VFX_NAME = "BleedVFX"
local BLEED_HIGHLIGHT_NAME = "BleedHighlight"
local STATUS_VFX_FALLBACK = 2

-- The Cryomancer's ring slow (`holdModelStatus`): no deadline, it lasts while the enemy
-- is inside a ring. The asset has no Highlight today; the name is there if it gets one.
local FROZEN_AURA_VFX_NAME = "FrozenAuraVFX"
local FROZEN_AURA_HIGHLIGHT_NAME = "FrozenAuraHighlight"

-- The Volt's charge (`PlayStatic`): held on the enemy while the charge lasts, with a
-- burst on each hit and pulse. The asset has no Highlight today; the name is there if it
-- gets one.
local SHOCKED_AURA_VFX_NAME = "ShockedAuraVFX"
local SHOCKED_AURA_HIGHLIGHT_NAME = "ShockedAuraHighlight"

-- How long `SetFrozenAura` keeps waiting for an enemy model that has not spawned yet.
local FROZEN_AURA_RETRIES = 10
local FROZEN_AURA_RETRY_DELAY = 0.1

--[=[
	The impact at the tip of the Electro's bolt, much smaller than the weather bolt's.

	The asset is the same (`LightningBeam`), and the addon keeps what happens where the
	bolt lands in the **tip** Attachment: the `CraterVFX` tag with `Count = 40` of
	debris, plus the `CameraShake` and `ImpactFrames` attributes. Authored that way, it
	is a bolt falling from the sky, which is what the weather wants.

	The `Size` here is a bit more than half the authored one (1.8 against 3 in length),
	not a third: with debris too small, the mark on the ground vanished mid-wave and the
	bolt looked like it touched nothing.

	In a chain that happens **per link**: four tips on the same frame are four camera
	shakes, four impact frames, and 160 pieces of debris per hit. A tower's hit must not
	hijack the player's screen like that, least of all one that repeats the whole match.
	The crater stays, small: it marks where the bolt touched the ground.

	The thunder bolt does not go through here: it falls once every five seconds and is a
	wave event, not an attack. It keeps everything unless the "VFX" setting is off
	(`STRIKE_IMPACT`).

	`Clear` **removes** the attribute instead of zeroing it because that is how the addon
	turns off: it reads `attrs.X` and bails out when it finds nothing (`if not attr then
	return end`). A zero there would still turn the effect on, just with a zeroed number.
]=]
local CHAIN_IMPACT = {
	Attributes = {
		Count = 6,
		Radius = 3,
		Variance = 1,
		Size = Vector3.new(1.8, 0.7, 1.2),
	},

	Clear = { "CameraShake", "ImpactFrames" },
}

--[=[
	The impact of the thunder weather's bolt and of its jumps between units when the
	"VFX" setting is off: the authored crater, without the camera shake and the impact
	frame. The bolt itself still falls, because it stuns a unit (see `effectsOn`); only
	the screen effects go. With the setting on, the bolt arrives as authored.
]=]
local STRIKE_IMPACT = {
	Attributes = {},

	Clear = { "CameraShake", "ImpactFrames" },
}

local VFXController = {
	Controllers = {
		UnitPlacementController = {},
		WeatherController = {},

		-- The "VFX" setting. See `effectsOn`.
		SettingsController = {},

		-- Where the enemy models come from, so the Electro's bolt ends on each one of
		-- them. See `mobPoint`.
		MobController = {}
	}
}
VFXController.Library = {}

local function resolveBaseCFrame(target, offset)
	if typeof(target) == "CFrame" then
		return target * CFrame.new(offset), nil
	end
	if typeof(target) == "Vector3" then
		return CFrame.new(target + offset), nil
	end
	if typeof(target) == "Instance" then
		if target:IsA("Model") then
			return target:GetPivot() * CFrame.new(offset), target
		elseif target:IsA("BasePart") then
			return target.CFrame * CFrame.new(offset), target
		end
	end
	return nil, nil
end

local function setClonePivot(clone, cf)
	if clone:IsA("Model") then
		if not clone.PrimaryPart then
			local part = clone:FindFirstChildWhichIsA("BasePart")
			if part then clone.PrimaryPart = part end
		end
		clone:PivotTo(cf)
	elseif clone:IsA("BasePart") then
		clone.CFrame = cf
	end
end

local function getCloneRoot(clone)
	if clone:IsA("Model") then
		return clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	end
	return clone
end

local function getModelRoot(model)
	return model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
end

--[=[
	The player's "VFX" setting. Off, the **decorative** bursts stop: attack
	particles, the aura money, the round card burst, the Electro's arc, and the
	particles of a status. What tells the player something stays: the status
	Highlight, the meteor rock, the Archmage's line, and the weather bolts (a match
	event that stuns a unit), which only lose their camera shake and impact frame
	(`STRIKE_IMPACT`). Sounds inside the assets still play.
]=]
function VFXController:effectsOn() : boolean
	local settings = self.Controllers.SettingsController
	return settings == nil or settings:Get("VFX")
end

-- The thunder weather's impact for the current "VFX" setting. See `STRIKE_IMPACT`.
function VFXController:strikeImpact()
	return if self:effectsOn() then nil else STRIKE_IMPACT
end

function VFXController:Play(effectName, target, options)
	options = options or {}
	local template = self.Library[effectName]
	if not template then return end

	local offset = options.Offset or Vector3.new(0, 0, 0)
	local baseCF, targetModel = resolveBaseCFrame(target, offset)
	if not baseCF then return end

	local clone = template:Clone()
	setClonePivot(clone, baseCF)
	clone.Parent = Workspace

	if options.Attach and (typeof(target) == "Instance" and target:IsA("Model")) then
		local targetRoot = getModelRoot(target)
		local cloneRoot = getCloneRoot(clone)
		if targetRoot and cloneRoot then
			cloneRoot.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = cloneRoot
			weld.Part1 = targetRoot
			weld.Parent = cloneRoot
		end
	end

	-- With the "VFX" setting off only the sound plays: it is the attack's feedback, not
	-- decoration. See `effectsOn`.
	local effects = self:effectsOn()

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			if effects then
				local count = options.EmitCount or descendant:GetAttribute("EmitCount") or DEFAULT_EMIT_COUNT
				descendant:Emit(count)
			end
		elseif descendant:IsA("Sound") then
			descendant:Play()
		elseif descendant:IsA("Light") then
			descendant.Enabled = effects
		end
	end

	local lifetime = options.Duration or clone:GetAttribute("Lifetime") or DEFAULT_LIFETIME
	task.delay(lifetime, function()
		if clone and clone.Parent then
			clone:Destroy()
		end
	end)

	return clone
end

function VFXController:Trigger(unitName, eventName, context)
	if not unitName then return end
	context = context or {}

	local config = SharedConfig.UnitVFXConfig and SharedConfig.UnitVFXConfig[unitName]
	if not config then return end

	for _, entry in config do
		if entry.Event ~= eventName then continue end

		-- The asset goes inside the enemy, welded to it, and bursts once. See
		-- `attachToMob`.
		if entry.Target == "MobRoot" then
			local mob = context.mobModel
			if mob and mob.Parent then
				self:EmitAttached(self:attachToMob(entry.Effect, mob, entry.WeldTo), entry.Duration)
			end
			continue
		end

		local target
		if entry.Target == "Unit" then
			target = context.unitModel
			if not target and context.unitId then
				target = self:resolveUnitModel(context.unitId)
			end
		elseif entry.Target == "Mob" then
			if context.mobModel and context.mobModel.Parent then
				target = context.mobModel
			else
				target = context.position
			end
		end

		if not target then continue end

		self:Play(entry.Effect, target, entry)
	end
end

--[=[
	Money coming out of the unit that just earned extra inside an Entrepreneur's aura.
	`UnitService` sends it, on the server: the cash is its business, and this way
	everyone sees the effect on the same unit.

	The asset is an Attachment, so it lives inside a BasePart: the unit's
	`HumanoidRootPart`. That is what makes the effect follow the model with no weld,
	unlike `Play`, which drops the clone in the Workspace.

	The emit belongs to the `vfx` module: `EmitCount`/`EmitDelay` come authored on the
	asset's ParticleEmitter and it knows how to read them. The cleanup too: with no
	explicit deadline, the module takes it from the asset's longest particle lifetime, so
	tweaking the emitter in Studio leaves no garbage behind.
]=]
function VFXController:PlayAuraBonus(unitId : string)
	if not self:effectsOn() then return end

	local template = self.Library[MONEY_VFX_NAME]
	if not template then
		log:StudioWarn(`could not find VFX "{MONEY_VFX_NAME}" in Assets.VFX.`)
		return
	end

	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	local root = model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart
	if not root or not root:IsA("BasePart") then return end

	local clone = template:Clone()
	clone.Parent = root

	VFX.emit(clone)
	VFX.destroyAfter(clone, VFX.maxLifetime(clone) or MONEY_VFX_FALLBACK)
end

--[=[
	Tones down a bolt tip's impact: smaller crater, no impact frame, and no camera shake.
	See `CHAIN_IMPACT`.

	It changes the **clone**, never the asset: the weather bolt comes from the same
	template and must keep arriving whole.
]=]
local function tuneBeamImpact(tip : Instance, impact)
	for name, value in impact.Attributes do
		tip:SetAttribute(name, value)
	end

	for _, name in impact.Clear do
		tip:SetAttribute(name, nil)
	end
end

local function disarmPart(part : BasePart)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

--[=[
	Hangs a VFX asset inside the unit's `HumanoidRootPart`, ready to play. Returns the
	clone.

	Two things parenting alone does not solve:

	**Positioning.** A Part child of a Part does not inherit position: the asset's is
	the one from when it was authored, across the map. `PlayAuraBonus` does not need this
	because its asset is an Attachment, which inherits.

	**Disarming.** Assets come from the plugin with `CanCollide`, `CanQuery`, and
	`CanTouch` on (`FrozenVFX` comes like that). Inside a unit that becomes an invisible
	box pushing whoever passes and, worse, showing up in placement's `GetPartsInPart`,
	refusing an empty spot for anyone trying to build next to it. We cannot rely on the
	asset coming right from Studio.
]=]
local function attachVFX(template : Instance, root : BasePart) : Instance
	local clone = template:Clone()
	clone.Parent = root

	if clone:IsA("BasePart") then
		clone.CFrame = root.CFrame
		disarmPart(clone)
	elseif clone:IsA("Attachment") then
		--[[
			**Zeroing the offset.** An Attachment inherits its parent's position, but does
			not zero its own: the authored one is where the asset was on the map when the
			plugin saved it. `PlayerStopTime` came with Y = 22.25 (the height where it was
			built), and hung on the player that put the particles 22 studs above their head:
			the effect played, just off screen.

			Rotation stays, since the author really chooses it (the particle direction
			comes from it); the offset goes, since it is assembly leftover.
			`MoneyEntrepreneur` never needed this only because it was saved at 0, 0, 0.
		]]
		clone.CFrame = clone.CFrame.Rotation
	end

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			disarmPart(descendant)
		end
	end

	return clone
end

--[=[
	Hangs an `Assets.VFX` asset on a Part and returns the clone, **without bursting**.

	It is the front half of `EmitAttached`, split because not every effect is born and
	bursts at the same instant: a round card's is hung on the player when the card is
	used and only bursts when the animation reaches the marker. Callers that split the
	two owe the `EmitAttached`, or destroying the clone if the burst never comes.
]=]
function VFXController:AttachAsset(assetName : string?, root : BasePart) : Instance?
	if not assetName then return nil end

	local template = self.Library[assetName]
	if not template then
		log:StudioWarn(`could not find VFX "{assetName}" in Assets.VFX.`)
		return nil
	end

	return attachVFX(template, root)
end

--[=[
	The burst of an asset already hung.

	A single `emit`, which is what a burst emitter asks for. Cleanup comes from the
	asset's longest particle lifetime (`fallback` only applies when the module cannot say:
	an asset with no particles, or with an infinite `EmitDuration`), so tweaking the
	emitter in Studio leaves no garbage behind.
]=]
function VFXController:EmitAttached(clone : Instance?, fallback : number?)
	if not clone or not clone.Parent then return end

	-- The "VFX" setting off: the clone was hung for a burst that will not come.
	if not self:effectsOn() then
		clone:Destroy()
		return
	end

	VFX.emit(clone)
	VFX.destroyAfter(clone, VFX.maxLifetime(clone) or fallback or DEFAULT_LIFETIME)
end

--[=[
	The weather freeze on the unit that just locked up: the same `IcedVFX` as the
	Frostione's freeze on enemies, through `playModelStatus`: particles welded to the
	`Torso` and its Highlight on the unit model's root.

	Nothing here is written against the name "Snow": the asset comes from the `Freeze`
	of the weather the server sent as the stun's cause. A weather without `Freeze`
	(lightning) and a stun with no weather at all (the enemy gimmick) drop out on their
	own, keeping only the yellow highlight `UnitPlacementController` draws.

	`duration` is what the server actually applied, not the config's `Freeze.Duration`:
	the longer deadline wins in `UnitService:StunUnit`.
]=]
function VFXController:PlayFreeze(unitId : string, weatherName : string?, duration : number?)
	local effects = WeatherConfig.GetEffects(weatherName)
	local freeze = effects and effects.Freeze
	if not freeze or not freeze.Asset then return end

	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	self:playModelStatus(model, freeze.Asset, ICED_HIGHLIGHT_NAME, duration)
end

--[=[
	Removes a unit's freeze before its time.

	It is the Staff of Healing: it removes the stun midway, and the drawing has its own
	deadline, a `GameClock.Delay` created with it that cannot know the freeze ended
	early. Without this, the unit would start attacking again still covered in ice.

	The names come from config: a new weather with its own `Freeze` enters this cleanup
	without going through here.
]=]
function VFXController:StopFreeze(unitId : string)
	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	for _, effects in WeatherConfig.Effects do
		local asset = effects.Freeze and effects.Freeze.Asset
		if asset then
			self:stopModelStatus(model, asset, ICED_HIGHLIGHT_NAME)
		end
	end
end

--[=[
	The burst of a single-target round card touching a tower.

	`CardShopService` sends it, on the server, and to **everyone**: the card is bought by
	one person, but the effect belongs to the room, and the burst must appear on the same
	tower for everyone, like lightning and aura money.

	The path is the same as the freeze burst: the asset is hung inside the tower's
	`HumanoidRootPart` (which is why it follows the model with no weld) and burst at
	once. Each emitter's `EmitCount` comes authored in the asset, and cleanup comes from
	its longest particle lifetime: tweaking the emitter in Studio leaves no garbage
	behind.
]=]
function VFXController:PlayUnitApplied(unitId : string)
	local model = self:resolveUnitModel(unitId)
	if not model or not model.Parent then return end

	local root = model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart
	if not root or not root:IsA("BasePart") then return end

	self:EmitAttached(self:AttachAsset(RoundCardConfig.AppliedVFX, root))
end

function VFXController:resolveUnitModel(unitId)
	local placement = self.Controllers.UnitPlacementController
	if not placement or not placement.createdClasses then return nil end
	for model, class in placement.createdClasses do
		if class and class.unitId == unitId then
			return model
		end
	end
	return nil
end

--[=[
	The unit's feet: the center of the bottom of its box.

	`GetPivot` would return the middle of the body, and the bolt must hit the ground.
]=]
local function footOf(model : Model) : Vector3
	local cf, size = model:GetBoundingBox()
	return Vector3.new(cf.Position.X, cf.Position.Y - size.Y / 2, cf.Position.Z)
end

--[=[
	Where the bolt comes down from.

	It should come from the cloud itself, so the height comes from the weather Part
	`WeatherService` left in `workspace.Weather`. With no weather on (the bolt may be
	fired by something else someday), it falls back to a fixed height above the feet.
]=]
local function strikeOrigin(foot : Vector3) : Vector3
	local container = Workspace:FindFirstChild("Weather")
	local cloud = container and container:FindFirstChildWhichIsA("BasePart", true)

	local height = cloud and cloud.Position.Y or (foot.Y + ThunderConfig.StrikeHeight)
	return Vector3.new(foot.X, math.max(height, foot.Y + 1), foot.Z)
end

--[=[
	An arc between two world points. Returns the tip Attachment, so the caller can hang
	a sound on it.

	The asset is an Attachment (the bolt's start) with a single-letter child Attachment
	(the end). Positioning both by `WorldPosition` is enough: the child's relative
	position recomputes on its own, and since neither has a BasePart ancestor, the world
	is the reference frame.

	It works both for the bolt coming down from the cloud and for the jump from one unit
	to another; the only difference between the two is where the ends are.

	`impact` is optional: the Electro's bolt sends `CHAIN_IMPACT`, and the thunder weather
	sends `STRIKE_IMPACT` while the "VFX" setting is off. Without it, the tip arrives with
	what was authored on the asset.
]=]
function VFXController:spawnBeam(from : Vector3, to : Vector3, impact : { [string] : any }?) : Attachment?
	local asset = self.Library[ThunderConfig.Asset]
	if not asset then
		log:StudioWarn(`could not find VFX "{ThunderConfig.Asset}" in Assets.VFX.`)
		return nil
	end

	local beam = asset:Clone()
	local tip = beam:FindFirstChildWhichIsA("Attachment")
	if not tip then
		log:StudioWarn(`"{ThunderConfig.Asset}" has no child Attachment marking the end of the bolt.`)
		beam:Destroy()
		return nil
	end

	-- Before the emit, and on the clone: the addon reads the tip's attributes when it
	-- is emitted, so changing them afterward would change nothing.
	if impact then
		tuneBeamImpact(tip, impact)
	end

	-- It must be in the DataModel before the emit: the module ignores what is loose.
	beam.Parent = VFX.temp

	beam.WorldPosition = from
	tip.WorldPosition = to

	--[[
		The asset comes with `EmitRepeat = -1`, which is how the plugin marks the looping
		preview. In practice `emit` treats -1 as "do not repeat", but relying on that is
		fragile: here the single shot is stated by hand, and the rest of the authored
		attributes still apply.
	]]
	local attrs = beam:GetAttributes()
	attrs.EmitRepeat = 0

	VFX.emit(beam, attrs)

	-- The asset has no ParticleEmitter of its own (the addon creates its own at runtime),
	-- so the module's `maxLifetime` would give zero: the lifetime comes from its `Duration`.
	local duration = VFX.num(beam:GetAttribute("Duration"), 5)
	VFX.destroyAfter(beam, duration + ThunderConfig.Cleanup)

	return tip
end

--[=[
	A bolt falling on a point on the map.

	`unitId` is optional: when present, the model's feet rule, because the server only
	knows the placement CFrame and the client measures the unit's real box. `position`
	is the target when the bolt hits the ground, and the fallback for when the unit has
	not replicated yet.
]=]
function VFXController:PlayLightningStrike(position : Vector3, unitId : string?)
	if typeof(position) ~= "Vector3" then return end

	local foot = position
	if unitId then
		local model = self:resolveUnitModel(unitId)
		if model and model.Parent then
			foot = footOf(model)
		end
	end

	local tip = self:spawnBeam(strikeOrigin(foot), foot, self:strikeImpact())
	if not tip then return end

	--[[
		After positioning, never before: the Sound becomes a child of the tip Attachment,
		so it comes from where the bolt hit. The sound clone dies with the beam, and the
		beam is only destroyed well after the crack ends.
	]]
	local weather = self.Controllers.WeatherController
	if weather then
		weather:PlayStrikeSound(tip)
	end
end

--[=[
	The middle of the unit's body, or the position the server sent when the model has
	not arrived yet.
]=]
function VFXController:chainPoint(unitId : string?, fallback : Vector3?) : Vector3?
	if unitId then
		local model = self:resolveUnitModel(unitId)
		if model and model.Parent then
			return model:GetPivot().Position
		end
	end

	return if typeof(fallback) == "Vector3" then fallback else nil
end

--[=[
	The bolt's jump from one unit to another.

	Each link comes from `ThunderService` with the pair of units and the pair of
	positions. The model rules when it has already replicated: the server's position is
	the placement CFrame, at the unit's feet, and a horizontal arc coming off the ground
	looks like a scratch on the floor. Without a model, the position is the backup.

	No crack of its own on purpose: the main bolt's is already playing, and a clone per
	arc would fill something that lasts half a second with overlapping thunder.
]=]
function VFXController:PlayLightningChain(links)
	if typeof(links) ~= "table" then return end

	local impact = self:strikeImpact()

	for _, link in links do
		local from = self:chainPoint(link.fromId, link.from)
		local to = self:chainPoint(link.toId, link.to)

		if from and to then
			self:spawnBeam(from, to, impact)
		end
	end
end

--[=[
	The middle of an enemy's body, or the position the server sent when the model is no
	longer there.

	The pair of `chainPoint`, which does the same with units; separate from it because
	the two live in different controllers: units belong to `UnitPlacementController`,
	enemies to `MobController`.

	The model rules when it exists. The client simulates enemy walking on its own, so the
	position in the event is already a few frames old when the bolt is drawn: on a fast
	enemy that is an arc visibly ending behind it.
]=]
function VFXController:mobPoint(mobId : string?, fallback : Vector3?) : Vector3?
	local mobs = self.Controllers.MobController
	local model = mobId and mobs and mobs.SpawnedMobs and mobs.SpawnedMobs[mobId]

	if model and model.Parent then
		return model:GetPivot().Position
	end

	return if typeof(fallback) == "Vector3" then fallback else nil
end

--[=[
	The Electro's bolt: an arc from the unit to the first enemy, and from there one to
	the next in the order the chain jumped.

	The asset is the same as the weather bolt's (`ThunderConfig.Asset`, through
	`spawnBeam`): it is the same addon drawing the same thing, which is why the thunder
	bolt and the unit's look alike on purpose.

	The server chose the targets, at the instant of the `Hit` marker
	(`UnitService:executeAttack`): no decision comes from here, only the drawing of the
	chain that already dealt damage.

	An enemy already off screen that sent no position does not break the chain: the next
	arc starts from the last point that could be drawn, instead of the bolt dying midway.
]=]
function VFXController:PlayChainLightning(arc)
	if typeof(arc) ~= "table" or typeof(arc.targets) ~= "table" then return end

	-- Decorative: the enemies it hit are already painted yellow by `MobController`.
	if not self:effectsOn() then return end

	local from = self:chainPoint(arc.unitId, arc.origin)
	if not from then return end

	for _, target in arc.targets do
		local to = self:mobPoint(target.mobId, target.position)
		if not to then continue end

		self:spawnBeam(from, to, CHAIN_IMPACT)
		from = to
	end
end

-- The tags the `vfx` module uses to turn an asset on and off by itself. See `attachToMob`.
local AUTO_VFX_TAGS = { "EnabledVFX", "SequencedVFX" }

--[=[
	Hangs an `Assets.VFX` asset on an enemy's `HumanoidRootPart`, welded, and returns
	the clone.

	The pair of `attachVFX`, which does the same on units; separate from it because of
	two differences:

	**Following something that walks.** Units stand still, enemies do not. The asset's
	Part leaves the anchor and is welded to `weldTo` (the root itself when no name comes),
	and the `PivotTo` `MobController` moves the enemy with carries it along.

	**Removing the `vfx` module's tags.** `IcedVFX` comes with `EnabledVFX`, and its
	Highlight with `SequencedVFX`: the module turns things with these tags on and off on
	its own, a frame after entering the Workspace, and would override whoever lit the
	emitters by hand. They are removed **before** parenting: removing them afterward
	would still fire the delayed on/off.
]=]
function VFXController:attachToMob(assetName : string?, mob : Model, weldTo : string?) : Instance?
	if not assetName then return nil end

	local root = mob:FindFirstChild(UNIT_ROOT_NAME) or mob.PrimaryPart
	if not root or not root:IsA("BasePart") then return nil end

	local template = self.Library[assetName]
	if not template then
		log:StudioWarn(`could not find VFX "{assetName}" in Assets.VFX.`)
		return nil
	end

	local clone = template:Clone()

	for _, instance in { clone, unpack(clone:GetDescendants()) } do
		for _, tag in AUTO_VFX_TAGS do
			instance:RemoveTag(tag)
		end
		if instance:IsA("BasePart") then
			disarmPart(instance)
			instance.Massless = true
		end
	end

	if clone:IsA("BasePart") then
		clone.CFrame = root.CFrame

		local anchor = weldTo and mob:FindFirstChild(weldTo)
		if not anchor or not anchor:IsA("BasePart") then
			anchor = root
		end

		clone.Anchored = false

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = clone
		weld.Part1 = anchor
		weld.Parent = clone
	elseif clone:IsA("Attachment") then
		-- An Attachment inherits its parent's position; only the assembly offset goes.
		clone.CFrame = clone.CFrame.Rotation
	end

	clone.Parent = root

	return clone
end

--[=[
	A state the server put on a model (enemy or unit: frozen, burning), drawn for the
	`duration` seconds it applied.

	The asset goes on the `HumanoidRootPart` welded to the `Torso`, with the emitters on,
	and its Highlight moves to the model's root, which is what it needs to paint the whole
	body. At the end the emitters turn off, the Highlight leaves immediately, and the
	Part is only destroyed after the last particles' tail.

	The same state on top of another replaces the previous one instead of stacking two.
	The model leaving midway (enemy dead, unit sold) cleans everything on its own: both
	live inside it. Different states coexist: each has its own asset and Highlight name.
]=]
function VFXController:playModelStatus(mob : Model, assetName : string, highlightName : string, duration : number?)
	duration = tonumber(duration) or 0
	if duration <= 0 or not mob.Parent then return end

	local clone, highlight = self:attachModelStatus(mob, assetName, highlightName)
	if not clone then return end

	-- Match time, like `StunMob` on the other side: at 3x the state ends sooner in
	-- real seconds, and the drawing must leave with it.
	GameClock.Delay(duration, function()
		if highlight and highlight.Parent then
			highlight:Destroy()
		end

		if not clone.Parent then return end

		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end

		VFX.destroyAfter(clone, VFX.maxLifetime(clone) or STATUS_VFX_FALLBACK)
	end)
end

--[=[
	A state with no deadline: it stays until `stopModelStatus`. Used for the
	Cryomancer's ring, which lasts exactly as long as the enemy is inside it.

	A state already on the model is kept, not replaced: the server only says "on" once,
	but replacing would restart the particles mid-loop if it ever said it twice.
]=]
function VFXController:holdModelStatus(mob : Model, assetName : string, highlightName : string)
	if not mob.Parent then return end

	local root = mob:FindFirstChild(UNIT_ROOT_NAME) or mob.PrimaryPart
	if root and root:FindFirstChild(assetName) then return end

	self:attachModelStatus(mob, assetName, highlightName)
end

--[=[
	Puts a state's asset on the model, replacing the same state if present: the clone
	welded to the `Torso`, its Highlight moved to the model, the emitters on. Returns
	both for the caller to end them.
]=]
function VFXController:attachModelStatus(mob : Model, assetName : string, highlightName : string) : (Instance?, Highlight?)
	local root = mob:FindFirstChild(UNIT_ROOT_NAME) or mob.PrimaryPart
	local previous = root and root:FindFirstChild(assetName)
	if previous then
		previous:Destroy()
	end

	local previousHighlight = mob:FindFirstChild(highlightName)
	if previousHighlight then
		previousHighlight:Destroy()
	end

	local clone = self:attachToMob(assetName, mob, "Torso")
	if not clone then return nil, nil end

	local highlight = clone:FindFirstChildWhichIsA("Highlight")
	if highlight then
		highlight.Name = highlightName
		highlight.Adornee = nil
		highlight.Parent = mob
	end

	-- With the "VFX" setting off only the Highlight shows the state: it is what tells
	-- the player, and the particles are decoration.
	local effects = self:effectsOn()

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = effects
		end
	end

	return clone, highlight
end


function VFXController:stopModelStatus(mob : Model, assetName : string, highlightName : string)
	local highlight = mob:FindFirstChild(highlightName)
	if highlight then
		highlight:Destroy()
	end

	local root = mob:FindFirstChild(UNIT_ROOT_NAME) or mob.PrimaryPart
	local clone = root and root:FindFirstChild(assetName)
	if not clone then return end

	-- Gives up the name so a new state right after does not destroy this one in the
	-- middle of the particle tail.
	clone.Name = assetName .. "Ending"

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		end
	end

	VFX.destroyAfter(clone, VFX.maxLifetime(clone) or STATUS_VFX_FALLBACK)
end

-- A state on an enemy, by id: the model lives in `MobController`.
function VFXController:playMobStatus(mobId : string, assetName : string, highlightName : string, duration : number?)
	local mobs = self.Controllers.MobController
	local mob = mobs and mobs.SpawnedMobs and mobs.SpawnedMobs[mobId]
	if not mob then return end

	self:playModelStatus(mob, assetName, highlightName, duration)
end

-- The Frostione's freeze (`IcedVFX`). See `playModelStatus`.
function VFXController:PlayIced(mobId : string, duration : number?)
	self:playMobStatus(mobId, ICED_VFX_NAME, ICED_HIGHLIGHT_NAME, duration)
end

-- The Pyre's burn (`BurningVFX`). See `playModelStatus`.
function VFXController:PlayBurning(mobId : string, duration : number?)
	self:playMobStatus(mobId, BURNING_VFX_NAME, BURNING_HIGHLIGHT_NAME, duration)
end

-- The Slasher's and Berserker's bleed (`BleedVFX`). See `playModelStatus`.
function VFXController:PlayBleeding(mobId : string, duration : number?)
	self:playMobStatus(mobId, BLEED_VFX_NAME, BLEED_HIGHLIGHT_NAME, duration)
end

--[=[
	The Cryomancer's ring slow (`FrozenAuraVFX`): on while the enemy is inside a ring,
	off when it leaves (`MobAuraSlowed`, from `MobService:SetAuraSlows`).

	"On" can arrive before the enemy's model: `SpawnClientMob` travels in another Warp
	queue, and an enemy born inside a ring is slowed on its first frame. So a missing
	model is retried for a moment, and an "off" in between cancels the wait.
]=]
function VFXController:SetFrozenAura(mobId : string, on : boolean)
	local mobs = self.Controllers.MobController
	local spawned = mobs and mobs.SpawnedMobs

	if not on then
		self.FrozenAuraPending[mobId] = nil

		local mob = spawned and spawned[mobId]
		if mob then
			self:stopModelStatus(mob, FROZEN_AURA_VFX_NAME, FROZEN_AURA_HIGHLIGHT_NAME)
		end

		return
	end

	local token = {}
	self.FrozenAuraPending[mobId] = token

	local tries = 0

	local function attach()
		if self.FrozenAuraPending[mobId] ~= token then return end

		local mob = spawned and spawned[mobId]
		if mob then
			self.FrozenAuraPending[mobId] = nil
			self:holdModelStatus(mob, FROZEN_AURA_VFX_NAME, FROZEN_AURA_HIGHLIGHT_NAME)
			return
		end

		tries += 1
		if tries > FROZEN_AURA_RETRIES then
			self.FrozenAuraPending[mobId] = nil
			return
		end

		task.delay(FROZEN_AURA_RETRY_DELAY, attach)
	end

	attach()
end

--[=[
	The Volt's charge (`ShockedAuraVFX`), from `MobStatic` (`MobService:ApplyStatic`):
	`remaining` is how long the charge has left, and `burst` fires the asset's
	`EmitCount`s once, on each hit and each stun pulse.

	The asset stays on the enemy, emitters on, until the charge's deadline, through
	`holdModelStatus` (the Cryomancer's ring path), so a refresh does not restart the
	particles. The deadline only grows: the server only ever pushes it forward, and
	keeping the latest one makes the order the notices arrive in irrelevant. Each
	notice schedules its own check, and only the one holding the current deadline
	takes the asset off.

	With the "VFX" setting off there is no burst and the emitters stay off, the same
	as the other states.
]=]
function VFXController:PlayStatic(mobId : string, remaining : number?, burst : boolean?)
	remaining = tonumber(remaining) or 0
	if remaining <= 0 then return end

	local mobs = self.Controllers.MobController
	local mob = mobs and mobs.SpawnedMobs and mobs.SpawnedMobs[mobId]
	if not mob or not mob.Parent then return end

	local deadline = math.max(self.StaticUntil[mobId] or 0, GameClock.Now() + remaining)
	self.StaticUntil[mobId] = deadline

	self:holdModelStatus(mob, SHOCKED_AURA_VFX_NAME, SHOCKED_AURA_HIGHLIGHT_NAME)

	if burst and self:effectsOn() then
		local root = mob:FindFirstChild(UNIT_ROOT_NAME) or mob.PrimaryPart
		local clone = root and root:FindFirstChild(SHOCKED_AURA_VFX_NAME)
		if clone then
			VFX.emit(clone)
		end
	end

	GameClock.Delay(deadline - GameClock.Now(), function()
		if self.StaticUntil[mobId] ~= deadline then return end

		self.StaticUntil[mobId] = nil

		if mob.Parent then
			self:stopModelStatus(mob, SHOCKED_AURA_VFX_NAME, SHOCKED_AURA_HIGHLIGHT_NAME)
		end
	end)
end

--suffocate logic

local MOVED_MARK = "MovedVFXAsset"
local function scaleSequence(sequence : NumberSequence, factor : number) : NumberSequence
	local keypoints = {}
	for _, key in sequence.Keypoints do
		table.insert(keypoints, NumberSequenceKeypoint.new(key.Time, key.Value * factor, key.Envelope * factor))
	end
	return NumberSequence.new(keypoints)
end

local function prepareEmitter(emitter : ParticleEmitter, factor : number)
	for _, tag in AUTO_VFX_TAGS do
		emitter:RemoveTag(tag)
	end

	if factor ~= 1 then
		emitter.Size = scaleSequence(emitter.Size, factor)
	end

	emitter.Enabled = true
end

-- Turns off every emitter in `root` (and `root` itself) and returns the longest tail.
local function disableEmitters(root : Instance) : number
	local longest = 0

	local function visit(item : Instance)
		if item:IsA("ParticleEmitter") then
			item.Enabled = false
			longest = math.max(longest, item.Lifetime.Max)
		end
	end

	visit(root)
	for _, descendant in root:GetDescendants() do
		visit(descendant)
	end

	return longest
end

-- Stops what was moved, then destroys it after the last particles' tail.
local function retireMoved(moved : { Instance })
	local longest = 0

	for _, instance in moved do
		if not instance.Parent then continue end

		-- A Highlight has no tail: it leaves at once.
		if instance:IsA("Highlight") then
			instance:Destroy()
			continue
		end

		longest = math.max(longest, disableEmitters(instance))
	end

	task.delay(longest + 0.1, function()
		for _, instance in moved do
			if instance.Parent then
				instance:Destroy()
			end
		end
	end)
end


function VFXController:PlaySuffocateCast(mobId : string, assetName : string?, partName : string?, castTime : number?)
	castTime = tonumber(castTime) or 0
	if castTime <= 0 or not assetName then return end

	-- Decorative, so the "VFX" setting silences it. See `effectsOn`.
	if not self:effectsOn() then return end

	local mobs = self.Controllers.MobController
	local mob = mobs and mobs.SpawnedMobs and mobs.SpawnedMobs[mobId]
	if not mob or not mob.Parent then return end

	local template = self.Library[assetName]
	if not template then
		log:StudioWarn(`could not find VFX "{assetName}" in Assets.VFX.`)
		return
	end

	local target = mob:FindFirstChild(partName or "Right Arm")
	if not target or not target:IsA("BasePart") then
		log:StudioWarn(`'{mob.Name}' has no Part named "{partName}" for "{assetName}".`)
		return
	end

	-- A cast still playing on this mob is replaced, not stacked.
	self:StopVictimVFX(mob, assetName)

	local source = template:Clone()

	local factor = 1
	if source:IsA("BasePart") and source.Size.Y > 0 then
		factor = target.Size.Y / source.Size.Y
	end

	local moved = {}

	for _, descendant in source:GetDescendants() do
		if not descendant:IsA("ParticleEmitter") then continue end

		prepareEmitter(descendant, factor)

		local holder = descendant.Parent
		if holder and holder:IsA("Attachment") then
			-- Travels with its Attachment so the offset along the arm survives.
			if not holder:GetAttribute(MOVED_MARK) then
				holder:SetAttribute(MOVED_MARK, assetName)
				holder.Position = holder.Position * factor
				holder.Parent = target
				table.insert(moved, holder)
			end
		else
			descendant:SetAttribute(MOVED_MARK, assetName)
			descendant.Parent = target
			table.insert(moved, descendant)
		end
	end

	local highlight = source:FindFirstChildWhichIsA("Highlight")
	if highlight then
		highlight:SetAttribute(MOVED_MARK, assetName)
		highlight.Adornee = target
		highlight.Parent = target
		table.insert(moved, highlight)
	end

	source:Destroy()

	if #moved == 0 then
		log:StudioWarn(`"{assetName}" had nothing to move onto '{mob.Name}'.`)
		return
	end

	GameClock.Delay(castTime, function()
		retireMoved(moved)
	end)
end


function VFXController:PlayVictimVFX(model : Model, assetName : string, duration : number?)
	duration = tonumber(duration) or 0
	if duration <= 0 or not model or not model.Parent then return end

	-- Decorative, so the "VFX" setting silences it. See `effectsOn`.
	if not self:effectsOn() then return end

	local template = self.Library[assetName]
	if not template then
		log:StudioWarn(`could not find VFX "{assetName}" in Assets.VFX.`)
		return
	end

	local fallback = model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart

	-- The same state on top of another replaces the previous one.
	self:StopVictimVFX(model, assetName)

	local source = template:Clone()
	local moved = {}

	for _, part in source:GetChildren() do
		if not part:IsA("BasePart") then continue end

		local target = model:FindFirstChild(part.Name)
		if not target or not target:IsA("BasePart") then
			target = fallback
		end
		if not target then continue end

		for _, child in part:GetChildren() do
			if child:IsA("ParticleEmitter") then
				prepareEmitter(child, 1)
				child:SetAttribute(MOVED_MARK, assetName)
				child.Parent = target
				table.insert(moved, child)
			end
		end
	end

	source:Destroy()

	if #moved == 0 then return end

	GameClock.Delay(duration, function()
		retireMoved(moved)
	end)
end

function VFXController:StopVictimVFX(model : Model, assetName : string)
	if not model or not model.Parent then return end

	local moved = {}
	for _, descendant in model:GetDescendants() do
		if descendant:GetAttribute(MOVED_MARK) == assetName then
			table.insert(moved, descendant)
		end
	end

	if #moved > 0 then
		retireMoved(moved)
	end
end



function VFXController:PlayWeatherChangeCast(mobId : string, assetName : string?, castTime : number?)
	castTime = tonumber(castTime) or 0
	if castTime <= 0 or not assetName then return end

	-- Decorative, so the "VFX" setting silences it. See `effectsOn`.
	if not self:effectsOn() then return end

	local mobs = self.Controllers.MobController
	local mob = mobs and mobs.SpawnedMobs and mobs.SpawnedMobs[mobId]
	if not mob or not mob.Parent then return end

	local template = self.Library[assetName]
	if not template then
		log:StudioWarn(`could not find VFX "{assetName}" in Assets.VFX.`)
		return
	end

	local source = template:Clone()
	local emitters = {}

	for _, part in source:GetChildren() do
		if not part:IsA("BasePart") then continue end

		local target = mob:FindFirstChild(part.Name)
		if not target or not target:IsA("BasePart") then continue end

		for _, child in part:GetChildren() do
			if not child:IsA("ParticleEmitter") then continue end

			for _, tag in AUTO_VFX_TAGS do
				child:RemoveTag(tag)
			end

			child.Enabled = true
			child.Parent = target
			table.insert(emitters, child)
		end
	end

	source:Destroy()

	if #emitters == 0 then
		log:StudioWarn(`"{assetName}" had no emitters matching the mob's parts.`)
		return
	end

	GameClock.Delay(castTime, function()
		local longest = 0

		for _, emitter in emitters do
			if emitter.Parent then
				emitter.Enabled = false
				longest = math.max(longest, emitter.Lifetime.Max)
			end
		end

		task.delay(longest + 0.1, function()
			for _, emitter in emitters do
				if emitter.Parent then
					emitter:Destroy()
				end
			end
		end)
	end)
end



-- The Archmage's two attacks that have visuals: the assets in `Assets.VFX`, the
-- explosion Attachment inside the meteor, and the backup cleanup.
local METEOR_VFX_NAME = "Meteor"
local METEOR_EXPLOSION_NAME = "EXPLOSION"
local ARCHMAGE_LIGHTNING_NAME = "ArchmageLightning"
local ARCHMAGE_VFX_FALLBACK = 2

--[=[
	A clone loose in the world, ready to be moved by hand: without the tags the `vfx`
	module uses to turn an asset on and off by itself (see `attachToMob`), and with every
	Part anchored and disarmed: assets come from the plugin colliding, and a solid
	falling meteor would push units and show up in the placement raycast.
]=]
local function looseVFXClone(template : Instance) : Instance
	local clone = template:Clone()

	for _, instance in { clone, unpack(clone:GetDescendants()) } do
		for _, tag in AUTO_VFX_TAGS do
			instance:RemoveTag(tag)
		end
		if instance:IsA("BasePart") then
			disarmPart(instance)
			instance.Anchored = true
		end
	end

	return clone
end

-- Turns an asset's continuous effects on or off, skipping what is inside
-- `skip` (the meteor's explosion, which only bursts at the end).
local function setEffectsEnabled(root : Instance, enabled : boolean, skip : Instance?)
	for _, descendant in root:GetDescendants() do
		if skip and descendant:IsDescendantOf(skip) then continue end

		if descendant:IsA("ParticleEmitter") or descendant:IsA("Light") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = enabled
		end
	end
end

--[=[
	The Archmage's meteor.

	It spawns `height` studs above the unit's `HumanoidRootPart` and falls in a straight
	line to `aimPos` (where the target was when the attack started, decided by the
	server) over `fallTime` match seconds. The emitters outside the `EXPLOSION` Attachment
	are the trail and stay on during the fall; at the end they turn off, the rock
	vanishes, and `EXPLOSION` bursts once.

	The fall is counted on the match clock, not a Tween: the server deals the damage
	after the same `fallTime` on `GameClock`, and at 2x a real-time Tween would explode
	after the enemy had already taken the damage.
]=]
function VFXController:PlayMeteor(unitId : string, aimPos : Vector3, fallTime : number?, height : number?)
	if typeof(aimPos) ~= "Vector3" then return end

	local template = self.Library[METEOR_VFX_NAME]
	if not template then
		log:StudioWarn(`could not find VFX "{METEOR_VFX_NAME}" in Assets.VFX.`)
		return
	end

	local model = self:resolveUnitModel(unitId)
	local root = model and (model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart)
	local origin = (root and root.Position or aimPos) + Vector3.new(0, tonumber(height) or 15, 0)

	local meteor = looseVFXClone(template)
	local explosion = meteor:FindFirstChild(METEOR_EXPLOSION_NAME)

	local heading = aimPos - origin
	local rotation = if heading.Magnitude > 1e-3 then CFrame.lookAt(Vector3.zero, heading) else CFrame.identity

	setClonePivot(meteor, CFrame.new(origin) * rotation)
	meteor.Parent = VFX.temp

	-- With the "VFX" setting off only the rock falls: it is what shows where the damage
	-- lands. The trail and the explosion are decoration.
	local effects = self:effectsOn()

	if effects then
		setEffectsEnabled(meteor, true, explosion)
	end

	local duration = math.max(0.05, tonumber(fallTime) or 1)
	local elapsed = 0
	local connection
	connection = game:GetService("RunService").Heartbeat:Connect(function(dt)
		if not meteor.Parent then
			connection:Disconnect()
			return
		end

		elapsed += GameClock.Scaled(dt)
		local alpha = math.min(1, elapsed / duration)
		setClonePivot(meteor, CFrame.new(origin:Lerp(aimPos, alpha)) * rotation)

		if alpha < 1 then return end
		connection:Disconnect()

		setEffectsEnabled(meteor, false, explosion)
		if meteor:IsA("BasePart") then
			meteor.Transparency = 1
		end

		if explosion and effects then
			VFX.emit(explosion)
		end

		VFX.destroyAfter(meteor, VFX.maxLifetime(meteor) or ARCHMAGE_VFX_FALLBACK)
	end)
end

--[=[
	The Archmage's line bolt, on for the `duration` seconds of damage.

	The asset is long along the X axis, with the tip (the Attachment) at +X. It starts at
	the unit's `HumanoidRootPart` and points, horizontally, at `throughPos`: the same aim
	the server uses to trace the damage line. It stays in the world, not inside the
	model, so the unit's smooth turning does not bend the drawing off the real line.

	The `SpotLight` comes with the `Sequencer` addon's tag, which does not run in a match
	(missing capability); that is why the tags are removed on the clone and everything is
	turned on and off by hand.
]=]
function VFXController:PlayArchmageLightning(unitId : string, throughPos : Vector3, duration : number?)
	if typeof(throughPos) ~= "Vector3" then return end

	local template = self.Library[ARCHMAGE_LIGHTNING_NAME]
	if not template then
		log:StudioWarn(`could not find VFX "{ARCHMAGE_LIGHTNING_NAME}" in Assets.VFX.`)
		return
	end

	local model = self:resolveUnitModel(unitId)
	local root = model and (model:FindFirstChild(UNIT_ROOT_NAME) or model.PrimaryPart)
	if not root then return end

	local start = root.Position
	local heading = Vector3.new(throughPos.X - start.X, 0, throughPos.Z - start.Z)
	if heading.Magnitude < 1e-3 then return end

	local direction = heading.Unit
	local beam = looseVFXClone(template)
	local length = if beam:IsA("BasePart") then beam.Size.X else 0

	setClonePivot(beam, CFrame.fromMatrix(start + direction * (length / 2), direction, Vector3.yAxis))
	beam.Parent = VFX.temp

	setEffectsEnabled(beam, true)

	GameClock.Delay(math.max(0, tonumber(duration) or 0), function()
		if not beam.Parent then return end

		setEffectsEnabled(beam, false)
		VFX.destroyAfter(beam, VFX.maxLifetime(beam) or ARCHMAGE_VFX_FALLBACK)
	end)
end

function VFXController:buildLibrary()
	local folder = Assets:FindFirstChild("VFX")
	if not folder then return end
	for _, effect in folder:GetChildren() do
		self.Library[effect.Name] = effect
	end
end

function VFXController:construct()
	self:buildLibrary()

	-- ThunderService, on the server, picks the target and keeps the beat: that way
	-- everyone sees the same bolt on the same unit.
	Framework:Listen("LightningStrike", function(position : Vector3, unitId : string?)
		self:PlayLightningStrike(position, unitId)
	end)

	Framework:Listen("LightningChain", function(links)
		self:PlayLightningChain(links)
	end)

	--[[
		The Electro's bolt. `MobController` listens to the same event to paint the enemies
		yellow: here it is only the arc, there only the highlight, and both arrive on the
		same frame.
	]]
	Framework:Listen("ChainLightning", function(arc)
		self:PlayChainLightning(arc)
	end)

	-- The Frostione's freeze: only the server knows when the stacks completed,
	-- so the notification comes from it (`MobService:ApplyFrost`).
	Framework:Listen("MobFrozen", function(mobId : string, duration : number)
		self:PlayIced(mobId, duration)
	end)

	-- The Pyre's burn: only the server knows whether the hit lit a new fire or landed
	-- on something already burning (`MobService:ApplyBurn`).
	Framework:Listen("MobBurning", function(mobId : string, duration : number)
		self:PlayBurning(mobId, duration)
	end)

	-- The Slasher's and Berserker's bleed, for the same reason (`MobService:ApplyBleed`).
	Framework:Listen("MobBleeding", function(mobId : string, duration : number)
		self:PlayBleeding(mobId, duration)
	end)

	-- The Volt's charge: only the server knows when it lands, refreshes, and pulses
	-- (`MobService:ApplyStatic`).
	Framework:Listen("MobStatic", function(mobId : string, remaining : number, burst : boolean?)
		self:PlayStatic(mobId, remaining, burst == true)
	end)

	-- The Cryomancer's ring: on when the enemy enters a ring, off when it leaves the
	-- last one (`MobService:SetAuraSlows`).
	Framework:Listen("MobAuraSlowed", function(mobId : string, on : boolean)
		self:SetFrozenAura(mobId, on == true)
	end)

	-- The Archmage's attacks that have visuals. The server decides the aim and timing
	-- (`UnitService:executeCombo`); only the drawing comes from here.
	Framework:Listen("ArchmageMeteor", function(unitId : string, aimPos : Vector3, fallTime : number, height : number)
		self:PlayMeteor(unitId, aimPos, fallTime, height)
	end)

	Framework:Listen("ArchmageLightning", function(unitId : string, throughPos : Vector3, duration : number)
		self:PlayArchmageLightning(unitId, throughPos, duration)
	end)

	Framework:Listen("AuraBonusVFX", function(unitId : string)
		self:PlayAuraBonus(unitId)
	end)

	Framework:Listen("RoundCardApplied", function(unitId : string)
		self:PlayUnitApplied(unitId)
	end)

	--[[
		The same event that lights the yellow highlight in `UnitPlacementController`. Both
		listen on purpose: the highlight applies to any stun, and the VFX only to a weather
		that has one.
	]]
	Framework:Listen("UnitStunned", function(unitId : string, duration : number, source : string?)
		self:PlayFreeze(unitId, source, duration)
	end)

	Framework:Listen("SuffocateCastVFX", function(mobId : string, assetName : string, partName : string, castTime : number)
		self:PlaySuffocateCast(mobId, assetName, partName, castTime)
	end)

	Framework:Listen("EnemyWeatherChangeVFX", function(mobId : string, assetName : string, castTime : number)
		self:PlayWeatherChangeCast(mobId, assetName, castTime)
	end)

end

function VFXController:start()
end

function VFXController:init()
	-- mobId -> the wait `SetFrozenAura` has for a model not spawned yet.
	self.FrozenAuraPending = {}

	-- mobId -> the match-clock deadline of the Volt's charge drawn on it. See `PlayStatic`.
	self.StaticUntil = {}

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return VFXController
