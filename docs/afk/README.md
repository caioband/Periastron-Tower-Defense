# AFK place

The AFK place: a third place in the universe, next to the Lobby and the Game.
Players stay here idle and earn coins for the time they spend; a button sends them back to the Lobby.

For the repository layout and what is shared between the places, see [Repository overview](../architecture/overview.md).

## What is specific to this place

| Folder | Mounted at | Contents |
| --- | --- | --- |
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | Entry LocalScript |
| `src/Controllers/` | `Client.Controllers.Afk` | AfkArea, CoinCount |
| `src/Services/` | `ServerScriptService.Services.Afk` | AfkArea |
| `src/Shared/` | `ReplicatedStorage.Afk` | `AfkRewards`: config the server and the client both read |

There are no place-specific Cmdr definitions yet, so the project has no `Commands.Afk` or `Types.Afk` node.
Add the node when the first file goes into that folder: a node that points at a folder git does not track breaks a fresh clone.

### Why `ReplicatedStorage.Afk` and not `Shared`

`ReplicatedStorage.Shared` is a Roblox Package (it has a `PackageLink`) shared with the Lobby and the Game.
Anything added inside it goes to the other places the next time the package is published.
Replicated code and config that only this place uses go in `ReplicatedStorage.Afk` instead.

## Pages

| Page | What it covers |
| --- | --- |
| [AFK area](afk-area.md) | The time-in-area timer, coin rewards, the HUD, and the button back to the Lobby |

## Loading

The AFK place loads the same way as the Lobby:

- `ClientBoot` fires `Framework:Fire("Loaded", true)` 1.2 seconds after the client starts.
- The shared `DataService` runs with the `Afk` entry of `Config.Data.Places`, the same settings as the Lobby: `Get` waits for the `Loaded` tag before handing out the profile (see [Data and profiles](../common/data-and-profiles.md#what-changes-per-place)).

When the client finishes loading, the Output shows:

```text
[Periastron] client loaded: AFK, QA environment, place version 0
```

## Shared systems here

Every Service in `common/server/Services` and every Controller in `common/client/Controllers` loads here too.
Systems that need content from the place (a board, a part reference, a GUI) log a warning and stay idle when it is missing, as they do in the other places.

- **Playtime.** `PlaytimeService` does nothing here: time in this place goes only to `Stats.TimeInAfkArea` (MOST AFK TIME) and stays out of `Stats.TimePlayed` (MOST TIME PLAYED, in the Lobby).
- **Leaderboards.** `LeaderboardService` draws the boards whose `Place` is `Afk`: today only MOST AFK TIME (`Stats.TimeInAfkArea`). See [AFK area](afk-area.md#saved-time-and-the-leaderboard).
- **Teleports.** `EnvironmentConfig` has an `Afk` id per environment: Production `80286820709620`, QA `116470384978275` ("AFK Station").
  The Lobby's `AfkTeleportService` sends players here with `Environment.GetPlaceId("Afk")`, and `AfkAreaService` sends them back with `Environment.GetPlaceId("Lobby")` (see [AFK area](afk-area.md#from-the-lobby)).

## Wally

The same four dependencies as the other places, with `wally.lock` pinned to the same resolved versions (Cmdr 1.12.0, Signal 2.0.3).

## Outside the repository

Everything that is not code (the map, GUIs, sounds, `ReplicatedStorage.Shared.Assets`) lives only in the published place, as in the other two.
