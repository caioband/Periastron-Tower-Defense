local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ClassConfig = SharedConfig.ClassConfig
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))
local Me = require(Vendor.Me)

local Framework = Me.new()

local FRAME_NAME = "BardModes"
local SONG_NAME = "BardSong"
local BADGE_NAME = "BardBuffBadge"
local ICON_WIDTH = 0.169157788
local ICON_HEIGHT = 0.136593476
local ICON_GAP = 0.02
local ACTIVE_COLOR = Color3.fromRGB(255, 255, 255)
local INACTIVE_COLOR = Color3.fromRGB(110, 110, 110)
local BUFF_COLOR = Color3.fromRGB(255, 255, 255)
local ACTIVE_SCALE = 1.1
local SYNC_INTERVAL = 0.25
local DEFAULT_SONG_FADE = 0.4
local BADGE_MAX_DISTANCE = 150
local BADGE_GROUP_WIDTH = 86
local BADGE_HEIGHT = 30
local PIXEL_FONT = Font.new("rbxasset://fonts/families/PressStart2P.json")

local STAT_ORDER = { "Damage", "Range", "AttackSpeed" }

local STAT_LABELS = {
	Damage = "DamagePerSecond",
	AttackSpeed = "AttackSpeed",
	Range = "Range",
}

local function supportOf(unitName : string?)
	local stats = unitName and SharedConfig.UnitStats[unitName]
	return stats and stats.Support
end

local function findRootPart(model : Model) : BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	if model.PrimaryPart then
		return model.PrimaryPart
	end

	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function formatPercent(value : number) : string
	local text = string.format("%.1f", value * 100)
	text = text:gsub("%.0$", "")
	return text
end

local BardController = {
	States = {},
	Buffs = {},
	Badges = {},
	Buttons = {},
	Songs = {},
	SeenSongs = {},
	SeenBadges = {},
	LabelColors = {},
	BuiltFor = nil,
	Frame = nil,
	ToggleTower = nil,
	Silenced = false,
	SyncClock = 0,
}

--[[ STATE ]]

function BardController:GetMode(unitId : string?, unitName : string?) : string?
	local state = unitId and self.States[unitId]
	local support = supportOf(unitName)

	if state and (not support or support.Modes[state.Mode]) then
		return state.Mode
	end

	return support and support.Default or nil
end

function BardController:GetCooldownLeft(unitId : string?) : number
	local state = unitId and self.States[unitId]
	if not state then return 0 end

	return math.max(0, state.ReadyAt - GameClock.Now())
end

function BardController:GetBuffs(unitId : string?)
	return unitId and self.Buffs[unitId] or nil
end

function BardController:GetBuffMultiplier(unitId : string?, stat : string) : number
	local buffs = self:GetBuffs(unitId)
	if not buffs then
		return 1
	end

	local total = 1

	for _, buff in buffs do
		if buff.Stat == stat then
			total += buff.Boost or 0
		end
	end

	return total
end

function BardController:IsStatBuffed(unitId : string?, stat : string) : boolean
	return self:GetBuffMultiplier(unitId, stat) > 1
end

function BardController:groupBuffs(buffs)
	local byStat = {}

	for _, buff in buffs do
		local group = byStat[buff.Stat]

		if group then
			group.Boost += buff.Boost or 0
			group.Capped = group.Capped or buff.Capped == true
		else
			byStat[buff.Stat] = {
				Stat = buff.Stat,
				Boost = buff.Boost or 0,
				Icon = buff.Icon,
				Capped = buff.Capped == true,
			}
		end
	end

	local groups = {}

	for _, stat in STAT_ORDER do
		if byStat[stat] then
			table.insert(groups, byStat[stat])
		end
	end

	return groups
end

--[[ LOOKUPS ]]

function BardController:getToggleTower()
	if self.ToggleTower then
		return self.ToggleTower
	end

	local library = script.Parent:FindFirstChild("UILibraryController")
	local components = library and library:FindFirstChild("Components")
	local module = components and components:FindFirstChild("ToggleTower")

	if module then
		self.ToggleTower = require(module)
	end

	return self.ToggleTower
end

function BardController:getCard() : GuiObject?
	local playerGui = Player:FindFirstChild("PlayerGui")
	local interface = playerGui and playerGui:FindFirstChild("Interface")
	local card = interface and interface:FindFirstChild("CardUpgrade")

	return card and card:IsA("GuiObject") and card or nil
end

function BardController:getSFXVolume() : number
	local music = Framework:Get("MusicController", false, false)
	if music and music.GetSFXVolume then
		return music:GetSFXVolume() or 1
	end

	return 1
end

function BardController:getClasses()
	local placement = Framework:Get("UnitPlacementController", false, false)
	return placement and placement.createdClasses, placement
end

--[[ SONGS ]]

function BardController:stopSong(unitId : string, fade : number?)
	local record = self.Songs[unitId]
	self.Songs[unitId] = nil

	local sound = record and record.Sound
	if not sound or not sound.Parent then return end

	local duration = fade or DEFAULT_SONG_FADE
	if duration <= 0 then
		sound:Destroy()
		return
	end

	local tween = TweenService:Create(sound, TweenInfo.new(duration), { Volume = 0 })
	tween.Completed:Connect(function()
		sound:Destroy()
	end)
	tween:Play()
end

function BardController:stopAllSongs(fade : number?)
	for unitId in self.Songs do
		self:stopSong(unitId, fade)
	end
end

function BardController:startSong(unitId : string, model : Model, support, mode : string)
	local modeConfig = support.Modes[mode]
	local song = modeConfig and modeConfig.Song
	local parent = findRootPart(model)

	local record = { Mode = mode, Model = model, Sound = nil }
	self.Songs[unitId] = record

	if not song or not song.SoundId or song.SoundId == "" or song.SoundId == "rbxassetid://0" then return end
	if not parent then return end

	local sound = Instance.new("Sound")
	sound.Name = SONG_NAME
	sound.SoundId = song.SoundId
	sound.Looped = true
	sound.PlaybackSpeed = song.PlaybackSpeed or 1
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = song.RollOffMinDistance or 10
	sound.RollOffMaxDistance = song.RollOffMaxDistance or 80
	sound.Volume = 0
	sound.Parent = parent
	sound:Play()

	local target = (song.Volume or 0.5) * self:getSFXVolume()
	local fade = support.SongFade or DEFAULT_SONG_FADE

	if fade > 0 then
		TweenService:Create(sound, TweenInfo.new(fade), { Volume = target }):Play()
	else
		sound.Volume = target
	end

	record.Sound = sound
end

function BardController:syncSongs()
	local classes = self:getClasses()
	local seen = self.SeenSongs
	table.clear(seen)

	if classes and not self.Silenced then
		for model, class in classes do
			if not model or not model.Parent or not class then continue end

			local support = supportOf(model.Name)
			if not support then continue end

			local unitId = class.unitId
			if not unitId then continue end

			seen[unitId] = true

			local mode = self:GetMode(unitId, model.Name)
			if not mode then continue end

			local record = self.Songs[unitId]
			local soundAlive = record and (record.Sound == nil or record.Sound.Parent ~= nil)

			if record and soundAlive and record.Mode == mode and record.Model == model then
				continue
			end

			if record then
				self:stopSong(unitId, support.SongFade)
			end

			self:startSong(unitId, model, support, mode)
		end
	end

	for unitId in self.Songs do
		if not seen[unitId] then
			self:stopSong(unitId)
		end
	end
end

--[[ BUFF BADGES ]]

function BardController:badgeKey(groups) : string
	local parts = {}

	for _, group in groups do
		table.insert(parts, tostring(group.Stat) .. ":" .. tostring(group.Boost) .. ":" .. tostring(group.Icon) .. ":" .. tostring(group.Capped))
	end

	return table.concat(parts, "|")
end

function BardController:removeBadge(unitId : string)
	local record = self.Badges[unitId]
	self.Badges[unitId] = nil

	if record and record.Gui then
		record.Gui:Destroy()
	end
end

function BardController:createBadge(unitId : string, model : Model, groups, key : string)
	local root = findRootPart(model)
	if not root then return end

	local anyCapped = false
	for _, group in groups do
		if group.Capped then
			anyCapped = true
			break
		end
	end

	local badgeHeight = if anyCapped then BADGE_HEIGHT + 14 else BADGE_HEIGHT
	local height = model:GetExtentsSize().Y * 0.5 + 1.25

	local gui = Instance.new("BillboardGui")
	gui.Name = BADGE_NAME
	gui.Size = UDim2.fromOffset(BADGE_GROUP_WIDTH * #groups, badgeHeight)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = BADGE_MAX_DISTANCE
	gui.ResetOnSpawn = false
	gui.Adornee = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = gui

	for index, group in groups do
		local column = Instance.new("Frame")
		column.Name = group.Stat
		column.LayoutOrder = index
		column.BackgroundTransparency = 1
		column.AutomaticSize = Enum.AutomaticSize.X
		column.Size = UDim2.fromOffset(0, badgeHeight)
		column.Parent = gui

		local stack = Instance.new("UIListLayout")
		stack.FillDirection = Enum.FillDirection.Vertical
		stack.HorizontalAlignment = Enum.HorizontalAlignment.Center
		stack.VerticalAlignment = Enum.VerticalAlignment.Bottom
		stack.Padding = UDim.new(0, 2)
		stack.SortOrder = Enum.SortOrder.LayoutOrder
		stack.Parent = column

		if group.Capped then
			local maxLabel = Instance.new("TextLabel")
			maxLabel.Name = "MaxStack"
			maxLabel.LayoutOrder = 1
			maxLabel.BackgroundTransparency = 1
			maxLabel.AutomaticSize = Enum.AutomaticSize.X
			maxLabel.Size = UDim2.fromOffset(0, 12)
			maxLabel.FontFace = PIXEL_FONT
			maxLabel.TextSize = 9
			maxLabel.TextColor3 = Color3.fromRGB(255, 215, 80)
			maxLabel.Text = "MAX STACK"
			maxLabel.Parent = column

			local maxStroke = Instance.new("UIStroke")
			maxStroke.Thickness = 1.5
			maxStroke.Color = Color3.fromRGB(0, 0, 0)
			maxStroke.Parent = maxLabel
		end

		local row = Instance.new("Frame")
		row.Name = "Row"
		row.LayoutOrder = 2
		row.BackgroundTransparency = 1
		row.AutomaticSize = Enum.AutomaticSize.X
		row.Size = UDim2.fromOffset(0, 24)
		row.Parent = column

		local inner = Instance.new("UIListLayout")
		inner.FillDirection = Enum.FillDirection.Horizontal
		inner.VerticalAlignment = Enum.VerticalAlignment.Center
		inner.Padding = UDim.new(0, 4)
		inner.SortOrder = Enum.SortOrder.LayoutOrder
		inner.Parent = row

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.LayoutOrder = 1
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromOffset(24, 24)
		icon.Image = ClassConfig.Icons[group.Icon or ""] or ""
		icon.Parent = row

		local label = Instance.new("TextLabel")
		label.Name = "Amount"
		label.LayoutOrder = 2
		label.BackgroundTransparency = 1
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromOffset(0, 24)
		label.FontFace = PIXEL_FONT
		label.TextSize = 14
		label.TextColor3 = BUFF_COLOR
		label.Text = "+" .. formatPercent(group.Boost) .. "%"
		label.Parent = row

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(0, 0, 0)
		stroke.Parent = label
	end

	gui.Parent = root

	self.Badges[unitId] = {
		Gui = gui,
		Model = model,
		Key = key,
	}
end

function BardController:syncBadges()
	local classes = self:getClasses()
	local seen = self.SeenBadges
	table.clear(seen)

	if classes then
		for model, class in classes do
			if not model or not model.Parent or not class then continue end

			local unitId = class.unitId
			local buffs = unitId and self.Buffs[unitId]
			if not buffs or #buffs == 0 then continue end

			seen[unitId] = true

			local groups = self:groupBuffs(buffs)
			local key = self:badgeKey(groups)
			local record = self.Badges[unitId]

			if record and record.Model == model and record.Key == key and record.Gui and record.Gui.Parent then
				continue
			end

			self:removeBadge(unitId)
			self:createBadge(unitId, model, groups, key)
		end
	end

	for unitId in self.Badges do
		if not seen[unitId] then
			self:removeBadge(unitId)
		end
	end
end

function BardController:clearBadges()
	for unitId in self.Badges do
		self:removeBadge(unitId)
	end
end

--[[ CARD ]]

function BardController:tintStatLabels(card : GuiObject?, unit : Model?)
	local unitId = unit and unit.Parent and unit:GetAttribute("UnitID") or nil
	local showing = card ~= nil and card.Visible

	for stat, labelName in STAT_LABELS do
		local label = card and card:FindFirstChild(labelName)
		if not label or not label:IsA("TextLabel") then continue end

		if self.LabelColors[label] == nil then
			self.LabelColors[label] = label.TextColor3
		end

		local buffed = showing and self:IsStatBuffed(unitId, stat)
		local target = if buffed then BUFF_COLOR else self.LabelColors[label]

		if label.TextColor3 ~= target then
			label.TextColor3 = target
		end
	end
end

function BardController:destroyButtons()
	if self.Frame then
		self.Frame:Destroy()
	end

	self.Frame = nil
	self.BuiltFor = nil
	table.clear(self.Buttons)
end

function BardController:requestMode(modeName : string)
	local toggle = self:getToggleTower()
	local unit = toggle and toggle.currentUnit
	if not unit or not unit.Parent then return end
	if unit:GetAttribute("Owned") ~= true then return end

	local support = supportOf(unit.Name)
	if not support or not support.Modes[modeName] then return end

	local unitId = unit:GetAttribute("UnitID")
	if not unitId then return end

	if self:GetMode(unitId, unit.Name) == modeName then return end
	if self:GetCooldownLeft(unitId) > 0 then return end

	Framework:Fire("SetBardMode", unitId, modeName)
end

function BardController:buildButtons(card : GuiObject, unitName : string, support)
	self:destroyButtons()

	local order = support.Order or {}
	local count = #order
	if count == 0 then return end

	local backgroundSource = card:FindFirstChild("ClassIconBackground")
	local backgroundImage = if backgroundSource and backgroundSource:IsA("ImageLabel") then backgroundSource.Image else ""

	local totalHeight = ICON_HEIGHT * count + ICON_GAP * (count - 1)

	local frame = Instance.new("Frame")
	frame.Name = FRAME_NAME
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.fromScale(-0.02, 0.04)
	frame.Size = UDim2.fromScale(ICON_WIDTH, totalHeight)
	frame.ZIndex = card.ZIndex + 1

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(ICON_GAP / totalHeight, 0)
	layout.Parent = frame

	for index, modeName in ipairs(order) do
		local modeConfig = support.Modes[modeName]
		if not modeConfig then continue end

		local button = Instance.new("ImageButton")
		button.Name = modeName
		button.LayoutOrder = index
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.Image = backgroundImage
		button.Size = UDim2.fromScale(1, ICON_HEIGHT / totalHeight)
		button.ZIndex = frame.ZIndex

		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1
		aspect.Parent = button

		local scale = Instance.new("UIScale")
		scale.Parent = button

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.8, 0.8)
		icon.Image = ClassConfig.Icons[modeConfig.Icon] or ""
		icon.ZIndex = button.ZIndex + 1
		icon.Parent = button

		local cooldown = Instance.new("TextLabel")
		cooldown.Name = "Cooldown"
		cooldown.BackgroundTransparency = 1
		cooldown.AnchorPoint = Vector2.new(0.5, 0.5)
		cooldown.Position = UDim2.fromScale(0.5, 0.5)
		cooldown.Size = UDim2.fromScale(0.8, 0.6)
		cooldown.FontFace = PIXEL_FONT
		cooldown.TextScaled = true
		cooldown.TextColor3 = Color3.fromRGB(255, 255, 255)
		cooldown.Text = ""
		cooldown.Visible = false
		cooldown.ZIndex = button.ZIndex + 2
		cooldown.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(0, 0, 0)
		stroke.Parent = cooldown

		button.Activated:Connect(function()
			self:requestMode(modeName)
		end)

		button.Parent = frame

		self.Buttons[modeName] = {
			Button = button,
			Icon = icon,
			Scale = scale,
			Cooldown = cooldown,
		}
	end

	frame.Parent = card

	self.Frame = frame
	self.BuiltFor = unitName
end

function BardController:stepCard()
	local toggle = self:getToggleTower()
	local card = self:getCard()
	local unit = toggle and toggle.currentUnit

	self:tintStatLabels(card, unit)

	local support = unit and unit.Parent and supportOf(unit.Name)

	if not (card and card.Visible and support) then
		if self.Frame then
			self.Frame.Visible = false
		end
		return
	end

	if not self.Frame or self.Frame.Parent ~= card or self.BuiltFor ~= unit.Name then
		self:buildButtons(card, unit.Name, support)
	end

	if not self.Frame then return end
	self.Frame.Visible = true

	local unitId = unit:GetAttribute("UnitID")
	local mode = self:GetMode(unitId, unit.Name)
	local left = self:GetCooldownLeft(unitId)
	local owned = unit:GetAttribute("Owned") == true

	for modeName, parts in self.Buttons do
		local isActive = modeName == mode
		local color = if isActive then ACTIVE_COLOR else INACTIVE_COLOR

		parts.Button.ImageColor3 = color
		parts.Icon.ImageColor3 = color
		parts.Scale.Scale = if isActive then ACTIVE_SCALE else 1
		parts.Button.Active = owned and not isActive and left <= 0

		local cooling = left > 0 and not isActive
		parts.Cooldown.Visible = cooling
		if cooling then
			parts.Cooldown.Text = tostring(math.ceil(left)) .. "s"
		end
	end
end

function BardController:refreshIfSelected(unitIds)
	local toggle = self:getToggleTower()
	local unit = toggle and toggle.currentUnit
	if not unit or not unit.Parent then return end

	local unitId = unit:GetAttribute("UnitID")
	if not unitId or unitIds[unitId] == nil then return end

	toggle:refresh()

	local _, placement = self:getClasses()
	if placement and placement.selectedUnit == unit and placement.resizeSelectionRing then
		placement:resizeSelectionRing()
	end
end

--[[ LIFECYCLE ]]

function BardController:construct()
	Framework:Listen("BardModeChanged", function(unitId, mode, remaining)
		if typeof(unitId) ~= "string" or typeof(mode) ~= "string" then return end

		self.States[unitId] = {
			Mode = mode,
			ReadyAt = GameClock.Now() + (tonumber(remaining) or 0),
		}

		self:syncSongs()
		self:refreshIfSelected({ [unitId] = true })
	end)

	Framework:Listen("BardBuffs", function(changes)
		if typeof(changes) ~= "table" then return end

		for unitId, payload in changes do
			if typeof(payload) ~= "table" or #payload == 0 then
				self.Buffs[unitId] = nil
				continue
			end

			local list = {}

			for _, buff in payload do
				if typeof(buff) == "table" and buff.Stat then
					table.insert(list, {
						Stat = buff.Stat,
						Boost = tonumber(buff.Boost) or 0,
						Icon = buff.Icon,
						Count = tonumber(buff.Count) or 1,
						Capped = buff.Capped == true,
					})
				end
			end

			self.Buffs[unitId] = if #list > 0 then list else nil
		end

		self:syncBadges()
		self:refreshIfSelected(changes)
	end)

	Framework:Listen("RoundRestarted", function()
		table.clear(self.States)
		table.clear(self.Buffs)
		self.Silenced = false
		self:stopAllSongs(0)
		self:clearBadges()
	end)

	Framework:Listen("GameOver", function()
		self.Silenced = true
		self:stopAllSongs()
	end)

	Framework:Listen("Win", function()
		self.Silenced = true
		self:stopAllSongs()
	end)
end

function BardController:start()
end

function BardController:init()
	self:construct()

	RunService.Heartbeat:Connect(function(dt)
		self:stepCard()

		self.SyncClock += dt
		if self.SyncClock >= SYNC_INTERVAL then
			self.SyncClock = 0
			self:syncSongs()
			self:syncBadges()
		end
	end)
end

return BardController