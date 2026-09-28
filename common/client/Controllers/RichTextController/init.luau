local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("RichTextController")

local Config = SharedConfig.RichTextConfig

--[[
	The size a sentence's width is measured at (see `measureWidth`).

	A text's width is linear in font size, so measuring once at a large size and
	scaling gives the width at any size, with the bonus that a small size's rounding
	error does not enter the math. It never shows on screen.
]]
local PROBE_SIZE = 100


--[[
	Rich text: letter by letter, with color, shake, and images mid-sentence.

	HyperText (`Shared.Vendor.HyperText`, MIT, by @lopjoss) renders it today, but the
	game does not know that. The game talks to this controller:

		local RichText = Framework:Get("RichTextController")

		RichText:Write(label, "WARNING! [shake]FOG[/shake] COMING IN 3 ROUNDS", {
			Preset = "Warning",
		})

	Or, when the same container will receive several sentences (an NPC line, a
	tutorial), keep the handle and reuse it:

		local handle = RichText:Bind(dialogueFrame, { Preset = "Dialogue" })

		handle:OnFinished(function()
			prompt.Visible = true
		end)

		handle:Write("Welcome, [color=yellow]commander[/color].[pause=1] Have a seat.")

	**Why not require HyperText directly.** Because it is today's choice. What the
	game writes (the markup inside the text, the preset names, the handle's methods)
	is described in `SharedConfig.RichTextConfig` and here, in terms that belong to no
	library. Switching technology means writing a new backend next to the two that
	exist and changing one column in the alias table; no game screen changes a line.

	**The backend.** `Backends/` has one module per technology. Each loads its library
	late, inside a pcall, and says whether it succeeded: that lets the config's
	`Backends` list an order of preference and this controller settle on the first
	that answers. Today: `HyperTextBackend` and, as a fallback, `PlainBackend`, which
	strips the markup and writes plain text into a TextLabel. The fallback is not
	decoration: vendor out of sync, a require error, an engine change; in any of these
	the warning still appears, ugly, but it appears.

	A backend implements:

		Backend.Name                            string
		Backend.Load() -> boolean               tries to load the library
		Backend.Tag(name, value, closing)       alias -> dialect (nil = not an alias)
		Backend.Create(container) -> object
		Backend.Apply(object, options)          neutral options -> library settings
		Backend.Render(object, text, options)
		Backend.Skip / Pause / Resume (object)
		Backend.Clear(object, instant)
		Backend.Destroy(object)
		Backend.IsRendering(object) -> boolean
		Backend.GetText(object) -> string?
		Backend.OnFinished(object, fn) -> () -> ()
		Backend.OnEvent(object, fn) -> () -> ()

	**Font size.** `Size` is in pixels, and pixels do not translate between screens.
	To have the font size come from the box instead of a number, ask for `Fit`:

		RichText:Write(label, "WAVE 12 INCOMING", { Fit = true })

	The box is measured at the moment of writing, and the size comes from it; see
	`RichTextConfig.Fit` for the math's walls and `:FitSize()` for a box that needs a
	single size for several sibling pieces.

	**The markup.** `[name]text[/name]`, `[name=value]`, `[br]`. Only what is in
	`RichTextConfig.Aliases` is a tag; any other bracket is plain text, which is what
	keeps a `[1]` in the middle of a sentence a `[1]`. `[[` writes a literal bracket:
	that is how `:Escape()` neutralizes player text.

	It lives in `common/` because both places write on screen.

	See docs/common/rich-text.md.
]]

local RichTextController = {
	Controllers = {}
}

-- The backend in use. Resolved the first time someone writes, not in `init`: a
-- controller that renders in its own `init` must not depend on the order in which
-- `Me:Load()` swept the folder.
RichTextController.Backend = nil :: any

RichTextController.Resolved = false

-- [GuiObject] = Handle. A container has a single handle: two renderers on the
-- same frame would write over each other.
RichTextController.Handles = {}

--[[
	`[font][sentence] = width at PROBE_SIZE`, for those already measured.

	It holds for the whole session: the same sentence does not change width between
	two writes, and the call that measures it is asynchronous. Without the cache,
	every relaunch of the same screen would pay the trip again.
]]
RichTextController.Widths = {}

--[[ HANDLE ]]

--[=[
	The object the game holds: a container plus the render in it.

	Every method returns `self` when it has nothing better to return, so calls can be
	chained. None of them blows up if the backend died midway: a handle for a
	destroyed container becomes inert instead of an error.
]=]
local Handle = {}
Handle.__index = Handle

export type Options = typeof(Config.Defaults)

export type Handle = typeof(setmetatable(
	{} :: {
		Container : GuiObject,
		Options : Options,
		Backend : any,
		Object : any,
		Alive : boolean,
	},
	Handle
))

--[=[
	Writes.

	Options passed here go on top of the ones the handle already had and **stay**:
	it is a `:SetOptions()` before the text, not a one-sentence adjustment. Going back
	means passing the old value again. It works this way because options become the
	renderer's internal configuration: undoing them after each sentence would cost a
	rebuild per sentence for a case the game does not have.

	With `Fit` on, the call **yields** before writing: the font size comes from the
	box, and the box only measures after the layout pass. See `:Fit()`.
]=]
function Handle:Write(text : string, options : Options?) : Handle
	if not self.Alive then return self end

	if options then
		self:SetOptions(options)
	end

	if self.Options.Fit then
		self:Fit(text)

		-- `:Fit()` yields, and the container may have been destroyed in the meantime.
		if not self.Alive then return self end
	end

	self.Backend.Render(self.Object, RichTextController:translate(text, self.Backend), self.Options)

	return self
end

--[=[
	Measures the box and takes the font size from it, from now on.

	It is what `Fit` does on its own on every `:Write()`. Calling it by hand is for
	afterward: the screen changed size and what is written needs the new measurement.

		container:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			handle:Fit()
		end)

	Without `text`, the math uses the last sentence written, which is what a resized
	screen wants. With `text`, it uses what is about to be written, which is what
	`:Write()` wants: the sentence not there yet is the one that has to fit.

	A list of sentences measures by the **longest** and returns a single size. See
	`RichTextController:FitSize`.

	**Yields**: waits for the box to have a stable size and measures the sentence's
	width with an asynchronous call. It does not rewrite what is already on screen: the
	renderer rescales what is drawn along with the box; the new size applies to the
	next write.
]=]
function Handle:Fit(text : (string | { string })?) : Handle
	if not self.Alive then return self end

	local sample = text or self.Backend.GetText(self.Object) or ""

	local fit = RichTextController:fitSettings(self.Options.Fit)

	RichTextController:AwaitLayout(self.Container, fit.LayoutTimeout)

	if not self.Alive then return self end

	local size = RichTextController:FitSize(self.Container, sample, self.Options, fit)

	if not self.Alive then return self end

	self.Options.Size = size
	self.Backend.Apply(self.Object, self.Options)

	return self
end

--[=[
	Shows everything now, without waiting for the rest of the typing. It is what the
	player's click mid-dialog should do.
]=]
function Handle:Skip() : Handle
	if self.Alive then
		self.Backend.Skip(self.Object)
	end

	return self
end

function Handle:Pause() : Handle
	if self.Alive then
		self.Backend.Pause(self.Object)
	end

	return self
end

function Handle:Resume() : Handle
	if self.Alive then
		self.Backend.Resume(self.Object)
	end

	return self
end

--[=[
	Clears what is written. `instant` skips the exit animation.
]=]
function Handle:Clear(instant : boolean?) : Handle
	if self.Alive then
		self.Backend.Clear(self.Object, instant)
	end

	return self
end

--[=[
	Replaces the handle's options from now on. It does not rewrite what is already on
	screen: call `:Write()` again for that.
]=]
function Handle:SetOptions(options : Options) : Handle
	if not self.Alive then return self end

	self.Options = RichTextController:resolveOptions(options, self.Options)
	self.Backend.Apply(self.Object, self.Options)

	return self
end

--[=[
	The last sentence's text, with no markup at all. It is for measuring, comparing, or
	sending to the log.
]=]
function Handle:GetText() : string?
	if not self.Alive then return nil end

	return self.Backend.GetText(self.Object)
end

--[=[
	`true` while there are still letters to appear, even when paused.
]=]
function Handle:IsWriting() : boolean
	if not self.Alive then return false end

	return self.Backend.IsRendering(self.Object)
end

--[=[
	Calls back when the sentence finishes appearing. Returns the disconnect function.

	The argument is `true` when the end came from a `:Skip()`: a skipped line does not
	deserve the same dramatic pause as one that ran to the end.
]=]
function Handle:OnFinished(callback : (skipped : boolean) -> ()) : () -> ()
	if not self.Alive then return function() end end

	return self.Backend.OnFinished(self.Object, callback)
end

--[=[
	Calls back when typing passes an `[event=name]`. Returns the disconnect function.

	It is the hook for syncing sound, camera, or VFX with a point in the sentence
	instead of a guessed `task.wait`.
]=]
function Handle:OnEvent(callback : (name : string) -> ()) : () -> ()
	if not self.Alive then return function() end end

	return self.Backend.OnEvent(self.Object, callback)
end

function Handle:Destroy()
	if not self.Alive then return end

	self.Alive = false
	RichTextController.Handles[self.Container] = nil

	self.Backend.Destroy(self.Object)
end

--[[ INTERNAL ]]

--[=[
	The backend in use, loading the first in line that answers.

	The warning at the end is for the impossible case of not even `PlainBackend`
	loading, which only happens with the `Backends` folder out of sync. Returning
	`nil`, every `Write` becomes a silent no-op instead of a cascade of errors.
]=]
function RichTextController:getBackend() : any
	if self.Resolved then
		return self.Backend
	end

	self.Resolved = true

	for _, name in Config.Backends do
		local module = script.Backends:FindFirstChild(`{name}Backend`)
		if not module or not module:IsA("ModuleScript") then
			log:StudioWarn(`backend "{name}" does not exist in Backends/.`)
			continue
		end

		local backend = require(module) :: any
		if backend.Load() then
			self.Backend = backend

			if name ~= Config.Backends[1] then
				log:StudioWarn(`using backend "{name}": "{Config.Backends[1]}" did not load.`)
			end

			return backend
		end
	end

	log:StudioWarn("no backend loaded; rich text is off.")

	return nil
end

--[=[
	Merges `Defaults`, the preset, and what came in the call, in that order.

	`base` is what the handle already had: it keeps a `:SetOptions()` with a single
	option from throwing away the rest of the handle's configuration.

	The preset only applies when it comes in **this** call. `base`'s preset is already
	inside `base`, mixed with the adjustments the caller made on top of it; reapplying
	it here would undo exactly those adjustments.
]=]
function RichTextController:resolveOptions(options : Options?, base : Options?) : Options
	local resolved = {}

	local function merge(source : any?)
		if not source then return end

		for key, value in source do
			if key == "Preset" then continue end

			resolved[key] = value
		end
	end

	merge(Config.Defaults)
	merge(base)

	local presetName = options and options.Preset
	if presetName then
		local preset = Config.Presets[presetName]
		if preset then
			merge(preset)
		else
			log:StudioWarn(`preset "{presetName}" does not exist in RichTextConfig.Presets.`)
		end
	end

	merge(options)
	resolved.Preset = presetName or (base and base.Preset)

	return resolved
end

--[=[
	`Fit`'s settings resolved against `RichTextConfig.Fit`.

	`true` (or anything that is not a table) means "the defaults"; a table goes on top
	of them field by field, so someone changing only `MaxRows` does not have to repeat
	the other five.
]=]
function RichTextController:fitSettings(fit : any) : any
	local resolved = {}

	for key, value in Config.Fit do
		resolved[key] = value
	end

	if type(fit) == "table" then
		for key, value in fit do
			if value ~= nil then
				resolved[key] = value
			end
		end
	end

	return resolved
end

--[=[
	A sentence's width at `PROBE_SIZE`, or `nil` when it could not be measured.

	Actually measured, not estimated by character count: the estimate (see
	`FitOptions.WidthPerChar`) errs both ways: too conservative, it shrinks the text
	for no reason; too optimistic, it lets the sentence overflow the box. Since width
	is linear in font size, one measurement serves every size.

	Yields, because the call is asynchronous; callers are already on their own thread.
	The result is cached per sentence **and per font**: the same sentence in two fonts
	is two widths.

	On failure (the font does not exist, the call was refused), returns `nil` and the
	caller falls back to the estimate. It is a better measurement, not a required one.
]=]
function RichTextController:measureWidth(text : string, font : string) : number?
	local byFont = self.Widths[font]
	if not byFont then
		byFont = {}
		self.Widths[font] = byFont
	end

	local cached = byFont[text]
	if cached then
		return cached
	end

	local success, bounds = pcall(function()
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Size = PROBE_SIZE
		params.Font = Font.new(font)

		-- 0 means "no limit": the width we want is the sentence's on a single row, and
		-- that is where the count of rows it needs comes from.
		params.Width = 0

		return TextService:GetTextBoundsAsync(params)
	end)

	if not success or not bounds or bounds.X <= 0 then
		return nil
	end

	byFont[text] = bounds.X

	return bounds.X
end

--[=[
	Our markup becoming the backend's dialect.

	A manual scan instead of `gsub` because of `[[`: an escape must be seen before the
	next `[` is considered a tag opening.

	A bracket that does not open a known alias goes back into the text as it was. That
	is what allows writing "[1]" or "[SPOILER]" in a sentence without escaping
	anything, and what makes a misspelled alias show on screen instead of vanishing
	silently.
]=]
function RichTextController:translate(text : string, backend : any) : string
	local out = {}
	local index = 1
	local length = #text

	while index <= length do
		local open = string.find(text, "[", index, true)

		if not open then
			table.insert(out, string.sub(text, index))
			break
		end

		table.insert(out, string.sub(text, index, open - 1))

		if string.sub(text, open + 1, open + 1) == "[" then
			table.insert(out, "[")
			index = open + 2
			continue
		end

		local close = string.find(text, "]", open + 1, true)
		if not close then
			table.insert(out, string.sub(text, open))
			break
		end

		local body = string.sub(text, open + 1, close - 1)
		local closing = string.sub(body, 1, 1) == "/"
		if closing then
			body = string.sub(body, 2)
		end

		local name, value = string.match(body, "^([%a][%w_]*)=(.+)$")
		if not name then
			name = string.match(body, "^([%a][%w_]*)$")
		end

		local tag = name and backend.Tag(string.lower(name), value, closing)

		table.insert(out, tag or string.sub(text, open, close))
		index = close + 1
	end

	return table.concat(out)
end

--[[ API ]]

--[=[
	The container's handle, creating one if there is none yet.

	Calling twice with the same container returns the same handle; `options` from the
	second call on act as `:SetOptions()`.
]=]
function RichTextController:Bind(container : GuiObject, options : Options?) : Handle?
	local existing = self.Handles[container]
	if existing then
		if options then
			existing:SetOptions(options)
		end

		return existing
	end

	local backend = self:getBackend()
	if not backend then
		return nil
	end

	local resolved = self:resolveOptions(options)
	local object = backend.Create(container)
	if not object then
		return nil
	end

	backend.Apply(object, resolved)

	local handle = setmetatable({
		Container = container,
		Options = resolved,
		Backend = backend,
		Object = object,
		Alive = true,
	}, Handle)

	self.Handles[container] = handle

	-- The container is the designer's, not ours: it goes away when the screen does, and
	-- the handle goes with it instead of becoming a dead cache entry.
	container.Destroying:Once(function()
		handle:Destroy()
	end)

	return handle
end

--[=[
	Writes into a container, managing the handle for the caller. It is the one-line
	call, for a screen that writes a sentence and forgets it.
]=]
function RichTextController:Write(container : GuiObject, text : string, options : Options?) : Handle?
	local handle = self:Bind(container, options)
	if not handle then
		return nil
	end

	-- `Bind` already applied the options when creating or finding the handle; passing
	-- them again would make the backend rebuild the same configuration for nothing.
	handle:Write(text)

	return handle
end

--[=[
	Clears whatever is written in the container. A container without a handle is
	silence, not an error: clearing what was never written is a legitimate no-op.
]=]
function RichTextController:Clear(container : GuiObject, instant : boolean?)
	local handle = self.Handles[container]
	if not handle then return end

	handle:Clear(instant)
end

--[=[
	Releases the container: stops the render, clears it, and forgets the handle.
]=]
function RichTextController:Release(container : GuiObject)
	local handle = self.Handles[container]
	if not handle then return end

	handle:Destroy()
end

--[=[
	Waits for the piece to have a **stable** on-screen size, and says whether it did.

	Nonzero is not enough. The measured size is what decides the font size (see
	`:FitSize()`) and what the renderer keeps as the scale reference for what it drew,
	and a `UIListLayout` still distributing its pieces gives an intermediate value that
	would become a wrong font size frozen on screen.

	The timeout exists for a box that will never get a size (screen disabled by another
	controller, hidden parent, authored zero size): that becomes a write with no
	effect, not an infinite wait. Writing when the timeout runs out is deliberate: the
	backend complains in the output that the box measures zero, and that is the clue
	to the bug. Silence here would become a screen that does not appear and does not
	explain.
]=]
function RichTextController:AwaitLayout(container : GuiObject, timeout : number?) : boolean
	local deadline = os.clock() + (timeout or Config.Fit.LayoutTimeout or 1)
	local previous = container.AbsoluteSize

	while true do
		local current = container.AbsoluteSize

		if current.Magnitude > 0 and current == previous then
			return true
		end

		if os.clock() > deadline then
			return false
		end

		previous = current

		task.wait()
	end
end

--[=[
	The font size that fits the box, in pixels.

	It is the math `Fit` does on its own (see `RichTextConfig.Fit` for the why of each
	wall). Calling it directly is for the case `Fit` does not solve: **several sibling
	pieces with a single size**. A list of lines is measured once, on the first piece,
	and the result applies to all of them: a different font size per line would look
	like a bug, not responsiveness:

		local size = RichText:FitSize(firstLine, texts, Config.Text, Config.Fit)

		for _, handle in handles do
			handle:Write(markup(...), { Size = size })
		end

	`text` is a sentence or a list of them; in a list, the **longest** rules. Markup is
	stripped before measuring: color and shake take no width.

	`options` is where the font the width is measured in comes from (and it accepts a
	`Preset`, like any call). `fit` is the settings; when absent it uses
	`options.Fit`, and then the config defaults.

	**Yields** the first time it sees a sentence (see `measureWidth`). It does not wait
	for layout: the box must already be measured when this is called, and callers
	outside `Fit` ensure that with `:AwaitLayout()` first.
]=]
function RichTextController:FitSize(
	container : GuiObject,
	text : (string | { string }),
	options : Options?,
	fit : any?
) : number
	local resolved = self:resolveOptions(options)
	local settings = self:fitSettings(fit or resolved.Fit)

	local longest = ""
	if type(text) == "table" then
		for _, entry in text do
			local plain = self:Plain(entry)

			if #plain > #longest then
				longest = plain
			end
		end
	else
		longest = self:Plain(text)
	end

	local font = resolved.Font or settings.Font
	local measured = if #longest > 0 then self:measureWidth(longest, font) else nil

	local box = container.AbsoluteSize

	local best, bestRows, bestWall = settings.MinTextSize, 1, "the FLOOR (MinTextSize)"

	for rows = 1, math.max(1, settings.MaxRows) do
		local fromHeight = (box.Y * settings.TextRatio) / rows

		local fromWidth = math.huge
		if box.X > 0 and #longest > 0 then
			fromWidth = if measured
				then (box.X * rows * PROBE_SIZE) / measured
				else (box.X * rows) / (#longest * settings.WidthPerChar)
		end

		local size = math.min(fromHeight, fromWidth)

		if size > best then
			best = size
			bestRows = rows
			bestWall = if fromWidth < fromHeight then "the box WIDTH" else "the box HEIGHT"
		end
	end

	-- The ceiling goes in after the choice, not inside the loop: it is a legibility
	-- limit, not a wall that should change how many rows win.
	best = math.min(best, settings.MaxTextSize)

	if settings.Debug then
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.zero

		-- The size math goes to the Studio Output (see `FitOptions.Debug`).
		log:Debug(string.format(
			-- Everything is %.0f, not %d: `ViewportSize` and `AbsoluteSize` are floats, and
			-- `%d` with a float that has no integer representation is an error, not rounding.
			"%s | screen %.0fx%.0f | box %.0fx%.0f | %.0f chars, width %s | text %.1f in %d row(s), limited by %s",
			container:GetFullName(),
			viewport.X, viewport.Y,
			box.X, box.Y,
			#longest,
			if measured then string.format("measured (%.0f at %d)", measured, PROBE_SIZE) else "estimated",
			best, bestRows, bestWall
		))
	end

	return best
end

--[=[
	Text that is not ours (a player name, a chat message, a map name from the server)
	goes through here before entering a sentence.

	It doubles the bracket (the escape `:translate()` understands) and swaps `<` for
	`‹`, the similar single-width sign: HyperText treats `<` as a tag start and would
	swallow the rest of the sentence waiting for a `>` that never comes.
]=]
function RichTextController:Escape(text : string) : string
	local escaped = string.gsub(text, "%[", "[[")
	escaped = string.gsub(escaped, "<", "‹")

	return escaped
end

--[=[
	The sentence with no effects: without our markup and without raw library tags.

	It is for things that do not render rich text: a tooltip, a log line, the name
	that goes into a plain BillboardGui.
]=]
function RichTextController:Plain(text : string) : string
	local plain = self:translate(text, require(script.Backends.PlainBackend))

	return (string.gsub(plain, "<[^<>]->", ""))
end

--[=[
	Which technology is drawing. Only for debugging and for Cmdr.
]=]
function RichTextController:GetBackend() : string?
	local backend = self:getBackend()

	return backend and backend.Name
end

--[[ LIFECYCLE ]]

function RichTextController:start()
	-- Resolves the backend off the first text's path: loading the vendor costs a few
	-- milliseconds, and they do not need to land on top of the first warning.
	self:getBackend()
end

function RichTextController:init()
end

return RichTextController
