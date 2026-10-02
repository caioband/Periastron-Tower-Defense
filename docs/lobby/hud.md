# HUD

The Lobby HUD (`StarterGui.HUD`): level, XP, coins, and shards in the middle, two columns of buttons at the sides, `New` badges on those buttons, plus the player list columns and the welcome badge.

**Runs in:** Lobby
**Code:** [`HUDController`](../../Lobby/src/Controllers/HUDController.luau), [`HUDButtonController`](../../Lobby/src/Controllers/HUDButtonController.luau), [`HUDBadgeController`](../../Lobby/src/Controllers/HUDBadgeController.luau), [`LeaderstatsService`](../../Lobby/src/Services/LeaderstatsService.luau), [`WelcomeBadgeService`](../../Lobby/src/Services/WelcomeBadgeService.luau), [`LevelConfig`](../../common/shared/Config/SharedConfig/LevelConfig.luau)

## Level, XP, coins, and shards

`HUDController` writes `HUD.HUDMiddle` from the profile replica (`Stats`): `Level`, `ExpAmount`, `CoinAmount.CoinAmountText` (which is `Stats.Cash`), and `ShardAmount.ShardAmountText`.
It listens to the replica's `OnChange`, so any server write to `Stats` (the end-of-match reward, a shop purchase) shows at once without its own event.

The **level is not stored in the profile**: it comes from the accumulated `Stats.XP` through `LevelConfig:Resolve(xp)`.
Level and XP can never be out of sync, and changing the curve re-evaluates everyone without a migration.
The curve is `floor(BASE_XP * level ^ CURVE)` (100 and 1.20), with `MAX_LEVEL = 50`; at the max, `ExpAmount` shows `MAX` and the bar is full.

### The XP bar

`ProgressBarContainer.EXPImage` is not a bar but a single `ImageLabel` that swaps art.
`LevelConfig.BAR_IMAGES` has one image per 20% of progress in the current level.
Exactly zero progress (a new profile, or right after a level up) uses the **empty bar authored in the GUI**, read from `EXPImage` on the first bind, so replacing the empty art in Studio is enough.

All six images are downloaded when the player joins and kept in memory by a disabled ScreenGui, `HUDImageCache`, with one `ImageLabel` per image.
`PreloadAsync` only guarantees the download; a live instance pointing at each image keeps it from being discarded.
That ScreenGui has `ResetOnSpawn = false` on purpose: the HUD is recreated on every respawn, the cache is not.

## Column buttons

`HUDButtonController` animates **every `GuiButton` inside the two columns** (`HUDFrame` on the right and `HUDLeft` on the left), at any depth.
Each button lives in a `Wrapper`, and a new button joins the animation just by appearing there (`DescendantAdded` stays connected because the GUI replicates in pieces).
A column missing from a HUD copy is skipped with a warning, and the other keeps working.

| Event | What it does |
| --- | --- |
| `MouseEnter` | slides `Position` to the column's `X.Scale` (`Circular`, 0.28 s) and plays `SharedSounds.SFX.UIHover` |
| `MouseLeave` | returns to the authored position, read once at bind |
| `MouseButton1Down` | shrinks the `UIScale` to 0.9 |
| `MouseButton1Up` | restores the scale (`Back`) and plays `SharedSounds.SFX.UIClick` |

With `AnchorPoint` 0.5 inside the wrapper (and `X.Scale = 0.5` at rest), a fifth of the width to the side is `X.Scale = 0.3`.
**The only difference between columns is direction**: the right column slides left (0.3) and the left one mirrors it (0.7), so the button always moves into the screen (`HUD_FRAMES`, one row per column).
`MouseLeave` also releases the scale, because releasing the click outside the button never fires its `MouseButton1Up`.

Only look and sound live there.
Each panel's own controller **opens** it (`ShopController`, `CrateUIController`, `DeckController`), and the owner of a map spot **takes** the player there (`RoundCardShopController` for `CardShop`, `ContractController` for `Contracts`), always through the same button's `Activated`.
That is why the click animation uses `Down`/`Up`, which consumes nobody's click.
Everyone finds the button by name at any depth (`UIUtil.waitForDescendant`), so rearranging wrappers in Studio does not break the bind.

## `New` badges

Five of the six column buttons have a `New` label drawn inside, and `HUDBadgeController` is the **only** code that writes its `Visible`.
One rule per button:

| Button | Lights when | Clears when |
| --- | --- | --- |
| `HUDLeft.Contracts` | a contract is ready to claim, **or** a period's `Period` rolled over | the claim happens (the profile undoes it); "rolled over" clears when the board opens |
| `HUDLeft.RobuxShop` | on arrival, and five minutes after each opening | the shop opens |
| `HUDFrame.Backpack` | a new crate enters the inventory | the backpack opens |
| `HUDFrame.Deck` | a unit the player **did not have** enters the profile | the loadout opens |
| `HUDFrame.CardShop` | the four-hour stock block turned | the shop opens |

**`HUDFrame.Shop` has no badge**: the crate shop always sells the same `ShopConfig.ITEMS`, so there is nothing new to announce, and its button has no label.

- **Opening the panel clears the badge.**
  Each panel calls `NoteSeen` when it opens: the `ProximityPanel`'s `BeforeOpen` for the contracts, the Robux shop, the card shop, and the backpack (`CrateUIController`), and `_setOpen` in the loadout (`DeckController`).
  It lives in the open path, not the click, because every panel also opens through `Open()`.
- The backpack and loadout badges are **reset** there, not turned off: whatever arrives after the look lights the badge again.
- **A pending claim is state, not news**: the contracts badge insists while a completed contract is unclaimed, even after the board opens.
- **The card shop turn is clock math** (`RoundCardShopConfig.rotationIndex`, checked every five seconds): the block turns at the same time for everyone.
  The contracts turn is read from the **profile** (`Contracts[kind].Period`), because what matters is the draw already saved.
- **The state belongs to the Lobby visit** and lives only on the client.
  Returning from a match is a new visit, and a snapshot of the profile is taken on arrival (`_snapshot`) so nothing the player already has counts as new.

The HUD is `ResetOnSpawn`, so the bind runs again on each copy; `HudToken` drops a lookup that returns from an old copy.
A missing piece (column, button, or label) becomes one warning per key.

## Leaderstats

`LeaderstatsService` adds three columns to the player list, in this order (Roblox draws them in the order values enter the folder).
It computes nothing; it copies `Data.Stats` into `IntValue`s.

| Column | Profile key |
| --- | --- |
| Coins | `Stats.Cash` |
| Wins | `Stats.Wins` |
| Shards | `Stats.Shards` |

**Coins is `Cash`**: the profile calls it `Cash` and the screen has always called it Coins; the list follows the screen.
It is not match money (`MobService.SessionCash`), which never reaches the profile.

**It stays current without polling.**
Every profile write goes through `DataService:Update`, which announces each one on the `DataUpdated` signal `(player, key, value)`.
The service listens to it (filtering `Stats`) and to `PlayerDataLoaded`, so the column changes the moment the profile changes.
The folder is parented to the `Player` **after** the three values are inside, so the list never flashes an empty row, and without an open profile the folder is not created at all.

Only the Lobby has this.
To add it to the Game, move the file to `common/server/Services`; `DataService` is shared, so `DataUpdated` already fires there.
The Game has its own session columns (see [Rewards](../game/rewards.md#leaderstats-damage-and-cash)).

## Welcome badge

`WelcomeBadgeService` asks [`BadgeService`](../common/badges.md) for the `Welcome` badge for every player who enters the Lobby, on `PlayerAdded`, without waiting for the profile.
It only exists in the Lobby, since the Game is never the first place a player sees.
