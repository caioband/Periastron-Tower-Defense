--[[
	Weathers.

	A weather is a Model in `ReplicatedStorage.Shared.Assets.Weathers`:

		Assets.Weathers
		├── Snow                  (Model, tag "AreaWeather")
		│   ├── Part              (Part with the ParticleEmitters)
		│   └── Lighting          (Folder: LightingService preset)
		└── Rain                  (Model, tags "AreaWeather" + "SkyWeather")
			├── Part              (tag "SkyWeather":  the cloud layer)
			├── Part              (tag "AreaWeather": the rain over the play area)
			└── Lighting          (Folder)

	The **tag** says how each Part is fitted to the map. A weather can have both
	kinds at once: then the Model carries both tags and **each Part states its own**.
	A single-kind weather does not need to tag its Parts: the Model's tag applies to
	all of them.

	The `Lighting` folder is a preset in the same format as `Assets.Lighting`
	(attributes = Lighting properties, children = instances). `WeatherService`
	registers it as a preset and applies it through `LightingService`, so a weather
	change goes through the same interpolated transition as any other lighting change.

	It lives in `common/` because both places mount Weathers.

	See docs/common/weather.md.
]]

local WeatherConfig = {}

-- Where weathers live, starting from `ReplicatedStorage`.
WeatherConfig.AssetsPath = { "Shared", "Assets", "Weathers" }

--[[
	How each weather Part is fitted to the map:

	- `Area`: becomes the map box. Fog, snow: things that happen *inside* the play
	  area.
	- `Sky`: takes the map's X and Z size and rises to an offset above the peak. The
	  height (the Part's Y) is the authored one, because it is the layer's thickness,
	  not its extent.

	Both apply to the **Model** and to each **Part**, and the Part's tag wins:

	- Model with a single tag and untagged Parts: every Part is of that kind. This is
	  how single-kind weathers are authored.
	- Model with both tags: each Part must state its own, or there is no way to guess
	  which of the two boxes it goes in. An untagged Part is rejected with a warning,
	  and the rest of the weather loads normally.

	A Model with neither tag is rejected entirely: that is easier to spot than a
	weather that loads and fits nothing.

	Parts do not need distinct names: `Rain` has two called `Part`, and the tag
	separates them, not the name.
]]
WeatherConfig.Tags = {
	Area = "AreaWeather",
	Sky = "SkyWeather",
}

-- How far a sky weather rises above the map's peak. A Model can carry the
-- `HeightOffset` attribute to set its own value.
WeatherConfig.SkyHeightOffset = 20
WeatherConfig.HeightOffsetAttribute = "HeightOffset"

--[[
	A Part the map carries saying where it is.

	When present, it wins, for both weather kinds. It is exact and depends on no
	heuristic: the computed box for `Volcano` is 500x500 because the background water
	lives inside its `Terrain`, and the authored box is 147x109.

	Only `Position` and `Size` are read; rotation is ignored on purpose.

	`BoundsFolders` and `MaxPartFootprint` below are the fallback, for a map that does
	not have the box yet.
]]
WeatherConfig.BoundsPartName = "BoundingBox"

--[[
	Which map subfolders count toward the box.

	Not the whole map, on purpose. `Locked` holds the background scenery (a
	2047-stud floor on Farm, 2033x2048 water on Mountain), and measuring it too would
	give a box 10x the play area, spreading the particles until they vanish. Farm's
	`Terrain` is 93x103, and Snow's authored Part is 100x100: that is the scale the
	weathers were made to cover.

	A map with none of these folders falls back to the whole map's box.

	Applies only to `AreaWeather`. `SkyWeather` measures the whole map on purpose:
	the sky layer covers everything visible, background floor included.
]]
WeatherConfig.BoundsFolders = { "Terrain", "Path" }

--[[
	A Part larger than this in X or Z does not count toward the box.

	The folders above are not enough: `Snowy` has two 2048x0x2048 `Ice` parts inside
	its own `Terrain`, and `Volcano` keeps its 2048x0x2048 water there too (it has no
	`Locked` at all). They are backdrops (ground painted to the horizon, not play
	area), and a single one stretches the box to 20x the rest of the map.

	512 separates the two populations with room to spare: the largest playable
	geometry in today's maps is ~150 studs, and the smallest backdrop is 2048. If
	nothing is left after the cut, the box is measured again without it, so a small
	map made of a single part keeps working.

	Like `BoundsFolders`, applies only to `AreaWeather`.
]]
WeatherConfig.MaxPartFootprint = 512

-- The loaded map's Model, inside the Workspace.
WeatherConfig.TargetName = "Map"

-- Where the active weather's clone hangs in the Workspace.
WeatherConfig.ContainerName = "Weather"

-- Prefix of the preset the weather registers in `Assets.Lighting`, for the same
-- reason as `MapPrefix`: a weather name must not collide with an authored preset.
WeatherConfig.PresetPrefix = "Weather_"

--[[
	The thunder weather's mechanic: every so often lightning strikes a placed unit.

	`ThunderService` (server) picks the target and keeps the beat, so everyone sees
	the same strike on the same unit. `VFXController` draws it on the client, since
	the `ReplicatedStorage.vfx` module only runs there.
]]
--[[
	Background sound per weather, looped by `WeatherController` while the weather is
	on. `Sound` is the name inside `SharedSounds.SFX` (the lookup is recursive, so
	the subfolder is not part of the name).

	A weather not listed here simply has no ambience.
]]
WeatherConfig.Ambience = {
	Thunder = { Sound = "Thunderstorm", Fade = 2 },
}

-- The ambience's `PlaySFX` key: a single one, so a weather replaces the previous one's.
WeatherConfig.AmbienceKey = "WeatherAmbience"

WeatherConfig.Thunder = {
	-- The Model name in `Assets.Weathers` that turns the mechanic on.
	Weather = "Thunder",

	-- VFX in `Assets.VFX`: an Attachment (the bolt's start) with a single-letter child
	-- Attachment (the end). That is how the `LightningBeams` addon recognizes a bolt.
	Asset = "LightningBeam",

	-- Interval between strikes.
	Interval = 5,

	--[[
		Chance that a strike picks a unit instead of any point in the box.

		It is a pity system: each strike that hits the ground adds `UnitChanceStep`,
		and the first one that hits a unit resets the chance to `UnitChance`. With
		today's values the chance rises 0.15 → 0.30 → … → 1.00, so the seventh strike
		is guaranteed. Simulated over 20 thousand sequences: an average of 2.9 strikes
		until a hit (~15s at the 5s interval) and a worst case of 7 (~35s).

		The chance does not rise when there are no units on the map: pity counts
		strikes that *could* have hit and did not, not strikes that had no target.
	]]
	UnitChance = 0.15,
	UnitChanceStep = 0.15,
	MaxUnitChance = 1,

	--[[
		Where the bolt starts when the cloud layer cannot be used.

		Normally the origin is the weather's own Part in `workspace.Weather`, the bolt
		coming down from where the cloud is. Without it, it falls back to this height
		above the unit's feet.
	]]
	StrikeHeight = 90,

	-- Margin after the asset's `Duration` before destroying the clone.
	Cleanup = 3,

	--[[
		The strike's crack: one clone of `SharedSounds.SFX.Thunders.Thunder` per strike,
		with a fade at the end so the tail does not cut off abruptly. No `Key`, on
		purpose: two strikes in a row may overlap.

		The Sound is created inside the Attachment at the bolt's tip, so it is 3D and
		comes from the impact point. `StrikeVolume` exists because of that: the asset
		has `RollOffMinDistance = 10`, and with the tower defense camera far from the
		ground, attenuation eats much of the volume. It is the multiplier that
		compensates without touching the asset.
	]]
	StrikeSound = "Thunder",
	StrikeFadeOut = 1,
	StrikeVolume = 1,

	--[[
		The stun the strike leaves.

		`Direct` is for the unit the bolt hit squarely; `Chain` is for units hit by the
		arc that jumped from it. The gap is large on purpose: 20s takes a unit out of
		the whole wave, and without a much smaller value on the jump, a well-placed
		strike would black out half the map at once.

		`Radius` is the jump's reach, measured from the struck unit's feet. `Hops` is
		how many times the arc may jump: 1 means only units near the original target
		are hit, and none propagate again. `MaxTargets` caps each jump.

		A unit immune to the weather (see `Effects.Thunder.Immune`) is neither stunned
		nor used as a bridge for the arc.
	]]
	Stun = {
		Direct = 20,
		Chain = 5,
		Radius = 12,
		Hops = 1,
		MaxTargets = 4,
	},

	--[[
		The reward for being struck, for `Electric` units, in place of the stun: an
		Electric touched by the bolt (or the arc) never stops.

		`Damage` multiplies damage and `AttackSpeed` attack speed: 1.5 on both is the
		"+50% DMG / +50% SPD (WHEN STRUCK)" the indicator panel shows.
		`UnitUpgradeConfig:GetCooldown` divides the cooldown by attack speed, so 1.5
		here is a third less recharge, not half.

		Besides this, Electric already gets a passive bonus while the weather lasts,
		which lives in `Effects.Thunder.Units.Electric`; this one is the temporary
		bonus that only applies when the bolt (or the arc) touches the unit.
	]]
	Charge = {
		Damage = 1.5,
		AttackSpeed = 1.5,
		Duration = 4,
	},
}

--[[ ============================ MATCH WEATHER ============================= ]]

--[[
	Which weathers each map can roll.

	The key is the map name in `MapConfig.MAPS` (the same as the folder name in
	`ServerStorage.Maps`), and the value is the list of `Assets.Weathers` Models that
	make sense there. Snow in the desert and a sandstorm in the cave are left out not
	by a code rule, but because they are not in this list.

	A map missing from here (or with an empty list) simply has no weather: the
	per-wave roll never runs. That is the right behavior for a new map that has not
	been themed yet.
]]
WeatherConfig.MapPools = {
	Farm = { "Fog", "Wind", "Thunder", "Rain" },
	Desert = { "Sandstorm", "Drought" },
	Volcano = { "Drought", "Fog" },
	Cave = { "Fog" },
	SnowyCastle = { "Snow", "Wind", "Fog", "Rain" },
	Mountain = { "Snow", "Wind", "Fog", "Thunder", "Drought", "Rain" },
	Snowy = { "Snow", "Wind", "Fog" },
	Swamp = { "Fog", "Rain" },
	Beach = { "Wind", "Rain", "Thunder", "Drought" },
	["Pale Garden"] = { "Fog", "Rain", "Sandstorm", "Snow", "Thunder", "Wind" },
}

--[[
	The pace of weather within a match.

	On every wave start, `WeatherRoundService` rolls a die. If it passes, it does not
	turn the weather on right away: it **announces** it, and the weather arrives
	`LeadWaves` waves later. The three waves of notice are the whole point of the
	system: the player sees the warning, knows what is coming, and has time to
	rearrange placement.

	`Duration` is how many waves the weather stays on after it arrives. It leaves on
	its own at the start of the wave after the last: with 4, a weather that arrives on
	wave 10 lasts from 10 to 13 and is gone on 14.

	`Chance` is only the floor: the difficulty preset's `WeatherChance`
	(`ServerScriptService.Config.Difficulty`) rules, rising from Easy to Nightmare.
	This value covers presets without the field.

	While a weather is scheduled or active, the die is not rolled again: two weathers
	never run at the same time, and a warning on top of another would only confuse.
]]
WeatherConfig.Round = {
	LeadWaves = 3,
	Duration = 4,
	Chance = 0.15,
	TransitionTime = 3,
}

--[[
	The weather warning's sentence.

	`Text` takes the weather name and how many waves remain; `TextOne` exists only to
	avoid writing "1 ROUNDS". `DisplayNames` is for when the Model name is not the
	name the player should read.

	The label itself and the animation are not here: they belong to `WarningConfig`,
	which weather shares with the other screen warnings (today, the server restart).
]]
WeatherConfig.Warning = {
	Text = "WARNING! %s COMING IN %d ROUNDS",
	TextOne = "WARNING! %s COMING NEXT ROUND",

	--[[
		The code's `Snow` is the game's "BLIZZARD", and that is the name the player reads
		in the warning and in the indicator panel. The Model name stays: renaming it
		would drag along every map's pool, the `weather` command, and the effect tables,
		just so the player reads the word they already read.
	]]
	DisplayNames = {
		Snow = "BLIZZARD",
	},
}

--[=[
	The HUD weather indicator: the corner button and the panel it opens.

	They are two **sibling** pieces in `Interface`, not one inside the other:

		Interface
		├── WeatherButton        (ImageButton: the weather icon, and the toggle)
		│   └── New              (optional: the "open this" badge)
		└── IndicatorWeather     (the panel, with a UIScale)
			├── WeatherImg       (ImageLabel: the same icon as the button)
			├── WeatherName      (TextLabel: the weather name)
			├── Duration         (TextLabel: "WEATHER ENDS IN 3 WAVES")
			└── Container        (UIListLayout: one line per effect)

	The button is a **toggle**: press it and the panel grows in through its
	`UIScale`, press again and it shrinks out. We count no reading time: the player
	closes it when done reading.

	**With no active weather there is no indicator**: the button hides and the panel
	closes, even if open. "Clear sky" is not worth occupying a corner of the screen;
	the indicator exists for waves where there is something to read.

	**The new badge.** A player who has not opened the panel this match does not
	know the button opens anything, so `New` (the button's optional child) lights up
	with it and **insists**: it appears on every storm until the panel is opened once.
	Once opened, it retires for the rest of the match; the next match starts without
	that memory, and the badge returns on its first weather.

	The `Container` lines are written by `RichTextController`, one after another (see
	`Line.Stagger`), and the color inside them is automatic: a number takes the color
	of what it does to the player, and a unit type takes the type's color. See
	`Colors` and `Details`.

	See docs/game/weather-in-match.md.
]=]
WeatherConfig.Indicator = {
	--[[
		The names in the tree, starting from `PlayerGui`.

		`Line` is the **optional template** for a line: when it exists inside
		`Container`, it is cloned once per effect and never shown itself, and the
		designer's size and margins come from it. When it does not exist, the
		controller creates a Frame `Line.HeightScale` of the `Container`'s height.

		Typography does **not** come from the template in either case: it belongs to
		`Text` below, because the rich text renderer draws the letters, not the
		TextLabel.
	]]
	Gui = {
		Screen = "Interface",
		Frame = "IndicatorWeather",
		Button = "WeatherButton",

		--[[
			The new badge **inside** the button, and it is optional: without it, the
			indicator works the same and nothing announces anything.
			`WeatherIndicatorController:refreshButton` lights and clears it.
		]]
		New = "New",
		Image = "WeatherImg",
		Name = "WeatherName",
		Duration = "Duration",
		Container = "Container",
		Line = "Line",
	},

	--[[
		Each weather's icon, on the button and on the panel.

		The key is the weather name as the rest of the game writes it (the Model in
		`Assets.Weathers`, `WeatherConfig.Effects`), not the display name: the art's
		"blizzard" is the code's `Snow`; see `Warning.DisplayNames`.

		There is no "no weather" icon on purpose: with no weather, the button hides.
	]]
	Icons = {
		Rain = "rbxassetid://137668421407555",
		Wind = "rbxassetid://131735996975678",
		Thunder = "rbxassetid://111534699707977",
		Sandstorm = "rbxassetid://112048992160649",
		Snow = "rbxassetid://138661703410675",
		Fog = "rbxassetid://86004956830955",
		Drought = "rbxassetid://128162722232087",
	},

	--[=[
		The panel's entrance and exit, written to its `UIScale`.

		The `UIScale` is the authored one when it exists; without it the controller
		creates one. The animation is scale, not position, precisely for this: it works
		in whatever corner the panel is anchored to, without the controller needing to
		know where it should come from.

		The entrance overshoots and returns (`Back`) and the exit does not (`Quad`): the
		same overshoot on the way out would make the panel look like it bounced out
		instead of being closed. The exit is also shorter: closing answers a click, and
		a click waiting on an animation feels like a freeze.

		`Open` is the **fallback** resting scale: the authored scale on the panel's
		`UIScale` rules, read before the animation writes to it. A panel designed at 0.8
		opens at 0.8 and does not puff up to 1 because the controller assumed 1 was the
		right size. This value covers a `UIScale` that starts at zero and one the
		controller creates.

		**The effect list is not written during the entrance**, and that is part of
		this animation's contract: rich text sizes itself by the box size at the moment
		it was written, and a box measured mid-growth gives a giant line, or no line at
		all when it measures zero. Anyone replacing this animation must keep that; see
		`writeLinesWhenSettled` in the controller.
	]=]
	Scale = {
		Open = 1,
		Closed = 0,
		OpenInfo = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		CloseInfo = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	},

	--[=[
		How much the panel grows with the screen.

		The panel's size is the designer's, and what is drawn is in pixels: the same
		panel on a 1080 screen and a 1440 one takes the same number of pixels, so it
		**looks smaller** on the larger one, which has more pixels for the same field of
		view. The text, which comes from the measured box (see `Line.Fit`), shrinks in
		the same proportion.

		The fix is a factor on the `UIScale`'s resting scale:

			factor = clamp(screenHeight / ReferenceHeight, Min, Max)

		Everything inside the panel grows together: the art, the icon, the labels, and
		the line text, which is measured from the box after the factor is applied.

		`Min = 1` is what keeps mobile in place: a screen smaller than the reference
		**does not shrink** the panel, because there it already takes the right share of
		the screen and shrinking would make it unreadable. `Max` exists because the
		factor cannot grow forever: on a 4K screen the panel would double and start
		competing with the game.

		`ReferenceHeight` is the screen **height** the panel was designed at, in pixels:
		1080 for a 1080p monitor, not 1920, which is its width. It is the easy mistake
		here, and it is silent: a reference that is too large pushes the factor below 1
		on every screen, `Min` pins it at 1, and both numbers stop having any effect.

		The right value is the screen height at which the panel **is already the size
		you want**. If mobile looks right and the monitor looks small, the reference is
		the mobile height: the panel grows from there up. The controller's Studio debug
		log shows each screen's height and the resulting factor, which is how to find
		both numbers instead of guessing.

		The **button** is left out of this math on purpose: its `UIScale` is where
		`UILibraryController`'s `AnimatedButton` writes hover and press, and two owners
		of the same property would give a button that returns from hover at the wrong
		size. A button that needs to grow with the screen grows through its `Size`, in
		Studio.
	]=]
	Responsive = {
		ReferenceHeight = 720,

		--[[
			**Currently off** (`Min` and `Max` equal to 1): the panel is the right size
			on every screen, and what was small was the text inside it, which has its
			own math in `Line`. This stays as the knob for the day the panel itself is
			wrong: `Max = 1.5` lets it grow up to one and a half times the reference.
		]]
		Min = 1,
		Max = 1,
	},

	--[=[
		The `Container` lines.

		`Height` is a line's height in pixels, and applies only to the Frame the
		controller creates when there is no template in Studio; with a template, the
		height is the template's. The spacing between lines belongs to the
		`UIListLayout`, which is the designer's in both cases.

		`Stagger` is the delay between the start of one line and the next. It is short
		on purpose: the whole list must be written in under a second, or a player who
		opened the panel to check a number ends up waiting on the animation instead of
		reading.
	]=]
	Line = {
		Stagger = 0.06,

		--[=[
			A line's height as a **fraction of the `Container`'s height**, not in
			pixels: it applies only to the Frame the controller creates when there is no
			template in Studio, and it is a fraction because pixels are not responsive:
			22px on a monitor is a fifth of the panel, and on mobile it is half.

			0.2 gives five lines filling the box, which is today's largest weather
			(Drought and Blizzard). A two-line weather takes 40% and the rest stays
			empty, which is right: a line's height must not depend on how many lines the
			weather has, or the text would change size from weather to weather.
		]=]
		HeightScale = 0.2,

		--[=[
			How long to wait for a piece to have a **stable** on-screen size before
			writing to it anyway.

			A freshly created piece only measures after the layout pass, and writing
			before that is what made the first line come out the wrong size. Once the
			timeout runs out, the write happens and the renderer complains in the
			output: the hint that the piece has an authored zero size or a hidden parent.
		]=]
		MeasureTimeout = 1,

		--[=[
			The text size comes from the **measured box**, not from a pixel number: that
			is what makes the list look the same on a monitor and on mobile, where the
			panel has a fraction of the pixels and 12px text would take twice the
			relative space.

			`RichTextController:FitSize` does the math, and each field is explained
			there (in `RichTextConfig.Fit`). What is tuned here is specific to this list:

			  1. `MaxRows = 2` because `+50% ELEC UNIT DMG (WHEN STRUCK)` in a narrow box
			     fits on one row only with unreadable text, and on two rows with twice
			     the available width. A wide, short box still picks one row on its own,
			     because there the height is the limit;
			  2. `WidthPerChar = 1` because Press Start 2P is nearly monospaced, and
			     this is the fallback for when the real measurement fails.

			The math applies to the whole list, not per line: the controller measures
			the first piece with the **longest sentence** and the size applies to all,
			because a list with a different font size per line looks broken.

			In Studio, the `[RichTextController]` line in the output says which of the
			two walls set the size; without it, tuning this is trial and error.
		]=]
		Fit = {
			TextRatio = 1.5, --
			MaxRows = 4,
			MinTextSize = 8,
			WidthPerChar = 1,
		},

		--[[
			How long to wait for the screen to stop changing before rewriting the list
			at the new measurement (phone rotation, window drag). Without this pause, a
			drag would restart the typing animation every frame.
		]]
		ResizeDebounce = 0.2,
	},

	--[=[
		How the lines are written. It goes whole to `RichTextController`, so any of its
		options fits here.

		**`Size` is not here on purpose**: the text size is measured from the box on
		every write (see `Line.Fit`), and a fixed number here would be the same pixel
		size on a monitor and on mobile. To make text larger or smaller, change the
		proportion, not this.

		**Neither is `Fit`**, for the usual reason: turned on here, each line would
		measure itself by its own sentence and the list would come out with a
		different font size per line. The controller calls `FitSize` once, with
		`Line.Fit`, and passes the resulting size to all of them.
	]=]
	Text = {
		Font = "rbxasset://fonts/families/PressStart2P.json",
		Speed = 60,
		Anim = "slide",
		AnimDuration = 0.18,
		Align = Enum.HorizontalAlignment.Left,
		VerticalAlign = Enum.VerticalAlignment.Center,
		Stroke = { Thickness = 0.06, Color = Color3.new(0, 0, 0) },
	},

	--[=[
		The two labels at the top of the panel: the weather name and the time left.

		They are plain text, and their typography is the designer's: this controller
		only writes the sentence. What it does for responsiveness is turn on their
		`TextScaled` and **cap it at the authored size** with a
		`UITextSizeConstraint`: on a monitor the text stays at the size it was
		designed at, and on mobile it shrinks with the label instead of overflowing
		the box.

		A label that already comes from Studio with `TextScaled` on is not touched: the
		designer already settled its size, and the authored `TextSize` no longer means
		anything; using it as a cap would pin the text at a 14 nobody chose.

		`Scale = false` hands both back to whatever Studio says, for the day the art
		wants full control.
	]=]
	Labels = {
		Scale = true,
		MinTextSize = 6,
	},

	--[[
		The `Duration` line: how many waves the weather still lasts, counting the one
		in progress. `EndsOne` exists for the same reason as `Warning.TextOne`: to
		avoid writing "1 WAVES".

		A weather turned on by hand (the `weather` command) has no end, and then the
		label simply does not appear: better a panel without the line than a promise
		of an end nobody will keep.
	]]
	Ends = "WEATHER ENDS IN %d WAVES",
	EndsOne = "WEATHER ENDS IN 1 WAVE",

	--[=[
		The colors inside a line, in `r,g,b`: the format rich text's `[color=...]`
		understands.

		`Buff` and `Debuff` paint **the number**, not the line: the sentence stays in
		the label's color and only the "+40%" changes color, which is what makes the
		list readable at a glance. The number's sign picks between the two, with the
		exception that lives in `Details`' `Kind`.

		`Classes` paints the unit type word, so players find what concerns them in the
		list without reading the whole line. The key is the word as written: `ELEC`,
		not `Electric`.
	]=]
	Colors = {
		Buff = "85,170,255",
		Debuff = "255,80,80",

		Classes = {
			FIRE = "255,125,60",
			ICE = "135,220,255",
			ELEC = "255,225,95",
			MAGIC = "200,130,255",
			MELEE = "255,180,95",
			RANGED = "150,230,140",
		},
	},

	--[=[
		What each weather does, one line per effect, in the order the panel shows them.

		It summarizes `WeatherConfig.Effects`: whoever changes the numbers there changes
		the line here too, because there is no way to derive one from the other without
		throwing a multiplier table in the player's face. And not everything the weather
		does is here, on purpose: Magic's immunity to lightning, for example, is not a
		line. The panel is what the player needs to know to play the wave, not the
		weather's documentation.

		Each line is a string, or a `{ Text = ..., Kind = ... }` table when the sign is
		misleading. `Kind` is "Buff" or "Debuff" and sets the color of every number in
		the line: `+40% ENEMY HP` is a terrible "+" for the player, and painting it blue
		because the number goes up would lie about the only thing the color says. A
		number with no sign (`20s UNIT STUN`) is a debuff, which is what today's stuns are.
	]=]
	Details = {
		Rain = {
			"DISABLES FIRE UNITS",
			"-35% UNIT SPD",
			"-25% ICE UNIT COST",
		},

		Thunder = {
			"20s UNIT STUN",
			"+10% ELEC UNIT DMG",
			"+50% ELEC UNIT DMG (WHEN STRUCK)",
			"+50% ELEC UNIT SPD (WHEN STRUCK)",
		},

		Drought = {
			{ Text = "+40% ENEMY HP", Kind = "Debuff" },
			"+30% FIRE UNIT DMG",
			"+20% FIRE UNIT SPD",
			"-60% ICE UNIT DMG",
			"-60% ICE UNIT SPD",
		},

		Snow = {
			"-10s UNIT STUN",
			"-40% UNIT SPD",
			"+25% ICE UNIT DMG",
			"+25% ICE UNIT SPD",
			"MAGIC UNITS ARE IMMUNE",
		},

		Sandstorm = {
			"-30% UNIT DMG",
			"-30% UNIT SPD",
			"MAGIC UNITS ARE IMMUNE",
		},

		Wind = {
			{ Text = "+30% ENEMY SPD", Kind = "Debuff" },
			"+30% MELEE SPD",
		},

		Fog = {
			"-30% UNIT RNG",
			"-45% MAGIC RNG",
		},
	},

	-- A weather without a written list yet: better an honest line than an empty panel.
	UnknownDetails = { "NO DETAILS ON THIS ONE YET" },
}

--[[
	What the weather shows above an affected unit.

	Two things, both from the same computation: a Highlight on the model (light blue
	when the weather helps, red when it hurts) and a billboard over the head with one
	icon per changed stat.

	The art is the `Assets.UI.BuffDebuffBillboard` Attachment, and inside
	`BillboardGui.Frame` lives one ImageLabel per icon. The asset has all six:
	`BuffDamage`/`DebuffDamage`, `BuffRange`/`DebuffRange`, and
	`BuffCooldown`/`DebuffCooldown`: the three stats the billboard shows, in both
	directions. The labels all come from Studio with `Visible = true`, and the drawing
	code turns on the ones the unit is feeling and **hides the rest**; a name
	requested here that does not exist there simply does not show, with a warning in
	Studio.

	`Cost` is left out on purpose: it is not a state of the unit on the field, it is
	the price of placing a new one. The card's own number in the hotbar shows it,
	already discounted.

	`AttackSpeed` shows as **Cooldown** because that is how the player reads the
	number on the card: higher attack speed is a shorter recharge. So
	`AttackSpeed > 1` lights the cooldown *buff* icon, not the debuff one.
]]
WeatherConfig.Feedback = {
	-- An Attachment in `Assets.UI`, cloned into the unit's head.
	Asset = "BuffDebuffBillboard",

	-- Where it is attached. All current units are character models.
	HeadName = "Head",

	--[[
		The weather Highlight's name.

		It is looked up by name instead of kept in a table: that way `Destroy` on the
		unit (sale, round restart) already cleans everything, and no bookkeeping is left
		to drift from what is in the Workspace.

		A distinct name also keeps it out of the way of the other Highlights a unit
		gets: the green of selection, the yellow of stun, and the cyan of the
		lightning charge.
	]]
	HighlightName = "WeatherHighlight",

	--[[
		One line per billboard icon, in the order they appear. `Buff` is the label for
		a multiplier above 1 and `Debuff` the one below.

		**This list is not weather-only.** It is the billboard's vocabulary, and both
		things that change a unit on the field read it: weather and round cards (see
		`CardModifier` and `WeatherFeedbackController`, which combines the two). That is
		why `Income`/`HitIncome` are here even though no weather touches income: a
		weather's multiplier for a stat it does not declare is 1, and the line simply
		does not light.

		`Stats` is a **list** because one icon can stand for more than one stat: the
		unit's money comes from two numbers, the farm's income (`Income`) and what its
		damage pays (`HitIncome`), and they are a single icon over its head. The line's
		multipliers are multiplied together, so what lights is the net effect on the
		player's wallet.
	]]
	Stats = {
		{ Stats = { "Damage" }, Buff = "BuffDamage", Debuff = "DebuffDamage" },
		{ Stats = { "Range" }, Buff = "BuffRange", Debuff = "DebuffRange" },
		{ Stats = { "AttackSpeed" }, Buff = "BuffCooldown", Debuff = "DebuffCooldown" },
		{ Stats = { "Income", "HitIncome" }, Buff = "BuffEco", Debuff = "DebuffEco" },
	},

	--[[
		The icon for a **disabled** unit (`Disable`).

		It is the cooldown debuff icon, not a seventh drawing: stopping attacks is the
		extreme of what that icon already means, and the unit also gets the red
		highlight. A dedicated icon can go here once the art exists: change this line
		and nothing else.
	]]
	Disabled = "DebuffCooldown",

	Highlight = {
		Buff = Color3.fromRGB(120, 200, 255),
		Debuff = Color3.fromRGB(255, 70, 70),
		Transparency = 0.75,
	},
}

--[[
	The classes effects can see.

	Each unit's class lives in `UnitStats[name].Class`, which accepts a string or a
	list: a unit can be `{"Melee", "Fire"}` and receive both sides of the same
	weather. A unit without `Class` still works: it just falls under no per-type rule
	and only gets what the weather does to `All`.
]]
WeatherConfig.ClassList = { "Melee", "Ranged", "Magic", "Fire", "Ice", "Electric" }

--[[
	What each weather does.

	Everything here is a **multiplier**: 0.7 is "down 30%", 1.3 is "up 30%". Never an
	absolute value, so the effect is the same on a level 0 unit and a level 5 one.

	- `Units.All` applies to every unit.
	- `Units.<Class>` applies only to units with that class, and **replaces** `All`
	  for that stat. That is why Fog writes 0.55 for Magic instead of expecting 0.7
	  and 0.55 to multiply: the class number is the final number. Replacement is
	  **per stat**: Rain's Ice entry writes only `Cost`, and its attack speed still
	  comes from `All`.
	- `Immune` takes the unit out of the whole weather: no debuff, no buff, no
	  freeze, no lightning, no disabling.
	- `Disable` **turns the unit off**: it stops attacking while the weather lasts.
	  It is yes-or-no per class, not a multiplier, because there is no "attack 90%
	  less": a unit is either in combat or it is not.
	- `Mobs` affects enemies: `Speed` applies immediately (including those already
	  walking) and `Health` applies only to enemies spawned while the weather is on.

	The unit stats are `Damage`, `Range`, `AttackSpeed`, and `Cost`.

	`AttackSpeed` above 1 is a faster attack: `UnitUpgradeConfig:GetCooldown` divides
	the cooldown by it.

	`Cost` is the price of **placing** the unit, not of upgrades:
	`UnitUpgradeConfig:GetPlaceCost` applies it, the server charges it, and the card
	shows it. The unit's sell value does not change with it; see the `GetPlaceCost`
	comment.
]]
WeatherConfig.Effects = {
	--[[
		Fog: everyone sees less. Magic suffers the same cut 1.5x (30% * 1.5 = 45%),
		so its multiplier is 0.55.
	]]
	Fog = {
		Units = {
			All = { Range = 0.7 },
			Magic = { Range = 0.55 },
		},
	},

	-- Wind: pushes enemies forward and makes melee hit harder.
	Wind = {
		Mobs = { Speed = 1.3 },
		Units = {
			Melee = { AttackSpeed = 1.3 },
		},
	},

	--[[
		Drought: beefier enemies, fire at an advantage, and ice practically out of the
		fight: 60% less damage, attack speed, and range.
	]]
	Drought = {
		Mobs = { Health = 1.4 },
		Units = {
			Fire = { Damage = 1.3, AttackSpeed = 1.2 },
			Ice = { Damage = 0.4, AttackSpeed = 0.4, Range = 0.4 },
		},
	},

	--[[
		Snow (the "BLIZZARD" on screen): besides the attack speed cut, it freezes a
		random unit every so often (`SnowService` keeps the beat). Magic is unaffected
		by both.

		Ice is the only one that comes out ahead, on both ends: 25% damage and 25%
		attack speed. Since replacement is per stat, its `1.25` overrides `All`'s
		`0.6`, and the ice unit shoots faster in the blizzard instead of slower.
	]]
	Snow = {
		Immune = { Magic = true },
		Units = {
			All = { AttackSpeed = 0.6 },
			Ice = { Damage = 1.25, AttackSpeed = 1.25 },
		},
		Freeze = {
			Interval = 30,
			Duration = 10,

			--[[
				The freeze's visual, in `Assets.VFX`: the same `IcedVFX` as the
				Frostione's freeze on enemies, particles welded to the unit's body and its
				Highlight painting the whole model, for the seconds the server applied
				(`VFXController:PlayFreeze`).

				`Freeze` existing is also what tells `VFXController` this stun has its
				own visual: it does not compare the weather with "Snow", it looks for the
				`Freeze` of whatever caused the stun. A weather without `Freeze` (and the
				lightning, and the enemy gimmick) keeps only the yellow highlight, and a
				frozen unit goes without it, so the yellow does not fight the ice.
			]]
			Asset = "IcedVFX",
		},
	},

	--[[
		Thunder: the bolt stuns whoever it hits and jumps to nearby units (the numbers
		are in `WeatherConfig.Thunder.Stun`). Electric gets a passive bonus while the
		weather lasts, and when struck it is not stunned: it gets a much larger,
		temporary one (`WeatherConfig.Thunder.Charge`). Magic is not a target.
	]]
	Thunder = {
		Immune = { Magic = true },
		Units = {
			Electric = { Damage = 1.1 },
		},
	},

	--[[
		Rain: puts out fire and soaks the rest.

		`Fire` units **turn off**: not a debuff, they leave combat while it rains.
		The others attack 35% slower (0.65), and `Magic` suffers the same cut 1.5x
		(52.5%), so its multiplier is 0.475: the same rule as Fog, and the reason the
		class number is written final instead of compounded.

		`Ice` is the only one that gains anything: placing costs 25% less. It is an
		invitation to rearrange the board while it rains, not a combat buff: its
		attack speed drops like everyone else's, because `Cost` is the only stat the
		class line writes.
	]]
	Rain = {
		Disable = { Fire = true },
		Units = {
			All = { AttackSpeed = 0.65 },
			Magic = { AttackSpeed = 0.475 },
			Ice = { Cost = 0.75 },
		},
	},

	--[[
		Sandstorm: less damage, attack speed, and range for units that rely on sight.
		Magic does not, and is unaffected.
	]]
	Sandstorm = {
		Immune = { Magic = true },
		Units = {
			All = { Damage = 0.7, AttackSpeed = 0.7, Range = 0.7 },
		},
	},
}

--[[ ================================ QUERIES ================================ ]]

local UnitStats = require(script.Parent.UnitStats)

local EMPTY = table.freeze({})

--[=[
	A unit's classes, always as a list.

	Accepts `Class = "Melee"` and `Class = {"Melee", "Fire"}` because the first form
	is what is written 99% of the time and the second is what the config must support.
]=]
function WeatherConfig.GetClasses(unitName : string?) : { string }
	local stats = unitName and UnitStats[unitName]
	local class = stats and stats.Class
	if not class then
		return EMPTY
	end

	if typeof(class) == "string" then
		return { class }
	end

	return class
end

function WeatherConfig.HasClass(unitName : string?, className : string) : boolean
	for _, class in WeatherConfig.GetClasses(unitName) do
		if class == className then
			return true
		end
	end

	return false
end

function WeatherConfig.GetEffects(weatherName : string?)
	if not weatherName then return nil end
	return WeatherConfig.Effects[weatherName]
end

--[=[
	Is the unit outside this weather?

	Immunity is total: not the debuff everyone gets, not its own class's buff, not
	freeze or lightning. That is what "does not affect Magic units" means.
]=]
function WeatherConfig.IsImmune(weatherName : string?, unitName : string?) : boolean
	local effects = WeatherConfig.GetEffects(weatherName)
	local immune = effects and effects.Immune
	if not immune then return false end

	for _, class in WeatherConfig.GetClasses(unitName) do
		if immune[class] then
			return true
		end
	end

	return false
end

--[=[
	Is the unit **turned off** by this weather?

	Off is yes-or-no: it stops attacking while the weather lasts, and no multiplier
	can say that. `UnitService` enforces it by skipping the unit in the attack loop;
	the rest (range, damage, attack speed) is still computed normally and simply not
	used.

	Immunity wins: `Immune` takes the unit out of the whole weather, and "whole"
	includes not being turned off.
]=]
function WeatherConfig.IsDisabled(weatherName : string?, unitName : string?) : boolean
	local effects = WeatherConfig.GetEffects(weatherName)
	local disable = effects and effects.Disable
	if not disable then return false end

	if WeatherConfig.IsImmune(weatherName, unitName) then return false end

	for _, class in WeatherConfig.GetClasses(unitName) do
		if disable[class] then
			return true
		end
	end

	return false
end

--[=[
	The weather's multiplier for a unit stat (`Damage`, `Range`, `AttackSpeed`, or
	`Cost`). With no weather, an unknown weather, or an immune unit, returns 1.

	The precedence rule is in the `Effects` comment: the class value replaces `All`'s,
	and two classes that change the same stat multiply together.
]=]
function WeatherConfig.GetUnitMultiplier(weatherName : string?, unitName : string?, stat : string) : number
	local effects = WeatherConfig.GetEffects(weatherName)
	local units = effects and effects.Units
	if not units then return 1 end

	if WeatherConfig.IsImmune(weatherName, unitName) then return 1 end

	local multiplier = 1
	local fromClass = false

	for _, class in WeatherConfig.GetClasses(unitName) do
		local entry = units[class]
		local value = entry and entry[stat]
		if value then
			multiplier *= value
			fromClass = true
		end
	end

	if fromClass then
		return multiplier
	end

	local all = units.All
	return (all and all[stat]) or 1
end

-- The weather's multiplier for an enemy stat (`Speed` or `Health`).
function WeatherConfig.GetMobMultiplier(weatherName : string?, stat : string) : number
	local effects = WeatherConfig.GetEffects(weatherName)
	local mobs = effects and effects.Mobs
	return (mobs and mobs[stat]) or 1
end

-- The weathers a map can roll. A map without a pool returns an empty list.
function WeatherConfig.GetPool(mapName : string?) : { string }
	local pool = mapName and WeatherConfig.MapPools[mapName]
	return pool or EMPTY
end

--[[
	The name the warning shows. With no entry in `DisplayNames`, it is the Model name
	in uppercase.
]]
function WeatherConfig.GetDisplayName(weatherName : string) : string
	return WeatherConfig.Warning.DisplayNames[weatherName] or string.upper(weatherName)
end

return WeatherConfig
