# Controls

Shared input pieces: `PointerUtil`, which puts mouse and touch behind one API, and `MobileButtons`, the thumb button cluster around the jump button.

**Runs in:** Game · Lobby (client)
**Code:** [`PointerUtil`](../../common/shared/Util/PointerUtil.luau), [`MovementController`](../../common/client/Controllers/MovementController/init.luau), [`MobileButtons`](../../common/client/Controllers/MovementController/Components/MobileButtons.luau), [`UILibraryController`](../../Game/src/Controllers/UILibraryController/init.luau)

## `PointerUtil`

`UserInputService:GetMouseLocation()` and `Enum.UserInputType.MouseButton1` do nothing useful on a phone: there is no mouse, and a touch arrives as `Enum.UserInputType.Touch`.
`PointerUtil` hides the difference:

| | PC | Touch |
| --- | --- | --- |
| `getScreenPosition()` | the cursor now | the last touched point (`nil` before the first touch) |
| `onPointerAction(cb)` | left button down | a short, still tap (≤ 20 px, ≤ 0.6 s) |
| `isTouchOnly()` | `false` | `true` |

The movement limit separates **pointing** from **turning the camera**: on a phone, dragging is how the player looks around, and a drag must not become a click in the world.
A PC with a touchscreen still counts as a PC.

### Screen and viewport coordinates

`InputObject.Position` is in GUI space, which starts below the Roblox top bar.
`Camera:ViewportPointToRay` counts from the top of the window, because the 3D view is drawn behind the bar too.
The difference is the GUI inset (about 36 px vertically), and it was all that separated a tap from its target.

Instead of adding 36 by hand (the value changes with the bar hidden, in full screen, and between devices), `PointerUtil` **measures** it: a zero-size frame in a `ScreenGui` with `IgnoreGuiInset` sits at the top corner of the whole window, and its `AbsolutePosition` is the origin of ray space.
The conversion is public (`PointerUtil.toViewportPoint`) for code that listens to raw touches through `ContextActionService`, as [unit placement](../game/unit-placement.md) does.

## `MobileButtons`

The dark circles with white borders around the jump button (`DASH`, `RUN`, `ROTATE`, and `LOCK`) are **one cluster**.

**Everything is derived from the Roblox jump button:** size is a fraction of it and position is measured from its center, so when the engine grows the jump button on a bigger screen, the cluster grows and spreads with it.
Without a jump button on screen (PC, gamepad, or hidden), the whole cluster goes away.

**Slots are contested, not fixed.**
There are six around the jump button (`Left`, `Up`, `Diagonal`, `FarLeft`, `FarUp`, `LeftUp`).
A slot is free if `GetGuiObjectsAtPosition` finds nothing on a grid of points there, so it works for any UI in either place, including future ones, with no list of names to maintain.
A panel that opens over a slot pushes the button to the next one.

Assignment is a **depth-first search, not greedy**.
The first slot in `DASH`'s list may be the only one that fits `RUN`, and a greedy loop would take it and leave `RUN` off screen.
Each level also has a branch that skips that button, which allows a partial solution when not all fit.
The first solution with the most buttons wins, which respects each button's priority and slot order.

Any controller can join the cluster:

```lua
local mobileButtons = Framework:Get("MobileButtons")

mobileButtons:register("Lock", {
    Text = "LOCK",
    Priority = 4,
    Slots = { "LeftUp", "FarLeft", "FarUp", "Diagonal", "Left", "Up" },
    OnActivate = function() ... end,
})
mobileButtons:setActive("Lock", true) -- the amber "on" highlight, like RUN
mobileButtons:unregister("Lock")
```

It is reachable with `Framework:Get` because the [`Me` framework](../architecture/me-framework.md) registers **every** ModuleScript under `Controllers`, not only controllers.

Lifecycle details:

- **The layout loop belongs to the cluster**, not to whoever registered: it starts with the first registration and stops with the last.
  It re-measures the screen every 0.25 s (`CHECK_INTERVAL`), which is how a button escapes a panel that opened over it.
- **`MovementController:stop()` unregisters only `DASH` and `RUN`**, the buttons that depend on the character.
  A respawn during placement must not take `ROTATE` away.
- The button count is part of the layout cache key, so registering a button mid-match redistributes the cluster even if the screen size did not change.

## Touch pitfalls in UI code

- **`MouseButton1Up` is not a click.**
  If the finger slides off the button before lifting, `Up` never arrives: the action is lost and the press animation sticks.
  Actions fire from `Activated` (`UILibraryController.addClickAnimation`, and sell and upgrade in `ToggleTower`), and the visual release is watched through `UserInputService.InputEnded`, which sees the finger leave anywhere.
- **Hover does not exist on touch.**
  `MouseEnter` sometimes fires without its `MouseLeave`, leaving the button enlarged forever, so `addHoverAnimation` does nothing on touch devices.
  `MobController:startHoverLoop` also stays off, since without a mouse it would raycast every 0.05 s and never find an enemy.
