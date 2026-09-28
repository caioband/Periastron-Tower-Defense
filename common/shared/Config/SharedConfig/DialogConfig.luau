--[[
	The dialog box: `StarterGui.SharedUIs.DialogGUI.Container`.

	`DialogController` writes to it and `RichTextController` draws the text, so a
	dialog line accepts the usual markup:

		"Welcome to [color=yellow]Periastron[/color].[pause=.6] Take a seat."

	`Gui` is a path by name instead of a `WaitForChild` written in the controller:
	the screen lives in the place (Rojo does not sync `StarterGui`), and renaming a
	frame in Studio must be one line here, not a runtime error.

	It lives in `common/` because both places have `SharedUIs`. See
	docs/common/dialog.md.
]]

local DialogConfig = {}

--[[
	Where the box lives inside `PlayerGui`. `Folder` is `SharedUIs`, which
	StarterGui copies whole to each player.
]]
DialogConfig.Gui = {
	Folder = "SharedUIs",
	Screen = "DialogGUI",
	Container = "Container",
}

--[[
	The options passed to `RichTextController` for every line. A `:Play()` caller
	can override them (the preset, the pace, the font).
]]
DialogConfig.Text = {
	Preset = "Dialogue",
}

--[=[
	What happens **behind** the dialog while it is on screen.

	All three are requests to systems that already exist:

	  - `HideOtherUIs` uses `InterfaceController`, the same "hide everything else" as
	    the maps panel, the portal countdown, and the cutscene. `HideReason` is the
	    request name; a `Show` with that name undoes it.
	  - `Blur` uses the shared `UIBlur` (`LightingUtil`), the same blur as the shop
	    and proximity panels. One in Lighting: two `BlurEffect`s would add up.
	  - `Duck` uses `MusicController:Duck`, which lowers music without touching the
	    player's volume. Music only: SFX stay as they are, or the dialog's own typing
	    sound would be muffled too.

	Each can be turned off per dialog (`Blur = false` in `:Play()`); these are the
	defaults.

	> The blur is shared on purpose, at a cost: a dialog that closes while a blurred
	> panel is open takes that panel's blur with it. In practice it does not happen,
	> because the dialog hides other panels, but know it before turning off
	> `HideOtherUIs`.
]=]
DialogConfig.Background = {
	HideOtherUIs = true,
	HideReason = "Dialog",

	Blur = {
		Enabled = true,

		-- The same 24 as `ProximityPanel`: two different blurs for the same "panel in
		-- front" look would only make the screen flicker between them.
		Size = 24,

		TweenIn = 0.35,
		TweenOut = 0.25,
		EasingStyle = Enum.EasingStyle.Quad,
		EasingDirection = Enum.EasingDirection.Out,
	},

	Duck = {
		Enabled = true,

		-- A quarter of the volume: the music does not vanish (a dialog is not a cutscene),
		-- it just steps out of the way of what is being said.
		Scale = 0.25,

		FadeIn = 0.4,
		FadeOut = 0.8,
	},
}

--[[
	The two buttons the designer left inside `Container`.

	`Names` is the order code uses: `Dialog:SetButton(1, ...)` changes the first
	name in the list. On today's screen `Button1` is on the **right** and `Button2`
	on the **left**; the position belongs to the designer, and swapping the order
	here flips that without touching callers.

	The text goes in a TextLabel the controller creates inside the button the first
	time it is used: the button is an ImageButton with no text of its own, and the
	alternative would be remembering to author a label in every new button.
	`Label` is that label's look; `MaxTextSize` exists because `TextScaled` on a
	169x61 button would turn "OK" into poster lettering.
]]
DialogConfig.Buttons = {
	Names = { "Button1", "Button2" },

	Label = {
		Name = "Label",
		Font = Enum.Font.GothamBold,
		Color = Color3.fromRGB(255, 255, 255),
		MaxTextSize = 26,
		Padding = 10,
	},
}

--[[
	How the player advances the dialog.

	Click, tap, `E`, space, enter, and the gamepad's A: a dialog is an interruption,
	and trying to leave it with the wrong key is cheap frustration to avoid.

	`Debounce` exists because the click that finishes typing a line would arrive
	milliseconds later to skip the next one: without it, one click would close the
	whole conversation.
]]
DialogConfig.Advance = {
	Keys = {
		Enum.KeyCode.E,
		Enum.KeyCode.Space,
		Enum.KeyCode.Return,
		Enum.KeyCode.ButtonA,
	},

	Mouse = true,
	Touch = true,
	Debounce = 0.2,
}

--[[
	Automatic dialog (`Auto = true` in `:Play()`), which nobody needs to advance:
	how many seconds a line stays after it finishes typing.
]]
DialogConfig.AutoHold = 2.5

--[=[
	How the dialog comes back after the player dies in the middle of it.

	`DialogGUI` has `ResetOnSpawn`: dying with the box open **destroys the box**, and
	the new screen comes empty. The dialog cannot just vanish: a player who dies mid
	tutorial instruction would lose the instruction, with the step still open on the
	server and nothing on screen saying what to do.

	So it comes back from the line it was on (see `DialogController:Play`). What is
	left in `Lines` from `Index` on is rewritten into the new box with the same
	options (background, buttons, automatic mode).

	`Timeout` is how long to wait for the new box. On timeout the dialog is
	considered lost and whoever waits on `:OnClosed()` **is notified**, so a
	tutorial step never waits forever for a dialog that will not return.

	`Interval` is the wait's cadence: a player respawning, not an animation.
]=]
DialogConfig.Respawn = {
	Timeout = 10,
	Interval = 0.2,
}

--[[
	The text of the Cmdr `dialog` command.

	It is fixed on purpose: it shows, on a real screen, the typewriter, color, a
	pause mid-sentence, wiggle, shake, and `[event=]` reaching `OnEvent`, all at
	once. Each entry is one line of the conversation.

	The second line starts with three dots separated by `[pause=0.3]`: an ellipsis
	appearing at the pace of someone hesitating, which also shows that a pause works
	mid-word, not only between sentences.
]]
--[=[
	The buttons the `dialog` command lights along with the test line.

	Text only: a callback cannot cross the network (it is a function), so in the
	demo both act as "continue", which is what a button without a callback does. A
	button with its own behavior is set up on the client with `Dialog:SetButton`.
]=]
DialogConfig.DemoButtons = {
	{ Text = "YES" },
	{ Text = "NO" },
}

DialogConfig.Demo = {
	"[color=white]Caio is [/color][color=green]a good developer[/color][pause=0.8][color=white] and a [/color][color=blue][wiggle]chill guy[/wiggle][/color]",
	".[pause=0.3].[pause=0.3].[pause=0.3] [color=red][shake]RIGHT?[/shake][/color][event=fim]",
}

return DialogConfig
