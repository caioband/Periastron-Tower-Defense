local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

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

local IndexCatalog = require(script.IndexCatalog)
local IndexModelView = require(script.IndexModelView)

local IndexConfig = SharedConfig.IndexConfig
local Mob = SharedConfig.Mob

local Framework = Me.new()
local log = Log.new("IndexController")

--[[ CONSTANTS ]]

--[=[
	`Index.Frame.ImageLabel`, the book. The left page holds the items
	(`ItemsContainer.ItemsScrolling`, whose `Wrapper` is the template for each item)
	and the page buttons; the right page holds the preview.
]=]
local GUI = {
	ScreenGui = "Index",
	Wrapper = "Frame",
	Panel = "ImageLabel",

	Items = "ItemsContainer",
	Scrolling = "ItemsScrolling",
	Template = "Wrapper",
	Button = "ItemButton",
	Icon = "Icon",
	Viewport = "ViewportFrame",
	New = "New",
	Locked = "LockedIMG",

	Pages = "NextPreviousButtons",
	Next = "Next",
	Previous = "Previous",
	PageLabel = "TextLabel",

	Preview = "PreviewContainer",
	PreviewItem = "PreviewItem",
	Description = "Description",

	-- What `RichTextController` writes the description into, inside `Description`.
	-- Authored in Studio when it exists; otherwise created here (see
	-- `_descriptionContainer`).
	DescriptionText = "DescriptionText",
}

local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDLeft"
local HUD_BUTTON_NAME = "Index"

local WAIT_TIMEOUT = 10

local HIDE_REASON = "Index"

-- The same Cascade animation as the contracts board and the shops.
local OPEN_ANIMATION = "OpenShop"

local PAGE_PREFIX = "Items_"

local LOCKED_COLOR = Color3.new(0, 0, 0)

local EMPTY_TEXT = "Nothing discovered here yet."

--[=[
	The description's look, through `RichTextController`: all at once (`Instant`),
	white with a dark outline like the page counter, so the colored words
	(`IndexCatalog`) read on the paper. `Font` and `Size` are added per write.
]=]
local DESCRIPTION_TEXT = {
	Preset = "Instant",
	Color = Color3.new(1, 1, 1),
	Stroke = { Thickness = 0.06, Color = Color3.fromRGB(60, 35, 20) },
	Align = Enum.HorizontalAlignment.Left,
	VerticalAlign = Enum.VerticalAlignment.Top,
	Wrapped = true,
}

-- Used only when the page counter is missing; it is the counter's font.
local DESCRIPTION_FONT = "rbxasset://fonts/families/PressStart2P.json"

--[[
	The description's size: the largest whole size, between these two, whose wrapped
	text fits the box. `FILL` is how much of the box height it may take; the rest
	absorbs the small difference between how `TextService` and the renderer wrap.
]]
local DESCRIPTION_SIZE_MIN = 6
local DESCRIPTION_SIZE_MAX = 18
local DESCRIPTION_FILL = 0.92

-- How long to wait for the box to settle (the open animation) before measuring.
local DESCRIPTION_LAYOUT_TIMEOUT = 3

local ASSETS_PATH = { "Assets" }
local UNIT_FOLDER = "Units"
local ENTITY_FOLDER = "Entities"
local DIFFICULTY_FOLDER = "Difficulties"

-- What each category's 3D model plays: a unit idles, an enemy walks.
local UNIT_ANIMATION = "Idle"
local ENEMY_ANIMATIONS = { "Walk", "SlowWalk", "FastWalk" }

--[=[
	The Lobby's Index: `StarterGui.Index`, the book of everything the player has
	discovered.

	One page per category (`IndexConfig.CATEGORIES`), turned by Next/Previous in a
	loop. Each page is its own clone of `ItemsScrolling`, built the first time it is
	shown and kept: turning pages and reopening the book redraw nothing, they only
	rewrite each item's state.

	**This controller decides nothing.** What is discovered and what is new come from
	the profile replica (`Index`, `IndexSeen`); clicking a new item asks the server
	to mark it seen (`IndexSeen`), and the `New` badge leaves for good when the
	replica says so. It is hidden locally at once only so the click feels instant.

	It opens like the contracts board (the same `ProximityPanel`, animation, blur,
	and hidden HUD), but from the HUD button only: the Index has no spot on the map.

	See docs/lobby/index.md.
]=]
local IndexController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		RichTextController = {},
	},
}

--[[ INTERNAL ]]

--- The replica's `Data`, or nil until it arrives.
function IndexController:_data() : any
	local replica = self.Replica
	return replica and replica.Data or nil
end

function IndexController:_assets() : Instance?
	local node : Instance? = Shared
	for _, name in ASSETS_PATH do
		node = node and node:FindFirstChild(name)
	end

	return node
end

--- The model a 3D item shows, and the animation it plays.
function IndexController:_modelOf(category : string, key : string) : (Model?, Animation?)
	local assets = self:_assets()
	if not assets then return nil, nil end

	if category == "Units" then
		local folder = assets:FindFirstChild(UNIT_FOLDER)
		local model = folder and folder:FindFirstChild(key)
		if not model or not model:IsA("Model") then return nil, nil end

		local animation = model:FindFirstChild(UNIT_ANIMATION)
		return model, if animation and animation:IsA("Animation") then animation else nil
	end

	if category == "Enemies" then
		local entity = Mob.Entities[key]
		local entities = assets:FindFirstChild(ENTITY_FOLDER)
		local difficulties = entities and entities:FindFirstChild(DIFFICULTY_FOLDER)
		local folder = difficulties and entity and difficulties:FindFirstChild(entity.Folder)
		local model = folder and folder:FindFirstChild(key)
		if not model or not model:IsA("Model") then return nil, nil end

		-- The same ladder as `MobController`: the enemy's own walk, then the generic one.
		for _, name in ENEMY_ANIMATIONS do
			local animation = model:FindFirstChild(name)
			if animation and animation:IsA("Animation") then
				return model, animation
			end
		end

		local generic = entities and entities:FindFirstChild("Walk")
		return model, if generic and generic:IsA("Animation") then generic else nil
	end

	return nil, nil
end

--- Whether the entry is drawn as a picture (`Icon`) rather than a 3D model.
local function usesImage(category : string, entry) : boolean
	if category == "Units" then
		return entry.Image ~= nil
	end

	return category == "Weathers" or category == "Maps"
end

--[[ ITEMS ]]

--[=[
	Writes one item's state: locked or not, new or not, and its picture or model.

	Locked: the button black and the padlock on; a unit keeps its locked art, an
	enemy (or a unit without art) its black model, and a weather or map shows no
	picture at all. Locked items take no clicks.
]=]
function IndexController:_applyItem(category : string, item)
	local data = self:_data()
	local key = item.Entry.Key

	local discovered = IndexConfig.has(data, category, key)
	local isNew = discovered and IndexConfig.isNew(data, category, key) and not self.PendingSeen[category][key]

	local button = item.Button
	button.ImageColor3 = if discovered then item.ButtonColor else LOCKED_COLOR
	button.AutoButtonColor = discovered and item.AutoButtonColor
	button.Active = discovered
	button.Interactable = discovered

	if item.Locked then item.Locked.Visible = not discovered end
	if item.New then item.New.Visible = isNew end

	-- The hover grow is bound once the item is open: on a locked one it would
	-- promise a click that does nothing. Discovery is forever, so once is enough.
	if discovered and not item.FeedbackBound then
		item.FeedbackBound = true
		ButtonUtil.bindFeedback(button, self.BindMaid)
	end

	if usesImage(category, item.Entry) then
		if item.Viewport then item.Viewport.Visible = false end

		if item.Icon then
			if category == "Units" then
				item.Icon.Image = (if discovered then item.Entry.Image else item.Entry.LockedImage) or ""
				item.Icon.Visible = true
			else
				item.Icon.Image = item.Entry.Image or ""
				item.Icon.Visible = discovered
			end
		end

		return
	end

	if item.Icon then item.Icon.Visible = false end
	if not item.Viewport then return end

	item.Viewport.Visible = true

	-- The look changes only once (black to color), and that means a new clone.
	if item.ViewDiscovered == discovered and item.View then return end

	if item.View then
		item.View:Destroy()
		item.View = nil
	end

	item.ViewDiscovered = discovered

	local model, animation = self:_modelOf(category, key)
	if model then
		item.View = IndexModelView.new(item.Viewport, model, {
			Animation = animation,
			Silhouette = not discovered,
		})

		item.View:SetActive(self.IsOpen and self:_currentCategory() == category)
	end
end

--- Builds a page: a clone of `ItemsScrolling` with one item per catalog entry.
function IndexController:_buildPage(category : string)
	local view = self.View
	if not view or self.Pages[category] then return end

	local scrolling = view.ScrollTemplate:Clone()
	scrolling.Name = PAGE_PREFIX .. category
	scrolling.Visible = false
	scrolling.ScrollingDirection = Enum.ScrollingDirection.Y
	scrolling.CanvasPosition = Vector2.zero
	scrolling.Parent = view.Items

	local page = { Scrolling = scrolling, Items = {} }
	self.Pages[category] = page

	for order, entry in IndexCatalog.entries(category) do
		local wrapper = view.WrapperTemplate:Clone()
		wrapper.Name = entry.Key
		wrapper.LayoutOrder = order
		wrapper.Parent = scrolling

		local button = wrapper:FindFirstChild(GUI.Button)
		if not button or not button:IsA("GuiButton") then
			log:StudioWarn(`no {GUI.Button} in {GUI.Template}; the {category} page stays empty.`)
			wrapper:Destroy()
			continue
		end

		local function child(name : string, className : string) : any
			local found = button:FindFirstChild(name)
			return if found and found:IsA(className) then found else nil
		end

		local item = {
			Entry = entry,
			Wrapper = wrapper,
			Button = button,
			Icon = child(GUI.Icon, "ImageLabel"),
			Viewport = child(GUI.Viewport, "ViewportFrame"),
			New = child(GUI.New, "GuiObject"),
			Locked = child(GUI.Locked, "GuiObject"),
			ButtonColor = if button:IsA("ImageButton") then button.ImageColor3 else Color3.new(1, 1, 1),
			AutoButtonColor = button.AutoButtonColor,
			FeedbackBound = false,
			View = nil,
			ViewDiscovered = nil,
		}

		page.Items[entry.Key] = item

		self.BindMaid:GiveTask(button.Activated:Connect(function()
			self:_onItemClicked(category, entry.Key)
		end))

		self.BindMaid:GiveTask(function()
			if item.View then
				item.View:Destroy()
				item.View = nil
			end
		end)

		self:_applyItem(category, item)
	end
end

--- Rewrites every built page's items from the profile.
function IndexController:_applyAll()
	for category, page in self.Pages do
		for _, item in page.Items do
			self:_applyItem(category, item)
		end
	end
end

--[[ PREVIEW ]]

function IndexController:_currentCategory() : string
	return IndexConfig.CATEGORIES[self.Page]
end

--- The first discovered entry of the category, in page order.
function IndexController:_firstDiscovered(category : string) : string?
	local data = self:_data()

	for _, entry in IndexCatalog.entries(category) do
		if IndexConfig.has(data, category, entry.Key) then
			return entry.Key
		end
	end

	return nil
end

local function findEntry(category : string, key : string?)
	if not key then return nil end

	for _, entry in IndexCatalog.entries(category) do
		if entry.Key == key then
			return entry
		end
	end

	return nil
end

function IndexController:_clearPreviewView()
	if self.PreviewView then
		self.PreviewView:Destroy()
		self.PreviewView = nil
	end
end

--[=[
	Draws the right page for the current category's selected item: the 3D model in
	`PreviewItem.ViewportFrame` (units and enemies) or the picture in
	`PreviewItem.Icon` (weathers and maps), and the description. A page with nothing
	discovered shows an empty preview.
]=]
function IndexController:_renderPreview()
	-- Closed, nothing is drawn: the description measures its box, which only has its
	-- real size on screen. Opening draws it (`BeforeOpen` -> `_showPage`).
	local view = self.View
	if not view or not self.IsOpen then return end

	local category = self:_currentCategory()
	local key = self.Selected[category]
	local entry = findEntry(category, key)

	-- Already on screen: turning back to a page, or a profile change that did not
	-- touch the selection, redraws nothing. A new copy of `Index` resets the key.
	local previewKey = `{category}/{tostring(key)}`
	if self.PreviewKey == previewKey then return end

	self.PreviewKey = previewKey
	self:_clearPreviewView()

	if view.PreviewIcon then view.PreviewIcon.Visible = false end
	if view.PreviewViewport then view.PreviewViewport.Visible = false end

	self:_writeDescription(if entry then IndexCatalog.describe(category, entry) else EMPTY_TEXT)

	if not entry then return end

	if category == "Weathers" or category == "Maps" then
		if view.PreviewIcon then
			view.PreviewIcon.Image = entry.Image or ""
			view.PreviewIcon.Visible = true
		end

		return
	end

	-- Units and enemies: the model, always in 3D here, even for a unit with art.
	local model, animation = self:_modelOf(category, entry.Key)
	if model and view.PreviewViewport then
		view.PreviewViewport.Visible = true

		self.PreviewView = IndexModelView.new(view.PreviewViewport, model, { Animation = animation })
		self.PreviewView:SetActive(self.IsOpen)
	end
end

--- Selects the page's first discovered item when nothing is selected yet.
function IndexController:_ensureSelection(category : string)
	local data = self:_data()
	local key = self.Selected[category]

	if key and IndexConfig.has(data, category, key) then return end

	self.Selected[category] = self:_firstDiscovered(category)
end

--[[ PAGES ]]

--- Plays only the current page's animations, and only while the book is open.
function IndexController:_updateActivity()
	local current = self:_currentCategory()

	for category, page in self.Pages do
		local active = self.IsOpen and category == current

		for _, item in page.Items do
			if item.View then
				item.View:SetActive(active)
			end
		end
	end

	if self.PreviewView then
		self.PreviewView:SetActive(self.IsOpen)
	end
end

function IndexController:_showPage(pageIndex : number)
	local count = #IndexConfig.CATEGORIES
	self.Page = ((pageIndex - 1) % count) + 1

	local category = self:_currentCategory()
	self:_buildPage(category)

	for name, page in self.Pages do
		page.Scrolling.Visible = name == category
	end

	local view = self.View
	if view and view.PageLabel then
		view.PageLabel.Text = `{self.Page}/{count}`
	end

	self:_ensureSelection(category)
	self:_renderPreview()
	self:_updateActivity()
end

--[[ INPUT ]]

--[=[
	A click on a discovered item: it goes to the preview and, when it was new, the
	server is asked to mark it seen. Locked items do not even get here (their button
	is not interactable), and the check repeats for safety.
]=]
function IndexController:_onItemClicked(category : string, key : string)
	local data = self:_data()
	if not IndexConfig.has(data, category, key) then return end

	self.Selected[category] = key

	if category == self:_currentCategory() then
		self:_renderPreview()
	end

	if IndexConfig.isNew(data, category, key) and not self.PendingSeen[category][key] then
		self.PendingSeen[category][key] = true
		Framework:Fire("IndexSeen", category, key)

		local page = self.Pages[category]
		local item = page and page.Items[key]
		if item then
			self:_applyItem(category, item)
		end
	end
end

--[[ BINDING ]]

--[=[
	The box the description is written into: the one authored inside `Description`,
	or a frame created to fill it. The text is sized to fit (`_fitDescriptionSize`),
	so the scroller never scrolls.
]=]
function IndexController:_descriptionContainer(description : ScrollingFrame) : GuiObject
	local authored = description:FindFirstChild(GUI.DescriptionText)
	if authored and authored:IsA("GuiObject") then
		return authored
	end

	description.CanvasSize = UDim2.new()
	description.AutomaticCanvasSize = Enum.AutomaticSize.None

	local frame = Instance.new("Frame")
	frame.Name = GUI.DescriptionText
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = description

	return frame
end

--[=[
	The largest size at which `plain` (the description without markup), wrapped at
	the box width, fits the box height.

	`RichTextController`'s `Fit` measures a sentence as one line split into rows, and
	the description is several paragraphs, each with its own break; so the size is
	measured here, wrapping the real text with `TextService`, and handed over as
	`Size`. The renderer keeps the box it was written in as the reference and rescales
	with it, so a resized screen needs no new measurement.

	**Yields** (`GetTextBoundsAsync`). Cached per text and box size.
]=]
function IndexController:_fitDescriptionSize(container : GuiObject, plain : string, font : string) : number
	local box = container.AbsoluteSize
	if box.X <= 0 or box.Y <= 0 then
		return DESCRIPTION_SIZE_MIN
	end

	local cacheKey = `{math.floor(box.X)}x{math.floor(box.Y)}|{plain}`
	local cached = self.DescriptionSizes[cacheKey]
	if cached then
		return cached
	end

	local fontFace = Font.new(font)

	local function fits(size : number) : boolean
		local params = Instance.new("GetTextBoundsParams")
		params.Text = plain
		params.Font = fontFace
		params.Size = size
		params.Width = box.X

		local ok, bounds = pcall(TextService.GetTextBoundsAsync, TextService, params)
		return ok and bounds.Y <= box.Y * DESCRIPTION_FILL
	end

	local best = DESCRIPTION_SIZE_MIN
	local low, high = DESCRIPTION_SIZE_MIN, DESCRIPTION_SIZE_MAX

	while low <= high do
		local middle = (low + high) // 2

		if fits(middle) then
			best = middle
			low = middle + 1
		else
			high = middle - 1
		end
	end

	self.DescriptionSizes[cacheKey] = best

	return best
end

--[=[
	Writes the description through `RichTextController`, all at once.

	The write waits for the box to settle and measures the text, so it runs in its own
	thread; a token drops a write that a newer click already replaced.
]=]
function IndexController:_writeDescription(markup : string)
	local view = self.View
	local container = view and view.DescriptionContainer
	local rich = self.Controllers.RichTextController

	if not container or not rich then return end

	self.DescriptionToken += 1
	local token = self.DescriptionToken

	rich:Clear(container, true)

	local pageLabel = view.PageLabel
	local font = if pageLabel then pageLabel.FontFace.Family else DESCRIPTION_FONT

	task.spawn(function()
		rich:AwaitLayout(container, DESCRIPTION_LAYOUT_TIMEOUT)
		if token ~= self.DescriptionToken or not container.Parent then return end

		local size = self:_fitDescriptionSize(container, rich:Plain(markup), font)
		if token ~= self.DescriptionToken or not container.Parent then return end

		local options = table.clone(DESCRIPTION_TEXT)
		options.Font = font
		options.Size = size

		rich:Write(container, markup, options)
	end)
end

--[=[
	A new copy of `Index` (the ScreenGui resets on spawn): finds the pieces, takes
	the templates off the screen, and forgets the pages built on the old copy. The
	panel itself (animation, blur, X) belongs to `ProximityPanel`.
]=]
function IndexController:_onBind(panel : GuiObject, maid)
	self.BindMaid = maid
	self.Pages = {}

	-- `ProximityPanel` starts every new copy closed, without firing `OpenChanged`.
	self.IsOpen = false
	self.PreviewKey = nil
	self.PreviewView = nil
	self.View = nil

	maid:GiveTask(function()
		self:_clearPreviewView()
	end)

	local items = panel:WaitForChild(GUI.Items, WAIT_TIMEOUT)
	local scrolling = items and items:WaitForChild(GUI.Scrolling, WAIT_TIMEOUT)
	local wrapper = scrolling and scrolling:WaitForChild(GUI.Template, WAIT_TIMEOUT)

	if not wrapper then
		log:StudioWarn(`could not find {GUI.Panel}.{GUI.Items}.{GUI.Scrolling}.{GUI.Template}; the Index stays empty.`)
		return
	end

	-- The authored scroller and its item leave the screen and stay only as templates.
	wrapper.Parent = nil
	scrolling.Parent = nil

	local pages = panel:FindFirstChild(GUI.Pages)
	local preview = panel:FindFirstChild(GUI.Preview)
	local previewItem = preview and preview:FindFirstChild(GUI.PreviewItem)
	local description = preview and preview:FindFirstChild(GUI.Description)

	local pageLabel = pages and pages:FindFirstChild(GUI.PageLabel)
	local previewIcon = previewItem and previewItem:FindFirstChild(GUI.Icon)
	local previewViewport = previewItem and previewItem:FindFirstChild(GUI.Viewport)

	self.View = {
		Items = items,
		ScrollTemplate = scrolling,
		WrapperTemplate = wrapper,
		PageLabel = if pageLabel and pageLabel:IsA("TextLabel") then pageLabel else nil,
		PreviewIcon = if previewIcon and previewIcon:IsA("ImageLabel") then previewIcon else nil,
		PreviewViewport = if previewViewport and previewViewport:IsA("ViewportFrame") then previewViewport else nil,
		Description = if description and description:IsA("ScrollingFrame") then description else nil,
		DescriptionContainer = nil,
	}

	maid:GiveTask(function()
		wrapper:Destroy()
		scrolling:Destroy()
	end)

	if self.View.Description then
		self.View.DescriptionContainer = self:_descriptionContainer(self.View.Description)
	end

	for name, step in { [GUI.Next] = 1, [GUI.Previous] = -1 } do
		local button = pages and pages:FindFirstChild(name)

		if button and button:IsA("GuiButton") then
			maid:GiveTask(button.Activated:Connect(function()
				self:_showPage(self.Page + step)
			end))

			ButtonUtil.bindFeedback(button, maid)
		else
			log:StudioWarn(`no {GUI.Pages}.{name}; that page button does nothing.`)
		end
	end

	if self.View.PageLabel then
		self.View.PageLabel.Text = `{self.Page}/{#IndexConfig.CATEGORIES}`
	end
end

--- Hooks the HUD button. Its own maid: the HUD and `Index` reset at different times.
function IndexController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, HUD_BUTTON_NAME, WAIT_TIMEOUT)

	if not button or not button:IsA("GuiButton") then
		if not self.WarnedButton then
			self.WarnedButton = true
			log:StudioWarn(`could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		end

		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:Open()
	end))
end

function IndexController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

function IndexController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		local function refresh()
			-- What the replica now confirms seen no longer needs the local guess.
			local data = self:_data()
			for category, keys in self.PendingSeen do
				for key in keys do
					if not IndexConfig.isNew(data, category, key) then
						keys[key] = nil
					end
				end
			end

			self:_applyAll()

			if self.View then
				local category = self:_currentCategory()
				self:_ensureSelection(category)
				self:_renderPreview()
			end
		end

		refresh()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= IndexConfig.DISCOVERED_KEY and key ~= IndexConfig.SEEN_KEY then
				return
			end

			refresh()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--- Spins what is on screen: the current page's models and the preview.
function IndexController:_watchSpin()
	self.Maid:GiveTask(RunService.RenderStepped:Connect(function(deltaTime : number)
		if not self.IsOpen then return end

		local page = self.Pages[self:_currentCategory()]
		if page then
			for _, item in page.Items do
				if item.View then
					item.View:Step(deltaTime)
				end
			end
		end

		if self.PreviewView then
			self.PreviewView:Step(deltaTime)
		end
	end))
end

--[[ EXTERNAL ]]

function IndexController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function IndexController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function IndexController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function IndexController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function IndexController:construct()
	self.Proximity = ProximityPanel.new({
		Name = "IndexController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		InterfaceController = self.Controllers.InterfaceController,

		OnBind = function(_screenGui, _wrapper, panel, maid)
			self:_onBind(panel, maid)
		end,

		BeforeOpen = function()
			self.IsOpen = true
			self:_showPage(self.Page)
		end,
	})

	self.Maid:GiveTask(self.Proximity.Signals.OpenChanged:Connect(function(isOpen : boolean)
		self.IsOpen = isOpen
		self:_updateActivity()
	end))

	self.Maid:GiveTask(function()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_observeUI()
	self:_watchProfile()
	self:_watchSpin()
end

function IndexController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function IndexController:init()
	self.Maid = Maid.new()

	-- The HUD button's click, which the engine rebuilds on every respawn.
	self.HudMaid = Maid.new()
	self.Maid:GiveTask(self.HudMaid)

	-- The current `Index` copy's maid, handed over by `ProximityPanel`.
	self.BindMaid = Maid.new()

	self.Replica = nil
	self.Proximity = nil
	self.View = nil
	self.IsOpen = false
	self.WarnedButton = false

	-- The current page, an index into `IndexConfig.CATEGORIES`.
	self.Page = 1

	-- [category] = { Scrolling, Items = { [key] = item } }, on the current copy.
	self.Pages = {}

	-- [category] = key. Kept across copies: a respawn does not lose the selection.
	self.Selected = {}

	-- [category] = { [key] = true }: clicked, not yet confirmed by the replica.
	self.PendingSeen = {}
	for _, category in IndexConfig.CATEGORIES do
		self.PendingSeen[category] = {}
	end

	self.PreviewView = nil
	self.PreviewKey = nil

	-- The description's pending write, and the measured sizes. See `_writeDescription`.
	self.DescriptionToken = 0
	self.DescriptionSizes = {}
end

return IndexController
