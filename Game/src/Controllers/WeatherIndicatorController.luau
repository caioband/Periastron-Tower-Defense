local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
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
local log = Log.new("WeatherIndicatorController")

local WeatherConfig = SharedConfig.WeatherConfig
local Config = WeatherConfig.Indicator

-- How close to rest the scale must be for the list to be written. A tween that
-- ends does not land exactly on the target on every machine, and the difference that
-- matters here is that of an animation in progress, which is orders of magnitude larger.
local SCALE_EPSILON = 0.001

--[[
	The HUD weather indicator: the corner button and the panel it opens.

	Two sibling pieces in `Interface` (see `WeatherConfig.Indicator.Gui`):

	  1. `WeatherButton`: the icon of the active weather, and the panel's **toggle**.
	     Press it and the panel comes in, press again and it leaves;
	  2. `IndicatorWeather`: the panel: the icon again, the weather name, how many waves
	     it still lasts, and the list of what it does.

	**With no active weather there is no indicator.** The button hides and the panel
	closes, even if open: "clear sky" is not a state worth occupying a corner of the
	screen.

	**The `New` badge** (the button's optional child) lights with it while the player has
	not opened the panel this match: without it the button is an icon nobody discovers
	is clickable. See `PanelSeen`.

	**The animation is on the panel's `UIScale`**, the authored one when it exists. Scale,
	not position, so the entrance works in whatever corner the designer anchors the
	panel.

	**The lines are rich text**, written one after another by `RichTextController`. The
	color inside them is built here (see `markup`): a number takes the color of what it
	does to the player, and a unit type takes the type's color.

	**Where what it says comes from.** The current weather comes from `WeatherController`
	(`WeatherChanged`); the wave it lasts until comes from `WeatherDuration`, which
	`WeatherRoundService` sends with the name; the current wave comes from `SetWave`.

	The three arrive in different events and **their order is not guaranteed**, so
	nothing here is computed on the arrival of one of them: each notification only stores
	what it brought and asks for a redraw, and the remaining-waves math comes from the
	whole state. That is also why `WeatherDuration` carries the weather name: a deadline
	whose name is not the active weather's is another weather's deadline, and does not
	show.

	It lives in Game: match weather only exists here.

	See docs/game/weather-in-match.md.
]]

local WeatherIndicatorController = {
	Controllers = {
		RichTextController = {},
		WeatherController = {},
	}
}

-- The screen pieces.
WeatherIndicatorController.Button = nil :: GuiButton?
WeatherIndicatorController.ButtonImage = nil :: ImageLabel?
WeatherIndicatorController.NewBadge = nil :: GuiObject?
WeatherIndicatorController.Panel = nil :: GuiObject?
WeatherIndicatorController.Scale = nil :: UIScale?
WeatherIndicatorController.Image = nil :: ImageLabel?
WeatherIndicatorController.NameLabel = nil :: TextLabel?
WeatherIndicatorController.DurationLabel = nil :: TextLabel?
WeatherIndicatorController.Container = nil :: GuiObject?

--[[
	The scale the designer drew, when they wrote one. The config's `Scale.Open` covers a
	`UIScale` that starts at zero (or one this controller creates).

	It is read in `bind`, before the animation writes to the `UIScale` for the first
	time: after that, the value there is the animation's, not the designer's.

	The resting scale is **not** this: it is this times the screen factor. See
	`openScale`.
]]
WeatherIndicatorController.AuthoredScale = 1

-- A line's template, when the designer drew one. See `lineFrame`.
WeatherIndicatorController.Template = nil :: GuiObject?

-- One entry per list line, reused across weathers: `{ Frame, Handle }`.
WeatherIndicatorController.Lines = {}

-- Is the panel open? It is the toggle's state, not the tween's.
WeatherIndicatorController.IsOpen = false

--[[
	Has the player opened the panel this match?

	It is the `New` badge's switch: while `false`, the badge lights on **every** storm:
	the notice is not about the weather that arrived, it is about the button nobody has
	opened yet, and an ignored weather leaves the discovery for the next one. Opening the
	panel retires it for the rest of the match.

	It lives on the client and not the profile: it is per match, and `RoundRestarted`
	resets it.
]]
WeatherIndicatorController.PanelSeen = false

-- The current wave, and the deadline the server sent: the weather name and the last
-- wave it lasts.
WeatherIndicatorController.Wave = 0
WeatherIndicatorController.EndsName = nil :: string?
WeatherIndicatorController.EndsWave = nil :: number?

--[[
	Goes up on every open and every close.

	Two things check whether it is still their turn before touching the screen: writing
	the lines, which sleeps between one and the next, and the end of the exit tween,
	which hides the panel. Without this, a weather changing mid-write would write over
	the new list, and a quick reopen would be hidden by the previous exit's end.
]]
WeatherIndicatorController.Token = 0

-- The scale tween in progress, so the next click chains onto it instead of fighting.
WeatherIndicatorController.ScaleTween = nil :: Tween?

-- Goes up on every screen change, so only the batch's last one rewrites the list. See
-- `onViewportChanged`.
WeatherIndicatorController.ViewportToken = 0

--[[ SCREEN ]]

--[=[
	Finds the pieces in `PlayerGui`.

	Returns `false` when the button or the panel does not exist in this place (or has not
	replicated yet): the controller then does nothing, instead of erroring on a `nil`.
	What is optional (the labels, the line template) only warns and moves on.
]=]
function WeatherIndicatorController:bind() : boolean
	local screen = PlayerGui:WaitForChild(Config.Gui.Screen, 60)
	local button = screen and screen:WaitForChild(Config.Gui.Button, 60)
	local panel = screen and screen:WaitForChild(Config.Gui.Frame, 60)

	if not button or not button:IsA("GuiButton") then
		log:StudioWarn(`could not find the {Config.Gui.Screen}.{Config.Gui.Button} button in PlayerGui.`)

		return false
	end

	if not panel or not panel:IsA("GuiObject") then
		log:StudioWarn(`could not find the {Config.Gui.Screen}.{Config.Gui.Frame} panel in PlayerGui.`)

		return false
	end

	self.Button = button
	self.Panel = panel

	--[[
		Where the button's icon is written.

		Normally it is the button itself, an `ImageButton`. A button that is not an image
		still works: the child with the same name as the panel's image (`Gui.Image`)
		applies, which is where a button drawn as a frame keeps its icon.
	]]
	if button:IsA("ImageButton") then
		self.ButtonImage = button :: any
	else
		local inner = button:FindFirstChild(Config.Gui.Image)

		if inner and (inner:IsA("ImageLabel") or inner:IsA("ImageButton")) then
			self.ButtonImage = inner :: any
		else
			log:StudioWarn(`{Config.Gui.Button} is not an ImageButton and has no {Config.Gui.Image} inside; its icon will not change.`)
		end
	end

	--[[
		The new badge, if the designer drew one.

		It is **optional** on purpose, which is why there is no warning when missing: the
		whole indicator works without the badge, and a button without a `New` child is a
		button without a badge, not a broken button. It starts off: `refreshButton` lights
		it, and only along with an active weather.
	]]
	local badge = button:FindFirstChild(Config.Gui.New)
	if badge and badge:IsA("GuiObject") then
		self.NewBadge = badge
		badge.Visible = false
	end

	--[[
		The `UIScale` is the authored one when it exists: that way the designer decides the
		panel's resting scale and the animation only writes to it. Without one, creating it
		is harmless: a scale-1 `UIScale` changes nothing that is drawn.
	]]
	local scale = panel:FindFirstChildWhichIsA("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "PanelScale"
		scale.Parent = panel
	end

	self.Scale = scale

	local authored = scale.Scale
	self.AuthoredScale = if authored > Config.Scale.Closed then authored else Config.Scale.Open

	local image = panel:FindFirstChild(Config.Gui.Image)
	if image and (image:IsA("ImageLabel") or image:IsA("ImageButton")) then
		self.Image = image :: any
	else
		log:StudioWarn(`{Config.Gui.Frame} has no {Config.Gui.Image} image.`)
	end

	local nameLabel = panel:FindFirstChild(Config.Gui.Name)
	if nameLabel and nameLabel:IsA("TextLabel") then
		self.NameLabel = nameLabel
		self:makeResponsive(nameLabel)
	else
		log:StudioWarn(`{Config.Gui.Frame} has no {Config.Gui.Name} label.`)
	end

	local durationLabel = panel:FindFirstChild(Config.Gui.Duration)
	if durationLabel and durationLabel:IsA("TextLabel") then
		self.DurationLabel = durationLabel
		self:makeResponsive(durationLabel)
	else
		log:StudioWarn(`{Config.Gui.Frame} has no {Config.Gui.Duration} label.`)
	end

	local container = panel:FindFirstChild(Config.Gui.Container)
	if container and container:IsA("GuiObject") then
		self.Container = container

		--[[
			The line template, if the designer drew one. It never shows itself: clones go
			into the list, and the original stays hidden as a size and margin reference.
		]]
		local template = container:FindFirstChild(Config.Gui.Line)
		if template and template:IsA("GuiObject") then
			template.Visible = false
			self.Template = template
		end
	else
		log:StudioWarn(`{Config.Gui.Frame} has no {Config.Gui.Container}; the effect list will not show.`)
	end

	-- The panel starts closed, however the designer left it in Studio: the button
	-- opens it.
	panel.Visible = false
	scale.Scale = Config.Scale.Closed

	return true
end

--[=[
	The screen factor: how much the panel grows above the reference resolution.

	The panel is drawn in pixels, and pixels do not grow with the screen: the same panel
	on a 1440 screen takes the same pixel area as on a 1080 one, so it looks smaller
	there. This factor restores the proportion, and everything inside the panel follows:
	the lines' text is measured from the box **after** the factor is applied.

	The reference is a screen **height**, in pixels (1080 on a 1080p monitor, not 1920):
	a reference that is too large pushes the factor below 1 on every screen, `Min` pins it
	at 1, and the config's two numbers stop having any effect, with no error showing up.

	`Min` keeps mobile in place: a screen smaller than the reference does not shrink the
	panel, because there it already takes the right share of the screen. `Max` sets the
	ceiling, so the panel does not double in size on 4K and start competing with the game.

	With no camera (the frame between join and the first `CurrentCamera`) the factor is 1:
	the panel opens at its drawn size, and the first screen change corrects it.
]=]
function WeatherIndicatorController:viewportFactor() : number
	local camera = workspace.CurrentCamera
	if not camera then
		return 1
	end

	local height = camera.ViewportSize.Y
	local responsive = Config.Responsive

	if height <= 0 or responsive.ReferenceHeight <= 0 then
		return 1
	end

	return math.clamp(height / responsive.ReferenceHeight, responsive.Min, responsive.Max)
end

--[=[
	The panel's resting scale: the authored one, corrected by the screen.

	It is computed on every use instead of cached because the screen changes mid-match
	(rotating the phone, dragging the window), and a cached copy would be the previous
	screen's scale. See `onViewportChanged`.
]=]
function WeatherIndicatorController:openScale() : number
	return self.AuthoredScale * self:viewportFactor()
end

--[=[
	Makes a designer's label shrink with the screen.

	`TextScaled` alone would fix mobile and break the monitor: the text would fill the
	whole label, bigger than drawn. Turning on `TextScaled` **with** a cap at the
	authored size gives both: the original drawing where there is room, and the text
	shrinking where there is not.

	A label that already arrives with `TextScaled` on stays as it is: its `TextSize` no
	longer means anything, and using it as a cap would pin the text at a number nobody
	chose.
]=]
function WeatherIndicatorController:makeResponsive(label : TextLabel)
	if not Config.Labels.Scale or label.TextScaled then return end

	local authored = label.TextSize

	label.TextScaled = true

	local constraint = label:FindFirstChildWhichIsA("UITextSizeConstraint")
	if not constraint then
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Name = "LabelTextSize"
		constraint.Parent = label
	end

	-- Order matters: `MaxTextSize` must not go below the `MinTextSize` that is
	-- there, nor the reverse, or the property is refused.
	constraint.MinTextSize = 1
	constraint.MaxTextSize = math.max(authored, Config.Labels.MinTextSize)
	constraint.MinTextSize = math.min(Config.Labels.MinTextSize, constraint.MaxTextSize)
end

--[=[
	The weather active now, or `nil`.
]=]
function WeatherIndicatorController:current() : string?
	local weather = self.Controllers.WeatherController

	return weather and weather:GetCurrent() or nil
end

--[[ CONTENT ]]

--[=[
	The weather's lines, each as `{ Text, Kind }`.

	The config accepts a string or a table (see `Indicator.Details`), and this is where
	the two shapes become one, so the writer does not have to check the type on every
	line.
]=]
function WeatherIndicatorController:details(weatherName : string) : { { Text : string, Kind : string? } }
	local lines = Config.Details[weatherName] or Config.UnknownDetails
	local out = {}

	for _, line in lines do
		if typeof(line) == "string" then
			table.insert(out, { Text = line })
		elseif typeof(line) == "table" and line.Text then
			table.insert(out, { Text = line.Text, Kind = line.Kind })
		end
	end

	return out
end

--[=[
	The line with the colors inside it. The rule lives in `WeatherConfig.MarkupDetail`,
	shared with the Lobby's Index, which draws the same lines.
]=]
function WeatherIndicatorController:markup(text : string, kind : string?) : string
	return WeatherConfig.MarkupDetail(text, kind)
end

--[=[
	The deadline sentence, or `nil` when there is none.

	The math is done **now**, not when the notification arrives: the deadline is a target
	wave and the player plays whole waves with the panel closed. The running wave counts,
	so a 4-wave weather that just arrived says "ENDS IN 4 WAVES" and the last one says
	"ENDS IN 1 WAVE".

	With no deadline at all (a weather turned on by hand with the `weather` command)
	there is no sentence, and the label simply does not appear.
]=]
function WeatherIndicatorController:endsText() : string?
	local current = self:current()
	if not current or self.EndsName ~= current or not self.EndsWave then
		return nil
	end

	if self.Wave <= 0 then
		return nil
	end

	local remaining = (self.EndsWave :: number) - self.Wave + 1
	if remaining <= 0 then
		return nil
	end

	return if remaining == 1
		then Config.EndsOne
		else string.format(Config.Ends, remaining)
end

--[=[
	The current weather's icon, on the button and on the panel.
]=]
function WeatherIndicatorController:refreshIcon(weatherName : string)
	local icon = Config.Icons[weatherName]
	if not icon then
		log:StudioWarn(`weather "{weatherName}" has no icon in WeatherConfig.Indicator.Icons.`)

		return
	end

	if self.ButtonImage then
		self.ButtonImage.Image = icon
	end

	if self.Image then
		self.Image.Image = icon
	end
end

--[=[
	The button: it exists while there is an active weather, and only then.
]=]
function WeatherIndicatorController:refreshButton()
	local button = self.Button
	if not button then return end

	local current = self:current()

	button.Visible = current ~= nil

	--[[
		The badge lives the button's life, except once the panel has been opened: with no
		weather it goes away with the button, and after the first open it does not return
		this match.
	]]
	local badge = self.NewBadge
	if badge then
		badge.Visible = current ~= nil and not self.PanelSeen
	end

	if current then
		self:refreshIcon(current)
	end
end

--[=[
	The top of the panel: icon, name, and deadline. With no deadline, the deadline label
	hides instead of showing half a sentence.
]=]
function WeatherIndicatorController:refreshHeader()
	local current = self:current()
	if not current then return end

	self:refreshIcon(current)

	if self.NameLabel then
		self.NameLabel.Text = WeatherConfig.GetDisplayName(current)
	end

	local duration = self.DurationLabel
	if duration then
		local text = self:endsText()

		duration.Text = text or ""
		duration.Visible = text ~= nil
	end
end

--[[ LINES ]]

--[=[
	The piece for line `index`, creating it the first time.

	Pieces are reused across weathers: the list changes content many times per match, and
	destroying to recreate would throw away each one's text render too. Leftovers from the
	previous weather are hidden, not destroyed (see `refreshLines`).

	With a template in Studio, the piece is a clone of it; without one, a Frame
	`Line.HeightScale` of the `Container`'s height: a fraction, not pixels, so the piece
	shrinks with the panel on mobile. In both cases `LayoutOrder` is the index, so the
	on-screen order is the order written in the config.
]=]
function WeatherIndicatorController:lineFrame(index : number) : GuiObject?
	local container = self.Container
	if not container then return nil end

	local frame : GuiObject

	if self.Template then
		frame = (self.Template :: GuiObject):Clone()
	else
		local created = Instance.new("Frame")
		created.Size = UDim2.new(1, 0, Config.Line.HeightScale, 0)
		created.BackgroundTransparency = 1
		created.BorderSizePixel = 0

		frame = created
	end

	frame.Name = `{Config.Gui.Line}{index}`
	frame.LayoutOrder = index
	frame.Visible = true
	frame.Parent = container

	return frame
end

--[=[
	The rich text handle for line `index`, creating its piece if needed.
]=]
function WeatherIndicatorController:lineEntry(index : number) : { Frame : GuiObject, Handle : any }?
	local existing = self.Lines[index]
	if existing then
		return existing
	end

	local richText = self.Controllers.RichTextController
	if not richText then return nil end

	local frame = self:lineFrame(index)
	if not frame then return nil end

	local handle = richText:Bind(frame, Config.Text)
	if not handle then
		frame:Destroy()

		return nil
	end

	local entry = { Frame = frame, Handle = handle }
	self.Lines[index] = entry

	return entry
end

--[=[
	Clears whatever is written on the lines, without undoing the pool.
]=]
function WeatherIndicatorController:clearLines()
	for _, entry in self.Lines do
		entry.Handle:Clear(true)
	end
end

--[=[
	Writes the active weather's list, one line after another.

	`Stagger` is what gives the effect of a list building up instead of appearing ready,
	and that is why writing lives on its own thread: it sleeps between one line and the
	next, and the click that started it must not wait for that.

	Leftovers from the previous weather are **hidden**, not destroyed: the piece stays in
	the pool for the next, longer list to reuse.
]=]
function WeatherIndicatorController:refreshLines()
	local current = self:current()
	if not current or not self.Container then return end

	local richText = self.Controllers.RichTextController
	if not richText then return end

	self.Token += 1
	local token = self.Token

	local lines = self:details(current)

	for index, entry in self.Lines do
		if index > #lines then
			entry.Handle:Clear(true)
			entry.Frame.Visible = false
		end
	end

	local entries = {}

	for index, line in lines do
		local entry = self:lineEntry(index)
		if not entry then continue end

		entry.Frame.Visible = true
		entry.Handle:Clear(true)

		entries[index] = { Entry = entry, Line = line }
	end

	-- The text **without** the colors: `FitSize` measures the width, and markup takes no
	-- width on screen.
	local texts = {}
	for _, line in lines do
		table.insert(texts, line.Text)
	end

	--[[
		The panel scale, in the Studio Output. It is how you find the two numbers in
		`Indicator.Responsive` instead of guessing: it shows the height of each screen
		and the factor that came out of it. The text size math is not logged here; it
		comes from `RichTextController:FitSize` (see `RichTextConfig.Fit.Debug`).
	]]
	log:Debug(string.format(
		-- %.0f, not %d: `ViewportSize` is a float, and `%d` with a float that has no
		-- integer representation is an error, not rounding.
		"screen %.0f tall | factor %.2f | scale %.2f",
		(workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y) or 0,
		self:viewportFactor(),
		(self.Scale and self.Scale.Scale) or 1
	))

	task.spawn(function()
		local size : number? = nil

		for index = 1, #lines do
			if self.Token ~= token then return end

			local queued = entries[index]
			if queued then
				-- A freshly created piece only measures after the layout pass.
				richText:AwaitLayout(queued.Entry.Frame, Config.Line.MeasureTimeout)

				if self.Token ~= token then return end

				--[[
					The size comes from the first measured piece and applies to the whole list:
					the pieces are all the same size, and the math uses the longest sentence (see
					`RichTextController:FitSize`); measuring again on each line would only open
					the chance of two lines coming out with different text sizes.

					The math yields the first time (the sentence width is measured by an
					asynchronous call), so the token is checked again after it.
				]]
				if not size then
					size = richText:FitSize(queued.Entry.Frame, texts, Config.Text, Config.Line.Fit)

					if self.Token ~= token then return end
				end

				queued.Entry.Handle:Write(
					self:markup(queued.Line.Text, queued.Line.Kind),
					{ Size = size }
				)
			end

			if index < #lines then
				task.wait(Config.Line.Stagger)
			end
		end
	end)
end

--[=[
	The screen changed size: the panel returns to the new screen's resting scale and the
	list is rewritten at the new measurement.

	Rotating the phone or dragging the window changes two things: the screen factor (and
	with it the panel's resting scale) and each line's box, and with it both text size
	computations: the height ratio and the width the longest line needs. The renderer
	rescales what is already written along with the box, which keeps the proportion, but
	does not undo a line break the new width no longer needs.

	`writeLinesWhenSettled` itself writes the new scale: it already exists to avoid
	writing on a panel out of rest, and a panel out of rest with no tween at all is
	exactly what a new screen leaves.

	It only applies with the panel open, and the last arrival sets the pace: a window drag
	fires this every frame, and rewriting the list on each would be the typing animation
	restarting nonstop.

	The **screen** is listened to, not the panel size: the panel changes size on every
	frame of its own entrance animation, and that change is not a new screen.
]=]
function WeatherIndicatorController:onViewportChanged()
	if not self.IsOpen then return end

	self.ViewportToken += 1
	local token = self.ViewportToken

	task.delay(Config.Line.ResizeDebounce, function()
		if self.ViewportToken ~= token or not self.IsOpen then return end

		self:writeLinesWhenSettled()
	end)
end

--[=[
	Writes the list with the panel at its resting scale, and not before.

	It is the only door the list enters through, and it exists because of how rich text
	sizes itself: it stores the box size at render time and scales the text by the ratio
	between the current size and that one. Since a child's `AbsoluteSize` already comes
	multiplied by the panel's `UIScale`, writing mid-entrance measures the box almost
	closed, and the line ends up screen-sized when the panel reaches the end, or does not
	appear, when the scale was still zero and the render was discarded for measuring zero.

	The **scale** decides, not the tween's state: a panel already at rest writes
	immediately, a panel out of rest waits. Waiting for the tween is the normal path; the
	`else` covers a panel left out of rest with no tween at all (a `Cancel` midway), and
	then the scale is written by hand and the list comes a frame later, the time for
	layout to measure.

	The previous list is cleared while waiting: it must not stay on screen under the
	animation of an opening that has not written yet.

	`Cancelled` does not write: it is the close (or another open) having knocked the tween
	down, and whoever knocked it down already decided what the screen shows.
]=]
function WeatherIndicatorController:writeLinesWhenSettled()
	local uiScale = self.Scale
	local rest = self:openScale()

	if not uiScale or math.abs(uiScale.Scale - rest) <= SCALE_EPSILON then
		self:refreshLines()

		return
	end

	self:clearLines()

	self.Token += 1
	local token = self.Token

	local tween = self.ScaleTween

	if tween and tween.PlaybackState == Enum.PlaybackState.Playing then
		tween.Completed:Once(function(state : Enum.PlaybackState)
			if state ~= Enum.PlaybackState.Completed then return end
			if self.Token ~= token or not self.IsOpen then return end

			self:refreshLines()
		end)

		return
	end

	uiScale.Scale = rest

	task.spawn(function()
		task.wait()

		if self.Token ~= token or not self.IsOpen then return end

		self:refreshLines()
	end)
end

--[[ OPEN AND CLOSE ]]

--[=[
	Takes the `UIScale` to a scale, canceling the previous tween.

	`Cancel` stops the tween without restoring the property: the scale stays where it got
	and the new one starts from there, which is what makes a click mid-animation chain
	instead of jumping.
]=]
function WeatherIndicatorController:tweenScale(scale : number, info : TweenInfo) : Tween?
	local uiScale = self.Scale
	if not uiScale then return nil end

	if self.ScaleTween then
		self.ScaleTween:Cancel()
	end

	local tween = TweenService:Create(uiScale, info, { Scale = scale })
	self.ScaleTween = tween
	tween:Play()

	return tween
end

--[=[
	Opens the panel: it grows, and the list comes in when it stops growing (see
	`writeLinesWhenSettled`).

	The arrival scale is the **authored** one on the `UIScale` corrected by the screen
	(see `openScale`): a panel drawn at 0.8 opens at 0.8 on the reference screen, and
	larger than that on a larger screen.

	With no active weather it does not open: the button is not even there, but `Toggle` is
	public and the screen state must not depend on who calls it.
]=]
function WeatherIndicatorController:Open()
	local panel = self.Panel
	if not panel or not self:current() then return end

	self.IsOpen = true

	--[[
		Opening is the discovery: the badge retires here, not on the button click, because
		the button is not the only caller of `Open`, and what retires the notice is the
		panel having been seen, wherever the opening came from.
	]]
	self.PanelSeen = true

	local badge = self.NewBadge
	if badge then
		badge.Visible = false
	end

	panel.Visible = true

	self:refreshHeader()
	self:tweenScale(self:openScale(), Config.Scale.OpenInfo)
	self:writeLinesWhenSettled()
end

--[=[
	Closes the panel. `instant` skips the animation: that is what a weather ending and a
	round restarting need.

	The text is cleared too: the list must come in writing on the next open, not already
	finished under the entrance animation.
]=]
function WeatherIndicatorController:Close(instant : boolean?)
	local panel = self.Panel
	if not panel then return end

	self.IsOpen = false

	-- Knocks down any write still in progress, and marks this exit.
	self.Token += 1
	local token = self.Token

	self:clearLines()

	if instant then
		if self.ScaleTween then
			self.ScaleTween:Cancel()
			self.ScaleTween = nil
		end

		local scale = self.Scale
		if scale then
			scale.Scale = Config.Scale.Closed
		end

		panel.Visible = false

		return
	end

	local tween = self:tweenScale(Config.Scale.Closed, Config.Scale.CloseInfo)
	if not tween then
		panel.Visible = false

		return
	end

	tween.Completed:Once(function()
		-- Only hides if this exit is still the current one: reopening before the animation
		-- ends leaves the panel open, and the later arrival rules.
		if self.Token ~= token or self.IsOpen then return end

		panel.Visible = false
	end)
end

--[=[
	The button's toggle.
]=]
function WeatherIndicatorController:Toggle()
	if self.IsOpen then
		self:Close()
	else
		self:Open()
	end
end

--[=[
	The weather changed: the button follows, and the open panel rebuilds, or closes when
	the sky cleared.
]=]
function WeatherIndicatorController:refresh()
	self:refreshButton()

	if not self:current() then
		if self.IsOpen then
			self:Close(true)
		end

		return
	end

	if self.IsOpen then
		self:refreshHeader()

		-- It may be a weather that changed mid-entrance, and then the new list
		-- waits for the same reason the first one did.
		self:writeLinesWhenSettled()
	end
end

--[[ LIFECYCLE ]]

function WeatherIndicatorController:construct()
	if not self:bind() then return end

	self:refreshButton()

	local button = self.Button :: GuiButton

	button.MouseButton1Click:Connect(function()
		self:Toggle()
	end)

	Framework:Listen("WeatherChanged", function()
		--[[
			`WeatherController` keeps the current weather, and it listens to the same
			notification. Reading from it one frame later avoids keeping a second copy of
			the same state here, and one fewer copy is one fewer chance of the two
			disagreeing.
		]]
		task.defer(function()
			self:refresh()
		end)
	end)

	--[[
		The active weather's deadline, with the name: the name is what separates this
		deadline from that of a weather that already left, since the order between this
		notification and `WeatherChanged` is not guaranteed.
	]]
	Framework:Listen("WeatherDuration", function(weatherName : any, untilWave : any)
		self.EndsName = if typeof(weatherName) == "string" then weatherName else nil
		self.EndsWave = tonumber(untilWave)

		self:refreshHeader()
	end)

	Framework:Listen("SetWave", function(wave : any)
		self.Wave = tonumber(wave) or self.Wave

		-- The deadline sentence counts the running wave, so it ages every wave even
		-- without the weather changing.
		self:refreshHeader()
	end)

	--[[
		A new round does not inherit the previous one's deadline, nor the open panel of the
		player who was reading when the match turned over.
	]]
	Framework:Listen("RoundRestarted", function()
		self.Wave = 0
		self.EndsName = nil
		self.EndsWave = nil

		-- New match, new discovery: the badge returns on its first weather.
		self.PanelSeen = false

		self:Close(true)
		self:refreshButton()
	end)

	--[[
		A screen that changes size (window, phone rotation) changes the text math, and the
		open list is rewritten at the new measurement. See `onViewportChanged`.
	]]
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			self:onViewportChanged()
		end)
	end

	-- A player joining in the middle of a storm needs its deadline.
	Framework:Fire("RequestWeatherDuration")
end

--[=[
	The weather this client joined with.

	The `WeatherChanged` for a player arriving mid-storm is requested by
	`WeatherController`, in its `construct`, and may have gone and come back before the
	`Listen` here existed. Reading its state here (after every `init`) is what guarantees
	the right button on screen even in that order.
]=]
function WeatherIndicatorController:start()
	if not self.Button then return end

	self:refresh()
end

function WeatherIndicatorController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WeatherIndicatorController
