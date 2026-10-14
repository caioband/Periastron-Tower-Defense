local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local SharedConfig = require(Configs.SharedConfig)

local Framework = Me.new()
local log = Log.new("NametagBackpackController")

local NametagConfig = SharedConfig.NametagConfig

local LocalPlayer = Players.LocalPlayer

--[[ CONSTANTS ]]
local GUI = {
	ScreenGui = "backpackui",
	Wrapper = "Frame",
	Panel = "Backpack",
	Content = "Content",
	Page = "NametagsPage",
	Shelf = "CrateWrapper",
}

local TEMPLATE_NAME = "skintemplate"
local ENTRY_PREFIX = "Nametag_"

local IMAGE_NAME = "skinimg"
local NAME_NAME = "skinname"
local TYPE_NAME = "skinunit"
local BUTTON_NAME = "EquipButton"
local STROKE_NAME = "EquippedStroke"

local TYPE_TEXT = "NAMETAG"
local LOCKED_COLOR = Color3.fromRGB(110, 110, 120)
local WAIT_TIMEOUT = 10
local REQUEST_COOLDOWN = 0.3
local CLICK_SOUND = "CardFlip"
local LAYOUT_OFFSET = 4000
local STATS_KEY = "Stats"

local ENTRIES_PER_ROW = 3
local ENTRY_PADDING_SCALE = 0.1
local ROW_GAP_SCALE = 0.12

--[=[
	The live preview on each card: the local player's name in the nametag's
	`Username` style and, when the nametag has a `Title`, that line above it in the
	`Title` style. Styling and gradient animation are `NametagController`'s, the same
	as on the real tag and in the Halloween shop.

	It covers the card's full width between `skinname` and `skinunit`, on one line,
	so `TextScaled` only shrinks it for long names. `skinimg` shows only a nametag's
	own `Icon`; without one it is hidden, so the template's placeholder never shows.
]=]
local PREVIEW = {
	Name = "Preview",
	Font = Font.new("rbxasset://fonts/families/PressStart2P.json", Enum.FontWeight.Bold),
	StrokeColor = Color3.fromRGB(8, 14, 18),
	StrokeThickness = 2,
	MaxTextSize = 40,
	LockedTransparency = 0.6,
	ZIndex = 4,

	-- { X, Y, Width, Height } in scale of the card.
	NameOnly = { 0.03, 0.26, 0.94, 0.3 },
	TitleLine = { 0.03, 0.21, 0.94, 0.2 },
	NameUnderTitle = { 0.03, 0.42, 0.94, 0.2 },
}

--[=[
	The backpack's Nametags tab (`backpackui...Content.NametagsPage.CrateWrapper`),
	cloned from that page's `skintemplate` and laid out from the top of the page. The
	page's scroll height is `BackpackTabController`'s.

	A card shows for every nametag that is available (free, owned, or level reached)
	and for every level nametag not reached yet. Those are locked: greyed, the button
	reads the level they need, and clicking does nothing. They unlock on their own when
	`Stats` changes in the replica.

	Each card previews the nametag (see `PREVIEW`), animated like the real tag.

	Clicking an available card or its `EquipButton` asks `NametagService` to equip or
	unequip. The equipped look reads the attributes authored on `EquipButton`, exactly
	like `SkinController`, so both tabs restyle together in Studio. With nothing
	equipped the default nametag shows as equipped and ignores unequip.
]=]
local NametagBackpackController = {
	Controllers = {
		DataController = {},
		MusicController = {},
		NametagController = {},
	},
}

--[[ INTERNAL ]]

local function placeOnGrid(entry : GuiObject, index : number)
	local column = (index - 1) % ENTRIES_PER_ROW
	local row = (index - 1) // ENTRIES_PER_ROW

	entry.Position = UDim2.fromScale(column * (1 + ENTRY_PADDING_SCALE), row * (1 + ROW_GAP_SCALE))
end

local function makePreviewLabel(name : string, parent : GuiObject, rect : { number }) : TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.FontFace = PREVIEW.Font
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.TextWrapped = false
	label.ZIndex = PREVIEW.ZIndex
	label.Position = UDim2.fromScale(rect[1], rect[2])
	label.Size = UDim2.fromScale(rect[3], rect[4])

	local stroke = Instance.new("UIStroke")
	stroke.Color = PREVIEW.StrokeColor
	stroke.Thickness = PREVIEW.StrokeThickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label

	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = PREVIEW.MaxTextSize
	limit.Parent = label

	label.Parent = parent
	return label
end

function NametagBackpackController:_data()
	local replica = self.Replica
	return replica and replica.Data
end

function NametagBackpackController:_level() : number
	return NametagConfig.LevelOf(self:_data())
end

function NametagBackpackController:_nametags()
	local data = self:_data()
	return NametagConfig.sanitize(data and data[NametagConfig.PROFILE_KEY], NametagConfig.LevelOf(data))
end

function NametagBackpackController:_equippedId(nametags) : string
	return nametags.Equipped or NametagConfig.DEFAULT
end

function NametagBackpackController:_style(label : TextLabel, style : any)
	local nametags = self.Controllers.NametagController
	if nametags and nametags._applyStyle and typeof(style) == "table" then
		nametags:_applyStyle(label, style)
	end
end

--[=[
	Draws the preview on the card: the Title line (if any) and the player's name,
	each in its own style. Returns the labels so the locked state can fade them.
]=]
function NametagBackpackController:_buildPreview(frame : GuiObject, nametag) : { TextLabel }
	local existing = frame:FindFirstChild(PREVIEW.Name)
	if existing then
		existing:Destroy()
	end

	local holder = Instance.new("Frame")
	holder.Name = PREVIEW.Name
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = PREVIEW.ZIndex
	holder.Parent = frame

	local style = nametag.Style or {}
	local title = NametagConfig.nonEmpty(nametag.Title)
	local labels = {}

	if title then
		local titleLabel = makePreviewLabel("Title", holder, PREVIEW.TitleLine)
		titleLabel.Text = string.upper(title)
		self:_style(titleLabel, style.Title)
		table.insert(labels, titleLabel)
	end

	local nameLabel = makePreviewLabel("Username", holder, if title then PREVIEW.NameUnderTitle else PREVIEW.NameOnly)
	nameLabel.Text = LocalPlayer.DisplayName
	self:_style(nameLabel, style.Username)
	table.insert(labels, nameLabel)

	return labels
end

function NametagBackpackController:_readLook(template : GuiObject)
	local button = template:FindFirstChild(BUTTON_NAME)
	local label = button and button:FindFirstChildWhichIsA("TextLabel")
	local stroke = label and label:FindFirstChildOfClass("UIStroke")

	local function attribute(name : string, fallback : any)
		local value = button and button:GetAttribute(name)
		return if value ~= nil then value else fallback
	end

	self.Look = {
		EquipText = attribute("EquipText", "Equip"),
		UnequipText = attribute("UnequipText", "Unequip"),
		EquipColor = attribute("EquipColor", button and button:IsA("ImageButton") and button.ImageColor3 or Color3.new(1, 1, 1)),
		UnequipColor = attribute("UnequipColor", Color3.fromRGB(255, 84, 84)),
		EquipStrokeColor = attribute("EquipStrokeColor", stroke and stroke.Color or Color3.new()),
		UnequipStrokeColor = attribute("UnequipStrokeColor", stroke and stroke.Color or Color3.new()),
	}
end

function NametagBackpackController:_applyState(entry, state : string)
	local look = self.Look
	if not look then
		return
	end

	entry.State = state

	local equipped = state == "Equipped"
	local locked = state == "Locked"

	local button = entry.Button
	if button and button:IsA("ImageButton") then
		button.ImageColor3 = if locked then LOCKED_COLOR elseif equipped then look.UnequipColor else look.EquipColor
	end

	if entry.Label then
		if locked then
			entry.Label.Text = string.format(NametagConfig.LOCKED_FORMAT, NametagConfig.UnlockLevelOf(entry.Id) or 0)
		else
			entry.Label.Text = if equipped then look.UnequipText else look.EquipText
		end

		local stroke = entry.Label:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if equipped then look.UnequipStrokeColor else look.EquipStrokeColor
		end
	end

	if entry.Stroke then
		entry.Stroke.Enabled = equipped
	end

	local fade = if locked then PREVIEW.LockedTransparency else 0
	for _, label in entry.Preview do
		label.TextTransparency = fade

		local stroke = label:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = fade
		end
	end
end

function NametagBackpackController:_createEntry(id : string)
	local nametag = NametagConfig.Get(id)
	local template = self.Template
	local wrapper = self.Wrapper

	if not nametag or not template or not wrapper then
		return nil
	end

	local frame = template:Clone()
	frame.Name = ENTRY_PREFIX .. id
	frame.Visible = true

	local nameLabel = frame:FindFirstChild(NAME_NAME)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = string.upper(nametag.DisplayName or id)
	end

	local typeLabel = frame:FindFirstChild(TYPE_NAME)
	if typeLabel and typeLabel:IsA("TextLabel") then
		typeLabel.Text = if NametagConfig.nonEmpty(nametag.Title) then string.upper(nametag.Title) else TYPE_TEXT
	end

	local image = frame:FindFirstChild(IMAGE_NAME)
	if image and image:IsA("ImageLabel") then
		local art = NametagConfig.nonEmpty(nametag.Icon)
		image.Visible = art ~= nil
		if art then
			image.Image = art
		end
	end

	local preview = self:_buildPreview(frame, nametag)

	local button = frame:FindFirstChild(BUTTON_NAME)
	local stroke = frame:FindFirstChild(STROKE_NAME)

	local entry = {
		Id = id,
		Frame = frame,
		Button = button,
		Label = button and button:FindFirstChildWhichIsA("TextLabel"),
		Stroke = if stroke and stroke:IsA("UIStroke") then stroke else nil,
		Preview = preview,
		State = "Available",
		Maid = Maid.new(),
	}

	entry.Maid:GiveTask(frame)

	if frame:IsA("GuiButton") then
		entry.Maid:GiveTask(frame.Activated:Connect(function()
			self:Toggle(id)
		end))
	end

	if button and button:IsA("GuiButton") then
		entry.Maid:GiveTask(button.Activated:Connect(function()
			self:Toggle(id)
		end))
	end

	frame.Parent = wrapper

	return entry
end

function NametagBackpackController:_layout()
	local wrapper = self.Wrapper
	if not wrapper or not wrapper.Parent then
		return
	end

	local hasLayout = wrapper:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil

	for index, id in self.Order do
		local entry = self.Entries[id]
		if entry then
			entry.Frame.LayoutOrder = LAYOUT_OFFSET + index

			if not hasLayout then
				placeOnGrid(entry.Frame, index)
			end
		end
	end
end

function NametagBackpackController:_scheduleLayout()
	if self.LayoutQueued then
		return
	end

	self.LayoutQueued = true
	task.defer(function()
		self.LayoutQueued = false
		self:_layout()
	end)
end

function NametagBackpackController:_render()
	if not self.Wrapper or not self.Template then
		return
	end

	local nametags = self:_nametags()
	local level = self:_level()
	local equippedId = self:_equippedId(nametags)
	local order = {}
	local states = {}

	for _, id in NametagConfig.ordered() do
		if NametagConfig.IsAvailable(id, nametags.Owned, level) then
			table.insert(order, id)
			states[id] = if equippedId == id then "Equipped" else "Available"
		elseif NametagConfig.UnlockLevelOf(id) then
			table.insert(order, id)
			states[id] = "Locked"
		end
	end

	for id, entry in self.Entries do
		if not states[id] then
			entry.Maid:DoCleaning()
			self.Entries[id] = nil
		end
	end

	for _, id in order do
		local entry = self.Entries[id]
		if not entry then
			entry = self:_createEntry(id)
			if not entry then
				continue
			end
			self.Entries[id] = entry
		end

		self:_applyState(entry, states[id])
	end

	self.Order = order
	self:_scheduleLayout()
end

function NametagBackpackController:_clearEntries()
	for _, entry in self.Entries do
		entry.Maid:DoCleaning()
	end

	self.Entries = {}
	self.Order = {}
end

function NametagBackpackController:_bindUI(screenGui : ScreenGui)
	self.UIMaid:DoCleaning()
	self:_clearEntries()
	self.Wrapper = nil
	self.Template = nil

	local frame = screenGui:WaitForChild(GUI.Wrapper, WAIT_TIMEOUT)
	local panel = frame and frame:WaitForChild(GUI.Panel, WAIT_TIMEOUT)
	local content = panel and panel:WaitForChild(GUI.Content, WAIT_TIMEOUT)
	local page = content and content:WaitForChild(GUI.Page, WAIT_TIMEOUT)
	local wrapper = page and page:WaitForChild(GUI.Shelf, WAIT_TIMEOUT)
	local template = wrapper and wrapper:WaitForChild(TEMPLATE_NAME, WAIT_TIMEOUT)

	if not template or not template:IsA("GuiObject") then
		log:StudioWarn(`could not find {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.Content}.{GUI.Page}.{GUI.Shelf}.{TEMPLATE_NAME}`)
		return
	end

	template.Visible = false

	self.Wrapper = wrapper
	self.Template = template
	self:_readLook(template)

	self:_render()
end

function NametagBackpackController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == GUI.ScreenGui then
			self:_bindUI(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	local existing = playerGui:FindFirstChild(GUI.ScreenGui)
	if existing then
		task.spawn(onChild, existing)
	end
end

function NametagBackpackController:_watchData()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= NametagConfig.PROFILE_KEY and key ~= STATS_KEY then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

function NametagBackpackController:Toggle(id : string)
	if not NametagConfig.Get(id) then
		return
	end

	local now = os.clock()
	if now - self.LastRequest < REQUEST_COOLDOWN then
		return
	end

	local nametags = self:_nametags()
	if not NametagConfig.IsAvailable(id, nametags.Owned, self:_level()) then
		return
	end

	local equipped = self:_equippedId(nametags) == id
	if equipped and id == NametagConfig.DEFAULT then
		return
	end

	self.LastRequest = now

	if equipped then
		Framework:Fire("RequestUnequipNametag", id)
	else
		Framework:Fire("RequestEquipNametag", id)
	end

	local music = self.Controllers.MusicController
	if music and music.PlaySFX then
		music:PlaySFX(CLICK_SOUND)
	end
end

function NametagBackpackController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()
	self:_watchData()
end

function NametagBackpackController:init()
	self.Maid = Maid.new()
	self.UIMaid = Maid.new()
	self.Maid:GiveTask(self.UIMaid)
	self.Maid:GiveTask(function()
		self:_clearEntries()
	end)

	self.Entries = {}
	self.Order = {}
	self.LayoutQueued = false
	self.LastRequest = 0
	self.Look = nil
end

return NametagBackpackController