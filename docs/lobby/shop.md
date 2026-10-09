# Crate shop

The Lobby crate shop (`StarterGui.ShopUI.Frame`), opened at the shop counter or from the HUD, and its shopkeeper.

**Runs in:** Lobby
**Code:** [`ShopController`](../../Lobby/src/Controllers/ShopController.luau), [`ShopService`](../../Lobby/src/Services/ShopService.luau), [`ShopKeeperController`](../../Lobby/src/Controllers/ShopKeeperController.luau), [`ShopConfig`](../../common/shared/Config/SharedConfig/ShopConfig.luau), [`CrateConfig`](../../common/shared/Config/SharedConfig/CrateConfig.luau)

## How it works

### One container per crate

The panel is `ShopUI.Frame.ImageLabel`, and its `ScrollingFrame` holds **one authored container per crate**, named after the crate's `Key`: `CrateOfBeginnings`, `CrateOfNature`, `FragmentedCrate`.
Each crate has its own illustration, frame, and row color, so the controller **finds** each container by name and writes only what changes:

```text
CrateOfBeginnings          <- item.Container, the crate's Key
├── BoxArt
│   └── TextLabel          <- the DisplayName, in capitals
├── Frame
│   ├── Rarity             <- this crate's TEMPLATE (cloned once per rarity)
│   │   └── RarityTextPercentage
│   └── UIListLayout
└── Buy
    ├── UIScale            <- the button's hover and press
    ├── TextLabel          <- the Price through ShopConfig.PRICE_FORMAT: `50`
    │   └── UIStroke       <- the color of this crate's currency
    └── ImageLabel         <- this crate's currency icon
        └── UIScale        <- icon size, which changes with the currency
```

- **The rarity row is a template per crate**, not a global one: each container's `Rarity` is that crate's art.
  The bind removes the authored row (keeping a clone) and adds one row per rarity the crate can drop, ordered from most common to rarest by `RarityConfig`, not by chance (on the Legendary Crate, Epic and Legendary tie at 40%).
- **A crate without a container does not show**, with a single warning.
  Today that is the Legendary Crate: it is still in `ShopConfig`, the inventory, the drops, and unboxing, and it returns to the shop when a `LegendaryCrate` container is authored.
  A container that matches no item is hidden, not destroyed.
- Until the odds arrive, a container shows **no rows** rather than the authored placeholder numbers.

### Two currencies

| Crate | Price | Profile key in `Data.Stats` |
| --- | ---: | --- |
| Crate of Beginnings | 50 Coins | `Cash` |
| Crate of Nature | 200 Coins | `Cash` |
| Fragmented Crate | 4 Shards | `Shards` |
| Legendary Crate | 1,800 Shards (out of scale; see Known issues) | `Shards` |

Prices are set against what a **complete** run pays (`WinCash`/`WinShards` in `Config.Difficulty`): 100 coins and 1 shard on Easy, 900 coins and 5 shards on Nightmare.
A Crate of Beginnings every half run on Easy, a Fragmented Crate every run on Nightmare.
VIP players pay 20% less (see [Game passes](../common/gamepasses.md#the-price-on-screen-is-the-price-charged)).

- **The key is the profile name, not the screen name.**
  Players read "Coins" and the profile has always stored `Cash`, so `ShopConfig.ITEMS` writes `Currency = "Cash"`.
  Writing the screen word would create a ghost `Stats.Coins` the day the server charged it.
  An unknown currency falls back to `ShopConfig.DEFAULT_CURRENCY` (`Shards`) with a warning, so a typo cannot give a crate away.
- **The server charges and refunds in the item's currency**, inside the same `:Update` that checks the balance, so two quick clicks cannot spend the same money.
  A refusal for balance is `NotEnoughCurrency`.
- **`ShopController` maps currency to look** (`CURRENCY_STYLE`): shards get a blue outline (`69,92,241`) and the shard icon; coins get amber (`211,170,88`) and the coin icon.
  It lives in the controller because it is presentation, and the containers were authored when the shop had one currency.

### Odds come from the server

Odds are **server-only** (`ServerScriptService.Config.Crate`): the client asks with `RequestCrateOdds` and receives `CrateOdds`, a `{ [item Id] = { [rarity] = % } }` map already computed.
The published number is the **real** chance, including crate upgrades (`Crate.GetDisplayOdds`); see [Crates and unboxing](crates-and-unboxing.md#odds).

**Each row's outline is its rarity color** from `RarityConfig`, the same that paints the unboxing reel and the card name in the deck:

| | Common | Rare | Epic | Legendary |
| --- | --- | --- | --- | --- |
| Outline | blue `29,33,250` | green `31,230,74` | magenta `227,19,255` | amber `255,191,51` |

On top is a vertical light gradient: **the `UIStroke` `Color` carries the color and the `UIGradient` carries only light**, in gray (white on top, 0.45 at the bottom), so changing a rarity color stays one line in `RarityConfig`.
If the template already has a `UIGradient`, it is rewritten instead of adding a second one.

### Opening clears the screen and blurs the background

While the shop is open it is alone in front: the HUD, the portal button, and the rest of the Lobby leave, and the background blurs to `BlurSize` 24.

```lua
InterfaceController:Hide("Shop", { Except = { "ShopUI" } })
InterfaceController:Show("Shop")
```

See [Interface visibility](../common/interface-visibility.md).
`ShopUI` itself is enabled through `InterfaceController:SetEnabled`, because it turns on in the same instant the request sweeps the GUIs; all enabling goes through `_setShopEnabled`.
`ShopUI` also holds the card shop, the Robux shop, and the [rune shop](rune-shop.md), so each one asks the others before disabling it (see [Card shop](round-card-shop.md#sharing-shopui)).

The screen is returned at the **start** of closing, so the rest of the UI returns behind the panel.
`_bindUI` also returns it, because `ShopUI` is `ResetOnSpawn` and dying with the shop open would otherwise leave the player without a HUD.

**The blur is `Lighting.UIBlur`**, shared with dialogs, other panels, and `UILibraryController` (two `BlurEffect`s would add up).
It is created with `LightingKeep = true`, so [lighting](../common/lighting.md) changes neither remove it nor treat it as an exiting effect.
The tween time comes from the `OpenShop` animation itself (`track.Duration`), and one tween runs at a time.

### The buy button

`Buy` grows to 1.05 on hover and sinks to 0.93 while pressed, on its authored `UIScale`, with the same timing and curves as the HUD buttons.
The press is softer than the HUD's 0.9 because a wide bar would move much more.

- **The target comes from the whole state**, not the latest event: pressed beats hovered beats idle.
- Press and release use `InputBegan`/`InputEnded` filtered for `MouseButton1` **and** `Touch`, which consume nothing, so `Activated` still buys.
- `MouseLeave` also undoes the press (releasing outside never fires `InputEnded`), and a finished touch clears both states (Roblox sends `MouseEnter` on touch).
- Everything lives in `ItemMaid`, so a new `_render` disconnects events and resets the scale.

### Purchase sound

`SoundService.BuySFX` is a **folder** with one sound per currency (`Coins`, `Shards`), loose at the root of `SoundService`, next to the `SharedSounds` package, because it is Lobby-only.

- It plays on the **result** from the server, not on the click, and the currency comes from `ShopConfig` (`BUY_SOUNDS`), not the network.
- **Every purchase restarts it**: both currencies share the `ShopBuy` key, so a new purchase cuts and restarts the sound instead of stacking.
- The sound is the **first** thing done with the result; `PurchaseResult` fires afterward.
- `ShopController` calls `MusicController:PreloadSFX` in `construct` so the first click does not wait for the download.
- [`MusicController`](../common/audio.md) reads loose sounds at the root two levels deep (`_findLoose`): a loose `Sound`, or a `Sound` in a loose folder, skipping `SharedSounds`.

### Closing and the counter

The X lives in the outer `Frame`, so it is searched from the wrapper in depth.
Closing by hand does not fight proximity: the panel only reacts to **crossing** the radius.
The shard counter is **optional**: the current panel has none, and it is looked up inside the panel before the whole ScreenGui (the old hidden panel still has a `CurrentShards`).
If the panel has no `UIScale`, the controller creates one for `OpenShop`.

## The shop counter and the shopkeeper

### Shop markers

`ShopPartReference` and `ShopPartTeleport` are grouped inside `Map.Shop`, and `MarkerUtil` finds them **in depth**, so the artist can group them anywhere.

### Two radii

| Radius | Config | What happens |
| --- | --- | --- |
| 20 studs | `KEEPER_APPROACH_RADIUS` | the shopkeeper gets up (`GetUp`) and waits at the counter (`IdleBench`) |
| 5 studs | `OPEN_RADIUS` | the shop opens |

The player crosses 20 studs while walking, so the shopkeeper is **already standing** when they reach the counter.
Both radii are measured from the **same point** (`ShopController:GetReferencePosition`), so nobody reaches the counter without crossing the outer radius first.

### The HUD button

`ShopPartTeleport` is about 15 studs from `ShopPartReference`: inside the shopkeeper's radius, **outside** the shop's.
`TeleportToShop` therefore opens the panel by hand and marks the radius entry, so walking away closes it.

### The shopkeeper remembers whether you bought

`ShopKeeperController` has four states: `Idle` alone, `GetUp` when the player approaches, `IdleBench` at the counter, and a goodbye when the player leaves.
Leaving with a purchase plays `ByeBye`; leaving empty-handed plays **`ByeByeEvil`**.
The memory resets every time the player crosses the radius inward.
It learns about purchases from `ShopController.Signals.PurchaseResult`; the shop does not know the shopkeeper exists.

**Animations play on the client**: the model belongs to the server and is anchored, so each client animates its own copy and each player sees the shopkeeper serving **them**.
It has no `Humanoid`; the tracks load on the authored `AnimationController`'s `Animator`, and the previous track is stopped by hand, since nothing resolves priority.
`KEEPER_GESTURE_TIMEOUT` (10 s) moves on if a gesture never loads, and the resting poses are rechecked every tick.

## Known issues

- The Legendary Crate's price (1,800 shards) dates from when a Medium run paid 60 shards; today it would take 360 matches.
  It has no container, so nobody sees it, but it must be repriced before it returns to the shop.
