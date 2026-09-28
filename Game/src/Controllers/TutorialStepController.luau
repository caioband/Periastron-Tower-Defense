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
local log = Log.new("TutorialStepController")

local Config = SharedConfig.TutorialConfig

--[[
	The tutorial script on the player's screen.

	The server sends `TutorialStep` when a step opens and `TutorialStepDone` when it is
	completed; the four things the player sees come from here:

	  1. the **instruction**, through the usual dialog box, with no blur and without
	     hiding the UI, unlike every other dialog in the game: the step asks the player to
	     use the HUD, and hiding it while asking would be a bad joke;
	  2. the **highlight** on the card they must use, through `HighlightController`;
	  3. the **arrow** at the map point where the unit must go, through
	     `ArrowController`;
	  4. the **button lock**, through `ButtonGateController`: what the step does not ask
	     for stops accepting clicks. The config writes the whitelist (the step's
	     `Buttons`), and it **outlives the step**: the lock belongs to the match, like the
	     deck's.

	**Blocking the other cards lives here**, and `CardController` asks:
	`:AllowsCard(name)` is what it checks before putting a card in hand. It is interface
	courtesy: `TutorialMatchService`, on the server, does the real refusing, because the
	client does not police itself.

	It lives in Game: the script belongs to the match, and matches only exist here.

	See docs/game/tutorial-match.md.
]]

-- How long to wait for one of the step's screen pieces to appear, in tenths of a second:
-- the card (`awaitCard`) and the button the step points at (`awaitHighlight`). The step can
-- ask for more with `HighlightWait`, in seconds; see the results screen step.
local UI_WAIT_FRAMES = 50

--[=[
	How long a step's dialog can stay on screen before the step moves on without it.

	The highlight and the arrows come in on the dialog's `OnClosed`, and only there. A
	dialog that does not close is a step that never points at anything: the instruction
	stays on screen, the player reads it, and after it there is no spotlight on any
	button.

	Twenty seconds is far more than the script's longest dialog (two lines in auto mode),
	so this does not fire in a normal match. When it fires, the output says so, and that
	line turns "the step pointed at nothing" into a bug with an address.
]=]
local SPEECH_TIMEOUT = 20

local TutorialStepController = {
	Controllers = {
		DialogController = {},
		HighlightController = {},
		ArrowController = {},
		RoundCardShopController = {},
		SpeedController = {},
		ButtonGateController = {},
		DifficultyController = {},
	}
}

TutorialStepController.Step = nil :: any

--[[
	Is this match the tutorial?

	It becomes `true` on the first step that arrives and never goes back: the script
	opens the Ready step before anything else, so when the card shop appears (wave 2) the
	answer is already here. It is what lets the tutorial apply **between** steps: a click
	outside the shop, for example, never closes the shop at any point in the match, not
	only while a purchase step is open.
]]
TutorialStepController.InTutorial = false

--[[
	The `Card` component, once it has resolved. See `resolveCardComponent`: it is cached
	precisely so the step path never has to wait on a `require` that yields.
]]
TutorialStepController.CardComponent = nil :: any

-- The cards the script locks until their step: `{ [Id] = true }`. The server
-- sends the list with the purchase step, and it is what the hand checks.
TutorialStepController.LockedCards = {}

--[[
	Is the hotbar off screen because a dialog is up? See `setCardsHidden`.

	Stored here, not read from `DialogController`, because it is reapplied when the
	`Card` component resolves, and that may happen after the dialog has already started.
]]
TutorialStepController.DeckHidden = false

-- The units the hand accepts now: `{ [name] = true }`, or `nil` with the deck
-- unlocked. It is the script's last request (see `setAllowedCards`), and it applies
-- **between** steps; `AllowsCard` is what asks.
TutorialStepController.AllowedUnits = nil :: { [string] : boolean }?

-- The step's arrows. There are several in the wrap-up, which points at both free points.
TutorialStepController.Arrows = {}

--[[
	The listeners that only apply while the step is open: today the speed menu's (see
	`watchSpeedOptions`). `clear` undoes them, as it does with the arrows: a step listener
	that outlives the step points the highlight at the wrong place on the next step.
]]
TutorialStepController.StepConnections = {}

--[[ INTERNAL ]]

--[=[
	`UILibraryController`'s `Card` component, or `nil` while it has not resolved.

	**This function does not yield, and that is its whole point.** `Card` does
	`Interface:WaitForChild("TowerContainer")` at module scope, so its first `require`
	yields the thread until the screen replicates, a real wait in the session's first
	second. Called from inside `show`, the step would be suspended between
	`self.Step = step` and registering the dialog's `OnClosed`, and in that gap two server
	notifications (which already have no guaranteed order; see `TutorialStepDone`) would
	trample each other.

	`resolveCardComponent` pays the wait, once, on its own thread. Until it returns,
	callers get `nil` and move on: what was left to tell the hotbar is stored in
	`DeckHidden` and `AllowedUnits`, and reapplied as soon as the component arrives.
]=]
function TutorialStepController:cardComponent() : any
	return self.CardComponent
end

--[=[
	Resolves the `Card` component, once, and applies what the script had already asked.

	The reapplication at the end is not overcaution: the hotbar may have been hidden by a
	dialog, or locked by a step, **before** the component existed, and without this that
	request would be silently lost: the hand would appear over the dialog, or the card
	the script locks would stay equippable.
]=]
function TutorialStepController:resolveCardComponent()
	local library = script.Parent:FindFirstChild("UILibraryController")
	local components = library and library:FindFirstChild("Components")
	local card = components and components:FindFirstChild("Card")
	if not card then
		log:StudioWarn("could not find the Card component; the hotbar does not follow the script.")

		return
	end

	local success, component = pcall(require, card)
	if not success or type(component) ~= "table" then
		log:StudioWarn(`the Card component did not load: {component}`)

		return
	end

	self.CardComponent = component

	if component.setHidden then
		component.setHidden(component, self.DeckHidden)
	end

	if component.setAllowed then
		component.setAllowed(component, self.AllowedUnits)
	end
end

function TutorialStepController:cardOf(unitName : string?) : GuiObject?
	if not unitName then
		return nil
	end

	local component = self:cardComponent()
	local getter = component and component.getCard

	return getter and getter(component, unitName)
end

--[=[
	Removes (or restores) the hotbar while the step's dialog is on screen.

	The rule belongs to the **dialog**, not the step: box up, hand out; box closed, hand
	back. The dialog comes first precisely to be read, and a lit card under it invites a
	click before finishing reading, all the more on a screen where the box may land right
	on top of the hotbar.

	The component itself restores it, and it restores **each card to the state it had**:
	a card with no units left stays dimmed instead of lighting up with the rest.
]=]
function TutorialStepController:setCardsHidden(hidden : boolean)
	self.DeckHidden = hidden == true

	local component = self:cardComponent()
	local setter = component and component.setHidden

	if setter then
		setter(component, self.DeckHidden)
	end
end

--[=[
	Locks the hotbar to the cards the step allows.

	`nil` unlocks everything. The lock is stored in the component, so it survives the
	hotbar being rebuilt: a deck change, a respawn, and the match restart of a player who
	won and played again.
]=]
function TutorialStepController:setAllowedCards(allowed : { [string] : boolean }?)
	-- Stored here too: the hotbar refuses the click on its own (`Active = false`), but
	-- `AllowsCard` answers `CardController`, and both answers must come from the same list
	-- so they do not disagree.
	self.AllowedUnits = allowed

	local component = self:cardComponent()
	local setter = component and component.setAllowed

	if setter then
		setter(component, allowed)
	end
end

--[=[
	The cards this step allows, or `nil` when it does not regulate the hotbar.

	A placement step with a requested unit allows only it; the wrap-up (`PlaceRest`)
	wants the whole deck on the ground and locks nothing.
]=]
function TutorialStepController:allowedOf(step : any) : { [string] : boolean }?
	--[[
		The list the server sent with the step rules: it is the deck lock, and it applies
		**between** steps too. A `nil` there means an unlocked deck: that is what arrives
		on the wrap-up step, on the last wave.

		The placement step can tighten it further (only the card it asks for), but never
		loosen it.
	]]
	local allowed = step and step.AllowedUnits

	if step and step.Kind == "Place" and step.Unit then
		return { [step.Unit] = true }
	end

	return allowed
end

--[=[
	Shows the step: dialog, highlight, and arrow.
]=]
function TutorialStepController:show(step : any)
	self.Step = step

	-- The whole hotbar off screen while the step asks for it (`HideDeck`). `clear`
	-- restores it, when the step ends or another opens on top.
	self:setDeckHeld(step.HideDeck == true)

	--[[
		The lock comes **before** the dialog, not with the highlight.

		The step's dialog is exactly the moment the player does not yet know where to
		click: leaving them free while reading the instruction invites them to find out on
		their own, which is the opposite of what the step is doing. And the lock does not
		get in the way of reading: the dialog advances with a click anywhere, not a button.
	]]
	self:gateFor(step)

	local dialog = self.Controllers.DialogController

	--[[
		The dialog comes first and alone; the highlight and arrow come in when it closes.

		Both at once compete for the player's eye: they read half the instruction, see the
		light blink on the card, and click before knowing why. And there is the worse case:
		the dialog sits **on top** of what is being pointed at.
	]]
	if dialog and step.Lines then
		log:Debug(`step "{step.Id}": showing the dialog; the visuals come in when it closes.`)

		-- The hand leaves while the box is up, and returns in `showVisuals`.
		self:setCardsHidden(true)

		local shown = false

		local function reveal(reason : string)
			-- Another step may have opened while the dialog ran, and then the visual is its own:
			-- lighting this one's spotlight would point at the previous step's button.
			if shown or self.Step ~= step then return end

			shown = true

			log:Debug(`step "{step.Id}": {reason}, showing highlight and arrow.`)
			self:showVisuals(step)
		end

		local disconnect
		disconnect = dialog:OnClosed(function()
			if disconnect then
				disconnect()
			end

			reveal("fala fechou")
		end)

		--[[
			The safety net: a dialog that does not close must not cost the highlight (see
			`SPEECH_TIMEOUT`). `reveal` is idempotent, so both it and `OnClosed` may run.
		]]
		task.delay(SPEECH_TIMEOUT, function()
			if shown or self.Step ~= step then return end

			log:StudioWarn(`the dialog of step "{step.Id}" did not close within {SPEECH_TIMEOUT}s; continuing without it.`)

			if disconnect then
				disconnect()
			end

			reveal("a fala estourou o prazo")
		end)

		-- Font and size come from `Speech`: the step's dialog is the same voice as the
		-- offer that brought the player here.
		dialog:Play(step.Lines, Config.Speech({
			-- The UI stays: the step asks the player to use the HUD.
			HideUI = false,
			Blur = false,
			Duck = false,
			Auto = true,
		}))

		return
	end

	self:showVisuals(step)
end

--[=[
	The step's highlight and arrow. Separate from `show` because they come in **after**
	the dialog, not with it.
]=]
function TutorialStepController:showVisuals(step : any)
	-- The dialog left (or the step had none): the hand returns. It is here, not at the
	-- end of the dialog, because a step with no dialog comes straight to this point.
	self:setCardsHidden(false)

	self:setAllowedCards(self:allowedOf(step))

	--[[
		What the highlight hugs: the hotbar card, when the step asks for a unit, or the
		screen path the step declares (the 2x button, for example). The path comes from
		config so a new step does not require new code.
	]]
	local highlight = self.Controllers.HighlightController
	if highlight then
		local target = self:cardOf(step.Unit)

		if not target and step.Highlight then
			target = highlight:Find(step.Highlight)
		end

		--[[
			The target may not be up yet when the step opens: the Ready button only becomes
			visible when the intermission countdown starts, and its step opens an instant
			before that. `Show` refuses an invisible target (and refusing quietly would
			leave the step with no highlight at all), so the path is **awaited** instead of
			looked up once.
		]]
		if not (target and highlight:Show(target)) and step.Highlight then
			self:awaitHighlight(step)
		end

		self:refreshGate()
	end

	-- The shop card and the hand card only exist after the shop opens and after
	-- the purchase happens: both arrive **after** the step. That is why they are
	-- awaited instead of looked up once.
	if step.Kind == "Buy" or step.Kind == "Use" then
		self:awaitCard(step)
	end

	-- The speed menu is also born later, and unlike the cards, it disappears and
	-- comes back as many times as the player wants.
	if step.Kind == "Speed" then
		self:watchSpeedOptions(step)
	end

	-- One arrow per spot: the wrap-up step points at both free points at once.
	local arrow = self.Controllers.ArrowController
	if arrow then
		if typeof(step.Position) == "Vector3" then
			table.insert(self.Arrows, arrow:Point(step.Position))
		end

		for _, position in (step.Positions or {}) do
			if typeof(position) == "Vector3" then
				table.insert(self.Arrows, arrow:Point(position))
			end
		end
	end
end

--[=[
	The step's whitelist becoming targets `ButtonGateController` understands.

	A screen path passes through as is: the gate resolves it, and resolving there is what
	lets a path that only exists later (the card on the shop table) be found when it
	arrives. What is translated here are the **aliases**, because their piece has no fixed
	path: it is cloned at runtime and its name depends on the step.

	An alias does not become an instance here: it becomes a **function**, which the gate
	calls on every sweep. That is what makes the purchase step work: the card on the table
	does not exist when the step opens, and a target resolved now would be `nil` forever,
	leaving the whitelist without exactly the button the step asks for. Along the same
	path, `@Highlight` follows the highlight when it slides from the shop button to the
	card (see `awaitCard`), without anyone having to notify the gate again.
]=]
function TutorialStepController:gateTargets(step : any, list : { any }?) : { any }
	local out = {}

	local aliases = {
		["@Highlight"] = function()
			local highlight = self.Controllers.HighlightController

			return highlight and highlight:GetTarget() or nil
		end,

		["@Deck"] = function()
			local interface = PlayerGui:FindFirstChild("Interface")

			return interface and interface:FindFirstChild("TowerContainer") or nil
		end,

		["@Card"] = function()
			return self:cardOf(step.Unit)
		end,

		["@Hand"] = function()
			return if step.Card then self:handCardOf(step.Card) else nil
		end,

		["@Offer"] = function()
			return if step.Card then self:offerCardOf(step.Card) else nil
		end,

		--[=[
			The speed menu options: **all** of them, not only the one the step asks for.

			The `Interface.Speed` button does not open a panel: it clones itself once per
			step and hangs the clones **next to it**, on the same parent (see
			`SpeedController:createOption`). They are not the button's children, so
			allowing the button does not allow them: the 1.5x step would open the menu with
			no clickable option.

			All of them, because choosing is comparing: a menu with one live option and the
			others dead does not teach what the button does. Which one the server accepts is
			still its call; what the step expects is the `Index` step, and that is where the
			highlight lands when the menu opens (see `watchSpeedOptions`).
		]=]
		["@SpeedOptions"] = function()
			local speed = self.Controllers.SpeedController

			return speed and speed:GetOptions() or nil
		end,
	}

	for _, entry in (list or {}) do
		if type(entry) ~= "string" then
			continue
		end

		if string.sub(entry, 1, 1) ~= "@" then
			table.insert(out, entry)

			continue
		end

		local alias = aliases[entry]

		if alias then
			table.insert(out, alias)
		else
			log:StudioWarn(`step "{step.Id}" asks for alias "{entry}", which does not exist.`)
		end
	end

	return out
end

--[=[
	Locks the screen to what this step allows.

	A step without `Buttons` **does not touch the lock**: it neither locks nor unlocks.
	That keeps an older script working and keeps the previous step's whitelist up while
	the new step has no opinion on the matter.

	The valve only runs while the step is open; see `onStepDone`.
]=]
function TutorialStepController:gateFor(step : any)
	local gate = self.Controllers.ButtonGateController
	if not gate or not step or not step.Buttons then return end

	local allow = self:gateTargets(step, step.Buttons)

	-- The dialog box enters every step: a choice button that does not accept clicks is
	-- a conversation with no way out.
	for _, entry in (Config.ButtonGate.Always or {}) do
		table.insert(allow, entry)
	end

	gate:Lock({
		Allow = allow,
		Block = self:gateTargets(step, step.BlockedButtons),
		Ignore = Config.ButtonGate.Ignore,
		Release = step.ButtonRelease or Config.ButtonGate.Release,
	})
end

--[=[
	Follows the speed menu with the highlight and the whitelist.

	The `Interface.Speed` button does not open a panel: it **clones itself** once per step
	and puts the clones next to it. While the menu is closed, what the step points at is
	the button; open, what it must point at is the step it asks for: pointing at the
	button the player just clicked does not say which of the three options is right, and
	the three are identical except for the art.

	The options are really created and destroyed, so the parent's `ChildAdded` and
	`ChildRemoved` announce them: there is no signal to listen to or loop to keep up.
	`defer` exists because the clone is born **before** `SpeedController` writes the step
	on it: pointing on the same frame would catch the option without the attribute.

	Once the menu closes, the highlight returns to the button. A player who opened it and
	clicked outside must not be left with nothing pointed at mid-step.
]=]
function TutorialStepController:watchSpeedOptions(step : any)
	local speed = self.Controllers.SpeedController
	local button = speed and speed:GetButton()
	local parent = button and button.Parent
	if not parent then return end

	local function update()
		if self.Step ~= step then return end

		local highlight = self.Controllers.HighlightController
		local target = speed:GetOption(step.Index) or button

		if highlight and target then
			highlight:Show(target)
		end

		-- The step's whitelist asks for `@SpeedOptions`, and the list changed: the gate's math
		-- does not wait for the next button to be born to be redone.
		self:refreshGate()
	end

	table.insert(self.StepConnections, parent.ChildAdded:Connect(function()
		task.defer(update)
	end))

	table.insert(self.StepConnections, parent.ChildRemoved:Connect(function()
		task.defer(update)
	end))
end

--[=[
	Tells the gate to redo the math now.

	It already reapplies on its own when a button is born, but the highlight changing
	target creates no button, and the `@Highlight` alias follows the highlight. Without
	this, a step that allows "whatever is highlighted" would keep allowing the old target.
]=]
function TutorialStepController:refreshGate()
	local gate = self.Controllers.ButtonGateController

	if gate then
		gate:Refresh()
	end
end

--[=[
	Waits for the step's card to appear on screen and highlights it.

	A **purchase** step points at the card on the shop table; a **use** step points at the
	card that ended up in the hotbar. Both are born after the step opens, and neither takes
	longer than the shop rising, which is why the wait has a short budget and gives up
	quietly: the step still applies with the dialog and the lock, just without the
	highlight.
]=]
function TutorialStepController:awaitCard(step : any)
	local highlight = self.Controllers.HighlightController
	if not highlight or not step.Card then return end

	task.spawn(function()
		for _ = 1, UI_WAIT_FRAMES do
			if self.Step ~= step then return end

			local target = if step.Kind == "Buy"
				then self:artOf(self:offerCardOf(step.Card))
				else self:artOf(self:handCardOf(step.Card))

			if target then
				highlight:Show(target)
				self:refreshGate()

				return
			end

			task.wait(0.1)
		end
	end)
end

--[=[
	Waits for the button the step points at to appear on screen and highlights it.

	It is `awaitCard`'s sibling for screen paths. It gives up quietly for the same reason:
	the step still applies with the dialog, and a highlight that never arrived beats a
	loop that never dies.
]=]
function TutorialStepController:awaitHighlight(step : any)
	local highlight = self.Controllers.HighlightController
	if not highlight or not step.Highlight then return end

	-- A target born at the end of a long animation (the results screen button)
	-- needs more time than a HUD button, which is already there.
	local frames = if typeof(step.HighlightWait) == "number"
		then math.max(1, math.round(step.HighlightWait * 10))
		else UI_WAIT_FRAMES

	task.spawn(function()
		for _ = 1, frames do
			if self.Step ~= step then return end

			local target = highlight:Find(step.Highlight)

			if target and highlight:Show(target) then
				self:refreshGate()

				return
			end

			task.wait(0.1)
		end

		log:StudioWarn(`step "{step.Id}" asks to highlight "{step.Highlight}", which did not show up on screen.`)
	end)
end

--[=[
	The card on the round shop table.
]=]
function TutorialStepController:offerCardOf(cardId : string) : GuiObject?
	local shop = self.Controllers.RoundCardShopController

	return shop and shop:GetOfferCard(cardId) or nil
end

--[=[
	The card inside a wrapper, when what you have is the wrapper.

	The wrapper is the layout slot and the highlight should not hug it; the card is the
	child that carries the art. Without a card inside, the wrapper will do: pointing at
	the right slot beats pointing at nothing.
]=]
function TutorialStepController:artOf(wrapper : GuiObject?) : GuiObject?
	if not wrapper then
		return nil
	end

	for _, child in wrapper:GetChildren() do
		if child:IsA("GuiButton") or child:IsA("ImageLabel") then
			return child
		end
	end

	return wrapper
end

--[=[
	The round card already in the hotbar, waiting to be used. The `Card` component names
	it `RoundCard_<Id>` when it enters.
]=]
function TutorialStepController:handCardOf(cardId : string) : GuiObject?
	local interface = PlayerGui:FindFirstChild("Interface")
	local container = interface and interface:FindFirstChild("TowerContainer")

	return container and container:FindFirstChild(`RoundCard_{cardId}`) or nil
end

--[=[
	Removes the step from the screen. Called when it is completed and when another opens
	on top: one step at a time, as on the server.

	What it does **not** undo are the two locks: the deck's (`AllowedUnits`) and the
	buttons' (`gateFor`). They belong to the match, not the step: releasing them here would
	make the gap between two waves the moment to leave the script.
]=]
function TutorialStepController:clear()
	self.Step = nil

	self:setDeckHeld(false)
	self:clearVisuals()
end

--[=[
	Hides (or restores) the whole `Interface.TowerContainer`, through
	`DifficultyController`, which owns its `Visible`.

	Unlike `setCardsHidden`, which dims the cards one by one while the dialog is up, this
	removes the whole container, and lasts the whole step.
]=]
function TutorialStepController:setDeckHeld(held : boolean)
	local difficulty = self.Controllers.DifficultyController
	if difficulty and difficulty.HoldHotbar then
		difficulty:HoldHotbar("Tutorial", held)
	end
end

--[=[
	Clears what the step drew: the highlight, the arrows, and its listeners.

	Separate from `clear` because respawn needs half of it: there the step stays open, and
	the goal is to redraw over the new screen, not to forget the step.
]=]
function TutorialStepController:clearVisuals()
	local highlight = self.Controllers.HighlightController
	if highlight then
		highlight:Hide()
	end

	for _, arrow in self.Arrows do
		arrow:Destroy()
	end

	table.clear(self.Arrows)

	for _, connection in self.StepConnections do
		connection:Disconnect()
	end

	table.clear(self.StepConnections)
end

--[=[
	The player respawned: the open step redraws on the new screen.

	Dying closes no step (it stays up on the server, holding the wave if that is the
	case), but takes everything with `ResetOnSpawn` along: the dialog box, the results
	screen, and in the Lobby the whole `HUD`. Without this the player would return to a
	match stopped on a step that no longer points at anything.

	**The dialog takes precedence.** If it is coming back (see
	`DialogController:IsResuming`), the highlight and arrows wait for it to end, as they
	would the first time: lighting the spotlight over an instruction a second away from
	reappearing is the same fight for the player's eye `show` avoids.

	The highlight finds itself again by name path (`HighlightController:rebind`); what
	only this can provide are the **arrows**, which point at map places and have no owner
	on screen, and the **button lock**, which must be rebuilt against the new tree.
]=]
function TutorialStepController:reassert()
	local step = self.Step
	if not step then return end

	log:Debug(`respawn with step "{step.Id}" open; redrawing.`)

	-- The screen is different: the whitelist must be recounted against it.
	self:gateFor(step)

	local dialog = self.Controllers.DialogController
	if dialog and (dialog:IsOpen() or dialog:IsResuming()) then
		local disconnect
		disconnect = dialog:OnClosed(function()
			if disconnect then
				disconnect()
			end

			if self.Step ~= step then return end

			self:clearVisuals()
			self:showVisuals(step)
		end)

		return
	end

	self:clearVisuals()
	self:showVisuals(step)
end

--[[ API ]]

--[=[
	Can the hotbar put this card in hand now?

	With no step open, everything is allowed: outside the script the tutorial does not
	interfere. With a placement step open, only its card.
]=]
function TutorialStepController:AllowsCard(unitName : string) : boolean
	--[[
		The deck lock comes before the step and outlives it: between wave 1 and 5 there is
		no placement step, and without this question the locked card would become
		equippable again in the intermission. It is the same math as `CanPlace` on the
		server.
	]]
	local allowed = self.AllowedUnits
	if allowed and not allowed[unitName] then
		return false
	end

	local step = self.Step

	if not step or step.Kind ~= "Place" or not step.Unit then
		return true
	end

	return unitName == step.Unit
end

--[=[
	Can this round card be used yet?

	It mirrors the server's `CanUse` so the hand does not accept the click of a card the
	server would refuse; the difference is that here the player sees nothing happen,
	instead of seeing aiming open and the card come back.
]=]
function TutorialStepController:AllowsCardUse(cardId : string) : boolean
	local step = self.Step

	if not step or step.Kind ~= "Use" or not step.Card then
		return not self.LockedCards or not self.LockedCards[cardId]
	end

	return cardId == step.Card
end

--[=[
	Is this match the tutorial?

	Callers are those that must behave differently in it without being part of the
	script: today `ResultController`, which locks "PLAY AGAIN" on the end screen.

	The answer is only reliable after the first step, which arrives in the intermission
	before wave 1: any match screen is well after that.
]=]
function TutorialStepController:IsTutorial() : boolean
	return self.InTutorial == true
end

--[=[
	Can the round card shop be closed with a click outside right now?

	**In the tutorial match, never.** `RoundCardShopController` asks this before
	dismissing the shop, and a player learning what the shop is clicks the table, the
	background, and whatever is nearby before choosing a card: closing on the first of
	those clicks removes from the screen exactly what the step told them to read.

	The way out still exists and is the usual one: the button that opened the shop
	closes it. Only "clicked anywhere, closed" goes away.

	Outside the tutorial nothing changes: the shop dismisses as it always did.
]=]
function TutorialStepController:AllowsShopDismiss() : boolean
	if self.InTutorial then
		return false
	end

	local step = self.Step

	return not (step and step.Kind == "Buy")
end

--[=[
	The step open now, for anyone who needs to decide something with it.
]=]
function TutorialStepController:GetStep() : any
	return self.Step
end

--[[ LIFECYCLE ]]

function TutorialStepController:construct()
	--[[
		Respawn does not close the step, but destroys half of what it drew. See
		`reassert`.

		`task.defer` because `CharacterAdded` arrives **before** `StarterGui` has finished
		being recloned: looking for the step's button on the same frame would find the old
		screen, or none. The highlight and the dialog do the real waiting, each with its
		own deadline; this only gets off the spawn frame.
	]]
	Player.CharacterAdded:Connect(function()
		task.defer(function()
			self:reassert()
		end)
	end)

	Framework:Listen("TutorialStep", function(step : any)
		if type(step) ~= "table" then return end

		self.InTutorial = true

		if type(step.Locked) == "table" then
			self.LockedCards = step.Locked
		end

		self:clear()
		self:show(step)
	end)

	Framework:Listen("TutorialStepDone", function(id : any)
		local step = self.Step

		--[=[
			The end of **one** step must not erase the next.

			The two notifications leave the server microseconds apart (the Ready step
			closes when the countdown ends, and wave 1 opens the Slingshot step on the next
			frame), and they travel in **different events**, which `Me` (Warp) queues
			separately: the arrival order on the client is not guaranteed.

			Without checking the id, a late "Ready ended" would clear the step already open:
			`self.Step` would become `nil`, and when the Slingshot dialog closed `show`
			would give up on its own: dialog on screen, no highlight, no arrow, and the
			hotbar without the step's lock.
		]=]
		if step and id ~= nil and step.Id ~= id then
			log:Debug(`"{id}" finished after "{step.Id}" opened; the open step stays.`)

			return
		end

		--[[
			A completed step removes the valve's **deadline**, not the lock.

			The valve exists for a step that did not recognize what the player did. A
			completed step is not that case: what comes after it is the wave running, with
			nothing to click until the next step, and letting the deadline run there would
			hand back the whole screen mid-script for the player having waited.
		]]
		local gate = self.Controllers.ButtonGateController
		if gate then
			gate:HoldRelease()
		end

		-- A completed step unlocks its card: from then on it is a card
		-- like any other.
		if step and step.Kind == "Use" and step.Card then
			self.LockedCards[step.Card] = nil
		end

		self:clear()
	end)
end

function TutorialStepController:start()
end

function TutorialStepController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	-- On its own thread because it yields (see `cardComponent`), and the framework's
	-- `init` must not yield: the following controllers would wait for this one.
	task.spawn(function()
		self:resolveCardComponent()
	end)

	self:construct()
end

return TutorialStepController
