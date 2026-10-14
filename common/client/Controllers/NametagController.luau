local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local SharedConfig = require(Configs.SharedConfig)

local Framework = Me.new()
local log = Log.new("NametagController")

local NametagConfig = SharedConfig.NametagConfig

local LocalPlayer = Players.LocalPlayer

local USERNAME_NAME = "Username"
local LEVEL_NAME = "Level"
local TITLE_NAME = "Title"
local WAIT_TIMEOUT = 10
local REQUEST_COOLDOWN = 0.3
local SCROLL_SAMPLES = 16

local EFFECTS_FOLDER = "NametagEffects"
local EFFECT_HOLDER_SIZE = Vector3.new(0.05, 0.05, 0.05)

--[=[
	Draws every player's nametag, in every place.

	What a player wears comes from their `EquippedNametag` attribute and their level
	from `Level`, both published by `NametagService`. The look is the BillboardGui
	named by the nametag's `Template` in `Shared.Assets.Nametags`, plus its optional
	`Style`, `Offset` and `Title`. A template only needs a `Username` and a `Level`
	TextLabel somewhere inside it, so each one can be laid out freely in Studio.

	**Effects.** A BillboardGui is 2D and cannot render particles, so a template
	carries them in Attachments placed directly under it. On spawn they move onto an
	invisible client-only part (`Workspace.NametagEffects`) that **follows the text,
	not the head**: every frame it is placed where the billboard draws (the head's
	position, plus `StudsOffsetWorldSpace`, plus `StudsOffset` in camera space) and
	turned to face the camera, like the billboard. So the effects never bob, tilt or
	turn with the head's animation, and an Attachment's authored `Position` reads as an
	offset from the text in screen directions (X right, Y up). `LockedToPart` emitters
	lock to that part, so they stay glued to the name too. They live and die with the
	tag: rebuilding, unequipping, respawning or leaving removes them.

	**Title.** A nametag with `Title` gets a line above the name. If the template
	already has a `Title` TextLabel it is used as authored. Otherwise `Username` is
	cloned into one at `TITLE_SCALE` of its height, the tag grows by that much, the
	existing lines shrink back to their old real size, and `StudsOffset` rises by half
	the growth, so the name stays where it was. `Style.Title` styles it.

	A style's `Animation = { Mode, Speed }` plays forever:
	  `Scroll` cycles the gradient's colours along the text, `Speed` cycles per second.
	  The pattern is resampled each frame with a phase shift and wraps from its last
	  colour back to its first, so make those two keypoints the same colour.
	  `Rotate` spins the gradient, `Speed` turns per second.

	`Animated` is a strong table on purpose: a weak-keyed one loses Instance keys when
	the garbage collector runs, which froze animations. Gradients leave it through
	`Destroying`, and `_step` also drops any that lost their parent.

	Text is written on the clone before it is parented, so a new tag never shows the
	template's placeholder text.

	`Toggle(id)` is the hook for an equip UI: it checks the replica for ownership and
	level, and asks `NametagService` to equip or unequip.
]=]
local NametagController = {
	Controllers = {
		DataController = {},
	},
}

--[[ INTERNAL ]]

local function sampleSequence(keypoints : { ColorSequenceKeypoint }, t : number) : Color3
	local count = #keypoints
	if count == 0 then
		return Color3.new(1, 1, 1)
	end

	if t <= keypoints[1].Time then
		return keypoints[1].Value
	end

	for index = 1, count - 1 do
		local current = keypoints[index]
		local following = keypoints[index + 1]
		if t <= following.Time then
			local span = following.Time - current.Time
			local alpha = if span > 0 then (t - current.Time) / span else 0
			return current.Value:Lerp(following.Value, alpha)
		end
	end

	return keypoints[count].Value
end

local function shiftedSequence(keypoints : { ColorSequenceKeypoint }, phase : number) : ColorSequence
	local shifted = table.create(SCROLL_SAMPLES)

	for index = 0, SCROLL_SAMPLES - 1 do
		local position = index / (SCROLL_SAMPLES - 1)
		local source = (position - phase) % 1
		shifted[index + 1] = ColorSequenceKeypoint.new(position, sampleSequence(keypoints, source))
	end

	return ColorSequence.new(shifted)
end

local function findLabel(root : Instance, name : string) : TextLabel?
	local label = root:FindFirstChild(name, true)
	return if label and label:IsA("TextLabel") then label else nil
end

local function scaleHeight(size : UDim2, factor : number) : UDim2
	return UDim2.new(size.X.Scale, size.X.Offset, size.Y.Scale * factor, size.Y.Offset * factor)
end

function NametagController:_template(id : string?) : BillboardGui?
	local folder = self.Folder
	if not folder then
		return nil
	end

	local _, nametag = NametagConfig.Resolve(id)
	local template = nametag and folder:FindFirstChild(nametag.Template)

	if not template or not template:IsA("BillboardGui") then
		local _, fallback = NametagConfig.Resolve(nil)
		template = folder:FindFirstChild(fallback.Template)
	end

	if template and template:IsA("BillboardGui") then
		return template
	end

	log:StudioWarn(`no BillboardGui template for nametag {tostring(id)}`)
	return nil
end

function NametagController:_addTitle(tag : BillboardGui, text : string) : TextLabel?
	local authored = findLabel(tag, TITLE_NAME)
	if authored then
		authored.Text = text
		authored.Visible = true
		return authored
	end

	local username = findLabel(tag, USERNAME_NAME)
	local container = username and username.Parent
	if not username or not container then
		return nil
	end

	local titleShare = username.Size.Y.Scale * NametagConfig.TITLE_SCALE
	if titleShare <= 0 then
		return nil
	end

	local grow = 1 + titleShare
	local lowestOrder = math.huge

	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child.Size = scaleHeight(child.Size, 1 / grow)
			lowestOrder = math.min(lowestOrder, child.LayoutOrder)
		end
	end

	local title = username:Clone()
	title.Name = TITLE_NAME
	title.Text = text
	title.Visible = true
	title.LayoutOrder = if lowestOrder == math.huge then -1 else lowestOrder - 1
	title.Size = UDim2.new(username.Size.X.Scale, username.Size.X.Offset, titleShare / grow, 0)

	for _, child in title:GetChildren() do
		if child:IsA("UIGradient") then
			child:Destroy()
		end
	end

	title.Parent = container

	local originalHeight = tag.Size.Y.Scale
	tag.Size = scaleHeight(tag.Size, grow)
	tag.StudsOffset += Vector3.new(0, originalHeight * (grow - 1) / 2, 0)

	return title
end

function NametagController:_takeEffects(tag : BillboardGui) : { Attachment }
	local effects = {}

	for _, child in tag:GetChildren() do
		if child:IsA("Attachment") then
			table.insert(effects, child)
		end
	end

	return effects
end

function NametagController:_effectsFolder() : Folder
	local folder = self.EffectsFolder
	if folder and folder.Parent then
		return folder
	end

	folder = workspace:FindFirstChild(EFFECTS_FOLDER)
	if not folder or not folder:IsA("Folder") then
		folder = Instance.new("Folder")
		folder.Name = EFFECTS_FOLDER
		folder.Parent = workspace
	end

	self.EffectsFolder = folder
	return folder
end

--- Where the billboard draws its centre this frame, and the camera's rotation.
local function textFrame(tag : BillboardGui, head : BasePart) : CFrame
	local camera = workspace.CurrentCamera
	local rotation = if camera then camera.CFrame.Rotation else CFrame.identity
	local position = head.Position + tag.StudsOffsetWorldSpace + rotation:VectorToWorldSpace(tag.StudsOffset)

	return CFrame.new(position) * rotation
end

--[=[
	Moves the template's effect Attachments onto a holder part that follows the text
	(see `_stepEffects`). The Attachments keep their authored `Position`, now an
	offset from the text in camera-aligned directions.
]=]
function NametagController:_mountEffects(tag : BillboardGui, head : BasePart, effects : { Attachment })
	if #effects == 0 then
		return
	end

	local holder = Instance.new("Part")
	holder.Name = tag.Name
	holder.Size = EFFECT_HOLDER_SIZE
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.CastShadow = false
	holder.Massless = true
	holder.CFrame = textFrame(tag, head)

	for _, attachment in effects do
		attachment.Parent = holder
	end

	holder.Parent = self:_effectsFolder()

	self.Effects[holder] = {
		Tag = tag,
		Head = head,
	}

	tag.Destroying:Connect(function()
		self.Effects[holder] = nil
		holder:Destroy()
	end)
end

function NametagController:_stepEffects()
	for holder, record in self.Effects do
		local tag = record.Tag
		local head = record.Head

		if not holder.Parent or not tag.Parent or not head.Parent then
			self.Effects[holder] = nil
			holder:Destroy()
			continue
		end

		holder.CFrame = textFrame(tag, head)
	end
end

function NametagController:_animate(gradient : UIGradient, animation : any, keypoints : { ColorSequenceKeypoint })
	local existing = self.Animated[gradient]
	if existing and existing.Connection then
		existing.Connection:Disconnect()
	end

	local record = {
		Mode = animation.Mode,
		Speed = tonumber(animation.Speed) or 0.5,
		BaseRotation = gradient.Rotation,
		Keypoints = keypoints,
		Connection = nil :: RBXScriptConnection?,
	}

	record.Connection = gradient.Destroying:Connect(function()
		if self.Animated[gradient] == record then
			self.Animated[gradient] = nil
		end
	end)

	self.Animated[gradient] = record
end

function NametagController:_applyStyle(label : TextLabel?, style : any)
	if not label or typeof(style) ~= "table" then
		return
	end

	if style.TextColor3 then
		label.TextColor3 = style.TextColor3
	end

	if style.FontFace then
		label.FontFace = style.FontFace
	end

	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		if style.StrokeColor then
			stroke.Color = style.StrokeColor
		end
		if style.StrokeThickness then
			stroke.Thickness = style.StrokeThickness
		end
	end

	if not style.Gradient then
		return
	end

	local gradient = label:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	gradient.Color = style.Gradient
	gradient.Rotation = style.GradientRotation or 0
	gradient.Offset = Vector2.zero
	gradient.Parent = label

	local animation = style.Animation
	if typeof(animation) == "table" and (animation.Mode == "Scroll" or animation.Mode == "Rotate") then
		self:_animate(gradient, animation, style.Gradient.Keypoints)
	end
end

function NametagController:_step()
	local now = os.clock()

	for gradient, animation in self.Animated do
		if not gradient.Parent then
			if animation.Connection then
				animation.Connection:Disconnect()
			end
			self.Animated[gradient] = nil
			continue
		end

		if animation.Mode == "Scroll" then
			gradient.Color = shiftedSequence(animation.Keypoints, (now * animation.Speed) % 1)
		else
			gradient.Rotation = (animation.BaseRotation + now * animation.Speed * 360) % 360
		end
	end
end

function NametagController:_writeText(player : Player, tag : BillboardGui)
	local username = findLabel(tag, USERNAME_NAME)
	if username then
		username.Text = player.DisplayName
	end

	local levelLabel = findLabel(tag, LEVEL_NAME)
	if levelLabel then
		local level = player:GetAttribute(NametagConfig.LEVEL_ATTRIBUTE)
		levelLabel.Visible = level ~= nil
		if level ~= nil then
			levelLabel.Text = string.format(NametagConfig.LEVEL_FORMAT, level)
		end
	end
end

function NametagController:_renderText(player : Player)
	local entry = self.Entries[player]
	local tag = entry and entry.Tag
	if not tag then
		return
	end

	self:_writeText(player, tag)
end

function NametagController:_attach(player : Player, character : Model)
	local entry = self.Entries[player]
	if not entry then
		return
	end

	local humanoid = character:WaitForChild("Humanoid", WAIT_TIMEOUT) :: Humanoid?
	local head = character:WaitForChild("Head", WAIT_TIMEOUT) :: BasePart?
	if not humanoid or not head or player.Character ~= character or self.Entries[player] ~= entry then
		return
	end

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	if entry.Tag then
		entry.Tag:Destroy()
		entry.Tag = nil
	end

	if player == LocalPlayer and not NametagConfig.SHOW_OWN then
		return
	end

	local id = NametagConfig.nonEmpty(player:GetAttribute(NametagConfig.ATTRIBUTE))
	local template = self:_template(id)
	if not template then
		return
	end

	local _, nametag = NametagConfig.Resolve(id)
	local style = nametag and nametag.Style

	local tag = template:Clone()
	tag.Name = NametagConfig.TAG_NAME
	tag.Adornee = head
	tag.ResetOnSpawn = false

	if nametag and typeof(nametag.Offset) == "Vector3" then
		tag.StudsOffset = nametag.Offset
	end

	local authoredTitle = findLabel(tag, TITLE_NAME)
	local titleText = nametag and NametagConfig.nonEmpty(nametag.Title)
	local titleLabel = nil

	if titleText then
		titleLabel = self:_addTitle(tag, titleText)
	elseif authoredTitle then
		authoredTitle.Visible = false
	end

	if style then
		self:_applyStyle(findLabel(tag, USERNAME_NAME), style.Username)
		self:_applyStyle(findLabel(tag, LEVEL_NAME), style.Level)
		self:_applyStyle(titleLabel, style.Title)
	end

	self:_writeText(player, tag)

	local effects = self:_takeEffects(tag)

	entry.Tag = tag
	tag.Parent = head

	self:_mountEffects(tag, head, effects)
end

function NametagController:_rebuild(player : Player)
	local character = player.Character
	if character then
		task.spawn(self._attach, self, player, character)
	end
end

function NametagController:_track(player : Player)
	if self.Entries[player] then
		return
	end

	local entry = {
		Maid = Maid.new(),
		Tag = nil :: BillboardGui?,
	}

	self.Entries[player] = entry

	entry.Maid:GiveTask(function()
		if entry.Tag then
			entry.Tag:Destroy()
			entry.Tag = nil
		end
	end)

	entry.Maid:GiveTask(player.CharacterAdded:Connect(function(character)
		self:_attach(player, character)
	end))

	entry.Maid:GiveTask(player:GetAttributeChangedSignal(NametagConfig.ATTRIBUTE):Connect(function()
		self:_rebuild(player)
	end))

	entry.Maid:GiveTask(player:GetAttributeChangedSignal(NametagConfig.LEVEL_ATTRIBUTE):Connect(function()
		self:_renderText(player)
	end))

	entry.Maid:GiveTask(player:GetPropertyChangedSignal("DisplayName"):Connect(function()
		self:_renderText(player)
	end))

	self:_rebuild(player)
end

function NametagController:_untrack(player : Player)
	local entry = self.Entries[player]
	if not entry then
		return
	end

	self.Entries[player] = nil
	entry.Maid:DoCleaning()
end

function NametagController:_data()
	local replica = self.Replica
	return replica and replica.Data
end

function NametagController:_level() : number
	return NametagConfig.LevelOf(self:_data())
end

function NametagController:_nametags()
	local data = self:_data()
	return NametagConfig.sanitize(data and data[NametagConfig.PROFILE_KEY], NametagConfig.LevelOf(data))
end

--[[ EXTERNAL ]]

function NametagController:GetEquipped(player : Player?) : string
	local target = player or LocalPlayer
	return NametagConfig.nonEmpty(target:GetAttribute(NametagConfig.ATTRIBUTE)) or NametagConfig.DEFAULT
end

function NametagController:Owns(id : string) : boolean
	return NametagConfig.IsAvailable(id, self:_nametags().Owned, self:_level())
end

function NametagController:Toggle(id : string)
	if not NametagConfig.Get(id) then
		return
	end

	local now = os.clock()
	if now - self.LastRequest < REQUEST_COOLDOWN then
		return
	end
	self.LastRequest = now

	if not self:Owns(id) then
		return
	end

	if self:_nametags().Equipped == id then
		Framework:Fire("RequestUnequipNametag", id)
	else
		Framework:Fire("RequestEquipNametag", id)
	end
end

function NametagController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	Framework:Listen("NametagResult", function(id, action, ok, reason)
		if not ok then
			log:StudioWarn(`nametag {tostring(action)} refused for {tostring(id)}: {tostring(reason)}`)
		end
	end)

	local assets = Shared:WaitForChild("Assets")
	self.Folder = assets:WaitForChild(NametagConfig.ASSET_FOLDER, WAIT_TIMEOUT)
	if not self.Folder then
		log:StudioWarn(`missing Shared.Assets.{NametagConfig.ASSET_FOLDER}`)
	end

	self.Maid:GiveTask(RunService.RenderStepped:Connect(function()
		if next(self.Animated) ~= nil then
			self:_step()
		end

		if next(self.Effects) ~= nil then
			self:_stepEffects()
		end
	end))

	for _, player in Players:GetPlayers() do
		self:_track(player)
	end

	self.Maid:GiveTask(Players.PlayerAdded:Connect(function(player)
		self:_track(player)
	end))

	self.Maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:_untrack(player)
	end))

	task.spawn(function()
		local dataController = self.Controllers.DataController
		if dataController and dataController.GetReplica then
			self.Replica = dataController:GetReplica()
		end
	end)
end

function NametagController:init()
	self.Maid = Maid.new()
	self.Entries = {}
	self.Animated = {}
	self.Effects = {}
	self.EffectsFolder = nil
	self.LastRequest = 0
	self.Replica = nil
	self.Folder = nil

	self.Maid:GiveTask(function()
		for player in self.Entries do
			self:_untrack(player)
		end

		for _, animation in self.Animated do
			if animation.Connection then
				animation.Connection:Disconnect()
			end
		end

		table.clear(self.Animated)

		for holder in self.Effects do
			holder:Destroy()
		end

		table.clear(self.Effects)
	end)
end

return NametagController