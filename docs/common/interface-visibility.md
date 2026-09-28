# Interface visibility

Several features need the screen to themselves: the maps panel, the shop, the portal countdown, and cutscenes.
They overlap and end at different times, so `InterfaceController` hides ScreenGuis through **named requests** instead of a global switch.

**Runs in:** Game · Lobby (client)
**Code:** [`InterfaceController`](../../common/client/Controllers/InterfaceController.luau)

## How it works

```lua
InterfaceController:Hide("ChooseMaps", { Except = { "ChooseMaps" } })
InterfaceController:Show("ChooseMaps")
```

A ScreenGui stays disabled while **any** request hides it, and returns to what its owner wanted when the last request leaves.
"What the owner wanted" (`Desired`) is tracked live: the controller watches the `Enabled` of every GUI in `PlayerGui`, so if someone enables a hidden GUI during a request, the new value is stored and the GUI stays disabled; when the request leaves, that value comes back.
Each controller can keep changing its own GUI as usual, unaware of any request.

The controller's own writes do not count as the owner's.
The `Enabled` change signal arrives **at the end of the frame** (`SignalBehavior.Deferred`), long after a flag set around the write would be cleared, so the echo is **counted** (`entry.Pending`), one per write.

Options:

- `Except`: names of ScreenGuis the request leaves alone.
- `HideCore`: also hides the Roblox core UI (chat, player list, backpack, and top bar).

The exception is also available by **attribute**: a ScreenGui with `IgnoreInterfaceHide` is never hidden.
It exists for the portal's white flash, which is created inside the cutscene to cover the teleport.

### Who asks

- **Maps panel** (`ChooseMapsController`): asks on `Open` with itself as the exception, and releases at the start of `Close`, so the Lobby UI returns while the panel is still leaving.
  `_bindUI` also releases, so a respawn with the panel open does not leave the Lobby hidden.
- **Portal countdown** (`PortalController:_onGroupChanged`): asks as soon as the player joins a group, keeping only `ExitGroupPortal`.
  It releases when the player **leaves the group**, not when the countdown ends: at zero the cutscene takes over, and this request underneath keeps the Lobby from reappearing between the end of the scene and the teleport.
  If the teleport fails, the portal returns the group (`_abortLaunch`), which brings the interface back.
- **Cutscene** (`CutsceneController:hideInterface`): asks with no exceptions and with `HideCore`.
  It leaves with the **scene**, not the camera: even with `holdCamera`, the interface returns when the scene ends.
- **Shop**: blurs the background and stays alone in front (see [Shop](../lobby/shop.md)).

### A GUI that changes together with a request

Because the `Enabled` signal is deferred, a `Hide` or `Show` that lands in the same frame as an owner's write reapplies the old stored value over it.
Most GUIs never hit this; a GUI that changes **together** with a request always does: the portal's exit button turns on at the same moment the countdown hides the Lobby, and the maps panel disables itself 0.18 s after returning the screen.

For those cases, `SetEnabled` writes `Desired` immediately and applies it:

```lua
InterfaceController:SetEnabled(screenGui, true)
```

It does not replace writing `Enabled` directly in general; it is for code that writes near a request.
Today `PortalController` (`_setExitVisible`) and `ChooseMapsController` (both ends of the panel) use it.
A GUI the controller does not track yet gets a direct write, and the `_track` that follows reads that value as the owner's, which covers respawns (every Lobby ScreenGui is `ResetOnSpawn`).

## Usage

| Method | What it does |
| --- | --- |
| `Hide(reason, options?)` | Adds a named request |
| `Show(reason)` | Removes it |
| `IsHidden(reason?)` | Whether that request (or any request) is active |
| `SetEnabled(screenGui, enabled)` | Writes the owner's value immediately, for GUIs that change alongside a request |
