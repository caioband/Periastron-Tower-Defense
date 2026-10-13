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
local log = Log.new("SkinController")

local SkinConfig = SharedConfig.SkinConfig
local CardConfig = SharedConfig.CardConfig

--[[ CONSTANTS ]]
local GUI = {
	ScreenGui = "backpackui",
	Wrapper = "Frame",
	Panel = "Backpack",
	Content = "Content",
	Page = "SkinsPage",
	Shelf = "CrateWrapper",
}

local TEMPLATE_NAME = "skintemplate"
local ENTRY_PREFIX = "Skin_"

local IMAGE_NAME = "skinimg"
local NAME_NAME = "skinname"
local UNIT_NAME = "skinunit"
local BUTTON_NAME = "EquipButton"
local STROKE_NAME = "EquippedStroke"

local WAIT_TIMEOUT = 10
local REQUEST_COOLDOWN = 0.3
local CLICK_SOUND = "CardFlip"
local LAYOUT_OFFSET = 3000

local ENTRIES_PER_ROW = 3
local ENTRY_PADDING_SCALE = 0.1
local ROW_GAP_SCALE = 0.12

--[=[
	The backpack's Skins tab (`backpackui...Content.SkinsPage.CrateWrapper`), one card
	per owned skin, cloned from the authored `skintemplate` and laid out from the top
	of the page.

	Clicking the card or its `EquipButton` asks `SkinService` to equip or unequip it.
	The equipped look (button text, colours, `EquippedStroke`) reads the attributes
	authored on `EquipButton`, so it is restyled in Studio, not here. Nothing here
	decides ownership: it reads the replica's `Skins`.
]=]
local SkinController = {
	Controllers = {
		DataController = {},
		MusicController = {},
	},
}

--[[ INTERNAL ]]

local function placeOnGrid(entry : GuiObject, index : number)
	local column = (index - 1) % ENTRIES_PER_ROW
	local row = (index - 1) // ENTRIES_PER_ROW

	entry.Position = UDim2.fromScale(column * (1 + ENTRY_PADDING_SCALE), row * (1 + ROW_GAP_SCALE))
end

function SkinController:_skins()
	local replica = self.Replica
	local data = replica and replica.Data

	return SkinConfig.sanitize(data and data[SkinConfig.PROFILE_KEY])
end

function SkinController:_readLook(template : GuiObject)
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

function SkinController:_applyState(entry, equipped : boolean)
	local look = self.Look
	if not look then
		return
	end

	entry.Equipped = equipped

	local button = entry.Button
	if button and button:IsA("ImageButton") then
		button.ImageColor3 = if equipped then look.UnequipColor else look.EquipColor
	end

	if entry.Label then
		entry.Label.Text = if equipped then look.UnequipText else look.EquipText

		local stroke = entry.Label:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if equipped then look.UnequipStrokeColor else look.EquipStrokeColor
		end
	end

	if entry.Stroke then
		entry.Stroke.Enabled = equipped
	end
end

function SkinController:_createEntry(id : string)
	local skin = SkinConfig.Get(id)
	local template = self.Template
	local wrapper = self.Wrapper

	if not skin or not template or not wrapper then
		return nil
	end

	local frame = template:Clone()
	frame.Name = ENTRY_PREFIX .. id
	frame.Visible = true

	local nameLabel = frame:FindFirstChild(NAME_NAME)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = string.upper(skin.DisplayName or id)
	end

	local unitLabel = frame:FindFirstChild(UNIT_NAME)
	if unitLabel and unitLabel:IsA("TextLabel") then
		unitLabel.Text = `{string.upper(skin.Unit)} SKIN`
	end

	local image = frame:FindFirstChild(IMAGE_NAME)
	local art = SkinConfig.nonEmpty(skin.Image) or CardConfig.Icons[skin.Unit]
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
		Equipped = false,
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

function SkinController:_layout()
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

function SkinController:_scheduleLayout()
	if self.LayoutQueued then
		return
	end

	self.LayoutQueued = true
	task.defer(function()
		self.LayoutQueued = false
		self:_layout()
	end)
end

function SkinController:_render()
	if not self.Wrapper or not self.Template then
		return
	end

	local skins = self:_skins()
	local order = {}
	local wanted = {}

	for _, id in SkinConfig.ordered() do
		if skins.Owned[id] then
			table.insert(order, id)
			wanted[id] = true
		end
	end

	for id, entry in self.Entries do
		if not wanted[id] then
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

		local skin = SkinConfig.Get(id)
		self:_applyState(entry, skin ~= nil and skins.Equipped[skin.Unit] == id)
	end

	self.Order = order
	self:_scheduleLayout()
end

function SkinController:_clearEntries()
	for _, entry in self.Entries do
		entry.Maid:DoCleaning()
	end

	self.Entries = {}
	self.Order = {}
end

function SkinController:_bindUI(screenGui : ScreenGui)
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

function SkinController:_observeUI()
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

function SkinController:_watchData()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= SkinConfig.PROFILE_KEY then
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

function SkinController:Toggle(id : string)
	local skin = SkinConfig.Get(id)
	if not skin then
		return
	end

	local now = os.clock()
	if now - self.LastRequest < REQUEST_COOLDOWN then
		return
	end
	self.LastRequest = now

	local skins = self:_skins()
	if not skins.Owned[id] then
		return
	end

	if skins.Equipped[skin.Unit] == id then
		Framework:Fire("RequestUnequipSkin", id)
	else
		Framework:Fire("RequestEquipSkin", id)
	end

	local music = self.Controllers.MusicController
	if music and music.PlaySFX then
		music:PlaySFX(CLICK_SOUND)
	end
end

function SkinController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	Framework:Listen("SkinResult", function(id, action, ok, reason)
		if not ok then
			log:StudioWarn(`skin {tostring(action)} refused for {tostring(id)}: {tostring(reason)}`)
		end
	end)

	self:_observeUI()
	self:_watchData()
end

function SkinController:init()
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

return SkinController