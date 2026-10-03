# AFK area

Pays players for time spent in the AFK place, saves that time to the profile for the MOST AFK TIME leaderboard, shows it over every head, and sends players back to the Lobby when they ask.

**Runs in:** AFK
**Code:** [`AfkAreaService`](../../Afk/src/Services/AfkAreaService.luau), [`AfkAreaController`](../../Afk/src/Controllers/AfkAreaController.luau), [`CoinCountController`](../../Afk/src/Controllers/CoinCountController.luau), [`AfkRewards`](../../Afk/src/Shared/AfkRewards.luau)

## How it works

### The timer

`AfkAreaService` starts a player's timer when their profile opens (`DataService.Signals.PlayerDataLoaded`) and stops it before the profile is released.
It sets the `AfkAreaEnteredAt` attribute on the `Player` to the start time, in `workspace:GetServerTimeNow()`.

Every second, the service writes the time in the area, as `HH:MM:SS`, on the `TimeSpent` billboard over the player's head.
Every player sees everyone's time.

Being AFK (see [AFK detection](../common/afk.md)) does not stop the timer: the area exists for idle players.

### Saved time and the leaderboard

The same timer is added to `Stats.TimeInAfkArea`, in seconds, every 60 seconds and once more before the profile is released.
Only whole seconds are written; the fraction goes in with the next write, so nothing is lost between writes.
A server that crashes loses at most the last minute.

`LeaderboardService` copies the counter to the `TimeInAfkArea` store and draws it on `Workspace.Leaderboards.MostAfkTimeLB` (MOST AFK TIME), in this place only.
See [Leaderboards](../common/leaderboards.md).

### Rewards

Each entry in `AfkRewards.Rewards` pays `Amount` of `Currency` every time the timer crosses another multiple of `Interval` seconds.
Payouts are worked out from the elapsed time, so a slow tick pays everything owed on the next one.

A payout goes through `CurrencyService:Apply`, and the profile is saved right after it instead of waiting for the autosave.
A payout that `Apply` rejects is retried on the next tick.
Payouts do not count toward `Stats.CoinsEarned` (the MOST COINS leaderboard).

### HUD

`AfkAreaController` shows the countdown to the next payout in `RewardFrame.TimerLabel`.
It works the countdown out from `AfkAreaEnteredAt` and the reward intervals, so the server sends nothing every second.
Until the timer starts, the label reads `--:--`.

`CoinCountController` keeps `CoinCount.CoinAmountText` equal to `Stats.Cash`, formatted as `12,500`.
It listens to the profile's replica, so it follows any change made through `DataService:Update`.

Both controllers bind their GUI elements again every time they appear, because the `ScreenGui` has `ResetOnSpawn`.

### Back to the Lobby

`ReturnFrame.ReturnButton` fires `AfkReturnToLobby`.
The server teleports the player to the Lobby of the current environment with `Environment.GetPlaceId("Lobby")`.
The server ignores repeat requests from the same player for 10 seconds; the button ignores clicks for 3 seconds and shows `...` in the meantime.

## Configuration

`AfkRewards` is mounted at `ReplicatedStorage.Afk.AfkRewards`, so the server and the client both read it.
It stays out of `ReplicatedStorage.Shared`, the Roblox Package shared with the other places (see [AFK place](README.md#why-replicatedstorageafk-and-not-shared)).

| Key | Default | Effect |
| --- | --- | --- |
| `EnteredAttribute` | `"AfkAreaEnteredAt"` | Player attribute with the timer's start time |
| `Rewards[].Id` | `"AfkCoins"` | Unique name; the service counts payouts per `Id` |
| `Rewards[].Interval` | `300` | Seconds in the area between payouts |
| `Rewards[].Currency` | `"Cash"` | `Data.Stats` key to pay into; must be in `CurrencyService.Stats` |
| `Rewards[].Amount` | `125` | What each payout gives |

To add a reward, add another entry to `Rewards`.
The service skips an entry with a missing `Id`, a non-positive `Amount` or `Interval`, or an unknown `Currency`, and logs a warning once when it starts.

## Studio setup

| Instance | What the code needs |
| --- | --- |
| `ReplicatedStorage.TimeSpent` | A `BillboardGui` with a `TextLabel`; cloned into each character's `Head` |
| `StarterGui.ScreenGui.RewardFrame.TimerLabel` | `TextLabel` for the countdown |
| `StarterGui.ScreenGui.RewardFrame.CoinCount.CoinAmountText` | `TextLabel` for the coins |
| `StarterGui.ScreenGui.ReturnFrame.ReturnButton` | `ImageButton`, with a `ButtonText` `TextLabel` child |
| `Workspace.Leaderboards.MostAfkTimeLB` | Leaderboard model with `Main > SurfaceGui > ScrollingFrame > Frame` (see [Leaderboards](../common/leaderboards.md#studio-setup)) |

The controllers match these elements by name and parent name, anywhere under `PlayerGui`.

## Known issues

- Only Production has an `Afk` place id in `EnvironmentConfig`, and nothing in the Lobby teleports players into this place yet.
- The billboard and the reward countdown start over on every visit; only `Stats.TimeInAfkArea` adds up across visits.
