local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("TutorialShopController")

local TutorialConfig = SharedConfig.TutorialConfig
local Config = TutorialConfig.Lobby

--[[
	The second half of the tutorial, in the Lobby, after the win.

	It is a seven-beat flow, and each beat points at **the only clickable thing at
	that moment**:

		1. the congratulations dialog;
		2. the shop button;
		3. the Crate of Beginnings buy button, when the shop opens;
		4. the shop closes on its own and the backpack button is pointed at;
		5. the first crate in the backpack, when it opens: **a single click**;
		6. the backpack closes on its own and the unboxing runs with the screen locked;
		7. the farewell dialog.

	**Nothing outside the step is clickable.** `ButtonGateController` turns the rest
	off, the same one the match steps use: at each beat the whitelist is that beat's
	target (plus the dialog box, which is `TutorialConfig.ButtonGate.Always`), and the
	rest stops accepting clicks. That keeps the player from opening the deck, entering
	a portal, or buying another crate mid-script.

	The lock is on the buttons, and **not** on the highlight's `BlockInput`, on
	purpose: that one covers the screen with frames that swallow any input, including
	the drag that turns the camera, and the player would be stuck looking one way. The
	lock leaves with the flow: when it ends, is interrupted, or the player dies,
	`finish` gives everything back.

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
		UnboxingController = {},
	}
}

TutorialShopController.Running = false

-- One session per flow: each wait's `while` dies when another starts (or when the
-- flow is aborted), instead of running in the background.
TutorialShopController.Session = 0

-- How often a long wait announces itself in the output.
local REPORT_INTERVAL = 3

--[[ INTERNAL ]]

--[=[
	A sibling controller, looked up **at the time of use**.

	Everything cannot be resolved in `init`: `Me:Load` calls each module's `init`
	during the sweep, so modules loaded after this one do not exist yet, and a
	non-waiting lookup there returns `nil` forever. That would leave the flow unable to
	react to the command, with `ShopController` never arriving.

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
	that did not exist when the previous one started: the buy button is born with the
	shop open, the crate is born with the backpack open. The gate also reapplies
	itself when a new button arrives, so the order between "opened the screen" and
	"pointed at the target" does not matter.

	`nil` locks the whole screen and clears the highlight: that is what the unboxing
	step asks for, so there is no second crate to open by accident.

	The valve's deadline is the config's `StallRelease`, counted from here, and since
	`point` always comes an instant before that beat's wait, it is that wait's
	deadline.
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

	The valve that releases the lock when a wait runs past the limit **is not here**:
	it belongs to `ButtonGateController`, armed by the `point` that comes before each
	wait (see `Lobby.StallRelease`). One shared implementation serves this flow and
	the match steps.
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

		-- A slow wait becomes a line in the output: "nothing happens" is the hardest
		-- report to investigate, and the flow knows exactly what it is waiting for.
		if label and os.clock() >= nextReport then
			nextReport = os.clock() + REPORT_INTERVAL

			log:Debug(`waiting: {label}`)
		end

		task.wait(Config.PollInterval)
	end

	return false
end

--[=[
	A dialog line, waiting for it to close before continuing.
]=]
function TutorialShopController:say(session : number, lines : { string }?) : boolean
	local dialog = self:controller("DialogController")
	if not dialog or not lines then
		return true
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

	--[=[
		A dialog line that did not start must not **stop** the flow.

		The wait below has no deadline: it runs until `OnClosed` arrives, and
		`OnClosed` for a line that never started never arrives. The flow would stall on
		the first line, with the screen locked on the previous beat's target and
		nothing happening; a restart after respawning in the Lobby would die silently.

		Continuing without it is the lesser evil: the next beat points at the shop
		button, which is what the player needs to click anyway. The output says what
		was missing.
	]=]
	if not playing then
		if disconnect then
			disconnect()
		end

		log:StudioWarn("the dialog box did not open; continuing the flow without it.")

		return true
	end

	local finished = self:await(session, nil, function()
		return closed
	end)

	-- A wait that ended without the dialog closing (another session started, or the
	-- flow was aborted) leaves the subscription behind: without this, each restart stacks one more.
	if disconnect then
		disconnect()
	end

	return finished
end

--[=[
	Is this element **actually** on screen?

	`Visible` is a property of each object, not of what is seen: a button inside a
	closed panel still has `Visible = true`, and its `AbsoluteSize` still holds.
	Checking only that let step 2's on-screen proof pass with the shop closed: the
	flow skipped the shop button click and highlighted the buy button inside a panel
	nobody had opened.

	Being on screen means the object visible **and** its whole ancestry visible, up to
	the `ScreenGui`, which in turn must be enabled.
]=]
function TutorialShopController:onScreen(instance : GuiObject?) : boolean
	if not instance or not instance.Visible then
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
	The tutorial crate's buy button, inside the shop.

	Looked up by the **item id**, which is how `ShopController` names each crate's
	container, and then the buy button inside it.
]=]
function TutorialShopController:buyButton() : GuiObject?
	local shop = PlayerGui:FindFirstChild("ShopUI")
	local container = shop and shop:FindFirstChild(Config.Item, true)
	local button = container and container:FindFirstChild(Config.BuyButton, true)

	return if button and button:IsA("GuiObject") then button else nil
end

--[=[
	The first crate in the backpack: the one the player just bought.

	"First" is the one with the lowest `LayoutOrder`, not the first in the children
	list: children order is creation order, and the layout rules the screen.

	**Only visible buttons count.** The wrapper keeps one entry per rarity, and
	`CrateController` only shows those the player owns, plus `cratetemplate`, the
	template, which stays hidden there for the designer to edit. Without the filter,
	the highlight would land on something invisible, which is the same as not showing.

	**`Active` does not count**, and this is an easy trap: the previous step leaves
	every button outside it disabled, and the backpack crates are in that "outside".
	Requiring `Active` here would look for a target this flow's own lock had just
	hidden: the step would wait five seconds and give up with no highlight. `point`
	unlocks it, right after this lookup.
]=]
function TutorialShopController:firstCrate() : GuiObject?
	local highlight = self:controller("HighlightController")
	local list = highlight and highlight:Find(Config.CrateList)
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

		-- A real entry has the prefix; the template does not. With no prefix declared, any
		-- visible button counts.
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
	Gives the screen back: no highlight, no lock.
]=]
function TutorialShopController:finish()
	self.Running = false

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
	The whole flow, top to bottom.

	Written as a sequence, not as a handful of callbacks, because that is what it is:
	each step only makes sense after the previous one, and `await` is what turns "the
	player clicked" into a line of code.

	It is split in two halves by the **purchase**, and the split is there because of
	respawn: dying in the Lobby destroys `HUD`, `ShopUI`, and `crateui` (all have
	`ResetOnSpawn`), and the flow has to restart somewhere. Before the purchase,
	restarting from zero costs nothing: the player had only clicked a button. After
	it, restarting would send them to buy a crate they already bought, so the return
	goes through the second half. See `onRespawn`.
]=]
function TutorialShopController:run(session : number, fromCrate : boolean?)
	if fromCrate then
		return self:runCrate(session)
	end

	if not self:runShop(session) then
		return
	end

	self:runCrate(session)
end

--[=[
	The first half: the dialog, the shop button, and the crate purchase.

	Returns `false` when the flow died midway: another session started, or a wait gave
	up.
]=]
function TutorialShopController:runShop(session : number) : boolean
	local highlight = self:controller("HighlightController")

	-- 1. the dialog
	if not self:say(session, Config.Lines) then return false end

	-- 2. the shop button, until it opens
	local shopButton = highlight and highlight:Find(Config.ShopButton)
	log:Debug(`step 2: shop button = {shopButton and shopButton:GetFullName() or "NOT FOUND"}`)

	self:point(shopButton)

	--[[
		The controller is looked up **on every pass**, not cached before the loop: if it
		had not loaded when the flow started, the condition would be false forever and
		the step would stall silently.
	]]
	--[[
		"The shop opened" is asked of the controller **and** checked on screen.

		The controller answers through the proximity panel, and the panel can open
		through paths it does not track. Since the lock turns off everything that is not
		the target, a wrong "did not open" would leave the buy button disabled forever.

		The second witness is the buy button **on screen**, and "on screen" means the
		whole ancestry visible (see `onScreen`), not the button's own `Visible`: that
		stays on inside a closed panel, and checking it alone made the step pass before
		the player clicked anything.
	]]
	if not self:await(session, nil, function()
		local shop = self:controller("ShopController")
		if shop and shop:IsOpen() then
			return true
		end

		return self:onScreen(self:buyButton())
	end, "the shop to open") then
		return false
	end

	-- 3. the buy button, until the purchase happens
	self:await(session, Config.WaitForUi, function()
		return self:buyButton() ~= nil
	end, "the buy button to appear")

	local buy = self:buyButton()
	log:Debug(`step 3: buy button = {buy and buy:GetFullName() or "NOT FOUND"}`)

	self:point(buy)

	if not self:await(session, nil, function()
		return self.Bought == true
	end, "the crate purchase") then
		return false
	end

	return true
end

--[=[
	The second half: the purchased crate leaving the backpack, and the farewell.

	This is how the flow returns when the player dies **after** buying.
]=]
function TutorialShopController:runCrate(session : number)
	local highlight = self:controller("HighlightController")

	-- 4. the shop closes on its own and the backpack is pointed at
	local shop = self:controller("ShopController")
	if shop and shop:IsOpen() then
		shop:Close()
	end

	self:point(highlight and highlight:Find(Config.BackpackButton))

	if not self:await(session, nil, function()
		local backpack = self:controller("CrateUIController")
		if backpack and backpack:IsOpen() then
			return true
		end

		-- The same second witness as the shop: the crate **on screen** is the backpack
		-- open, whatever the controller says.
		return self:onScreen(self:firstCrate())
	end, "a mochila abrir") then
		return
	end

	-- 5. the first crate, until it leaves the backpack (it was opened)
	self:await(session, Config.WaitForUi, function()
		return self:firstCrate() ~= nil
	end, "the first crate to appear in the backpack")

	local crate = self:firstCrate()

	do
		local highlight = self:controller("HighlightController")
		local list = highlight and highlight:Find(Config.CrateList)
		local visible = 0

		if list then
			for _, c in list:GetDescendants() do
				if c:IsA("GuiButton") and c.Visible then visible += 1 end -- `Active` stays out: the previous step's lock turns it off
			end
		end

		log:Debug(string.format("step 5: list=%s visible buttons=%d picked=%s",
			list and list:GetFullName() or "NOT FOUND", visible,
			crate and `{crate.Name} (order {crate.LayoutOrder})` or "NONE"))
	end

	self:point(crate)

	--[[
		**One crate, one click.**

		Waiting for the unboxing to finish with the button still highlighted and
		clickable was an invitation: the player has more crates, the button is still
		there, and they open three while the first is still spinning. The step listens
		to the button's **activation** and closes on the first click; from then on
		nothing is clickable (`point(nil)` locks everything) until the unboxing ends.
	]]
	local clicked = false
	local connection = if crate and crate:IsA("GuiButton")
		then crate.Activated:Connect(function()
			clicked = true
		end)
		else nil

	local advanced = self:await(session, nil, function()
		return clicked or self.Unboxed == true or crate == nil or not crate.Parent
	end, "the click on the crate")

	if connection then
		connection:Disconnect()
	end

	if not advanced then
		return
	end

	-- From the first crate to the end of the unboxing, the whole screen stays locked:
	-- there is no second crate to open by accident.
	self:point(nil)

	-- 6. the backpack gets out of the unboxing's way
	local backpack = self:controller("CrateUIController")
	if backpack and backpack:IsOpen() then
		backpack:Close()
	end

	-- 7. the unboxing ends and the farewell dialog closes the tutorial
	local unboxed = self:await(session, nil, function()
		return self.Unboxed == true
	end, "o unboxing terminar")

	--[[
		The onboarding funnel's last step is sent from here, not from `:finish()`: that
		one also runs when the flow aborts (`:Stop`, or an `await` that returned false),
		and "opened the crate" must mean the crate opened.

		The server checks whether this player really finished the tutorial, and is not
		someone running Cmdr's `tutorialshop`.
	]]
	if unboxed then
		Framework:Fire("TutorialShopFinished")
	end

	self:say(session, Config.ClosingLines)
	self:finish()
end

--[[ API ]]

--[=[
	Starts the flow. Calling again restarts from the first step: that is what Cmdr's
	`tutorialshop` does when someone wants to see it again.

	`fromCrate` enters through the second half, with the purchase taken as done. It is
	how respawn returns when the player had already bought the crate (see
	`onRespawn`), and it also keeps the restart from asking for a second purchase.
]=]
function TutorialShopController:Start(fromCrate : boolean?)
	self:hookUnboxing()

	self.Session += 1
	local session = self.Session

	self.Running = true
	self.Unboxed = false

	-- Restarting through the second half does not undo the purchase: it happened, and
	-- the server would not make it again.
	self.Bought = fromCrate == true

	log:Debug(string.format("starting the flow | dialog=%s highlight=%s shop=%s backpack=%s unboxing=%s",
		tostring(self:controller("DialogController") ~= nil),
		tostring(self:controller("HighlightController") ~= nil),
		tostring(self:controller("ShopController") ~= nil),
		tostring(self:controller("CrateUIController") ~= nil),
		tostring(self:controller("UnboxingController") ~= nil)))

	task.spawn(function()
		self:run(session, fromCrate)

		if self.Session == session then
			self:finish()
		end
	end)
end

--[=[
	The player died mid-flow.

	In the Lobby **every** `ScreenGui` has `ResetOnSpawn`: `HUD`, `ShopUI`, `crateui`.
	The screen the flow was pointing at no longer exists, and the references it held
	became garbage, including the crate whose click it was waiting for, which is an
	instance and not a condition.

	So the return is a restart, and where it restarts depends on what was done:

	  - **without the purchase**, from the first beat. The player had only clicked a
	    button, and redoing that costs nothing;
	  - **with the purchase**, from the second half. Sending them to buy a crate they
	    already own would be a step that never closes: the server does not sell twice.

	A stopped flow does not react: dying outside the shop tutorial is just dying.
]=]
function TutorialShopController:onRespawn()
	if not self.Running then return end

	local bought = self.Bought == true

	log:Debug(`respawn in the middle of the flow; restarting {bought and "from the crate" or "from the start"}.`)

	--[[
		The new screen has not arrived yet when `CharacterAdded` fires: `ResetOnSpawn`
		reclones `StarterGui` after it. The flow's waits already look for each piece
		with their own budget, so it is enough to get off the spawn frame; `await` does
		the real waiting.
	]]
	task.defer(function()
		if not self.Running then return end

		self:Start(bought)
	end)
end

--[=[
	Hooks up the end-of-unboxing notification, once.
]=]
function TutorialShopController:hookUnboxing()
	if self.UnboxingHooked then return end

	local unboxing = self:controller("UnboxingController")
	local signal = unboxing and unboxing.Signals and unboxing.Signals.UnboxingFinished
	if not signal then return end

	self.UnboxingHooked = true

	signal:Connect(function()
		self.Unboxed = true
	end)
end

--[=[
	Aborts whatever is in progress and gives the screen back.
]=]
function TutorialShopController:Stop()
	self.Session += 1
	self:finish()
end

function TutorialShopController:IsRunning() : boolean
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

	-- The purchase: the server announces it, through the same event that closed the
	-- old step.
	Framework:Listen("TutorialShopDone", function()
		self.Bought = true
	end)

	--[[
		The unboxing controller may not have loaded when this `construct` runs (see
		`controller`), so the subscription happens the first time the flow starts, and
		only once.
	]]
	self.UnboxingHooked = false
end

function TutorialShopController:start()
end

function TutorialShopController:init()
	self:construct()
end

return TutorialShopController
