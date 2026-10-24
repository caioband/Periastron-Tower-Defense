local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local CutsceneFormat = require(Util.CutsceneFormat)
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local Log = require(Util:WaitForChild("Log"))
local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("CutsceneController")

--[[
	Player for Moon Animator and Eclipse Animator cutscenes.

	Reading the file lives in Shared.Util.CutsceneFormat, which understands the
	exported sources and the compressed blob of both. Only what needs live instances
	and frame-by-frame work stays here.

	An **Eclipse** scene (`format = "eclipse"`) plays on a stage: the whole scene is
	cloned into the Workspace on this client, moved so its reference lands on the
	origin, and destroyed at the end. That is what brings its scenery along, and it
	never touches the original. It also brings Screen Cover, Camera Shake, subtitles,
	and the scene's own Lighting. See `stageEclipse` and docs/common/cutscenes.md.

	What follows describes the **Moon Animator** layout.

		<SceneName>               Model
		├── SceneReferenceCFrame  Part: the scene's coordinate center. Everything is
		│                         measured from it, and it is what lands at the
		│                         origin passed to playCutscene
		├── <camera rig>          a root Part linked to CamPart by a Motor6D
		├── <actor rigs>          the Models Moon Animator animates
		├── SceneData             StringValue with the blob, after baking
		└── 1, 2, 3, ...          the save's Folders, if not baked yet

		The coordinate center can be the Model's World Pivot instead of the Part: set
		the UseWorldPivot attribute on the scene (or have no Part). See
		readSceneReference.

	The camera comes from the rig, not from the camera item's `CFrame` track. That
	track stores world CFrames baked at export time: if the scene is dragged in
	Studio, the Parts move and the baked values stay behind. The rig is C1 relative
	to the root Part, so it follows the scene wherever it goes.

	There is no AnimationId anywhere: joints are animated by writing C1, the same way
	Moon Animator does in the editor.
--]]

local DEFAULT_CUTSCENE = "EnterCutscene"

local SCENE_REFERENCE = "SceneReferenceCFrame"
local CAMERA_PART = "CamPart"

-- Name of the InterfaceController request: while the scene plays, the screen is clean.
local HIDE_REASON = "Cutscene"

-- Scene attribute: turn it on to use the Model's World Pivot as the center instead
-- of the reference Part.
local PIVOT_ATTRIBUTE = "UseWorldPivot"

local SCENE_FPS = 60

local RIG_R6 = "R6"
local RIG_R15 = "R15"

-- What is dressed from one character onto another without swapping any Part.
local APPEARANCE_CLASSES = {
	Shirt = true,
	Pants = true,
	ShirtGraphic = true,
	BodyColors = true,
}

-- The parts of an R6 or R15 body: what `removeCostume` keeps visible.
local ROOT_PART = "HumanoidRootPart"
local BODY_PARTS = {
	Head = true,
	Torso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
	UpperTorso = true,
	LowerTorso = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
}

--[[
	A rig dressed with `ReplaceCostume` gets this attribute, and its legs play upright.

	Eclipse lets an animator spin a limb 180 degrees in place and move it back: a
	plain R6 leg is a box, so the silhouette does not change, and under the rig's own
	3D clothing nobody sees it. With the player's Pants on it, the texture shows up
	upside down (`numsei1`'s left leg, from frame 2370 on). A leg pointing against its
	torso is no real pose, so on these rigs it is turned back: same box, texture up.
--]]
local UPRIGHT_LEGS_ATTRIBUTE = "CutsceneUprightLegs"
local LEGS = {
	["Left Leg"] = true,
	["Right Leg"] = true,
}
local LEG_FLIPS = {
	CFrame.Angles(0, 0, math.pi),
	CFrame.Angles(math.pi, 0, 0),
}
local LEG_FLIP_HYSTERESIS = 0.5

-- An Attachment we had to create on the rig carries this mark, so it is removed afterward.
local CREATED_ATTACHMENT = "CutsceneAttachment"

-- Where to look for the attachment point when the rig lacks the source character's
-- Part: an R15 accessory attached to LeftUpperArm goes on an R6's "Left Arm".
local PART_FALLBACKS = {
	UpperTorso = "Torso",
	LowerTorso = "Torso",
	LeftUpperArm = "Left Arm",
	LeftLowerArm = "Left Arm",
	LeftHand = "Left Arm",
	RightUpperArm = "Right Arm",
	RightLowerArm = "Right Arm",
	RightHand = "Right Arm",
	LeftUpperLeg = "Left Leg",
	LeftLowerLeg = "Left Leg",
	LeftFoot = "Left Leg",
	RightUpperLeg = "Right Leg",
	RightLowerLeg = "Right Leg",
	RightFoot = "Right Leg",

	Torso = "UpperTorso",
	["Left Arm"] = "LeftUpperArm",
	["Right Arm"] = "RightUpperArm",
	["Left Leg"] = "LeftUpperLeg",
	["Right Leg"] = "RightUpperLeg",
}

-- Moon Animator uses its own names for two styles, and "Constant" is not a tween
-- style: it is a step, the value holds until the next key.
local CONSTANT_EASE = "Constant"
local EASE_ALIASES = {
	Expo = "Exponential",
	Circ = "Circular",
}

local EASING_STYLES = {}
for _, style in Enum.EasingStyle:GetEnumItems() do
	EASING_STYLES[style.Name] = style
end

local EASING_DIRECTIONS = {}
for _, direction in Enum.EasingDirection:GetEnumItems() do
	EASING_DIRECTIONS[direction.Name] = direction
end

local warnedEases = {}

--[[
	Eclipse's `Bezier` ease: a CSS-style cubic curve from (0, 0) to (1, 1) with two
	control points, written as `Bezier|x1,y1,x2,y2` by CutsceneFormat. TweenService
	has no way to take the points, so it is solved here: find the curve parameter
	whose x is the time (bisection; x is monotonic for x1, x2 in [0, 1]), and return
	its y.
--]]
local BEZIER_EASE = "Bezier"
local BEZIER_ITERATIONS = 24

local bezierCache = {}

local function cubic(t: number, p1: number, p2: number): number
	local inverse = 1 - t
	return 3 * inverse * inverse * t * p1 + 3 * inverse * t * t * p2 + t * t * t
end

local function bezierAlpha(alpha: number, points: string?): number
	local curve = points and bezierCache[points]
	if not curve and points then
		local x1, y1, x2, y2 = string.match(points, "^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
		if x1 then
			curve = { math.clamp(tonumber(x1) :: number, 0, 1), tonumber(y1), math.clamp(tonumber(x2) :: number, 0, 1), tonumber(y2) }
			bezierCache[points] = curve
		end
	end

	if not curve then return alpha end

	local low, high = 0, 1
	for _ = 1, BEZIER_ITERATIONS do
		local middle = (low + high) / 2
		if cubic(middle, curve[1], curve[3]) < alpha then
			low = middle
		else
			high = middle
		end
	end

	return cubic((low + high) / 2, curve[2], curve[4])
end

-- Lighting children with this attribute belong to another system; LightingController
-- and LightingService leave them alone. The scene's own effects go in with it.
local LIGHTING_KEEP = SharedConfig.LightingConfig.KeepAttribute

-- The ScreenGui with the Screen Cover and the subtitles. It escapes the interface
-- hide on purpose: it is the cutscene itself.
local OVERLAY_NAME = "CutsceneOverlay"
local OVERLAY_DISPLAY_ORDER = 50
local IGNORE_INTERFACE_HIDE = "IgnoreInterfaceHide"

-- Camera Shake: how far one unit of Eclipse's `Strength` moves the camera.
local SHAKE_STUDS = 0.2
local SHAKE_DEGREES = 1.2

-- Subtitles: Eclipse sizes text against a 1080-pixel-tall screen.
local SUBTITLE_REFERENCE_HEIGHT = 1080
local SUBTITLE_ROWS = {
	Top = 0.1,
	Center = 0.5,
	Bottom = 0.9,
}

local CutsceneController = {
	Controllers = {
		InterfaceController = {},
		LightingController = {},
	},

	Signals = {
		-- (frame : number, lastFrame : number, asset : Instance)
		-- Once per scene frame, with the frame already as an integer. Anything that wants
		-- to fire near the end compares with lastFrame.
		FrameReached = Signal.new(),
	},
}

local function lerpValue(from, to, alpha: number)
	local kind = typeof(from)
	if kind == "CFrame" or kind == "Color3" then
		return from:Lerp(to, alpha)
	end

	-- A switch (an effect's `Enabled`) has no halfway: it holds until the next key.
	if kind ~= "number" and kind ~= "Vector2" and kind ~= "Vector3" then
		return from
	end

	return from + (to - from) * alpha
end

local function colorFromHex(hex: any, fallback: Color3): Color3
	if type(hex) ~= "string" then return fallback end

	local ok, color = pcall(Color3.fromHex, hex)
	return if ok then color else fallback
end

-- Eclipse names fonts by their `Enum.Font` name ("Arcade", "Gotham").
local function fontFrom(name: any, bold: boolean?, italic: boolean?): Font
	local family = Font.fromEnum(Enum.Font.GothamBold).Family

	if type(name) == "string" then
		local ok, font = pcall(function()
			return Font.fromEnum((Enum.Font :: any)[name])
		end)
		if ok and font then
			family = font.Family
		end
	end

	return Font.new(
		family,
		if bold then Enum.FontWeight.Bold else Enum.FontWeight.Regular,
		if italic then Enum.FontStyle.Italic else Enum.FontStyle.Normal
	)
end

--[[ SCENE ]]

function CutsceneController:findMotor(root: Instance, partName: string)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part1 and descendant.Part1.Name == partName then
			return descendant
		end
	end

	return nil
end

--[[
	Reads the scene once and caches the result: the data comes from CutsceneFormat,
	and here we resolve the live instances it cannot carry.
--]]
function CutsceneController:parseScene(asset: Instance)
	local cached = self.scenes[asset]
	if cached then return cached end

	local data, source = CutsceneFormat.Read(asset)
	if not data then return nil end

	-- An Eclipse scene resolves its instances on the stage, at play time.
	if data.format == "eclipse" then
		local scene = {
			eclipse = true,
			data = data,
			lastFrame = data.lastFrame,
			duration = data.lastFrame / SCENE_FPS,
			source = source,
		}

		self.scenes[asset] = scene
		return scene
	end

	local motor = self:findMotor(asset, CAMERA_PART)
	if not motor or not motor.Part0 then return nil end

	local rigs = {}
	for _, entry in data.rigs do
		local rig = asset:FindFirstChild(entry.target) or workspace:FindFirstChild(entry.target)
		if rig and rig:IsA("Model") then
			table.insert(rigs, { rig = rig, joints = entry.joints })
		else
			log:StudioWarn(string.format("cutscene %q has no rig named %q.", asset.Name, entry.target))
		end
	end

	local scene = {
		cameraMotor = motor,
		cameraKeys = data.camera,
		cameraFov = data.fov,
		rigs = rigs,
		lastFrame = data.lastFrame,
		duration = data.lastFrame / SCENE_FPS,
		source = source,
	}

	self.scenes[asset] = scene
	return scene
end

--[[ SAMPLING ]]

function CutsceneController:easeAlpha(alpha: number, ease: string?)
	if not ease then return alpha end

	local name, direction = string.match(ease, "^([^|]+)|(.+)$")
	name = name or ease

	if name == "Linear" then return alpha end
	if name == CONSTANT_EASE then return 0 end

	if name == BEZIER_EASE then
		return bezierAlpha(alpha, direction)
	end

	local style = EASING_STYLES[EASE_ALIASES[name] or name]
	if not style then
		if not warnedEases[name] then
			warnedEases[name] = true
			log:StudioWarn(string.format("unknown ease %q, falling back to Linear.", name))
		end
		return alpha
	end

	-- TweenService refuses some styles (Spring, and Bezier without its points). An
	-- error here would stop the whole frame, camera included, every frame after it.
	local ok, value = pcall(TweenService.GetValue, TweenService, alpha, style, EASING_DIRECTIONS[direction or "In"] or Enum.EasingDirection.In)
	if not ok then
		if not warnedEases[name] then
			warnedEases[name] = true
			log:StudioWarn(string.format("ease %q cannot be evaluated, falling back to Linear.", name))
		end
		return alpha
	end

	return value
end

--[[
	Samples a track. The cursor only moves forward, so the per-frame cost is constant
	instead of scanning the whole list.
--]]
function CutsceneController:sampleTrack(track, frame: number)
	local keys = track.keys
	local cursor = track.cursor

	while cursor < #keys and keys[cursor + 1].frame <= frame do
		cursor += 1
	end
	track.cursor = cursor

	local from = keys[cursor]
	local to = keys[cursor + 1]
	if not to or frame <= from.frame then return from.value end

	local span = to.frame - from.frame
	local alpha = span > 0 and (frame - from.frame) / span or 1
	return lerpValue(from.value, to.value, self:easeAlpha(alpha, to.ease))
end

--[[ ACTORS ]]

--[[
	Puts a rig in the scene and returns the joints ready to receive C1 per frame.

	A rig stored with the scene is a template: it goes in cloned and comes out
	destroyed. A rig that already lives in the world is used in place, with its
	position and C1 restored at the end.
--]]
function CutsceneController:prepareRig(parsed, sessionMaid, origin: CFrame, reference: CFrame)
	local rig = parsed.rig
	local isClone = not rig:IsDescendantOf(workspace)
	if isClone then
		rig = rig:Clone()
	end

	local motors = {}
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part1 then
			motors[descendant.Part1.Name] = descendant
		end
	end

	local tracks = {}
	for _, joint in parsed.joints do
		local motor = motors[joint.partName]
		if not motor then continue end

		local restC1 = motor.C1
		sessionMaid:GiveTask(function()
			motor.C1 = restC1
		end)

		table.insert(tracks, { motor = motor, keys = joint.keys, cursor = 1 })
	end

	local offset = reference:ToObjectSpace(rig:GetPivot())

	if isClone then
		sessionMaid:GiveTask(rig)
		rig.Parent = workspace
	else
		local restPivot = rig:GetPivot()
		sessionMaid:GiveTask(function()
			rig:PivotTo(restPivot)
		end)
	end

	rig:PivotTo(origin * offset)
	return tracks
end

--[[ APPEARANCE ]]

--[[
	R6 or R15, read from the Parts and not the Humanoid: a cutscene rig does not
	always have one. Returns nil for a Model that is not a character.
--]]
function CutsceneController:readRigType(rig: Instance): string?
	if rig:FindFirstChild("UpperTorso") or rig:FindFirstChild("LowerTorso") then
		return RIG_R15
	end

	if rig:FindFirstChild("Torso") and rig:FindFirstChild("Head") then
		return RIG_R6
	end

	local humanoid = rig:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		return humanoid.RigType == Enum.HumanoidRigType.R15 and RIG_R15 or RIG_R6
	end

	return nil
end

--[[
	A scene's character rigs. `rigName` filters by name, for a scene with more than one
	actor where only one is the player.

		for _, entry in CutsceneController:getSceneRigs(scene) do
			print(entry.rig.Name, entry.rigType)   --> playerportal R6
		end
--]]
function CutsceneController:getSceneRigs(asset: Instance, rigName: string?)
	local rigs = {}

	for _, descendant in asset:GetDescendants() do
		if not descendant:IsA("Model") then continue end
		if rigName and descendant.Name ~= rigName then continue end

		local rigType = self:readRigType(descendant)
		if not rigType then continue end

		table.insert(rigs, {
			rig = descendant,
			rigType = rigType,
			humanoid = descendant:FindFirstChildWhichIsA("Humanoid"),
		})
	end

	return rigs
end

--[[
	A character's face. `GetCharacterAppearanceAsync` returns the Decal loose in the
	model; the live character carries it inside the Head.
--]]
function CutsceneController:findFace(character: Instance): Decal?
	local head = character:FindFirstChild("Head")
	local decal = head and head:FindFirstChildWhichIsA("Decal")

	return decal or character:FindFirstChildWhichIsA("Decal")
end

--[[
	Copies the face: the Decal id on the character's Head goes to the Decal on the
	rig's Head.

	That is all, and it works for both types: R6 and R15 store the face the same way,
	in a Decal on the Head. Returns the function that puts the old id back, or nil
	when one of the two sides has no Decal at all.
--]]
function CutsceneController:copyFace(rig: Model, character: Instance): (() -> ())?
	local sourceFace = self:findFace(character)
	local rigFace = self:findFace(rig)

	if not sourceFace then
		log:StudioWarn(string.format("%q has no face Decal in its Head to copy.", character.Name))
		return nil
	end

	if not rigFace then
		log:StudioWarn(string.format("rig %q has no face Decal in its Head.", rig.Name))
		return nil
	end

	local previousTexture = rigFace.Texture
	rigFace.Texture = sourceFace.Texture

	return function()
		rigFace.Texture = previousTexture
	end
end

--[[
	The rig point where an accessory attaches.

	If the rig lacks that Attachment (an R6 does not have all of an R15's points), it
	is created from the same point on the source character, at the same relative
	position, corrected by the size difference between the two Parts. It is marked
	for removal afterward.
--]]
function CutsceneController:findRigAttachment(rig: Model, name: string, source: Instance?): Attachment?
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == name and descendant.Parent and descendant.Parent:IsA("BasePart") then
			return descendant
		end
	end

	if not source then return nil end

	for _, descendant in source:GetDescendants() do
		if not descendant:IsA("Attachment") or descendant.Name ~= name then continue end

		local sourcePart = descendant.Parent
		if not sourcePart or not sourcePart:IsA("BasePart") then continue end

		local fallback = PART_FALLBACKS[sourcePart.Name]
		local rigPart = rig:FindFirstChild(sourcePart.Name) or (fallback and rig:FindFirstChild(fallback))
		if not rigPart or not rigPart:IsA("BasePart") then continue end

		local rotation = descendant.CFrame - descendant.CFrame.Position
		local position = descendant.Position * (rigPart.Size / sourcePart.Size)

		local created = Instance.new("Attachment")
		created.Name = name
		created.CFrame = CFrame.new(position) * rotation
		created:SetAttribute(CREATED_ATTACHMENT, true)
		created.Parent = rigPart

		return created
	end

	return nil
end

--[[
	Hangs an accessory on a rig. It is what `AddAccessory` does, by hand, and by hand
	because the clone arrives with the source character's weld inside the Handle,
	pointing outside the clone: at the real player's Head. With `AddAccessory` the
	accessory would end up on the character's head, which the cutscene hides.

	`source` is the character the accessory came from, used only to find an
	attachment point the rig does not have.
--]]
function CutsceneController:weldAccessory(rig: Model, accessory: Instance, source: Instance?): boolean
	local handle = accessory:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then return false end

	for _, descendant in handle:GetDescendants() do
		if descendant:IsA("JointInstance") then
			descendant:Destroy()
		end
	end

	handle.Anchored = false
	handle.CanCollide = false
	handle.Massless = true

	local weld = Instance.new("Weld")
	weld.Name = "AccessoryWeld"
	weld.Part0 = handle

	local attachment = handle:FindFirstChildWhichIsA("Attachment")
	local target = attachment and self:findRigAttachment(rig, attachment.Name, source)

	if target then
		weld.Part1 = target.Parent
		weld.C0 = attachment.CFrame
		weld.C1 = target.CFrame
	else
		-- An old accessory, without an Attachment: the fit comes from its properties.
		local head = rig:FindFirstChild("Head")
		if not head or not head:IsA("BasePart") or not accessory:IsA("Accoutrement") then
			weld:Destroy()
			return false
		end

		weld.Part1 = head
		weld.C0 = accessory.AttachmentPoint
		weld.C1 = CFrame.new(
			accessory.AttachmentPos.X, accessory.AttachmentPos.Y, accessory.AttachmentPos.Z,
			accessory.AttachmentRight.X, accessory.AttachmentUp.X, accessory.AttachmentForward.X,
			accessory.AttachmentRight.Y, accessory.AttachmentUp.Y, accessory.AttachmentForward.Y,
			accessory.AttachmentRight.Z, accessory.AttachmentUp.Z, accessory.AttachmentForward.Z
		)
	end

	weld.Parent = handle
	accessory.Parent = rig

	return true
end

--[[
	Takes off the rig's own costume, for a rig that stands for the player but was
	authored as a character of its own (the intro's `numsei1`):

	- parts **welded** to the body that are not body parts (3D clothing, a hair Part
	  welded straight to the Head) turn invisible;
	- body parts that were invisible under that clothing (the Torso) show again;
	- of the Decals on the Head, only the first stays, the one `copyFace` writes the
	  player's face into: an authored face is often two Decals (eyes and mouth).

	A part moved by a Motor6D stays: it is animated, so it is a prop the scene uses
	(a weapon in the hand), not clothing. Accessories are not touched here; the
	caller detaches them. Everything is written into `restores`.
--]]
function CutsceneController:removeCostume(rig: Model, restores: { () -> () })
	local animated = {}
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part1 then
			animated[descendant.Part1] = true
		end
	end

	local function setTransparency(instance: BasePart | Decal, value: number)
		local previous = instance.Transparency
		if previous == value then return end

		instance.Transparency = value
		table.insert(restores, function()
			instance.Transparency = previous
		end)
	end

	for _, descendant in rig:GetDescendants() do
		if not descendant:IsA("BasePart") or descendant:FindFirstAncestorWhichIsA("Accoutrement") then continue end

		if BODY_PARTS[descendant.Name] then
			setTransparency(descendant, 0)
		elseif descendant.Name ~= ROOT_PART and not animated[descendant] then
			setTransparency(descendant, 1)
		end
	end

	local face = self:findFace(rig)
	local head = rig:FindFirstChild("Head")

	for _, decal in head and head:GetChildren() or {} do
		if decal:IsA("Decal") then
			setTransparency(decal, if decal == face then 0 else 1)
		end
	end

	-- The player's Pants show what the costume hid; see `UPRIGHT_LEGS_ATTRIBUTE`.
	rig:SetAttribute(UPRIGHT_LEGS_ATTRIBUTE, true)
	table.insert(restores, function()
		rig:SetAttribute(UPRIGHT_LEGS_ATTRIBUTE, nil)
	end)
end

--[[
	For an upright leg (see `UPRIGHT_LEGS_ATTRIBUTE`): the joints that hang things on
	it (accessory welds, a Motor6D whose Part0 it is), so a turned leg can carry them
	along without moving them.
--]]
function CutsceneController:collectLegJoints(rig: Model, leg: BasePart, ownMotor: Motor6D)
	local joints = {}

	for _, descendant in rig:GetDescendants() do
		if not descendant:IsA("JointInstance") or descendant == ownMotor then continue end

		if descendant.Part0 == leg then
			table.insert(joints, { joint = descendant, property = "C0", original = descendant.C0 })
		elseif descendant.Part1 == leg then
			table.insert(joints, { joint = descendant, property = "C1", original = descendant.C1 })
		end
	end

	return joints
end

--[[
	The C1 of an upright leg on this frame. When the pose points the leg against its
	torso, the leg is turned 180 degrees about its own center, around whichever axis
	leaves its front closest to the torso's front: the same box, texture up.

	`Part1 = Part0 * C0 * C1:Inverse()` with the leg's pose `rel` gives
	`C1 = rel:Inverse() * C0`. Whatever hangs on the leg gets the inverse turn
	(`flip` is its own inverse), only when the state changes.
--]]
function CutsceneController:uprightLegC1(track, transform: CFrame): CFrame
	local motor = track.motor
	local rel = motor.C0 * transform * track.rest:Inverse()

	local upright = track.upright

	local flip = nil
	if rel.UpVector.Y < -0.5 then
		-- The axis in use stays until the other is clearly better: with the leg
		-- sideways both are close, and switching would swap the Pants' front and back.
		local best = -math.huge
		for _, candidate in LEG_FLIPS do
			local alignment = -(rel * candidate).LookVector.Z
			if candidate == upright.flip then
				alignment += LEG_FLIP_HYSTERESIS
			end

			if alignment > best then
				best, flip = alignment, candidate
			end
		end
	end

	if flip ~= upright.flip then
		upright.flip = flip
		for _, entry in upright.joints do
			entry.joint[entry.property] = if flip then flip * entry.original else entry.original
		end
	end

	if flip then
		rel *= flip
	end

	return rel:Inverse() * motor.C0
end

--[[
	Dresses a scene rig with a character's appearance: clothing, body colors, face,
	and accessories. `source` is the Player (uses their Character, or downloads the
	appearance if they do not have one at the moment) or a ready character Model.

	`options.ReplaceCostume` also takes off what the rig wears that is not clothing
	nor an accessory (see `removeCostume`).

	No Part is swapped: an R15's package MeshParts stay as they are. Swapping Parts
	would mean destroying the Motor6Ds the scene animates, and the joint carries the
	whole animation. That is why an R15 dressed onto an R6 rig (or the reverse) works:
	what travels is clothing, color, face, and accessories, which apply to both.

	Returns a function that undoes everything: the scene rig is the original instance,
	so without undoing, the next player enters the portal wearing the previous one's
	clothes. Call it before `playCutscene`: after that the joints have already been
	read.
--]]
function CutsceneController:applyCharacter(rig: Model, source: Player | Model, options: { ReplaceCostume: boolean? }?): (() -> ())?
	local appearance: Instance? = source :: any
	local temporary = false

	if typeof(source) == "Instance" and source:IsA("Player") then
		appearance = source.Character

		if not appearance then
			local success, result = pcall(function()
				return Players:GetCharacterAppearanceAsync(source.UserId)
			end)

			if not success or not result then
				log:StudioWarn(string.format("could not read the appearance of %s.", source.Name))
				return nil
			end

			appearance, temporary = result, true
		end
	end

	if not appearance then return nil end

	local restores = {}

	local function detach(instance: Instance)
		local parent = instance.Parent
		instance.Parent = nil

		table.insert(restores, function()
			instance.Parent = parent
		end)
	end

	local function attach(instance: Instance, parent: Instance)
		instance.Parent = parent

		table.insert(restores, function()
			instance:Destroy()
		end)
	end

	-- What the rig was already wearing leaves the scene (without being destroyed) and returns at the end.
	for _, child in rig:GetChildren() do
		if APPEARANCE_CLASSES[child.ClassName] or child:IsA("Accessory") then
			detach(child)
		end
	end

	-- Before the player's accessories go in: their Handles are welded parts too.
	if options and options.ReplaceCostume then
		self:removeCostume(rig, restores)
	end

	-- BodyColors writes the color into the Parts: removing the object afterward does not
	-- restore the rig, so each Part's color is saved by hand, and saved here, before the
	-- new pieces go in, so on the way back it is applied after they leave.
	if appearance:FindFirstChildOfClass("BodyColors") then
		for _, descendant in rig:GetDescendants() do
			if not descendant:IsA("BasePart") then continue end

			local previous = descendant.Color
			table.insert(restores, function()
				descendant.Color = previous
			end)
		end
	end

	for _, child in appearance:GetChildren() do
		if APPEARANCE_CLASSES[child.ClassName] then
			attach(child:Clone(), rig)
		elseif child:IsA("Accoutrement") then
			local accessory = child:Clone()

			if self:weldAccessory(rig, accessory, appearance) then
				table.insert(restores, function()
					accessory:Destroy()
				end)
			else
				log:StudioWarn(string.format("could not attach %q to rig %q.", child.Name, rig.Name))
				accessory:Destroy()
			end
		end
	end

	local restoreFace = self:copyFace(rig, appearance)
	if restoreFace then
		table.insert(restores, restoreFace)
	end

	-- An attachment point the rig lacked and had to be created leaves too.
	table.insert(restores, function()
		for _, descendant in rig:GetDescendants() do
			if descendant:IsA("Attachment") and descendant:GetAttribute(CREATED_ATTACHMENT) then
				descendant:Destroy()
			end
		end
	end)

	if temporary then
		appearance:Destroy()
	end

	return function()
		-- In reverse: the clones leave before the colors and original pieces return.
		for index = #restores, 1, -1 do
			restores[index]()
		end
	end
end

--[[
	Dresses every rig of a scene at once (or only the one named `rigName`) and returns
	a function that undoes everything. `options` goes to `applyCharacter`.
--]]
function CutsceneController:dressScene(asset: Instance, source: Player | Model, rigName: string?, options: { ReplaceCostume: boolean? }?): () -> ()
	local restores = {}

	for _, entry in self:getSceneRigs(asset, rigName) do
		local restore = self:applyCharacter(entry.rig, source, options)
		if restore then
			table.insert(restores, restore)
		end
	end

	return function()
		for _, restore in restores do
			restore()
		end
	end
end

--[[
	The frame driver of a Moon Animator scene: the rigs go in through `prepareRig`,
	and `step(frame)` writes the camera and the joints' C1.
--]]
function CutsceneController:buildMoonDriver(scene, sessionMaid, origin: CFrame, reference: CFrame, camera: Camera)
	-- The camera is the Motor6D's Part1: Part0 * C0 * Transform * C1:Inverse(), with
	-- Transform at rest. Everything before C1 is constant, so it is resolved once.
	local motor = scene.cameraMotor
	local cameraBase = origin * reference:ToObjectSpace(motor.Part0.CFrame * motor.C0)

	local cameraTrack = { keys = scene.cameraKeys, cursor = 1 }
	local fovTrack = scene.cameraFov and { keys = scene.cameraFov, cursor = 1 }

	local jointTracks = {}
	for _, parsed in scene.rigs do
		for _, track in self:prepareRig(parsed, sessionMaid, origin, reference) do
			table.insert(jointTracks, track)
		end
	end

	local driver = {}

	function driver.step(frame: number)
		camera.CFrame = cameraBase * self:sampleTrack(cameraTrack, frame):Inverse()

		if fovTrack then
			camera.FieldOfView = self:sampleTrack(fovTrack, frame)
		end

		for _, track in jointTracks do
			track.motor.C1 = self:sampleTrack(track, frame)
		end
	end

	function driver.finalCamera(): CFrame
		return cameraBase * self:sampleTrack(cameraTrack, scene.lastFrame):Inverse()
	end

	return driver
end

--[[ ECLIPSE ]]

--[[
	The screen the cutscene draws on: Screen Cover and subtitles. `IgnoreInterfaceHide`
	keeps it out of `InterfaceController:Hide`, which the scene itself asks for.
--]]
function CutsceneController:createOverlay(sessionMaid): ScreenGui
	local overlay = Instance.new("ScreenGui")
	overlay.Name = OVERLAY_NAME
	overlay.IgnoreGuiInset = true
	overlay.ResetOnSpawn = false
	overlay.DisplayOrder = OVERLAY_DISPLAY_ORDER
	overlay.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	overlay:SetAttribute(IGNORE_INTERFACE_HIDE, true)
	overlay.Parent = self.player:WaitForChild("PlayerGui")

	sessionMaid:GiveTask(overlay)
	return overlay
end

--[[
	The scene's Lighting folder (preset format: attributes are Lighting properties,
	children go inside Lighting) takes over while the scene plays, and the previous
	lighting comes back at the end.

	A transition still running is cut first (`LightingController:Skip`), so it does
	not keep writing over the scene. The scene's effects carry `LightingKeep`, which
	keeps LightingController from treating them as part of a preset if one arrives
	in the meantime.
--]]
function CutsceneController:applySceneLighting(folder: Instance?, sessionMaid)
	if not folder then return end

	local lightingController = self.Controllers.LightingController
	if lightingController and lightingController.Skip then
		pcall(lightingController.Skip, lightingController)
	end

	local previous = {}
	for property, value in folder:GetAttributes() do
		local ok, current = pcall(function()
			return (Lighting :: any)[property]
		end)

		if ok and pcall(function() (Lighting :: any)[property] = value end) then
			previous[property] = current
		end
	end

	local hidden = {}
	for _, child in Lighting:GetChildren() do
		if child:GetAttribute(LIGHTING_KEEP) == true then continue end

		table.insert(hidden, child)
		child.Parent = nil
	end

	local added = {}
	for _, child in folder:GetChildren() do
		local clone = child:Clone()
		clone:SetAttribute(LIGHTING_KEEP, true)
		clone.Parent = Lighting
		table.insert(added, clone)
	end

	sessionMaid:GiveTask(function()
		for _, clone in added do
			clone:Destroy()
		end

		-- A child the server destroyed in the meantime cannot come back; pcall.
		for _, child in hidden do
			pcall(function()
				child.Parent = Lighting
			end)
		end

		for property, value in previous do
			pcall(function()
				(Lighting :: any)[property] = value
			end)
		end
	end)
end

--[[
	The value of an effect property on this frame: its track if it has one, the
	authored default if not.
--]]
function CutsceneController:sampleEffect(effect, property: string, frame: number)
	local track = effect.tracks[property]
	if track then
		return self:sampleTrack(track, frame)
	end
	return effect.defaults[property]
end

--[[
	Builds the Eclipse effects. Returns a function that updates them for a frame and
	answers the camera offset (Camera Shake), identity when nothing shakes.

	- **Screen Cover**: a Frame over the whole screen. `Size` and `Position` are in
	  screen scale, `Position` measured from the center.
	- **Camera Shake**: noise on the camera, `Strength` times `SHAKE_STUDS` and
	  `SHAKE_DEGREES`, at a frequency that grows with `Speed`. Eclipse's own curve is
	  not documented; this is an approximation.
--]]
function CutsceneController:buildEffects(effects, overlay: ScreenGui)
	local covers, shakes = {}, {}

	for _, entry in effects do
		local effect = { defaults = entry.defaults, tracks = {} }
		for property, keys in entry.tracks do
			effect.tracks[property] = { keys = keys, cursor = 1 }
		end

		if entry.kind == "Screen Cover" then
			local cover = Instance.new("Frame")
			cover.Name = "ScreenCover"
			cover.AnchorPoint = Vector2.new(0.5, 0.5)
			cover.BorderSizePixel = 0
			cover.BackgroundTransparency = 1
			cover.ZIndex = 1
			cover.Parent = overlay

			effect.frame = cover
			table.insert(covers, effect)
		elseif entry.kind == "Camera Shake" then
			table.insert(shakes, effect)
		else
			log:StudioWarnOnce("effect:" .. tostring(entry.kind), string.format("Eclipse effect %q is not supported; it is skipped.", tostring(entry.kind)))
		end
	end

	return function(frame: number): CFrame
		for _, effect in covers do
			local cover = effect.frame
			local enabled = self:sampleEffect(effect, "Enabled", frame)
			local color = self:sampleEffect(effect, "Color", frame)
			local transparency = self:sampleEffect(effect, "Transparency", frame)
			local size = self:sampleEffect(effect, "Size", frame)
			local position = self:sampleEffect(effect, "Position", frame)
			local rotation = self:sampleEffect(effect, "Rotation", frame)

			cover.Visible = enabled ~= false
			cover.BackgroundColor3 = if typeof(color) == "Color3" then color else Color3.new()
			cover.BackgroundTransparency = if type(transparency) == "number" then math.clamp(transparency, 0, 1) else 1
			cover.Size = if typeof(size) == "Vector2" then UDim2.fromScale(size.X, size.Y) else UDim2.fromScale(1, 1)
			cover.Position = if typeof(position) == "Vector2"
				then UDim2.fromScale(0.5 + position.X, 0.5 + position.Y)
				else UDim2.fromScale(0.5, 0.5)
			cover.Rotation = if type(rotation) == "number" then rotation else 0
		end

		local offset = CFrame.identity
		for _, effect in shakes do
			if self:sampleEffect(effect, "Enabled", frame) == false then continue end

			local strength = self:sampleEffect(effect, "Strength", frame)
			if type(strength) ~= "number" or strength <= 0 then continue end

			local speed = self:sampleEffect(effect, "Speed", frame)
			local time = frame / SCENE_FPS * (if type(speed) == "number" then speed else 12)

			local function noise(seed: number): number
				return math.noise(time, seed + 0.37)
			end

			local studs = strength * SHAKE_STUDS
			local angle = math.rad(strength * SHAKE_DEGREES)

			offset *= CFrame.new(noise(1) * studs, noise(2) * studs, 0)
				* CFrame.Angles(noise(3) * angle, noise(4) * angle, noise(5) * angle * 0.5)
		end

		return offset
	end
end

--[[
	Builds the subtitle box. Returns a function that shows, for a frame, the subtitle
	that started last and has not ended yet.

	Eclipse has many entrance presets ("Letter slide", "Word spring", ...); here every
	entrance is a typewriter reveal with a fade over `inFrames`, and every exit a
	fade over `outFrames`. Text, speaker, font, size, colors, outline, background,
	width, position row, and alignment come from the subtitle.
--]]
function CutsceneController:buildSubtitles(subtitles, overlay: ScreenGui)
	if #subtitles == 0 then
		return function() end
	end

	local box = Instance.new("Frame")
	box.Name = "Subtitle"
	box.AnchorPoint = Vector2.new(0.5, 1)
	box.AutomaticSize = Enum.AutomaticSize.Y
	box.BorderSizePixel = 0
	box.ZIndex = 5
	box.Visible = false
	box.Parent = overlay

	local corner = Instance.new("UICorner")
	corner.Parent = box

	local padding = Instance.new("UIPadding")
	padding.Parent = box

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.Parent = box

	local function makeLabel(name: string, order: number): (TextLabel, UIStroke)
		local label = Instance.new("TextLabel")
		label.Name = name
		label.LayoutOrder = order
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextWrapped = true
		label.RichText = false
		label.ZIndex = 6
		label.Parent = box

		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.Parent = label

		return label, stroke
	end

	local speakerLabel, speakerStroke = makeLabel("Speaker", 1)
	local textLabel, textStroke = makeLabel("Text", 2)

	local shown = nil
	local graphemes = 0

	local function style(subtitle)
		local camera = workspace.CurrentCamera
		local scale = (camera and camera.ViewportSize.Y or SUBTITLE_REFERENCE_HEIGHT) / SUBTITLE_REFERENCE_HEIGHT

		local row = SUBTITLE_ROWS[subtitle.position] or SUBTITLE_ROWS.Bottom
		box.AnchorPoint = Vector2.new(0.5, if row >= 0.5 then 1 else 0)
		box.Position = UDim2.fromScale(0.5 + (tonumber(subtitle.x) or 0), row + (tonumber(subtitle.y) or 0))
		box.Size = UDim2.fromScale(math.clamp(tonumber(subtitle.width) or 0.65, 0.1, 1), 0)
		box.BackgroundColor3 = colorFromHex(subtitle.background, Color3.new())
		box.BackgroundTransparency = 1 - math.clamp(tonumber(subtitle.backgroundOpacity) or 0, 0, 1)
		corner.CornerRadius = UDim.new(0, 8 * scale)

		local inset = UDim.new(0, 12 * scale)
		padding.PaddingTop, padding.PaddingBottom, padding.PaddingLeft, padding.PaddingRight = inset, inset, inset, inset

		local alignment = if subtitle.align == "Left" then Enum.TextXAlignment.Left
			elseif subtitle.align == "Right" then Enum.TextXAlignment.Right
			else Enum.TextXAlignment.Center

		textLabel.Text = subtitle.text
		textLabel.TextXAlignment = alignment
		textLabel.FontFace = fontFrom(subtitle.font, subtitle.bold, subtitle.italic)
		textLabel.TextSize = math.max(12, (tonumber(subtitle.size) or 48) * scale)
		textLabel.TextColor3 = colorFromHex(subtitle.color, Color3.new(1, 1, 1))
		textStroke.Color = colorFromHex(subtitle.outlineColor, Color3.new())
		textStroke.Thickness = (tonumber(subtitle.outline) or 0) * 2 * scale
		textStroke.Enabled = (tonumber(subtitle.outline) or 0) > 0

		local speaker = if type(subtitle.speaker) == "string" then subtitle.speaker else ""
		speakerLabel.Visible = speaker ~= ""
		speakerLabel.Text = speaker
		speakerLabel.TextXAlignment = alignment
		speakerLabel.FontFace = fontFrom(subtitle.nameFont, true, false)
		speakerLabel.TextSize = math.max(10, (tonumber(subtitle.nameSize) or 21) * scale)
		speakerLabel.TextColor3 = colorFromHex(subtitle.nameColor, Color3.new(1, 1, 1))
		speakerStroke.Color = textStroke.Color
		speakerStroke.Thickness = textStroke.Thickness
		speakerStroke.Enabled = textStroke.Enabled

		graphemes = utf8.len(subtitle.text) or #subtitle.text
	end

	return function(frame: number)
		local current = nil
		for _, subtitle in subtitles do
			if subtitle.frame > frame then break end
			if frame < subtitle.frame + subtitle.duration then
				current = subtitle
			end
		end

		if current ~= shown then
			shown = current
			box.Visible = current ~= nil
			if current then
				style(current)
			end
		end

		if not current then return end

		local elapsed = frame - current.frame
		local remaining = current.frame + current.duration - frame

		local reveal = if current.inFrames > 0 then math.clamp(elapsed / current.inFrames, 0, 1) else 1
		local fadeOut = if current.outFrames > 0 then math.clamp(remaining / current.outFrames, 0, 1) else 1
		local transparency = 1 - math.min(reveal, fadeOut)

		textLabel.MaxVisibleGraphemes = if reveal < 1 then math.floor(graphemes * reveal) else -1
		textLabel.TextTransparency = transparency
		speakerLabel.TextTransparency = transparency
		textStroke.Transparency = transparency
		speakerStroke.Transparency = transparency
	end
end

--[[
	Puts an Eclipse scene on stage and returns the frame driver: `step(frame)` poses
	everything and moves the camera, `finalCamera()` is the camera on the last frame.
	Returns nil when the stage has no camera rig.

	The stage is a clone of the whole scene, on this client, moved so the scene's
	reference lands on `origin`: the scenery, the rigs, and the camera rig go
	together, which is what keeps the authored framing. The clone goes to the
	session's Maid, so the end of the scene takes everything with it, and the source
	(in ReplicatedStorage) is never touched.

	Joints play by C1, like the Moon path, but the keys are the joints' Transform:
	`C1 = restC1 * Transform:Inverse()` puts Part1 exactly where Roblox's own
	`Part0 * C0 * Transform * C1:Inverse()` would.
--]]
function CutsceneController:stageEclipse(asset: Instance, scene, sessionMaid, origin: CFrame, reference: CFrame, camera: Camera)
	local data = scene.data

	local stage = asset:Clone()

	-- The blob already became `data`; the clone does not need half a megabyte of text.
	local blob = stage:FindFirstChild(CutsceneFormat.DATA_NAME)
	if blob then
		blob:Destroy()
	end

	-- The rigs are actors: no name or health bar over their heads.
	for _, descendant in stage:GetDescendants() do
		if descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			descendant.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		end
	end

	if stage:IsA("PVInstance") then
		stage:PivotTo(origin * reference:ToObjectSpace(stage:GetPivot()))
	end

	local motor = self:findMotor(stage, CAMERA_PART)
	if not motor or not motor.Part0 then
		stage:Destroy()
		return nil
	end

	-- The camera rig's own parts (lens, target) would sit in front of the lens.
	local cameraRig = motor.Part0.Parent
	if cameraRig and cameraRig ~= stage then
		for _, descendant in cameraRig:GetDescendants() do
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				descendant.Transparency = 1
			end
		end
	end

	sessionMaid:GiveTask(stage)
	stage.Parent = workspace

	local cameraBase = motor.Part0.CFrame * motor.C0
	local cameraRest = motor.C1:Inverse()
	local cameraTrack = { keys = data.camera, cursor = 1 }
	local fovTrack = data.fov and { keys = data.fov, cursor = 1 }

	local rigsFolder = stage:FindFirstChild("Rigs") or stage
	local jointTracks, rootTracks = {}, {}

	for _, entry in data.rigs do
		local rig = rigsFolder:FindFirstChild(entry.target)
		if not rig or not rig:IsA("Model") then
			log:StudioWarn(string.format("cutscene %q has no rig named %q.", asset.Name, entry.target))
			continue
		end

		local motors = {}
		for _, descendant in rig:GetDescendants() do
			if descendant:IsA("Motor6D") and descendant.Part1 then
				motors[descendant.Part1.Name] = descendant
			end
		end

		local uprightLegs = rig:GetAttribute(UPRIGHT_LEGS_ATTRIBUTE) == true

		for _, joint in entry.joints do
			local jointMotor = motors[joint.partName]
			if jointMotor and joint.keys then
				local track = { motor = jointMotor, rest = jointMotor.C1, keys = joint.keys, cursor = 1 }

				-- Only a plain block: a mesh is not symmetric, and turning it would show.
				local leg = jointMotor.Part1
				if uprightLegs and LEGS[joint.partName] and leg and leg.ClassName == "Part"
					and not leg:FindFirstChildWhichIsA("DataModelMesh") then
					track.upright = { flip = nil, joints = self:collectLegJoints(rig, leg, jointMotor) }
				end

				table.insert(jointTracks, track)
			end
		end

		if entry.root then
			table.insert(rootTracks, { rig = rig, keys = entry.root, cursor = 1, last = nil })
		end
	end

	self:applySceneLighting(stage:FindFirstChild("Lighting"), sessionMaid)

	local overlay = self:createOverlay(sessionMaid)
	local updateEffects = self:buildEffects(data.effects or {}, overlay)
	local updateSubtitles = self:buildSubtitles(data.subtitles or {}, overlay)

	local driver = {}

	function driver.step(frame: number)
		for _, track in jointTracks do
			local transform = self:sampleTrack(track, frame)

			if track.upright then
				track.motor.C1 = self:uprightLegC1(track, transform)
			else
				track.motor.C1 = track.rest * transform:Inverse()
			end
		end

		-- Only when it changes: a held root key is the same CFrame every frame.
		for _, track in rootTracks do
			local value = self:sampleTrack(track, frame)
			if value ~= track.last then
				track.last = value
				track.rig:PivotTo(origin * value)
			end
		end

		local view = cameraBase * self:sampleTrack(cameraTrack, frame) * cameraRest
		if fovTrack then
			camera.FieldOfView = self:sampleTrack(fovTrack, frame)
		end

		-- Effects and subtitles are dressing: an error in them must not freeze the
		-- camera and the actors, which are the scene.
		local ok, shake = pcall(updateEffects, frame)
		if not ok then
			log:StudioWarnOnce("effects:" .. asset.Name, string.format("cutscene %q effects failed: %s", asset.Name, tostring(shake)))
			shake = CFrame.identity
		end

		local subtitlesOk, subtitlesError = pcall(updateSubtitles, frame)
		if not subtitlesOk then
			log:StudioWarnOnce("subtitles:" .. asset.Name, string.format("cutscene %q subtitles failed: %s", asset.Name, tostring(subtitlesError)))
		end

		camera.CFrame = view * shake
	end

	function driver.finalCamera(): CFrame
		return cameraBase * self:sampleTrack(cameraTrack, scene.lastFrame) * cameraRest
	end

	return driver
end

--[[ CONTROL ]]

--[[
	Clears the world out of the way while the scene plays: billboards and highlights
	off, character invisible. None of this leaves the client (`Enabled` and
	`LocalTransparencyModifier` written here do not replicate), and everything returns
	to what it was in the sessionMaid cleanup.
--]]
function CutsceneController:hideWorld(sessionMaid)
	local function hideGui(instance: Instance)
		if not instance:IsA("BillboardGui") and not instance:IsA("Highlight") then return end
		if not instance.Enabled then return end

		instance.Enabled = false
		sessionMaid:GiveTask(function()
			if instance.Parent then
				instance.Enabled = true
			end
		end)
	end

	for _, descendant in workspace:GetDescendants() do
		hideGui(descendant)
	end

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end

		for _, descendant in character:GetDescendants() do
			-- The face is a Decal: hiding only the Parts would leave it floating.
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				local previous = descendant.LocalTransparencyModifier
				descendant.LocalTransparencyModifier = 1

				sessionMaid:GiveTask(function()
					descendant.LocalTransparencyModifier = previous
				end)
			else
				hideGui(descendant)
			end
		end
	end
end

--[[
	Clears the interface out of the way while the scene plays: the game's GUIs and
	Roblox's own, chat and top bar included.

	The interface returns with the **scene**, not with the camera: it always goes to
	the sessionMaid, even with `holdCamera`, where character control stays locked
	longer. The scene is over, so is the reason for a clean screen. At the portal this
	happens behind the white flash, which by then already covers everything.

	It is not `Enabled = false` by hand on each one: InterfaceController does that,
	the same one the maps panel uses. Without that middleman the two would undo each
	other: closing the panel would bring the interface back mid-cutscene.

	A ScreenGui marked `IgnoreInterfaceHide` stays: that is the case of the portal's
	white flash, which is born at the end of the scene precisely to cover the screen.
--]]
function CutsceneController:hideInterface(sessionMaid)
	local InterfaceController = self.Controllers.InterfaceController
	if not InterfaceController then return end

	InterfaceController:Hide(HIDE_REASON, { HideCore = true })
	sessionMaid:GiveTask(function()
		InterfaceController:Show(HIDE_REASON)
	end)
end

function CutsceneController:lockControls(sessionMaid)
	local playerScripts = self.player:FindFirstChild("PlayerScripts")
	local playerModuleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModuleScript then return end

	local success, controls = pcall(function()
		return require(playerModuleScript):GetControls()
	end)

	if not success or not controls then return end

	controls:Disable()
	sessionMaid:GiveTask(function()
		controls:Enable()
	end)
end

--[[
	The scene's coordinate center, read live: dragging the scene in Studio moves the
	reference along with the rest, and the cutscene follows.

	There are two modes:

	- **Part** (default): the `SceneReferenceCFrame`.
	- **World Pivot**: the Model's own pivot, which Studio's Edit Pivot tool moves.
	  Turn it on by setting the `UseWorldPivot` attribute on the scene, or simply by
	  not having the Part.

	The pivot is only reliable when it is real: `GetPivot()` falls back to the
	bounding box center when the Model has no `WorldPivot` set and no `PrimaryPart`,
	and that center moves with the rigs, that is, it changes from one play to the next.
	For a pivot-based scene, set the pivot by hand in Studio or leave a PrimaryPart.
--]]
function CutsceneController:readSceneReference(asset: Instance)
	if asset:GetAttribute(PIVOT_ATTRIBUTE) ~= true then
		local reference = asset:FindFirstChild(SCENE_REFERENCE)

		if reference then
			if reference:IsA("BasePart") then return reference.CFrame end
			if reference:IsA("CFrameValue") then return reference.Value end
		end
	end

	if asset:IsA("PVInstance") then
		return asset:GetPivot()
	end

	return nil
end

--[[
	Moves the whole scene to `origin`: the scene's reference (the Part or the World
	Pivot) lands there, and the rest follows. Returns the pivot the scene came from, so
	the caller can put it back, or nil if the scene has no reference at all.
--]]
function CutsceneController:placeScene(asset: PVInstance, origin: CFrame): CFrame?
	local reference = self:readSceneReference(asset)
	if not reference then return nil end

	local previousPivot = asset:GetPivot()
	asset:PivotTo(origin * reference:ToObjectSpace(previousPivot))

	return previousPivot
end

function CutsceneController:construct()
	self.maid = Maid.new()
	self.player = Players.LocalPlayer
	self.cutsceneActive = false
	self.cameraHold = nil
	self.scenes = {}

	self.cutscenes = Shared:WaitForChild("Assets"):WaitForChild("Cutscenes")

	-- Reads ahead so the first cutscene does not pay for parsing.
	task.spawn(function()
		for _, asset in self.cutscenes:GetChildren() do
			self:parseScene(asset)
			task.wait()
		end
	end)
end

function CutsceneController:start()
end

function CutsceneController:stopCutscene()
	self.maid.CurrentCutscene = nil
end

--[[
	Returns the camera and control that `holdCamera` held. With no hold in progress it
	does nothing, so it can be called just in case.
--]]
function CutsceneController:releaseCamera()
	local hold = self.cameraHold
	if not hold then return end

	self.cameraHold = nil
	hold:DoCleaning()
end

--[[
	Whether the camera is parked at the end of a scene waiting for someone to release it.
--]]
function CutsceneController:isCameraHeld(): boolean
	return self.cameraHold ~= nil
end

--[[
	Plays a cutscene and returns its duration, or nil if it could not play.

	`cutscene` is the scene's name inside Assets.Cutscenes or the instance itself:
	code that already took the scene out of ReplicatedStorage (the portal moves the
	original into the world) passes it directly. `origin` is where the scene's
	reference lands; without it, the scene plays where it is built.

	`holdCamera` leaves the camera where the scene ended, Scriptable and at the last
	frame's CFrame, with character control still locked. It is for code that will
	move the player away right after (the portal, behind the flash) and does not want
	the camera returning to their shoulder midway. Call `releaseCamera` to undo it; at
	the portal that only happens if the teleport fails.
--]]
function CutsceneController:playCutscene(cutscene: (string | Instance)?, origin: CFrame?, holdCamera: boolean?)
	if self.cutsceneActive then return nil end

	local asset, name
	if typeof(cutscene) == "Instance" then
		asset, name = cutscene, cutscene.Name
	else
		-- construct() may still be waiting for Assets to replicate.
		if not self.cutscenes then return nil end

		name = cutscene or DEFAULT_CUTSCENE
		asset = self.cutscenes:FindFirstChild(name)
	end

	if not asset then
		log:StudioWarn(string.format("no cutscene named %q in Assets.Cutscenes.", name))
		return nil
	end

	local scene = self:parseScene(asset)
	if not scene then
		log:StudioWarn(string.format("cutscene %q has no data or no rig driving a %q part.", name, CAMERA_PART))
		return nil
	end

	local reference = self:readSceneReference(asset)
	if not reference then
		log:StudioWarn(string.format("cutscene %q has neither a %s part nor a pivot to measure from.", name, SCENE_REFERENCE))
		return nil
	end

	self.cutsceneActive = true

	local sessionMaid = Maid.new()
	self.maid.CurrentCutscene = sessionMaid

	-- Holding the camera means it is not returned at the end of the scene: world
	-- control and what the camera is looking at stay owned by holdMaid, which is only
	-- released by releaseCamera.
	local holdMaid = holdCamera and Maid.new() or nil
	if holdMaid then
		self:releaseCamera()
		self.cameraHold = holdMaid
	end

	local camera = workspace.CurrentCamera
	local previousCameraType = camera.CameraType
	local previousCameraSubject = camera.CameraSubject
	local previousFieldOfView = camera.FieldOfView

	camera.CameraType = Enum.CameraType.Scriptable

	self:lockControls(holdMaid or sessionMaid)
	self:hideInterface(sessionMaid)
	self:hideWorld(sessionMaid)

	local sceneOrigin = origin or reference
	local duration = scene.duration
	local lastFrame = scene.lastFrame

	local driver = nil

	-- Registered before the driver exists, so a stage that fails still gives the
	-- camera and the controls back.
	sessionMaid:GiveTask(function()
		self.cutsceneActive = false

		if holdMaid and driver then
			-- The scene ended but the camera stays: parked on the last frame, which is what the
			-- portal wants behind the flash. releaseCamera gives it back.
			camera.CFrame = driver.finalCamera()

			holdMaid:GiveTask(function()
				camera.CameraType = previousCameraType
				camera.CameraSubject = previousCameraSubject
				camera.FieldOfView = previousFieldOfView
			end)

			return
		end

		camera.CameraType = previousCameraType
		camera.CameraSubject = previousCameraSubject
		camera.FieldOfView = previousFieldOfView
	end)

	if scene.eclipse then
		driver = self:stageEclipse(asset, scene, sessionMaid, sceneOrigin, reference, camera)
	else
		driver = self:buildMoonDriver(scene, sessionMaid, sceneOrigin, reference, camera)
	end

	if not driver then
		log:StudioWarn(string.format("cutscene %q has no rig driving a %q part.", name, CAMERA_PART))

		self.maid.CurrentCutscene = nil
		if holdMaid then
			self:releaseCamera()
		end

		return nil
	end

	-- Frame 0 before the first render: the stage must not show up unposed.
	driver.step(0)

	local elapsed = 0
	local firedFrame = -1

	sessionMaid:GiveTask(RunService.RenderStepped:Connect(function(deltaTime)
		elapsed = math.min(elapsed + deltaTime, duration)
		local frame = elapsed * SCENE_FPS

		driver.step(frame)

		-- One notification per scene frame, not per render frame.
		local reached = math.floor(frame)
		if reached > firedFrame then
			firedFrame = reached
			self.Signals.FrameReached:Fire(reached, lastFrame, asset)
		end
	end))

	task.delay(duration, function()
		if self.maid.CurrentCutscene == sessionMaid then
			self.maid.CurrentCutscene = nil
		end
	end)

	return duration
end

function CutsceneController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CutsceneController
