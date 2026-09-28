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
local log = Log.new("ButtonGateController")

--[[
	The button lock: which `GuiButton`s on screen accept clicks right now.

		local Gate = Framework:Get("ButtonGateController")

		Gate:Lock({
			Allow = { "Interface.ReadyWave", someInstance },
			Block = { "Interface.SkipPrompt" },
			Release = 90,
		})

		Gate:Unlock()

	**The whitelist is closed and rules both ways.** Whatever is not in `Allow` (nor a
	child or parent of something that is) stops accepting clicks, hover, and gamepad
	navigation; whatever is **starts accepting**, even if it arrives disabled. Both are
	`Active`/`Selectable`, and both return to what they were on `Unlock`. Turning on is
	also what saves a piece cloned from a template the lock disabled; see `enforce`.
	`Block` is the subtraction: it beats `Allow`, and it is how you remove one button
	from inside a fully allowed panel.

	**The target's children and parents come along.** Clicking a button inside the
	target is clicking the target, and a clickable wrapper around the target must not
	go dead while what is inside it works.

	**Why not the highlight's `BlockInput`.** It covers the screen with four `Active`
	frames, and an `Active` frame swallows *any* input passing over it, including the
	drag that turns the camera: the player would be stuck looking one way. Here the
	camera stays free: only what the buttons accept changes.

	**A button that was already disabled is not touched.** A prior `Active = false`
	means it has another owner (`ToggleTower` locks upgrade and sell for the whole
	tutorial match), and turning it back on at `Unlock` would undo someone else's lock.

	**Buttons off screen are left out.** You cannot click what you cannot see, and
	changing a hidden piece's `Active` breaks whoever clones it: the clone is born with
	the state the lock wrote on the template. The lock listens to whatever is hiding
	and redoes the math when the panel appears; see `onScreen` and `watch`.

	**A button another owner turns back on gets turned off again.** A button has more
	than one owner, and none of them knows the tutorial is running:
	`DifficultyController` restores the steps' `Active` when the vote closes,
	`ReadyController` turns its own back on every intermission. The lock listens to
	the `Active` of each button it disabled and undoes that; see `disable`.

	**Buttons born later enter the math.** The shop table, the card going to the hand,
	the backpack's crate list: all are born with the lock already up. The gate listens
	to `PlayerGui` and reapplies on its own: whoever called `Lock` does not need to
	know when the screen finished building.

	**The valve (`Release`).** The lock exists to keep the player on the script, not to
	trap them: if a step's whitelist is wrong, the right button stays disabled and
	nobody is around to turn it back on. After `Release` seconds the lock drops on its
	own and the output says why. Code that knows the wait is legitimate (the step is
	already done and the player is just watching the wave run) calls `:HoldRelease()`
	and the lock stays without a deadline.

	It lives in `common/` because both places have scripts that point at buttons.

	See docs/common/tutorial.md.
]]

local ButtonGateController = {
	Controllers = {
		HighlightController = {},
	}
}

-- The active lock, as it came in `Lock`. `nil` means the screen is free.
ButtonGateController.Spec = nil :: any

--[[
	`[GuiButton] = { Active, Selectable, Connection }`: what each button was before the
	lock disabled it, and the listener that keeps it disabled. This table is what
	`Unlock` undoes.
]]
ButtonGateController.Saved = {}

-- Goes up on every `Lock`. The valve and the deferred sweep check the number before
-- touching the screen: a new lock during the previous one's wait must not be undone
-- by the valve of a lock that is already gone.
ButtonGateController.Token = 0

--[[
	Goes up on every `Lock`, every `Unlock`, and on `HoldRelease`. It is the number the
	valve checks when it wakes, and it is separate from `Token` on purpose: removing
	the deadline must not cancel a deferred sweep that is scheduled.
]]
ButtonGateController.ReleaseToken = 0

-- The `PlayerGui` listener, connected only while a lock is up.
ButtonGateController.Connection = nil :: RBXScriptConnection?

--[[
	`[Instance] = connection`: what is **hiding** buttons right now, and the listener
	that says when it appears.

	A closed panel creates no children when it opens (it only becomes `Visible`), so
	without this the lock could not know the buttons inside it just came on screen.
	See `onScreen` and `watch`.
]]
ButtonGateController.Watched = {}

-- Is a sweep already scheduled for the end of this frame? See `schedule`.
ButtonGateController.Pending = false

--[[ INTERNAL ]]

--[=[
	A whitelist target becoming an instance. It comes in three forms:

	  - **screen path** (`"Interface.ReadyWave"`), resolved by
	    `HighlightController:Find`: the same depth-first lookup the step's `Highlight`
	    uses;
	  - **instance**, for callers that already hold the reference and do not need to
	    go through a path;
	  - **function**, for a piece with no fixed path because it is cloned at runtime:
	    the card on the shop table, the crate in the backpack, whatever the highlight is
	    hugging now. It can return **one** instance or a list of them: the speed menu
	    opens one clone per step, and there are several steps.

	**Everything is resolved on every sweep**, not once in `Lock`. That is what
	matters: the buy button is born when the shop opens, and a target resolved too
	early would be `nil` forever, leaving the whitelist without exactly the button the
	step asks for. The function exists for the same reason and goes further: it finds
	the target again every time, even if it was destroyed and recloned mid-step.
]=]
function ButtonGateController:resolve(entries : { any }?) : { Instance }
	local out = {}

	for _, entry in (entries or {}) do
		if type(entry) == "function" then
			-- A caller's target: an error inside it must not take down the sweep and leave
			-- half the screen locked.
			local success, found = pcall(entry)

			if not success then
				log:StudioWarn(`a whitelist target errored: {found}`)
			elseif typeof(found) == "Instance" then
				if found.Parent then
					table.insert(out, found)
				end
			elseif type(found) == "table" then
				for _, one in found do
					if typeof(one) == "Instance" and one.Parent then
						table.insert(out, one)
					end
				end
			end

			continue
		end

		if typeof(entry) == "Instance" then
			if entry.Parent then
				table.insert(out, entry)
			end

			continue
		end

		if type(entry) ~= "string" then
			continue
		end

		local highlight = self.Controllers.HighlightController
		local found = highlight and highlight:Find(entry)

		if found then
			table.insert(out, found)
		end
	end

	return out
end

--[=[
	The screens the lock does not touch, by name.

	The highlight is always one of them: its screen has no buttons, but sweeping it is
	wasted work every time. The rest comes from the caller: Cmdr is the usual case,
	because locking the console locks the very tool for unlocking.
]=]
function ButtonGateController:ignored(spec : any) : { [string] : boolean }
	local out = { [SharedConfig.HighlightConfig.Gui.Name] = true }

	for _, name in (spec.Ignore or {}) do
		out[name] = true
	end

	return out
end

--[=[
	The screen (`LayerCollector`) a button lives in, or `nil`.
]=]
local function screenOf(instance : Instance) : Instance?
	local current : Instance? = instance

	while current do
		if current:IsA("LayerCollector") then
			return current
		end

		current = current.Parent
	end

	return nil
end

--[=[
	Is the button **actually** on screen? Also returns **everything** hiding it.

	`Visible` is a property of each object, not of what is seen: a button inside a
	closed panel still has `Visible = true`. Being on screen means it is visible
	**and** its whole ancestry is visible, up to a `ScreenGui` that is enabled.

	The list includes **all** that hide it, not only the nearest, and that is not
	overcaution: the hotbar hides at two levels (the card and the container), and
	returning them one at a time loses the race. Listening only to the card, the frame
	where it reappears with the container still closed would spend the only
	notification there was; the container would open later, with nothing listening,
	and the card would be clickable outside the whitelist. With the whole ancestry
	listened to, either one redoes the math.
]=]
local function onScreen(instance : GuiObject) : (boolean, { Instance })
	local hiders = {}

	if not instance.Visible then
		table.insert(hiders, instance)
	end

	local current : Instance? = instance.Parent

	while current do
		if current:IsA("LayerCollector") then
			if not current.Enabled then
				table.insert(hiders, current)
			end

			return #hiders == 0, hiders
		end

		if current:IsA("GuiObject") and not current.Visible then
			table.insert(hiders, current)
		end

		current = current.Parent
	end

	-- Outside any screen: it is nowhere the player can see.
	return false, hiders
end

--[=[
	Is the button **inside** the target (or the target itself)? It is the `Block` check.
]=]
local function contains(target : Instance, button : Instance) : boolean
	return button == target or button:IsDescendantOf(target)
end

--[=[
	Is the button part of the target, in either direction? It is the `Allow` check.

	A parent counts along with a child: a clickable `CardWrapper` around the pointed
	card must not go dead while the card inside it works.
]=]
local function touches(target : Instance, button : Instance) : boolean
	return button == target or button:IsDescendantOf(target) or target:IsDescendantOf(button)
end

--[=[
	Restores a button to what it was and drops its listener.

	**The listener goes first**, before `Active` returns, not after: it exists exactly
	to hold the button in the state the lock wants, and restoring it with the listener
	connected would make the lock clamp down on its own restoration.
]=]
function ButtonGateController:restore(button : GuiButton)
	local state = self.Saved[button]
	if not state then return end

	self.Saved[button] = nil

	if state.Connection then
		state.Connection:Disconnect()
	end

	if button.Parent then
		button.Active = state.Active
		button.Selectable = state.Selectable
	end
end

--[=[
	Puts a button in the state the lock wants and holds it there.

	`want` is `false` for what the whitelist does not cover and `true` for what it
	covers: **the whitelist rules both ways**, not only for turning off. Turning on
	seems excessive until you see what happens without it: `RoundCardShopController`
	takes the card template off its own screen (`_template` clones the authored
	`CardWrapper` and destroys the original), and if the lock disabled the template
	first, `Active = false` travels in the clone. Every card in the offer is born dead,
	**including the one the step asks to buy**: the Weather Report card would have no
	click. A lock that only turns off cannot undo that, because the state it saved is
	the template's, not the clone's, which did not even exist.

	So the lock turns on whatever is in the whitelist. If another owner had disabled it
	on purpose, the whitelist wins: a step that points at a button and does not let it
	be clicked is a step that never closes. The original state is saved and returns on
	`Unlock`, as with any other button.

	The listener is what separates this from a loose `Active = false`. A button has
	more than one owner (`DifficultyController` restores the steps' `Active` when the
	vote closes, `ReadyController` turns its own back on every intermission) and none
	of them knows the tutorial is running. Without it, the first one to pass opens a
	hole in the whitelist that only a lucky sweep would close.

	There is no loop: the listener only acts when the value **differs** from what the
	lock wants, and writing the right value triggers nothing it responds to.
]=]
function ButtonGateController:enforce(button : GuiButton, want : boolean)
	local state = self.Saved[button]

	if state then
		if state.Want == want then
			-- Already ours and already wants the same thing; the listener handles the rest.
			return
		end

		--[[
			The whitelist changed its mind about this button from one step to the next.
			The original state is the one from the first time we saw it, and that is
			what must return at the end, so it is reused instead of reread from the
			screen, which now shows what **we** wrote.
		]]
		if state.Connection then
			state.Connection:Disconnect()
		end
	else
		state = { Active = button.Active, Selectable = button.Selectable }
	end

	state.Want = want
	self.Saved[button] = state

	state.Connection = button:GetPropertyChangedSignal("Active"):Connect(function()
		if self.Saved[button] ~= state or button.Active == want then return end

		button.Active = want
		button.Selectable = want
	end)

	button.Active = want
	button.Selectable = want
end

--[=[
	Keeps an eye on an ancestor that is hiding buttons.

	It is `onScreen`'s pair. A panel that opens creates no children (it only becomes
	`Visible`), and `DescendantAdded` has nothing to report: without this listener, the
	buttons that just came on screen would stay clickable until someone created a
	button somewhere.

	One listener per ancestor, not per button: it is a handful of panels against
	dozens of buttons, and what matters is the moment the panel appears.
]=]
function ButtonGateController:watch(hiders : { Instance })
	for _, hider in hiders do
		if self.Watched[hider] then
			continue
		end

		local property = if hider:IsA("LayerCollector") then "Enabled" else "Visible"

		self.Watched[hider] = hider:GetPropertyChangedSignal(property):Connect(function()
			self:schedule()
		end)
	end
end

--[=[
	Drops every visibility listener.
]=]
function ButtonGateController:unwatch()
	for _, connection in self.Watched do
		connection:Disconnect()
	end

	table.clear(self.Watched)
end

--[=[
	Applies the active lock: turns off what is left over, restores what is allowed
	again, and leaves the rest as it is.

	The difference is computed instead of unlocking and relocking the screen: the
	second way goes through an instant with everything on, and a sweep that happens in
	the middle of a click would let the click through.
]=]
function ButtonGateController:apply()
	local spec = self.Spec
	if not spec then return end

	local allow = self:resolve(spec.Allow)
	local block = self:resolve(spec.Block)
	local ignored = self:ignored(spec)

	-- `[GuiButton] = the Active the lock wants`. `nil` means "not my business".
	local wanted = {}

	for _, instance in PlayerGui:GetDescendants() do
		if not instance:IsA("GuiButton") then
			continue
		end

		local screen = screenOf(instance)
		if screen and ignored[screen.Name] then
			continue
		end

		--[=[
			A button off screen is left out of the math, both ways.

			You cannot click what you cannot see, so locking it buys nothing, and
			touching it **costs**: a screen that clones a hidden piece carries the
			`Active` the lock wrote on the template, and the template's owner cannot
			know that. Turning on would also go wrong, for a more immediate reason: the
			hotbar card stays disabled while the step's dialog is on screen, and lighting
			it there would allow dragging before the player finishes reading.

			Whatever is hiding the button starts being listened to, because a panel
			that opens creates no children: the math is redone when it appears.
		]=]
		local visible, hiders = onScreen(instance)
		if not visible then
			self:watch(hiders)

			continue
		end

		local permitted = false
		for _, target in allow do
			if touches(target, instance) then
				permitted = true
				break
			end
		end

		-- `Block` beats `Allow`: that is how you allow a whole panel and remove one button
		-- from inside it.
		if permitted then
			for _, target in block do
				if contains(target, instance) then
					permitted = false
					break
				end
			end
		end

		--[[
			A button the whitelist does not cover that was **already** disabled has
			another owner: `ToggleTower` locks upgrade and sell for the whole tutorial
			match. Taking it here would make `Unlock` turn it back on, and the other
			owner's lock would go away without it knowing.

			What the whitelist covers is taken either way, on or off: there the lock
			rules both ways (see `enforce`).
		]]
		if permitted or instance.Active then
			wanted[instance] = permitted
		end
	end

	-- Whatever left the math (the button went off screen, or stopped being our
	-- business) returns to what it was.
	for button in self.Saved do
		if wanted[button] ~= nil and button.Parent then
			continue
		end

		self:restore(button)
	end

	for button, want in wanted do
		self:enforce(button, want)
	end
end

--[=[
	Schedules a sweep for the end of the frame.

	A shop that opens puts three cards on screen in three consecutive
	`DescendantAdded`s, and sweeping the whole `PlayerGui` three times would pay the
	same price three times for the same result. `defer` batches them.
]=]
function ButtonGateController:schedule()
	if self.Pending then return end

	self.Pending = true

	local token = self.Token

	task.defer(function()
		self.Pending = false

		if self.Token ~= token or not self.Spec then return end

		self:apply()
	end)
end

--[=[
	Arms the valve: once the deadline passes, the lock drops and the output explains.
]=]
function ButtonGateController:armRelease(seconds : number?)
	if type(seconds) ~= "number" or seconds <= 0 then
		return
	end

	local token = self.ReleaseToken

	task.delay(seconds, function()
		if self.ReleaseToken ~= token or not self.Spec then return end

		log:StudioWarn(string.format(
			"the button lock has been up for %.0fs without being released; giving the screen back. "
				.. "If the step did not finish, its whitelist does not cover the button it asks for.",
			seconds
		))

		self:Unlock()
	end)
end

--[[ API ]]

--[=[
	Locks the screen, leaving clickable only what `Allow` says.

		Gate:Lock({
			Allow = { "Interface.ReadyWave", "SharedUIs.DialogGUI.Container" },
			Block = { "Interface.SkipPrompt" },
			Ignore = { "Cmdr" },
			Release = 90,
		})

	`Allow` and `Block` accept a screen path (from `PlayerGui`, like the step's
	`Highlight`), the instance directly, or a function that returns the instance, the
	last one for a piece cloned at runtime, which is found again on every sweep. See
	`resolve`.

	Calling with a lock up **replaces** the whitelist without freeing the screen in
	between: what stays forbidden stays off, and only the difference moves. That keeps
	the screen from flashing fully clickable between one step and the next.
]=]
function ButtonGateController:Lock(spec : any)
	if type(spec) ~= "table" then return end

	self.Token += 1
	self.ReleaseToken += 1
	self.Spec = spec

	-- The listeners are rebuilt by the sweep: what hides a button changes from one
	-- whitelist to the next.
	self:unwatch()

	if not self.Connection then
		--[[
			The shop table, the card going to the hand, the crate list: all are born with
			the lock already up, and without this listener they would be born clickable.
			It filters by `GuiButton` before scheduling the sweep because
			`DescendantAdded` on `PlayerGui` fires for every `UIStroke` and `TextLabel`
			on every screen.
		]]
		self.Connection = PlayerGui.DescendantAdded:Connect(function(instance)
			if instance:IsA("GuiButton") then
				self:schedule()
			end
		end)
	end

	self:apply()
	self:armRelease(spec.Release)
end

--[=[
	Frees the screen: each button returns to the `Active` and `Selectable` it had.
]=]
function ButtonGateController:Unlock()
	self.Token += 1
	self.ReleaseToken += 1
	self.Spec = nil

	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end

	self:unwatch()

	for button in self.Saved do
		self:restore(button)
	end

	table.clear(self.Saved)
end

--[=[
	Removes the valve's deadline without releasing the lock.

	It is what a completed step calls. The valve exists for a step that **did not
	recognize** what the player did; a step already completed must not be unlocked by
	it: the wave is running, there is nothing to click, and freeing the screen there
	would release the player mid-script for having waited.
]=]
function ButtonGateController:HoldRelease()
	if not self.Spec then return end

	-- The new number is what makes the valve scheduled in `Lock` give up when it wakes.
	self.ReleaseToken += 1
end

--[=[
	Reapplies the active lock. It is for code that changed the screen from outside and
	wants the math redone now, instead of at the next button that is born.
]=]
function ButtonGateController:Refresh()
	if not self.Spec then return end

	self:apply()
end

function ButtonGateController:IsLocked() : boolean
	return self.Spec ~= nil
end

--[[ LIFECYCLE ]]

function ButtonGateController:start()
end

function ButtonGateController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
end

return ButtonGateController
