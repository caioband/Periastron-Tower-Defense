# Leaderboards

Eight global leaderboards on the Lobby map (`Workspace.Leaderboards`), fed by both places.

**Runs in:** Game · Lobby (both write; only the Lobby displays)
**Code:** [`LeaderboardService`](../../common/server/Services/LeaderboardService.luau), [`PlaytimeService`](../../common/server/Services/PlaytimeService.luau), [`MatchStatsService`](../../Game/src/Services/MatchStatsService.luau), [`CurrencyService`](../../common/server/Services/CurrencyService.luau), [`Config.Leaderboard`](../../common/server/Config/Leaderboard.luau)

## How it works

Each board is a model with `Main > SurfaceGui > ScrollingFrame > Frame`.
The `Frame` is the **template**: the server removes it and clones one row per position (`Position` = `1st`, `Username`, `Value`), up to `TOP` (50).
The list of boards is `Config.Leaderboard.Boards` (server only).

| Model | Profile value | Format |
| --- | --- | --- |
| `HighestLevelLB` | `Stats.XP` (shown as level) | `25` |
| `MostCoinsLB` | `Stats.CoinsEarned` (total earned, not the balance) | `1.25M` |
| `MostMatchesWonLB` | `Stats.Wins` | `1.25M` |
| `NightmareWinsLB` | `Stats.DifficultyWins.Nightmare` | `1.25M` |
| `MostBoxesOpened` | `Stats.BoxesOpened` | `1.25M` |
| `MostMatchesPlayedLB` | `Stats.MatchesPlayed` | `1.25M` |
| `MostTimeInMatchesLB` | `Stats.TimeInMatches` (seconds) | `DD:HH:MM` |
| `MostTimePlayedLB` | `Stats.TimePlayed` (seconds) | `DD:HH:MM` |

HIGHEST LEVEL stores **XP**, not the level: the order is the same, and XP breaks ties among max-level players.

### One OrderedDataStore per board

The profile stays the source; the store is a sorted copy keyed by UserId.
Reading the top is **one page** of `GetSortedAsync(false, 50, 1)`, the same cost with a thousand or a billion players; the final `1` drops players at zero.

Each store is named `<PROFILE_KEY>_LB_<Store>`, so changing `PROFILE_KEY` resets profiles **and** boards together.

### Who writes, and when

Both places write (the Game changes XP, coins, wins, and matches; the Lobby changes coins, crates, and time), so the service is in `common/`.
Each server sends its own players' numbers:

- when the profile loads (everything that is not zero);
- every `WRITE_INTERVAL` (120 s), **only what changed** since the last write;
- on leave and on shutdown, through `DataService:OnBeforeRelease` with order `1`, after everyone who still writes to the profile on leave (the early-leave reward, the last playtime minute, the match clock).

Everything goes through a queue with one entry per store and player: a value that changes again before the write replaces the entry.
The queue respects the Roblox write budget (60 + 10 per player per minute) and, if a store fails, waits for the next cycle.
`BindToClose` holds the server until the queue is empty (25 s at most).
Players with a negative UserId (Studio test clients) are not written.

### Who reads

Only where `Workspace.Leaderboards` exists, which today is the Lobby.
Every `READ_INTERVAL` (120 s) it reads the eight boards, resolves names in one batch (`UserService:GetUserInfosByUserIdsAsync`, cached), and rewrites the rows.
Rows are reused between reads, and extra rows are hidden.
The SurfaceGui is in the Workspace, so what the server writes replicates to everyone.

### The counters

`BoxesOpened`, `TimePlayed`, `TimeInMatches`, and `MatchesPlayed` start at **zero for everyone**, including existing players; old profiles get the keys through the reconcile.

| Key | Written by | Rule |
| --- | --- | --- |
| `BoxesOpened` | `CrateService:OpenCrate` (Lobby) | a crate spent and rolled; the `unbox` command does not count |
| `TimePlayed` | `PlaytimeService` (common) | from profile load until leave, in both places; written every minute |
| `TimeInMatches` | `MatchStatsService` (Game) | real time with `WaveService` `Running`, from waiting for players to the last wave |
| `MatchesPlayed` | `MatchStatsService` (Game) | +1 when the player's time in that round passes `Data.MIN_MATCH_SECONDS` (180 s): win, loss, or leaving midway |

`MatchStatsService` starts a clock per player on `WaveService.Signals.RoundStarted` (or when they join a running round) and stops it on `RoundClosed` or on leave.
Stopping removes the clock, so a match counts once per player.

### MOST COINS is the total earned

`Stats.CoinsEarned` only goes up: spending in the shop drops nobody.
Whoever **gives** coins adds to it along with `Cash`: `WaveService:grantReward` (match rewards) and `ContractService` (contract claims).
Refunds (`ShopService`, `RoundCardShopService`) and the `cash` command only change the balance.

The key is **not in the template**, on purpose.
A player who played before it existed has earned at least their current balance, so `CurrencyService` creates the key with the current `Cash` when it is missing; a new profile has zero balance and starts at zero.
With the key in the template, the reconcile would create it at zero first, and old profiles could no longer be told apart.

## Studio setup

Each board is a model in `Workspace.Leaderboards` named as in the table, with `Main > SurfaceGui > ScrollingFrame > Frame` and the `Position`, `Username`, and `Value` labels inside the `Frame`.
