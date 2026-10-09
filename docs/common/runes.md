# Runes

Temporary buffs bought with shards in the Lobby [rune shop](../lobby/rune-shop.md).
This page covers the shared core: the profile record, the clock, and how a rune's bonus reaches a reward.

**Runs in:** Game · Lobby · AFK
**Code:** [`RuneService`](../../common/server/Services/RuneService.luau), [`RuneConfig`](../../common/shared/Config/SharedConfig/RuneConfig.luau), [`Config.Data`](../../common/server/Config/Data.luau)

## How it works

### Tiers

Each rune has three tiers.
The tier changes only the bonus and the price; every tier lasts `DURATION` (25 minutes).

| Rune | Tier | Bonus | Price |
| --- | --- | ---: | ---: |
| Shards | I | +10% | 10 shards |
| Shards | II | +20% | 20 shards |
| Shards | III | +35% | 40 shards |

### The clock only runs while the player is in the game

The profile keeps the **seconds left**, not an expiry date:

```lua
Runes = {
	Shards = { Tier = 2, Remaining = 1312 },
}
```

`RuneService` runs in every place and counts the time down while the profile is open on that server.
Every `FLUSH_INTERVAL` (30 s) and when the profile closes (`OnBeforeRelease`, order 1), it subtracts the whole seconds played since its last write and removes a rune that reached zero.
Time offline and time spent teleporting between places is never subtracted.

Between two writes, `GetEntry` and `GetBonus` read the live value (saved minus elapsed), so a rune stops counting the second it runs out, not at the next write.
A player without a rune never gets a write: only the in-memory clock moves on.

### Buying again

Only one tier of each rune is active at a time.
`RuneConfig.purchaseAction` decides, and both the shop's client and the server call it, so they always agree:

| Active | Bought | Result |
| --- | --- | --- |
| none | any | `New`: the tier, with a full `DURATION` |
| tier N | tier N | `Extend`: another `DURATION` on top of what is left |
| tier N | higher | `Upgrade`: the new tier replaces it, with a fresh `DURATION` (the time left on the old tier is lost) |
| tier N | lower | refused with `LowerTier` |

Different runes are independent and can all be active at once.

### Where the Shards rune applies

It multiplies the shards from the end-of-match reward, in `WaveService:rewardsFor`, on top of the game passes: 1.5x Shards with a +20% rune pays 1.8x.
The result is rounded once, at the end, like the game passes alone.
Shards from contracts, codes, and Endless milestones are not multiplied.

Preset wins pay few shards, so rounding eats most of a low tier.
Extra shards per complete win, without game passes:

| Tier | Easy (1) | Medium (2) | Hard (3) | Impossible (4) | Nightmare (5) |
| --- | ---: | ---: | ---: | ---: | ---: |
| I (+10%) | 0 | 0 | 0 | 0 | +1 |
| II (+20%) | 0 | 0 | +1 | +1 | +1 |
| III (+35%) | 0 | +1 | +1 | +1 | +2 |

Endless pays up to 30 shards a run, where the bonus works in full (+3 to +10).

### A match keeps the best bonus it saw

A rune that is active at any point of a match covers the whole match, even if it runs out before the last wave.
`WaveService` calls `RuneService:Lock` for everyone when a round starts and for each player whose profile loads during a running round.
From then on `GetBonus` never returns less than the locked bonus.
The next `StartRound` clears the locks before locking again, so an expired rune does not carry into the next match.

The release hook runs at order 1 so the leave reward (order 0) still reads the lock.

## Configuration

`SharedConfig.RuneConfig`:

| Key | Default | Effect |
| --- | --- | --- |
| `Runes` | Shards | The catalog: `Id`, `DisplayName`, `Effect`, and `Tiers` (`Bonus`, `Price`) |
| `DURATION` | `1500` | Seconds of play one purchase adds |
| `CURRENCY` | `Shards` | The `Data.Stats` key that pays for a rune without its own `Currency` (`Shards` or `Cash`) |

## Usage

```lua
local RuneService = Framework:Get("RuneService")

RuneService:GetMultiplier(player, "Shards") -- 1.2 with tier II active (or locked)
RuneService:GetEntry(player, "Shards")      -- { Tier = 2, Remaining = 1311.4 } or nil
RuneService:Grant(player, "Shards", 3)      -- true, "Upgrade"; charges nothing
RuneService:Clear(player)                   -- removes every rune
```

To add a rune, add an entry to `RuneConfig.Runes`, author its frame in the shop (see [Rune shop](../lobby/rune-shop.md#studio-setup)), and make the reward it boosts read `RuneService:GetMultiplier(player, Id)`.

The `rune` admin command grants or removes a rune without charging; its optional `seconds` shortens the duration to watch a rune run out.
`runereset` removes every active rune and is open to QA testers (see [Admin commands](admin-commands.md)).
Both go through `RuneService:Clear`, which also drops the match lock, so a rune cleared mid-match no longer pays that match.
