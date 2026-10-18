local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local LightingUtil = require(Util.LightingUtil)
local Log = require(Util:WaitForChild("Log"))
local Me = require(Vendor.Me)

local Framework = Me.new()
local log = Log.new("DialogController")

local Config = SharedConfig.DialogConfig

-- Frames of patience with the box's layout before the first line. See
-- `waitForLayout`.
local LAYOUT_FRAMES = 4

-- What `:Play()` understands and `RichTextController` does not: they belong to the
-- conversation, not the text, so they do not go down to the render.
local DIALOG_ONLY_OPTIONS = {
	Auto = true,
	Buttons = true,
	ButtonsAtEnd = true,
	HideUI = true,
	Blur = true,
	Duck = true,
	Locked = true,
	MinRead = true,
}

--[[
	The dialog box: `SharedUIs.DialogGUI.Container`.

	This controller is the **only** one that touches it. Anything with something to
	say sends the finished lines:

		local Dialog = Framework:Get("DialogController")

		Dialog:Play({
			"Welcome to [color=yellow]Periastron[/color].[pause=.6] Have a seat.",
			"Wave 8 brings a [shake]BLIZZARD[/shake].",
		})

	The text is written by `RichTextController`, so the usual markup applies here,
	including `[event=name]`, which reaches `:OnEvent()` subscribers when typing passes
	the mark. It is the hook for syncing sound, camera, or VFX with a point in the
	sentence instead of a guessed `task.wait`.

	**One line at a time, and the player advances.** Click, tap, `E`, space, enter, or
	the gamepad's A: with the line still being written, the gesture shows it whole;
	with it done, it goes to the next; on the last, it closes. It is the contract every
	dialog game has, and the player knows it before anyone explains. A line requested
	with `Auto = true` advances on its own after `DialogConfig.AutoHold` seconds.

	**The box's two buttons** (`Button1` on the right, `Button2` on the left) receive
	text, appear, disappear, and call whatever the requester sends:

		Dialog:Play("Accept the contract?", {
			Buttons = {
				{ Text = "ACCEPT", OnClick = function() Contracts:Accept() end },
				{ Text = "NOT NOW", OnClick = function() Dialog:Close() end },
			},
		})

	Outside `:Play()` they are changed through `:SetButton(index, spec)`,
	`:SetButtons`, `:ClearButtons`, and `:GetButton`; the last returns the ImageButton
	for anyone who wants to swap the image, animate, or put an icon inside. A button
	**without** `OnClick` advances the dialog, which is the most likely intent of
	someone pressing a button in a conversation. A line that asks for no buttons
	starts without buttons: an old conversation's choice on the new one's screen is a
	bug that only shows up in the player's hands.

	**Behind the dialog**, the screen gets out of the way: the rest of the UI hides
	(through `InterfaceController`, the same "hide everything else" as the cutscene
	and the panels), the background blurs (the shared `UIBlur`, tweened in and out),
	and the music lowers (`MusicController:Duck`, which does not touch the volume the
	player chose). All three are turned on by `DialogConfig.Background` and can be
	turned off per line: `Dialog:Play(text, { Blur = false })`.

	**The screen lives in the place, not in git**: `StarterGui` is not synced by Rojo.
	That is why the path is by name (`DialogConfig.Gui`) and resolved late:
	`SharedUIs` may not have replicated when the controller loads, and a
	`WaitForChild` in `init` would hold up the client boot for a box that may not even
	be used this session.

	It lives in `common/` because both places have `SharedUIs`.

	See docs/common/dialog.md.
]]

local DialogController = {
	Controllers = {
		RichTextController = {},

		-- The dialog's background: what hides the rest of the UI and what lowers the music.
		-- Both already existed for the cutscene and the panels; here they are only requested.
		InterfaceController = {},
		MusicController = {},
	}
}

DialogController.Container = nil :: GuiObject?
DialogController.Screen = nil :: ScreenGui?

--[[
	Has the box appeared at least once this session?

	It is what separates "this place has no dialog box" from "the box died and is
	coming back". Without the difference, `getContainer` would have to choose between
	never waiting (and losing every line requested right after a respawn) and always
	waiting (and blocking every `Play` for ten seconds in a place without `SharedUIs`).
]]
DialogController.Existed = false
DialogController.Handle = nil :: any

-- The conversation on screen.
DialogController.Lines = {} :: { string }
DialogController.Index = 0
DialogController.Open = false

-- A dialog that advances on its own, without the player.
DialogController.Auto = false
-- A dialog the player cannot fast-forward: no skipping the typing, and each line
-- holds for `MinRead` seconds after it finishes before a click continues.
DialogController.Locked = false
DialogController.MinRead = 0
DialogController.LineStartedAt = 0
DialogController.LineFinishedAt = nil :: number?

-- One session per `:Play()`: auto mode's `task.delay` only applies while nobody
-- has started another conversation on top.
DialogController.Session = 0

DialogController.LastAdvance = 0
DialogController.Listeners = {}

--[[
	The current dialog's options, saved so it can return the same after a respawn
	(see `Respawn` in `DialogConfig` and the `Destroying` in `:Play`).
]]
DialogController.Options = nil :: any

--[[
	The dialog waiting for the new box, when the player died in the middle of it.
	`nil` when nothing is coming back.

	`IsOpen()` answers `false` during that gap (the box really is not on screen), so
	code that needs to know more dialog is coming asks `IsResuming()`.
]]
DialogController.Resume = nil :: any

-- Goes up on every scheduled return and every `:Play()`. It is what makes a new
-- dialog cancel the previous one's return instead of the two fighting over the box.
DialogController.ResumeToken = 0

-- Who wants to know when the box closed. See `:OnClosed`.
DialogController.ClosedListeners = {}
DialogController.Warned = false

-- [index] = { Instance, Label, OnClick }. Filled the first time the button is used
-- and emptied along with the container (see `getContainer`).
DialogController.ButtonSlots = {}

-- Buttons waiting for the last sentence to finish (`ButtonsAtEnd`). Nil when there
-- is no pending choice.
DialogController.PendingButtons = nil :: { any }?

-- What the dialog took from the screen now: the rest of the UI hidden, the blur up,
-- the music ducked. Saved so closing returns exactly what opening took: no more
-- (a blur from a panel that is not ours) and no less.
DialogController.Background = { UI = false, Blur = false, Duck = false }
DialogController.BlurTween = nil :: Tween?

--[[ INTERNAL ]]

--[=[
	The box, the first time it is needed.

	Cached once found, and found again when its `Parent` goes away: `PlayerGui` is
	rebuilt on every respawn and the old reference becomes garbage.

	**If it existed and vanished, we wait for it.** `DialogGUI` has `ResetOnSpawn`:
	respawning destroys the screen and the new one only arrives a few frames later,
	when the `StarterGui` clone happens. A line requested in that gap (exactly the case
	of the tutorial flow restarting on `CharacterAdded`) would find no box, `:Play()`
	would return `false`, and whoever waited on `OnClosed` would wait forever: no
	dialog on screen and the script stalled.

	The wait is **only** for sessions that have seen the box once (see `Existed`). A
	place without `SharedUIs` still answers `nil` immediately: there is nothing to
	wait for there.
]=]
function DialogController:getContainer() : GuiObject?
	local container = self.Container
	if container and container.Parent then
		return container
	end

	local gui = Config.Gui
	local respawn = Config.Respawn or {}

	local function look() : GuiObject?
		local folder = PlayerGui:FindFirstChild(gui.Folder)
		local screen = folder and folder:FindFirstChild(gui.Screen)
		local found = screen and screen:FindFirstChild(gui.Container)

		return if found and found:IsA("GuiObject") then found :: GuiObject else nil
	end

	local found = look()

	if not found and self.Existed then
		local deadline = os.clock() + (respawn.Timeout or 10)

		repeat
			task.wait(respawn.Interval or 0.2)

			found = look()
		until found or os.clock() > deadline

		if not found then
			log:StudioWarn("the dialog box did not come back after the respawn.")
		end
	end

	if not found then
		self:warnMissing()

		return nil
	end

	local screen = found.Parent

	self.Existed = true
	self.Container = found
	self.Screen = if screen and screen:IsA("ScreenGui") then screen else nil

	-- The handle belongs to the container: a new container (respawn, recreated screen)
	-- needs a new handle, or we would write into a frame no longer on screen. The
	-- buttons are its children and die with it; their cache goes away for the same reason.
	self.Handle = nil
	table.clear(self.ButtonSlots)

	return found
end

--[=[
	The button at the index, ready to use: found inside the container, with its text
	label created and its click already connected.

	The label is created here, not authored in Studio, because the button is an
	ImageButton: it has no text of its own. Created here, any new button the designer
	adds to the box gets centered text without anyone having to remember anything.

	`nil` when there is no button at that index: the box belongs to the place, and a
	place with a single button (or none) is not an error, it is a different screen.
]=]
function DialogController:getButton(index : number) : any
	local slot = self.ButtonSlots[index]
	if slot and slot.Instance.Parent then
		return slot
	end

	local container = self:getContainer()
	local name = Config.Buttons.Names[index]
	if not container or not name then
		return nil
	end

	local instance = container:FindFirstChild(name)
	if not instance or not instance:IsA("GuiButton") then
		return nil
	end

	local labelConfig = Config.Buttons.Label

	local label = instance:FindFirstChild(labelConfig.Name)
	if not label or not label:IsA("TextLabel") then
		label = Instance.new("TextLabel")
		label.Name = labelConfig.Name
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = ""
		label.TextColor3 = labelConfig.Color
		label.Font = labelConfig.Font
		label.TextScaled = true
		label.TextWrapped = true

		-- The click belongs to the button, not the label: otherwise the label would eat
		-- the tap in the middle of the button, which is exactly where the finger lands.
		label.Active = false

		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, labelConfig.Padding)
		padding.PaddingBottom = UDim.new(0, labelConfig.Padding)
		padding.PaddingLeft = UDim.new(0, labelConfig.Padding)
		padding.PaddingRight = UDim.new(0, labelConfig.Padding)
		padding.Parent = label

		-- `TextScaled` alone would turn "OK" into poster-sized text.
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = labelConfig.MaxTextSize
		constraint.Parent = label

		label.Parent = instance
	end

	slot = {
		Instance = instance,
		Label = label,
		OnClick = nil,
	}

	self.ButtonSlots[index] = slot

	-- One connection per button, forever: it calls whatever callback **is** in the slot
	-- at click time. Reconnecting on every `:SetButton()` would be a recipe for one
	-- click firing three times.
	instance.Activated:Connect(function()
		local current = self.ButtonSlots[index]
		if not current then return end

		if current.OnClick then
			task.spawn(current.OnClick, index)

			return
		end

		-- A button without a callback is a "continue": the most likely intent of someone
		-- pressing a button in a dialog is wanting the next line.
		self:Advance(true)
	end)

	return slot
end

--[=[
	Noise when the box does not show up, only once, so a recurring line does not
	become spam.

	A place without `SharedUIs` is not a mistake and does not deserve a warning: the
	screen simply does not exist there. `SharedUIs` existing **without** `DialogGUI`
	is a mistake, and that one does.
]=]
function DialogController:warnMissing()
	if self.Warned then return end
	if not PlayerGui:FindFirstChild(Config.Gui.Folder) then return end

	self.Warned = true
	log:StudioWarn(`could not find {Config.Gui.Folder}.{Config.Gui.Screen}.{Config.Gui.Container} in PlayerGui.`)
end

--[=[
	The container's text handle, created once and reused.

	This is where a line's `[event=]` becomes the subscriber's `:OnEvent()`: the
	subscription is on the handle, and there is a single handle, so it does not
	multiply with each line.
]=]
function DialogController:getHandle(options : any) : any
	local container = self:getContainer()
	if not container then
		return nil
	end

	local RichText = self.Controllers.RichTextController

	if self.Handle then
		self.Handle:SetOptions(options)

		return self.Handle
	end

	local handle = RichText:Bind(container, options)
	if not handle then
		return nil
	end

	handle:OnEvent(function(name : string)
		for _, listener in self.Listeners do
			task.spawn(listener, name)
		end
	end)

	self.Handle = handle

	return handle
end

--[=[
	Shows or hides the box.

	It touches the ScreenGui's `Enabled` **and** the frame's `Visible`: the designer
	may have left either one on in Studio, and the box showing up empty on spawn is
	the easiest bug to prevent from here.
]=]
function DialogController:setVisible(visible : boolean)
	local container = self.Container
	if container then
		container.Visible = visible
	end

	local screen = self.Screen
	if screen then
		screen.Enabled = visible
	end
end

--[=[
	Puts the background in the requested state: the rest of the UI, the blur, and the
	music.

	It works by difference instead of "apply everything": a new line starting on top
	of another must not drop the blur to zero and raise it again; that would be a
	flicker in the middle of a conversation that, for the player, never stopped.

	Each piece is optional because each may not exist in the place: without
	`InterfaceController` the dialog appears with the whole UI behind it, which is ugly,
	not broken.
]=]
function DialogController:applyBackground(wanted : { UI : boolean, Blur : boolean, Duck : boolean })
	local active = self.Background
	local background = Config.Background

	if wanted.UI ~= active.UI then
		local interface = self.Controllers.InterfaceController

		if interface then
			if wanted.UI then
				-- The `Except` is a safeguard: `DialogGUI` lives inside the `SharedUIs` folder, and
				-- `InterfaceController` only tracks direct children of PlayerGui, so today it does
				-- not even enter the math. Someone moving the screen out of the folder tomorrow
				-- should not find out by the dialog vanishing.
				interface:Hide(background.HideReason, { Except = { Config.Gui.Screen } })
			else
				interface:Show(background.HideReason)
			end
		end
	end

	if wanted.Blur ~= active.Blur then
		local blur = background.Blur

		-- One tween at a time: `Cancel` does not restore the property, so closing mid-open
		-- goes down from wherever the rise got to.
		if self.BlurTween then
			self.BlurTween:Cancel()
			self.BlurTween = nil
		end

		local info = TweenInfo.new(
			if wanted.Blur then blur.TweenIn else blur.TweenOut,
			blur.EasingStyle,
			blur.EasingDirection
		)

		self.BlurTween = LightingUtil.TweenUIBlur(if wanted.Blur then blur.Size else 0, info)
	end

	if wanted.Duck ~= active.Duck then
		local music = self.Controllers.MusicController

		if music then
			if wanted.Duck then
				music:Duck(background.Duck.Scale, background.Duck.FadeIn)
			else
				music:Unduck(background.Duck.FadeOut)
			end
		end
	end

	self.Background = wanted
end

--[=[
	Returns everything the dialog took. It is what closing calls, and it is safe to call
	twice: `applyBackground` only touches what differs.
]=]
function DialogController:releaseBackground()
	self:applyBackground({ UI = false, Blur = false, Duck = false })
end

--[=[
	Waits for the box to have a real size before writing into it.

	Two reasons. The renderer **draws nothing** in a container that measures zero, and
	a freshly enabled ScreenGui measures zero until the next layout frame: the line
	simply would not appear. And the container's size at render time is the scale
	reference for that line's text: taking it before layout (before
	`UIAspectRatioConstraint`) pins the scale to a size that never existed on screen.

	The frame budget exists for a box that never gets a size (a screen disabled by
	another controller): that becomes a line with no effect, not an infinite wait.
]=]
function DialogController:waitForLayout(container : GuiObject)
	local previous = container.AbsoluteSize

	for _ = 1, LAYOUT_FRAMES do
		RunService.Heartbeat:Wait()

		local current = container.AbsoluteSize
		if current.Magnitude > 0 and current == previous then
			return
		end

		previous = current
	end
end

--[=[
	Writes the line the conversation is on.
]=]
function DialogController:write(session : number)
	local handle = self.Handle
	local line = self.Lines[self.Index]
	if not handle or not line then return end

	local isLast = self.Index >= #self.Lines

	self.LineStartedAt = os.clock()
	self.LineFinishedAt = nil

	handle:Write(line)

	if not self.Auto and not self.Locked and not (isLast and self.PendingButtons) then return end

	-- One subscription per line, undone on the first firing: the next line subscribes
	-- its own, and without this the third sentence would call three callbacks.
	local disconnect
	disconnect = handle:OnFinished(function()
		if disconnect then
			disconnect()
		end

		if self.Session ~= session then return end

		self.LineFinishedAt = os.clock()

		-- The choice only appears once the last sentence finished being written: buttons
		-- up while the text is still arriving invite the player to answer a question they
		-- have not read yet. Skipping the typing also lands here, which keeps players in a
		-- hurry from ending up without the buttons.
		if isLast and self.PendingButtons then
			self:SetButtons(self.PendingButtons)
			self.PendingButtons = nil
		end

		if not self.Auto then return end

		task.delay(Config.AutoHold, function()
			if self.Session ~= session then return end
			if not self.Open then return end

			self:Advance(true)
		end)
	end)
end

--[=[
	Is there a choice on screen? That is a visible button **with** its own callback.

	A button without a callback is a "continue" and holds nothing; a button with a
	callback is a question, and while it is on screen a click on empty space must not
	close the box, or the answer is lost on the first distracted click.
]=]
function DialogController:hasChoice() : boolean
	for index in Config.Buttons.Names do
		local slot = self.ButtonSlots[index]

		if slot and slot.OnClick and slot.Instance.Visible then
			return true
		end
	end

	return false
end

--[[ API ]]

export type ButtonSpec = {
	Text : string?,
	Visible : boolean?,
	OnClick : ((index : number) -> ())?,

	-- Font family path (`rbxasset://fonts/families/....json`) for this button.
	-- Without it, `DialogConfig.Buttons.Label.Font` applies.
	Font : string?,
}

export type PlayOptions = {
	Auto : boolean?,
	Preset : string?,
	Speed : number?,
	Font : string?,
	Buttons : { ButtonSpec }?,

	-- `true` holds the buttons until the last sentence finishes being written. It is what
	-- a question wants: the choice appears after the player reads what was
	-- asked.
	ButtonsAtEnd : boolean?,

	-- The background: hide the rest of the UI, blur the screen, duck the music. With no
	-- value, `DialogConfig.Background` applies.
	HideUI : boolean?,
	Blur : boolean?,
	Duck : boolean?,
}

--[=[
	Changes one of the box's buttons. Only what comes in `spec` changes:

		Dialog:SetButton(1, {
			Text = "ACCEPT",
			OnClick = function()
				Contracts:Accept()
				Dialog:Close()
			end,
		})

		Dialog:SetButton(2, { Text = "NOT NOW", Visible = true })

	`Text` goes centered in a label inside the button. `Visible` turns the button on
	and off. `OnClick` is the callback, and it is free-form: it receives the index and
	need not return anything. A button **without** a callback works as "continue":
	the click advances the dialog.

	Passing `Text` turns the button on by itself, because writing on an invisible
	button is always a mistake. To write and keep it hidden, send `Visible = false`
	along.

	Returns `false` if there is no button at that index in this place.
]=]
function DialogController:SetButton(index : number, spec : ButtonSpec) : boolean
	local slot = self:getButton(index)
	if not slot then
		return false
	end

	if spec.Font ~= nil then
		local success, font = pcall(Font.new, spec.Font)
		if success then
			slot.Label.FontFace = font
		else
			log:StudioWarn(`invalid font on button {index}: {spec.Font}`)
		end
	end

	if spec.Text ~= nil then
		slot.Label.Text = spec.Text
		slot.Instance.Visible = true
	end

	if spec.Visible ~= nil then
		slot.Instance.Visible = spec.Visible
	end

	if spec.OnClick ~= nil then
		slot.OnClick = spec.OnClick
	end

	return true
end

--[=[
	Both at once, in `DialogConfig.Buttons.Names` order. An index with no spec in the
	list is cleared: that is what makes `{ {...} }` leave only the first on screen.
]=]
function DialogController:SetButtons(specs : { ButtonSpec })
	for index in Config.Buttons.Names do
		local spec = specs[index]

		if spec then
			self:SetButton(index, spec)
		else
			self:SetButton(index, { Visible = false, Text = "" })
		end
	end
end

--[=[
	Clears both and forgets the callbacks.

	It is what runs when a line starts without asking for buttons and when the box
	closes: a conversation's choices must not outlive it. A callback from an old line
	on a new line's button is the kind of bug that only shows up in the player's
	hands.
]=]
function DialogController:ClearButtons()
	for index in Config.Buttons.Names do
		local slot = self:getButton(index)
		if not slot then continue end

		slot.OnClick = nil
		slot.Label.Text = ""
		slot.Instance.Visible = false
	end
end

--[=[
	The button itself, for anyone who wants to do what this API does not: swap the
	image, animate, put an icon inside. It is the escape hatch for "customized any
	way".
]=]
function DialogController:GetButton(index : number) : GuiButton?
	local slot = self:getButton(index)

	return slot and slot.Instance
end

--[=[
	The box died with the dialog open: saves what is left to say and releases what is
	outside it.

	What remains is from `Index` on, not the whole dialog: the player already read what
	they read, and restarting from zero makes them read the same thing twice as
	punishment for dying. The options are the same (the same background, the same
	buttons, the same auto mode), because the dialog is the same; only the box is
	different.

	The background is returned **now**, not on return: the blur and the hidden UI
	belong to the screen that just died, and leaving them up while the new box has not
	arrived is exactly the stuck screen this block exists to prevent. The return asks
	for them again, because it goes through the full `:Play()`.
]=]
function DialogController:noteDestroyed()
	local remaining = {}
	for index = math.max(1, self.Index), #self.Lines do
		table.insert(remaining, self.Lines[index])
	end

	self.Session += 1
	self.Open = false
	self.Lines = {}
	self.Index = 0
	self.PendingButtons = nil

	self:releaseBackground()

	if #remaining == 0 then
		-- Nothing left to say: the dialog had ended, and this is a close like any
		-- other.
		self:fireClosed()

		return
	end

	self.ResumeToken += 1
	local token = self.ResumeToken

	self.Resume = { Lines = remaining, Options = self.Options }

	task.spawn(function()
		self:awaitResume(token)
	end)
end

--[=[
	Waits for the new box to appear and rewrites what was missing into it.

	The box does not return on the same frame the old one dies: `ResetOnSpawn` only
	reclones `StarterGui` when the new character enters, and between the two there is
	the server's respawn time. That is why it waits, rather than trying once.

	When it gives up (see `Respawn.Timeout`), whoever waited on `:OnClosed()` **is
	notified**. That line is what keeps a tutorial step from stalling forever waiting
	for a dialog that will not come back: better the step continues without the
	instruction than the player stuck on a screen that does not respond.
]=]
function DialogController:awaitResume(token : number)
	local respawn = Config.Respawn or {}
	local deadline = os.clock() + (respawn.Timeout or 10)

	while os.clock() < deadline do
		if self.ResumeToken ~= token then return end

		local container = self:getContainer()

		if container and container.Parent then
			local resume = self.Resume

			self.Resume = nil

			if resume then
				self:Play(resume.Lines, resume.Options)
			end

			return
		end

		task.wait(respawn.Interval or 0.2)
	end

	if self.ResumeToken ~= token then return end

	log:StudioWarn("the dialog box did not come back after the respawn; the line was lost.")

	self.Resume = nil
	self:fireClosed()
end

--[=[
	Notifies `:OnClosed()` subscribers. In `task.spawn` because the callback is external:
	an error in it must not take down the code closing the box.

	**It walks a copy of the list.** `task.spawn` runs the callback right away, and a
	callback that unsubscribes itself (the tutorial step does, first thing) removes
	its entry mid-loop: walking the live list, the next subscriber slides into the
	freed slot and the loop steps past it, so every second listener was never told the
	box closed. That is what left the tutorial's wave 3 waiting on a read that never
	came.
]=]
function DialogController:fireClosed()
	for _, listener in table.clone(self.ClosedListeners) do
		task.spawn(listener)
	end
end

--[=[
	Puts a conversation on screen. `lines` is one sentence or a list of them.

	Returns `false` when it could not: a box that does not exist in this place, or rich
	text with no backend at all. A new conversation always replaces the one on screen:
	dialog is an interruption, and queuing old dialog behind new is how the player
	ends up reading the previous wave's warning.
]=]
function DialogController:Play(lines : string | { string }, options : PlayOptions?) : boolean
	local list = if type(lines) == "table" then lines else { lines }
	if #list == 0 then
		return false
	end

	local resolved = table.clone(Config.Text)
	if options then
		for key, value in options do
			-- A conversation option is not a text option: sending it to
			-- `RichTextController` would only become an unknown option in there.
			if DIALOG_ONLY_OPTIONS[key] then continue end

			resolved[key] = value
		end
	end

	local handle = self:getHandle(resolved)
	if not handle then
		return false
	end

	self.Session += 1
	local session = self.Session

	-- A scheduled return from a previous dialog must not write over this one.
	self.ResumeToken += 1
	self.Resume = nil

	-- Saved so the dialog can return the same after a respawn (see the
	-- `Destroying` further below).
	self.Options = options

	self.Lines = list
	self.Index = 1
	self.Auto = options and options.Auto or false
	self.Locked = options ~= nil and options.Locked == true
	self.MinRead = math.max(0, (options and tonumber(options.MinRead)) or 0)
	self.Open = true
	self.LastAdvance = os.clock()

	-- A line that asked for no buttons enters without buttons: the previous
	-- conversation's choices must not stay on screen over this one. Requests with
	-- `ButtonsAtEnd` are held until the last sentence ends (see `write`).
	self:ClearButtons()
	self.PendingButtons = nil

	if options and options.Buttons then
		if options.ButtonsAtEnd then
			self.PendingButtons = options.Buttons
		else
			self:SetButtons(options.Buttons)
		end
	end

	--[=[
		`DialogGUI` has `ResetOnSpawn`: dying with the dialog open **destroys the box**.

		Without this the close would never come: the blur would stay on screen and the
		rest of the UI hidden until the player left the server. Worse than the blur:
		whoever waits on `:OnClosed()` (the tutorial step, the Lobby flow) would wait
		forever for a notification that never comes.

		It is not a `:Close()` on purpose: the box and buttons no longer exist, and
		clearing them would write to destroyed instances. Here only what is **outside**
		the dead screen is undone, and the dialog's return is scheduled (see
		`awaitResume`).
	]=]
	local container = self.Container
	if container then
		container.Destroying:Once(function()
			if not self.Open or self.Session ~= session then return end

			self:noteDestroyed()
		end)
	end

	local background = Config.Background
	local function wanted(option : any, default : boolean) : boolean
		if option == nil then
			return default
		end

		return option == true
	end

	self:applyBackground({
		UI = wanted(options and options.HideUI, background.HideOtherUIs),
		Blur = wanted(options and options.Blur, background.Blur.Enabled),
		Duck = wanted(options and options.Duck, background.Duck.Enabled),
	})

	self:setVisible(true)
	self:waitForLayout(self.Container :: GuiObject)

	-- Another conversation may have started while we waited for layout.
	if self.Session ~= session then
		return true
	end

	self:write(session)

	return true
end

--[=[
	The player's gesture: shows the whole line if it is still being written,
	otherwise goes to the next, and closes if it was the last.

	`ignoreDebounce` is for callers that are not a finger: auto mode does not need
	protection from itself.
]=]
function DialogController:Advance(ignoreDebounce : boolean?) : boolean
	if not self.Open then
		return false
	end

	local handle = self.Handle

	-- A locked dialog cannot be fast-forwarded: nothing while the line is typing, and
	-- nothing until it has been on screen, finished, for `MinRead` seconds.
	if self.Locked and handle then
		if handle:IsWriting() then
			return false
		end

		local readyAt = (self.LineFinishedAt or self.LineStartedAt) + self.MinRead
		if os.clock() < readyAt then
			return false
		end
	end

	if not ignoreDebounce then
		local now = os.clock()
		if now - self.LastAdvance < Config.Advance.Debounce then
			return false
		end

		self.LastAdvance = now
	end

	if not handle then
		self:Close()

		return false
	end

	if handle:IsWriting() then
		handle:Skip()

		return true
	end

	if self.Index >= #self.Lines then
		-- Last sentence with a choice on screen: the box stays. The button closes it, and
		-- that is why the question does not die to a distracted click on the scenery.
		if self:hasChoice() then
			return false
		end

		self:Close()

		return false
	end

	self.Index += 1
	self:write(self.Session)

	return true
end

--[=[
	Closes the box and forgets the conversation.
]=]
function DialogController:Close()
	self.Session += 1
	self.Open = false
	self.Lines = {}
	self.Index = 0
	self.Locked = false
	self.MinRead = 0
	self.LineFinishedAt = nil

	if self.Handle then
		self.Handle:Clear(true)
	end

	self.PendingButtons = nil
	self:ClearButtons()
	self:releaseBackground()
	self:setVisible(false)

	-- A gesture close cancels the return of a dialog that was waiting for a box.
	self.ResumeToken += 1
	self.Resume = nil

	self:fireClosed()
end

--[=[
	Is more dialog coming?

	`true` in the gap between the box dying with the player and the new box arriving.
	It is what separates "the dialog is over" from "the dialog is coming back" for
	code deciding what to put on screen now: the tutorial step must not light the
	highlight over an instruction a second away from reappearing.
]=]
function DialogController:IsResuming() : boolean
	return self.Resume ~= nil
end

function DialogController:IsOpen() : boolean
	return self.Open
end

--[=[
	Calls back when the box closes: by player gesture, by button, or at the end of an
	auto dialog. Returns the unsubscribe function.

	It is what allows chaining: code that wants to show something **after** the dialog
	waits here instead of guessing a `task.wait`.
]=]
function DialogController:OnClosed(callback : () -> ()) : () -> ()
	table.insert(self.ClosedListeners, callback)

	return function()
		local index = table.find(self.ClosedListeners, callback)
		if index then
			table.remove(self.ClosedListeners, index)
		end
	end
end

--[=[
	Calls back when typing passes an `[event=name]`. Returns the unsubscribe function.
]=]
function DialogController:OnEvent(callback : (name : string) -> ()) : () -> ()
	table.insert(self.Listeners, callback)

	return function()
		local index = table.find(self.Listeners, callback)
		if index then
			table.remove(self.Listeners, index)
		end
	end
end

--[[ LIFECYCLE ]]

function DialogController:construct()
	-- The server tells it to speak. `DialogService` fires it, and Cmdr goes through it
	-- for testing.
	Framework:Listen("DialogPlay", function(lines : any, options : any)
		if type(lines) ~= "table" and type(lines) ~= "string" then return end

		self:Play(lines, if type(options) == "table" then options else nil)
	end)

	UserInputService.InputBegan:Connect(function(input : InputObject, gameProcessed : boolean)
		if not self.Open then return end

		-- `gameProcessed` is the player typing in chat or Cmdr: the key belongs there,
		-- not to the dialog.
		if gameProcessed then return end

		local advance = Config.Advance
		local kind = input.UserInputType

		local pressed = (advance.Mouse and kind == Enum.UserInputType.MouseButton1)
			or (advance.Touch and kind == Enum.UserInputType.Touch)
			or (kind == Enum.UserInputType.Keyboard or kind == Enum.UserInputType.Gamepad1)
			and table.find(advance.Keys, input.KeyCode) ~= nil

		if not pressed then return end

		self:Advance()
	end)
end

function DialogController:start()
	-- An empty box on the spawn screen is the cheapest bug to prevent: the designer
	-- authors `DialogGUI` visible to see it in Studio. The buttons enter the same math:
	-- they are born visible there, with whatever test text they have.
	if self:getContainer() then
		self:ClearButtons()
		self:setVisible(false)
	end
end

function DialogController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return DialogController
