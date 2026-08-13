local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local CrateConfig = SharedConfig.CrateConfig

local Framework = Me.new()

--[[ CONSTANTS ]]
local CRATES_FOLDER_NAME = "UnboxingCrates"
local TARGET_PART_NAME = "TargetPart"

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
local MIN_CRATE_SPACING = 6

-- Past this many at once the ring sweep runs out of spots that respect the spacing
-- above, and crates would start landing on top of each other.
local MAX_ACTIVE_UNBOXINGS = 5

local CRATE_CAN_COLLIDE = false

-- Reel: REEL_LENGTH entries are cloned out of the authored pool, and the reel stops
-- with entry (REEL_LENGTH - WINNER_TAIL) centered on the Clipper.
local REEL_LENGTH = 36
local WINNER_TAIL = 4

local SPIN_TIME = 4.25
local SPIN_INFO = TweenInfo.new(SPIN_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SETTLE_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

-- How far past the winner the reel rolls before settling back onto it, as a
-- fraction of one entry's width.
local OVERSHOOT_FRACTION = 0.08

-- How long the landed reel stays up before the crate is cleaned up.
local RESULT_HOLD = 2.5

local UnboxingController = {
	Controllers = {},

	Signals = {
		-- (rarity : string, crate : Model)
		UnboxingStarted = Signal.new(),
		-- (rarity : string, entry : GuiObject, crate : Model)
		UnboxingFinished = Signal.new(),
	},
}

--[[ INTERNAL ]]

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

function UnboxingController:_getRoot() : BasePart?
	local character = Players.LocalPlayer.Character
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

function UnboxingController:_spawnCrate(rarity : string, sessionMaid) : Model?
	local modelName = CrateConfig.getModelName(rarity)
	local template = modelName and self.CrateModels:FindFirstChild(modelName)
	if not template or not template:IsA("Model") then
		warn(string.format("[UnboxingController]: No crate model named %q in Assets.CratesModel.", tostring(modelName)))
		return nil
	end

	local rootPart = self:_getRoot()
	if not rootPart then
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
	crate:PivotTo(self:_resolvePlacement(rootPart, extents))

	crate.Parent = self.CratesFolder
	sessionMaid:GiveTask(crate)

	return crate
end

--[=[
	Clones the authored attachment into the crate's TargetPart. The attachment already
	carries its own offset, so it lands above the crate on its own.
]=]
function UnboxingController:_attachBillboard(crate : Model, sessionMaid) : Attachment?
	local targetPart = crate:FindFirstChild(TARGET_PART_NAME)
	if not targetPart or not targetPart:IsA("BasePart") then
		warn(string.format("[UnboxingController]: %s has no %s.", crate.Name, TARGET_PART_NAME))
		return nil
	end

	local attachment = self.AttachmentTemplate:Clone()
	attachment.Parent = targetPart
	sessionMaid:GiveTask(attachment)

	return attachment
end

--[=[
	Rebuilds the ScrollingFrame contents into a long reel. The entries the designer left
	in there are the pool -- they are pulled out and cloned back in at random.

	Returns a small handle with everything the spin needs: the frame to move, the
	entries, and a mapping from entry index to the frame position that centers it
	on the Clipper.
]=]
function UnboxingController:_buildReel(attachment : Attachment, sessionMaid)
	local billboard = attachment:FindFirstChildWhichIsA("BillboardGui")
	local frame = billboard and billboard:FindFirstChild("Frame")
	local scrollingFrame = frame and frame:FindFirstChild("ScrollingFrame")

	if not scrollingFrame or not scrollingFrame:IsA("ScrollingFrame") then
		warn("[UnboxingController]: UnboxingAttachment.BillboardGui.Frame.ScrollingFrame is missing.")
		return nil
	end

	local pool = {}
	for _, child in scrollingFrame:GetChildren() do
		if child:IsA("GuiObject") then
			table.insert(pool, child)

			-- Out of the layout, but kept alive as a template for the reel entries.
			child.Parent = nil
			sessionMaid:GiveTask(child)
		end
	end

	if #pool == 0 then
		warn("[UnboxingController]: ScrollingFrame has no entries to build the reel from.")
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

	local entries = table.create(REEL_LENGTH)
	for index = 1, REEL_LENGTH do
		local entry = pool[math.random(#pool)]:Clone()
		entry.Name = string.format("ReelEntry_%02d", index)
		entry.LayoutOrder = index
		entry.Visible = true
		entry.Parent = scrollingFrame

		entries[index] = entry
	end

	--[=[
		Frame position (scale) that puts entry `index` right under the Clipper.
	]=]
	local function positionFor(index : number) : number
		local offset = ((index - 1) * step + entryWidth * 0.5) * frameWidth
		return targetCenter + anchorX * frameWidth - offset
	end

	return {
		ScrollingFrame = scrollingFrame,
		Entries = entries,
		EntryWidth = entryWidth * frameWidth,
		PositionFor = positionFor,
	}
end

function UnboxingController:_spin(reel, sessionMaid, onFinished : (GuiObject) -> ())
	local scrollingFrame = reel.ScrollingFrame
	local basePosition = scrollingFrame.Position

	local function positionAt(x : number) : UDim2
		return UDim2.new(x, 0, basePosition.Y.Scale, basePosition.Y.Offset)
	end

	local winnerIndex = math.clamp(REEL_LENGTH - WINNER_TAIL, 1, #reel.Entries)
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

	settle.Completed:Once(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed then
			return
		end

		onFinished(winnerEntry)
	end)

	spin:Play()

	return winnerEntry
end

--[=[
	One unboxing = one session: its own maid, and the spot it took.
]=]
function UnboxingController:_openSession()
	self.SessionCount += 1

	local session = {
		Id = self.SessionCount,
		Maid = Maid.new(),
		Position = nil :: Vector3?,
		Closed = false,
	}

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

--[=[
	Spawns the crate of `rarity` in front of the local player and rolls the unboxing
	reel on top of it.

	Unboxings stack: calling this again while others are still rolling starts another
	one beside them, up to MAX_ACTIVE_UNBOXINGS. Returns false when it could not start
	(bad rarity, no character, missing asset, or too many already playing).
]=]
function UnboxingController:Open(rarity : string) : boolean
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[UnboxingController]: %q is not a valid crate rarity.", tostring(rarity)))
		return false
	end

	if #self.Sessions >= MAX_ACTIVE_UNBOXINGS then
		return false
	end

	if not self:_getRoot() then
		warn("[UnboxingController]: The character is not spawned yet.")
		return false
	end

	local session = self:_openSession()

	local crate = self:_spawnCrate(resolvedRarity, session.Maid)
	if not crate then
		self:_closeSession(session)
		return false
	end

	-- Where the crate ended up is what the next unboxing has to keep away from.
	session.Position = crate:GetPivot().Position

	local attachment = self:_attachBillboard(crate, session.Maid)
	if not attachment then
		self:_closeSession(session)
		return false
	end

	local reel = self:_buildReel(attachment, session.Maid)
	if not reel then
		self:_closeSession(session)
		return false
	end

	local winnerEntry = self:_spin(reel, session.Maid, function(entry : GuiObject)
		if session.Closed then
			return
		end

		self.Signals.UnboxingFinished:Fire(resolvedRarity, entry, crate)

		task.delay(RESULT_HOLD, function()
			self:_closeSession(session)
		end)
	end)

	self.Signals.UnboxingStarted:Fire(resolvedRarity, crate)

	return winnerEntry ~= nil
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

	self.CrateModels = Assets:WaitForChild("CratesModel")
	self.AttachmentTemplate = Assets:WaitForChild("UI"):WaitForChild("UnboxingAttachment")

	local folder = Instance.new("Folder")
	folder.Name = CRATES_FOLDER_NAME
	folder.Parent = workspace

	self.CratesFolder = folder
	self.Maid:GiveTask(folder)

	-- The server drives this once crates are actually consumed; until then it is here
	-- so the flow can be triggered from outside the client.
	Framework:Listen("PlayUnboxing", function(rarity : string)
		self:Open(rarity)
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
