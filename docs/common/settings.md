# Settings

The settings panel (`SharedUIs.SettingsGUI`) opens from a **Settings** icon on the TopbarPlus bar, next to Satchel's Inventory.
Every setting is an on/off toggle, and **nothing is saved yet**: each place starts from the defaults, and a teleport between the Lobby and the Game resets them.

**Runs in:** Game · Lobby
**Code:** [`SettingsController`](../../common/client/Controllers/SettingsController.luau), [`SettingsConfig`](../../common/shared/Config/SharedConfig/SettingsConfig.luau)

## The settings

All of them start **on**, and each one is applied by the system that owns the effect.

| Setting | Off does | Applied by | Places |
| --- | --- | --- | --- |
| Music | Mutes the music | `MusicController:Mute` | both |
| Sound Effects | Silences every sound that is not music: UI, footsteps, weather, attacks, what the server plays | `MusicController:SetSFXMuted` | both |
| VFX | Removes decorative bursts (see below) | `VFXController`, `ProjectileController`, `TripmineController` | Game |
| Shadows | `Lighting.GlobalShadows = false` | `LightingController` | both |
| Post Effects | Turns off Bloom, SunRays, and DepthOfField | `LightingController` | both |
| Weather Effects | Stops the weather particles | `WeatherController` | both |
| Damage Numbers | Hides the numbers over enemies; the health bar still moves | `MobController` | Game |

A setting whose `Requires` controller does not exist in the place (VFX and Damage Numbers in the Lobby) has no row there.

### What VFX off keeps

The rule is: decoration goes, information stays.

- **Goes:** attack particles (`VFXController:Play`, whose sounds still play), bursts hung on a model (`EmitAttached`: round card, `MobRoot` hits), the Entrepreneur's aura money, the Electro's arc, the meteor's trail and explosion, projectile trails and impact bursts, the tripmine's explosion particles, and the particles of a status (frozen, burning, bleeding).
- **Stays:** the status Highlight, the meteor rock, the projectile shell, the Archmage's line, and the weather lightning bolts (a match event that stuns a unit).

The check happens when the effect starts: an effect already playing when the toggle changes finishes as it began.

### Shadows and post effects

`LightingController` is what writes Lighting on the client, and a transition would undo a setting that wrote on its own.
So every write goes through `_write`: a property a setting forces keeps the value it was asked for as the **truth** and gets the forced value instead.
What the server replicates on top (a new preset) is caught by a property watcher and becomes the new truth.
Turning the setting back on writes the truth back, so the preset's own value returns.

### Sound effects

`SetSFXVolume` only reaches `PlaySFX`, and most of the game's sound goes around it.
Muting puts every `Sound` under the Workspace, SoundService, and PlayerGui (except the Musics folder) into a local `SoundGroup` at volume 0, and new ones follow while the mute lasts.
Unmuting searches the same places again for whoever is in that group and gives each sound back the group it had.
It searches instead of keeping a list because a weak-keyed table of Instances loses entries while the Instance is alive (its userdata is collected when no Lua code holds it): the `PlaySFX` templates got lost that way, stayed muted, and every clone of them was born muted.

## The panel

The panel is a [proximity panel](proximity-panel.md) with no spot on the map, the same as the Robux shop: the icon calls `Open`/`Close`, and the X inside `SettingsContainer` closes it.

| Piece | Name |
| --- | --- |
| Folder | `SharedUIs` |
| ScreenGui | `SettingsGUI` |
| Frame that comes and goes (`Wrapper`) | `SettingsContainer` |
| Art (`Panel`) | `Settings` |
| Row template | `Settings.SettingsText.Setting1` |

- **Rows are clones of `Setting1`**, one per setting, in `SettingsConfig.List` order: the `Settings` label gets the name, the `ImageButton` is the toggle, and its `ONOFF` label says the state.
  The toggle shows `ON_IMAGE` (the art authored on the template) or `OFF_IMAGE`.
  OFF also swaps the `HoverImage` for `OFF_HOVER_IMAGE` and paints the `UIStroke` on `ONOFF` with `OFF_STROKE_COLOR` (red); ON returns both to what the template carries.
- **The toggle pops like the match speed button**: it sinks to `0.9` while pressed and returns with an overshoot, and `UIClick` plays.
  The value changes before the click sound, so turning sound effects off gives a silent click.
- **Animation:** the Cascade `OpenShop` in the Lobby. The Game has no Cascade, so the frame grows and shrinks with a plain scale tween instead.
- **The rest of the UI goes away** while the panel is open, except the TopbarPlus bar (`TopbarStandard`, `TopbarCentered`): the icon stays so it can close the panel again.
- **The icon and the panel always agree.** Closing with the X deselects the icon, and a click the panel cannot honor does not leave the icon selected.
- **The icon shows up with the first copy of the screen.** A place without `SettingsGUI` gets no icon.
- **Dying with the panel open** brings a new copy of `SettingsGUI` (it resets on spawn), which starts closed; the icon is deselected with it and the rows are rebuilt with the current values.

## Reading a setting from code

```lua
local Settings = Framework:Get("SettingsController")

Settings:Get("Shadows")                          -- boolean
Settings:Set("Shadows", false)
local connection = Settings:Observe("Shadows", function(enabled)
    -- called now, and on every change
end)
```

`IsOpen`, `Open`, `Close`, and `Toggle` act on the panel.

## Changing it

- **A new setting:** an entry in `SettingsConfig.List` (`Key`, `Label`, `Default`, and `Requires` when it only exists in some places), plus the code that applies it in the system that owns the effect.
- **Icon text, order:** `SettingsConfig.Icon`. `Order` is relative to Inventory, which is `-1`.
- **Toggle art and text:** `ON_IMAGE`, `OFF_IMAGE`, `ON_TEXT`, `OFF_TEXT`.
- **Which post effects turn off:** `SettingsConfig.POST_EFFECT_CLASSES`.
- **Renaming a frame in Studio:** `SettingsConfig.Gui` and `SettingsConfig.Row`.

## Known limits

- `SettingsGUI` lives inside the `SharedUIs` folder, and [`InterfaceController`](interface-visibility.md) only tracks direct children of `PlayerGui`.
  Another request to hide the UI (a cutscene, a Lobby panel opening on walk-up) does not hide the settings panel if it is already open.
- In the Lobby, `OpenShop` animates only the art (`Settings`); the X sits next to it in `SettingsContainer` and does not grow with it.
- With Shadows or Post Effects off, a preset switch that has no folder in `Assets.Lighting` (the transition is skipped) can leave the truth one preset behind if the server writes the same value that is being forced.
