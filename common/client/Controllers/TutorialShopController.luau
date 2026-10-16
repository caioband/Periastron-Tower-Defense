local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Util:WaitForChild("Log"))
local ProximityPanel = require(Util:WaitForChild("ProximityPanel"))

local Framework = Me.new()
local log = Log.new("TutorialShopController")

local TutorialConfig = SharedConfig.TutorialConfig
local Config = TutorialConfig.Lobby

local WALK_IN_REASON = "TutorialShop"
local CRATE_HIGHLIGHT_NAME = "TutorialCrateHighlight"

local PHASE_SHOP = "shop"
local PHASE_CRATE = "crate"
local PHASE_LOADOUT = "loadout"

--[[
	The second half of the tutorial, in the Lobby, after the win.

	Every beat points at **the only clickable thing at that moment**:

		1. the congratulations dialog;
		2. the shop button;
		3. the Crate of Beginnings buy button, when the shop opens;
		4. the shop closes on its own, and stays closed for the rest of the flow;
		5. the backpack button;
		6. the first crate in the backpack, which selects it;
		7. the "OPEN 1" button of the bulk panel;
		8. the backpack closes on its own, and the crate in the world is highlighted
		   while it rolls and reveals the unit;
		9. the loadout button, the new unit's card, and the equip button;
		10. the farewell dialog.

	**Nothing outside the step is clickable.** `ButtonGateController` turns the rest
	off, the same one the match steps use: at each beat the whitelist is that beat's
	target (plus the dialog box, which is `TutorialConfig.ButtonGate.Always`).

	**Nothing opens by walking into it either.** Before the purchase only the panels in
	`Lobby.WalkInAllow` (the shop) open on walk-in; after it, none does, and a guard
	closes the shop the moment anything opens it, until the flow ends.

	The lock is on the buttons, and **not** on the highlight's `BlockInput`, on
	purpose: that one covers the screen with frames that swallow any input, including
	the drag that turns the camera. The lock leaves with the flow: when it ends, is
	interrupted, or the player dies, `finish` gives everything back.

	**The server starts it** (`TutorialShopPrompt`), and the server guarantees this
	crate's epic unit: the client asks for no rarity, so there is no way to forge one.

	It lives in `common/` because the highlight and the dialog box live there; the flow
	itself only exists in the Lobby, and that place's server triggers it.

	See docs/common/tutorial.md.
]]

local TutorialShopController = {
	Controllers = {
		DialogController = {},
		HighlightController = {},
		ButtonGateController = {},

		-- The screens the flow opens and closes. None of them is required: a place
		-- missing one simply does not have that step.
		ShopController = {},
		CrateUIController = {},
		CrateController = {},
		UnboxingController = {},
		DeckController = {},
	}
}

TutorialShopController.Running = false

-- One session per flow: each wait's `while` dies when another starts (or when the
-- flow is aborted), instead of running in the background.
TutorialShopController.Session = 0

-- What has already happened, so a respawn restarts from the right place.
TutorialShopController.Bought = false
TutorialShopController.Unboxed = false
TutorialShopController.Revealed = false
TutorialShopController.UnboxStarted = false
TutorialShopController.NewUnit = nil :: string?

-- The world crate of the running unboxing, and the highlight on it.
TutorialShopController.CrateModel = nil :: Model?
TutorialShopController.CrateHighlight = nil :: Highlight?

-- Bumped to stop the shop guard thread.
TutorialShopController.GuardSession = 0

-- How often a long wait announces itself in the output.
local REPORT_INTERVAL = 3

--[[ INTERNAL ]]

--[=[
	A sibling controller, looked up **at the time of use**.

	Everything cannot be resolved in `init`: `Me:Load` calls each module's `init`
	during the sweep, so modules loaded after this one do not exist yet, and a
	non-waiting lookup there returns `nil` forever.

	Waiting does not work either: half of these controllers are Lobby-only and do not
	exist in Game, and a waiting `Get` would hang forever there. Looking up late and
	caching what was found solves both cases.
]=]
function TutorialShopController:controller(name : string) : any
	local found = self.Controllers[name]

	if found and type(found) == "table" and next(found) ~= nil then
		return found
	end

	found = Framework:Get(name, false, false)

	if found then
		self.Controllers[name] = found
	end

	return found
end

--[=[
	Points at a target and leaves **only it** clickable.

	The lock is rebuilt on every beat of the flow, and that is what covers buttons
	that did not exist when the previous one started. The gate also reapplies itself
	when a new button arrives, so the order between "opened the screen" and "pointed
	at the target" does not matter.

	`nil` locks the whole screen and clears the highlight.

	The valve's deadline is the config's `StallRelease`, counted from here.
]=]
function TutorialShopController:point(target : GuiObject?)
	local gate = self:controller("ButtonGateController")

	if gate then
		local allow = {}

		if target then
			table.insert(allow, target)
		end

		for _, entry in (TutorialConfig.ButtonGate.Always or {}) do
			table.insert(allow, entry)
		end

		gate:Lock({
			Allow = allow,
			Ignore = TutorialConfig.ButtonGate.Ignore,
			Release = Config.StallRelease,
		})
	end

	local highlight = self:controller("HighlightController")
	if not highlight then return end

	if not target then
		highlight:Hide()

		return
	end

	highlight:Show(target)
end

--[=[
	Waits for a condition to become true, without exceeding the budget.

	Returns `false` when time runs out **or** when another flow started midway;
	callers treat both the same way: stop waiting and leave.
]=]
function TutorialShopController:await(session : number, timeout : number?, condition : () -> boolean, label : string?) : boolean
	local deadline = if timeout then os.clock() + timeout else nil
	local nextReport = os.clock() + REPORT_INTERVAL

	while self.Session == session and self.Running do
		if condition() then
			return true
		end

		if deadline and os.clock() > deadline then
			log:Debug(`gave up waiting: {label or "?"}`)

			return false
		end

		if label and os.clock() >= nextReport then
			nextReport = os.clock() + REPORT_INTERVAL

			log:Debug(`waiting: {label}`)
		end

		task.wait(Config.PollInterval)
	end

	return false
end

--[=[
	Whether the flow is still this session's.
]=]
function TutorialShopController:alive(session : number) : boolean
	return self.Session == session and self.Running
end

--[=[
	A dialog line, waiting for it to close before continuing.

	A dialog line that did not start must not **stop** the flow: its `OnClosed`
	never arrives, and the wait below has no deadline. Continuing without it is the
	lesser evil.
]=]
function TutorialShopController:say(session : number, lines : { string }?) : boolean
	local dialog = self:controller("DialogController")
	if not dialog or not lines or #lines == 0 then
		return self:alive(session)
	end

	local closed = false

	local disconnect
	disconnect = dialog:OnClosed(function()
		if disconnect then
			disconnect()
		end

		closed = true
	end)

	local playing = dialog:Play(lines, TutorialConfig.Speech({
		-- The HUD stays: the next step points at one of its buttons.
		HideUI = false,
		Blur = false,
		Duck = false,
		Auto = true,
	}))

	if not playing then
		if disconnect then
			disconnect()
		end

		log:StudioWarn("the dialog box did not open; continuing the flow without it.")

		return self:alive(session)
	end

	local finished = self:await(session, nil, function()
		return closed
	end)

	if disconnect then
		disconnect()
	end

	return finished
end

--[=[
	The same lines with `%s` filled in by `value`.
]=]
local function formatLines(lines : { string }?, value : string) : { string }?
	if not lines then
		return nil
	end

	local formatted = {}

	for _, line in lines do
		local ok, result = pcall(string.format, line, value)
		table.insert(formatted, if ok then result else line)
	end

	return formatted
end

--[=[
	Is this element **actually** on screen?

	Being on screen means the object visible **and** its whole ancestry visible, up to
	the `ScreenGui`, which in turn must be enabled. A button inside a closed panel
	still has `Visible = true`.
]=]
function TutorialShopController:onScreen(instance : GuiObject?) : boolean
	if not instance or not instance.Parent or not instance.Visible then
		return false
	end

	local current : Instance? = instance.Parent

	while current do
		if current:IsA("LayerCollector") then
			return current.Enabled
		end

		if current:IsA("GuiObject") and not current.Visible then
			return false
		end

		current = current.Parent
	end

	return false
end

--[=[
	A GUI element by its config path, or `nil`.
]=]
function TutorialShopController:find(path : string?) : GuiObject?
	if not path then
		return nil
	end

	local highlight = self:controller("HighlightController")
	local found = highlight and highlight:Find(path)

	return if found and found:IsA("GuiObject") then found else nil
end

--[=[
	The tutorial crate's buy button, inside the shop, looked up by the **item id**.
]=]
function TutorialShopController:buyButton() : GuiObject?
	local shop = PlayerGui:FindFirstChild("ShopUI")
	local container = shop and shop:FindFirstChild(Config.Item, true)
	local button = container and container:FindFirstChild(Config.BuyButton, true)

	return if button and button:IsA("GuiObject") then button else nil
end

--[=[
	The first crate in the backpack: the one the player just bought.

	"First" is the lowest `LayoutOrder`. Only visible buttons count (the template stays
	hidden), and `Active` does not count: the previous step's lock turns it off.
]=]
function TutorialShopController:firstCrate() : GuiObject?
	local list = self:find(Config.CrateList)
	if not list then
		return nil
	end

	local prefix = Config.CratePrefix
	local best, bestOrder = nil, math.huge
	local fallback, fallbackOrder = nil, math.huge

	for _, child in list:GetDescendants() do
		if not child:IsA("GuiButton") or not child.Visible then
			continue
		end

		local order = child.LayoutOrder

		if not prefix or string.sub(child.Name, 1, #prefix) == prefix then
			if order < bestOrder then
				best, bestOrder = child, order
			end
		elseif order < fallbackOrder then
			fallback, fallbackOrder = child, order
		end
	end

	return best or fallback
end

--[=[
	The "OPEN 1" button of the backpack's bulk panel.
]=]
function TutorialShopController:openOneButton() : GuiObject?
	return self:find(Config.OpenOneButton)
end

--[=[
	The new unit's card button in the loadout's inventory list.
]=]
function TutorialShopController:inventoryCard(unitName : string?) : GuiObject?
	if not unitName then
		return nil
	end

	local list = self:find(Config.InventoryList)
	local wrapper = list and list:FindFirstChild(unitName)
	if not wrapper then
		return nil
	end

	local card = wrapper:FindFirstChild("Card")
	local button = card and card:FindFirstChild("Button")

	if button and button:IsA("GuiObject") then
		return button
	end

	return if card and card:IsA("GuiObject") then card else nil
end

--[=[
	Scrolls the inventory list so the card is in view: the highlight on a card the
	list has clipped away would point at nothing.
]=]
function TutorialShopController:scrollTo(target : GuiObject?)
	local list = self:find(Config.InventoryList)
	if not target or not list or not list:IsA("ScrollingFrame") then
		return
	end

	local top = target.AbsolutePosition - list.AbsolutePosition
	local bottom = top + target.AbsoluteSize
	local window = list.AbsoluteWindowSize
	local canvas = list.CanvasPosition

	local x, y = canvas.X, canvas.Y

	if top.Y < 0 or bottom.Y > window.Y then
		y = math.max(0, canvas.Y + top.Y - (window.Y - target.AbsoluteSize.Y) / 2)
	end

	if top.X < 0 or bottom.X > window.X then
		x = math.max(0, canvas.X + top.X - (window.X - target.AbsoluteSize.X) / 2)
	end

	list.CanvasPosition = Vector2.new(x, y)
end

--[=[
	How many copies of a unit are in the equipped deck, whatever shape the deck has.
]=]
function TutorialShopController:equippedCount(unitName : string?) : number
	local deck = self:controller("DeckController")
	if not unitName or not deck or not deck._getEquipped then
		return 0
	end

	local ok, equipped = pcall(deck._getEquipped, deck)
	if not ok or type(equipped) ~= "table" then
		return 0
	end

	local count = 0

	for key, value in equipped do
		if value == unitName then
			count += 1
		elseif key == unitName and type(value) == "number" then
			count += value
		elseif type(value) == "table" and (value.Unit == unitName or value.Name == unitName) then
			count += 1
		end
	end

	return count
end

--[=[
	Waits for a button's click. Returns `true` on the click or when `other` says the
	step happened some other way.
]=]
function TutorialShopController:awaitClick(session : number, button : GuiObject?, other : (() -> boolean)?, label : string?) : boolean
	local clicked = false

	local connection = if button and button:IsA("GuiButton")
		then button.Activated:Connect(function()
			clicked = true
		end)
		else nil

	local done = self:await(session, nil, function()
		return clicked or (other ~= nil and other())
	end, label)

	if connection then
		connection:Disconnect()
	end

	return done
end

--[=[
	The world crate of this player's unboxing gets a highlight, so the eye goes to
	it the moment the backpack closes.
]=]
function TutorialShopController:highlightCrate(crate : Instance?)
	self:clearCrateHighlight()

	if not crate or not crate.Parent then
		return
	end

	local colors = Config.CrateHighlight or {}

	local highlight = Instance.new("Highlight")
	highlight.Name = CRATE_HIGHLIGHT_NAME
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = colors.Fill or Color3.fromRGB(255, 205, 60)
	highlight.OutlineColor = colors.Outline or Color3.new(1, 1, 1)
	highlight.FillTransparency = colors.FillTransparency or 0.55
	highlight.OutlineTransparency = 0
	highlight.Adornee = crate
	highlight.Parent = crate

	self.CrateHighlight = highlight
end

function TutorialShopController:clearCrateHighlight()
	if self.CrateHighlight then
		self.CrateHighlight:Destroy()
		self.CrateHighlight = nil
	end
end

--[=[
	After the purchase the shop is done with: it closes now, and closes again
	whenever anything opens it, until the flow ends. Walk-in opens nothing anymore.
]=]
function TutorialShopController:sealShop()
	ProximityPanel.UnlockWalkIn(WALK_IN_REASON)
	ProximityPanel.LockWalkIn(WALK_IN_REASON, {})

	local shop = self:controller("ShopController")
	if shop and shop:IsOpen() then
		shop:Close()
	end

	self.GuardSession += 1
	local guard = self.GuardSession

	task.spawn(function()
		while self.Running and self.GuardSession == guard do
			local current = self:controller("ShopController")

			if current and current:IsOpen() then
				current:Close()
			end

			task.wait(Config.PollInterval)
		end
	end)
end

--[=[
	Gives the screen back: no highlight, no lock, no shop guard.
]=]
function TutorialShopController:finish()
	self.Running = false
	self.GuardSession += 1

	ProximityPanel.UnlockWalkIn(WALK_IN_REASON)

	self:clearCrateHighlight()

	local gate = self:controller("ButtonGateController")
	if gate then
		gate:Unlock()
	end

	local highlight = self:controller("HighlightController")
	if highlight then
		highlight:Hide()
	end
end

--[=[
	The whole flow, top to bottom, entered at `phase`.

	It is split in three by what cannot be redone: the **purchase** and the
	**unboxing**. Dying in the Lobby destroys `HUD`, `ShopUI`, and the backpack (all
	have `ResetOnSpawn`), and the flow has to restart somewhere that does not ask for
	a second purchase or a second crate. See `onRespawn`.
]=]
function TutorialShopController:run(session : number, phase : string)
	if phase == PHASE_SHOP then
		if not self:runShop(session) then return end

		phase = PHASE_CRATE
	end

	if phase == PHASE_CRATE then
		if not self:runCrate(session) then return end

		phase = PHASE_LOADOUT
	end

	if phase == PHASE_LOADOUT then
		self:runLoadout(session)
	end
end

--[=[
	The dialog, the shop button, and the crate purchase.
]=]
function TutorialShopController:runShop(session : number) : boolean
	-- 1. the dialog
	if not self:say(session, Config.Lines) then return false end

	-- 2. the shop button, until it opens
	local shopButton = self:find(Config.ShopButton)
	log:Debug(`shop button = {shopButton and shopButton:GetFullName() or "NOT FOUND"}`)

	self:point(shopButton)

	if not self:await(session, nil, function()
		if self.Bought then
			return true
		end

		local shop = self:controller("ShopController")
		if shop and shop:IsOpen() then
			return true
		end

		return self:onScreen(self:buyButton())
	end, "the shop to open") then
		return false
	end

	-- 3. the buy button, until the purchase happens
	if not self.Bought then
		self:await(session, Config.WaitForUi, function()
			return self:buyButton() ~= nil
		end, "the buy button to appear")

		local buy = self:buyButton()
		log:Debug(`buy button = {buy and buy:GetFullName() or "NOT FOUND"}`)

		self:point(buy)

		if not self:await(session, nil, function()
			return self.Bought == true
		end, "the crate purchase") then
			return false
		end
	end

	return true
end

--[=[
	The shop closing for good, the backpack, the crate, "OPEN 1", and the unboxing.
]=]
function TutorialShopController:runCrate(session : number) : boolean
	-- 4. the shop closes and stays closed
	self:sealShop()

	if not self.UnboxStarted then
		-- 5. the backpack button, until it opens
		self:point(nil)

		if not self:say(session, Config.BackpackLines) then return false end

		self:point(self:find(Config.BackpackButton))

		if not self:await(session, nil, function()
			if self.UnboxStarted then
				return true
			end

			local backpack = self:controller("CrateUIController")
			if backpack and backpack:IsOpen() then
				return true
			end

			return self:onScreen(self:firstCrate())
		end, "the backpack to open") then
			return false
		end

		-- 6. the first crate, until it is selected and the bulk panel shows
		if not self.UnboxStarted then
			self:await(session, Config.WaitForUi, function()
				return self:firstCrate() ~= nil
			end, "the first crate to appear in the backpack")

			local crate = self:firstCrate()
			log:Debug(`crate = {crate and crate.Name or "NONE"}`)

			self:point(crate)

			if not self:awaitClick(session, crate, function()
				return self.UnboxStarted or self:onScreen(self:openOneButton())
			end, "the click on the crate") then
				return false
			end
		end

		-- 7. "OPEN 1", until the unboxing starts
		if not self.UnboxStarted then
			self:await(session, Config.WaitForUi, function()
				return self.UnboxStarted or self:onScreen(self:openOneButton())
			end, "the OPEN 1 button to appear")

			local openOne = self:openOneButton()
			log:Debug(`open one = {openOne and openOne:GetFullName() or "NOT FOUND"}`)

			self:point(openOne)

			local clicked = self:awaitClick(session, openOne, function()
				return self.UnboxStarted
			end, "the click on OPEN 1")

			if not clicked then
				return false
			end
		end
	end

	-- 8. the backpack gets out of the way; the screen stays locked until the reveal
	self:point(nil)

	local backpack = self:controller("CrateUIController")
	if backpack and backpack:IsOpen() then
		backpack:Close()
	end

	if self.CrateModel and not self.CrateHighlight then
		self:highlightCrate(self.CrateModel)
	end

	if not self:await(session, nil, function()
		return self.Unboxed == true
	end, "the unboxing to finish") then
		return false
	end

	-- The onboarding funnel's last step: sent here, not from `finish`, which also runs
	-- when the flow aborts. The server checks the player really is in the tutorial.
	if not self.FinishSent then
		self.FinishSent = true
		Framework:Fire("TutorialShopFinished")
	end

	-- The reveal: the unit comes out of the crate. A missing signal does not stall it.
	self:await(session, 8, function()
		return self.Revealed == true
	end, "the unit reveal")

	task.wait(Config.RevealHold or 0)

	return self:alive(session)
end

--[=[
	The loadout button, the new unit's card, the equip button, and the farewell.
]=]
function TutorialShopController:runLoadout(session : number)
	self:clearCrateHighlight()

	local unitName = self.NewUnit

	-- 9. the loadout
	local lines = if unitName then formatLines(Config.LoadoutLines, unitName) else nil

	self:point(nil)

	if not self:say(session, lines) then return end

	local deck = self:controller("DeckController")

	if deck and unitName then
		self:point(self:find(Config.LoadoutButton))

		if not self:await(session, nil, function()
			local current = self:controller("DeckController")
			return current ~= nil and current:IsOpen()
		end, "the loadout to open") then
			return
		end

		local before = self:equippedCount(unitName)

		-- the new unit's card
		self:await(session, Config.WaitForUi, function()
			return self:onScreen(self:inventoryCard(unitName))
		end, "the new unit's card")

		local card = self:inventoryCard(unitName)
		log:Debug(`loadout card = {card and card:GetFullName() or "NOT FOUND"}`)

		if card then
			self:scrollTo(card)
			self:point(card)

			if not self:awaitClick(session, card, function()
				local current = self:controller("DeckController")
				return (current ~= nil and current.SelectedUnit == unitName) or self:equippedCount(unitName) > before
			end, "the click on the new card") then
				return
			end
		end

		-- the equip button; it only shows while a copy is left to equip
		local equip = nil

		if self:equippedCount(unitName) <= before then
			self:await(session, Config.WaitForUi, function()
				return self:onScreen(self:find(Config.EquipButton))
			end, "the equip button")

			equip = self:find(Config.EquipButton)
		end

		if equip and self:onScreen(equip) then
			self:point(equip)

			if not self:awaitClick(session, equip, function()
				return self:equippedCount(unitName) > before
			end, "the click on equip") then
				return
			end

			task.wait(0.4)
		end

		self:point(nil)

		local current = self:controller("DeckController")
		if current and current:IsOpen() then
			current:Close()
		end
	end

	-- 10. the farewell
	self:point(nil)
	self:say(session, Config.ClosingLines)
	self:finish()
end

--[[ API ]]

--[=[
	Starts the flow. Calling with nothing restarts from the first step: that is what
	Cmdr's `tutorialshop` does when someone wants to see it again.

	`phase` enters further in: `true` or `"crate"` takes the purchase as done,
	`"loadout"` takes the unboxing as done too. It is how respawn returns.
]=]
function TutorialShopController:Start(phase : (string | boolean)?)
	self:hookUnboxing()

	local resolved = if phase == true then PHASE_CRATE
		elseif phase == PHASE_CRATE or phase == PHASE_LOADOUT then phase
		else PHASE_SHOP

	self.Session += 1
	local session = self.Session

	self.Running = true

	if resolved == PHASE_SHOP then
		self.FinishSent = false
		self.Bought = false
		self.UnboxStarted = false
		self.Unboxed = false
		self.Revealed = false
		self.NewUnit = nil
	elseif resolved == PHASE_CRATE then
		self.Bought = true

		-- A crate that started rolling before the respawn is still rolling: keep it.
		if not self.UnboxStarted then
			self.Unboxed = false
			self.Revealed = false
			self.NewUnit = nil
		end
	else
		self.Bought = true
		self.UnboxStarted = true
		self.Unboxed = true
		self.Revealed = true
	end

	self:clearCrateHighlight()

	ProximityPanel.UnlockWalkIn(WALK_IN_REASON)
	ProximityPanel.LockWalkIn(WALK_IN_REASON, if resolved == PHASE_SHOP then Config.WalkInAllow else {})

	log:Debug(string.format("starting the flow at %s | dialog=%s highlight=%s shop=%s backpack=%s unboxing=%s deck=%s",
		resolved,
		tostring(self:controller("DialogController") ~= nil),
		tostring(self:controller("HighlightController") ~= nil),
		tostring(self:controller("ShopController") ~= nil),
		tostring(self:controller("CrateUIController") ~= nil),
		tostring(self:controller("UnboxingController") ~= nil),
		tostring(self:controller("DeckController") ~= nil)))

	task.spawn(function()
		self:run(session, resolved)

		if self.Session == session then
			self:finish()
		end
	end)
end

--[=[
	The player died mid-flow.

	In the Lobby **every** `ScreenGui` has `ResetOnSpawn`, so the return is a restart,
	from wherever nothing is redone:

	  - **without the purchase**, from the first beat;
	  - **with the purchase**, from the backpack;
	  - **with the unboxing over**, from the loadout.
]=]
function TutorialShopController:onRespawn()
	if not self.Running then return end

	local phase = if self.Unboxed then PHASE_LOADOUT
		elseif self.Bought then PHASE_CRATE
		else PHASE_SHOP

	log:Debug(`respawn in the middle of the flow; restarting at {phase}.`)

	task.defer(function()
		if not self.Running then return end

		self:Start(phase)
	end)
end

--[=[
	Hooks up the unboxing notifications, once: the start (for the world crate's
	highlight), the end (for the unit), and the reveal.
]=]
function TutorialShopController:hookUnboxing()
	if self.UnboxingHooked then return end

	local unboxing = self:controller("UnboxingController")
	local signals = unboxing and unboxing.Signals
	if not signals or not signals.UnboxingFinished then return end

	self.UnboxingHooked = true

	local function mine(owner : any) : boolean
		return owner == nil or owner == Player
	end

	if signals.UnboxingStarted then
		signals.UnboxingStarted:Connect(function(result : any, crate : Instance?, owner : any)
			if not self.Running or not mine(owner) then return end

			self.UnboxStarted = true
			self.CrateModel = crate :: any

			if type(result) == "table" and result.Unit then
				self.NewUnit = result.Unit
			end

			self:highlightCrate(crate)
		end)
	end

	signals.UnboxingFinished:Connect(function(result : any, _entry : any, _crate : any, owner : any)
		if not mine(owner) then return end

		self.UnboxStarted = true
		self.Unboxed = true

		if type(result) == "table" and result.Unit then
			self.NewUnit = result.Unit
		end
	end)

	if signals.UnitRevealed then
		signals.UnitRevealed:Connect(function(_result : any, _unit : any, owner : any)
			if not mine(owner) then return end

			self.Revealed = true
		end)
	end
end

--[=[
	Aborts whatever is in progress and gives the screen back.
]=]
function TutorialShopController:Stop()
	self.Session += 1
	self:finish()
end

--[=[
	What `CrateController` asks before a crate click: `true` makes the click open the
	crate on the spot, skipping the bulk panel.

	This flow walks the player through "OPEN 1", so it only answers `true` when no
	`OpenOneButton` is configured.
]=]
function TutorialShopController:IsRunning() : boolean
	return self.Running and Config.OpenOneButton == nil
end

--- Whether the flow is in progress, whatever step it is on.
function TutorialShopController:IsActive() : boolean
	return self.Running
end

--[[ LIFECYCLE ]]

function TutorialShopController:construct()
	Framework:Listen("TutorialShopPrompt", function()
		self:Start()
	end)

	-- See `onRespawn`: in the Lobby, respawn takes the whole screen away.
	Player.CharacterAdded:Connect(function()
		self:onRespawn()
	end)

	-- The purchase: the server announces it.
	Framework:Listen("TutorialShopDone", function()
		self.Bought = true
	end)

	self.UnboxingHooked = false
end

--[=[
	Tells the server this flow is listening, so a player back from the won match
	gets the shop step. The server holds the prompt until this arrives: a prompt
	fired before `construct` hooked it would be dropped by the network layer.

	It waits for the character and `PromptDelay` first, so the dialog does not
	open under the loading screen.
]=]
function TutorialShopController:announceReady()
	task.spawn(function()
		if not Player.Character then
			Player.CharacterAdded:Wait()
		end

		task.wait(TutorialConfig.PromptDelay or 3)

		Framework:Fire("TutorialShopReady")
	end)
end

function TutorialShopController:start()
	self:announceReady()
end

function TutorialShopController:init()
	self:construct()
end

return TutorialShopController