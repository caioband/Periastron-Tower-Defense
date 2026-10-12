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

--[[ CONSTANTS ]]
local CRATE_UI_NAME = "crateui"
local TEMPLATE_NAME = "skintemplate"
local ENTRY_PREFIX = "Nametag_"
local CRATE_PREFIX = "Crate_"
local RUNE_PREFIX = "Rune_"
local SKIN_PREFIX = "Skin_"

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

local ENTRIES_PER_ROW = 5
local ENTRY_PADDING_SCALE = 0.1
local ROW_GAP_SCALE = 0.12

local BASE_SIZE_ATTRIBUTE = "AuthoredSize"
local BASE_CANVAS_ATTRIBUTE = "AuthoredCanvasSize"
local BOTTOM_PADDING = 0.25

--[=[
	The nametags on the Backpack shelf (`crateui...CrateWrapper`), cloned from the same
	`skintemplate` the skins use.

	A card shows for every nametag that is available (free, owned, or level reached)
	and for every level nametag not reached yet. Those are locked: greyed, the button
	reads the level they need, and clicking does nothing. They unlock on their own when
	`Stats` changes in the replica.

	Clicking an available card or its `EquipButton` asks `NametagService` to equip or
	unequip. The equipped look reads the attributes authored on `EquipButton`, exactly
	like `SkinController`, so both shelves restyle together in Studio.

	Cards sit on the grid after crates, runes and skins. With nothing equipped the
	default nametag shows as equipped and ignores unequip.

	**Canvas.** `CrateWrapper` is authored as a fraction of `scrollcrates`' canvas and
	every card is placed in multiples of it, so growing the canvas grew the cards and
	extra rows never fitted. Being last on the shelf, this controller owns the fit:
	each layout pass pins `CrateWrapper` to the pixel size its authored scale gives at
	the authored canvas (so cards look the same and still follow the screen), then
	sizes the canvas to the lowest visible card plus `BOTTOM_PADDING` card heights,
	never shorter than authored. Sizes are read without the open animation's `UIScale`.
	The authored values are kept as attributes so a rebind never compounds them.
]=]
local NametagBackpackController = {
	Controllers = {
		DataController = {},
		MusicController = {},
	},
}

--[[ INTERNAL ]]

local function placeOnGrid(entry : GuiObject, index : number, firstRow : number)
	local column = (index - 1) % ENTRIES_PER_ROW
	local row = firstRow + (index - 1) // ENTRIES_PER_ROW

	entry.Position = UDim2.fromScale(column * (1 + ENTRY_PADDING_SCALE), row * (1 + ROW_GAP_SCALE))
end

local function hasPrefix(name : string, prefix : string) : boolean
	return string.sub(name, 1, #prefix) == prefix
end

local function readAuthored(instance : Instance, property : string, attribute : string) : UDim2
	local saved = instance:GetAttribute(attribute)
	if typeof(saved) == "UDim2" then
		return saved
	end

	local value = (instance :: any)[property] :: UDim2
	instance:SetAttribute(attribute, value)
	return value
end

local function cumulativeScale(gui : Instance) : number
	local scale = 1
	local current = gui

	while current and not current:IsA("LayerCollector") do
		local uiScale = current:FindFirstChildOfClass("UIScale")
		if uiScale then
			scale *= uiScale.Scale
		end
		current = current.Parent
	end

	return scale
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
	local art = NametagConfig.nonEmpty(nametag.Icon)
	if image and image:IsA("ImageLabel") and art then
		image.Image = art
	end

	local button = frame:FindFirstChild(BUTTON_NAME)
	local stroke = frame:FindFirstChild(STROKE_NAME)

	local entry = {
		Id = id,
		Frame = frame,
		Button = button,
		Label = button and button:FindFirstChildWhichIsA("TextLabel"),
		Stroke = if stroke and stroke:IsA("UIStroke") then stroke else nil,
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

function NametagBackpackController:_fitCanvas()
	local scroll = self.Scroll
	local wrapper = self.Wrapper
	if not scroll or not wrapper or not scroll.Parent or not wrapper.Parent then
		return
	end

	local scale = cumulativeScale(scroll)
	if scale < 0.01 then
		return
	end

	local window = scroll.AbsoluteSize / scale
	if window.X <= 0 or window.Y <= 0 then
		return
	end

	local baseSize = self.BaseWrapperSize
	local baseCanvas = self.BaseCanvas

	local canvasWidth = math.max(baseCanvas.X.Scale * window.X + baseCanvas.X.Offset, window.X)
	local authoredHeight = baseCanvas.Y.Scale * window.Y + baseCanvas.Y.Offset

	local wrapperWidth = math.floor(baseSize.X.Scale * canvasWidth + baseSize.X.Offset + 0.5)
	local wrapperHeight = math.floor(baseSize.Y.Scale * authoredHeight + baseSize.Y.Offset + 0.5)
	if wrapperWidth <= 0 or wrapperHeight <= 0 then
		return
	end

	local pinned = UDim2.fromOffset(wrapperWidth, wrapperHeight)
	if wrapper.Size ~= pinned then
		wrapper.Size = pinned
	end

	local bottom = 0
	for _, child in wrapper:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			local height = child.Size.Y.Scale * wrapperHeight + child.Size.Y.Offset
			local top = child.Position.Y.Scale * wrapperHeight + child.Position.Y.Offset - child.AnchorPoint.Y * height
			bottom = math.max(bottom, top + height)
		end
	end

	local wrapperTop = wrapper.AbsolutePosition.Y / scale - scroll.AbsolutePosition.Y / scale + scroll.CanvasPosition.Y
	local needed = math.ceil(math.max(authoredHeight, wrapperTop + bottom + wrapperHeight * BOTTOM_PADDING))

	local canvas = UDim2.new(baseCanvas.X.Scale, baseCanvas.X.Offset, 0, needed)
	if scroll.CanvasSize ~= canvas then
		scroll.CanvasSize = canvas
	end
end

function NametagBackpackController:_layout()
	local wrapper = self.Wrapper
	if not wrapper or not wrapper.Parent then
		return
	end

	local hasLayout = wrapper:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
	local crates, runes, skins = 0, 0, 0

	for _, child in wrapper:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			local name = child.Name
			if hasPrefix(name, CRATE_PREFIX) then
				crates += 1
			elseif hasPrefix(name, RUNE_PREFIX) then
				runes += 1
			elseif hasPrefix(name, SKIN_PREFIX) then
				skins += 1
			end
		end
	end

	local firstRow = math.ceil(crates / ENTRIES_PER_ROW)
		+ math.ceil(runes / ENTRIES_PER_ROW)
		+ math.ceil(skins / ENTRIES_PER_ROW)

	for index, id in self.Order do
		local entry = self.Entries[id]
		if entry then
			entry.Frame.LayoutOrder = LAYOUT_OFFSET + index

			if not hasLayout then
				placeOnGrid(entry.Frame, index, firstRow)
			end
		end
	end

	self:_fitCanvas()
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
	self.Scroll = nil

	local frame = screenGui:WaitForChild("Frame", WAIT_TIMEOUT)
	local rectangle = frame and frame:WaitForChild("Rectangle", WAIT_TIMEOUT)
	local scroll = rectangle and rectangle:WaitForChild("scrollcrates", WAIT_TIMEOUT)
	local wrapper = scroll and scroll:WaitForChild("CrateWrapper", WAIT_TIMEOUT)
	local template = wrapper and wrapper:WaitForChild(TEMPLATE_NAME, WAIT_TIMEOUT)

	if not template or not template:IsA("GuiObject") or not scroll:IsA("ScrollingFrame") then
		log:StudioWarn(`could not find {CRATE_UI_NAME}.Frame.Rectangle.scrollcrates.CrateWrapper.{TEMPLATE_NAME}`)
		return
	end

	self.Wrapper = wrapper
	self.Template = template
	self.Scroll = scroll
	self.BaseWrapperSize = readAuthored(wrapper, "Size", BASE_SIZE_ATTRIBUTE)
	self.BaseCanvas = readAuthored(scroll, "CanvasSize", BASE_CANVAS_ATTRIBUTE)
	self:_readLook(template)

	local function watch(child : Instance)
		if not child:IsA("GuiObject") then
			return
		end

		local name = child.Name
		if hasPrefix(name, CRATE_PREFIX) or hasPrefix(name, RUNE_PREFIX) or hasPrefix(name, SKIN_PREFIX) then
			self.UIMaid:GiveTask(child:GetPropertyChangedSignal("Visible"):Connect(function()
				self:_scheduleLayout()
			end))

			self.UIMaid:GiveTask(child:GetPropertyChangedSignal("Position"):Connect(function()
				self:_scheduleLayout()
			end))
		end
	end

	self.UIMaid:GiveTask(wrapper.ChildAdded:Connect(function(child)
		watch(child)
		self:_scheduleLayout()
	end))

	self.UIMaid:GiveTask(wrapper.ChildRemoved:Connect(function()
		self:_scheduleLayout()
	end))

	self.UIMaid:GiveTask(scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_scheduleLayout()
	end))

	for _, child in wrapper:GetChildren() do
		watch(child)
	end

	self:_render()
end

function NametagBackpackController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == CRATE_UI_NAME then
			self:_bindUI(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	local existing = playerGui:FindFirstChild(CRATE_UI_NAME)
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
	self.Scroll = nil
	self.BaseWrapperSize = UDim2.new()
	self.BaseCanvas = UDim2.new()
end

return NametagBackpackController