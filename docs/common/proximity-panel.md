# Proximity panel

`Shared.Util.ProximityPanel` is the shared behavior of the Lobby's walk-up panels: the crate shop, the card shop, the Robux shop, and the contracts board.
A panel opens when the player reaches a spot on the map and closes when they leave.

**Runs in:** Lobby
**Code:** [`ProximityPanel`](../../common/shared/Util/ProximityPanel.luau), used by [`ShopController`](../../Lobby/src/Controllers/ShopController.luau), [`RoundCardShopController`](../../Lobby/src/Controllers/RoundCardShopController.luau), [`RobuxShopController`](../../Lobby/src/Controllers/RobuxShopController.luau), and [`ContractController`](../../Lobby/src/Controllers/ContractController.luau)

## How it works

A panel opens with the Cascade `OpenShop` animation, blurs the background, and hides the rest of the UI through [`InterfaceController`](interface-visibility.md).
The controller only supplies the content:

```lua
self.Proximity = ProximityPanel.new({
    Name = "ContractController",
    ScreenGui = "Contracts", Wrapper = "Frame", Panel = "MainBoard",
    Animation = "OpenShop",
    HideReason = "Contracts",
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
- **Cascade is looked up the first time a panel opens**, not at the top of the module: the Game also mounts `Shared.Util` and has no Cascade runtime.

The reference points are map markers found through `Shared.Util.MarkerUtil` (see [Shop](../lobby/shop.md#shop-markers)).
