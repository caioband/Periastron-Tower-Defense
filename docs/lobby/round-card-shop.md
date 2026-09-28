# Card shop (Lobby)

The Lobby card shop (`StarterGui.ShopUI.RCSS`) sells **access** to [round cards](../game/round-cards.md): a purchase writes the card's `Id` into `Data.RoundCards`, and that table is what the in-match offer draws from.
Buying here unlocks a card; using it still means buying it again during a match, with round cash.

**Runs in:** Lobby
**Code:** [`RoundCardShopController`](../../Lobby/src/Controllers/RoundCardShopController.luau), [`RoundCardShopService`](../../Lobby/src/Services/RoundCardShopService.luau), [`RoundCardShopConfig`](../../common/shared/Config/SharedConfig/RoundCardShopConfig.luau), [`ProximityPanel`](../../common/shared/Util/ProximityPanel.luau)

## How it works

It opens by [proximity](../common/proximity-panel.md), like the crate shop, using the markers `ShopCardPartReference` and `ShopCardPartTeleport` (inside `Map.Deco.Houses.CardShop`, found in depth under `Workspace.Map`).
The radius is `OPEN_RADIUS` (5 studs), and the landing marker is outside it, as with the crate shop: `TeleportToShop` opens the panel by hand and marks the entry, so walking away closes it the same way.
The HUD's `CardShop` button (`HUD.HUDFrame.Wrapper.CardShop`) calls the teleport; its hover and press animation belong to [`HUDButtonController`](hud.md).

### Each player's stock comes from the clock

Three cards per four-hour block (`ROTATION_SECONDS`), **drawn per player**: two friends in the same lobby see different offers.
**Nothing is stored**: the block comes from `os.time()` (`rotationIndex`), and the three cards are recomputed from it plus the `UserId` with a seeded `Random` (`stockFor`).
That is why `RoundCardConfig.Draw` takes an `rng`: with the global `math.random`, the same player would see different cards on each Lobby server.

What everyone shares is the **clock**: blocks turn at 00:00, 04:00, 08:00… UTC, so `ResetText` still means something.
The countdown is written every second against the `ResetsAt` the **server** sent, since only the server agrees on the block the stock was drawn in.

**This only works because the pool does not change.**
The draw scans the whole catalog, including cards the player already owns (they show the `SOLD` veil).
A pool that shrank with each purchase would rebuild the stock by itself.

The two seed terms (block and player) **must use different multipliers** (`ROTATION_SEED` and `PLAYER_SEED`); with the same constant, block and player become interchangeable and one player's stock today would be another's tomorrow.

- A server that starts mid-block reaches the same stock for each player.
- No DataStore is needed for something the time and the owner already answer.
- **Reordering `RoundCardConfig.Cards` changes everyone's stock.**

The server keeps only `{ Index, ResetsAt }` per block (`GetBlock`); cards come from `GetStockFor`, per player.
When the block turns, the server pushes the new stock to everyone in the Lobby (`_watchRotation`, which sleeps until the reset), and the client also asks when its own countdown reaches zero.
The push covers players with the shop open; the request covers clock differences.

### Rerolling replaces that player's three cards

The dice button (`RCSS.ImageLabel.RerollDice`) opens developer product `REROLL_PRODUCT_ID` (3712166271, "Reroll Card Shop").
Buying it replaces the three cards at once: instead of the block's draw, they come from what was saved in the profile, until the block turns.
The `ResetText` countdown does **not** change: a reroll buys cards, not time.

**The rerolled shelf is saved** in `Data.RoundCardRoll`: `{ Index, Rolls, Cards }` (the block, how many rerolls were bought in it, and the card `Id`s).
An old record stops applying by itself when the block number changes.

A shelf is a result, not a formula.
The reroll draws **only from what the player has not unlocked**, a pool that shrinks when they buy, including when they buy from the rerolled shelf.
Recomputed from a seed, a sold slot would refill with a new card instead of staying `SOLD`.
Saving three strings in the profile is simpler than any seed, so `drawReroll` uses plain `math.random`: what it returns is saved, so it only needs to be unpredictable.

**The reroll avoids cards already owned, on a best-effort basis** (`REROLL_EXCLUDES_UNLOCKED`).
`splitByUnlocked` splits the catalog into what is missing and what is owned, and `drawReroll` fills the three slots from the first, completing from the second only when fewer than three remain:

| Cards already owned (of 24) | Rerolled stock |
| --- | --- |
| 0 to 21 | 3 cards, none `SOLD` |
| 22 | 3 cards, 1 `SOLD` |
| 23 | 3 cards, 2 `SOLD` |
| 24 (all) | button disabled; no draw |

When nothing is missing, the button is disabled: the time to prevent a useless purchase is before the prompt, because after the receipt Roblox has already charged.

The purchase does not go through any "I want to reroll" event:

1. the client calls `MarketplaceService:PromptProductPurchase`;
2. Roblox charges and sends the receipt to the server;
3. `MonetizationService`'s `ProcessReceipt` finds the callback registered by `RoundCardShopService` and calls `Reroll(player)`;
4. `Reroll` increments the block's counter and sends the new shelf through `RoundCardStock`.

A client request could only open the prompt (which it already does) or credit without payment; the receipt is the only proof of payment.
`Reroll` returns `false` when it cannot write the profile, and the receipt goes back as `NotProcessedYet`, so Roblox retries later.

On the client, a redraw compares `Index` **and** `Rolls`: a reroll does not change the block.

**A profile still loading is not "did not reroll".**
The client asks for the stock when `ShopUI` mounts, which happens before `StartSessionAsync` returns.
`GetStockFor` returns `nil` without a profile instead of guessing.
`RequestRoundCardStock` goes through `DataService:Get` and answers **when** the profile arrives, and `PlayerDataLoaded` pushes the stock by itself to cover a request that was lost.
The shop opens empty for a second instead of opening with the wrong shelf.

### `SOLD` is what this player owns

Cards the player already unlocked show the `SoldFrame` veil and an inactive `Buy` button.
The veil follows `RoundCards` from the **replica**, not the purchase reply, so there is one source for that state.
Buying with the shop open only lights the veil; the row is not redrawn.

With the veil, **the card's title and description hide**: the description used to overlap `SOLD` and turn the panel into a blur of letters.
It uses `Visible`, not transparency, because the card reveal (`UIUtil.applyFades`) writes those labels' transparency and the two would fight.

### Prices

4 to 8 shards, **written card by card** in `RoundCardShopConfig.PRICES`, one line per card, grouped by price.
Today's numbers follow the card's in-match `Price` (150 to 500): what is expensive in a round is expensive to unlock.
That is where the first table came from, not a rule the code enforces.

`MIN_PRICE`/`MAX_PRICE` do not decide prices; they **clamp** what is written, so a mistyped `12` becomes 8 and a `0` becomes 4.
A card in `RoundCardConfig` without a line does not break the shop: `priceOf` maps its in-match cost onto the range.
That is a safety net; a new card deserves a line decided by whoever is balancing.

The number goes into `Card.Buy.TextLabel` through `PRICE_FORMAT` (the shard icon and outline are authored on the button).

### Sharing `ShopUI`

`ShopUI.Frame` is the crate shop, `ShopUI.RCSS` the card shop, and `ShopUI.RobuxShop` the Robux shop, siblings in the same ScreenGui.
**None of them owns `Enabled` alone**: each wrapper's `Visible` says which panel is on screen, and each controller asks the others (`IsOpen`) before disabling the ScreenGui (the `CanDisable` of [`ProximityPanel`](../common/proximity-panel.md)).
By proximity the counters never overlap (while a shop is open, the HUD is hidden), but `Open` is public, so the guard stays.

Shared pieces live in `common/shared/Util`:

| Module | What it is | Used by |
| --- | --- | --- |
| `ButtonUtil.bindFeedback` | the buy button's weight (grows on hover, sinks on press) | the shops |
| `MarkerUtil` | finds a marker under `Workspace.<map>` in depth, with cache and a single warning; reads its pivot and half height | the shops |
| `LightingUtil.GetUIBlur` / `.TweenUIBlur` | the **single** `UIBlur` in Lighting, marked `LightingKeep` | the shops, dialogs, and `UILibraryController` |
| `UIUtil.captureFades` / `.applyFades` | read a clone's authored transparencies and fade from 1 to them | this shop and the in-match card shop |

Each card is a clone of the authored `CardWrapper`, and the `Card` **inside** it animates: the wrapper holds the slot in the `UIListLayout`.
Timings are `RoundCardConfig.Animation`, the same as the in-match offer.

### Events and checks

| Event | Direction | Purpose |
| --- | --- | --- |
| `RequestRoundCardStock` | client → server | asks for the stock |
| `RoundCardStock` | server → client | `{ Index, ResetsAt, Cards = { { Id, Price } } }` |
| `RequestBuyRoundCard` | client → server | `cardId` |
| `RoundCardPurchaseResult` | server → client | `cardId, success, reason` |

`reason` is one of `NotLoaded`, `NotInStock`, `AlreadyOwned`, `NotEnoughCurrency`, or `GrantFailed`: ways for a request to be stale or repeated, not program errors.

The purchase checks **that player's** current stock (`GetStockFor`, not the global one, and not `priceOf` directly, or the whole catalog would be for sale to a hand-crafted event).
It charges inside a single `:Update` of `Stats`, which does not yield, so two clicks cannot spend the same balance.
It checks ownership **again** inside the `RoundCards` write, so two clicks in the same frame never pay twice for the same card.
Anything that fails after charging is refunded.

## Design notes

The reroll was the game's first developer product, and it exposed two bugs on a path nobody had exercised: the Lobby had no `DataService:Save` (which `ProcessReceipt` calls before granting), and `MonetizationService:RegisterProduct` depended on boot order.
Both places now have `Save`, and product registration no longer depends on which `start()` runs first.
