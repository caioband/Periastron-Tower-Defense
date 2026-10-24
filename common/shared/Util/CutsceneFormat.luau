--[[
	Reading and compressing cutscene files from two animators.

	- **Moon Animator** (format 1): the save is a tree of Folders. Each key becomes at
	  least three instances, and a scene easily passes 700, all replicated to every
	  client on join.
	- **Eclipse Animator** (format 2): each rig carries a native KeyframeSequence in
	  `AnimSaves/<project>`, and effects keep their tracks in a compressed JSON. One
	  scene passes 20 thousand instances.

	This module reads either one, packs it into a blob, and lets the source go: the
	published scene keeps only the live Parts plus a `SceneData` StringValue.

	Usage in Studio, after exporting from Moon Animator:

		local CutsceneFormat = require(game.ReplicatedStorage.Shared.Util.CutsceneFormat)
		print(CutsceneFormat.BakeAll(game.ReplicatedStorage.Shared.Assets.Cutscenes))

	And after copying an Eclipse scene to `ServerStorage.CutsceneSources`:

		print(CutsceneFormat.BakeEclipseAll())

	`Read` prefers the blob and falls back to the source when there is none, so a
	freshly exported scene still plays without baking.

	The blob is base64 instead of raw bytes: it costs 33% of an already small
	number, and in exchange the place serialization cannot corrupt a non-printable
	byte.

	See docs/common/cutscenes.md.
--]]

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local CutsceneFormat = {}

CutsceneFormat.VERSION = 1
CutsceneFormat.ECLIPSE_VERSION = 2
CutsceneFormat.DATA_NAME = "SceneData"

local RIG_FOLDER = "Rig"
local RIG_TARGET = "Target"
local JOINT_KEYFRAMES = "_keyframes"
local JOINT_HIERARCHY = "_hier"
local CAMERA_FOV_TRACK = "FieldOfView"
local CAMERA_PART = "CamPart"

local VALUES_FOLDER = "Values"
local EASES_FOLDER = "Eases"
local EASE_TYPE = "Type"
local EASE_DIRECTION = "Direction"

--[[ BASE64 ]]

-- Everything in a buffer: concatenating strings or running gsub over a few KB
-- costs more than the rest of the whole decode.
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_PAD = string.byte("=")
local B64_BYTE = {}
local B64_VALUE = {}
for i = 1, #B64_ALPHABET do
	local byte = string.byte(B64_ALPHABET, i)
	B64_BYTE[i - 1] = byte
	B64_VALUE[byte] = i - 1
end

local function toBase64(source: buffer): string
	local length = buffer.len(source)
	local result = buffer.create(math.ceil(length / 3) * 4)
	local read, write = 0, 0

	while read + 3 <= length do
		local packed = buffer.readu8(source, read) * 65536
			+ buffer.readu8(source, read + 1) * 256
			+ buffer.readu8(source, read + 2)

		buffer.writeu8(result, write, B64_BYTE[bit32.rshift(packed, 18)])
		buffer.writeu8(result, write + 1, B64_BYTE[bit32.band(bit32.rshift(packed, 12), 63)])
		buffer.writeu8(result, write + 2, B64_BYTE[bit32.band(bit32.rshift(packed, 6), 63)])
		buffer.writeu8(result, write + 3, B64_BYTE[bit32.band(packed, 63)])

		read += 3
		write += 4
	end

	local remaining = length - read
	if remaining > 0 then
		local packed = buffer.readu8(source, read) * 65536
			+ (remaining > 1 and buffer.readu8(source, read + 1) * 256 or 0)

		buffer.writeu8(result, write, B64_BYTE[bit32.rshift(packed, 18)])
		buffer.writeu8(result, write + 1, B64_BYTE[bit32.band(bit32.rshift(packed, 12), 63)])
		buffer.writeu8(result, write + 2, remaining > 1 and B64_BYTE[bit32.band(bit32.rshift(packed, 6), 63)] or B64_PAD)
		buffer.writeu8(result, write + 3, B64_PAD)
	end

	return buffer.tostring(result)
end

local function fromBase64(encoded: string): buffer
	local source = buffer.fromstring(encoded)
	local length = buffer.len(source)
	while length > 0 and buffer.readu8(source, length - 1) == B64_PAD do
		length -= 1
	end

	local size = math.floor(length * 3 / 4)
	local result = buffer.create(size)
	local read, write = 0, 0

	while read + 4 <= length do
		local packed = (B64_VALUE[buffer.readu8(source, read)] or 0) * 262144
			+ (B64_VALUE[buffer.readu8(source, read + 1)] or 0) * 4096
			+ (B64_VALUE[buffer.readu8(source, read + 2)] or 0) * 64
			+ (B64_VALUE[buffer.readu8(source, read + 3)] or 0)

		buffer.writeu8(result, write, bit32.rshift(packed, 16))
		buffer.writeu8(result, write + 1, bit32.band(bit32.rshift(packed, 8), 255))
		buffer.writeu8(result, write + 2, bit32.band(packed, 255))

		read += 4
		write += 3
	end

	local remaining = length - read
	if remaining >= 2 then
		local packed = (B64_VALUE[buffer.readu8(source, read)] or 0) * 262144
			+ (B64_VALUE[buffer.readu8(source, read + 1)] or 0) * 4096
			+ (remaining > 2 and (B64_VALUE[buffer.readu8(source, read + 2)] or 0) * 64 or 0)

		buffer.writeu8(result, write, bit32.rshift(packed, 16))
		if remaining > 2 then
			buffer.writeu8(result, write + 1, bit32.band(bit32.rshift(packed, 8), 255))
		end
	end

	return result
end

--[[ READING THE FOLDERS ]]

local function easeName(ease: string?, direction: string?): string?
	if not ease then return nil end
	if not direction then return ease end
	return ease .. "|" .. direction
end

local function readTrack(track: Instance?)
	if not track then return nil end

	local keys = {}
	for _, block in track:GetChildren() do
		local blockStart = tonumber(block.Name)
		local values = blockStart and block:FindFirstChild(VALUES_FOLDER)
		if not values then continue end

		local eases = block:FindFirstChild(EASES_FOLDER)
		for _, value in values:GetChildren() do
			local offset = tonumber(value.Name)
			if not offset or not value:IsA("ValueBase") then continue end

			local ease = eases and eases:FindFirstChild(value.Name)
			local easeType = ease and ease:FindFirstChild(EASE_TYPE)
			local easeDirection = ease and ease:FindFirstChild(EASE_DIRECTION)

			table.insert(keys, {
				frame = blockStart + offset,
				value = (value :: any).Value,
				ease = easeName(easeType and easeType.Value or nil, easeDirection and easeDirection.Value or nil),
			})
		end
	end

	if #keys == 0 then return nil end

	table.sort(keys, function(a, b) return a.frame < b.frame end)
	return keys
end

--[[
	Reads the Moon Animator Folder tree. Returns plain data only (names and keys,
	no instance references) so it can be serialized.
--]]
function CutsceneFormat.ReadFolders(asset: Instance)
	local scene = { camera = nil, fov = nil, rigs = {}, lastFrame = 0 }

	local function stretch(keys)
		if keys then
			scene.lastFrame = math.max(scene.lastFrame, keys[#keys].frame)
		end
	end

	for _, item in asset:GetChildren() do
		if not item:IsA("Folder") or not tonumber(item.Name) then continue end

		local rigFolder = item:FindFirstChild(RIG_FOLDER)
		if not rigFolder then
			scene.fov = scene.fov or readTrack(item:FindFirstChild(CAMERA_FOV_TRACK))
			stretch(scene.fov)
			continue
		end

		local target = item:FindFirstChild(RIG_TARGET)
		local rig = target and target:IsA("ObjectValue") and target.Value

		local joints = {}
		for _, joint in rigFolder:GetChildren() do
			local hierarchy = joint:FindFirstChild(JOINT_HIERARCHY)
			local keys = readTrack(joint:FindFirstChild(JOINT_KEYFRAMES))
			if not hierarchy or not keys then continue end

			local partName = string.match(hierarchy.Value, "([^%.]+)$")
			if partName == CAMERA_PART then
				scene.camera = keys
			else
				table.insert(joints, { partName = partName, keys = keys })
			end
			stretch(keys)
		end

		if #joints > 0 and rig then
			table.insert(scene.rigs, { target = rig.Name, joints = joints })
		end
	end

	if not scene.camera then return nil end
	return scene
end

--[[ ENCODE / DECODE ]]

-- CFrame key: frame u16 + ease u8 + the 12 components as f32.
--
-- Storing position + axis/angle would be smaller (32 bytes against 51), but the axis
-- is ill-conditioned for rotations near 180 degrees: measured, it drifted 0.078
-- studs at 100 studs away. The 12 components are exact (CFrame is f32 inside)
-- and rebuild 2.2x faster, with no trigonometry.
local CFRAME_KEY_SIZE = 2 + 1 + 48
local NUMBER_KEY_SIZE = 2 + 1 + 4

local function measure(scene): number
	local size = 1 + 2 + 1 -- version, lastFrame, flags
	size += 1 -- number of easings
	size += 2 + #scene.camera * CFRAME_KEY_SIZE
	if scene.fov then
		size += 2 + #scene.fov * NUMBER_KEY_SIZE
	end
	size += 1
	for _, rig in scene.rigs do
		size += 1 + #rig.target + 1
		for _, joint in rig.joints do
			size += 1 + #joint.partName + 2 + #joint.keys * CFRAME_KEY_SIZE
		end
	end
	return size
end

--[[
	Packs the scene. Easing names become a small table in the header and each key
	stores only the index, so any Moon Animator easing works without the format
	knowing the list.
--]]
function CutsceneFormat.Encode(scene): string
	local easeList = {}
	local easeIndex = {}
	local function easeId(ease: string?): number
		if not ease then return 0 end
		if not easeIndex[ease] then
			table.insert(easeList, ease)
			easeIndex[ease] = #easeList
		end
		return easeIndex[ease]
	end

	for _, key in scene.camera do easeId(key.ease) end
	if scene.fov then
		for _, key in scene.fov do easeId(key.ease) end
	end
	for _, rig in scene.rigs do
		for _, joint in rig.joints do
			for _, key in joint.keys do easeId(key.ease) end
		end
	end

	local easeBytes = 0
	for _, ease in easeList do easeBytes += 1 + #ease end

	local data = buffer.create(measure(scene) + easeBytes)
	local offset = 0

	local function writeString(text: string)
		buffer.writeu8(data, offset, #text)
		offset += 1
		buffer.writestring(data, offset, text)
		offset += #text
	end

	buffer.writeu8(data, offset, CutsceneFormat.VERSION) offset += 1
	buffer.writeu16(data, offset, scene.lastFrame) offset += 2
	buffer.writeu8(data, offset, scene.fov and 1 or 0) offset += 1

	buffer.writeu8(data, offset, #easeList) offset += 1
	for _, ease in easeList do writeString(ease) end

	local function writeCFrameKeys(keys)
		buffer.writeu16(data, offset, #keys) offset += 2
		for _, key in keys do
			buffer.writeu16(data, offset, key.frame) offset += 2
			buffer.writeu8(data, offset, easeId(key.ease)) offset += 1

			local components = { key.value:GetComponents() }
			for index = 1, 12 do
				buffer.writef32(data, offset, components[index])
				offset += 4
			end
		end
	end

	writeCFrameKeys(scene.camera)

	if scene.fov then
		buffer.writeu16(data, offset, #scene.fov) offset += 2
		for _, key in scene.fov do
			buffer.writeu16(data, offset, key.frame) offset += 2
			buffer.writeu8(data, offset, easeId(key.ease)) offset += 1
			buffer.writef32(data, offset, key.value) offset += 4
		end
	end

	buffer.writeu8(data, offset, #scene.rigs) offset += 1
	for _, rig in scene.rigs do
		writeString(rig.target)
		buffer.writeu8(data, offset, #rig.joints) offset += 1
		for _, joint in rig.joints do
			writeString(joint.partName)
			writeCFrameKeys(joint.keys)
		end
	end

	return toBase64(data)
end

local function decodeMoon(data: buffer)
	local offset = 0

	if buffer.len(data) < 4 or buffer.readu8(data, 0) ~= CutsceneFormat.VERSION then
		return nil
	end
	offset += 1

	local scene = { camera = nil, fov = nil, rigs = {}, lastFrame = 0 }
	scene.lastFrame = buffer.readu16(data, offset) offset += 2
	local hasFov = buffer.readu8(data, offset) == 1 offset += 1

	local function readString(): string
		local length = buffer.readu8(data, offset)
		offset += 1
		local text = buffer.readstring(data, offset, length)
		offset += length
		return text
	end

	local easeList = {}
	local easeCount = buffer.readu8(data, offset) offset += 1
	for _ = 1, easeCount do
		table.insert(easeList, readString())
	end

	local function readCFrameKeys()
		local count = buffer.readu16(data, offset) offset += 2
		local keys = table.create(count)
		for i = 1, count do
			local frame = buffer.readu16(data, offset) offset += 2
			local ease = easeList[buffer.readu8(data, offset)] offset += 1

			local x = buffer.readf32(data, offset)
			local y = buffer.readf32(data, offset + 4)
			local z = buffer.readf32(data, offset + 8)
			local r00 = buffer.readf32(data, offset + 12)
			local r01 = buffer.readf32(data, offset + 16)
			local r02 = buffer.readf32(data, offset + 20)
			local r10 = buffer.readf32(data, offset + 24)
			local r11 = buffer.readf32(data, offset + 28)
			local r12 = buffer.readf32(data, offset + 32)
			local r20 = buffer.readf32(data, offset + 36)
			local r21 = buffer.readf32(data, offset + 40)
			local r22 = buffer.readf32(data, offset + 44)
			offset += 48

			keys[i] = {
				frame = frame,
				value = CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22),
				ease = ease,
			}
		end
		return keys
	end

	scene.camera = readCFrameKeys()

	if hasFov then
		local count = buffer.readu16(data, offset) offset += 2
		local keys = table.create(count)
		for i = 1, count do
			local frame = buffer.readu16(data, offset) offset += 2
			local ease = easeList[buffer.readu8(data, offset)] offset += 1
			keys[i] = { frame = frame, value = buffer.readf32(data, offset), ease = ease }
			offset += 4
		end
		scene.fov = keys
	end

	local rigCount = buffer.readu8(data, offset) offset += 1
	for _ = 1, rigCount do
		local target = readString()
		local jointCount = buffer.readu8(data, offset) offset += 1
		local joints = table.create(jointCount)
		for i = 1, jointCount do
			joints[i] = { partName = readString(), keys = readCFrameKeys() }
		end
		table.insert(scene.rigs, { target = target, joints = joints })
	end

	return scene
end

--[[
	The blob of a scene, or nil. A long blob is split: `SceneData` holds the first
	piece and its StringValue children (`Chunk002`, `Chunk003`, ...) the rest, in name
	order. See `writeBlob`.
--]]
local function readBlob(asset: Instance): string?
	local stored = asset:FindFirstChild(CutsceneFormat.DATA_NAME)
	if not stored or not stored:IsA("StringValue") or stored.Value == "" then
		return nil
	end

	local chunks = stored:GetChildren()
	if #chunks == 0 then
		return stored.Value
	end

	table.sort(chunks, function(a, b) return a.Name < b.Name end)

	local parts = { stored.Value }
	for _, chunk in chunks do
		if chunk:IsA("StringValue") then
			table.insert(parts, chunk.Value)
		end
	end

	return table.concat(parts)
end

--[[
	Reads the scene, preferring the blob. Returns the scene and where it came from,
	so the caller can warn that it is still in the heavy format.

	An Eclipse scene has `format = "eclipse"`; a Moon Animator scene has no `format`.
--]]
function CutsceneFormat.Read(asset: Instance)
	local encoded = readBlob(asset)
	if encoded then
		local scene = CutsceneFormat.Decode(encoded)
		if scene then return scene, "blob" end
	end

	if asset:GetAttribute("EclipseProject") ~= nil then
		return CutsceneFormat.ReadEclipse(asset), "keyframes"
	end

	return CutsceneFormat.ReadFolders(asset), "folders"
end

--[[ BAKE (Studio) ]]

local function countKeys(scene): number
	local total = #scene.camera + (scene.fov and #scene.fov or 0)
	for _, rig in scene.rigs do
		for _, joint in rig.joints do
			total += #joint.keys
		end
	end
	return total
end

--[[
	Converts the scene and deletes the data Folders.

	Only deletes after decoding the blob back and checking that it matches: never
	destroy the source trusting the encode.
--]]
function CutsceneFormat.Bake(asset: Instance): (boolean, string)
	local scene = CutsceneFormat.ReadFolders(asset)
	if not scene then
		return false, string.format("%s: no Moon Animator tracks to convert", asset.Name)
	end

	local encoded = CutsceneFormat.Encode(scene)
	local check = CutsceneFormat.Decode(encoded)
	if not check or countKeys(check) ~= countKeys(scene) or #check.rigs ~= #scene.rigs then
		return false, string.format("%s: the blob does not match the source; nothing was deleted", asset.Name)
	end

	local before = #asset:GetDescendants()

	local stored = asset:FindFirstChild(CutsceneFormat.DATA_NAME)
	if not stored or not stored:IsA("StringValue") then
		stored = Instance.new("StringValue")
		stored.Name = CutsceneFormat.DATA_NAME
		stored.Parent = asset
	end
	stored.Value = encoded

	for _, item in asset:GetChildren() do
		if item:IsA("Folder") and tonumber(item.Name) then
			item:Destroy()
		end
	end

	local after = #asset:GetDescendants()
	return true, string.format(
		"%s: %d -> %d instances, %.1f KB blob, %d keys",
		asset.Name, before, after, #encoded / 1024, countKeys(scene)
	)
end

function CutsceneFormat.BakeAll(folder: Instance): string
	local lines = {}
	for _, asset in folder:GetChildren() do
		local success, message = CutsceneFormat.Bake(asset)
		table.insert(lines, (success and "ok     " or "FAILED ") .. message)
	end

	if #lines == 0 then
		return "no scenes found"
	end

	return table.concat(lines, "\n")
end

--[[ ECLIPSE ]]

--[[
	An Eclipse scene, as `ServerStorage.CutsceneSources` holds it:

		<Scene>                   Model, attribute EclipseProject = project name
		├── SceneReferenceCFrame  Part, attribute AuthoredCFrame = where it stood when
		│                         the scene was assembled
		├── <camera rig>          RootPart + Motor6D CamPart and FovPart, AnimSaves/<project>
		├── Rigs                  the actors, each with AnimSaves/<project>
		├── Effects               Screen Cover, Camera Shake: tracks in EclipseProperties
		├── Subtitles             the project's EclipseSubtitles folder
		├── Set                   scenery, not animated
		└── Lighting              lighting preset (docs/common/lighting.md format)

	What was verified against the files, so the next reader does not redo it:

	- a Pose's CFrame is the joint's `Transform`: `Part1 = Part0 * C0 * Transform * C1:Inverse()`.
	  A weapon that leaves the hand (`EclipseParented = false`) is already baked that
	  way: its Transform compensates the arm, and the forward kinematics land on the
	  `DetachedWorldCFrame` Eclipse recorded within 0.03 studs. Nothing special to do.
	- the easing of a Pose (and of a property key) describes the way **out** of that
	  key, as in Roblox. The player reads the easing on the key it is going **to**
	  (Moon Animator's convention), so the reader moves each one a key forward.
	- `FovPart`'s pose Y is the FOV minus 70 (the camera rig's README says so; it
	  matches Eclipse's own FOV export exactly).
	- the root CFrame track (`EclipseProperties`, id `CFrame`) is in world space at
	  authoring time, so it is stored relative to `AuthoredCFrame`.
	- `EclipseProperties` is JSON whose payload is a Roblox buffer object (zstd);
	  `HttpService:JSONDecode` hands it back decompressed.
--]]

local ECLIPSE_PROJECT = "EclipseProject"
local ECLIPSE_SAVES = "AnimSaves"
local ECLIPSE_EXPORTS = "AnimExports"
local ECLIPSE_PROPERTIES = "EclipseProperties"
local ECLIPSE_EVENTS = "EclipseEvents"
local ECLIPSE_FOV_PART = "FovPart"
local ECLIPSE_FOV_BASE = 70
local ECLIPSE_ROOT_TRACK = "CFrame"

local SCENE_REFERENCE = "SceneReferenceCFrame"
local AUTHORED_ATTRIBUTE = "AuthoredCFrame"
local RIGS_FOLDER = "Rigs"
local EFFECTS_FOLDER = "Effects"
local SUBTITLES_FOLDER = "Subtitles"

local SCENE_FPS = 60

-- Below this, two keys are the same value (studs, rotation matrix components, degrees).
local SAME_EPSILON = 1e-4

-- A StringValue this long or longer is split into chunks; see `writeBlob`.
local BLOB_CHUNK = 100000

-- The effect properties the player knows, read from `Effect<Name>` attributes when
-- the effect has no track for them.
local EFFECT_PROPERTIES = { "Color", "Transparency", "Size", "Position", "Rotation", "Enabled", "Speed", "Strength" }

local function sameValue(a, b): boolean
	if typeof(a) == "CFrame" then
		if (a.Position - b.Position).Magnitude > SAME_EPSILON then return false end

		local ca = { a:GetComponents() }
		local cb = { b:GetComponents() }
		for index = 4, 12 do
			if math.abs(ca[index] - cb[index]) > SAME_EPSILON then return false end
		end
		return true
	end

	if type(a) == "number" and type(b) == "number" then
		return math.abs(a - b) <= SAME_EPSILON
	end

	return a == b
end

local function poseEase(pose: Pose): string?
	local style = pose.EasingStyle.Name
	if style == "Linear" then return nil end
	if style == "Constant" then return "Constant" end
	if style == "CubicV2" then style = "Cubic" end
	return style .. "|" .. pose.EasingDirection.Name
end

--[[
	A property key's easing. `Bezier` is a CSS-style cubic curve whose two control
	points travel in place of the direction (`Bezier|x1,y1,x2,y2`): TweenService
	cannot evaluate it, so the player does (see `CutsceneController:easeAlpha`).
--]]
local function propertyEase(style: string?, direction: string?, bezier: any): string?
	if not style or style == "Linear" then return nil end
	if style == "Constant" then return style end

	if style == "Bezier" then
		local points = type(bezier) == "table" and bezier or {}
		local x1, y1, x2, y2 = tonumber(points[1]), tonumber(points[2]), tonumber(points[3]), tonumber(points[4])
		if not (x1 and y1 and x2 and y2) then return nil end
		return string.format("Bezier|%.4f,%.4f,%.4f,%.4f", x1, y1, x2, y2)
	end

	if not direction or direction == "Automatic" then direction = "InOut" end
	return style .. "|" .. direction
end

--[[
	Turns keys with `leave` (the easing out of each key, Eclipse's convention) into
	keys with `ease` (the easing into each key, the player's), dropping the keys that
	change nothing:

	- the same value as the key kept before it **and** as the one after it: the curve
	  is flat on both sides, whatever the easing;
	- the same value as the key before, with both holding (`Constant`): the hold just
	  goes on.

	The last key always stays, because it is what gives the track its length.
--]]
local function finishKeys(keys)
	local kept = { keys[1] }

	for index = 2, #keys do
		local key = keys[index]
		local previous = kept[#kept]
		local following = keys[index + 1]

		local redundant = following ~= nil and sameValue(previous.value, key.value) and (
			sameValue(key.value, following.value)
			or (previous.leave == "Constant" and key.leave == "Constant")
		)

		if not redundant then
			table.insert(kept, key)
		end
	end

	for index = #kept, 1, -1 do
		local previous = kept[index - 1]
		kept[index].ease = previous and previous.leave or nil
	end

	for _, key in kept do
		key.leave = nil
	end

	return kept
end

local function sortKeys(keys)
	table.sort(keys, function(a, b)
		if a.frame ~= b.frame then return a.frame < b.frame end
		return (a.order or 0) < (b.order or 0)
	end)
end

--[[
	The tracks of a KeyframeSequence, by Pose name (= the joint's Part1). A Pose with
	`Weight = 0` is only a placeholder for the hierarchy and is not a key.

	`EclipseExactFrame` is preferred over `Time`: Eclipse writes keys a thousandth of
	a frame apart (59.999 and 60) to make a jump, and `Time` is an f32 in seconds.
--]]
local function readSequence(sequence: KeyframeSequence)
	local tracks = {}

	for order, keyframe in sequence:GetKeyframes() do
		local exact = keyframe:GetAttribute("EclipseExactFrame")
		local frame = if type(exact) == "number" then exact else keyframe.Time * SCENE_FPS

		for _, pose in keyframe:GetDescendants() do
			if not pose:IsA("Pose") or pose.Weight <= 0 then continue end

			local keys = tracks[pose.Name]
			if not keys then
				keys = {}
				tracks[pose.Name] = keys
			end

			table.insert(keys, { frame = frame, order = order, value = pose.CFrame, leave = poseEase(pose) })
		end
	end

	for _, keys in tracks do
		sortKeys(keys)
	end

	return tracks
end

local function stripOrder(keys)
	for _, key in keys do
		key.order = nil
	end
	return keys
end

--[[
	Eclipse's packed values: `{"t": "table", "v": [[key, value], ...]}` for tables,
	`{"t": "cf" | "v3" | "Vector2" | "Color3", "v": [...]}` for Roblox types, and
	plain JSON for the rest.
--]]
local function unpackNode(node)
	if type(node) ~= "table" then return node end

	local kind, values = node.t, node.v
	if kind == "table" then
		local result = {}
		for _, pair in values or {} do
			result[pair[1]] = unpackNode(pair[2])
		end
		return result
	elseif kind == "cf" then
		return CFrame.new(table.unpack(values))
	elseif kind == "v3" then
		return Vector3.new(values[1], values[2], values[3])
	elseif kind == "Vector2" then
		return Vector2.new(values[1], values[2])
	elseif kind == "Color3" then
		if values[1] > 1 or values[2] > 1 or values[3] > 1 then
			return Color3.fromRGB(values[1], values[2], values[3])
		end
		return Color3.new(values[1], values[2], values[3])
	end

	return values
end

local function readProperties(sequence: Instance?)
	local folder = sequence and sequence:FindFirstChild(ECLIPSE_PROPERTIES)
	if not folder then return nil end

	local chunks = folder:GetChildren()
	table.sort(chunks, function(a, b) return a.Name < b.Name end)

	local parts = {}
	for _, chunk in chunks do
		if chunk:IsA("StringValue") then
			table.insert(parts, chunk.Value)
		end
	end

	local ok, document = pcall(HttpService.JSONDecode, HttpService, table.concat(parts))
	if not ok then return nil end

	if typeof(document) == "buffer" then
		ok, document = pcall(HttpService.JSONDecode, HttpService, buffer.tostring(document))
		if not ok then return nil end
	end

	return unpackNode(document)
end

-- The property tracks of an `EclipseProperties` document, by property name.
local function readPropertyTracks(properties)
	local tracks = {}
	if not properties or type(properties.tracks) ~= "table" then return tracks end

	for _, track in properties.tracks do
		if type(track) ~= "table" or type(track.id) ~= "string" then continue end
		if track.enabled == false or track.disabled == true then continue end
		if type(track.keys) ~= "table" then continue end

		local keys = {}
		for frame, key in track.keys do
			if type(key) ~= "table" or key.PropertyValue == nil then continue end

			table.insert(keys, {
				frame = tonumber(key.Frame) or tonumber(frame) or 0,
				value = key.PropertyValue,
				leave = propertyEase(key.EasingStyle, key.EasingDirection, key.BezierPoints),
			})
		end

		if #keys > 0 then
			sortKeys(keys)
			tracks[track.id] = { default = track.default, keys = keys }
		end
	end

	return tracks
end

local function saveOf(model: Instance, project: string): KeyframeSequence?
	local saves = model:FindFirstChild(ECLIPSE_SAVES)
	local sequence = saves and saves:FindFirstChild(project)
	if sequence and sequence:IsA("KeyframeSequence") then
		return sequence
	end
	return nil
end

local function motorNames(model: Instance)
	local names = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part1 then
			names[descendant.Part1.Name] = true
		end
	end
	return names
end

-- The camera rig: a direct child of the scene with a Motor6D driving `CamPart`.
local function findCameraRig(asset: Instance): Instance?
	for _, child in asset:GetChildren() do
		if not child:IsA("Model") then continue end
		if motorNames(child)[CAMERA_PART] then
			return child
		end
	end
	return nil
end

local function readSubtitles(asset: Instance)
	local subtitles = {}

	local folder = asset:FindFirstChild(SUBTITLES_FOLDER)
	local events = folder and folder:FindFirstChild(ECLIPSE_EVENTS)
	if not events then return subtitles end

	for _, event in events:GetChildren() do
		if event:GetAttribute("Enabled") == false then continue end

		local frame = event:GetAttribute("Frame")
		local value = event:FindFirstChild("Subtitle")
		if type(frame) ~= "number" or not value or not value:IsA("StringValue") or value.Value == "" then continue end

		local ok, subtitle = pcall(HttpService.JSONDecode, HttpService, value.Value)
		if not ok or type(subtitle) ~= "table" then continue end

		local base = type(subtitle.Base) == "table" and subtitle.Base or {}
		local text = type(base.Text) == "string" and string.match(base.Text, "^%s*(.-)%s*$") or ""
		if text == "" then continue end

		table.insert(subtitles, {
			frame = frame,
			duration = tonumber(subtitle.Duration) or 120,
			inFrames = tonumber(subtitle.InFrames) or 0,
			outFrames = tonumber(subtitle.OutFrames) or 0,
			entrance = subtitle.Entrance,
			exit = subtitle.Exit,
			text = text,
			speaker = base.Speaker,
			font = base.Font,
			size = base.Size,
			bold = base.Bold,
			italic = base.Italic,
			color = base.Color,
			outline = base.Outline,
			outlineColor = base.OutlineColor,
			background = base.Background,
			backgroundOpacity = base.BackgroundOpacity,
			position = base.Position,
			x = base.X,
			y = base.Y,
			width = base.Width,
			align = base.Align,
			nameColor = base.NameColor,
			nameFont = base.NameFont,
			nameSize = base.NameSize,
		})
	end

	table.sort(subtitles, function(a, b) return a.frame < b.frame end)
	return subtitles
end

--[[
	Reads an Eclipse scene from its KeyframeSequences. Returns plain data only (names
	and keys, no instance references), the same shape `Decode` gives back for a
	format 2 blob:

		{
			format = "eclipse",
			lastFrame = number,
			camera = keys,        -- CamPart Transform
			fov = keys?,          -- degrees
			rigs = { { target, joints = { { partName, keys } }, root = keys? } },
			effects = { { kind, defaults, tracks = { [property] = keys } } },
			subtitles = { ... },
		}

	Joint and camera values are the joints' `Transform`, not C1: the player turns
	them into C1 against each Motor6D's own rest C1.
--]]
function CutsceneFormat.ReadEclipse(asset: Instance)
	local project = asset:GetAttribute(ECLIPSE_PROJECT)
	if type(project) ~= "string" then return nil end

	local reference = asset:FindFirstChild(SCENE_REFERENCE)
	local authored = reference and reference:GetAttribute(AUTHORED_ATTRIBUTE)
	if typeof(authored) ~= "CFrame" then
		authored = reference and reference:IsA("BasePart") and reference.CFrame or CFrame.identity
	end

	local scene = {
		format = "eclipse",
		lastFrame = 0,
		camera = nil,
		fov = nil,
		rigs = {},
		effects = {},
		subtitles = {},
	}

	local function stretch(keys)
		if keys and #keys > 0 then
			scene.lastFrame = math.max(scene.lastFrame, keys[#keys].frame)
		end
	end

	-- Camera
	local cameraRig = findCameraRig(asset)
	local cameraSequence = cameraRig and saveOf(cameraRig, project)
	if not cameraSequence then return nil end

	local cameraTracks = readSequence(cameraSequence)
	local cameraKeys = cameraTracks[CAMERA_PART]
	if not cameraKeys or #cameraKeys == 0 then return nil end

	scene.camera = finishKeys(stripOrder(cameraKeys))
	stretch(scene.camera)

	local fovKeys = cameraTracks[ECLIPSE_FOV_PART]
	if fovKeys and #fovKeys > 0 then
		for _, key in fovKeys do
			key.value = key.value.Y + ECLIPSE_FOV_BASE
		end
		scene.fov = finishKeys(stripOrder(fovKeys))
		stretch(scene.fov)
	end

	-- Rigs
	local rigs = asset:FindFirstChild(RIGS_FOLDER)
	for _, rig in rigs and rigs:GetChildren() or {} do
		local sequence = saveOf(rig, project)
		if not sequence then continue end

		local motors = motorNames(rig)
		local joints = {}

		for partName, keys in readSequence(sequence) do
			if not motors[partName] or #keys == 0 then continue end

			local finished = finishKeys(stripOrder(keys))
			table.insert(joints, { partName = partName, keys = finished })
			stretch(finished)
		end

		table.sort(joints, function(a, b) return a.partName < b.partName end)

		-- A root track that never changes is the rig standing where it was placed:
		-- nothing to play.
		local root = nil
		local rootTrack = readPropertyTracks(readProperties(sequence))[ECLIPSE_ROOT_TRACK]
		if rootTrack and #rootTrack.keys > 1 then
			local moves = false
			for index = 2, #rootTrack.keys do
				if not sameValue(rootTrack.keys[index].value, rootTrack.keys[1].value) then
					moves = true
					break
				end
			end

			if moves then
				for _, key in rootTrack.keys do
					key.value = authored:ToObjectSpace(key.value)
				end
				root = finishKeys(rootTrack.keys)
				stretch(root)
			end
		end

		if #joints > 0 or root then
			table.insert(scene.rigs, { target = rig.Name, joints = joints, root = root })
		end
	end

	-- Effects
	local effects = asset:FindFirstChild(EFFECTS_FOLDER)
	for _, effect in effects and effects:GetChildren() or {} do
		local kind = effect:GetAttribute("EffectKind")
		if type(kind) ~= "string" then continue end

		local defaults = {}
		for _, property in EFFECT_PROPERTIES do
			defaults[property] = effect:GetAttribute("Effect" .. property)
		end

		local tracks = {}
		for property, track in readPropertyTracks(readProperties(saveOf(effect, project))) do
			if track.default ~= nil then
				defaults[property] = track.default
			end

			tracks[property] = finishKeys(track.keys)
			stretch(tracks[property])
		end

		table.insert(scene.effects, { kind = kind, defaults = defaults, tracks = tracks })
	end

	-- Subtitles
	scene.subtitles = readSubtitles(asset)
	for _, subtitle in scene.subtitles do
		scene.lastFrame = math.max(scene.lastFrame, subtitle.frame + subtitle.duration)
	end

	return scene
end

--[[ ECLIPSE: ENCODE / DECODE ]]

-- A buffer that grows as it is written.
local function newWriter()
	local data = buffer.create(65536)
	local offset = 0

	local function reserve(count: number)
		local size = buffer.len(data)
		if offset + count <= size then return end

		while offset + count > size do
			size *= 2
		end

		local grown = buffer.create(size)
		buffer.copy(grown, 0, data, 0, offset)
		data = grown
	end

	local writer = {}

	function writer.u8(value: number)
		reserve(1)
		buffer.writeu8(data, offset, value)
		offset += 1
	end

	function writer.u32(value: number)
		reserve(4)
		buffer.writeu32(data, offset, value)
		offset += 4
	end

	function writer.f32(value: number)
		reserve(4)
		buffer.writef32(data, offset, value)
		offset += 4
	end

	function writer.string(text: string)
		writer.u32(#text)
		reserve(#text)
		buffer.writestring(data, offset, text)
		offset += #text
	end

	function writer.finish(): buffer
		local result = buffer.create(offset)
		buffer.copy(result, 0, data, 0, offset)
		return result
	end

	return writer
end

local function newReader(data: buffer, start: number)
	local offset = start
	local reader = {}

	function reader.u8(): number
		local value = buffer.readu8(data, offset)
		offset += 1
		return value
	end

	function reader.u32(): number
		local value = buffer.readu32(data, offset)
		offset += 4
		return value
	end

	function reader.f32(): number
		local value = buffer.readf32(data, offset)
		offset += 4
		return value
	end

	function reader.string(): string
		local length = reader.u32()
		local text = buffer.readstring(data, offset, length)
		offset += length
		return text
	end

	return reader
end

--[[
	Rotation as a quaternion: 7 floats a key instead of 12. Taken from the matrix (not
	`ToAxisAngle`), which stays well-conditioned at any angle; `Bake` measures the
	round trip and refuses to save if it drifts.
--]]
local function toQuaternion(value: CFrame): (number, number, number, number)
	local _, _, _, m00, m01, m02, m10, m11, m12, m20, m21, m22 = value:GetComponents()
	local trace = m00 + m11 + m22

	if trace > 0 then
		local s = math.sqrt(1 + trace) * 2
		return (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		return 0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		return (m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		return (m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s
	end
end

-- Roblox values in the JSON part of the blob: effects and subtitles.
local function packValue(value)
	local kind = typeof(value)
	if kind == "Color3" then return { c3 = { value.R, value.G, value.B } } end
	if kind == "Vector2" then return { v2 = { value.X, value.Y } } end
	if kind == "number" or kind == "boolean" or kind == "string" then return value end
	return nil
end

local function unpackValue(value)
	if type(value) ~= "table" then return value end
	if value.c3 then return Color3.new(value.c3[1], value.c3[2], value.c3[3]) end
	if value.v2 then return Vector2.new(value.v2[1], value.v2[2]) end
	return nil
end

--[[
	Format 2 layout:

		u8      version (2)
		f32     lastFrame
		u8      number of easings, then each as u32 length + bytes
		track   camera (CFrame)
		track   fov (number), count 0 when there is none
		u32     number of rigs, and for each:
		          string target, u32 number of joints,
		          per joint: string partName + track (CFrame),
		          track root (CFrame), count 0 when the rig does not move
		string  JSON: effects and subtitles

	A track is a u32 count and, per key, f32 frame + u8 easing + the value: 3 f32
	position and 4 f32 quaternion for a CFrame, one f32 for a number. Frames are f32
	because Eclipse bakes sub-frame keys (41.5, 90.125).
--]]
function CutsceneFormat.EncodeEclipse(scene): string
	local easeList = {}
	local easeIndex = {}
	local function easeId(ease: string?): number
		if not ease then return 0 end
		if not easeIndex[ease] then
			table.insert(easeList, ease)
			easeIndex[ease] = #easeList
		end
		return easeIndex[ease]
	end

	local function collect(keys)
		for _, key in keys or {} do easeId(key.ease) end
	end

	collect(scene.camera)
	collect(scene.fov)
	for _, rig in scene.rigs do
		for _, joint in rig.joints do collect(joint.keys) end
		collect(rig.root)
	end
	assert(#easeList < 256, "too many distinct easings for one scene")

	local writer = newWriter()

	local function writeCFrameKeys(keys)
		writer.u32(keys and #keys or 0)
		for _, key in keys or {} do
			writer.f32(key.frame)
			writer.u8(easeId(key.ease))

			local position = key.value.Position
			writer.f32(position.X)
			writer.f32(position.Y)
			writer.f32(position.Z)

			local qx, qy, qz, qw = toQuaternion(key.value)
			writer.f32(qx)
			writer.f32(qy)
			writer.f32(qz)
			writer.f32(qw)
		end
	end

	writer.u8(CutsceneFormat.ECLIPSE_VERSION)
	writer.f32(scene.lastFrame)

	writer.u8(#easeList)
	for _, ease in easeList do writer.string(ease) end

	writeCFrameKeys(scene.camera)

	writer.u32(scene.fov and #scene.fov or 0)
	for _, key in scene.fov or {} do
		writer.f32(key.frame)
		writer.u8(easeId(key.ease))
		writer.f32(key.value)
	end

	writer.u32(#scene.rigs)
	for _, rig in scene.rigs do
		writer.string(rig.target)
		writer.u32(#rig.joints)
		for _, joint in rig.joints do
			writer.string(joint.partName)
			writeCFrameKeys(joint.keys)
		end
		writeCFrameKeys(rig.root)
	end

	-- Effects and subtitles are few and varied: JSON is enough, with the Roblox
	-- values packed by hand.
	local effects = {}
	for _, effect in scene.effects do
		local defaults = {}
		for property, value in effect.defaults do
			defaults[property] = packValue(value)
		end

		local tracks = {}
		for property, keys in effect.tracks do
			local packed = {}
			for _, key in keys do
				table.insert(packed, { f = key.frame, e = key.ease, v = packValue(key.value) })
			end
			tracks[property] = packed
		end

		table.insert(effects, { kind = effect.kind, defaults = defaults, tracks = tracks })
	end

	writer.string(HttpService:JSONEncode({ effects = effects, subtitles = scene.subtitles }))

	return toBase64(writer.finish())
end

local function decodeEclipse(data: buffer)
	local reader = newReader(data, 1)

	local scene = {
		format = "eclipse",
		lastFrame = reader.f32(),
		camera = nil,
		fov = nil,
		rigs = {},
		effects = {},
		subtitles = {},
	}

	local easeList = {}
	for _ = 1, reader.u8() do
		table.insert(easeList, reader.string())
	end

	local function readCFrameKeys()
		local count = reader.u32()
		if count == 0 then return nil end

		local keys = table.create(count)
		for index = 1, count do
			local frame = reader.f32()
			local ease = easeList[reader.u8()]
			local x, y, z = reader.f32(), reader.f32(), reader.f32()
			local qx, qy, qz, qw = reader.f32(), reader.f32(), reader.f32(), reader.f32()

			keys[index] = { frame = frame, ease = ease, value = CFrame.new(x, y, z, qx, qy, qz, qw) }
		end
		return keys
	end

	scene.camera = readCFrameKeys()

	local fovCount = reader.u32()
	if fovCount > 0 then
		local keys = table.create(fovCount)
		for index = 1, fovCount do
			local frame = reader.f32()
			local ease = easeList[reader.u8()]
			keys[index] = { frame = frame, ease = ease, value = reader.f32() }
		end
		scene.fov = keys
	end

	for _ = 1, reader.u32() do
		local target = reader.string()
		local joints = {}
		for _ = 1, reader.u32() do
			local partName = reader.string()
			table.insert(joints, { partName = partName, keys = readCFrameKeys() })
		end
		table.insert(scene.rigs, { target = target, joints = joints, root = readCFrameKeys() })
	end

	local ok, extra = pcall(HttpService.JSONDecode, HttpService, reader.string())
	if ok and type(extra) == "table" then
		for _, effect in extra.effects or {} do
			local defaults = {}
			for property, value in effect.defaults or {} do
				defaults[property] = unpackValue(value)
			end

			local tracks = {}
			for property, packed in effect.tracks or {} do
				local keys = {}
				for _, key in packed do
					table.insert(keys, { frame = key.f, ease = key.e, value = unpackValue(key.v) })
				end
				if #keys > 0 then
					tracks[property] = keys
				end
			end

			table.insert(scene.effects, { kind = effect.kind, defaults = defaults, tracks = tracks })
		end

		scene.subtitles = extra.subtitles or {}
	end

	if not scene.camera then return nil end
	return scene
end

--[[
	Decodes a blob of either format: the first byte says which.
--]]
function CutsceneFormat.Decode(encoded: string)
	local data = fromBase64(encoded)
	if buffer.len(data) < 4 then return nil end

	local version = buffer.readu8(data, 0)
	if version == CutsceneFormat.VERSION then
		return decodeMoon(data)
	elseif version == CutsceneFormat.ECLIPSE_VERSION then
		local ok, scene = pcall(decodeEclipse, data)
		return if ok then scene else nil
	end

	return nil
end

--[[ ECLIPSE: BAKE (Studio) ]]

local function writeBlob(asset: Instance, encoded: string)
	local stored = asset:FindFirstChild(CutsceneFormat.DATA_NAME)
	if stored then
		stored:Destroy()
	end

	stored = Instance.new("StringValue")
	stored.Name = CutsceneFormat.DATA_NAME
	stored.Value = string.sub(encoded, 1, BLOB_CHUNK)

	local index = 2
	for start = BLOB_CHUNK + 1, #encoded, BLOB_CHUNK do
		local chunk = Instance.new("StringValue")
		chunk.Name = string.format("Chunk%03d", index)
		chunk.Value = string.sub(encoded, start, start + BLOB_CHUNK - 1)
		chunk.Parent = stored
		index += 1
	end

	stored.Parent = asset
end

-- The worst gap between two decodings of the same scene: studs and radians.
local function measureDrift(source, decoded): (number, number, number)
	local positionError, angleError, keys = 0, 0, 0

	local function compare(a, b)
		if not a or not b then return end
		for index, key in a do
			local other = b[index]
			if not other then continue end

			keys += 1
			positionError = math.max(positionError, (key.value.Position - other.value.Position).Magnitude)

			local delta = key.value.Rotation:ToObjectSpace(other.value.Rotation)
			local _, angle = delta:ToAxisAngle()
			angleError = math.max(angleError, math.abs(angle))
		end
	end

	compare(source.camera, decoded.camera)
	for index, rig in source.rigs do
		local other = decoded.rigs[index]
		if not other then continue end

		for jointIndex, joint in rig.joints do
			local otherJoint = other.joints[jointIndex]
			compare(joint.keys, otherJoint and otherJoint.keys)
		end
		compare(rig.root, other.root)
	end

	return positionError, angleError, keys
end

local function countEclipseKeys(scene): number
	local total = (scene.camera and #scene.camera or 0) + (scene.fov and #scene.fov or 0)
	for _, rig in scene.rigs do
		for _, joint in rig.joints do
			total += joint.keys and #joint.keys or 0
		end
		total += rig.root and #rig.root or 0
	end
	return total
end

--[[
	Builds the playable copy of an Eclipse scene in `destination`, under the same
	name, replacing any copy already there. The source is not touched.

	The copy loses everything only the editor reads (the KeyframeSequences, the
	effect Models, the subtitle folders, scripts) and gains `SceneData`, plus the
	`Duration` attribute (seconds) so the server knows how long to wait without
	decoding the blob.

	Nothing is written when the blob does not decode back to the same keys, or when
	the quaternion round trip drifts more than a hundredth of a stud or a degree.
--]]
function CutsceneFormat.BakeEclipse(source: Instance, destination: Instance): (boolean, string)
	local scene = CutsceneFormat.ReadEclipse(source)
	if not scene then
		return false, string.format("%s: no Eclipse camera with AnimSaves/%s", source.Name, tostring(source:GetAttribute(ECLIPSE_PROJECT)))
	end

	local encoded = CutsceneFormat.EncodeEclipse(scene)
	local check = CutsceneFormat.Decode(encoded)
	if not check or countEclipseKeys(check) ~= countEclipseKeys(scene) or #check.rigs ~= #scene.rigs
		or #check.effects ~= #scene.effects or #check.subtitles ~= #scene.subtitles then
		return false, string.format("%s: the blob does not match the source; nothing was written", source.Name)
	end

	local positionError, angleError = measureDrift(scene, check)
	if positionError > 0.01 or angleError > math.rad(1) then
		return false, string.format("%s: the blob drifts %.4f studs / %.3f deg; nothing was written",
			source.Name, positionError, math.deg(angleError))
	end

	local runtime = source:Clone()
	for _, descendant in runtime:GetDescendants() do
		if descendant:IsA("KeyframeSequence") or descendant:IsA("LuaSourceContainer")
			or descendant.Name == ECLIPSE_SAVES or descendant.Name == ECLIPSE_EXPORTS then
			descendant:Destroy()
		end
	end

	for _, name in { EFFECTS_FOLDER, SUBTITLES_FOLDER } do
		local folder = runtime:FindFirstChild(name)
		if folder then
			folder:Destroy()
		end
	end

	writeBlob(runtime, encoded)
	runtime:SetAttribute("Duration", scene.lastFrame / SCENE_FPS)

	local previous = destination:FindFirstChild(source.Name)
	if previous then
		previous:Destroy()
	end
	runtime.Parent = destination

	return true, string.format(
		"%s: %d -> %d instances, %.1f KB blob, %d keys, %d subtitles, %d effects, %.1f s, drift %.4f studs",
		source.Name, #source:GetDescendants(), #runtime:GetDescendants(), #encoded / 1024,
		countEclipseKeys(scene), #scene.subtitles, #scene.effects, scene.lastFrame / SCENE_FPS, positionError
	)
end

--[[
	Bakes every scene in `sources` (default `ServerStorage.CutsceneSources`) into
	`destination` (default `ServerStorage.Cutscenes`, created if missing).
--]]
function CutsceneFormat.BakeEclipseAll(sources: Instance?, destination: Instance?): string
	sources = sources or ServerStorage:FindFirstChild("CutsceneSources")
	if not sources then
		return "no ServerStorage.CutsceneSources"
	end

	if not destination then
		destination = ServerStorage:FindFirstChild("Cutscenes")
		if not destination then
			destination = Instance.new("Folder")
			destination.Name = "Cutscenes"
			destination.Parent = ServerStorage
		end
	end

	local lines = {}
	for _, source in (sources :: Instance):GetChildren() do
		local success, message = CutsceneFormat.BakeEclipse(source, destination :: Instance)
		table.insert(lines, (success and "ok     " or "FAILED ") .. message)
	end

	if #lines == 0 then
		return "no scenes found"
	end

	return table.concat(lines, "\n")
end

return CutsceneFormat
