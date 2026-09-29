# Proximity panel

`Shared.Util.ProximityPanel` is the shared behavior of the Lobby's walk-up panels (the crate shop, the card shop, the Robux shop, and the contracts board) and of the [settings panel](settings.md).
A panel opens when the player reaches a spot on the map and closes when they leave; one without a spot opens only from a button.

**Runs in:** Lobby · Game (only the settings panel)
**Code:** [`ProximityPanel`](../../common/shared/Util/ProximityPanel.luau), used by [`ShopController`](../../Lobby/src/Controllers/ShopController.luau), [`RoundCardShopController`](../../Lobby/src/Controllers/RoundCardShopController.luau), [`RobuxShopController`](../../Lobby/src/Controllers/RobuxShopController.luau), [`ContractController`](../../Lobby/src/Controllers/ContractController.luau), and [`SettingsController`](../../common/client/Controllers/SettingsController.luau)

## How it works

A panel opens with the Cascade `OpenShop` animation, blurs the background, and hides the rest of the UI through [`InterfaceController`](interface-visibility.md).
The controller only supplies the content:

```lua
self.Proximity = ProximityPanel.new({
    Name = "ContractController",
    Folder = nil,                    -- only for a ScreenGui inside a folder (SharedUIs)
    ScreenGui = "Contracts", Wrapper = "Frame", Panel = "MainBoard",
    Animation = "OpenShop",
    HideReason = "Contracts",
    Except = nil,                    -- other ScreenGuis kept on screen while open
    GetReference = function() return target.Position end,
    Radius = 6,
    InterfaceController = self.Controllers.InterfaceController,
    OnBind = function(screenGui, wrapper, panel, maid) ... end, -- each new copy of the ScreenGui
    BeforeOpen = function() ... end,                            -- right before opening
    CanDisable = function() return true end,                    -- a shared ScreenGui (ShopUI)
})
self.Proximity:Start()
```

- **Only crossing the boundary acts.**
  Closing with the X while standing there does not reopen on the next tick; the panel returns when the player leaves and comes back.
  `EnterRange()` is for the HUD teleport: it marks the entry and opens, otherwise the exit would never happen.
- **The frame (`Wrapper`) comes and goes, not the ScreenGui.**
  `ShopUI` holds several shops; each one's `CanDisable` returns `false` while a neighbor is open, and closing hides only its own frame.
- **A new copy starts hidden and gives the screen back**, so dying with the panel open does not leave the player without a HUD.
- **Cascade is looked up the first time a panel binds**, after the game loads, not at the top of the module: the Game also mounts `Shared.Util` and has no Cascade runtime.
  There, a panel with an `Animation` gets a plain scale tween on its frame (`Wrapper`) instead: it grows from nothing on open and shrinks back on close.
- **`Folder`** is for a ScreenGui that is not a direct child of `PlayerGui` (`SharedUIs.SettingsGUI`). Each copy of the folder is followed, and the ScreenGui inside it.
- **`Except`** keeps other ScreenGuis on screen while the panel is open. The settings panel keeps the TopbarPlus bar, so its icon can close it again.

The reference points are map markers found through `Shared.Util.MarkerUtil` (see [Shop](../lobby/shop.md#shop-markers)).
