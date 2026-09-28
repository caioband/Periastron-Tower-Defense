--[[
	Reading and compressing Moon Animator cutscene files.

	A Moon Animator save is a tree of Folders: each key becomes at least three
	instances, and a scene easily passes 700, all replicated to every client on
	join. This module reads that tree, packs it into a blob of a few KB, and lets
	the Folders be deleted: the published scene keeps only the live Parts plus a
	StringValue.

	Usage in Studio, after exporting from Moon Animator:

		local CutsceneFormat = require(game.ReplicatedStorage.Shared.Util.CutsceneFormat)
		print(CutsceneFormat.BakeAll(game.ReplicatedStorage.Shared.Assets.Cutscenes))

	`Read` prefers the blob and falls back to the Folders when there is none, so a
	freshly exported scene still plays without baking.

	The blob is base64 instead of raw bytes: it costs 33% of an already small
	number, and in exchange the place serialization cannot corrupt a non-printable
	byte.
--]]

local CutsceneFormat = {}

CutsceneFormat.VERSION = 1
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

function CutsceneFormat.Decode(encoded: string)
	local data = fromBase64(encoded)
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
	Reads the scene, preferring the blob. Returns the scene and where it came from,
	so the caller can warn that it is still in the heavy format.
--]]
function CutsceneFormat.Read(asset: Instance)
	local stored = asset:FindFirstChild(CutsceneFormat.DATA_NAME)
	if stored and stored:IsA("StringValue") and stored.Value ~= "" then
		local scene = CutsceneFormat.Decode(stored.Value)
		if scene then return scene, "blob" end
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

return CutsceneFormat
