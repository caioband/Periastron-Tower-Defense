local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local PhysicsService = game:GetService("PhysicsService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Classes = Shared:WaitForChild("Classes")
local Utils = Shared:WaitForChild("Util")

local UIAssets = Assets:WaitForChild("UI")

local Units = Assets:WaitForChild("Units")

local UnitClass = require(Classes.Unit)

local SharedConfig = require(Configs.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local ClientConfig = require(Configs.Client)
local PointerUtil = require(Utils.PointerUtil)
local PlacementUtil = require(Utils.PlacementUtil)
local GameClock = require(Utils.GameClock)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("UnitPlacementController")
local Player = Players.LocalPlayer

local LERP_SPEED = 14
-- Cap on `replicatePlacedUnit`'s snap-to-ground. One stud covers the scale difference
-- between the ghost and the real unit; beyond that the "fix" would be the unit moving
-- somewhere else on its own.
local MAX_GROUND_SNAP = 1
local VALID_COLOR = Color3.fromRGB(0, 255, 0)
local INVALID_COLOR = Color3.fromRGB(255, 0, 0)
local COLOR_LERP_SPEED = 10


local function formatVector(v : Vector3?)
	if not v then return "nil" end
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

--[=[
	The surface the placement raycast hit, for the log: full path and class.

	The class goes along because `GetFullName` alone does not distinguish a Part from a
	MeshPart nor, above all, say the target is `Terrain` itself, which is a common hit,
	since many maps have sculpted ground, and shows up as a single instance for the
	whole map.
]=]
local function describeSurface(instance : Instance?) : string
	if not instance then
		return "nothing (the pointer hit no surface)"
	end

	return string.format("%s (%s)", instance:GetFullName(), instance.ClassName)
end

--[=[
	`base` plus the character of every player on the server.

	It is the exclusion list for the generic obstruction test: characters are not part of
	it, because `FindBlockingCharacter` answers for characters, with the whole unit's box
	and the rule of skipping accessories, which is what the server does too. Two lists
	instead of one because the ground raycast still excludes only the ghost and the player
	themself: aiming on top of another player still rests the ghost on them, and
	`FindBlockingCharacter` is what paints that red.
]=]
local function characterFilter(base : { Instance }) : { Instance }
	local list = table.clone(base)

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character and not table.find(list, character) then
			table.insert(list, character)
		end
	end

	return list
end

--[=[
	The ghost's collision group, or `nil` if it does not exist here yet.

	`CollisionService` registers it, on the server, and registration replicates. Asking
	before writing is what separates "the service did not start" from an error mid
	placement: a `CollisionGroup` with an unregistered name errors, and erroring here
	would take the whole ghost with it.
]=]
local function getGhostCollisionGroup() : string?
	local group = PlacementUtil.GhostCollisionGroup

	local ok, registered = pcall(function()
		return PhysicsService:IsCollisionGroupRegistered(group)
	end)

	if ok and registered then
		return group
	end

	log:Debug("collision group", group, "is not registered; the ghost relies on CanCollide = false only")

	return nil
end

--[=[
	The ghost's Humanoid, injected on the spot when the rig does not ship one.

	The unit rigs are hand-built R6 (MeshParts hung by Motor6D on an anchored
	HumanoidRootPart) and none of them keeps a Humanoid: the real unit's animation is
	played by the `AnimationController` the `Unit` class creates, and the idle rig needs
	nothing beyond its joints.

	The ghost does. Because of an old engine bug, Highlight does not render on transparent
	parts when the model has no Humanoid, and the ghost is semi-transparent by nature.
	Without it the model shows in its normal colors and exactly the green/red that says
	whether placement is allowed disappears.

	So it goes in quietly. `EvaluateStateMachine = false` because the state machine rules
	a character's collision: on entering a new state (Running, Landed...) it turns the
	torso's `CanCollide` back on and undoes `visualize`'s loop. And both displays are
	removed so the model name and health bar do not float over the ghost, the only trace
	a freshly created Humanoid would leave on screen.
]=]
local function prepareGhostHumanoid(ghost : Model) : Humanoid
	local humanoid = ghost:FindFirstChildOfClass("Humanoid") or Instance.new("Humanoid")

	-- Everything configured before parenting: parenting into the workspace is what
	-- triggers the first evaluation, and it must already find the machine off.
	humanoid.EvaluateStateMachine = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	-- The rig is not a character: there is no neck to watch or death to act out, and a
	-- Humanoid that thinks it died breaks the joints and drops the ghost.
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = ghost

	return humanoid
end

local TILT_MAX = math.rad(16)
local TILT_PER_STUD = 0.08
local TILT_LERP_SPEED = 10

local RING_SPIN_SPEED = 40
local DOTTED_LINE_SPIN_SPEED = 25
local SELECT_SCALE = 1.3

-- The name of the yellow stun highlight. It is looked up by name when a card
-- removes the stun early; see `UnitCleansed` in `construct`.
local STUN_HIGHLIGHT = "StunHighlight"

-- How the path is marked while the player places a unit.
local GRID_PREVIEW_COLOR = Color3.fromRGB(255, 0, 0)
local GRID_PREVIEW_MATERIAL = Enum.Material.Neon

--[[
	The entrance is a cascade, and what is configured is its TOTAL TIME, not the interval
	between parts. The interval comes from dividing by the loaded map's part count, so the
	animation lasts the same on Default (5 parts) and Mountain (206), instead of stretching
	from 0.25s to 10s depending on the map.

	GRID_PAINT_TOTAL_TIME counts from the start until the last part finishes turning red,
	so it already includes the final tween.
]]
local GRID_PAINT_TOTAL_TIME = 0.75
local GRID_PAINT_TIME = 0.25

local function getPaintStagger(count : number)
	if count <= 1 then
		return 0
	end
	return math.max(0, GRID_PAINT_TOTAL_TIME - GRID_PAINT_TIME) / (count - 1)
end

--[[
	The path parts' original appearance, stored the first time each one is painted and
	restored when placement ends.

	Weak keys: the map can change between rounds, and the old map's parts must not stay
	stuck here.
]]
local gridOriginals = setmetatable({}, { __mode = "k" })

local cachedGridParts = nil

local function invalidateGridParts()
	cachedGridParts = nil
end

--[[
	The path parts of the loaded map, and only that map.

	The scope is the clone MapService puts in `workspace.Map`. Maps live in
	ServerStorage, so the client only ever sees the loaded one; scoping to
	`workspace.Map` keeps that true even if other tagged parts ever replicate.

	The result is computed once per map and reused for every placement; the cache drops
	on RoundRestarted, when the map may have changed.

	See docs/game/unit-placement.md.
]]
local function getWorldGridParts()
	if cachedGridParts then
		return cachedGridParts
	end

	local mapRoot = workspace:FindFirstChild("Map")

	local parts = {}
	for _, part in CollectionService:GetTagged("Grid") do
		if part:IsA("BasePart") and part:IsDescendantOf(mapRoot or workspace) then
			table.insert(parts, part)
		end
	end

	-- Without the map in workspace the list may be incomplete (replication on the way),
	-- so it is not stored; otherwise an empty list would stay frozen forever.
	if mapRoot then
		cachedGridParts = parts
	end

	return parts
end

-- The cascade in progress and the live color tweens, so both can be cut the moment
-- the player drops the unit.
local gridPaintThread = nil
local gridTweens = {}

local function stopGridPaint()
	if gridPaintThread then
		pcall(task.cancel, gridPaintThread)
		gridPaintThread = nil
	end

	for part, tween in gridTweens do
		tween:Cancel()
		gridTweens[part] = nil
	end
end

-- Lights a part: Material at once, color by tween.
local function paintOneGridPart(part)
	if not part.Parent then
		return
	end

	-- Captured the moment the part goes in: parts the cascade has not reached yet
	-- stay untouched and without a snapshot.
	if not gridOriginals[part] then
		gridOriginals[part] = { material = part.Material, color = part.Color }
	end

	part.Material = GRID_PREVIEW_MATERIAL

	local tween = TweenService:Create(
		part,
		TweenInfo.new(GRID_PAINT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Color = GRID_PREVIEW_COLOR }
	)

	gridTweens[part] = tween
	tween.Completed:Once(function()
		if gridTweens[part] == tween then
			gridTweens[part] = nil
		end
	end)
	tween:Play()
end

--[[
	Lights the path in a cascade: each part switches to Neon and pulls its color to red by
	tween, staggered to fit GRID_PAINT_TOTAL_TIME.

	It advances by elapsed time, not a `task.wait(interval)` per part. With 107 parts in
	0.75s the interval is ~0.005s, well below a frame, and `task.wait` always spends a
	whole frame, which would make the cascade take 107 frames (~1.8s) instead of the
	requested 0.75s. Here each frame paints every part whose time has come, which is also
	what produces the batch feel.

	Material cannot be interpolated (it is an enum), so it switches at once the instant
	the part goes in: that is what makes it "light up". Only the color moves.
]]
local function paintGridParts(parts)
	stopGridPaint()

	local total = #parts
	if total == 0 then
		return
	end

	local stagger = getPaintStagger(total)

	gridPaintThread = task.spawn(function()
		local startedAt = os.clock()
		local nextIndex = 1

		while nextIndex <= total do
			local elapsed = os.clock() - startedAt

			while nextIndex <= total and (nextIndex - 1) * stagger <= elapsed do
				paintOneGridPart(parts[nextIndex])
				nextIndex += 1
			end

			if nextIndex <= total then
				RunService.Heartbeat:Wait()
			end
		end

		gridPaintThread = nil
	end)
end

--[[
	Restores everything at once, without a tween.

	The cascade and the color tweens are cut first: a surviving tween would keep writing
	Color after the restore and leave the part red.
]]
local function restoreGridParts(parts)
	stopGridPaint()

	for _, part in parts do
		local original = gridOriginals[part]
		if original then
			if part.Parent then
				part.Material = original.material
				part.Color = original.color
			end
			gridOriginals[part] = nil
		end
	end
end

local TILT_MAX = math.rad(16)
local TILT_PER_STUD = 0.08
local TILT_LERP_SPEED = 10

local function setDottedLineVisible(dottedLine, visible)
	if not dottedLine then return end
	for _, child in dottedLine:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "BlueCircle" then
			child.Transparency = visible and 0 or 1
		end
		if child.Name == "BlueCircle" then
			local gui = child:FindFirstChild("SurfaceGUI")
			if gui then
				local star = gui:FindFirstChild("Star")
				if star then star.Visible = visible end
			end
		end
	end
end

local function tweenRingOut(ring)
	if not ring or not ring.Parent then return end
	local currentScale = ring:GetScale()
	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = currentScale
	scaleVal.Changed:Connect(function(v)
		if ring and ring.Parent then ring:ScaleTo(v) end
	end)
	local tween = TweenService:Create(
		scaleVal,
		TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Value = 0.001 }
	)
	tween:Play()
	tween.Completed:Connect(function()
		scaleVal:Destroy()
		if ring and ring.Parent then ring:Destroy() end
	end)
end

--[[
	The ground height under a point.

	Path parts count as ground here and are not filtered: they are the trail's visible
	floor. Ignoring them would make the ray pass through the track and stop at the block
	below: a unit accepted in mid-air (on a bridge corner, on the face of a rock) would
	then be DRAWN standing on the path, far from the CFrame the server stored and aims
	from.
]]
local function raycastGroundY(position : Vector3, excludeInstances : {Instance}?)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = excludeInstances or {}

	-- The ray starts from the point itself, not above it: what matters is the ground
	-- BELOW the unit. Starting up high, the first thing hit becomes whatever is
	-- above (a tree canopy, a rock ledge) and the unit would be lifted
	-- up there.
	local result = workspace:Raycast(position, Vector3.new(0, -1000, 0), raycastParams)
	if result then
		return result.Position.Y
	end

	return nil
end

--[[
	Placement controls for touch players.

	On PC the whole flow fits in the mouse: the ghost follows the cursor, R rotates, and
	the click confirms. On mobile there is no cursor to follow nor key to rotate, and
	confirming on the tap itself would be even worse: the finger covers exactly the spot
	where the unit will be born, and the player would place the tower without seeing the
	range circle or the ghost's color.

	So a tap on the map only MOVES the ghost, and confirmation comes from here. The
	buttons sit in the right corner: the bottom-left corner is Roblox's movement
	thumbstick and the bottom center is the card bar.

	Everything here is in scale, not pixels: the same offset measurement that makes a
	comfortable button on a tablet becomes a tiny target on a narrow phone. The size
	limits only exist for the extremes: a touch target must not shrink below a finger nor
	become a poster on a large screen.
]]
--[[ MOBILE PLACEMENT ]]

--[[
	Mobile placement controls live in the shared `MobileButtons` cluster, next to `DASH`
	and `RUN`, plus one gesture:

	| Action | How |
	| `ROTATE` | the `ROTATE` button in the cluster |
	| place | two taps on the ghost |
	| cancel | tap the equipped card again |
	| lock the ghost | the `LOCK` button |

	A dedicated panel would cost screen space (a tall rectangle over the map, right where
	the player needs to see the ghost and the range circle) and speak a different
	language from the game's other touch controls.

	"You cannot place here" is the ghost's Highlight, which already paints green and red
	the whole time.
]]

--- Names in the cluster. Constants because registering and unregistering are two places.
local ROTATE_BUTTON = "Rotate"
local LOCK_BUTTON = "Lock"

--- The `ContextActionService` action that takes over the camera drag.
local TOUCH_ACTION = "UnitPlacementTouch"

--[[
	Above the camera.

	The default camera's touch pan is bound by `PlayerModule` through
	`ContextActionService`, so beating it is a matter of priority, not of disabling any
	module, which would break the day Roblox changes `PlayerModule` underneath.
]]
local TOUCH_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value

--[[
	A touch only becomes a "tap" if the finger barely moved and lifted quickly: the same
	numbers as `PointerUtil`, repeated here because there they are local and the double
	tap math is done in this file.
]]
local TAP_MAX_MOVEMENT = 20
local TAP_MAX_DURATION = 0.6

--[[
	What separates two taps from a double tap: it must be quick and in the same place.

	`DOUBLE_TAP_RADIUS` is what keeps the player from placing the unit by accident while
	only repositioning. Unlocked, the first tap already takes the ghost to where the finger
	touched, so "the two taps close to each other" is exactly the same as "the two taps
	on the ghost", just measured without depending on the ghost having arrived (it chases
	the target by lerp, and on the tap's frame it is still on its way).
]]
local DOUBLE_TAP_WINDOW = 0.45
local DOUBLE_TAP_RADIUS = 55

--[[
	How close to the ghost a tap must land to count as "on it", in pixels.

	It only applies when locked, which is when the tap moves nothing and the double tap
	really has to aim. The measure comes from the ghost's on-screen size (it changes with
	camera distance), with a comfortable floor for the finger.
]]
local GHOST_TAP_MIN_RADIUS = 60

local UnitPlacementController = {
	Controllers = {
		TargetingController = {},
		UILibraryController = {},
		CardController = {},
		VFXController = {},
		MobController = {},
		MusicController = {},
		WeatherController = {},
		WeatherFeedbackController = {},
		CardModifierController = {},
	},
	selectedUnit = nil,
	selectionHighlight = nil,
	selectionData = nil
}
UnitPlacementController.createdClasses = {}
UnitPlacementController.classesById = {}
UnitPlacementController.unitDottedLines = {}
UnitPlacementController.dottedLineData = {}
UnitPlacementController.scaleTweens = {}
UnitPlacementController.isPlacing = false
-- Total damage per unitId. Kept outside the model because the server batch may
-- arrive before `ReplicateUnit` creates the unit.
UnitPlacementController.damageDoneById = {}

function UnitPlacementController:getGroundExcludeList(extra)
	local list = {}
	for unitModel, _ in pairs(self.createdClasses) do
		table.insert(list, unitModel)
	end
	if extra then
		for _, inst in extra do
			table.insert(list, inst)
		end
	end
	return list
end

function UnitPlacementController:tweenUnitScale(unitModel, targetScale, easingDirection)
	local existing = self.scaleTweens[unitModel]
	if existing then
		existing.tween:Cancel()
		existing.value:Destroy()
		self.scaleTweens[unitModel] = nil
	end

	if not unitModel or not unitModel.Parent then return end

	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = unitModel:GetScale()
	scaleVal.Changed:Connect(function(v)
		if unitModel and unitModel.Parent then unitModel:ScaleTo(v) end
	end)

	local tween = TweenService:Create(scaleVal, TweenInfo.new(0.18, Enum.EasingStyle.Back, easingDirection), { Value = targetScale })
	self.scaleTweens[unitModel] = { tween = tween, value = scaleVal }
	tween.Completed:Connect(function()
		local current = self.scaleTweens[unitModel]
		if current and current.tween == tween then
			self.scaleTweens[unitModel] = nil
		end
		scaleVal:Destroy()
	end)
	tween:Play()
end

function UnitPlacementController:deselectCurrent()
	if self.selectedUnit and self.selectedOriginalScale and self.selectedUnit.Parent then
		self:tweenUnitScale(self.selectedUnit, self.selectedOriginalScale, Enum.EasingDirection.In)
	end
	self.selectedOriginalScale = nil

	if self.selectionHighlight then
		self.selectionHighlight:Destroy()
		self.selectionHighlight = nil
	end

	if self.selectionRingTween then
		self.selectionRingTween.tween:Cancel()
		self.selectionRingTween.value:Destroy()
		self.selectionRingTween = nil
	end
	self.selectionRing = nil
	self.selectionRingBase = nil

	if self.ringSpinConn then
		self.ringSpinConn:Disconnect()
		self.ringSpinConn = nil
	end

	if self.dottedLineSpinConn then
		self.dottedLineSpinConn:Disconnect()
		self.dottedLineSpinConn = nil
	end

	if self.AOE then
		for _, inst in self.AOE do
			tweenRingOut(inst)
		end
		table.clear(self.AOE)
	end

	if self.selectedUnit then
		local dottedLine = self.unitDottedLines[self.selectedUnit]
		setDottedLineVisible(dottedLine, false)
	end

	self.selectedUnit = nil

	self.Controllers.UILibraryController:doComponent("ToggleTower", "destroy")
end

--[=[
	A unit's range with the current weather applied.

	The circle on the ground must show the real range: during fog the unit looks for
	targets in a smaller radius, and a circle drawn at the dry range would promise
	coverage it does not have. It is the same function the server uses, just with the
	weather this client is seeing.
]=]
--[=[
	A unit's range as the server computes it: the table, with weather, times what round
	cards are doing to it.

	`position` and `unitId` are what an area card needs to answer: the Staff of the Winds
	ring only applies to units inside it. Without them (the placement ghost, which is not
	anywhere yet) only modifiers that do not depend on where the unit is apply.
]=]
function UnitPlacementController:getUnitRange(unitName : string, upgrades : number, position : Vector3?, unitId : string?) : number
	local weatherController = self.Controllers.WeatherController
	local weather = weatherController and weatherController:GetCurrent() or nil

	local range = SharedConfig.UnitUpgradeConfig:GetRange(unitName, upgrades, weather)

	local cards = self.Controllers.CardModifierController
	if cards then
		range *= cards:Multiplier("Range", unitName, position, unitId)
	end

	return range
end

--[=[
	Redoes the selected unit's circle from its current range.

	Called when range changes under the player: an upgrade bought or a weather change.
	With no unit selected (or no circle on screen) it does nothing.
]=]
function UnitPlacementController:resizeSelectionRing()
	local unitModel = self.selectedUnit
	if not unitModel or not unitModel.Parent then return end
	if not self.selectionRing or not self.selectionRing.Parent then return end
	if not self.selectionRingBase then return end

	local class = self.createdClasses[unitModel]
	local range = self:getUnitRange(
		unitModel.Name,
		unitModel:GetAttribute("Upgrades") or 0,
		unitModel:GetPivot().Position,
		class and class.unitId or nil
	)
	local scale = self.selectionRingBase.scale * (range * 2) / self.selectionRingBase.diameter

	self:tweenSelectionRing(scale)
end

function UnitPlacementController:tweenSelectionRing(targetScale)
	local ring = self.selectionRing
	if not ring or not ring.Parent then return end

	if self.selectionRingTween then
		self.selectionRingTween.tween:Cancel()
		self.selectionRingTween.value:Destroy()
		self.selectionRingTween = nil
	end

	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = ring:GetScale()
	scaleVal.Changed:Connect(function(v)
		if ring and ring.Parent then ring:ScaleTo(v) end
	end)

	local tween = TweenService:Create(scaleVal, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = targetScale })
	self.selectionRingTween = { tween = tween, value = scaleVal }
	tween.Completed:Connect(function()
		local current = self.selectionRingTween
		if current and current.tween == tween then
			self.selectionRingTween = nil
		end
		scaleVal:Destroy()
	end)
	tween:Play()
end

function UnitPlacementController:selectUnit(unitModel)
	if self.selectedUnit == unitModel then
		self:deselectCurrent()
		return
	end

	self:deselectCurrent()

	self.selectedUnit = unitModel

	local baseScale = unitModel:GetAttribute("BaseScale")
	if not baseScale then
		baseScale = unitModel:GetScale()
		unitModel:SetAttribute("BaseScale", baseScale)
	end
	self.selectedOriginalScale = baseScale
	self:tweenUnitScale(unitModel, baseScale * SELECT_SCALE, Enum.EasingDirection.Out)

	local dottedLine = self.unitDottedLines[unitModel]
	setDottedLineVisible(dottedLine, true)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(0, 255, 0)
	highlight.OutlineColor = Color3.fromRGB(0, 255, 0)
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.6
	highlight.Parent = unitModel
	self.selectionHighlight = highlight

	self.Controllers.UILibraryController:doComponent("ToggleTower", "create", unitModel)

	self.AOE = {}

	local unitPos = unitModel:GetPivot().Position
	local groundSurfaceY = raycastGroundY(unitPos, self:getGroundExcludeList({unitModel})) or unitPos.Y

	local Ring = UIAssets.AOE.Ring:Clone()
	local ringPartSel = Ring:FindFirstChild("Renge")
	local targetScale = Ring:GetScale()

	if ringPartSel then
		local upgrades = unitModel:GetAttribute("Upgrades") or 0
		local selectedClass = self.createdClasses[unitModel]
		local unitRange = self:getUnitRange(unitModel.Name, upgrades, unitPos, selectedClass and selectedClass.unitId or nil)
		local currentDiameter = ringPartSel.Size.X
		local scaleFactor = (unitRange * 2) / currentDiameter
		targetScale = Ring:GetScale() * scaleFactor
		self.selectionRingBase = { scale = Ring:GetScale(), diameter = currentDiameter }
	end

	Ring:ScaleTo(0.001)
	Ring:PivotTo(CFrame.new(unitPos.X, groundSurfaceY + Ring:GetExtentsSize().Y / 2, unitPos.Z))
	Ring.Parent = workspace.CurrentCamera
	self.selectionRing = Ring

	self:tweenSelectionRing(targetScale)

	local ringYAngle = 0
	self.ringSpinConn = RunService.Heartbeat:Connect(function(dt)
		if not Ring or not Ring.Parent then return end
		ringYAngle = ringYAngle + RING_SPIN_SPEED * dt
		Ring:PivotTo(CFrame.new(unitPos.X, groundSurfaceY + Ring:GetExtentsSize().Y / 2, unitPos.Z) * CFrame.Angles(0, math.rad(ringYAngle), 0))
	end)

	local data = self.dottedLineData[unitModel]
	if dottedLine and data then
		self.dottedLineSpinConn = RunService.Heartbeat:Connect(function(dt)
			if not dottedLine or not dottedLine.Parent then return end
			data.angle += DOTTED_LINE_SPIN_SPEED * dt
			local rot = CFrame.Angles(0, math.rad(data.angle), 0)
			for _, entry in data.dotParts do
				local rotatedOffset = rot * entry.offset
				entry.part.CFrame = CFrame.new(data.centerPos + rotatedOffset) * entry.baseCF * rot
			end
			if data.blueCircle and data.blueCircleCF then
				data.blueCircle.CFrame = data.blueCircleCF
			end
		end)
	end

	table.insert(self.AOE, Ring)

	self.Controllers.MusicController:PlaySFX("SelectSound")
end

function UnitPlacementController:replicatePlacedUnit(unitName : string, CF : CFrame, ownerUserId : number, unitId : string, upgrades : number, priority : string?)
	local unitModel = Units:FindFirstChild(unitName)
	if not unitModel then return end

	local unit = unitModel:Clone()

	for _, descendant in unit:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end

	local humanoid = unit:FindFirstChild("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end

	unit:PivotTo(CF or CFrame.new())
	unit.Parent = workspace

	--[[
		Snaps the unit to the ground. The adjustment is fine-tuning: the client computes the
		ghost's height with the model at a reduced scale, so the full-size unit is born
		about 20 cm buried.

		Hence the cap: the server rules the position, and a "fix" of meters is no fix at
		all: it is the unit ending up somewhere else. That happens when the ray starts
		inside some geometry (the bridge corner the unit was dropped on): with nothing to
		hit nearby, it goes down to the ground far below and the unit is drawn standing in
		the middle of the path, while the server keeps aiming from where it was really
		dropped.
	]]
	local boundsCF, boundsSize = unit:GetBoundingBox()
	local bottomY = boundsCF.Position.Y - boundsSize.Y / 2
	local groundSurfaceY = raycastGroundY(boundsCF.Position, self:getGroundExcludeList({unit}))
	if groundSurfaceY then
		local lift = groundSurfaceY - bottomY
		if math.abs(lift) > MAX_GROUND_SNAP then
			log:Debug(unitName, "ground correction skipped:", string.format("%.2f studs", lift),
				"is above the limit of", string.format("%.2f", MAX_GROUND_SNAP))
			groundSurfaceY = bottomY
		elseif math.abs(lift) > 0.001 then
			unit:PivotTo((CF or CFrame.new()) + Vector3.new(0, lift, 0))
		end
	else
		groundSurfaceY = bottomY
	end

	local unitPos = unit:GetPivot().Position

	log:Debug(unitName, "unit placed at", formatVector(unitPos),
		"(server CFrame:", formatVector(CF and CF.Position) .. ")",
		"owner", ownerUserId, "unitId", unitId)

	local DottedLine = UIAssets.AOE.DottedLine:Clone()
	local dottedPivot = DottedLine:GetPivot()
	DottedLine:PivotTo(CFrame.new(unitPos.X, groundSurfaceY, unitPos.Z) * dottedPivot.Rotation)
	local isOwner = ownerUserId == Player.UserId

	local blueCircle = DottedLine:FindFirstChild("BlueCircle")
	if blueCircle then
		blueCircle.CFrame = CFrame.new(unitPos.X, groundSurfaceY + blueCircle.Size.X / 2, unitPos.Z) * CFrame.Angles(0, 0, math.pi / 2)

		--[[
			The blue disc is the "this one is yours" mark: it stays lit the whole time,
			outside the on/off the dotted line gets on selection. It only makes sense under
			this player's units: on the ground of a full match, a disc under every unit of
			every player becomes noise and erases the mark.
		]]
		if not isOwner then
			blueCircle.Transparency = 1
		end
	end
	DottedLine.Parent = workspace.CurrentCamera
	setDottedLineVisible(DottedLine, false)
	self.unitDottedLines[unit] = DottedLine

	local centerPos = Vector3.new(unitPos.X, groundSurfaceY, unitPos.Z)
	local dotParts = {}
	for _, child in DottedLine:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "BlueCircle" then
			local offset = child.CFrame.Position - centerPos
			table.insert(dotParts, { part = child, offset = offset, baseCF = child.CFrame - child.CFrame.Position })
		end
	end
	self.dottedLineData[unit] = {
		angle = 0,
		blueCircleCF = blueCircle and blueCircle.CFrame or nil,
		blueCircle = blueCircle,
		centerPos = centerPos,
		dotParts = dotParts,
	}

	local class = UnitClass.new(unitName, unit)
	class.unitId = unitId
	class.isOwner = isOwner
	class.upgrades = upgrades or 0
	unit:SetAttribute("UnitID", unitId)
	unit:SetAttribute("Upgrades", upgrades or 0)
	-- Priority travels in an attribute for the same reason as level: its consumers
	-- (the card, which writes the name on the button, and TargetingController, which
	-- turns the unit) read it from the model, without going through any controller.
	unit:SetAttribute("TargetPriority", TargetPriority.Get(priority))
	unit:SetAttribute("Owned", class.isOwner)
	-- The unit's total damage; the server updates it through `UnitDamageStats` and the
	-- upgrade card listens to the attribute.
	unit:SetAttribute("DamageDone", self.damageDoneById[unitId] or 0)
	self.createdClasses[unit] = class
	self.classesById[unitId] = class

	local unitStats = SharedConfig.UnitStats[unitName]
	local skipTargeting = unitStats and (unitStats.Farm ~= nil or unitStats.Tripmine ~= nil)
	if not skipTargeting and self.Controllers.TargetingController and self.Controllers.TargetingController.RegisterUnit then
		self.Controllers.TargetingController:RegisterUnit(class)
	end

	if self.Controllers.VFXController then
		self.Controllers.VFXController:Trigger(unitName, "OnPlace", { unitModel = unit })
	end

	--[[
		A unit born in the middle of a weather (or inside a staff's ring) is born with its
		highlight and billboard already.

		The `unitId` travels along: the feedback over the unit needs to know which tower is
		which to light a single-target card (Bloxiade on one tower) on the right tower. It
		comes from here instead of being read back from `createdClasses` to avoid closing a
		cycle between the two controllers.
	]]
	if self.Controllers.WeatherFeedbackController then
		self.Controllers.WeatherFeedbackController:Register(unit, unitId)
	end

	self.Controllers.MusicController:PlaySFX("UnitPlace")
end

--[=[
	The ghost that follows the pointer: the unit model in half-tone, green where it can go
	and red where it cannot, with the range ring and the painted path.

	`options` lets the same ghost serve callers that are not placing a new unit. It exists
	for Zippers, the card that **moves a tower**: its destination goes through exactly the
	same checks as a new placement, and rewriting those checks in the card would
	guarantee the two answers diverge the first time one of them changed.

	| field | what it does |
	| --- | --- |
	| `IgnoreModel` | the tower being moved: it leaves the raycast, obstruction, and minimum distance, or the destination would be refused by the tower itself |
	| `Range` | the ring's range; without it, the table's, with no upgrade or card |
	| `Rotation` | the ghost's initial rotation, in degrees |
	| `OnConfirm(cf)` | runs instead of `PlaceUnit`, with the ghost already put away |
	| `OnCancel()` | runs instead of unequipping from the unit hotbar |

	Without `options` none of this changes: it is the usual placement, with the unit card
	equipped.
]=]
function UnitPlacementController:visualize(unitName : string, options : { [string] : any }?)
	if self.isPlacing then
		log:Debug(unitName, "cannot place: a ghost is already active")
		return
	end

	options = options or {}
	local ignoreModel = options.IgnoreModel
	local unitModel = Units:FindFirstChild(unitName)
	if not unitModel then
		log:StudioWarn(unitName, "cannot place: the model does not exist in Assets.Units")
		return
	end
	self.isPlacing = true

	local maid = Maid.new()
	self._maid = maid
	local ghost = unitModel:Clone()

	--[[
		Zippers starts with the tower's current rotation: someone who only wants to move it
		should not have to find its direction again with R, and a ghost starting at zero
		would turn every moved tower the same way.
	]]
	local currentRotation = options.Rotation or 0
	local currentColor = VALID_COLOR
	local canPlace = false
	-- Kept only so the Studio log can say why placement is blocked.
	local blockReason = "pointer is off every surface"

	--[[
		The surface the ghost is resting on, only for the log when the unit is sent.

		It moves with `targetCF`: both only change inside `if raycastResult`, so what the
		log says is that CFrame's surface, not the last one the pointer happened to touch.
	]]
	local groundInstance : Instance? = nil

	--[[
		On touch the ghost follows the finger while it is on the screen, and stays where it
		stopped when it lifts. Unlocked, dragging positions; locked, dragging goes back to
		the camera and the ghost does not move.

		It is born at the center of the screen because that is where the camera is looking:
		the player sees the unit and the range circle right away, instead of a ghost lost at
		the world origin until they touch the screen.
	]]
	local isTouch = PointerUtil.isTouchOnly()
	local touchTarget : Vector2? = if isTouch then workspace.CurrentCamera.ViewportSize / 2 else nil

	--[[
		`LOCK`. It starts unlocked: the first thing the player does is choose the spot, and
		locking before that would ask for one more tap to get started.

		`lockedPosition` is what `LOCK` actually freezes: the position in the **world**, not
		the screen point. While it exists the ghost is not re-aimed.
	]]
	local ghostLocked = false
	local lockedPosition : Vector3? = nil

	local scale = ghost:GetScale()
	ghost:ScaleTo(scale * 0.8)

	--[[
		The ghost collides with nothing, and that takes three safeguards.

		**The collision group** is what really solves it: a part in a group declared
		non-collidable with all the others does not collide, period. `CollisionService`
		registers the group, on the server: `RegisterCollisionGroup` does not run on the
		client. A registration that has not arrived is not an error: the ghost just keeps
		the other two safeguards.

		**`CanCollide = false`** is still applied, as the fallback for the above.

		**The Humanoid** is `prepareGhostHumanoid`'s job: today's rigs ship none, and without
		a Humanoid the Highlight does not paint transparent parts, leaving the ghost without
		its green/red. It goes in with the state machine off, before the model goes into the
		workspace.

		The placement queries do not change their answers because of the group: they run
		with `OverlapParams` in the `Default` group, and it is the *params*' group that
		counts, not the queried part's.
	]]
	local ghostHumanoid = prepareGhostHumanoid(ghost)

	local ghostGroup = getGhostCollisionGroup()

	for _, descendant in pairs(ghost:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false

			-- An invisible part stays invisible. The new rigs' HumanoidRootPart is an
			-- opaque 0.76-stud box that only does not show because it is at
			-- Transparency = 1; painted at 0.5 it becomes a block inside the ghost,
			-- bursting through the torso of the thinner units.
			if descendant.Transparency < 1 then
				descendant.Transparency = 0.5
			end

			if ghostGroup then
				descendant.CollisionGroup = ghostGroup
			end
		end
	end

	--[[
		The animation does not depend on the state machine: the Animator plays the track,
		and the track is requested by hand here.

		The Animator goes on the injected Humanoid, not an `AnimationController` as the
		`Unit` class does. Both play the same, and the Humanoid is already there anyway for
		the Highlight: adding an AnimationController would be a second track owner on the
		same model, with nothing in return.
	]]
	local animator = ghostHumanoid:FindFirstChildWhichIsA("Animator") or Instance.new("Animator")
	animator.Parent = ghostHumanoid

	local idleAnim = ghost:FindFirstChild("Idle")
	if idleAnim and idleAnim:IsA("Animation") then
		local track = animator:LoadAnimation(idleAnim)
		track:Play()
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.3
	highlight.FillColor = VALID_COLOR
	highlight.OutlineColor = VALID_COLOR
	highlight.Parent = ghost
	ghost.Parent = workspace

	local unitStats = SharedConfig.UnitStats[unitName]
	local unitRange = options.Range or (unitStats and unitStats.Range) or 10
	local ghostBoundsCF, ghostBoundsSize = unitModel:GetBoundingBox()
	local unitSizeX = ghostBoundsSize.X
	--[[
		Ground height before the first mouse move, only so the ring is born at the right
		height; from then on the raycast in the loop below rules.

		Measured by the ground under the player instead of a fixed part: the map is cloned at
		runtime by MapService and each map has its own, so there is no
		`workspace.GroundPart` to read.
	]]
	local character = Player.Character
	local characterPosition = character and character:GetPivot().Position
	local groundSurfaceY = 0

	if characterPosition then
		groundSurfaceY = raycastGroundY(characterPosition, self:getGroundExcludeList({ ghost, character }))
			or characterPosition.Y
	end

	local currentGroundY = groundSurfaceY

	local placementRing = UIAssets.AOE.Ring:Clone()


	local ringPart = placementRing:FindFirstChild("Renge")
	if ringPart then
		local currentDiameter = ringPart.Size.X
		local scaleFactor = (unitRange * 2) / currentDiameter
		placementRing:ScaleTo(placementRing:GetScale() * scaleFactor)
	end

	local targetRingScale = placementRing:GetScale()
	placementRing:ScaleTo(0.001)
	-- Born under the player, not at the world center: the loop only repositions the ring
	-- when the mouse hits some surface.
	local ringOrigin = characterPosition or Vector3.zero
	placementRing:PivotTo(CFrame.new(ringOrigin.X, groundSurfaceY + placementRing:GetExtentsSize().Y / 2, ringOrigin.Z))
	placementRing.Parent = workspace.CurrentCamera

	local FOOTPRINT_LIFT = 0.05
	local footprintRing : BasePart? = nil
	local footprintThickness = 0.15

	-- The same blue disc a placed tower shows under itself, sized to the tower's width
	-- (the width the spacing rule uses).
	local blueCircleTemplate = UIAssets.AOE.DottedLine:FindFirstChild("BlueCircle")
	if blueCircleTemplate then
		footprintRing = blueCircleTemplate:Clone()
		footprintThickness = blueCircleTemplate.Size.X
		footprintRing.Size = Vector3.new(footprintThickness, unitSizeX, unitSizeX)
		footprintRing.CFrame = CFrame.new(
			ringOrigin.X,
			groundSurfaceY + footprintThickness / 2 + FOOTPRINT_LIFT,
			ringOrigin.Z
		) * CFrame.Angles(0, 0, math.pi / 2)
		footprintRing.Parent = workspace.CurrentCamera
	end

	local ringScaleValue = Instance.new("NumberValue")
	ringScaleValue.Value = 0.001
	local ringTween = TweenService:Create(
		ringScaleValue,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Value = targetRingScale }
	)
	ringScaleValue.Changed:Connect(function(v)
		if placementRing and placementRing.Parent then
			placementRing:ScaleTo(v)
		end
	end)
	ringTween:Play()
	ringTween.Completed:Connect(function()
		ringScaleValue:Destroy()
	end)

	-- A distinct name on purpose: the validation loop below has its own
	-- `gridParts`, which is the result of a GetPartsInPart and unrelated.
	local paintedGridParts = getWorldGridParts()
	paintGridParts(paintedGridParts)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local ghostExtentsSize = ghost:GetExtentsSize()
	local halfHeight = ghostExtentsSize.Y / 2

	local gridProbe = Instance.new("Part")
	-- The size comes from `PathProbe`, like the server's: the unit's box plus the
	-- air column below it. The CFrame is reset on every test, below.
	local _, gridProbeSize = PlacementUtil.PathProbe(CFrame.new(), ghostBoundsSize)
	gridProbe.Size = gridProbeSize
	gridProbe.Anchored = true
	gridProbe.CanCollide = false
	gridProbe.CanQuery = false
	gridProbe.CanTouch = false
	gridProbe.Transparency = 1
	gridProbe.Parent = workspace
	maid:GiveTask(gridProbe)

	local ghostCF = ghost:GetPivot()
	local targetCF = ghostCF
	local smoothLean = Vector3.zero


	local overlapCheckElapsed = 0
	local OVERLAP_CHECK_INTERVAL = 0.05

	maid:GiveTask(RunService.RenderStepped:Connect(function(dt)
		local character = Player.Character
		local filterList = {ghost}
		if character then
			table.insert(filterList, character)
		end

		--[[
			The tower being moved leaves the aim along with the ghost. It is still standing
			at the old spot, and without this the raycast would stop on it: the player could
			not point at the ground under their own tower, and the obstruction test would
			accuse it of obstructing itself.
		]]
		if ignoreModel and ignoreModel.Parent then
			table.insert(filterList, ignoreModel)
		end
		raycastParams.FilterDescendantsInstances = filterList

		-- With a mouse the aim is where the cursor is now; on touch it is where the finger
		-- last touched, which only changes when the player touches again.
		local pointerPosition = if isTouch then touchTarget else PointerUtil.getScreenPosition()

		--[=[
			Locked, the ghost stops being re-aimed: its position becomes an anchor in the
			**world**.

			The aim is a **screen** point, and the ray comes from the camera, which moves
			with the player. Without this guard, locking would only stop the finger: two
			steps by the player would make the same screen point land elsewhere on the map,
			and the unit would slide along, exactly what `LOCK` exists to prevent.

			Validation keeps running on the anchor, and it is not wasted: the world changes
			under a still ghost (another tower is born next to it, someone stands on the
			spot) and the Highlight must follow. Rotation also still applies, because
			`targetCF` is rebuilt every frame from the anchor plus `currentRotation`.
		]=]
		local raycastResult = nil
		if not lockedPosition and pointerPosition then
			local pointerRay = workspace.CurrentCamera:ViewportPointToRay(pointerPosition.X, pointerPosition.Y)
			raycastResult = workspace:Raycast(pointerRay.Origin, pointerRay.Direction * 1000, raycastParams)
		end

		local placedPosition = lockedPosition
		if raycastResult then
			local position = raycastResult.Position
			currentGroundY = position.Y
			groundInstance = raycastResult.Instance
			placedPosition = Vector3.new(position.X, position.Y + halfHeight, position.Z)
		end

		if placedPosition then
			targetCF = CFrame.new(placedPosition) * CFrame.Angles(0, math.rad(currentRotation), 0)

			overlapCheckElapsed += dt
			if overlapCheckElapsed >= OVERLAP_CHECK_INTERVAL then
				overlapCheckElapsed = 0

				local ghostCFrameNow = CFrame.new(placedPosition) * CFrame.Angles(0, math.rad(currentRotation), 0)
				local probeCF = PlacementUtil.PathProbe(ghostCFrameNow, ghostBoundsSize)
				gridProbe.CFrame = probeCF

				local gridOverlapParams = OverlapParams.new()
				gridOverlapParams.FilterType = Enum.RaycastFilterType.Include
				gridOverlapParams.FilterDescendantsInstances = CollectionService:GetTagged("Grid")
				local gridParts = workspace:GetPartsInPart(gridProbe, gridOverlapParams)
				local onGrid = #gridParts > 0

				local isObstructed = false
				local reason = ""

				if onGrid then
					reason = string.format("on the path (%d Grid part(s) within %d studs below, first: %s)",
						#gridParts, PlacementUtil.PathClearance, gridParts[1]:GetFullName())
				end

				if not onGrid then
					--[[
						No character enters this test, neither the player's nor the others'.
						`FindBlockingCharacter` just below answers for them, and its box is the
						whole unit's: everything this test would catch on a body, that one
						already catches, and with the right rule.

						The rule that matters here is the accessory one. Hats and wings stick out
						meters past the body and are queryable parts like any other, so the hat
						of someone walking by would paint the ghost red, on a spot the server
						would accept, because there the only character test is
						`FindBlockingCharacter`, which skips accessories on purpose. A red ghost
						with the server approving is exactly the divergence `PlacementUtil`
						exists to prevent.
					]]
					local overlapParams = OverlapParams.new()
					overlapParams.FilterType = Enum.RaycastFilterType.Exclude
					overlapParams.FilterDescendantsInstances = characterFilter(filterList)
					local parts = workspace:GetPartsInPart(ghost.PrimaryPart or ghost:FindFirstChildWhichIsA("BasePart"), overlapParams)
					for _, part in ipairs(parts) do
						if part ~= raycastResult.Instance then
							isObstructed = true
							reason = "obstruido por " .. part:GetFullName()
							break
						end
					end
				end

				--[[
					Characters are a separate case because the generic test above does not catch
					them: it runs only on the ghost's HumanoidRootPart (about 0.6 stud) and also
					skips the part the raycast hit, which, when aiming at a player, is exactly
					their body. Here the box is the whole unit's, and the player themself counts:
					placing a tower inside yourself is not allowed either.
				]]
				if not onGrid and not isObstructed then
					local blockingCharacter = PlacementUtil.FindBlockingCharacter(ghostCFrameNow, ghostBoundsSize)
					if blockingCharacter then
						isObstructed = true
						reason = "on top of character " .. blockingCharacter:GetFullName()
					end
				end

				if not onGrid and not isObstructed then
					for placedUnit, _ in pairs(self.createdClasses) do
						-- The same `ignoreEntry` as `UnitService:isSpotFree` on the server:
						-- a tower is never too close to itself.
						if placedUnit == ignoreModel then continue end

						local placedPos = placedUnit:GetPivot().Position
						local otherTemplate = Units:FindFirstChild(placedUnit.Name)
						local otherSizeX = otherTemplate and select(2, otherTemplate:GetBoundingBox()).X or unitSizeX
						local minDist = (unitSizeX + otherSizeX) / 2
						local dist = (Vector3.new(placedPosition.X, 0, placedPosition.Z) - Vector3.new(placedPos.X, 0, placedPos.Z)).Magnitude
						if dist < minDist then
							isObstructed = true
							reason = string.format("too close to %s: %.2f studs (minimum %.2f)", placedUnit.Name, dist, minDist)
							break
						end
					end
				end

				canPlace = not onGrid and not isObstructed
				blockReason = reason
			end
		end

		local targetColor = canPlace and VALID_COLOR or INVALID_COLOR
		currentColor = currentColor:Lerp(targetColor, math.min(1, dt * COLOR_LERP_SPEED))
		highlight.FillColor = currentColor
		highlight.OutlineColor = currentColor

		local alpha = math.min(1, dt * LERP_SPEED)
		ghostCF = ghostCF:Lerp(targetCF, alpha)

		local remaining = targetCF.Position - ghostCF.Position
		local desiredLean = Vector3.new(remaining.X, 0, remaining.Z)
		smoothLean = smoothLean:Lerp(desiredLean, math.min(1, dt * TILT_LERP_SPEED))

		local displayCF = ghostCF
		local leanMagnitude = smoothLean.Magnitude
		if leanMagnitude > 0.001 then
			local tiltAxis = Vector3.yAxis:Cross(smoothLean.Unit)
			if tiltAxis.Magnitude > 0.001 then
				local tiltAngle = math.min(leanMagnitude * TILT_PER_STUD, TILT_MAX)
				displayCF = CFrame.new(ghostCF.Position) * CFrame.fromAxisAngle(tiltAxis.Unit, tiltAngle) * (ghostCF - ghostCF.Position)
			end
		end
		ghost:PivotTo(displayCF)

		local ghostPos = ghostCF.Position
		placementRing:PivotTo(CFrame.new(ghostPos.X, currentGroundY + placementRing:GetExtentsSize().Y / 2, ghostPos.Z))
		if footprintRing then
			footprintRing.CFrame = CFrame.new(
				ghostPos.X,
				currentGroundY + footprintThickness / 2 + FOOTPRINT_LIFT,
				ghostPos.Z
			) * CFrame.Angles(0, 0, math.pi / 2)
			footprintRing.Color = currentColor
		end
	end))

	local function rotateGhost()
		currentRotation = (currentRotation + 90) % 360
	end

	--[[
		Drops the unit where the ghost is. It lives in its own function because it has two
		entry points: the mouse click on PC and the double tap on touch.
	]]
	local function confirmPlacement()
		if not self.isPlacing then return end

		if not canPlace then
			log:Debug(unitName, "cannot place here:", blockReason ~= "" and blockReason or "unknown reason",
				"ghost at", formatVector(targetCF.Position))
			return
		end

		--[[
			It sends `targetCF`, not `ghostCF`: the ghost chases the target by lerp, so it is
			almost never exactly where the aim points. The target is what was validated by the
			path and overlap tests, and it is what must reach the server; the lerp only
			exists so the unit does not teleport on screen.

			With a mouse the difference is invisible because the cursor stays on the point
			and the ghost catches up before the click. On touch it is not: the finger confirms
			with the ghost still on its way, and the unit would be born midway.
		]]
		log:Debug(unitName, "ghost sent to the server at", formatVector(targetCF.Position),
			"| resting on", describeSurface(groundInstance))

		--[[
			The CFrame is frozen **before** the cleanup, and the notification goes out
			**after** it.

			Whoever receives `OnConfirm` usually tears down its own aiming in the same step
			(Zippers sends the card and closes the target, and closing calls this
			`unequip`). Notifying first, that would land in the middle of this body: the maid
			would be destroyed twice and `ghost` would already be gone when the cleanup got to
			it.
		]]
		local placedCF = targetCF
		local onConfirm = options.OnConfirm

		-- Restoring the path's appearance is left to the maid, just
		-- below: a single owner for both exit paths.
		placementRing:Destroy()
		ringScaleValue:Destroy()
		self.isPlacing = false
		maid:Destroy()
		ghost:Destroy()

		if onConfirm then
			onConfirm(placedCF)
			return
		end

		Framework:Fire("PlaceUnit", unitName, placedCF)

		self.Controllers.CardController:setUnequipState()
	end

	--[[
		Gives up the unit in hand. On both PC and touch it is clicking or tapping the
		equipped card again; this is the shared exit.
	]]
	local function cancelPlacement()
		--[[
			Callers that came in through `options` have their own exit: the card stays in the
			player's hand and `RoundCardShopController` releases it. Touching the unit hotbar
			here would unequip a unit card that is not even equipped.
		]]
		if options.OnCancel then
			options.OnCancel()
			return
		end

		self.Controllers.CardController:setUnequipState()
		self:unequip()
	end

	maid:GiveTask(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.KeyCode == Enum.KeyCode.R then
			rotateGhost()
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			confirmPlacement()
		end
	end))

	if isTouch then
		local mobileButtons = Framework:Get("MobileButtons")

		--[=[
			Whether the touch started on top of some interface.

			`ContextActionService` delivers the touch even when it landed on a button, so the
			question has to be asked by hand: without this, pressing `ROTATE` would teleport
			the ghost under the button itself.

			The position goes **raw**: `GetGuiObjectsAtPosition` answers in interface space,
			which is `InputObject.Position`'s. Converting here would be off by a GuiInset.
			`GuiButton` covers the buttons and `Active` covers the rest that intercepts touch
			(Roblox's thumbstick, the upgrade card).
		]=]
		local function isOverInterface(rawPosition : Vector2) : boolean
			local playerGui = Player:FindFirstChildOfClass("PlayerGui")
			if not playerGui then return false end

			for _, object in playerGui:GetGuiObjectsAtPosition(rawPosition.X, rawPosition.Y) do
				if object:IsA("GuiButton") or object.Active then
					return true
				end
			end

			return false
		end

		--[=[
			Whether a tap landed on the ghost.

			It is only asked with the ghost locked: unlocked, the pair's first tap already
			took the ghost there, and the closeness between the two taps answers the same
			question without depending on the lerp.

			The radius follows the ghost's on-screen size: the same unit takes far more
			pixels with the camera close, and a fixed radius would be generous from afar and
			tight up close. The measure comes from its box's projected height.
		]=]
		local function tapHitsGhost(rawPosition : Vector2) : boolean
			if not ghost or not ghost.Parent then return false end

			local camera = workspace.CurrentCamera
			local center, onScreen = camera:WorldToViewportPoint(ghostCF.Position)
			if not onScreen then return false end

			local top = camera:WorldToViewportPoint(ghostCF.Position + Vector3.new(0, ghost:GetExtentsSize().Y / 2, 0))
			local radius = math.max(GHOST_TAP_MIN_RADIUS, (Vector2.new(top.X, top.Y) - Vector2.new(center.X, center.Y)).Magnitude)

			local point = PointerUtil.toViewportPoint(rawPosition)
			return (point - Vector2.new(center.X, center.Y)).Magnitude <= radius
		end

		local lastTapClock = 0
		local lastTapPosition : Vector2? = nil

		--[=[
			Closes (or starts) a pair of taps.

			The second tap only places the unit if it came quickly, in the same place as the
			first, and (when locked) on the ghost. After placing, the pair is forgotten:
			without that a third tap would chain into a fourth and the gesture would keep
			counting after the unit was already born.
		]=]
		local function registerTap(rawPosition : Vector2)
			local now = os.clock()
			local previous = lastTapPosition

			local isSecond = previous ~= nil
				and (now - lastTapClock) <= DOUBLE_TAP_WINDOW
				and (rawPosition - previous).Magnitude <= DOUBLE_TAP_RADIUS

			if isSecond and (not ghostLocked or tapHitsGhost(rawPosition)) then
				lastTapPosition = nil
				confirmPlacement()
				return
			end

			lastTapClock = now
			lastTapPosition = rawPosition
		end

		--[[
			The finger in charge now. Stored by identity so a second finger on the screen
			does not hijack the drag midway: the same care the upgrade card's drag takes.
		]]
		local activeInput : InputObject? = nil
		local startPosition = Vector2.zero
		local startClock = 0
		local maxMovement = 0

		local function handleTouch(_actionName, state : Enum.UserInputState, input : InputObject)
			if input.UserInputType ~= Enum.UserInputType.Touch then
				return Enum.ContextActionResult.Pass
			end

			local raw = Vector2.new(input.Position.X, input.Position.Y)

			if state == Enum.UserInputState.Begin then
				-- A finger is already in charge, or this one started on a button: not ours.
				if activeInput or isOverInterface(raw) then
					return Enum.ContextActionResult.Pass
				end

				activeInput = input
				startPosition = raw
				startClock = os.clock()
				maxMovement = 0

				if not ghostLocked then
					touchTarget = PointerUtil.toViewportPoint(raw)
					return Enum.ContextActionResult.Sink
				end

				return Enum.ContextActionResult.Pass
			end

			if input ~= activeInput then
				return Enum.ContextActionResult.Pass
			end

			if state == Enum.UserInputState.Change then
				maxMovement = math.max(maxMovement, (raw - startPosition).Magnitude)

				if not ghostLocked then
					touchTarget = PointerUtil.toViewportPoint(raw)
					return Enum.ContextActionResult.Sink
				end

				return Enum.ContextActionResult.Pass
			end

			-- End / Cancel
			activeInput = nil

			--[[
				A drag is not a tap. Whoever dragged already said what they wanted while
				dragging (the ghost followed the finger), and letting that count as a tap would
				turn a back-and-forth drag into half a double tap.
			]]
			local wasTap = maxMovement <= TAP_MAX_MOVEMENT
				and (os.clock() - startClock) <= TAP_MAX_DURATION

			if wasTap then
				registerTap(raw)
			end

			return ghostLocked and Enum.ContextActionResult.Pass or Enum.ContextActionResult.Sink
		end

		ContextActionService:BindActionAtPriority(
			TOUCH_ACTION, handleTouch, false, TOUCH_ACTION_PRIORITY, Enum.UserInputType.Touch
		)
		maid:GiveTask(function()
			ContextActionService:UnbindAction(TOUCH_ACTION)
		end)

		if mobileButtons then
			mobileButtons:register(ROTATE_BUTTON, {
				Text = "ROTATE",
				Priority = 3,
				Slots = { "Diagonal", "FarUp", "LeftUp", "Up", "FarLeft", "Left" },
				OnActivate = rotateGhost,
			})

			mobileButtons:register(LOCK_BUTTON, {
				Text = "LOCK",
				Priority = 4,
				Slots = { "LeftUp", "FarLeft", "FarUp", "Diagonal", "Left", "Up" },
				OnActivate = function()
					ghostLocked = not ghostLocked
					mobileButtons:setActive(LOCK_BUTTON, ghostLocked)

					--[[
						Locks where the ghost **was already validated**, not where the finger is:
						`targetCF` is what passed the path and overlap tests and what would be
						sent to the server. Freezing the aim instead would leave the anchor a lerp
						behind what the player sees.
					]]
					lockedPosition = if ghostLocked then targetCF.Position else nil

					--[[
						Locking mid-drag releases the finger in charge: without that the next
						`Change` would still land in the in-charge branch and the player would have
						to lift the finger for the lock to take effect.
					]]
					activeInput = nil
				end,
			})

			maid:GiveTask(function()
				mobileButtons:unregister(ROTATE_BUTTON)
				mobileButtons:unregister(LOCK_BUTTON)
			end)
		end
	end

maid:GiveTask(function()
	if footprintRing and footprintRing.Parent then
		footprintRing:Destroy()
	end
	restoreGridParts(paintedGridParts)
	if placementRing and placementRing.Parent then
		placementRing:Destroy()
	end
	if ghost and ghost.Parent then
		ghost:Destroy()
	end
	self.isPlacing = false
	self._maid = nil
	end)
end

function UnitPlacementController:unequip()
	if not self.isPlacing then return end
	if self._maid then
		self._maid:Destroy()
		self._maid = nil
	end
end

--[=[
	Drops everything the player had in hand: the ghost following the mouse, the selected
	unit (with ring, dotted line, and upgrade panel), and the equipped hotbar card.

	The ghost is a Model in the workspace, not GUI: disabling the Interface at the end of
	the round does not make it disappear; it would keep following the mouse over the
	results screen. That is why the cleanup is explicit.
]=]
function UnitPlacementController:clearInteraction()
	self:unequip()
	self:deselectCurrent()

	local cardController = self.Controllers.CardController
	if cardController and cardController.setUnequipState then
		cardController:setUnequipState()
	end
end

--[=[
	Destroys every unit's dotted line: the end of the round.

	It is the pair of `RemoveUnit`'s loop, for when there is no `unitId` to look for. The
	lines live in `CurrentCamera`, which survives the round, and that event destroys them,
	which at match end only arrives with `ResetRound`, along with the next round. Until
	then they would stay in the Camera, already invisible (the results screen calls
	`clearInteraction`, which clears the selected tower's), taking up instances for
	nothing.

	The tower model is not touched on purpose: it stays on the map behind the results
	screen, and `ResetRound`'s `RemoveUnit` takes it down.
]=]
function UnitPlacementController:clearAllDottedLines()
	for unitModel, dottedLine in self.unitDottedLines do
		if dottedLine then
			dottedLine:Destroy()
		end
		self.dottedLineData[unitModel] = nil
	end

	table.clear(self.unitDottedLines)
	table.clear(self.dottedLineData)

	-- The rotation was the selected tower's line, and it was just destroyed.
	if self.dottedLineSpinConn then
		self.dottedLineSpinConn:Disconnect()
		self.dottedLineSpinConn = nil
	end
end

function UnitPlacementController:flashUpgrade(unitModel)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(120, 255, 140)
	highlight.OutlineColor = Color3.fromRGB(180, 255, 200)
	highlight.FillTransparency = 0.5
	highlight.OutlineTransparency = 0
	highlight.Parent = unitModel
	TweenService:Create(highlight, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()
	task.delay(0.45, function()
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end)
end

--[=[
	What is under the pointer, in the world. The player's own character is left out: it
	walks around the map and would hide the tower behind it.

	Returns the `RaycastResult`, or nil when the ray touches nothing (the sky, the edge of
	the map).
]=]
function UnitPlacementController:raycastFromPointer(screenPosition : Vector2) : RaycastResult?
	local pointerRay = workspace.CurrentCamera:ViewportPointToRay(screenPosition.X, screenPosition.Y)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	if Player.Character then
		raycastParams.FilterDescendantsInstances = {Player.Character}
	end

	return workspace:Raycast(pointerRay.Origin, pointerRay.Direction * 1000, raycastParams)
end

--- The placed unit this part belongs to, or nil.
function UnitPlacementController:findUnitAt(instance : Instance?) : Model?
	if not instance then return nil end

	for unitModel, _ in pairs(self.createdClasses) do
		if instance == unitModel or instance:IsDescendantOf(unitModel) then
			return unitModel
		end
	end

	return nil
end

--[=[
	The unit the pointer is aiming at: its model and `unitId`.

	It exists for the round cards that ask for a tower (Bloxy Cola, Bloxiade, Zippers).
	They need the **id**, which is what the server understands, and it lives in the unit's
	class, which belongs to this controller, not the model.
]=]
function UnitPlacementController:getUnitAtPointer(screenPosition : Vector2)
	local hit = self:raycastFromPointer(screenPosition)
	local unitModel = hit and self:findUnitAt(hit.Instance) or nil
	if not unitModel then return nil end

	local class = self.createdClasses[unitModel]

	return unitModel, class and class.unitId or nil
end

--[=[
	Locks (or unlocks) clicking in the world.

	While a round card is asking for a target, the click belongs to it: tower selection
	gets out of the way and returns when aiming ends or is canceled.
]=]
function UnitPlacementController:setPointerLocked(locked : boolean)
	self.pointerLocked = locked == true

	--[[
		Aiming starts with an empty hand: an equipped unit's ghost would compete for the
		same click on the map, and a selected tower's upgrade card would sit over what the
		card is asking for. `clearInteraction` drops all three at once: the ghost, the
		selection, and the hotbar card.
	]]
	if self.pointerLocked then
		self:clearInteraction()
	end
end

function UnitPlacementController:construct()
	--[[
		A mouse click on PC, a short tap on mobile: in both cases what arrives here is a
		point on the screen, and the rest of the path is the same.

		With a unit in hand that point belongs to placement (that is where it moves the
		ghost), so selection gets out of the way.
	]]
	PointerUtil.onPointerAction(function(screenPosition)
		if self.isPlacing then return end

		--[[
			A round card is asking for a target: the click is its.

			Without this door the same click would do both things (choose the tower for the
			card and select that tower), and the player would finish aiming with the upgrade
			card open over a card that just vanished. `RoundCardShopController` opens and
			closes the door (see `setPointerLocked`).
		]]
		if self.pointerLocked then return end

		local hit = self:raycastFromPointer(screenPosition)
		local foundUnit = hit and self:findUnitAt(hit.Instance) or nil

		if foundUnit then
			self:selectUnit(foundUnit)
		else
			self:deselectCurrent()
		end
	end)

	-- Safety net: if the round restarts without going through the results screen,
	-- the player is not left with a ghost or an equipped card from a finished match.
	Framework:Listen("RoundRestarted", function()
		self:clearInteraction()
		-- The map may have changed; the path part list is rebuilt on the
		-- next placement.
		invalidateGridParts()
	end)

	--[[
		The round's end from both sides (`GameOver` is the base falling, `Win` is the last
		wave cleared), and the dotted lines go in both. See `clearAllDottedLines`.
	]]
	Framework:Listen("GameOver", function()
		self:clearAllDottedLines()
	end)

	Framework:Listen("Win", function()
		self:clearAllDottedLines()
	end)

	Framework:Listen("RemoveUnit", function(unitId)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				if self.selectedUnit == unitModel then
					self:deselectCurrent()
				end
				local dottedLine = self.unitDottedLines[unitModel]
				if dottedLine then
					dottedLine:Destroy()
					self.unitDottedLines[unitModel] = nil
					self.dottedLineData[unitModel] = nil
				end
				if self.Controllers.TargetingController and self.Controllers.TargetingController.UnregisterUnit then
					self.Controllers.TargetingController:UnregisterUnit(class)
				end
				if class.Destroy then
					class:Destroy()
				end
				self.createdClasses[unitModel] = nil
				self.classesById[unitId] = nil
				self.damageDoneById[unitId] = nil
				unitModel:Destroy()

				--[[
					The tower that left was a neighbor of the others, and two cards measure
					neighborhood (Iceolated and Ice to Meet You): selling one can turn the buff
					on or off for those that remain. The sweep is also what drops this one from
					the feedback registry.
				]]
				if self.Controllers.WeatherFeedbackController then
					self.Controllers.WeatherFeedbackController:Refresh()
				end

				break
				end
			end
	end)

	Framework:Listen("UnitPriorityChanged", function(unitId, priority)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				unitModel:SetAttribute("TargetPriority", TargetPriority.Get(priority))
				break
			end
		end
	end)

	Framework:Listen("UnitUpgraded", function(unitId, newLevel)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				class.upgrades = newLevel
				unitModel:SetAttribute("Upgrades", newLevel)
				self:flashUpgrade(unitModel)

				if self.selectedUnit == unitModel then
					self:resizeSelectionRing()
				end

				self.Controllers.MusicController:PlaySFX("UnitUpgrade")
				break
			end
		end
	end)

	Framework:Listen("UnitDamageStats", function(batch)
		if typeof(batch) ~= "table" then return end

		for unitId, total in batch do
			self.damageDoneById[unitId] = total

			local class = self.classesById[unitId]
			if class and class.model and class.model.Parent then
				class.model:SetAttribute("DamageDone", total)
			end
		end
	end)

	Framework:Listen("ReplicateUnit", function(...)
		return self:replicatePlacedUnit(...)
	end)

	Framework:Listen("UnitSwing", function(unitId, unitName, targetMobId, stepIndex, swingWindow)
		local class = self.classesById[unitId]
		if not class then return end
		local mobController = self.Controllers.MobController
		local target = mobController and mobController.SpawnedMobs and mobController.SpawnedMobs[targetMobId] or nil
		class:playAttackVisual(target, stepIndex, swingWindow)
	end)

	Framework:Listen("FarmPayout", function(unitId, amount)
		local class = self.classesById[unitId]
		if not class or not class.playFarmVisual then return end
		class:playFarmVisual()
	end)

	--[[
		Weather changes the range and the card numbers, and neither redraws on its own:
		the circle is only redone when someone asks, and the card only when the selection
		changes. Here both are redone on the change, so the player sees the fog shrink the
		circle the moment it arrives.
	]]
	Framework:Listen("WeatherChanged", function()
		self:resizeSelectionRing()
		self.Controllers.UILibraryController:doComponent("ToggleTower", "refresh")
	end)

	--[=[
		A temporary highlight on a unit, so the player sees something caught it.

		Yellow is stun (the unit stopped), cyan is charge (it is better than normal). Two
		colors because both states come from the same bolt and happen side by side: without
		separating them, a charged Electric unit would look frozen.
	]=]
	local function highlightUnit(unitId, duration, color, name)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				local highlight = Instance.new("Highlight")

				--[[
					A distinct name so the highlight can be **cleared early**: the Staff of
					Healing removes the stun midway, and without a name there would be no way to
					tell this highlight from the selection's green, which lives on the same model.
				]]
				highlight.Name = name or "TempHighlight"
				highlight.FillColor = color
				highlight.OutlineColor = color
				highlight.FillTransparency = 0.6
				highlight.OutlineTransparency = 0.2
				highlight.Parent = unitModel

				--[[
					The duration comes from the server in match time, so the wait also runs on
					the match clock: at 2x the 5s stun ends in 2.5 real seconds, and the
					highlight must go off with it.
				]]
				GameClock.Delay(duration, function()
					if highlight and highlight.Parent then
						highlight:Destroy()
					end
				end)
				break
			end
		end
	end

	Framework:Listen("UnitStunned", function(unitId, duration, source)
		-- The weather freeze has its own visual, with the ice's blue Highlight
		-- (`VFXController:PlayFreeze`): yellow on top would only muddy the color.
		local effects = SharedConfig.WeatherConfig.GetEffects(source)
		if effects and effects.Freeze then return end

		highlightUnit(unitId, duration, Color3.fromRGB(255, 200, 60), STUN_HIGHLIGHT)
	end)

	Framework:Listen("UnitCharged", function(unitId, duration)
		highlightUnit(unitId, duration, Color3.fromRGB(90, 220, 255), "ChargeHighlight")
	end)

	--[=[
		The Staff of Healing removed this unit's stun early.

		The yellow highlight has its own deadline (a `GameClock.Delay` created with it) and
		cannot know the stun ended sooner: it is cleared by name. The snow freeze VFX goes
		away for the same reason, which is why `VFXController` is notified too.
	]=]
	Framework:Listen("UnitCleansed", function(unitId)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				local highlight = unitModel:FindFirstChild(STUN_HIGHLIGHT)
				if highlight then
					highlight:Destroy()
				end
				break
			end
		end

		local vfx = self.Controllers.VFXController
		if vfx and vfx.StopFreeze then
			vfx:StopFreeze(unitId)
		end
	end)
end



function UnitPlacementController:start()
end

function UnitPlacementController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return UnitPlacementController
