-- HALLOWEEN EVENT OFF in the Lobby: the whole module is commented out below.
-- To bring it back, delete this header, the opening `--[==[` and the closing
-- `]==]` + `return {}` at the end of the file.

--[==[
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Util:WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local ProximityPanel = require(Util.ProximityPanel)
local UIUtil = require(Util.UIUtil)

local HalloweenConfig = SharedConfig.HalloweenConfig
local EventCurrencyConfig = SharedConfig.EventCurrencyConfig
local SkinConfig = SharedConfig.SkinConfig
local NametagConfig = SharedConfig.NametagConfig

local Framework = Me.new()
local log = Log.new("HalloweenController")

local LocalPlayer = Players.LocalPlayer
local MERCHANT = HalloweenConfig.Merchant

--[[ CONSTANTS ]]

--[=[
	`HalloweenUI.Frame.Board`, with `Tabs.<Skin|Quest|Title>` (each with its `Glow`)
	and `Pages.Info` / `Pages.Quest`. The two pages are **art templates**: `Info` is
	the shop row (portrait, name bar, price bar) and `Quest` the quest row. They leave
	the screen on bind and every row is a clone, with its text and buttons created
	here, so the art in Studio carries no labels.
]=]
local GUI = {
	ScreenGui = "HalloweenUI",
	Wrapper = "Frame",
	Panel = "Board",
	Tabs = "Tabs",
	Glow = "Glow",
	Pages = "Pages",
	ShopTemplate = "Info",
	QuestTemplate = "Quest",
}

local TAB_ORDER = { "Skin", "Quest", "Title" }
local DEFAULT_TAB = "Skin"

-- Which `HalloweenConfig.Shop` list each shop tab shows.
local TAB_CATEGORY = {
	Skin = "Skins",
	Title = "Titles",
}

local HIDE_REASON = "HalloweenUI"

local FONT = Font.new("rbxasset://fonts/families/PressStart2P.json", Enum.FontWeight.Bold)
local TEXT_COLOR = Color3.new(1, 1, 1)
local STROKE_COLOR = Color3.fromRGB(8, 14, 18)
local ACCENT_COLOR = Color3.fromRGB(92, 212, 191)
local CURRENCY_COLOR = Color3.fromRGB(255, 85, 0)
local SCROLL_COLOR = Color3.fromRGB(92, 140, 150)

local DISABLED_TRANSPARENCY = 0.55

-- The lists run from the template's top down to the floor of the board art.
local LIST_BOTTOM = 0.8
local LIST_PADDING = 6

--[=[
	Rows are sized in **pixels** from the list's width and the art's ratio
	(`_resize`). A ScrollingFrame child with a scale height of 0 and only an aspect
	constraint collapses to nothing, so the height cannot be left to the constraint.
]=]
local SHOP_ROW_WIDTH = 0.96
local QUEST_ROW_WIDTH = 0.96 * (360 / 402)
local HEADER_WIDTH = 0.96
local HEADER_RATIO = 12

-- { X, Y, Width, Height } in scale of the row art.
local SHOP_ROW = {
	Portrait = { 0.05, 0.09, 0.36, 0.80 },
	Name = { 0.48, 0.25, 0.48, 0.24 },
	Price = { 0.47, 0.55, 0.35, 0.18 },
}

local QUEST_ROW = {
	Icon = { 0.09, 0.22, 0.26, 0.56 },
	Task = { 0.39, 0.12, 0.56, 0.42 },
	Reward = { 0.39, 0.60, 0.28, 0.26 },
	Claim = { 0.69, 0.60, 0.26, 0.26 },
}

-- On the board's base, under the floor. Named so `EventCurrencyController` fills it.
local COUNTER = { 0.2, 0.905, 0.6, 0.075 }
local COUNTER_NAME = "EventCurrency"
local COUNTER_TEXT_NAME = "EventAmountText"

-- Upper limits for `TextScaled`; the box decides the size below them.
local TEXT_MAX = {
	Counter = 48,
	Header = 28,
	Name = 28,
	Preview = 24,
	Price = 24,
	Task = 20,
	Reward = 22,
	Claim = 22,
}

local ROW_PREFIX = "Item_"
local QUEST_PREFIX = "Quest_"

local BUY_SOUND = "Coins"
local BUY_SOUND_KEY = "HalloweenBuy"
local CLAIM_SOUND_KEY = "HalloweenClaim"

local REQUEST_COOLDOWN = 0.25
local TIMER_INTERVAL = 1

local WATCHED_KEYS = {
	Stats = true,
	[SkinConfig.PROFILE_KEY] = true,
	[NametagConfig.PROFILE_KEY] = true,
	[HalloweenConfig.PROFILE_KEY] = true,
}

--[=[
	The Spooky Merchant: `StarterGui.HalloweenUI`.

	It opens when the player reaches `SpookyMerchant`'s beam circle and closes when
	they leave, through `ProximityPanel`, like the contracts board and the shops. It
	never opens while the event is off.

	**This controller decides nothing.** Buying sends "category, id" to
	`HalloweenShopService`; claiming sends "slot N of period X" to
	`HalloweenQuestService`. What the rows show (owned, equipped, progress, claimed,
	balance) is read from the profile replica.
]=]
local HalloweenController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},
		EventCurrencyController = {},
		NametagController = {},
	},
}

--[[ BUILDERS ]]

local function place(gui : GuiObject, rect : { number })
	gui.Position = UDim2.fromScale(rect[1], rect[2])
	gui.Size = UDim2.fromScale(rect[3], rect[4])
end

local function makeText(className : string, name : string, parent : Instance, rect : { number }, color : Color3?, maxSize : number?) : any
	local label = Instance.new(className)
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.FontFace = FONT
	label.Text = ""
	label.TextColor3 = color or TEXT_COLOR
	label.TextScaled = true
	label.TextWrapped = true
	place(label, rect)

	if label:IsA("TextButton") then
		label.AutoButtonColor = false
	end

	local stroke = Instance.new("UIStroke")
	stroke.Color = STROKE_COLOR
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label

	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxSize or 24
	limit.Parent = label

	label.Parent = parent
	return label
end

local function makeIcon(name : string, parent : Instance, rect : { number }, image : string) : ImageLabel
	local icon = Instance.new("ImageLabel")
	icon.Name = name
	icon.BackgroundTransparency = 1
	icon.BorderSizePixel = 0
	icon.Image = image
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ResampleMode = Enum.ResamplerMode.Pixelated
	place(icon, rect)

	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = icon

	icon.Parent = parent
	return icon
end

--- The board's width over its height, from the wrapper's own constraint.
local function boardRatio(wrapper : Instance) : number
	local constraint = wrapper:FindFirstChildWhichIsA("UIAspectRatioConstraint")
	return if constraint then constraint.AspectRatio else 546 / 750
end

--- The art's own width over height, from its scale on the board.
local function artRatio(template : GuiObject, board : number) : number
	return (template.Size.X.Scale / math.max(template.Size.Y.Scale, 1e-3)) * board
end

--- A clone of the art for a list. Its height is set by `_resize`.
local function cloneRow(template : GuiObject, name : string, order : number, width : number) : GuiObject
	local row = template:Clone()
	row.Name = name
	row.Visible = true
	row.AnchorPoint = Vector2.zero
	row.Position = UDim2.new()
	row.Size = UDim2.fromScale(width, 0)
	row.LayoutOrder = order

	return row
end

--- A scrolling list covering the content area, starting where the template sits.
local function makeList(parent : Instance, template : GuiObject, name : string) : ScrollingFrame
	local list = Instance.new("ScrollingFrame")
	list.Name = name
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromScale(template.Position.X.Scale, template.Position.Y.Scale)
	list.Size = UDim2.fromScale(template.Size.X.Scale, LIST_BOTTOM - template.Position.Y.Scale)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = SCROLL_COLOR
	list.Visible = false

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, LIST_PADDING)
	layout.Parent = list

	list.Parent = parent
	return list
end

--[[ INTERNAL ]]

function HalloweenController:_data()
	local replica = self.Replica
	return replica and replica.Data or nil
end

function HalloweenController:_balance() : number
	local currency = self.Controllers.EventCurrencyController
	return if currency then currency:GetAmount() else 0
end

function HalloweenController:_merchant() : BasePart?
	local model = workspace:FindFirstChild(MERCHANT.Model)
	local target = model and model:FindFirstChild(MERCHANT.Target, true)

	if target and target:IsA("BasePart") then
		return target
	end

	if not self.WarnedMerchant then
		self.WarnedMerchant = true
		log:StudioWarn(`no {MERCHANT.Model}.{MERCHANT.Target} in Workspace -- the merchant never opens.`)
	end

	return nil
end

function HalloweenController:_ownsSkin(id : string) : boolean
	local data = self:_data()
	local skins = SkinConfig.sanitize(data and data[SkinConfig.PROFILE_KEY])
	return skins.Owned[id] == true
end

function HalloweenController:_ownsTitle(id : string) : boolean
	local nametags = self.Controllers.NametagController
	if nametags and nametags.Owns then
		return nametags:Owns(id)
	end

	local data = self:_data()
	local level = NametagConfig.LevelOf(data)
	local owned = NametagConfig.sanitize(data and data[NametagConfig.PROFILE_KEY], level).Owned
	return NametagConfig.IsAvailable(id, owned, level)
end

function HalloweenController:_owns(category : string, id : string) : boolean
	if category == "Skins" then
		return self:_ownsSkin(id)
	end

	return self:_ownsTitle(id)
end

function HalloweenController:_isEquippedTitle(id : string) : boolean
	return LocalPlayer:GetAttribute(NametagConfig.ATTRIBUTE) == id
end

function HalloweenController:_select(tab : string)
	self.Tab = tab

	for name, glow in self.Glows do
		glow.Visible = name == tab
	end

	for name, list in self.Lists do
		list.Visible = name == tab
		list.CanvasPosition = Vector2.zero
	end
end

--[[ SIZING ]]

--- Registers a list child whose height follows the list's width at `ratio`.
function HalloweenController:_fit(list : ScrollingFrame, gui : GuiObject, width : number, ratio : number)
	local entries = self.Fitted[list]
	if not entries then
		entries = {}
		self.Fitted[list] = entries
	end

	table.insert(entries, { Gui = gui, Width = width, Ratio = ratio })
end

function HalloweenController:_resize(list : ScrollingFrame)
	local entries = self.Fitted[list]
	if not entries then return end

	local listWidth = list.AbsoluteSize.X
	if listWidth <= 0 then return end

	for _, entry in entries do
		local height = math.max(1, math.floor(listWidth * entry.Width / entry.Ratio + 0.5))
		entry.Gui.Size = UDim2.new(entry.Width, 0, 0, height)
	end
end

function HalloweenController:_watchSize(list : ScrollingFrame, maid)
	maid:GiveTask(list:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_resize(list)
	end))

	self:_resize(list)
end

--[[ RENDER ]]

function HalloweenController:_renderShopRow(entry)
	local category = entry.Category
	local id = entry.Item.Id
	local owned = self:_owns(category, id)

	local text, active, color

	if owned and category == "Titles" then
		local equipped = self:_isEquippedTitle(id)
		text = if equipped then "EQUIPPED" else "EQUIP"
		active = true
		color = ACCENT_COLOR
	elseif owned then
		text = "OWNED"
		active = false
		color = ACCENT_COLOR
	else
		text = UIUtil.formatCommas(entry.Item.Price)
		active = self:_balance() >= entry.Item.Price
		color = CURRENCY_COLOR
	end

	entry.Icon.Visible = not owned
	entry.Label.Position = if owned then UDim2.fromScale(0, 0) else UDim2.fromScale(0.25, 0)
	entry.Label.Size = if owned then UDim2.fromScale(1, 1) else UDim2.fromScale(0.75, 1)
	entry.Label.TextXAlignment = if owned then Enum.TextXAlignment.Center else Enum.TextXAlignment.Left
	entry.Label.Text = text
	entry.Label.TextColor3 = color

	local dimmed = not active and not owned
	entry.Label.TextTransparency = if dimmed then DISABLED_TRANSPARENCY else 0
	entry.Icon.ImageTransparency = if dimmed then DISABLED_TRANSPARENCY else 0

	entry.Buy.Active = active
end

function HalloweenController:_renderQuests()
	local data = self:_data()
	local quests = data and data[HalloweenConfig.PROFILE_KEY]

	for kind, section in self.QuestSections do
		local bucket = typeof(quests) == "table" and quests[kind]
		local slots = bucket and bucket.Slots or {}

		for index, entry in section.Rows do
			local slot = slots[index]
			local definition = slot and HalloweenConfig.get(slot.Id)

			entry.Row.Visible = definition ~= nil
			if not definition then continue end

			local claimed = slot.Claimed == true
			local canClaim = HalloweenConfig.isComplete(definition, slot) and not claimed

			entry.Task.Text = HalloweenConfig.describe(definition, slot)
			entry.Reward.Text = "+" .. UIUtil.formatCommas(HalloweenConfig.rewardOf(definition, slot))

			entry.Claim.Text = if claimed then "CLAIMED" else "CLAIM"
			entry.Claim.Active = canClaim
			entry.Claim.TextTransparency = if canClaim then 0 else DISABLED_TRANSPARENCY

			entry.Icon.ImageTransparency = if claimed then DISABLED_TRANSPARENCY else 0
			entry.Reward.TextTransparency = if claimed then DISABLED_TRANSPARENCY else 0
		end
	end
end

function HalloweenController:_updateTimers()
	local time = workspace:GetServerTimeNow()

	for kind, section in self.QuestSections do
		local header = section.Header
		if header and header.Parent then
			local period = HalloweenConfig.periodOf(kind, time)
			local remaining = HalloweenConfig.endsAt(kind, period) - time
			header.Text = string.format("%s  %s", string.upper(kind), HalloweenConfig.formatRemaining(remaining))
		end
	end
end

function HalloweenController:_render()
	for _, rows in self.ShopRows do
		for _, entry in rows do
			self:_renderShopRow(entry)
		end
	end

	self:_renderQuests()
end

--[[ REQUESTS ]]

function HalloweenController:_cooldown() : boolean
	local now = os.clock()
	if now - self.LastRequest < REQUEST_COOLDOWN then
		return false
	end

	self.LastRequest = now
	return true
end

function HalloweenController:_onShopClick(category : string, id : string)
	local item = HalloweenConfig.getShopItem(category, id)
	if not item or not self:_cooldown() then return end

	if self:_owns(category, id) then
		local nametags = self.Controllers.NametagController
		if category == "Titles" and nametags then
			nametags:Toggle(id)
		end
		return
	end

	if self:_balance() < item.Price then return end

	Framework:Fire("RequestBuyHalloweenItem", category, id)
end

function HalloweenController:_requestClaim(kind : string, index : number)
	local data = self:_data()
	local quests = data and data[HalloweenConfig.PROFILE_KEY]
	local slot = quests and quests[kind] and quests[kind].Slots[index]
	local definition = slot and HalloweenConfig.get(slot.Id)

	if not definition or slot.Claimed or not HalloweenConfig.isComplete(definition, slot) then
		return
	end

	if not self:_cooldown() then return end

	Framework:Fire("ClaimHalloweenQuest", kind, index)
end

--[[ BIND ]]

function HalloweenController:_buildShopRow(tab : string, item, order : number, template : GuiObject, ratio : number, maid)
	local category = TAB_CATEGORY[tab]
	local _, definition = HalloweenConfig.getShopItem(category, item.Id)
	if not definition then return end

	local list = self.Lists[tab]
	local row = cloneRow(template, ROW_PREFIX .. item.Id, order, SHOP_ROW_WIDTH)

	if category == "Skins" then
		local image = definition.Icon or definition.Image or ""
		local portrait = makeIcon("Portrait", row, SHOP_ROW.Portrait, image)
		portrait.ResampleMode = Enum.ResamplerMode.Default
		portrait:FindFirstChildWhichIsA("UIAspectRatioConstraint"):Destroy()
	else
		local preview = makeText("TextLabel", "Portrait", row, SHOP_ROW.Portrait, TEXT_COLOR, TEXT_MAX.Preview)
		preview.Text = LocalPlayer.DisplayName

		local nametags = self.Controllers.NametagController
		local style = definition.Style and (definition.Style.Username or definition.Style.Title)
		if nametags and nametags._applyStyle and style then
			nametags:_applyStyle(preview, style)
		end
	end

	local name = makeText("TextLabel", "ItemName", row, SHOP_ROW.Name, TEXT_COLOR, TEXT_MAX.Name)
	name.Text = string.upper(definition.DisplayName)
	name.TextXAlignment = Enum.TextXAlignment.Left

	local buy = Instance.new("TextButton")
	buy.Name = "Buy"
	buy.BackgroundTransparency = 1
	buy.BorderSizePixel = 0
	buy.Text = ""
	buy.AutoButtonColor = false
	place(buy, SHOP_ROW.Price)
	buy.Parent = row

	local icon = makeIcon("CurrencyIcon", buy, { 0.02, 0, 0.2, 1 }, HalloweenConfig.CURRENCY_ICON)
	local label = makeText("TextLabel", "Label", buy, { 0.25, 0, 0.75, 1 }, CURRENCY_COLOR, TEXT_MAX.Price)

	row.Parent = list
	self:_fit(list, row, SHOP_ROW_WIDTH, ratio)

	maid:GiveTask(buy.Activated:Connect(function()
		self:_onShopClick(category, item.Id)
	end))
	ButtonUtil.bindFeedback(buy, maid)

	table.insert(self.ShopRows[tab], {
		Category = category,
		Item = item,
		Buy = buy,
		Icon = icon,
		Label = label,
	})
end

function HalloweenController:_buildQuests(template : GuiObject, ratio : number, maid)
	local list = self.Lists.Quest

	for order, kind in HalloweenConfig.KIND_ORDER do
		local header = makeText("TextLabel", kind .. "Header", list, { 0, 0, HEADER_WIDTH, 0 }, ACCENT_COLOR, TEXT_MAX.Header)
		header.LayoutOrder = order * 100
		header.TextXAlignment = Enum.TextXAlignment.Left
		self:_fit(list, header, HEADER_WIDTH, HEADER_RATIO)

		local rows = {}

		for index = 1, HalloweenConfig.KINDS[kind].Count do
			local row = cloneRow(template, QUEST_PREFIX .. kind .. "_" .. index, order * 100 + index, QUEST_ROW_WIDTH)
			row.Visible = false

			local icon = makeIcon("Icon", row, QUEST_ROW.Icon, HalloweenConfig.CURRENCY_ICON)

			local task = makeText("TextLabel", "Task", row, QUEST_ROW.Task, TEXT_COLOR, TEXT_MAX.Task)
			task.TextXAlignment = Enum.TextXAlignment.Left

			local reward = makeText("TextLabel", "Reward", row, QUEST_ROW.Reward, CURRENCY_COLOR, TEXT_MAX.Reward)
			reward.TextXAlignment = Enum.TextXAlignment.Left

			local claim = makeText("TextButton", "ClaimButton", row, QUEST_ROW.Claim, ACCENT_COLOR, TEXT_MAX.Claim)

			row.Parent = list
			self:_fit(list, row, QUEST_ROW_WIDTH, ratio)

			maid:GiveTask(claim.Activated:Connect(function()
				self:_requestClaim(kind, index)
			end))
			ButtonUtil.bindFeedback(claim, maid)

			rows[index] = {
				Row = row,
				Icon = icon,
				Task = task,
				Reward = reward,
				Claim = claim,
			}
		end

		self.QuestSections[kind] = {
			Header = header,
			Rows = rows,
		}
	end
end

function HalloweenController:_buildCounter(panel : GuiObject)
	local counter = Instance.new("Frame")
	counter.Name = COUNTER_NAME
	counter.BackgroundTransparency = 1
	counter.BorderSizePixel = 0
	counter.ZIndex = 3
	place(counter, COUNTER)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.02, 0)
	layout.Parent = counter

	local icon = makeIcon("Icon", counter, { 0, 0, 1, 1 }, HalloweenConfig.CURRENCY_ICON)
	icon.LayoutOrder = 1

	local text = makeText("TextLabel", COUNTER_TEXT_NAME, counter, { 0, 0, 0.7, 1 }, CURRENCY_COLOR, TEXT_MAX.Counter)
	text.LayoutOrder = 2
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Text = UIUtil.formatCommas(self:_balance())

	counter.Parent = panel
end

function HalloweenController:_onBind(wrapper : GuiObject, panel : GuiObject, maid)
	self.Glows = {}
	self.Lists = {}
	self.Fitted = {}
	self.ShopRows = { Skin = {}, Title = {} }
	self.QuestSections = {}

	local tabs = panel:FindFirstChild(GUI.Tabs)

	for _, name in TAB_ORDER do
		local tab = tabs and tabs:FindFirstChild(name)

		if tab and tab:IsA("GuiButton") then
			local glow = tab:FindFirstChild(GUI.Glow)
			if glow and glow:IsA("GuiObject") then
				self.Glows[name] = glow
			end

			maid:GiveTask(tab.Activated:Connect(function()
				self:_select(name)
			end))
			ButtonUtil.bindFeedback(tab, maid)
		else
			log:StudioWarn(`no {GUI.Tabs}.{name} button in {GUI.ScreenGui}.`)
		end
	end

	local pages = panel:FindFirstChild(GUI.Pages)
	local shopTemplate = pages and pages:FindFirstChild(GUI.ShopTemplate)
	local questTemplate = pages and pages:FindFirstChild(GUI.QuestTemplate)

	if not shopTemplate or not questTemplate then
		log:StudioWarn(`could not find {GUI.Pages}.{GUI.ShopTemplate} / {GUI.Pages}.{GUI.QuestTemplate}.`)
		return
	end

	shopTemplate.Parent = nil
	questTemplate.Parent = nil

	local board = boardRatio(wrapper)
	local shopRatio = artRatio(shopTemplate, board)
	local questRatio = artRatio(questTemplate, board)

	self.Lists.Skin = makeList(pages, shopTemplate, "SkinList")
	self.Lists.Title = makeList(pages, shopTemplate, "TitleList")
	self.Lists.Quest = makeList(pages, shopTemplate, "QuestList")

	for tab, category in TAB_CATEGORY do
		for order, item in HalloweenConfig.Shop[category] do
			self:_buildShopRow(tab, item, order, shopTemplate, shopRatio, maid)
		end
	end

	self:_buildQuests(questTemplate, questRatio, maid)
	self:_buildCounter(panel)

	for _, list in self.Lists do
		self:_watchSize(list, maid)
	end

	maid:GiveTask(shopTemplate)
	maid:GiveTask(questTemplate)

	self:_select(self.Tab)
	self:_render()
	self:_updateTimers()
end

--[[ WATCHERS ]]

function HalloweenController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and not WATCHED_KEYS[key] then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)

	self.Maid:GiveTask(LocalPlayer:GetAttributeChangedSignal(NametagConfig.ATTRIBUTE):Connect(function()
		self:_render()
	end))
end

function HalloweenController:_watchTimers()
	local clock = 0

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		clock += deltaTime
		if clock < TIMER_INTERVAL then return end

		clock = 0

		if self:IsOpen() then
			self:_updateTimers()
		end
	end))
end

--[[ EXTERNAL ]]

function HalloweenController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function HalloweenController:Open()
	if self.Proximity and EventCurrencyConfig.Enabled then
		self.Proximity:Open()
	end
end

function HalloweenController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function HalloweenController:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function HalloweenController:construct()
	local function playSound(key : string)
		local music = self.Controllers.MusicController
		if music then
			music:PlaySFX(BUY_SOUND, { Key = key })
		end
	end

	Framework:Listen("HalloweenPurchaseResult", function(category, id, success : boolean, reason : string?)
		if success then
			playSound(BUY_SOUND_KEY)
		elseif reason then
			log:Debug(`purchase of {tostring(category)}.{tostring(id)} refused ({reason}).`)
		end

		self:_render()
	end)

	Framework:Listen("HalloweenQuestClaimResult", function(_kind, _index, success : boolean, reason : string?)
		if success then
			playSound(CLAIM_SOUND_KEY)
		elseif reason then
			log:Debug(`quest claim refused ({reason}).`)
		end
	end)

	local music = self.Controllers.MusicController
	if music then
		music:PreloadSFX({ BUY_SOUND })
	end

	self.Proximity = ProximityPanel.new({
		Name = "HalloweenController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = MERCHANT.Animation,
		HideReason = HIDE_REASON,
		GetReference = function()
			if not EventCurrencyConfig.Enabled then
				return nil
			end

			local target = self:_merchant()
			return target and target.Position or nil
		end,
		Radius = MERCHANT.OpenRadius,
		Interval = MERCHANT.ProximityInterval,
		InterfaceController = self.Controllers.InterfaceController,

		OnBind = function(_screenGui, wrapper, panel, maid)
			self:_onBind(wrapper, panel, maid)
		end,

		BeforeOpen = function()
			self:_select(DEFAULT_TAB)
			self:_render()
			self:_updateTimers()

			for _, list in self.Lists do
				self:_resize(list)
			end
		end,
	})

	self.Maid:GiveTask(function()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_watchProfile()
	self:_watchTimers()
end

function HalloweenController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function HalloweenController:init()
	self.Maid = Maid.new()

	self.Replica = nil
	self.Proximity = nil
	self.WarnedMerchant = false
	self.LastRequest = 0

	self.Tab = DEFAULT_TAB

	-- Per copy of `HalloweenUI`, rebuilt in `_onBind`.
	self.Glows = {}
	self.Lists = {}
	self.Fitted = {}
	self.ShopRows = { Skin = {}, Title = {} }
	self.QuestSections = {}
end

return HalloweenController
]==]

return {}
