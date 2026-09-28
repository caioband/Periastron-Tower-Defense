--[[
	The highlight: darkens the whole screen except a rectangle around a GuiObject.

	The technique is the giant `UIStroke`, where the DevForum converges: a
	transparent frame with an absurdly thick `UIStroke` paints **everything
	outside** it. The frame becomes the spotlight's hole, a `UICorner` rounds the
	edge for free, and there is no image or four-part mask to keep aligned.

	`HighlightController` draws it; the numbers are here. See
	docs/common/ui-guidance.md.
]]

local HighlightConfig = {}

--[[
	The highlight screen, created in code by the controller.

	`DisplayOrder` must be above the game's screens (all at 0 today) and **below**
	any screen that should appear over the dark, such as the dialog box when a
	tutorial step explains what is highlighted. `DialogGUI` is at 0 today; to put
	it on top, raise its `DisplayOrder`, not lower this one (or the highlight goes
	behind the HUD).

	`IgnoreGuiInset` is `true` so the dark also covers the top bar strip. That
	offsets `AbsolutePosition` by 36 px, which the controller solves by measuring,
	not by compensating by hand; see `HighlightController:origin`.
]]
HighlightConfig.Gui = {
	Name = "Highlight",
	DisplayOrder = 5,
	IgnoreGuiInset = true,

	--[[
		The attribute `InterfaceController` reads to **never** hide a screen.

		Without it, the highlight disappears exactly when it is needed most: the shop
		and the proximity panels ask to hide everything else when they open, and
		"everything else" includes this screen.

		The name is the one `InterfaceController` declares; it lives here so whoever
		reads the config knows the mark exists.
	]]
	IgnoreHideAttribute = "IgnoreInterfaceHide",
}

--[=[
	The hole.

	`Padding` is the gap on each side of the target (a highlight hugging the button
	looks misaligned) and `Radius` is the `UICorner`, both **proportional to the
	target**, not fixed pixels.

	Pixels do not measure apparent size: 8 px of padding on a 200 px button on a
	monitor is a detail, and on the same button at 60 px on a phone it is a frame.
	`Fraction` is the fraction of the target's shorter side, and `Min`/`Max` are the
	floor and ceiling in pixels, so padding neither vanishes on a tiny icon nor
	becomes a frame around a whole panel.

	Passing `Padding = 16` to `:Show()` still sets exact pixels, for when the
	proportional value does not fit.

	`Thickness` is the `UIStroke` thickness in pixels: it must exceed the largest
	screen the game runs on, since it paints everything else. Ten thousand covers
	any current monitor and costs nothing; the thickness is an outline, not geometry.

	`Transparency` is how much of the game shows through the dark: 0 is solid
	black, 1 is invisible. Measured in game, 0.45 dims too lightly for a tutorial
	step; 0.35 separates without erasing the scene.
]=]
HighlightConfig.Hole = {
	Padding = { Fraction = 0.15, Min = 6, Max = 22 },
	Radius = { Fraction = 0.22, Min = 6, Max = 18 },

	Thickness = 10000,
	Color = Color3.fromRGB(0, 0, 0),
	Transparency = 0.35,
}

--[=[
	Animations.

	`FadeIn`/`FadeOut` are for the dark (the stroke's transparency). `Move` is how
	long the hole slides from one target to another when the highlight changes
	target without leaving; an instant swap would make the player lose track of
	what is being pointed at.
]=]
HighlightConfig.Tween = {
	FadeIn = 0.25,
	FadeOut = 0.2,
	Move = 0.25,

	EasingStyle = Enum.EasingStyle.Quad,
	EasingDirection = Enum.EasingDirection.Out,
}

--[=[
	Click blocking. **Off by default**, and that is the important part.

	The `UIStroke` receives no input (it is an outline, not a surface). When blocking
	is requested, four invisible `Active` frames around the hole swallow outside
	clicks and leave the middle free.

	The default is `false` because a highlight is not modal. A spotlight on a card
	should not stop the player from **turning the camera** or clicking the ground,
	which is exactly what happened when the default was `true`: the "place a unit"
	step blocked the world click it asked for.

	Ask per call with `Highlight:Show(target, { BlockInput = true })`, and only when
	the target is the **only** clickable thing in the step: a UI button, never a
	spot on the map.
]=]
HighlightConfig.BlockInput = false

--[=[
	How the highlight comes back when its target is destroyed under it.

	Almost every `ScreenGui` has `ResetOnSpawn`, so **dying erases what was pointed
	at**: the screen is recloned from `StarterGui` and the held instance is gone.
	Without this, the spotlight left and never returned, and a tutorial step kept
	asking for a click on a button nobody highlights.

	The highlight stores the target's **name path** to `PlayerGui` (see
	`HighlightController:Show`) and looks up the equivalent on the new screen.
	Names survive recloning: the authored button returns with the same one, and
	runtime clones (the hotbar card, the backpack crate) are rebuilt with it too.

	`Timeout` is how long to wait. The new screen does not arrive in the same frame:
	`ResetOnSpawn` only reclones when the new character enters. On timeout the
	highlight leaves for good, silently; whoever asked knows whether pointing still
	makes sense.

	`Interval` is the search cadence.
]=]
HighlightConfig.Rebind = {
	Timeout = 10,
	Interval = 0.2,
}

return HighlightConfig
