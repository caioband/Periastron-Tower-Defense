local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("HighlightController")

local Config = SharedConfig.HighlightConfig

--[[
	The spotlight: the screen darkens except for a rectangle around a GuiObject.

		local Highlight = Framework:Get("HighlightController")

		Highlight:Show(shopButton)
		Highlight:Show(deckButton, { Padding = 16 })   -- slides from the previous one
		Highlight:Hide()

	**The technique is a giant `UIStroke`.** A transparent frame with a ten-thousand
	pixel `UIStroke` paints everything **outside** it: the frame is the hole, the
	stroke is the dark, `UICorner` rounds it, and there is no image, four-part mask,
	or `EditableImage` to keep aligned. It is the solution the DevForum converges on
	for this effect, and the cheapest of all: one instance.

	**A finger points at it.** A pointing hand sits under the hole (or over it, upside
	down, when there is no room below) and jabs towards it, so the player's eye goes
	to the target even when the dark alone is easy to miss. `Show(target, { Finger =
	false })` leaves it out. See `HighlightConfig.Finger`.

	**Clicking is another matter, and by default the highlight stays out of it.** A
	stroke receives no input (it is an outline, not a surface), and blocking (four
	`Active` frames around the hole, the four-mask technique) only comes in when the
	caller asks: `Show(target, { BlockInput = true })`.

	The default is not to block because a highlight is not modal: pointing at a card
	must not stop the player from turning the camera or clicking the ground. Blocking
	only makes sense when the target is the only clickable thing in the step: a UI
	button, never a place on the map.

	**It does not disappear with "hide everything else".** The screen is created
	with the `IgnoreInterfaceHide` mark, which `InterfaceController` respects:
	proximity panels and the shop hide the HUD when opening, and a highlight that
	vanished with it would only point at what was already on screen, never at what is
	inside the panel that just opened.

	**Alignment is measured, not computed.** `AbsolutePosition` lives in the space
	with the top bar inset: in a `ScreenGui` with `IgnoreGuiInset = true` (this one's
	case, so the dark covers the top strip), a frame at the top-left corner reports
	`(0, -36)`. Roblox does this on purpose, for compatibility. Instead of adding 36
	by hand (or calling `GuiService:GetGuiInset`, which returns zero in the first
	frames after boot, exactly when a tutorial runs), the controller keeps a zero-size
	probe frame at its own screen's origin and reads its position. The difference
	between the probe and the target is the answer, and it stays right on any device,
	with or without inset, even if the rule changes.

	**It follows the target.** The highlight reacts to the target's `AbsolutePosition`
	and `AbsoluteSize` and to the viewport size, and does not sweep the screen every
	frame: the usual example's `RenderStepped` redraws sixty times a second for a HUD
	button that does not move.

	**Nothing here is hard-coded pixels.** Position and size are copied from the
	target, so they hold at any resolution; padding and corner radius are fractions of
	the target's smaller side, with a floor and ceiling, because 8px of padding on a
	200px button is a detail and on the same button at 60px it is a frame. A target
	inside something that clips (`ScrollingFrame`) has its rectangle clipped too, and
	when it goes out of view the highlight **suspends** instead of dying: the target
	stays pointed at and lights up again when the player scrolls back. Only a target
	removed from `PlayerGui` clears it for good.

	> Not covered: a **rotated** target. `AbsolutePosition`/`AbsoluteSize` describe
	> the unrotated box, so the hole would come out crooked, and `UIStroke` cannot cut
	> diagonally. UI rotation does not exist here today.

	It lives in `common/` because both places have buttons to point at.

	See docs/common/ui-guidance.md.
]]

local HighlightController = {
	Controllers = {}
}

HighlightController.Gui = nil :: ScreenGui?
HighlightController.Hole = nil :: Frame?
HighlightController.Corner = nil :: UICorner?
HighlightController.Stroke = nil :: UIStroke?
HighlightController.Origin = nil :: Frame?
HighlightController.Blockers = {} :: { Frame }

-- The pointing finger: a frame placed next to the hole, and the image inside it that
-- bobs. See `placeFinger`.
HighlightController.Finger = nil :: Frame?
HighlightController.FingerImage = nil :: ImageLabel?
HighlightController.FingerMoveTween = nil :: Tween?
HighlightController.FingerBobTween = nil :: Tween?
HighlightController.FingerBobKey = nil :: string?

HighlightController.Target = nil :: GuiObject?
HighlightController.Options = nil :: any

-- What is connected to the current target. Switching targets clears everything at once.
HighlightController.TargetMaid = nil :: any

HighlightController.FadeTween = nil :: Tween?
HighlightController.MoveTween = nil :: Tween?

-- A pointed-at target that is **currently** not on screen: scrolled out of the
-- ScrollingFrame, or went invisible. The highlight leaves, the target is still
-- followed, and it returns when the target does. See `suspend`.
HighlightController.Suspended = false

--[[
	The name path from the target up to `PlayerGui`, to find it again if its screen
	is recloned (respawn). See `pathOf` and `rebind`.
]]
HighlightController.Path = nil :: { string }?

-- Goes up on every `Show` and every `Hide`. A search in progress checks the number
-- before pointing: a new target during it wins, and `Hide` cancels it for good.
HighlightController.RebindToken = 0

--[[ INTERNAL ]]

local function create(className : string, properties : { [string] : any }, parent : Instance?) : any
	local instance = Instance.new(className)

	for property, value in properties do
		(instance :: any)[property] = value
	end

	if parent then
		instance.Parent = parent
	end

	return instance
end

--[=[
	Builds the highlight screen. Once per session.
]=]
function HighlightController:build()
	if self.Gui and self.Gui.Parent then
		return
	end

	local gui = create("ScreenGui", {
		Name = Config.Gui.Name,
		ResetOnSpawn = false,
		IgnoreGuiInset = Config.Gui.IgnoreGuiInset,
		DisplayOrder = Config.Gui.DisplayOrder,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
	}, PlayerGui)

	--[[
		The highlight does not disappear with "hide everything else" requests.

		The shop and proximity panels make that request when opening, and without this
		mark the effect would be inverted: with the shop closed the highlight would
		show, and with it open (exactly when it needs to point at the buy button) it
		would vanish along with the HUD.
	]]
	if Config.Gui.IgnoreHideAttribute then
		gui:SetAttribute(Config.Gui.IgnoreHideAttribute, true)
	end

	-- The probe: zero size, zero position, invisible. It draws nothing; it exists
	-- only so its `AbsolutePosition` tells where this screen's origin is in the
	-- same space the target is measured in.
	self.Origin = create("Frame", {
		Name = "Origin",
		Size = UDim2.fromOffset(0, 0),
		Position = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Visible = false,
	}, gui)

	local hole = create("Frame", {
		Name = "Hole",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0),
		Position = UDim2.fromOffset(0, 0),
	}, gui)

	self.Corner = create("UICorner", { CornerRadius = UDim.new(0, Config.Hole.Radius.Min) }, hole)

	self.Stroke = create("UIStroke", {
		Thickness = Config.Hole.Thickness,
		Color = Config.Hole.Color,
		Transparency = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, hole)

	-- The four that swallow clicks outside. Invisible: the stroke does the darkening.
	self.Blockers = {}
	for index = 1, 4 do
		self.Blockers[index] = create("Frame", {
			Name = `Blocker{index}`,
			BackgroundTransparency = 1,
			Active = true,
			Visible = false,
			Size = UDim2.fromOffset(0, 0),
		}, gui)
	end

	-- The finger draws over the dark and takes no input: a click on it goes to
	-- whatever is under it, which is usually the target itself.
	local finger = create("Frame", {
		Name = "Finger",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0),
		Visible = false,
		ZIndex = 3,
		Interactable = false,
	}, gui)

	self.FingerImage = create("ImageLabel", {
		Name = "Image",
		BackgroundTransparency = 1,
		Image = Config.Finger.Image,
		Size = UDim2.fromScale(1, 1),
		ResampleMode = Enum.ResamplerMode.Pixelated,
		ZIndex = 3,
		Interactable = false,
	}, finger)

	self.Gui = gui
	self.Hole = hole
	self.Finger = finger
end

--[=[
	Where this screen's top-left corner is, in the space targets are measured in.
	Read every time, not cached: the inset changes (the top bar hides during a
	cutscene and comes back) and the boot value does not hold forever.
]=]
function HighlightController:origin() : Vector2
	local probe = self.Origin

	return if probe then probe.AbsolutePosition else Vector2.zero
end

--[=[
	The highlight rectangle now, in this screen's coordinates: the target's box plus
	padding.
]=]
function HighlightController:rect() : (Vector2?, Vector2?)
	local target = self.Target
	if not target or not target.Parent or not target.Visible then
		return nil
	end

	local padding = self:measure(Config.Hole.Padding, target.AbsoluteSize)
	if self.Options and self.Options.Padding then
		padding = self.Options.Padding
	end

	local position = target.AbsolutePosition - Vector2.new(padding, padding)
	local size = target.AbsoluteSize + Vector2.new(padding * 2, padding * 2)

	-- Clip by ancestors that clip. A target inside a ScrollingFrame that scrolled
	-- out must not be pointed at where it is no longer drawn: either the highlight
	-- follows the visible part, or it goes away while there is no visible part at
	-- all. Without this, scrolling the list would leave a hole in the dark pointing at
	-- a button the player cannot see.
	local ancestor = target.Parent
	while ancestor and ancestor:IsA("GuiObject") do
		if ancestor.ClipsDescendants then
			local clipMin = ancestor.AbsolutePosition
			local clipMax = clipMin + ancestor.AbsoluteSize

			local minX = math.max(position.X, clipMin.X)
			local minY = math.max(position.Y, clipMin.Y)
			local maxX = math.min(position.X + size.X, clipMax.X)
			local maxY = math.min(position.Y + size.Y, clipMax.Y)

			if maxX <= minX or maxY <= minY then
				return nil
			end

			position = Vector2.new(minX, minY)
			size = Vector2.new(maxX - minX, maxY - minY)
		end

		ancestor = ancestor.Parent
	end

	return position - self:origin(), size
end

--[=[
	A number proportional to the target, with a floor and ceiling: the hole's padding
	and radius.

	The reference is the target's **smaller side**, not the screen: what needs to
	look like padding is the distance to the button's edge, and a small button on a
	large screen is still a small button.
]=]
function HighlightController:measure(rule : { Fraction : number, Min : number, Max : number }, size : Vector2) : number
	local reference = math.min(size.X, size.Y)

	return math.clamp(reference * rule.Fraction, rule.Min, rule.Max)
end

--[=[
	Places the four blockers around the hole.

	They cover the whole screen except the middle: top strip, bottom strip, and the
	two sides at the hole's height. There is always some overlap at the corners, and
	that is fine: two stacked invisible frames swallow the same click once.

	The strips are deliberately larger than the screen (scale `Size` plus an offset
	exaggeration): a screen that grows between one frame and the next must not leave
	a clickable gap at the edge.
]=]
function HighlightController:layoutBlockers(position : Vector2, size : Vector2)
	local blockers = self.Blockers
	if #blockers < 4 then return end

	local visible = if self.Options and self.Options.BlockInput ~= nil
		then self.Options.BlockInput == true
		else Config.BlockInput

	if not visible then
		for _, blocker in blockers do
			blocker.Visible = false
		end

		return
	end

	local far = 10000

	-- Top
	blockers[1].Position = UDim2.fromOffset(-far, position.Y - far)
	blockers[1].Size = UDim2.fromOffset(far * 2, far)

	-- Bottom
	blockers[2].Position = UDim2.fromOffset(-far, position.Y + size.Y)
	blockers[2].Size = UDim2.fromOffset(far * 2, far)

	-- Left
	blockers[3].Position = UDim2.fromOffset(position.X - far, position.Y)
	blockers[3].Size = UDim2.fromOffset(far, size.Y)

	-- Right
	blockers[4].Position = UDim2.fromOffset(position.X + size.X, position.Y)
	blockers[4].Size = UDim2.fromOffset(far, size.Y)

	for _, blocker in blockers do
		blocker.Visible = true
	end
end

--[=[
	Whether this highlight wants the finger: the caller's `Finger` option, or the
	config default.
]=]
function HighlightController:fingerWanted() : boolean
	if self.Options and self.Options.Finger ~= nil then
		return self.Options.Finger == true
	end

	return Config.Finger.Enabled == true
end

function HighlightController:hideFinger()
	if self.FingerMoveTween then
		self.FingerMoveTween:Cancel()
		self.FingerMoveTween = nil
	end

	if self.FingerBobTween then
		self.FingerBobTween:Cancel()
		self.FingerBobTween = nil
	end

	self.FingerBobKey = nil

	if self.FingerImage then
		self.FingerImage.Position = UDim2.fromOffset(0, 0)
	end

	if self.Finger then
		self.Finger.Visible = false
	end
end

--[=[
	Puts the finger next to the hole, its tip on the hole's horizontal centre.

	Below the hole, pointing up, when it fits on screen; otherwise above it, the
	image turned upside down, pointing down. The tip is the anchor (`TipX` across,
	the top edge, or the bottom edge once flipped), so the gap to the hole is the
	same either way and the tip, not the hand's middle, lines up with the target.

	The jab is a tween on the image inside the frame, towards the hole and back,
	restarted only when its direction or size changes: the target moving a pixel
	must not make the finger stutter.
]=]
function HighlightController:placeFinger(position : Vector2, size : Vector2, animate : boolean?)
	local finger = self.Finger
	local image = self.FingerImage
	local gui = self.Gui
	if not finger or not image or not gui then return end

	if not self:fingerWanted() then
		self:hideFinger()
		return
	end

	local settings = Config.Finger
	local height = self:measure(settings.Size, size)
	local width = height * settings.Aspect
	local screen = gui.AbsoluteSize

	local below = position.Y + size.Y + settings.Gap + height <= screen.Y
	local tipX = if below then settings.TipX else 1 - settings.TipX

	-- Kept on screen sideways: a target at the edge still gets the whole hand.
	local centerX = math.clamp(position.X + size.X / 2, width * tipX, screen.X - width * (1 - tipX))

	local goal
	if below then
		finger.AnchorPoint = Vector2.new(tipX, 0)
		goal = UDim2.fromOffset(centerX, position.Y + size.Y + settings.Gap)
		image.Rotation = 0
	else
		finger.AnchorPoint = Vector2.new(tipX, 1)
		goal = UDim2.fromOffset(centerX, position.Y - settings.Gap)
		image.Rotation = 180
	end

	finger.Size = UDim2.fromOffset(width, height)

	if self.FingerMoveTween then
		self.FingerMoveTween:Cancel()
		self.FingerMoveTween = nil
	end

	if animate and finger.Visible then
		local info = TweenInfo.new(Config.Tween.Move, Config.Tween.EasingStyle, Config.Tween.EasingDirection)

		self.FingerMoveTween = TweenService:Create(finger, info, { Position = goal })
		self.FingerMoveTween:Play()
	else
		finger.Position = goal
	end

	finger.Visible = true

	local amplitude = math.floor(height * settings.Bob.Amplitude + 0.5)
	local direction = if below then -1 else 1
	local key = `{direction}:{amplitude}`

	if key == self.FingerBobKey then return end

	self.FingerBobKey = key

	if self.FingerBobTween then
		self.FingerBobTween:Cancel()
	end

	image.Position = UDim2.fromOffset(0, 0)

	local info = TweenInfo.new(settings.Bob.Period, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

	self.FingerBobTween = TweenService:Create(image, info, {
		Position = UDim2.fromOffset(0, amplitude * direction),
	})
	self.FingerBobTween:Play()
end

--[=[
	Removes (or restores) the highlight without forgetting the target.

	It is the "the target exists, but is not in view right now" state: scrolled out of
	the list, went invisible, its panel closed. Clearing for good would lose the
	pointing: the tutorial is still pointing at the same button, and it lights up again
	when the player scrolls back.

	The darkening leaves quickly, not at the normal exit time: this is not the end of
	a step, it is the screen changing under it.
]=]
function HighlightController:suspend(suspended : boolean)
	if self.Suspended == suspended then
		return
	end

	self.Suspended = suspended

	if suspended then
		for _, blocker in self.Blockers do
			blocker.Visible = false
		end

		self:hideFinger()
		self:fade(1, Config.Tween.FadeOut)

		return
	end

	local transparency = (self.Options and self.Options.Transparency) or Config.Hole.Transparency
	self:fade(transparency, Config.Tween.FadeIn)
end

--[=[
	Sticks the hole to the target.

	`animate` is for a target switch: then the hole slides from one to the other
	instead of jumping. Any movement of the target midway cancels the tween and the
	real position takes over: chasing the target beats finishing the pretty
	animation.
]=]
function HighlightController:refresh(animate : boolean?)
	local hole = self.Hole
	if not hole then return end

	local position, size = self:rect()
	if not position or not size then
		self:suspend(true)

		return
	end

	self:suspend(false)

	-- The radius follows the hole's size for the same reason as the padding: a 12px
	-- rounded corner on a 40px icon is almost a circle, and on a whole panel it is
	-- invisible.
	local corner = self.Corner
	if corner then
		corner.CornerRadius = UDim.new(0, self:measure(Config.Hole.Radius, size))
	end

	if self.MoveTween then
		self.MoveTween:Cancel()
		self.MoveTween = nil
	end

	local goalPosition = UDim2.fromOffset(position.X, position.Y)
	local goalSize = UDim2.fromOffset(size.X, size.Y)

	if animate then
		local info = TweenInfo.new(Config.Tween.Move, Config.Tween.EasingStyle, Config.Tween.EasingDirection)

		self.MoveTween = TweenService:Create(hole, info, {
			Position = goalPosition,
			Size = goalSize,
		})
		self.MoveTween:Play()
	else
		hole.Position = goalPosition
		hole.Size = goalSize
	end

	self:placeFinger(position, size, animate)
	self:layoutBlockers(position, size)
end

--[=[
	Binds the highlight to the target: it follows whatever the target does and goes
	away with it.

	These are notifications, not a per-frame sweep. A HUD button does not move;
	recomputing sixty times a second a rectangle that does not change is the cost the
	most common example's `RenderStepped` charges needlessly.
]=]
--[=[
	The name path from a target up to `PlayerGui`, or `nil` if it is not there.

	It is the same language as `:Find()`, on purpose: what is saved to find the target
	again must be exactly what the lookup knows how to follow. A name is also the only
	thing that survives `ResetOnSpawn`, which destroys the instance and clones an
	identical one from `StarterGui`.
]=]
function HighlightController:pathOf(target : Instance) : { string }?
	local names = {}
	local current : Instance? = target

	while current and current ~= PlayerGui do
		table.insert(names, 1, current.Name)
		current = current.Parent
	end

	if current ~= PlayerGui or #names == 0 then
		return nil
	end

	return names
end

--[=[
	The target died under the highlight: looks for its equivalent on the new screen.

	It is the respawn case: almost every `ScreenGui` has `ResetOnSpawn`, and the whole
	screen is recloned. The old instance is garbage, but the name path still holds,
	and it is how the highlight finds what it was pointing at again.

	If it is not found within the timeout (`Rebind.Timeout`), it leaves for good and
	**quietly**: whoever asked for the highlight knows whether a step still needs that
	button, and a warning here would also show in the legitimate case of the screen
	having been closed for good.
]=]
function HighlightController:rebind()
	local path = self.Path
	local options = self.Options

	if not path then
		self:Hide()

		return
	end

	self.RebindToken += 1
	local token = self.RebindToken

	-- The dark leaves while there is nothing to point at: a spotlight on nothing is
	-- worse than no spotlight. It is `suspend`, not `Hide`, because the target was not
	-- forgotten: it is being found again.
	self:suspend(true)

	local rebind = Config.Rebind or {}

	task.spawn(function()
		local deadline = os.clock() + (rebind.Timeout or 10)

		while os.clock() < deadline do
			if self.RebindToken ~= token then return end

			local found = self:Find(path)

			--[[
				`Show` refuses an invisible target, and the new screen's target is often
				born that way: the Ready button only appears when the countdown starts, the
				backpack crate only when it opens. A refusal is not giving up: the search
				continues, which is why it checks `Show`'s result instead of assuming the
				target is pointed at.

				A successful `Show` bumps the token, and that is what ends this thread.
			]]
			if found and found:IsDescendantOf(PlayerGui) then
				if self.RebindToken ~= token then return end

				if self:Show(found, options) then
					return
				end
			end

			task.wait(rebind.Interval or 0.2)
		end

		if self.RebindToken ~= token then return end

		self:Hide()
	end)
end

function HighlightController:track(target : GuiObject)
	local maid = Maid.new()
	self.TargetMaid = maid

	local function onMoved()
		self:refresh(false)
	end

	maid:GiveTask(target:GetPropertyChangedSignal("AbsolutePosition"):Connect(onMoved))
	maid:GiveTask(target:GetPropertyChangedSignal("AbsoluteSize"):Connect(onMoved))

	-- A screen that changes size (window, phone rotation) moves everything together,
	-- and the origin probe moves with it.
	local camera = workspace.CurrentCamera
	if camera then
		maid:GiveTask(camera:GetPropertyChangedSignal("ViewportSize"):Connect(onMoved))
	end

	-- A target that goes invisible takes the highlight off screen, but is not forgotten:
	-- a panel closing and reopening is the normal case in a tutorial, and the step is
	-- still the same.
	maid:GiveTask(target:GetPropertyChangedSignal("Visible"):Connect(function()
		self:refresh(false)
	end))

	--[[
		A target removed from `PlayerGui` may be its end, or it may be the whole screen
		being recloned by a respawn, which is the most common case of all, because
		almost every `ScreenGui` has `ResetOnSpawn`.

		Both are the same event from here, so the highlight does not decide: it looks
		for the same path on the new screen and gives up if it is not found (see
		`rebind`).
	]]
	maid:GiveTask(target.AncestryChanged:Connect(function()
		if not target:IsDescendantOf(PlayerGui) then
			self:rebind()
		end
	end))
end

--[=[
	Takes the darkening to a transparency.
]=]
function HighlightController:fade(transparency : number, duration : number)
	local stroke = self.Stroke
	if not stroke then return end

	if self.FadeTween then
		self.FadeTween:Cancel()
		self.FadeTween = nil
	end

	local info = TweenInfo.new(duration, Config.Tween.EasingStyle, Config.Tween.EasingDirection)

	self.FadeTween = TweenService:Create(stroke, info, { Transparency = transparency })
	self.FadeTween:Play()
end

--[[ API ]]

export type Options = {
	-- Padding in pixels on each side of the target.
	Padding : number?,

	-- How much of the game still shows through the dark (0 black, 1 invisible).
	Transparency : number?,

	-- `false` lets the player click what is darkened.
	BlockInput : boolean?,

	-- `false` leaves the pointing finger out of this highlight.
	Finger : boolean?,
}

--[=[
	Points at a GuiObject: the screen darkens except for it.

	Calling with the highlight already up switches the target by sliding from one to
	the other: no blinking in the middle of a tutorial.

	Returns `false` for a target that is not on screen (destroyed, invisible, outside
	`PlayerGui`): there is nothing to point at, and darkening over nothing would only
	take the game away from the player.
]=]
function HighlightController:Show(target : GuiObject, options : Options?) : boolean
	if not target or not target:IsDescendantOf(PlayerGui) or not target.Visible then
		return false
	end

	self:build()

	local wasShown = self:IsShown()

	if self.TargetMaid then
		self.TargetMaid:DoCleaning()
		self.TargetMaid = nil
	end

	self.Target = target
	self.Options = options
	self.Suspended = false

	--[[
		The name path is saved with the target: it is how the highlight finds the
		button again when its screen is recloned by a respawn (see `rebind`). A target
		without a path (not under `PlayerGui`) simply does not come back, and that is
		honest: there is nowhere to look for it.
	]]
	self.Path = self:pathOf(target)

	-- A new target cancels the previous one's search.
	self.RebindToken += 1

	local gui = self.Gui
	if gui then
		gui.Enabled = true
	end

	self:refresh(wasShown)
	self:track(target)

	if not wasShown then
		local stroke = self.Stroke
		if stroke then
			stroke.Transparency = 1
		end
	end

	local transparency = (options and options.Transparency) or Config.Hole.Transparency
	self:fade(transparency, if wasShown then Config.Tween.Move else Config.Tween.FadeIn)

	return true
end

--[=[
	Clears the highlight. Idempotent: clearing what is already cleared does nothing.
]=]
function HighlightController:Hide()
	if not self:IsShown() then
		return
	end

	if self.TargetMaid then
		self.TargetMaid:DoCleaning()
		self.TargetMaid = nil
	end

	self.Target = nil
	self.Options = nil
	self.Suspended = false

	-- Forgetting the path is what separates "leaving" from "coming back": after a
	-- `Hide` there is nothing to find again, and a search in progress dies here.
	self.Path = nil
	self.RebindToken += 1

	for _, blocker in self.Blockers do
		blocker.Visible = false
	end

	self:hideFinger()
	self:fade(1, Config.Tween.FadeOut)

	-- The screen is only disabled at the end of the exit: disabling it with the tween
	-- would cut the dark halfway.
	local gui = self.Gui
	task.delay(Config.Tween.FadeOut, function()
		if self.Target then return end
		if gui then
			gui.Enabled = false
		end
	end)
end

function HighlightController:IsShown() : boolean
	return self.Target ~= nil
end

function HighlightController:GetTarget() : GuiObject?
	return self.Target
end

--[=[
	The target by name path from `PlayerGui`: `"HUD.HUDLeft.Shop"`.

	It is what allows pointing at a button from outside the code that knows it: Cmdr's
	`highlight` command and a tutorial step written in config, neither needing a
	reference to the instance.

	It accepts the already-split list of names, for callers that have it: that is the
	case of `rebind`, which saved the target's chain and cannot join it with dots to
	split again: a name with a dot in it (`"1.5x"`, the kind of name art gets) would
	become two steps and the target would never be found again.
]=]
function HighlightController:Find(path : string | { string }) : GuiObject?
	local names = {}

	if type(path) == "table" then
		names = path
	else
		for name in string.gmatch(path, "[^%.]+") do
			table.insert(names, name)
		end
	end

	--[[
		Depth-first search, not one `FindFirstChild` per step.

		The HUD has **several** siblings named `Wrapper`, one per button: taking the
		first and continuing from there would find the backpack's wrapper and give up
		at `Shop`. By trying each same-name sibling until the rest of the path closes,
		`HUDFrame.Wrapper.Shop` finds the wrapper that actually contains Shop.
	]]
	local function walk(parent : Instance, index : number) : Instance?
		local name = names[index]
		if not name then
			return parent
		end

		for _, child in parent:GetChildren() do
			if child.Name == name then
				local found = walk(child, index + 1)

				if found then
					return found
				end
			end
		end

		return nil
	end

	local found = walk(PlayerGui, 1)

	return if found and found:IsA("GuiObject") then found else nil
end

--[[ LIFECYCLE ]]

function HighlightController:construct()
	Framework:Listen("HighlightShow", function(path : any, options : any)
		if type(path) ~= "string" then
			self:Hide()

			return
		end

		local target = self:Find(path)
		if not target then
			log:StudioWarn(`could not find "{path}" in PlayerGui.`)

			return
		end

		self:Show(target, if type(options) == "table" then options else nil)
	end)
end

function HighlightController:start()
end

function HighlightController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return HighlightController