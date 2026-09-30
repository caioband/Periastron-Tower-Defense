# Rewards

What a match pays: round cash for every finished wave, the player list columns, and the coins, shards, and XP that go to the profile at the end of the match or when a player leaves early.

**Runs in:** Game
**Code:** [`WaveService`](../../Game/src/Services/WaveService.luau), [`LeaderstatsService`](../../Game/src/Services/LeaderstatsService.luau), [`DataService`](../../common/server/Services/DataService.luau), [`Config.Wave`](../../common/server/Config/Wave.luau), [`Config.Difficulty`](../../common/server/Config/Difficulty.luau), [`Config.Data`](../../common/server/Config/Data.luau)

## Wave cash

Every wave that ends pays round cash to **every player in the match**.
It is the only income that does not depend on what the player did: not damage, not kills, not farms.
It pays the same to everyone, including players who joined mid-match.

The payout is **cumulative**: each tier in `Config.Wave.CASH_TIERS` says how much one wave adds over the previous one, and wave N pays the sum of the steps of every wave up to it.

```lua
Wave.CASH_TIERS = {
    { UpTo = 10, Step = 25 },
    { Step = 50 },
}
```

| Wave | 1 | 2 | 3 | … | 10 | 11 | 12 | … | 25 | 30 | 35 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Payout | 25 | 50 | 75 | | 250 | 300 | 350 | | 1,000 | 1,250 | 1,500 |

The last tier has no `UpTo` and applies from there on.
This matters because `MaxWaves` depends on the difficulty, and Nightmare goes up to wave 35.

`WaveService:payWaveCash` pays it, called from `runRound` **after** the game-over check (a lost wave pays nothing) and **before** the victory check (the last wave is a finished wave like any other).

The amount is fixed: unlike kill cash, it does not go through the preset's `RewardMultiplier`.
A wave pays the same on Easy and on Nightmare; what changes between presets is how many waves there are.

### Effect on the economy

`Config.Wave` records that kill rewards were tuned for Hard to yield about 9,000 cash over its 25 waves.
Wave cash alone adds **11,125** over the same run, more than doubling the match economy and making it the largest income source in the game.

| Difficulty | Waves | Total wave cash |
| --- | --- | --- |
| Easy | 15 | 3,375 |
| Medium | 20 | 6,625 |
| Hard | 25 | 11,125 |
| Impossible | 30 | 16,875 |
| Nightmare | 35 | 23,875 |

To rebalance it, change `CASH_TIERS`; nothing else needs to change.

## Leaderstats: Damage and Cash

`LeaderstatsService` adds two columns to the player list, in this order (Roblox draws them in the order the values are added to the folder):

| Column | Source |
| --- | --- |
| Damage | `MobService.SessionDamage`, the score that picks the MVP (`GetDamageDealt`) |
| Cash | `MobService.SessionCash`, the round cash (`getCash`) |

Both belong to the **session**, not the profile: nothing here is saved, and both go back to zero when the round restarts.
Do not confuse them with the [Lobby leaderstats](../lobby/hud.md#leaderstats), which show the profile's Coins, Wins, and Shards.

The columns are **polled** four times a second (`REFRESH_INTERVAL = 0.25`) instead of updated on each write:

- **Frequency:** damage grows on every hit on every enemy.
  With area attacks and several towers that is dozens of writes a second, far more than the list can show.
- **Resets:** the end of a round clears the score with `table.clear(SessionDamage)`, which is not a write at all.
  An event-driven design would keep showing the previous match; reading the state gets the reset for free.

A value is written only when it changes, so an idle server replicates nothing.
The `math.floor` is explicit so the comparison uses the same number that is written; without it, fractional damage would count as a change on every hit without the column ever changing.

## End-of-match reward

A completed run pays the full numbers of its difficulty: `WinCash` and `WinShards` in `Config.Difficulty` are the final amounts, so changing them is all it takes to reprice a difficulty.

| Difficulty | Waves | Coins | Shards |
| --- | ---: | ---: | ---: |
| Easy | 15 | 100 | 1 |
| Medium | 20 | 225 | 2 |
| Hard | 25 | 450 | 3 |
| Impossible | 30 | 685 | 4 |
| Nightmare | 35 | 900 | 5 |

XP is still a base times a multiplier (`Data.BASE_WINNING_XP` times the difficulty's `WinXpMultiplier`), because the base is the same for everyone and the multiplier is the number worth reading.

These are the base amounts.
Per-player multipliers such as game passes are applied afterward in `WaveService:rewardsFor` (see [Game passes](../common/gamepasses.md)).

### Proration and losses

`WaveService:computeReward` prorates the reward by the waves survived.
Shards only start after `Data.SHARD_WAVE_THRESHOLD` (half the match) and follow the curve from there, so the expensive currency stays with players who get close to the end.

**Losing pays no shards**, and pays a fifth of the coins (`Data.LOSS_CASH_MULTIPLIER = 0.2`).
The whole run is the product, not time survived: otherwise, falling on Nightmare's last wave would pay almost the same as finishing it.
Shards are zeroed **after** the curve, not by skipping it: a loss does not change *when* they would start, it removes all of them.

| Medium, 20 waves | Coins | Shards |
| --- | ---: | ---: |
| Won | 225 | 2 |
| Lost on wave 20 | 45 | 0 |
| Lost on wave 10 | 23 | 0 |

## Early-leave reward

Leaving mid-match, by closing the game or because the server is shutting down, pays the reward prorated to the waves survived.
It uses the same `computeReward` as the end of the round: leaving on wave 18 of 20 pays almost everything, leaving on wave 2 pays almost nothing, and wave 0 (difficulty vote, intermission) pays nothing.

With the default preset (Medium, 20 waves):

| Left on wave | Coins | Shards | XP |
| --- | --- | --- | --- |
| 1 | 11 | 0 | 10 |
| 10 | 113 | 0 | 100 |
| 15 | 169 | 1 | 150 |
| 20 | 225 | 2 | 200 |

**Leaving is not losing.** `GrantLeaveReward` calls `computeReward` without the `lost` flag on purpose: a player who leaves a round that is still running was not defeated.

### Paying only once

`WaveService.PaidRewards` records how much each `UserId` has already received this round, and `grantReward` pays only the difference.
That lets the leave reward coexist with the end-of-round reward in two cases:

- a player who leaves at the exact moment the round ends would be paid by `onRoundEnded` **and** by the leave;
- a player who leaves on wave 19 and rejoins the same round would get both full rewards.

With the difference, a player who comes and goes never gets more than one who stayed the whole round.
The ledger resets on `StartRound` and `ResetRound`.

## Design notes

- **The leave hook lives in `DataService`.**
  `DataService` calls `WaveService:GrantLeaveReward` from `OnBeforeRelease`, not from a `PlayerRemoving` in `WaveService`.
  Both services listen to `PlayerRemoving` and their order is not guaranteed, and a credit written after `EndSession` goes to a closed profile and is lost.
  On shutdown, `DataService`'s `BindToClose` calls `Destroy` for each player, where `PlayerRemoving` is unreliable.
  Every exit goes through `Destroy`, so the hook covers both cases.
  Each callback runs in a `pcall`: an error there must not stop the session from closing, or the profile stays locked and the player cannot join another server.
- **Final amounts instead of base × multiplier for coins and shards.**
  With a base and a multiplier, the number that matters (what Nightmare pays) only appeared after the math.

## Known issues

Leaving pays more than losing.
On Medium, losing on wave 19 pays 43 coins and 0 shards, while *closing the game* on wave 19 pays 214 coins and 2 shards.
If this becomes a problem, the fix is one line, `computeReward(preset, true)` in `GrantLeaveReward`, at the cost of a dropped connection counting as a loss.
