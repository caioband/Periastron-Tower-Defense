# Rune shop

The Lobby rune shop (`StarterGui.ShopUI.RuneShop`) sells [runes](../common/runes.md), temporary buffs paid in shards.

**Runs in:** Lobby
**Code:** [`RuneShopController`](../../Lobby/src/Controllers/RuneShopController.luau), [`RuneShopService`](../../Lobby/src/Services/RuneShopService.luau), [`RuneConfig`](../../common/shared/Config/SharedConfig/RuneConfig.luau), [`ProximityPanel`](../../common/shared/Util/ProximityPanel.luau)

## How it works

It opens by [proximity](../common/proximity-panel.md) to `Map.RunesShopPartReference` (`OPEN_RADIUS`, 5 studs), like the crate and card shops.
`RunesShopPartTeleport` is about 21 studs away, outside the radius; `RuneShopController:TeleportToShop` lands there and opens the panel by hand.
No HUD button calls it yet.

### One frame per rune

Each rune has an authored frame inside `Runes`, named after its `Id`.
The arrows step through the tiers (wrapping around), and the frame shows the selected tier:

| Piece | Text |
| --- | --- |
| `RuneDisplay.RuneType` | The rune's `DisplayName`: `SHARD` |
| `RuneDisplay.CurrentTier` | `TIER II` |
| `TextLabel` (direct child of the frame) | `+20% SHARDS GAIN (25m)` |
| `Buy.TextLabel` | `20 Shards`, or `HIGHER ACTIVE` when a higher tier of this rune is active |

The tier on screen starts at the active tier (or I) and then follows the arrows.
A lower tier than the active one cannot be bought, so its button stops taking clicks instead of waiting for the server's `LowerTier`.

The price label's `UIStroke` takes the rune's currency color from `RuneConfig.CURRENCIES`, the same as the crate shop's buttons: blue (`69,92,241`) for shards, amber (`211,170,88`) for coins.
A rune pays in shards unless its entry sets `Currency = "Cash"`.

### Active runes

`ActiveRunes` (a child of the wrapper) lists every active rune with its time left: `SHARD II · 24:13`.
The authored `RuneActiveWrapper` is the row template: cloned once per active rune and destroyed, and a single `NONE` row shows when nothing is active.

The server only writes the time left every 30 seconds, so the list counts down locally from the last `Runes` write in the replica.
A rune that reaches zero leaves the list on the spot and unblocks the lower tiers; the server drops it from the profile on its next write.
The countdown only ticks while the shop is open, and opening it catches up.

### Purchase

The click sends `RequestBuyRune(id, tier)`, and `RuneShopService:Purchase`:

1. Checks that the tier exists and that `purchaseAction` allows it against the live rune (`LowerTier` refuses before charging).
2. Charges the rune's currency inside one `Update` (`NotEnoughCurrency` when short).
3. Grants through `RuneService:Grant`, which checks the rule again inside its own write and refunds if two clicks raced.

`RunePurchaseResult(id, tier, success, result)` comes back, and a success plays the currency's sound from `SoundService.BuySFX` (`Shards` or `Coins`, key `RuneShopBuy`).
The screen itself follows the replica, not the result.
The VIP discount does not apply to runes.

### Sharing `ShopUI`

`ShopUI` holds the crate, card, Robux, and rune shops as siblings.
Each one's `CanDisable` asks the other three before disabling the ScreenGui; see [Crate shop](shop.md#opening-clears-the-screen-and-blurs-the-background).

## Configuration

`SharedConfig.RuneConfig`, besides the catalog (see [Runes](../common/runes.md#configuration)):

| Key | Default | Effect |
| --- | --- | --- |
| `Gui` | | The authored names, in one place |
| `PRICE_FORMAT` | `%s %s` | The buy button's text: price, then the currency's `Name` |
| `CURRENCIES` | Shards, Cash | Per currency: the word on the button and the label's outline color |
| `BLOCKED_TEXT` | `HIGHER ACTIVE` | The button while a higher tier is active |
| `DESCRIPTION_FORMAT` | `+%d%% %s (%s)` | The bonus line: percent, `Effect`, duration |
| `ACTIVE_FORMAT` | `%s %s · %s` | An active row: `DisplayName`, tier, time left |
| `EMPTY_TEXT` | `NONE` | The row shown with no active rune |
| `OPEN_RADIUS` | `5` | Studs from the reference marker that open the shop |

## Studio setup

```text
ShopUI.RuneShop                 <- wrapper (UIAspectRatioConstraint, Close)
├── Runes                       <- panel, animated by OpenShop
│   └── Shards                  <- one frame per rune, named after its Id
│       ├── RuneDisplay
│       │   ├── Previous / Next
│       │   ├── RuneType
│       │   └── CurrentTier
│       ├── Buy
│       │   └── TextLabel
│       └── TextLabel           <- the bonus line
├── ActiveRunes                 <- ScrollingFrame with a UIListLayout
│   └── RuneActiveWrapper       <- row template
│       └── Rune
└── Close
```

A rune in the config without a frame is not sold, with a Studio warning.
A `UIScale` inside `Buy`, `Previous`, or `Next` gives the button the shops' hover and press (`ButtonUtil`); without one the button still works.

## Known issues

- No HUD button opens the shop; it is reached only on foot.
- A failed purchase (not enough shards) shows nothing on screen; `PurchaseResult` carries the reason for whoever wants to show it.
