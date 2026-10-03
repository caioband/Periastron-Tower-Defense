# Environments

The game is published to two experiences, Production and QA, and `Environment` tells code which one it is running in and which place ids belong to it.
Every teleport between the Lobby and the Game takes its destination from here.

**Runs in:** Game · Lobby · AFK (server and client)
**Code:** [`Environment`](../../common/shared/Util/Environment.luau), [`EnvironmentConfig`](../../common/shared/Config/SharedConfig/EnvironmentConfig.luau)

## How it works

Each environment is its own universe, with its own Lobby and Game places, and optionally an AFK place.
When `Environment` is first required, it compares `game.GameId` (the universe id) with the `UniverseId` of each environment in `EnvironmentConfig` and keeps the match.

A teleport has to stay inside its own universe: `TeleportAsync` with `ShouldReserveServer` can only reserve a server in the caller's universe.
So the QA Lobby must send players to the QA Game, and the QA Game must send them back to the QA Lobby.
`Environment.GetPlaceId` returns the right id for the universe the server is in.

| Environment | Universe | Lobby | Game | AFK |
| --- | --- | --- | --- | --- |
| `Production` | `10340119210` | `132304466547289` | `109030368179494` | `80286820709620` |
| `QA` | `10767160215` | `80434020174775` | `131924395601623` | none yet |

These are the callers:

| Caller | What it does |
| --- | --- |
| `PortalService` (Lobby) | Sends a portal group to `GetPlaceId("Game")` |
| `TutorialService` | Sends the player to the tutorial match at `GetPlaceId("Game")`, and offers the tutorial only when `IsPlace("Lobby")` |
| `WaveService` (Game) | Sends the player back to `GetPlaceId("Lobby")` |
| `AfkAreaService` (AFK) | Sends the player back to `GetPlaceId("Lobby")` |
| `CmdrService` | Lets every player run `QA_COMMANDS` (currencies, units, and level) when `IsQA()`; see [Admin commands](admin-commands.md#testers-in-qa) |

### Unknown universes

If `game.GameId` matches no environment, `Environment` uses `EnvironmentConfig.FALLBACK` (`Production`) and sets `Known` to `false`.

- In a loose `.rbxl` that was never published, `GameId` is 0. There is nowhere to teleport, so this only logs a Studio debug line.
- In a published universe that is missing from the config, the server logs a warning once, because every teleport from there will fail.
  Add the universe to `EnvironmentConfig` to fix it.

## Configuration

`SharedConfig.EnvironmentConfig`:

| Key | Default | Effect |
| --- | --- | --- |
| `Environments.<Name>.UniverseId` | See the table above | The universe id (`game.GameId`) that identifies the environment |
| `Environments.<Name>.Places.Lobby` | See the table above | The Lobby place id in that universe |
| `Environments.<Name>.Places.Game` | See the table above | The Game ("Main Game") place id in that universe |
| `Environments.<Name>.Places.Afk` | See the table above | The AFK place id in that universe; optional |
| `FALLBACK` | `"Production"` | The environment used when the universe is unknown |

All these ids are public, so the config is replicated.

## Usage

```lua
local Environment = require(Shared.Util.Environment)

Environment.Name                 -- "Production" or "QA"
Environment.Known                -- false when the universe is not in the config
Environment.IsProduction()
Environment.IsQA()
Environment.GetPlaceId("Game")   -- the Game place id of this environment
Environment.IsPlace("Lobby")     -- is this the Lobby of this environment?
Environment.HasPlace("Afk")      -- does this environment have an AFK place?
Environment.Describe()           -- "QA", or "unknown universe <id>, using Production ids"
```

### Client boot line

When a client finishes loading, the `ClientBoot` of each place prints one public line with `log:Info`, in live servers too:

```text
[Periastron] client loaded: Lobby, QA environment, place version 42
```

It prints 1.2 seconds after the controllers load (in the Lobby, right after `Loaded` is sent to the server), once `game:IsLoaded()` is true.
The place is `Lobby`, `Main Game`, or `AFK`.
`Environment.Describe()` gives the environment part, and says `unknown universe <id>, using Production ids` when the universe is not in the config.

Do not hard-code a place id or read `EnvironmentConfig` directly; go through `Environment` so both environments keep working.

`GetPlaceId` errors for a place the environment does not have, so anything that teleports to the AFK place must check `HasPlace("Afk")` first (QA has none yet).
`IsPlace` just answers `false` there.

To add an environment, add an entry to `Environments` with its universe id and the Lobby and Game place ids (and `Afk` when it has one), and add its name to the `EnvironmentName` type in `Environment`.

## Design notes

The environment comes from the universe id and not from the place id, because the universe is the unit that separates Production from QA, and both places of an environment share it.

`PlaytimeService` tells the Lobby from the Game by the Rojo folder it is mounted in, not by place id, and that stays as is: it only needs to know which place it is, not which environment.
