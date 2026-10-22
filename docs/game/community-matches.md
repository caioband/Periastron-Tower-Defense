# Community matches

A match on a map a player built in the Map Editor and published: the Game builds it at runtime and plays it like any other map, with smaller rewards.

**Runs in:** Game (server)
**Code:** [`MapService`](../../Game/src/Services/MapService.luau), [`WaveService`](../../Game/src/Services/WaveService.luau), [`ContractTrackerService`](../../Game/src/Services/ContractTrackerService.luau), [`MatchStatsService`](../../Game/src/Services/MatchStatsService.luau), [`common/mapeditor`](../../common/mapeditor) (`PeriMapAdapter`, `TemplateBuilder`), [`Config.CommunityMaps`](../../common/server/Config/CommunityMaps.luau)

The group comes from a build portal in the Lobby (see [Community maps panel](../lobby/community-maps.md)); the catalog is described in [Community maps](../common/community-maps.md).

## How it works

The Lobby teleports the group with `TeleportData.CommunityMap = "map_<userId>_<mapId>"` instead of `Map`.
`MapService:init` checks for it before the usual map choice:

1. **Hold.** Every character is anchored where it spawned (`HoldSpawns`): there is no ground yet.
2. **Check.** `CommunityMapService:GetListedEntry(key)` confirms the map is still published.
3. **Read.** `PlayerMapService:GetAsync(key)` reads the content, `Serializer.decodeMap` decodes it, and its owner must match the key.
4. **Build.** `TemplateBuilder.build()` turns `ServerStorage.MapEditorAssets` into `ServerStorage.MapEditor.Templates` (once per server), and `PeriMapAdapter.export` builds the map folder.
5. **Load.** The folder goes into `ServerStorage.Maps` as `CommunityMap` and `LoadMap` loads it like any other map.
   The characters are moved to its spawn and let go.
6. **Count.** `CommunityMapService:CountPlay(key)` adds one to the map's Plays.

The round waits for this: `WaveService:runRound` calls `MapService:AwaitLoaded()` after the players are ready, so no wave spawns before the path exists.

If any step fails, `AwaitLoaded` answers `false` and no round starts.
The reason goes to the server console (`MapService` warning).

- **Production:** the group goes back to the Lobby with `TeleportData.CommunityMapFailed = true` (players still arriving are sent back too), and the Lobby shows "THAT COMMUNITY MAP COULD NOT BE LOADED".
- **QA:** the group stays on the server, still anchored, so whoever is testing the map can read the error in the console (F9).

### The folder name is fixed

The map is always `CommunityMap` in `Maps`, never its own name, so a community map named "Farm" does not pick up Farm's music, weather pool, or Index entry.
`MapService.CommunityMapName` keeps the real name.

| System | On a community map |
| --- | --- |
| Lighting | The place's own (the map has no `Lighting` folder) |
| Music | None of the game maps' (`MapConfig.getMusic` does not know the name) |
| Weather | None (`WeatherConfig.GetPool` has no pool for it) |
| Index | Not recorded |

### Rewards

Anyone can publish an easy map, so a community match must not be a farm:

| What | On a community map |
| --- | --- |
| Coins, shards, XP | `REWARD_MULTIPLIER` of the usual (`WaveService:computeReward`) |
| `Stats.Wins` and `DifficultyWins` | Not counted: no map or difficulty unlock, no wins leaderboard |
| `Stats.CoinsEarned` | Not counted (Most Coins leaderboard) |
| `Stats.EndlessBestWave` and Endless badges | Not counted |
| `Stats.MatchesPlayed`, `Stats.TimeInMatches` | Not counted |
| Contracts | Nothing is recorded (`ContractTrackerService:_record`) |

XP still raises the player's level, at the reduced rate.

## Configuration

| Key | Default | Effect |
| --- | --- | --- |
| `Config.CommunityMaps.REWARD_MULTIPLIER` | `0.5` | Fraction of coins, shards, and XP a community match pays |
| `LOAD_TIMEOUT` (in `MapService`) | `60` | Seconds the round waits for the map before starting anyway |

## Studio setup

- `ServerStorage.MapEditorAssets`: the Map Editor's props, the same Package as in the Map Editor place.
- `ServerStorage.MapEditor`: mounted by Rojo from `common/mapeditor`.
- To test in Studio, set the `StudioCommunityMap` attribute on `ServerStorage.Maps` to a published map's key (`map_<userId>_<mapId>`).
  It needs API access to read the QA DataStores.

## Known issues

- The map is built around the world origin, where the editor's plot starts; anything the place keeps there overlaps it.
- A map whose props are missing from `MapEditorAssets` loads without them and logs how many were skipped.
- `MobController` drops the drawing of an enemy that is not over a `Grid` part, while the server keeps it (units still shoot it).
  The Map Editor refuses to publish a route that leaves the Path pieces, but a map published before that rule, or saved off-path after publishing, shows invisible enemies there.
