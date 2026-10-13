local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("BackpackTabController")

--[[ CONSTANTS ]]

local GUI = {
	ScreenGui = "backpackui",
	Wrapper = "Frame",
	Panel = "Backpack",
	Content = "Content",
	Shelf = "CrateWrapper",
}

-- Tab button name -> its page under `Content`, top to bottom.
local TABS = {
	{ Button = "Crates", Page = "CratesPage" },
	{ Button = "Skins", Page = "SkinsPage" },
	{ Button = "Nametags", Page = "NametagsPage" },
	{ Button = "Runes", Page = "RunesPage" },
}

local DEFAULT_TAB = "Crates"
local WAIT_TIMEOUT = 10
local CLICK_SOUND = "CardFlip"

local SELECTED_COLOR = Color3.new(1, 1, 1)
local IDLE_COLOR = Color3.fromRGB(150, 150, 150)

-- Space under the last row of cards, in card heights.
local BOTTOM_PADDING = 0.25

--[=[
	The backpack's tabs: each button on the left shows its own page inside the bag
	(`Content.<Tab>Page`), one page at a time. The selected button is lit and the rest
	are dimmed. Opening the backpack always lands on Crates, so the tutorial's crate
	is on screen when it asks for it.

	**Each page's scroll fits its cards.** The shelf controllers place cards on a grid
	in their page's `CrateWrapper` (one card cell); this sizes the page's canvas to the
	lowest visible card plus `BOTTOM_PADDING`, never shorter than the page itself. The
	cell keeps its shape through a `UIAspectRatioConstraint` driven by width, so growing
	the canvas never grows the cards. Sizes are read without the open animation's
	`UIScale`.

	This controller fills nothing: crates and runes are `CrateController`'s, skins are
	`SkinController`'s, nametags are `NametagBackpackController`'s.
]=]
local BackpackTabController = {
	Controllers = {
		CrateUIController = {},
		MusicController = {},
	},

	Signals = {
		-- (tab : string)
		TabChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

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

function BackpackTabController:_fit(page : ScrollingFrame)
	local shelf = page:FindFirstChild(GUI.Shelf)
	if not shelf or not shelf:IsA("GuiObject") or not page.Parent then
		return
	end

	local scale = cumulativeScale(page)
	if scale < 0.01 then
		return
	end

	local window = page.AbsoluteSize.Y / scale
	local cellHeight = shelf.AbsoluteSize.Y / scale
	if window <= 0 or cellHeight <= 0 then
		return
	end

	local bottom = 0
	for _, child in shelf:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			local height = child.Size.Y.Scale * cellHeight + child.Size.Y.Offset
			local top = child.Position.Y.Scale * cellHeight + child.Position.Y.Offset - child.AnchorPoint.Y * height
			bottom = math.max(bottom, top + height)
		end
	end

	local shelfTop = (shelf.AbsolutePosition.Y - page.AbsolutePosition.Y) / scale + page.CanvasPosition.Y
	local needed = math.ceil(math.max(window, shelfTop + bottom + cellHeight * BOTTOM_PADDING))

	local canvas = UDim2.fromOffset(0, needed)
	if page.CanvasSize ~= canvas then
		page.CanvasSize = canvas
	end
end

function BackpackTabController:_scheduleFit(page : ScrollingFrame)
	if self.FitQueued[page] then
		return
	end

	self.FitQueued[page] = true
	task.defer(function()
		self.FitQueued[page] = nil
		self:_fit(page)
	end)
end

function BackpackTabController:_watchPage(page : ScrollingFrame)
	page.AutomaticCanvasSize = Enum.AutomaticSize.None

	local shelf = page:FindFirstChild(GUI.Shelf)
	if not shelf then
		log:StudioWarn(`{page:GetFullName()} has no {GUI.Shelf}`)
		return
	end

	local function watchCard(child : Instance)
		if not child:IsA("GuiObject") then
			return
		end

		self.UiMaid:GiveTask(child:GetPropertyChangedSignal("Visible"):Connect(function()
			self:_scheduleFit(page)
		end))

		self.UiMaid:GiveTask(child:GetPropertyChangedSignal("Position"):Connect(function()
			self:_scheduleFit(page)
		end))
	end

	self.UiMaid:GiveTask(shelf.ChildAdded:Connect(function(child)
		watchCard(child)
		self:_scheduleFit(page)
	end))

	self.UiMaid:GiveTask(shelf.ChildRemoved:Connect(function()
		self:_scheduleFit(page)
	end))

	self.UiMaid:GiveTask(page:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_scheduleFit(page)
	end))

	for _, child in shelf:GetChildren() do
		watchCard(child)
	end

	self:_scheduleFit(page)
end

function BackpackTabController:_apply()
	for _, tab in TABS do
		local selected = tab.Button == self.Tab

		local page = self.Pages[tab.Button]
		if page then
			page.Visible = selected
			if selected then
				page.CanvasPosition = Vector2.zero
				self:_scheduleFit(page)
			end
		end

		local button = self.Buttons[tab.Button]
		if button then
			button.ImageColor3 = if selected then SELECTED_COLOR else IDLE_COLOR
		end
	end
end

function BackpackTabController:_bindUI(screenGui : ScreenGui)
	self.UiMaid:DoCleaning()
	table.clear(self.Pages)
	table.clear(self.Buttons)
	table.clear(self.FitQueued)
	self.Screen = screenGui

	local wrapper = screenGui:WaitForChild(GUI.Wrapper, WAIT_TIMEOUT)
	local panel = wrapper and wrapper:WaitForChild(GUI.Panel, WAIT_TIMEOUT)
	local content = panel and panel:WaitForChild(GUI.Content, WAIT_TIMEOUT)

	if self.Screen ~= screenGui then
		return
	end

	if not content then
		log:StudioWarn(`could not find {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.Content}`)
		return
	end

	for _, tab in TABS do
		local page = content:WaitForChild(tab.Page, WAIT_TIMEOUT)
		local button = panel:FindFirstChild(tab.Button)

		if page and page:IsA("ScrollingFrame") then
			self.Pages[tab.Button] = page
			self:_watchPage(page)
		else
			log:StudioWarn(`could not find page {tab.Page}`)
		end

		if button and button:IsA("GuiButton") then
			self.Buttons[tab.Button] = button
			button.AutoButtonColor = false

			self.UiMaid:GiveTask(button.Activated:Connect(function()
				self:SetTab(tab.Button)
			end))
		else
			log:StudioWarn(`could not find tab button {tab.Button}`)
		end
	end

	if self.Screen ~= screenGui then
		return
	end

	self.Tab = DEFAULT_TAB
	self:_apply()
end

function BackpackTabController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == GUI.ScreenGui then
			self:_bindUI(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

function BackpackTabController:GetTab() : string
	return self.Tab
end

function BackpackTabController:GetPage(tab : string) : ScrollingFrame?
	return self.Pages[tab]
end

--- Shows one tab's page. `silent` skips the click sound (used when the backpack opens).
function BackpackTabController:SetTab(tab : string, silent : boolean?)
	local known = false
	for _, entry in TABS do
		if entry.Button == tab then
			known = true
			break
		end
	end

	if not known then
		return
	end

	local changed = self.Tab ~= tab
	self.Tab = tab
	self:_apply()

	if not silent and changed then
		local music = self.Controllers.MusicController
		if music and music.PlaySFX then
			music:PlaySFX(CLICK_SOUND)
		end
	end

	if changed then
		self.Signals.TabChanged:Fire(tab)
	end
end

function BackpackTabController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()

	local crateUI = self.Controllers.CrateUIController
	if crateUI and crateUI.Signals and crateUI.Signals.OpenChanged then
		local connection = crateUI.Signals.OpenChanged:Connect(function(isOpen : boolean)
			if isOpen then
				self:SetTab(DEFAULT_TAB, true)
				for _, page in self.Pages do
					self:_scheduleFit(page)
				end
			end
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end
end

function BackpackTabController:init()
	self.Maid = Maid.new()

	-- Tab clicks and page watchers, per copy of `backpackui`.
	self.UiMaid = Maid.new()
	self.Maid:GiveTask(self.UiMaid)

	self.Screen = nil
	self.Tab = DEFAULT_TAB

	-- [tab] = ScrollingFrame / GuiButton
	self.Pages = {}
	self.Buttons = {}

	-- [page] = true while a fit is deferred
	self.FitQueued = {}
end

return BackpackTabController