local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local CutsceneFormat = require(Util.CutsceneFormat)
local Log = require(Util:WaitForChild("Log"))
local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("CutsceneController")

--[[
	Player for Moon Animator cutscenes.

	Reading the file lives in Shared.Util.CutsceneFormat, which understands both the
	exported Folder tree and the compressed blob. Only what needs live instances and
	frame-by-frame work stays here.

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

local CutsceneController = {
	Controllers = {
		InterfaceController = {},
	},

	Signals = {
		-- (frame : number, lastFrame : number, asset : Instance)
		-- Once per scene frame, with the frame already as an integer. Anything that wants
		-- to fire near the end compares with lastFrame.
		FrameReached = Signal.new(),
	},
}

local function lerpValue(from, to, alpha: number)
	if typeof(from) == "CFrame" then
		return from:Lerp(to, alpha)
	end

	return from + (to - from) * alpha
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

	local style = EASING_STYLES[EASE_ALIASES[name] or name]
	if not style then
		if not warnedEases[name] then
			warnedEases[name] = true
			log:StudioWarn(string.format("unknown Moon Animator ease %q, falling back to Linear.", name))
		end
		return alpha
	end

	return TweenService:GetValue(alpha, style, EASING_DIRECTIONS[direction or "In"] or Enum.EasingDirection.In)
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
	Dresses a scene rig with a character's appearance: clothing, body colors, face,
	and accessories. `source` is the Player (uses their Character, or downloads the
	appearance if they do not have one at the moment) or a ready character Model.

	No Part is swapped: an R15's package MeshParts stay as they are. Swapping Parts
	would mean destroying the Motor6Ds the scene animates, and the joint carries the
	whole animation. That is why an R15 dressed onto an R6 rig (or the reverse) works:
	what travels is clothing, color, face, and accessories, which apply to both.

	Returns a function that undoes everything: the scene rig is the original instance,
	so without undoing, the next player enters the portal wearing the previous one's
	clothes. Call it before `playCutscene`: after that the joints have already been
	read.
--]]
function CutsceneController:applyCharacter(rig: Model, source: Player | Model): (() -> ())?
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
	a function that undoes everything.
--]]
function CutsceneController:dressScene(asset: Instance, source: Player | Model, rigName: string?): () -> ()
	local restores = {}

	for _, entry in self:getSceneRigs(asset, rigName) do
		local restore = self:applyCharacter(entry.rig, source)
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

	-- The camera is the Motor6D's Part1: Part0 * C0 * Transform * C1:Inverse(), with
	-- Transform at rest. Everything before C1 is constant, so it is resolved once.
	local motor = scene.cameraMotor
	local cameraBase = sceneOrigin * reference:ToObjectSpace(motor.Part0.CFrame * motor.C0)

	local cameraTrack = { keys = scene.cameraKeys, cursor = 1 }
	local fovTrack = scene.cameraFov and { keys = scene.cameraFov, cursor = 1 }

	local jointTracks = {}
	for _, parsed in scene.rigs do
		for _, track in self:prepareRig(parsed, sessionMaid, sceneOrigin, reference) do
			table.insert(jointTracks, track)
		end
	end

	local duration = scene.duration
	local lastFrame = scene.lastFrame
	local elapsed = 0
	local firedFrame = -1

	sessionMaid:GiveTask(RunService.RenderStepped:Connect(function(deltaTime)
		elapsed = math.min(elapsed + deltaTime, duration)
		local frame = elapsed * SCENE_FPS

		camera.CFrame = cameraBase * self:sampleTrack(cameraTrack, frame):Inverse()

		if fovTrack then
			camera.FieldOfView = self:sampleTrack(fovTrack, frame)
		end

		for _, track in jointTracks do
			track.motor.C1 = self:sampleTrack(track, frame)
		end

		-- One notification per scene frame, not per render frame.
		local reached = math.floor(frame)
		if reached > firedFrame then
			firedFrame = reached
			self.Signals.FrameReached:Fire(reached, lastFrame, asset)
		end
	end))

	sessionMaid:GiveTask(function()
		self.cutsceneActive = false

		if holdMaid then
			-- The scene ended but the camera stays: parked on the last frame, which is what the
			-- portal wants behind the flash. releaseCamera gives it back.
			camera.CFrame = cameraBase * self:sampleTrack(cameraTrack, lastFrame):Inverse()

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
