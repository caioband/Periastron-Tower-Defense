local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Util:WaitForChild("Log"))
local Signal = require(Packages.Signal)

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local MarkerUtil = require(Util.MarkerUtil)
local ProximityPanel = require(Util.ProximityPanel)
local UIUtil = require(Util.UIUtil)

local RuneConfig = SharedConfig.RuneConfig

local Framework = Me.new()
local log = Log.new("RuneShopController")

local GUI = RuneConfig.Gui

--[[ CONSTANTS ]]

local CHARACTER_ROOT = "HumanoidRootPart"

-- The `InterfaceController` request. Its own name, so it never gives back the
-- screen another shop asked for.
local HIDE_REASON = "RuneShop"

--[=[
	The purchase sound, per currency, from `SoundService.BuySFX` like the crate shop.
	Keyed by the `Data.Stats` key; the folder names coins `Coins`.
]=]
local BUY_SOUNDS = {
	Shards = "Shards",
	Cash = "Coins",
}
local BUY_SOUND_KEY = "RuneShopBuy"

-- How often the active runes' countdown is rewritten while the shop is open.
local COUNTDOWN_INTERVAL = 1

--[=[
	The Lobby rune shop: `StarterGui.ShopUI.RuneShop`.

	Each rune has an authored frame in `Runes`, named after its `Id`. The arrows on
	`RuneDisplay` step through the tiers, and the frame shows the selected tier's
	icon, bonus and price. The `ActiveRunes` list on the side shows every active rune
	with its time left.

	**Buying stores, it does not activate.** The rune goes to the backpack, where
	`CrateController` lists it and activates it on click, so the Buy button is never
	blocked by an active tier.

	**This controller decides nothing.** The click sends "rune X, tier N", and
	`RuneShopService` charges and stores. What the screen shows comes from the
	profile replica (`Data.Runes`).

	**The countdown runs here.** The server only writes the time left every 30
	seconds (see `RuneService`), so the list counts down from the last write it
	received (`Baseline`). A rune that reaches zero leaves the list on the spot, and
	the server drops it from the profile on its next write.

	It opens by proximity to `Map.RunesShopPartReference`, like the other Lobby
	shops, and shares `ShopUI` with them (see `CanDisable` in `construct`).

	See docs/lobby/rune-shop.md.
]=]
local RuneShopController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},

		-- The other shops in the same `ScreenGui`, to know whether any is open before
		-- disabling it. See `CanDisable` in `construct`.
		ShopController = {},
		RoundCardShopController = {},
		RobuxShopController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),

		-- (id : string, tier : number)
		PurchaseRequested = Signal.new(),

		-- (id : string, tier : number, success : boolean, result : string?) -- `result`
		-- is `Stored` on success and the reason otherwise (UnknownRune, NotLoaded,
		-- BackpackFull, NotEnoughCurrency).
		PurchaseResult = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	The rune's record as of now: the replica's time left minus what passed since the
	replica last wrote `Runes`. Nil when it is not active.
]=]
function RuneShopController:_activeEntry(id : string) : { Tier : number, Remaining : number }?
	local replica = self.Replica
	local entry = RuneConfig.entryOf(replica and replica.Data.Runes, id)

	if not entry then
		return nil
	end

	entry.Remaining -= os.clock() - self.Baseline

	return if entry.Remaining > 0 then entry else nil
end

--- The tier on screen for a rune: the one the player picked, or the active one, or 1.
function RuneShopController:_selectedTier(id : string) : number
	local selected = self.Selected[id]
	if selected then
		return selected
	end

	local active = self:_activeEntry(id)
	return if active then active.Tier else 1
end

--- Steps the selected tier by `step`, wrapping around both ends.
function RuneShopController:_step(id : string, step : number)
	local rune = RuneConfig.Get(id)
	if not rune then
		return
	end

	local count = #rune.Tiers
	self.Selected[id] = (self:_selectedTier(id) - 1 + step) % count + 1

	self:_renderRune(id)
end

--- Writes a rune's frame: icon, name, tier, bonus line, and the buy button.
function RuneShopController:_renderRune(id : string)
	local row = self.Rows[id]
	local rune = RuneConfig.Get(id)

	if not row or not rune then
		return
	end

	local tier = self:_selectedTier(id)
	local definition = rune.Tiers[tier]

	if row.Display and definition.Image and definition.Image ~= "" then
		row.Display.Image = definition.Image
	end

	if row.Name then
		row.Name.Text = rune.DisplayName
	end

	if row.Tier then
		row.Tier.Text = string.format(RuneConfig.TIER_FORMAT, RuneConfig.tierName(tier))
	end

	if row.Description then
		row.Description.Text = string.format(
			RuneConfig.DESCRIPTION_FORMAT,
			math.floor(definition.Bonus * 100 + 0.5),
			rune.Effect,
			RuneConfig.formatDuration(RuneConfig.DURATION)
		)
	end

	local currency = RuneConfig.CURRENCIES[RuneConfig.currencyOf(rune)]

	if row.BuyLabel then
		row.BuyLabel.Text = string.format(RuneConfig.PRICE_FORMAT, UIUtil.formatCommas(definition.Price), currency.Name)

		-- The outline carries the currency's color, as on the crate shop's buttons.
		local stroke = row.BuyLabel:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Color = currency.Color
		end
	end

	if row.Buy then
		row.Buy.Active = true
		row.Buy.AutoButtonColor = true
	end
end

--[=[
	Rebuilds the `ActiveRunes` list: one row per active rune, in catalog order, or a
	single `EMPTY_TEXT` row when there is none. The labels are kept so the countdown
	only rewrites text (`_tick`).
]=]
function RuneShopController:_renderActive()
	self.ActiveMaid:DoCleaning()
	self.ActiveLabels = {}

	local list = self.ActiveList
	local template = self.ActiveTemplate

	if not list or not template then
		return
	end

	local function addRow(order : number) : TextLabel?
		local row = template:Clone()
		row.LayoutOrder = order
		row.Parent = list
		self.ActiveMaid:GiveTask(row)

		local label = row:FindFirstChild(GUI.ActiveText, true)
		return if label and label:IsA("TextLabel") then label else nil
	end

	for index, rune in RuneConfig.Runes do
		if not self:_activeEntry(rune.Id) then
			continue
		end

		local label = addRow(index)
		if label then
			self.ActiveLabels[rune.Id] = label
		end
	end

	if next(self.ActiveLabels) == nil then
		local label = addRow(0)
		if label then
			label.Text = RuneConfig.EMPTY_TEXT
		end
	end

	self:_tick()
end

--[=[
	Rewrites the time left on each active row. A rune that just ran out redraws
	everything: it leaves the list.
]=]
function RuneShopController:_tick()
	for id, label in self.ActiveLabels do
		local rune = RuneConfig.Get(id)
		local entry = self:_activeEntry(id)

		if not entry or not rune then
			self:_refresh()
			return
		end

		label.Text = string.format(
			RuneConfig.ACTIVE_FORMAT,
			rune.DisplayName,
			RuneConfig.tierName(entry.Tier),
			RuneConfig.formatCountdown(entry.Remaining)
		)
	end
end

function RuneShopController:_refresh()
	for id in self.Rows do
		self:_renderRune(id)
	end

	self:_renderActive()
end

function RuneShopController:_requestPurchase(id : string)
	local tier = self:_selectedTier(id)

	self.Signals.PurchaseRequested:Fire(id, tier)
	Framework:Fire("RequestBuyRune", id, tier)
end

--- Hooks one rune's authored frame. A rune without a frame is not sold, with a warning.
function RuneShopController:_bindRune(panel : GuiObject, rune, maid)
	local frame = panel:FindFirstChild(rune.Id)
	if not frame then
		log:StudioWarn(`no {rune.Id} frame in {GUI.Wrapper}.{GUI.Panel}; that rune is not on sale.`)
		return
	end

	local display = frame:FindFirstChild(GUI.Display)

	local function find(parent : Instance?, name : string, class : string) : any
		local child = parent and parent:FindFirstChild(name)
		return if child and child:IsA(class) then child else nil
	end

	local buy = find(frame, GUI.Buy, "GuiButton")

	local row = {
		Display = find(frame, GUI.Display, "ImageLabel"),
		Name = find(display, GUI.Name, "TextLabel"),
		Tier = find(display, GUI.Tier, "TextLabel"),
		Description = find(frame, GUI.Description, "TextLabel"),
		Buy = buy,
		BuyLabel = find(buy, GUI.BuyLabel, "TextLabel"),
	}

	self.Rows[rune.Id] = row

	local previous = find(display, GUI.Previous, "GuiButton")
	local nextButton = find(display, GUI.Next, "GuiButton")

	if previous then
		maid:GiveTask(previous.Activated:Connect(function()
			self:_step(rune.Id, -1)
		end))
		ButtonUtil.bindFeedback(previous, maid)
	end

	if nextButton then
		maid:GiveTask(nextButton.Activated:Connect(function()
			self:_step(rune.Id, 1)
		end))
		ButtonUtil.bindFeedback(nextButton, maid)
	end

	if buy then
		maid:GiveTask(buy.Activated:Connect(function()
			self:_requestPurchase(rune.Id)
		end))
		ButtonUtil.bindFeedback(buy, maid)
	else
		log:StudioWarn(`the {rune.Id} rune has no {GUI.Buy} button.`)
	end
end

--[=[
	The shop's content on a new copy of `ShopUI` (it is `ResetOnSpawn`). The panel
	itself (frame, animation, blur, X, screen request) belongs to `ProximityPanel`.
]=]
function RuneShopController:_onBind(wrapper : GuiObject, panel : GuiObject, maid : any)
	self.Rows = {}
	self.ActiveMaid:DoCleaning()
	self.ActiveLabels = {}

	for _, rune in RuneConfig.Runes do
		self:_bindRune(panel, rune, maid)
	end

	--[[
		The authored row is the template: cloned once and destroyed, or it would stay
		in the list as an extra row with the designer's sample text.
	]]
	local list = wrapper:FindFirstChild(GUI.ActiveList)
	local authored = list and list:FindFirstChild(GUI.ActiveRow)

	if authored and authored:IsA("GuiObject") then
		self.ActiveList = list
		self.ActiveTemplate = authored:Clone()
		authored:Destroy()
	else
		self.ActiveList = nil
		self.ActiveTemplate = nil
		log:StudioWarn(`could not find {GUI.Wrapper}.{GUI.ActiveList}.{GUI.ActiveRow}; the shop opens without the active list.`)
	end

	self:_refresh()
end

--[=[
	Follows the replica's `Runes`. Every write restarts the local countdown from the
	time left the server just wrote.
]=]
function RuneShopController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica
		self.Baseline = os.clock()

		self:_refresh()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= "Runes" then
				return
			end

			self.Baseline = os.clock()
			self:_refresh()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

function RuneShopController:_watchCountdown()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.CountdownClock += deltaTime

		if self.CountdownClock < COUNTDOWN_INTERVAL then
			return
		end

		self.CountdownClock = 0

		-- Nobody reads the list with the shop closed; `BeforeOpen` catches it up.
		if self:IsOpen() then
			self:_tick()
		end
	end))
end

function RuneShopController:_getMapPart(partName : string) : Instance?
	return MarkerUtil.find(
		RuneConfig.REFERENCE_PARENT_NAME,
		partName,
		self.MapParts,
		self.WarnedMissing,
		"RuneShopController"
	)
end

--[[ EXTERNAL ]]

--- Where the shop is, for anyone who needs to measure against the same center as proximity.
function RuneShopController:GetReferencePosition() : Vector3?
	local pivot = MarkerUtil.pivotOf(self:_getMapPart(RuneConfig.REFERENCE_PART_NAME))

	return pivot and pivot.Position or nil
end

function RuneShopController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function RuneShopController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function RuneShopController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function RuneShopController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

--[=[
	Drops the player on `RunesShopPartTeleport`, next to the shop. The landing is
	outside `OPEN_RADIUS`, so this opens the panel by hand through `EnterRange`, which
	also marks the entry: walking away then closes it like any other visit.

	Nothing calls it yet; it is here for a HUD button.
]=]
function RuneShopController:TeleportToShop() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)

	if not root then
		return false
	end

	local part = self:_getMapPart(RuneConfig.TELEPORT_PART_NAME)
	local pivot = MarkerUtil.pivotOf(part)

	if not pivot then
		return false
	end

	local halfHeight = MarkerUtil.halfHeightOf(part)

	character:PivotTo(pivot * CFrame.new(0, halfHeight + RuneConfig.TELEPORT_HEIGHT_OFFSET, 0))
	root.AssemblyLinearVelocity = Vector3.zero

	if self.Proximity then
		self.Proximity:EnterRange()
	end

	return true
end

function RuneShopController:construct()
	Framework:Listen("RunePurchaseResult", function(id : string, tier : number, success : boolean, result : string?)
		local rune = RuneConfig.Get(id)

		if success and rune then
			local music = self.Controllers.MusicController
			local sound = BUY_SOUNDS[RuneConfig.currencyOf(rune)]

			if music and sound then
				music:PlaySFX(sound, { Key = BUY_SOUND_KEY })
			end
		end

		self.Signals.PurchaseResult:Fire(id, tier, success, result)
	end)

	local music = self.Controllers.MusicController
	if music then
		local sounds = {}
		for _, rune in RuneConfig.Runes do
			local sound = BUY_SOUNDS[RuneConfig.currencyOf(rune)]
			if sound and not table.find(sounds, sound) then
				table.insert(sounds, sound)
			end
		end

		music:PreloadSFX(sounds)
	end

	self.Proximity = ProximityPanel.new({
		Name = "RuneShopController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = RuneConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		GetReference = function()
			return self:GetReferencePosition()
		end,
		Radius = RuneConfig.OPEN_RADIUS,
		Interval = RuneConfig.PROXIMITY_INTERVAL,
		InterfaceController = self.Controllers.InterfaceController,

		-- `ShopUI` is shared with the other shops: closing this one with another open
		-- must not disable the ScreenGui under it.
		CanDisable = function()
			for _, name in { "ShopController", "RoundCardShopController", "RobuxShopController" } do
				local shop = self.Controllers[name]
				if shop and shop:IsOpen() then
					return false
				end
			end

			return true
		end,

		OnBind = function(_screenGui, wrapper, panel, maid)
			self:_onBind(wrapper, panel, maid)
		end,

		-- The countdown only ticks while open, so opening catches it up.
		BeforeOpen = function()
			self:_refresh()
		end,
	})

	local openChanged = self.Proximity.Signals.OpenChanged:Connect(function(isOpen : boolean)
		self.Signals.OpenChanged:Fire(isOpen)
	end)

	self.Maid:GiveTask(function()
		openChanged:Disconnect()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_watchProfile()
	self:_watchCountdown()
end

function RuneShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function RuneShopController:init()
	self.Maid = Maid.new()

	-- The active list's rows, rebuilt by `_renderActive`.
	self.ActiveMaid = Maid.new()
	self.Maid:GiveTask(self.ActiveMaid)

	self.Proximity = nil
	self.Replica = nil

	-- `os.clock()` of the replica's last `Runes` write: the local countdown's zero.
	self.Baseline = os.clock()

	-- [Id] = the tier on screen, once the player picked one with the arrows.
	self.Selected = {}

	-- [Id] = the icon, labels and button of the rune's frame, per `ShopUI` copy.
	self.Rows = {}

	self.ActiveList = nil
	self.ActiveTemplate = nil

	-- [Id] = the active row's label, rewritten by `_tick`.
	self.ActiveLabels = {}

	self.MapParts = {}
	self.WarnedMissing = {}

	self.CountdownClock = 0
end

return RuneShopController