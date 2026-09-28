--[[
	Rich text: the vocabulary the game speaks.

	Code that writes animated text never writes library tags: it speaks this
	vocabulary, and `RichTextController` translates it to the current technology
	(today HyperText, in `ReplicatedStorage.Shared.Vendor.HyperText`).

	The three tables live in the same file on purpose: together they are the whole
	contract. Switching libraries means rewriting the library column in `Aliases`,
	writing a new backend, and touching nothing else in the game.

		Options   - what a render can ask for (speed, color, font...)
		Presets   - named combinations: "Dialogue", "Warning", "Instant"
		Aliases   - markup inside the text: `[shake]BLIZZARD[/shake]`

	**Markup.** Brackets, not angle brackets: `[name]text[/name]` wraps a span,
	`[name]` alone marks a point (`[br]`, `[pause]`). An alias that takes a value
	uses `=`: `[color=red]`, `[size=40]`, `[pause=1]`. Brackets separate our markup
	from the vendor's: a hand-written `<...>` still reaches the library raw, the
	escape hatch for what is not an alias yet.

	**Why two levels.** `Options` applies to the whole render and does not fit in the
	text (font, alignment, speed); `Aliases` apply to a span and only make sense
	mid-sentence. Text from the server or a translation crosses the network as text,
	which is why the effect travels inside it.

	See docs/common/rich-text.md.
]]

local RichTextConfig = {}

--[[
	Backend order of preference. The controller tries top to bottom and keeps the
	first that loads.

	`Plain` is last and never fails: it strips the markup and writes plain text into
	a TextLabel. It holds the screen when the vendor falls out of sync or breaks in a
	Roblox update: an ugly warning beats no warning.
]]
RichTextConfig.Backends = { "HyperText", "Plain" }

--[=[
	What a render can ask for. All optional; anything missing takes the `Defaults`
	value and, failing that, the backend default.

	`Speed` is in **characters per second**, not an interval: that is how you think
	about a typewriter, and the backend converts. `Speed = 0` writes everything at once.
]=]
--[=[
	How the text size comes from the **box** instead of a pixel number.

	Pixels do not translate between screens: 12 px is a fifth of a box on a monitor
	and half of it on a phone. With `Fit`, the controller measures the box at write
	time and derives the text size from it: `Size` computed, not written.

	There are two walls, and the text size is the smaller:

	  1. the box **height** times `TextRatio`, divided by the rows;
	  2. the box **width** against the real width of the longest sentence, also
	     divided by the rows.

	That is why **rows** enter the math. A 32-character sentence in a narrow box is
	tiny if it must fit one row: width rules, and rules small. Allowing two doubles
	the available width and halves each row's height. The controller tries 1 to
	`MaxRows` and keeps whichever gives the **largest** text.

	`TextRatio` is the text height as a fraction of the box height; the rest is padding.

	`MinTextSize` is the floor: below it nothing is readable, and it is better for the
	sentence to overflow (and someone notice) than to become a gray smudge.
	`MaxTextSize` is the ceiling, so a big box with a short sentence does not become
	a billboard.

	`MaxRows` is how many rows a sentence may take. 1 is the default because it
	surprises nobody; a wrapping container (a dialog, a tutorial) says how many fit.

	`WidthPerChar` is the **fallback**: sentence width is measured for real
	(`TextService`), and this per-character estimate only applies when measuring
	fails. 0.6 is a proportional font's average; an almost monospaced font (Press
	Start 2P) wants 1.

	`Font` is the font width is measured in, used only when the render did not set
	`Options.Font`. The value is HyperText's default: measuring in one font and
	drawing in another gives the wrong size.

	`LayoutTimeout` is how long to wait for the box to have a **stable** size before
	measuring. A new piece only has a size after the layout pass. See
	`RichTextController:AwaitLayout`.

	`Debug` logs in Studio **which wall** decided the size. Without it, tuning a box
	is guesswork: `TextRatio` does nothing when width limits, and `MaxRows` does
	nothing when height limits.
]=]
export type FitOptions = {
	TextRatio : number?,
	MaxRows : number?,
	MinTextSize : number?,
	MaxTextSize : number?,
	WidthPerChar : number?,
	Font : string?,
	LayoutTimeout : number?,
	Debug : boolean?,
}

export type Options = {
	-- A named combination from `Presets`, applied underneath everything else.
	Preset : string?,

	-- Typewriter.
	Speed : number?,
	Sound : (string | number)?,
	SoundVolume : number?,

	-- Look.
	Size : number?,

	--[[
		Derives `Size` from the box instead of taking pixels. `true` uses the
		`RichTextConfig.Fit` defaults; a table overrides any of them.

		When on, the write **yields**: it waits for a stable box size and measures
		the sentence width asynchronously. Code in a click handler already runs in its
		own thread; anything else should use `task.spawn`.
	]]
	Fit : (boolean | FitOptions)?,

	Color : Color3?,
	Font : string?,
	Weight : Enum.FontWeight?,
	Italic : boolean?,
	Transparency : number?,
	Stroke : { Thickness : number?, Color : Color3?, Transparency : number? }?,
	Shadow : { Color : Color3?, Offset : Vector2? }?,

	-- Each character's entrance: "slide", "bounce", "wiggle", "grow", or "none".
	Anim : string?,
	AnimDuration : number?,
	AnimLoop : boolean?,

	-- Layout inside the container.
	Align : Enum.HorizontalAlignment?,
	VerticalAlign : Enum.VerticalAlignment?,
	ZIndex : number?,
	Wrapped : boolean?,

	-- `true` holds the caller's thread until the render ends.
	Yield : boolean?,
}

--[[
	What applies to every render that does not ask otherwise.

	Short on purpose: each value is a decision the backend no longer makes.
	`Anim = "none"` because most screens want text, not an entrance animation; those
	that do ask for a preset.
]]
RichTextConfig.Defaults = {
	Speed = 0,
	Anim = "none",
	Wrapped = true,
} :: Options

--[[
	`Fit` defaults, for renders that set `Fit = true` without choosing anything.
	Call options override them field by field. See the `FitOptions` type.
]]
RichTextConfig.Fit = {
	TextRatio = 0.9,
	MaxRows = 1,
	MinTextSize = 6,
	MaxTextSize = math.huge,
	WidthPerChar = 0.6,
	Font = "rbxasset://fonts/families/FredokaOne.json",
	LayoutTimeout = 1,
	Debug = true,
} :: FitOptions

--[[
	Named combinations.

	The name is what game code says; the contents are designer tuning and can change
	here without anyone else noticing.
]]
RichTextConfig.Presets = {
	-- Text that only needs to appear.
	Instant = {
		Speed = 0,
		Anim = "none",
	},

	-- A short, urgent warning, sized for `WarningController`: types in letter by
	-- letter, fast, with an outline to survive any background.
	Warning = {
		Speed = 45,
		Anim = "slide",
		AnimDuration = 0.35,
		Stroke = { Thickness = 0.04, Color = Color3.new(0, 0, 0) },
		Align = Enum.HorizontalAlignment.Center,
		VerticalAlign = Enum.VerticalAlignment.Center,
	},

	--[[
		NPC dialog: slow enough to read at a speaker's pace.

		`Size` is the line height in pixels **in the box at the size it had when the
		text entered**: the renderer keeps that as the reference and rescales with the
		screen, so the number works at every resolution. 24 fits today's
		`DialogGUI.Container` (625x287) with room for four lines; 38 already overflows
		and breaks words. A box of another size needs another number, changed here.
	]]
	Dialogue = {
		Size = 24,
		Speed = 28,
		Anim = "slide",
		AnimDuration = 0.25,

		-- Centered on both axes: the dialog fills the box instead of growing from the
		-- top corner, and a short sentence does not float at the top.
		Align = Enum.HorizontalAlignment.Center,
		VerticalAlign = Enum.VerticalAlignment.Center,
	},
} :: { [string] : Options }

--[=[
	The palettes `[gradient=name]` uses.

	Colors as `r,g,b`, separated by `;`: the format HyperText understands, and
	repeating it here is more honest than inventing our own and converting midway.
	From 1 to 18 colors.

	`MoveSpeed` is how many full color cycles the gradient makes per second; zero is
	a still gradient. `MoveDir` ("left" or "right") and `Rot` (degrees) are optional.

	The name is what the game writes (`[gradient=orange]`), and it survives a library
	change. Colors are designer tuning and change here.
]=]
RichTextConfig.Gradients = {
	-- The module's own, for `[gradient]` without a name.
	default = { Colors = "85,170,255;255,85,0" },

	orange = { Colors = "255,205,95;255,110,20", MoveSpeed = 0.2 },
	green = { Colors = "165,255,150;35,170,80", MoveSpeed = 0.5 },
	gold = { Colors = "255,240,170;225,165,40", MoveSpeed = 0.3 },
	ice = { Colors = "200,245,255;70,160,255", MoveSpeed = 0.25 },
}

--[=[
	The markup the game writes, and what it becomes in each backend.

	Each alias has one column per backend. `Plain` has none because it strips
	everything; that is its point.

	`%s` is where `[name=value]`'s value goes. An alias with `%s` and no `Default`
	requires a value; without `%s`, a value is ignored. An alias without `Close` is a
	point in the text and does not close: `[br]`, `[pause=1]`.

	`Converter` is a value that differs between the two worlds: `"Speed"` is
	characters per second here and an interval in seconds inside. The backend
	converts, because the target unit is its own.

	Player-typed values never reach here: `RichTextController:Escape()` exists for
	player names and chat, and neutralizes brackets and `<` first.
]=]
export type Alias = {
	HyperText : { Open : string, Close : string? }?,
	Default : string?,
	Converter : string?,
}

RichTextConfig.Aliases = {
	--[[ STYLE ]]

	b = { HyperText = { Open = "<weight=bold>", Close = "</weight>" } },
	i = { HyperText = { Open = "<italic=true>", Close = "</italic>" } },
	u = { HyperText = { Open = "<underline=true>", Close = "</underline>" } },
	s = { HyperText = { Open = "<strike=true>", Close = "</strike>" } },

	color = { HyperText = { Open = "<color=%s>", Close = "</color>" } },
	size = { HyperText = { Open = "<size=%s>", Close = "</size>" } },
	font = { HyperText = { Open = "<font=%s>", Close = "</font>" } },
	trans = { HyperText = { Open = "<trans=%s>", Close = "</trans>" } },

	stroke = { HyperText = { Open = "<stroke=true>", Close = "</stroke>" } },
	shadow = { HyperText = { Open = "<shadow=true>", Close = "</shadow>" } },
	mark = { HyperText = { Open = "<mark=true>", Close = "</mark>" } },

	--[[ EFFECT ]]

	-- A short, violent shake: damage, danger, something breaking.
	shake = { HyperText = { Open = "<shake=true loop=true dur=.4>", Close = "</shake>" } },

	--[[
		A continuous wave: something magical, floating.

		`amp` is the wave height as a fraction of the letter size, and it makes the
		effect subtle or circus-like: the module default (.3) shakes the whole
		sentence. .1 with `rot=false` waves the line without tilting the letters, so
		the text stays readable while it moves, which is the point in a dialog.
	]]
	wiggle = { HyperText = { Open = "<anim=wiggle loop=true amp=.1 rot=false>", Close = "</anim>" } },

	rainbow = { HyperText = { Open = "<rainbow=true>", Close = "</rainbow>" } },
	fog = { HyperText = { Open = "<fog=true>", Close = "</fog>" } },

	-- Sparkles over the text. The value is their color: a module shortcut
	-- (`[shiny=yellow]`) or `r,g,b`.
	shiny = { HyperText = { Open = "<shiny=true color=%s>", Close = "</shiny>" }, Default = "white" },

	-- A gradient from a palette named in `RichTextConfig.Gradients`.
	gradient = {
		HyperText = { Open = "<gradient=true %s>", Close = "</gradient>" },
		Default = "default",
		Converter = "Gradient",
	},

	-- Shiny gold: the letter color and the sparkle at once, because together they make
	-- the effect; the color alone is yellow text, the sparkle alone is glitter in the
	-- dark.
	gold = {
		HyperText = {
			Open = "<color=255,205,70><shiny=true color=255,240,175 rate=1.5>",
			Close = "</shiny></color>",
		},
	},

	--[[ PACING AND PUNCTUATION ]]

	-- Line break. A raw `\n` is ignored by HyperText on purpose.
	br = { HyperText = { Open = "<br=%s>" }, Default = "1" },

	-- A pause mid-typing, in seconds.
	pause = { HyperText = { Open = "<wait=%s>" }, Default = "0.4" },

	-- Speed from here on, in characters per second. The backend converts.
	speed = { HyperText = { Open = "<interval=%s>", Close = "</interval>" }, Converter = "Speed" },

	-- An inline image by asset id.
	img = { HyperText = { Open = "<img=%s>" } },

	-- A mark in the text that fires `handle:OnEvent(name)` when typing reaches it.
	-- It is how a dialog syncs sound and camera with its own sentence.
	event = { HyperText = { Open = "<renderEvent=%s>" } },
} :: { [string] : Alias }

return RichTextConfig
