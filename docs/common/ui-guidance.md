# UI guidance: highlight and arrow

Two tools for pointing the player at something: `HighlightController` darkens the screen except around a GUI element, and `ArrowController` places a bobbing arrow over a point in the world.
The tutorial uses both.

**Runs in:** Game · Lobby
**Code:** [`HighlightController`](../../common/client/Controllers/HighlightController.luau), [`HighlightService`](../../common/server/Services/HighlightService.luau), [`ArrowController`](../../common/client/Controllers/ArrowController.luau), [`ArrowService`](../../common/server/Services/ArrowService.luau), [`HighlightConfig`](../../common/shared/Config/SharedConfig/HighlightConfig.luau), [`IndicatorArrowConfig`](../../common/shared/Config/SharedConfig/IndicatorArrowConfig.luau)

## Highlight

The screen darkens except for a rectangle around a `GuiObject`: a tutorial step's spotlight.

```lua
local Highlight = Framework:Get("HighlightController")

Highlight:Show(shopButton)
Highlight:Show(deckButton, { Padding = 16 })   -- slides over from the previous target
Highlight:Hide()
```

Other methods: `IsShown()`, `GetTarget()`, and `Find(path)`, which resolves a name path from `PlayerGui`.

### How the highlight works

**The technique is a giant `UIStroke`**: a transparent frame with a 10,000-pixel `UIStroke` paints everything **outside** it.
The frame is the hole, the stroke is the dark, and a `UICorner` rounds it: one instance, no image, no four-part mask to keep aligned.

**Clicks are a separate matter, and by default the highlight stays out of them.**
A stroke receives no input.
Blocking (four `Active` frames around the hole) only applies when the caller asks: `Show(target, { BlockInput = true })`.
The default is **not** to block (`HighlightConfig.BlockInput = false`): a blocking highlight on the "place a unit" step swallowed the world click it asked for, and the camera drag with it.
Block only when the target is the only clickable thing in the step, which means a UI button and never a spot on the map.

**Alignment is measured, not computed.**
`AbsolutePosition` lives in a space that includes the top bar inset: in a `ScreenGui` with `IgnoreGuiInset = true` (this one, so the dark covers the top strip), the top-left corner reports `(0, -36)`.
This is [intended by Roblox for compatibility](https://devforum.roblox.com/t/gui-absoluteposition-doesnt-respect-ignoreguiinset/1168583).
`GuiService:GetGuiInset()` [returns zero during the first frames after boot](https://devforum.roblox.com/t/guiservicegetguiinset-returns-0000-at-first/3472295), exactly when a tutorial runs, so the controller keeps a zero-size probe frame at its own screen's origin and reads its position.
The difference between probe and target is the answer, with or without inset, on any device.

**No hardcoded pixels.**
Position and size are copied from the target; padding and corner radius are **fractions of the target's shorter side**, with a floor and a ceiling (`HighlightConfig.Hole`).
In practice: 6 px on a 40 px icon, 9 px on a 169×61 HUD button, 22 px on a 600×300 panel.

**A target inside something that clips** (a `ScrollingFrame`) has its rectangle **clipped too**, ancestor by ancestor.
Scrolled out of view, the highlight **suspends** and comes back when the player scrolls back.

**A target destroyed by a respawn comes back by itself.**
Almost every ScreenGui has `ResetOnSpawn` (in the Lobby, all of them), so dying reclones the screen and the old instance is gone.
`Show` stores the target's **name path** to `PlayerGui`, and on losing it the highlight looks up the same path in the new screen (`HighlightConfig.Rebind`).
While searching it is **suspended**, not cleared, and a target not yet visible does not count as giving up (the Ready button and the backpack crate appear that way).
When the deadline passes it clears silently: whoever asked knows whether a step still needs that button.

**It follows the target by signal, not by frame**: it reacts to `AbsolutePosition`, `AbsoluteSize`, and `ViewportSize`.
A destroyed, invisible, or detached target clears the highlight.

The highlight's `DisplayOrder` is 5 (`HighlightConfig.Gui`), above the game's screens at 0.
A screen that must appear **above** the dark (the dialog explaining what is highlighted) raises its own `DisplayOrder`; lowering the highlight's would send it behind the HUD.

The server asks through `HighlightService:Show(players, path, options)` with a **name path** from `PlayerGui` (`"HUD.HUDLeft.Shop"`), the only way to refer to a screen that exists only on the client.
The `highlight` [admin command](admin-commands.md) uses it.

### Known limitations

A **rotated** target is not supported: `AbsolutePosition` and `AbsoluteSize` describe the unrotated box, and the `UIStroke` does not cut diagonally.
No UI in the game is rotated today.

## Indicator arrow

Points at a world position with `Shared.Assets.VFX.IndicatorArrow`: the arrow floats above the target, spinning and bobbing.

```lua
local Arrow = Framework:Get("ArrowController")

local arrow = Arrow:Point(unit.Position)
arrow:MoveTo(otherPosition)
arrow:Destroy()

Arrow:ClearAll()
```

An arrow also has `GetPosition()` and `IsAlive()`; the controller has `Count()`.

### How the arrow works

- **`Height` is the gap between the tip and the target**, in studs, not the pivot height.
  The controller measures once, on the template, the distance from the pivot to the bottom tip, and uses that.
  The pivot is wherever the designer left it; setting a `PrimaryPart` tomorrow would move it, and the arrow would still point at the same place.
- **The template is checked, not trusted.**
  The model comes from Studio anchored, welded, and without collision, query, or touch; the controller rewrites those properties **once** on a template kept outside the tree.
- **One connection for every arrow**, connected with the first and disconnected with the last.
  Each arrow starts half a cycle out of phase, since two arrows bobbing in sync look like one thing blinking.
- Arrows live in their own Workspace folder (`Indicators`), **outside `Workspace.Map`**, which `MapService` swaps between matches.
- The model's `Highlight` uses `DepthMode = AlwaysOnTop`, so the arrow shows through geometry.

The numbers (height, spins per second, bob amplitude and cycles, scale) are in `SharedConfig.IndicatorArrowConfig`.
**Do not confuse it with `ArrowConfig`**, which is the Archer's projectile.

From the server, `ArrowService:Point(players, position)` sends only the `Vector3` and each client builds its own arrow; `ArrowService:Clear(players)` removes them.
The `arrow` [admin command](admin-commands.md) uses it.
