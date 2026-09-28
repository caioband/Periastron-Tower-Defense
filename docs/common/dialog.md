# Dialog

The dialog box (`SharedUIs.DialogGUI.Container`) shows lines of [rich text](rich-text.md) one at a time, with up to two buttons.
`DialogController` is the only code that touches it.

**Runs in:** Game · Lobby
**Code:** [`DialogController`](../../common/client/Controllers/DialogController.luau), [`DialogService`](../../common/server/Services/DialogService.luau), [`DialogConfig`](../../common/shared/Config/SharedConfig/DialogConfig.luau)

## Usage

```lua
local Dialog = Framework:Get("DialogController")

Dialog:Play({
    "Welcome to [color=yellow]Periastron[/color].[pause=.6] Take a seat.",
    "Wave 8 brings a [shake]BLIZZARD[/shake].[event=end]",
})
```

One line at a time, advanced by click, tap, `E`, space, enter, or the gamepad's A button.
While a line is still typing, the input **shows it whole**; once it is complete, it moves to the next; on the last, it closes.
A dialog played with `Auto = true` advances by itself after `DialogConfig.AutoHold` (2.5 s).
`[event=name]` reaches subscribers of `Dialog:OnEvent()` when typing passes the mark: the hook for sound, camera, or VFX mid-sentence.

When the **server** knows a line is due (a completed contract, a special wave), it sends it with `DialogService:Send(players, lines, options)`, which reaches the controller through `DialogPlay`.
For buttons, the server only sends text and visibility; what a click does belongs to the client, because callbacks do not cross the network.

The `dialog` [admin command](admin-commands.md) plays `DialogConfig.Demo`, a fixed line that exercises typing, effects, pauses, line breaks, and `[event=]` at once.

### Buttons

`Button1` (right) and `Button2` (left) take text, appear, disappear, and call whatever the dialog asks:

```lua
Dialog:Play("Accept the contract?", {
    Buttons = {
        { Text = "ACCEPT", OnClick = function() Contracts:Accept() end },
        { Text = "NOT NOW", OnClick = function() Dialog:Close() end },
    },
})
```

Outside `:Play()`: `Dialog:SetButton(index, spec)` (`Text`, `Visible`, `OnClick`; only what is given changes), `:SetButtons`, `:ClearButtons`, and `:GetButton`, which returns the `ImageButton` for anyone who wants to change its image, animate it, or add an icon.

- **A button without `OnClick` advances the dialog.**
- **A dialog that asks for no buttons starts with none**, so choices from an old conversation never show on a new one.
- **The text goes in a `TextLabel` the controller creates inside the button** the first time it is used (the button is an `ImageButton`).
  Its look (font, color, `MaxTextSize`, padding) is in `DialogConfig.Buttons.Label`, and the index order in `DialogConfig.Buttons.Names`.

## How it works

### The screen steps aside

While the box is open, the rest of the UI hides, the background blurs, and the music ducks, each through an existing system:

| What | Through | Detail |
| --- | --- | --- |
| Hide the rest | `InterfaceController:Hide("Dialog")` | the same request the cutscene, maps panel, and portal countdown use (see [Interface visibility](interface-visibility.md)) |
| Blur the background | `LightingUtil.TweenUIBlur` | the shared `UIBlur` (the shop's and the proximity panels'), tweened in and out |
| Duck the sound | `MusicController:Duck` | lowers the music without touching the player's volume; SFX stay as they are |

Defaults are in `DialogConfig.Background`, and each can be turned off per dialog: `Dialog:Play(text, { Blur = false, Duck = false, HideUI = false })`.

- **Nobody hides `DialogGUI`, not even the cutscene**: it lives inside the `SharedUIs` folder, and `InterfaceController` only tracks **direct** children of `PlayerGui`.
  The dialog's request still passes its own name in `Except`, in case the screen ever moves out of the folder.
- **The background is applied by difference**: a new dialog starting over another does not drop the blur to zero and raise it again.

### Dying mid-dialog

`DialogGUI` has `ResetOnSpawn`, so the box is destroyed with the screen and a new, empty one arrives.
The controller keeps what was left to say (from the current `Index` on, not the whole dialog) with the same options, restores the background at once, and rewrites into the new box when it arrives (`DialogConfig.Respawn`).
`IsResuming()` tells "the dialog ended" apart from "the dialog is coming back".
The controller also listens to the container's `Destroying` and restores what the dead screen had taken (blur, UI, and music).

If the new box does not show up in time, the dialog is considered lost and **whoever waits on `:OnClosed()` is notified**; otherwise a tutorial step waiting for it would wait forever.

## Studio setup

- The box lives in the place, not in git: `StarterGui` is not synced by Rojo.
  Its path is configured by name in `DialogConfig.Gui` and resolved late, so renaming a frame in Studio is a config change, not a runtime error.
- **`Size` is the line height in pixels, in the box at the size it had when the text entered.**
  The renderer keeps that size as the reference and rescales with the screen.
  In today's `DialogGUI` (625×287), `Dialogue` uses 24; 38 already overflows the box and breaks words.
