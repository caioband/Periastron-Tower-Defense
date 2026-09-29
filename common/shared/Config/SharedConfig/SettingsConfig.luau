--[[
	The settings panel: `StarterGui.SharedUIs.SettingsGUI`, opened by a TopbarPlus
	icon.

	It lives in `common/` because `SharedUIs` is in every place: the panel is the
	same wherever the player is. Every setting is an on/off toggle, and nothing is
	saved yet: each place starts from `Default`. See docs/common/settings.md.
]]

local SettingsConfig = {}

--[=[
	The UI path. `Folder` is `SharedUIs`, which StarterGui copies whole to each
	player; `Wrapper` is the frame that comes and goes, and `Panel` is the art
	`OPEN_ANIMATION` animates (see `ProximityPanel`).
]=]
SettingsConfig.Gui = {
	Folder = "SharedUIs",
	ScreenGui = "SettingsGUI",
	Wrapper = "SettingsContainer",
	Panel = "Settings",
}

--[=[
	One row per setting, cloned from the authored `Template` inside `List`. The
	template leaves the screen and only serves as the source for the rows.
]=]
SettingsConfig.Row = {
	List = "SettingsText",
	Template = "Setting1",

	-- The setting's name, the toggle, and the ON/OFF text inside the toggle.
	Label = "Settings",
	Button = "ImageButton",
	State = "ONOFF",
}

-- The toggle's art and text per state. `ON` is the image authored on the template.
SettingsConfig.ON_IMAGE = "rbxassetid://133953929547050"
SettingsConfig.OFF_IMAGE = "rbxassetid://78857377895866"
SettingsConfig.ON_TEXT = "ON"
SettingsConfig.OFF_TEXT = "OFF"

--[=[
	What changes only in the OFF state: the toggle's `HoverImage` and the color of the
	`UIStroke` on the ON/OFF text. The ON state is whatever the template carries
	(today a dark green stroke and hover `93496915708525`), read from each row when it
	is created.
]=]
SettingsConfig.OFF_HOVER_IMAGE = "rbxassetid://71757769910774"
SettingsConfig.OFF_STROKE_COLOR = Color3.fromRGB(140, 20, 20)

-- The toggle's click: the same pop as the match speed button (`SpeedController`).
SettingsConfig.PRESS_SCALE = 0.9
SettingsConfig.CLICK_SOUND = "UIClick"

-- The Cascade animation where the place has it (the Lobby). Elsewhere
-- `ProximityPanel` grows the frame with a plain scale tween instead.
SettingsConfig.OPEN_ANIMATION = "OpenShop"

--[=[
	The TopbarPlus icon. Text only until it gets art. `Order` puts it right after
	Satchel's Inventory icon, which is `-1`.
]=]
SettingsConfig.Icon = {
	Name = "Settings",
	Label = "Settings",
	Order = 0,
}

--[=[
	The TopbarPlus ScreenGuis, kept on screen while the panel is open: the rest of
	the UI goes away, but the icon has to stay so it can close the panel again.
]=]
SettingsConfig.KEEP_ON_SCREEN = { "TopbarStandard", "TopbarCentered" }

--[=[
	The settings, in the order they appear on the panel.

	- `Key`: what code asks `SettingsController:Get` for.
	- `Label`: the text on the row.
	- `Default`: the state each place starts in.
	- `Requires`: a controller that only exists in some places. Without it in this
	  place the row does not appear: there is nothing there for it to turn off
	  (`VFXController` and `MobController` only exist in the Game).

	Who reads each one:

	- `Music`: `MusicController:Mute`.
	- `SoundEffects`: `MusicController:SetSFXMuted`, every sound that is not music.
	- `VFX`: the decorative bursts in `VFXController`, `ProjectileController`, and
	  `TripmineController`. What tells the player something stays (status
	  highlights, the meteor, the Archmage's line, weather bolts).
	- `Shadows`: `Lighting.GlobalShadows`, through `LightingController`.
	- `PostEffects`: the `POST_EFFECT_CLASSES` below, through `LightingController`.
	- `WeatherEffects`: the weather particles, through `WeatherController`.
	- `DamageNumbers`: the numbers over enemies, in `MobController`.
]=]
SettingsConfig.List = {
	{ Key = "Music", Label = "Music", Default = true },
	{ Key = "SoundEffects", Label = "Sound Effects", Default = true },
	{ Key = "VFX", Label = "VFX", Default = true, Requires = "VFXController" },
	{ Key = "Shadows", Label = "Shadows", Default = true },
	{ Key = "PostEffects", Label = "Post Effects", Default = true },
	{ Key = "WeatherEffects", Label = "Weather Effects", Default = true },
	{ Key = "DamageNumbers", Label = "Damage Numbers", Default = true, Requires = "MobController" },
}

--[=[
	The Lighting effects `PostEffects` turns off. `ColorCorrectionEffect` and
	`Atmosphere` stay: they are the map's look, not a cost. `BlurEffect` stays too:
	it is the panels' `UIBlur`.
]=]
SettingsConfig.POST_EFFECT_CLASSES = { "BloomEffect", "SunRaysEffect", "DepthOfFieldEffect" }

return SettingsConfig
