# Game passes and Robux purchases

Six game passes and three coin packs.
No pass logic is spread across the code: the whole catalog is `SharedConfig.GamepassConfig`, and each benefit is a number in a field.

**Runs in:** Game · Lobby
**Code:** [`MonetizationService`](../../common/server/Services/MonetizationService.luau), [`RobuxShopService`](../../common/server/Services/RobuxShopService.luau), [`RobuxShopController`](../../Lobby/src/Controllers/RobuxShopController.luau), [`PlayerChatController`](../../common/client/Controllers/PlayerChatController.luau), [`GamepassConfig`](../../common/shared/Config/SharedConfig/GamepassConfig.luau), [`RobuxShopConfig`](../../common/shared/Config/SharedConfig/RobuxShopConfig.luau)

## Passes

| Pass | Id | What it does | Where it applies |
| --- | ---: | --- | --- |
| `CardSlots` | 1966789042 | +5 cards in the deck | `DeckConfig.limitFor` |
| `Luck` | 1969136561 | ×1.3 weight for Epic and up in unboxing | `CrateService:_rollRarity` |
| `Coins` | 1969568499 | 2x end-of-match coins | `WaveService:rewardsFor` |
| `Shards` | 1970648287 | 1.5x end-of-match shards | `WaveService:rewardsFor` |
| `Speed` | 1970667486 | unlocks the 2x match speed step | `SpeedConfig.Steps` (see [Match speed](../game/match-speed.md)) |
| `VIP` | 1953119816 | 20% off crates, 1.25x XP, chat tag | `ShopConfig.priceFor`, `WaveService:rewardsFor`, `PlayerChatController` |

## How it works

### A pass is state, not a credit

This rule decides everything else.
A developer product purchase is an **event** that must be credited once (what `ProcessReceipt` and `PurchaseHistory` do).
A game pass is a **state**: the player owns it or not, today.

So **nothing about a pass is saved as a value in the profile.**
The +5 cards do not go into `CardLimit`; they are added on read (`DeckConfig.limitFor`).
Writing to the profile would be a credit, and credits do not go back: a refunded player would keep the higher cap forever, and a second login would add five more.

What is saved is a **copy** of what Roblox answered, in `Data.Gamepasses`:

```lua
Gamepasses = { VIP = true, Coins = true }
```

The key is the `GamepassConfig` key, **not** the numeric id: the id belongs to Roblox and changes if a pass is recreated.
A changed id is one line in the config, not a profile migration.

- `MonetizationService:RecalibratePasses` rewrites the **whole** table on every join, so a refunded pass disappears on the next login.
  The copy only exists so the rest of the game does not ask Roblox on every crate and every round end.
- **An API failure does not remove a pass.**
  `_ownsPass` returns `nil` (not `false`) when the call fails, and `nil` keeps what the profile already had.
- **A pass works immediately.**
  `PromptGamePassPurchaseFinished` recalibrates on purchase, so a player who buys 2x Coins sees it right away.

### Numbers multiply, and nobody writes `if`

`GamepassConfig`'s functions scan the passes a profile has: multipliers multiply each other, bonuses add up, and a missing field is neutral.
A second coins pass tomorrow works **without touching any reader**, which would not happen with an `if` per pass.

### Luck lifts the top and leaves the bottom alone

`Luck` multiplies the weight of Epic, Legendary, and Cosmic in the crate pool (from `GamepassConfig.LUCK_MIN_RARITY`) and leaves Common and Rare as they are.
The draw normalizes by the sum of weights, so raising the top already pushes the bottom down.
The relative gain shrinks as a crate gets better: normalized weights leave little room when Epic+ is already most of the pool.

The odds shown in the shop **do not change**: `Crate.GetDisplayOdds` is still the raw pool, which is what a player *without* the pass gets.

### The price on screen is the price charged

`ShopConfig.priceFor(item, profile)` is called on both sides: `ShopService` to charge and `ShopController` to write the button.
It rounds **to the nearest** value, with a floor of 1.
Not up: the Fragmented Crate costs 4 shards, 20% of that is 0.8, and rounding up would charge VIP players the same 4.

| Crate | Normal | VIP |
| --- | ---: | ---: |
| Crate of Beginnings | 50 coins | 40 |
| Crate of Nature | 200 coins | 160 |
| Fragmented Crate | 4 shards | 3 |
| Legendary Crate | 1800 shards | 1440 |

### Rewards: one match base, one multiplier per player

`WaveService:computeReward` is **one** calculation for the whole room, from waves survived and difficulty.
Each player's multiplier enters afterward, in `rewardsFor`.
The `RoundReward` sent to the screen carries the **multiplied** number: the player reads what actually reached their wallet.

### The chat tag is an attribute, not the profile

The profile replica only reaches its owner, so it cannot drive chat: `[VIP]` must appear on the player's messages **on everyone's screen**.
`MonetizationService` publishes a `Pass_<key>` attribute on the `Player` for each pass with a `ChatTag`, and `Player` attributes replicate to the room.
`PlayerChatController` decorates messages in `TextChatService.OnIncomingMessage`; it decides nothing.

## The Robux shop

`StarterGui.ShopUI.RobuxShop` in the Lobby is a storefront only.
`RobuxShopConfig.PASSES` maps each row (`GP1`–`GP6`) to a pass key, and `RobuxShopConfig.PACKS` lists the coin packs:

| Row | Product id | Coins |
| --- | ---: | ---: |
| `DEVPROD1` | 3713311022 | 200 |
| `DEVPROD2` | 3713311161 | 1,400 |
| `DEVPROD3` | 3713311237 | 7,000 |

Buttons open the Roblox prompt, and crediting stays where it always was: passes through `MonetizationService` (state), packs through `ProcessReceipt` in `RobuxShopService` (an event, credited once).
If the pack cannot be credited (no profile yet, no `CurrencyService`), the receipt is not granted and Roblox retries it.
A pass the player owns shows `OWNED` and stops opening the prompt; packs can be bought any number of times.
The config holds only names and numbers; what each pass does stays in `GamepassConfig`, so a pass cannot gain a benefit in the shop that it lacks in the game.
