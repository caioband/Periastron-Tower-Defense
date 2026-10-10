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
local CRATE_UI_NAME = "crateui"
local ENTRY_NAME_PREFIX = "Crate_"
local RUNE_ENTRY_PREFIX = "Rune_"
local TEMPLATE_NAME = "cratetemplate"

-- Crates the player does not own are hidden. Set to false to always show every rarity.
local HIDE_EMPTY_CRATES = true

-- Runes come after every crate on the shelf.
local RUNE_LAYOUT_OFFSET = 1000

-- Horizontal gap between entries, as a fraction of one entry's width.
-- Only used when CrateWrapper has no UIListLayout / UIGridLayout of its own.
local ENTRY_PADDING_SCALE = 0.1

-- Vertical gap between rows, as a fraction of one entry's height.
local ROW_GAP_SCALE = 0.12

-- Entries per row before wrapping: what fits the panel before the scrollbar.
-- Crates fill their rows first; runes start on the row under the last crate.
local ENTRIES_PER_ROW = 5

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

--[=[
	The Backpack shelf (`crateui.Frame.Rectangle.scrollcrates.CrateWrapper`): one
	entry per crate rarity the player owns, then one per unused rune tier
	(`Inventory.Runes`) on the rows below, all cloned from `cratetemplate`.

	Clicking a crate opens it; clicking a rune activates it (`RuneShopService`). A
	rune whose lower tier cannot start while a higher one is active is dimmed and
	says `HIGHER ACTIVE`; the server checks the same rule (`RuneConfig.purchaseAction`).
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

--[=[
	Rebuilds one entry per rarity and one per rune tier inside CrateWrapper, using
	cratetemplate as the source. The template itself is kept hidden so the designer
	can keep editing it.
]=]
function CrateController:_buildEntries(wrapper : Instance, template : ImageButton)
	self.Entries = {}
	self.RuneEntries = {}

	for _, rarity in CrateConfig.getOrderedRarities() do
		local entry = template:Clone()
		entry.Name = ENTRY_NAME_PREFIX .. rarity
		entry.Visible = false
		entry.LayoutOrder = CrateConfig.CRATES[rarity].Order or 0

		addScale(entry)

		-- cratetemplate is an ImageButton: each entry is what the player clicks to open
		-- that rarity.
		if entry:IsA("GuiButton") then
			self.UiMaid:GiveTask(entry.Activated:Connect(function()
				self:RequestOpen(rarity)
			end))
		end

		entry.Parent = wrapper

		self.Entries[rarity] = entry
		self.UiMaid:GiveTask(entry)
	end

	local order = 0

	for _, rune in RuneConfig.Runes do
		for tier in rune.Tiers do
			order += 1

			local id = rune.Id
			local entry = template:Clone()
			entry.Name = `{RUNE_ENTRY_PREFIX}{id}_{tier}`
			entry.Visible = false
			entry.LayoutOrder = RUNE_LAYOUT_OFFSET + order

			addScale(entry)

			if entry:IsA("GuiButton") then
				self.UiMaid:GiveTask(entry.Activated:Connect(function()
					self:RequestActivateRune(id, tier)
				end))
			end

			entry.Parent = wrapper

			self.RuneEntries[RuneConfig.itemKey(id, tier)] = entry
			self.UiMaid:GiveTask(entry)
		end
	end
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

--- Puts an entry on the shelf grid: `index` is its place in its section (1-based),
--- `firstRow` the row that section starts on (0-based).
local function placeOnGrid(entry : GuiObject, index : number, firstRow : number)
	local column = (index - 1) % ENTRIES_PER_ROW
	local row = firstRow + (index - 1) // ENTRIES_PER_ROW

	entry.Position = UDim2.fromScale(
		column * (1 + ENTRY_PADDING_SCALE),
		row * (1 + ROW_GAP_SCALE)
	)
end

--[=[
	Writes the crate and rune amounts into the UI. Crates fill the top rows and runes
	start on the row under them. Entries gained since the last refresh get a small
	pop, and CrateGained / RuneGained fire for anything the player just received.
]=]
function CrateController:_render()
	if not self.Entries or not self.RuneEntries then
		return
	end

	local wrapper = self.Wrapper
	if not wrapper or not wrapper.Parent then
		return
	end

	local data = self:_data()
	local crates = getCratesFromData(data)
	local inventory = data and data.Inventory

	-- Respect a layout the designer added to CrateWrapper; otherwise lay the entries
	-- out ourselves as a grid, crates on top and runes underneath.
	local hasLayout = wrapper:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
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

			if not hasLayout then
				placeOnGrid(entry, crateCount, 0)
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

	-- The first row under the crates; row 0 when the player owns none.
	local runeFirstRow = math.ceil(crateCount / ENTRIES_PER_ROW)
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

				if not hasLayout then
					placeOnGrid(entry, runeCount, runeFirstRow)
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
end

--[=[
	Binds to a crateui instance. crateui has ResetOnSpawn enabled, so this runs again
	for every fresh copy the engine parents into PlayerGui.
]=]
function CrateController:_bindUI(screenGui : ScreenGui)
	self.UiMaid:DoCleaning()
	self.Entries = nil
	self.RuneEntries = nil
	self.Wrapper = nil

	local frame = screenGui:WaitForChild("Frame", 10)
	local rectangle = frame and frame:WaitForChild("Rectangle", 10)
	local scroll = rectangle and rectangle:WaitForChild("scrollcrates", 10)
	local wrapper = scroll and scroll:WaitForChild("CrateWrapper", 10)
	local template = wrapper and wrapper:WaitForChild(TEMPLATE_NAME, 10)

	if not template then
		log:StudioWarn(`could not find {CRATE_UI_NAME}.Frame.Rectangle.scrollcrates.CrateWrapper.{TEMPLATE_NAME}`)
		return
	end

	template.Visible = false

	self.Wrapper = wrapper
	self:_buildEntries(wrapper, template)

	-- Force a full repaint for the new UI instances.
	table.clear(self.Cache)
	table.clear(self.RuneCache)
	self:_render()
end

function CrateController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child.Name ~= CRATE_UI_NAME or not child:IsA("ScreenGui") then
			return
		end

		self:_bindUI(child)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	local existing = playerGui:FindFirstChild(CRATE_UI_NAME)
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
	self.Replica = nil
	self.LastRequest = 0

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