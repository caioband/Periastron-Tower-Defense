local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Utils.UIUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Signal = require(Packages.Signal)

local CrateConfig = SharedConfig.CrateConfig
local RuneConfig = SharedConfig.RuneConfig

local Framework = Me.new()
local log = Log.new("CrateController")

--[[ CONSTANTS ]]
local GUI = {
	ScreenGui = "backpackui",
	Wrapper = "Frame",
	Panel = "Backpack",
	Content = "Content",
	CratesPage = "CratesPage",
	RunesPage = "RunesPage",
	Shelf = "CrateWrapper",

	Bulk = "BulkOpen",
	BulkPreview = "Preview",
	BulkImage = "CrateImg",
	BulkName = "CrateName",
	BulkAmount = "CrateAmount",
	BulkLabel = "Label",
	BulkButtons = { "OpenOne", "OpenMid", "OpenMax" },
}

local ENTRY_NAME_PREFIX = "Crate_"
local RUNE_ENTRY_PREFIX = "Rune_"
local TEMPLATE_NAME = "cratetemplate"
local WAIT_TIMEOUT = 10

-- Crates the player does not own are hidden. Set to false to always show every rarity.
local HIDE_EMPTY_CRATES = true

-- Runes sort after every crate (kept for anything reading LayoutOrder).
local RUNE_LAYOUT_OFFSET = 1000

-- Horizontal gap between entries, as a fraction of one entry's width.
-- Only used when CrateWrapper has no UIListLayout / UIGridLayout of its own.
local ENTRY_PADDING_SCALE = 0.1

-- Vertical gap between rows, as a fraction of one entry's height.
local ROW_GAP_SCALE = 0.12

-- Entries per row before wrapping: what fits inside the backpack.
local ENTRIES_PER_ROW = 3

local GAIN_POP_SCALE = 1.15
local GAIN_POP_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GAIN_RETURN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- The icon tint of a rune that cannot be activated while a higher tier is active.
local BLOCKED_COLOR = Color3.fromRGB(110, 110, 110)
local READY_COLOR = Color3.new(1, 1, 1)

-- How often blocked runes are rechecked, so one unlocks when the higher tier runs out.
local BLOCKED_CHECK_INTERVAL = 1

-- The server is the one that spends the crate or rune; this only stops a burst of
-- requests from going out while the first one is still in flight.
local REQUEST_COOLDOWN = 0.5

-- The bulk panel's middle and bottom buttons. Below a step the player owns, that
-- button becomes "OPEN REST" (everything left), or hides when the rest is already
-- covered by the button above it.
local BULK_MID = 15
local BULK_MAX = 30

-- How long the "OPENED x / BEST: y" line stays in the bulk preview.
local BULK_SUMMARY_HOLD = 4

--[=[
	The backpack's Crates and Runes tabs. Crates go on
	`backpackui.Frame.Backpack.Content.CratesPage.CrateWrapper`, one entry per rarity
	the player owns; runes go on `...RunesPage.CrateWrapper`, one entry per unused rune
	tier (`Inventory.Runes`). Both are cloned from their page's `cratetemplate` and laid
	out from the top of their own page.

	Clicking a crate selects it and shows `Backpack.BulkOpen` on the right: OPEN 1,
	OPEN 15 and OPEN 30, with the last step the player cannot afford turning into
	OPEN REST. While the crate tutorial runs, clicking a crate opens one straight away
	instead, which is the click that tutorial waits for. The panel hides when the
	Crates page or the backpack closes, or when the selected crate runs out.

	Clicking a rune activates it (`RuneShopService`). A rune whose lower tier cannot
	start while a higher one is active is dimmed and says `HIGHER ACTIVE`; the server
	checks the same rule (`RuneConfig.purchaseAction`). Which page is on screen is
	`BackpackTabController`'s.
]=]
local CrateController = {
	Controllers = {
		DataController = {},
	},

	Signals = {
		-- (rarity : string, gained : number, total : number)
		CrateGained = Signal.new(),

		-- (id : string, tier : number, gained : number, total : number)
		RuneGained = Signal.new(),

		-- (id : string, tier : number, success : boolean, result : string?) -- `result`
		-- is the action on success (New, Extend, Upgrade) and the reason otherwise
		-- (UnknownRune, NotLoaded, LowerTier, NotOwned).
		RuneActivateResult = Signal.new(),

		-- (rarity : string?) -- nil when the selection clears.
		CrateSelected = Signal.new(),

		-- (rarity : string, summary : { Opened : number, Rarities : { [string] : number }, Units : { [string] : number } }, best : any)
		BulkOpened = Signal.new(),
	},
}

--[[ INTERNAL ]]

local function getCratesFromData(data) : { [string]: number }
	local inventory = data and data.Inventory
	local crates = inventory and inventory.Crates

	return crates or CrateConfig.createEmptyCrates()
end

function CrateController:_data() : any
	local replica = self.Replica
	return replica and replica.Data or nil
end

--[=[
	A rune's active record as of now: the replica's time left minus what passed since
	the replica last wrote `Runes`. Nil when it is not active.
]=]
function CrateController:_activeRune(id : string) : { Tier : number, Remaining : number }?
	local data = self:_data()
	local entry = RuneConfig.entryOf(data and data.Runes, id)

	if not entry then
		return nil
	end

	entry.Remaining -= os.clock() - self.RunesBaseline

	return if entry.Remaining > 0 then entry else nil
end

local function addScale(entry : Instance)
	local scale = Instance.new("UIScale")
	scale.Name = "CrateScale"
	scale.Parent = entry
end

--- Whether the post-match crate tutorial is running: its step waits for a crate click to open one.
local function tutorialRunning() : boolean
	local tutorial = Framework:Get("TutorialShopController", false, false)
	return tutorial ~= nil and tutorial.IsRunning ~= nil and tutorial:IsRunning() == true
end

--[=[
	Rebuilds one crate entry per rarity on the Crates page and one rune entry per tier
	on the Runes page, each cloned from its page's `cratetemplate`. The templates stay
	hidden so the designer can keep editing them.
]=]
function CrateController:_buildEntries(crateWrapper : Instance, crateTemplate : GuiObject, runeWrapper : Instance, runeTemplate : GuiObject)
	self.Entries = {}
	self.RuneEntries = {}

	for _, rarity in CrateConfig.getOrderedRarities() do
		local entry = crateTemplate:Clone()
		entry.Name = ENTRY_NAME_PREFIX .. rarity
		entry.Visible = false
		entry.LayoutOrder = CrateConfig.CRATES[rarity].Order or 0

		addScale(entry)

		-- cratetemplate is an ImageButton: each entry is what the player clicks to pick
		-- that rarity in the bulk panel.
		if entry:IsA("GuiButton") then
			self.UiMaid:GiveTask(entry.Activated:Connect(function()
				self:_onEntryClicked(rarity)
			end))
		end

		entry.Parent = crateWrapper

		self.Entries[rarity] = entry
		self.UiMaid:GiveTask(entry)
	end

	local order = 0

	for _, rune in RuneConfig.Runes do
		for tier in rune.Tiers do
			order += 1

			local id = rune.Id
			local entry = runeTemplate:Clone()
			entry.Name = `{RUNE_ENTRY_PREFIX}{id}_{tier}`
			entry.Visible = false
			entry.LayoutOrder = RUNE_LAYOUT_OFFSET + order

			addScale(entry)

			if entry:IsA("GuiButton") then
				self.UiMaid:GiveTask(entry.Activated:Connect(function()
					self:RequestActivateRune(id, tier)
				end))
			end

			entry.Parent = runeWrapper

			self.RuneEntries[RuneConfig.itemKey(id, tier)] = entry
			self.UiMaid:GiveTask(entry)
		end
	end
end

function CrateController:_onEntryClicked(rarity : string)
	if tutorialRunning() then
		self:RequestOpen(rarity)
		return
	end

	self:Select(rarity)
end

function CrateController:_playGainEffect(entry : Instance)
	local scale = entry:FindFirstChild("CrateScale")
	if not scale then
		return
	end

	local popTween = TweenService:Create(scale, GAIN_POP_INFO, { Scale = GAIN_POP_SCALE })
	popTween.Completed:Once(function()
		if scale.Parent then
			TweenService:Create(scale, GAIN_RETURN_INFO, { Scale = 1 }):Play()
		end
	end)
	popTween:Play()
end

--- Puts an entry on its page's grid: `index` is its place on the page (1-based).
local function placeOnGrid(entry : GuiObject, index : number)
	local column = (index - 1) % ENTRIES_PER_ROW
	local row = (index - 1) // ENTRIES_PER_ROW

	entry.Position = UDim2.fromScale(
		column * (1 + ENTRY_PADDING_SCALE),
		row * (1 + ROW_GAP_SCALE)
	)
end

--[=[
	Writes the crate and rune amounts into the UI, each from the top of its own page.
	Entries gained since the last refresh get a small pop, and CrateGained / RuneGained
	fire for anything the player just received.
]=]
function CrateController:_render()
	if not self.Entries or not self.RuneEntries then
		return
	end

	local crateWrapper, runeWrapper = self.Wrapper, self.RuneWrapper
	if not crateWrapper or not crateWrapper.Parent or not runeWrapper or not runeWrapper.Parent then
		return
	end

	local data = self:_data()
	local crates = getCratesFromData(data)
	local inventory = data and data.Inventory

	-- Respect a layout the designer added to a CrateWrapper; otherwise lay the entries
	-- out ourselves as a grid.
	local crateHasLayout = crateWrapper:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
	local runeHasLayout = runeWrapper:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
	local crateCount = 0

	for _, rarity in CrateConfig.getOrderedRarities() do
		local entry = self.Entries[rarity]
		local info = CrateConfig.CRATES[rarity]
		if not entry or not info then
			continue
		end

		local amount = crates[rarity] or 0
		local previousAmount = self.Cache[rarity]

		local shouldShow = (not HIDE_EMPTY_CRATES) or amount > 0
		entry.Visible = shouldShow

		if shouldShow then
			crateCount += 1

			if not crateHasLayout then
				placeOnGrid(entry, crateCount)
			end

			local nameLabel = entry:FindFirstChild("cratename")
			if nameLabel and nameLabel:IsA("TextLabel") then
				nameLabel.Text = info.DisplayName or rarity
			end

			local amountLabel = entry:FindFirstChild("crateamount")
			if amountLabel and amountLabel:IsA("TextLabel") then
				amountLabel.Text = string.format("%sx", UIUtil.formatAbbreviated(amount))
			end

			local imageLabel = entry:FindFirstChild("crateimg")
			if imageLabel and imageLabel:IsA("ImageLabel") and info.Image and info.Image ~= "" then
				imageLabel.Image = info.Image
			end
		end

		-- previousAmount is nil on the very first render, so joining with crates
		-- already in the profile does not fire as a "gain".
		if previousAmount ~= nil and amount > previousAmount then
			if shouldShow then
				self:_playGainEffect(entry)
			end

			self.Signals.CrateGained:Fire(rarity, amount - previousAmount, amount)
		end

		self.Cache[rarity] = amount
	end

	local runeCount = 0
	local hasBlocked = false

	for _, rune in RuneConfig.Runes do
		for tier, definition in rune.Tiers do
			local key = RuneConfig.itemKey(rune.Id, tier)
			local entry = self.RuneEntries[key]
			if not entry then
				continue
			end

			local amount = RuneConfig.itemCount(inventory, rune.Id, tier)
			local previousAmount = self.RuneCache[key]

			local shouldShow = amount > 0
			entry.Visible = shouldShow

			if shouldShow then
				runeCount += 1

				if not runeHasLayout then
					placeOnGrid(entry, runeCount)
				end

				local allowed = RuneConfig.purchaseAction(self:_activeRune(rune.Id), tier) ~= nil
				if not allowed then
					hasBlocked = true
				end

				local nameLabel = entry:FindFirstChild("cratename")
				if nameLabel and nameLabel:IsA("TextLabel") then
					nameLabel.Text = string.format(RuneConfig.ITEM_NAME_FORMAT, rune.DisplayName, RuneConfig.tierName(tier))
				end

				local amountLabel = entry:FindFirstChild("crateamount")
				if amountLabel and amountLabel:IsA("TextLabel") then
					amountLabel.Text = if allowed
						then string.format("%sx", UIUtil.formatAbbreviated(amount))
						else RuneConfig.BLOCKED_TEXT
				end

				local imageLabel = entry:FindFirstChild("crateimg")
				if imageLabel and imageLabel:IsA("ImageLabel") then
					if definition.Image and definition.Image ~= "" then
						imageLabel.Image = definition.Image
					end

					imageLabel.ImageColor3 = if allowed then READY_COLOR else BLOCKED_COLOR
				end

				if entry:IsA("GuiButton") then
					entry.AutoButtonColor = allowed
				end
			end

			if previousAmount ~= nil and amount > previousAmount then
				if shouldShow then
					self:_playGainEffect(entry)
				end

				self.Signals.RuneGained:Fire(rune.Id, tier, amount - previousAmount, amount)
			end

			self.RuneCache[key] = amount
		end
	end

	self.HasBlocked = hasBlocked

	self:_renderBulk()
end

--[[ BULK PANEL ]]

local function setLabel(button : GuiObject, text : string)
	local label = button:FindFirstChild(GUI.BulkLabel)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

--[=[
	What each bulk button opens for `amount` owned crates: { count, text } per slot,
	or nil for a hidden slot.

	  - slot 1: always OPEN 1;
	  - slot 2: OPEN 15 once they own 15, otherwise OPEN REST (when more than one);
	  - slot 3: OPEN 30 once they own 30, otherwise OPEN REST (only when the rest is
	    more than slot 2 already opens).
]=]
local function bulkSlots(amount : number) : { { Count : number, Text : string }? }
	local slots = {}

	slots[1] = if amount >= 1 then { Count = 1, Text = "OPEN 1" } else nil

	if amount >= BULK_MID then
		slots[2] = { Count = BULK_MID, Text = `OPEN {BULK_MID}` }
	elseif amount > 1 then
		slots[2] = { Count = amount, Text = "OPEN REST" }
	end

	if amount >= BULK_MAX then
		slots[3] = { Count = BULK_MAX, Text = `OPEN {BULK_MAX}` }
	elseif amount > BULK_MID then
		slots[3] = { Count = amount, Text = "OPEN REST" }
	end

	return slots
end

--[=[
	Binds the bulk panel of a new backpackui copy. The panel and its buttons are
	optional: without them, clicking a crate only selects it.
]=]
function CrateController:_bindBulk(frame : GuiObject, panel : Instance, cratesPage : GuiObject?)
	self.Bulk = nil

	local bulk = panel:WaitForChild(GUI.Bulk, WAIT_TIMEOUT)
	if not bulk or not bulk:IsA("GuiObject") then
		log:StudioWarn(`could not find {GUI.Panel}.{GUI.Bulk}`)
		return
	end

	local preview = bulk:FindFirstChild(GUI.BulkPreview)

	local state = {
		Panel = bulk,
		Image = preview and preview:FindFirstChild(GUI.BulkImage),
		Name = preview and preview:FindFirstChild(GUI.BulkName),
		Amount = preview and preview:FindFirstChild(GUI.BulkAmount),
		Buttons = {},
		Counts = {},
		CratesPage = cratesPage,
		Frame = frame,
	}

	for index, name in GUI.BulkButtons do
		local button = bulk:FindFirstChild(name)
		if not button or not button:IsA("GuiButton") then
			log:StudioWarn(`could not find {GUI.Bulk}.{name}`)
			continue
		end

		state.Buttons[index] = button

		self.UiMaid:GiveTask(button.Activated:Connect(function()
			local rarity = self.Selected
			local count = state.Counts[index]

			if rarity and count then
				self:RequestOpenMany(rarity, count)
			end
		end))
	end

	bulk.Visible = false
	self.Bulk = state

	local function onHidden()
		if not frame.Visible or (cratesPage and not cratesPage.Visible) then
			self:Select(nil)
		end
	end

	self.UiMaid:GiveTask(frame:GetPropertyChangedSignal("Visible"):Connect(onHidden))

	if cratesPage then
		self.UiMaid:GiveTask(cratesPage:GetPropertyChangedSignal("Visible"):Connect(onHidden))
	end
end

--[=[
	Paints the bulk panel for the selected crate: the preview and which buttons show.
	A selection whose crate ran out clears itself. While a bulk summary is up, the
	preview keeps it and only the buttons update.
]=]
function CrateController:_renderBulk()
	local state = self.Bulk
	if not state or not state.Panel.Parent then
		return
	end

	local rarity = self.Selected
	local amount = rarity and self:GetCrateAmount(rarity) or 0
	local pageShown = state.CratesPage == nil or state.CratesPage.Visible

	if not rarity or amount <= 0 or not pageShown then
		if rarity and amount <= 0 then
			self.Selected = nil
			self.Signals.CrateSelected:Fire(nil)
		end

		state.Panel.Visible = false
		return
	end

	local info = CrateConfig.CRATES[rarity]

	if os.clock() >= self.SummaryUntil then
		if state.Image and state.Image:IsA("ImageLabel") and info and info.Image and info.Image ~= "" then
			state.Image.Image = info.Image
		end

		if state.Name and state.Name:IsA("TextLabel") then
			state.Name.Text = string.upper((info and info.DisplayName) or rarity)
		end

		if state.Amount and state.Amount:IsA("TextLabel") then
			state.Amount.Text = string.format("%sx", UIUtil.formatAbbreviated(amount))
		end
	end

	local slots = bulkSlots(amount)

	for index, button in state.Buttons do
		local slot = slots[index]

		button.Visible = slot ~= nil
		state.Counts[index] = slot and slot.Count or nil

		if slot then
			setLabel(button, slot.Text)
		end
	end

	state.Panel.Visible = true
end

--- Shows the result of a bulk opening in the preview for `BULK_SUMMARY_HOLD` seconds.
function CrateController:_showBulkSummary(summary : any, best : any)
	local state = self.Bulk
	if not state then
		return
	end

	local opened = typeof(summary) == "table" and tonumber(summary.Opened) or 0
	local bestRarity = typeof(best) == "table" and best.Rarity or nil

	self.SummaryUntil = os.clock() + BULK_SUMMARY_HOLD
	local token = self.SummaryUntil

	if state.Name and state.Name:IsA("TextLabel") then
		state.Name.Text = `OPENED {opened}`
	end

	if state.Amount and state.Amount:IsA("TextLabel") then
		state.Amount.Text = if bestRarity then `BEST: {string.upper(tostring(bestRarity))}` else ""
	end

	task.delay(BULK_SUMMARY_HOLD, function()
		if self.SummaryUntil ~= token then
			return
		end

		self.SummaryUntil = 0
		self:_renderBulk()
	end)
end

local function findShelf(content : Instance, pageName : string) : (Instance?, GuiObject?)
	local page = content:WaitForChild(pageName, WAIT_TIMEOUT)
	local wrapper = page and page:WaitForChild(GUI.Shelf, WAIT_TIMEOUT)
	local template = wrapper and wrapper:WaitForChild(TEMPLATE_NAME, WAIT_TIMEOUT)

	if template and template:IsA("GuiObject") then
		return wrapper, template
	end

	return nil, nil
end

--[=[
	Binds to a backpackui instance. backpackui has ResetOnSpawn enabled, so this runs
	again for every fresh copy the engine parents into PlayerGui.
]=]
function CrateController:_bindUI(screenGui : ScreenGui)
	self.UiMaid:DoCleaning()
	self.Entries = nil
	self.RuneEntries = nil
	self.Wrapper = nil
	self.RuneWrapper = nil
	self.Bulk = nil
	self.Selected = nil
	self.SummaryUntil = 0

	local frame = screenGui:WaitForChild(GUI.Wrapper, WAIT_TIMEOUT)
	local panel = frame and frame:WaitForChild(GUI.Panel, WAIT_TIMEOUT)
	local content = panel and panel:WaitForChild(GUI.Content, WAIT_TIMEOUT)

	if not content then
		log:StudioWarn(`could not find {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.Content}`)
		return
	end

	local crateWrapper, crateTemplate = findShelf(content, GUI.CratesPage)
	local runeWrapper, runeTemplate = findShelf(content, GUI.RunesPage)

	if not crateWrapper or not crateTemplate then
		log:StudioWarn(`could not find {GUI.Content}.{GUI.CratesPage}.{GUI.Shelf}.{TEMPLATE_NAME}`)
		return
	end

	if not runeWrapper or not runeTemplate then
		log:StudioWarn(`could not find {GUI.Content}.{GUI.RunesPage}.{GUI.Shelf}.{TEMPLATE_NAME}`)
		return
	end

	crateTemplate.Visible = false
	runeTemplate.Visible = false

	self.Wrapper = crateWrapper
	self.RuneWrapper = runeWrapper
	self:_buildEntries(crateWrapper, crateTemplate, runeWrapper, runeTemplate)

	local cratesPage = content:FindFirstChild(GUI.CratesPage)
	self:_bindBulk(frame, panel, if cratesPage and cratesPage:IsA("GuiObject") then cratesPage else nil)

	-- Force a full repaint for the new UI instances.
	table.clear(self.Cache)
	table.clear(self.RuneCache)
	self:_render()
end

function CrateController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child.Name ~= GUI.ScreenGui or not child:IsA("ScreenGui") then
			return
		end

		self:_bindUI(child)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	local existing = playerGui:FindFirstChild(GUI.ScreenGui)
	if existing then
		task.spawn(onChild, existing)
	end
end

--- Redraws while some rune is blocked, so it unlocks the second the higher tier runs out.
function CrateController:_watchBlocked()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.BlockedClock += deltaTime

		if self.BlockedClock < BLOCKED_CHECK_INTERVAL then
			return
		end

		self.BlockedClock = 0

		if self.HasBlocked then
			self:_render()
		end
	end))
end

--[[ EXTERNAL ]]

--[=[
	Current crate amounts of the local player, straight from the replica.
]=]
function CrateController:GetCrates() : { [string]: number }
	return getCratesFromData(self:_data())
end

--[=[
	Picks the crate the bulk panel acts on, and shows the panel. `nil` clears the
	selection and hides it.
]=]
function CrateController:Select(rarity : string?)
	local resolved = rarity and CrateConfig.resolveRarity(rarity) or nil

	if resolved == self.Selected then
		self:_renderBulk()
		return
	end

	self.Selected = resolved
	self.SummaryUntil = 0

	self.Signals.CrateSelected:Fire(resolved)
	self:_renderBulk()
end

function CrateController:GetSelected() : string?
	return self.Selected
end

--[=[
	Asks the server to open one crate of a rarity.

	The Backpack panel stays open on purpose: the player can keep opening crates
	from it without reopening the panel after every unboxing.

	The amount check here is only to keep the UI from firing pointless requests -- the
	server reads the profile and is what actually spends the crate.
]=]
function CrateController:RequestOpen(rarity : string) : boolean
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		return false
	end

	if self:GetCrateAmount(resolvedRarity) <= 0 then
		return false
	end

	local now = os.clock()
	if now - self.LastRequest < REQUEST_COOLDOWN then
		return false
	end

	self.LastRequest = now

	Framework:Fire("RequestOpenCrate", resolvedRarity)

	return true
end

--[=[
	Asks the server to open `count` crates of a rarity at once (capped at what the
	player owns). One crate goes through the normal single opening.
]=]
function CrateController:RequestOpenMany(rarity : string, count : number) : boolean
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		return false
	end

	local owned = self:GetCrateAmount(resolvedRarity)
	count = math.min(math.floor(tonumber(count) or 0), owned)

	if count <= 0 then
		return false
	end

	if count == 1 then
		return self:RequestOpen(resolvedRarity)
	end

	local now = os.clock()
	if now - self.LastRequest < REQUEST_COOLDOWN then
		return false
	end

	self.LastRequest = now

	Framework:Fire("RequestOpenCrates", resolvedRarity, count)

	return true
end

function CrateController:GetCrateAmount(rarity : string) : number
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		return 0
	end

	return self:GetCrates()[resolvedRarity] or 0
end

--- How many unused runes of a tier the local player holds.
function CrateController:GetRuneAmount(id : string, tier : number) : number
	local data = self:_data()
	return RuneConfig.itemCount(data and data.Inventory, id, tier)
end

--[=[
	Asks the server to activate one unused rune. The checks here only keep the UI
	from firing pointless requests; the server spends and grants.
]=]
function CrateController:RequestActivateRune(id : string, tier : number) : boolean
	if not RuneConfig.getTier(id, tier) then
		return false
	end

	if self:GetRuneAmount(id, tier) <= 0 then
		return false
	end

	if not RuneConfig.purchaseAction(self:_activeRune(id), tier) then
		return false
	end

	local now = os.clock()
	if now - self.LastRequest < REQUEST_COOLDOWN then
		return false
	end

	self.LastRequest = now

	Framework:Fire("RequestActivateRune", id, tier)

	return true
end

function CrateController:construct()
	local DataController = self.Controllers.DataController
	local replica = DataController:GetReplica()

	self.Replica = replica
	self.RunesBaseline = os.clock()

	-- DataService writes whole keys, but listen through OnChange so any deeper write
	-- (Inventory.Crates, Inventory.Runes, ...) refreshes the UI too. `Runes` (the active
	-- ones) decides which rune entries are blocked.
	local connection = replica:OnChange(function(_action, path)
		local key = path[1]
		if key ~= nil and key ~= "Inventory" and key ~= "Runes" then
			return
		end

		if key == nil or key == "Runes" then
			self.RunesBaseline = os.clock()
		end

		self:_render()
	end)

	self.Maid:GiveTask(function()
		connection:Disconnect()
	end)

	Framework:Listen("RuneActivateResult", function(id : string, tier : number, success : boolean, result : string?)
		self.Signals.RuneActivateResult:Fire(id, tier, success, result)
	end)

	Framework:Listen("BulkUnboxResult", function(rarity : string, summary : any, best : any)
		if rarity == self.Selected then
			self:_showBulkSummary(summary, best)
		end

		self.Signals.BulkOpened:Fire(rarity, summary, best)
	end)

	self:_observeUI()
	self:_watchBlocked()
end

function CrateController:start()

end

function CrateController:init()
	self.Maid = Maid.new()
	self.UiMaid = Maid.new()
	self.Maid:GiveTask(self.UiMaid)

	self.Cache = {}
	self.RuneCache = {}
	self.Entries = nil
	self.RuneEntries = nil
	self.Wrapper = nil
	self.RuneWrapper = nil
	self.Replica = nil
	self.LastRequest = 0

	-- The bulk panel: its UI, the crate it acts on, and until when the preview holds a summary.
	self.Bulk = nil
	self.Selected = nil
	self.SummaryUntil = 0

	-- `os.clock()` of the replica's last `Runes` write: the local countdown's zero.
	self.RunesBaseline = os.clock()

	self.HasBlocked = false
	self.BlockedClock = 0

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CrateController