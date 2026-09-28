# Maps

`MapService` picks the map for the match, clones it into the Workspace, and sets up everything that hangs off it: the spawn, the base health display, the weather bounding box, and the map lighting.

**Runs in:** Game
**Code:** [`MapService`](../../Game/src/Services/MapService.luau), [`BaseHealthController`](../../Game/src/Controllers/BaseHealthController.luau), [`MapConfig`](../../common/shared/Config/SharedConfig/MapConfig.luau)

## How it works

### Picking the map

- **Live server:** the map comes from the TeleportData of the first player, sent by the Lobby portal.
  If it is missing or invalid, the server warns and picks a random map.
  If the Lobby asks for a map that `MapConfig` knows but `ServerStorage.Maps` does not have, the server warns and falls back as well.
- **Studio:** there is no TeleportData.
  Set the `StudioMap` attribute on `ServerStorage.Maps` to choose a map; without it, a random map is picked silently.

A random pick uses the maps in `MapConfig.MAPS` that exist in `ServerStorage.Maps`.
If none of them exist, it picks straight from the folder.

The map list, display names, and the wins each map needs in the Lobby are in `MapConfig.MAPS` (see [Maps panel](../lobby/maps-panel.md)).

### Spawn fallback

When the map loads, `MapService` stores the position of the map folder's first `SpawnLocation` (the one at the root; without it, the first at any depth), `MapConfig.SPAWN_HEIGHT_OFFSET` studs above it.
Every character that spawns (respawns included), and everyone already in the game when the map arrives, is checked: anyone more than `MapConfig.SPAWN_FALLBACK_RADIUS` studs away (on the horizontal plane) is moved there.

This covers a `SpawnLocation` left enabled somewhere in the place (Roblox picks among all enabled ones) and a character that spawned before the map existed.
A map without a `SpawnLocation` only warns.

### Base health display (`BaseHP`)

Each map folder has, at its root, a Part named **`BaseHP`**: invisible, anchored, and inert, with a `BillboardGui` whose `TextLabel` named **`Value`** shows the base health.

`MapService:LoadMap` clones the Part into `workspace.Map` with the rest of the map.
The clone is forced to `Anchored`, with `CanCollide`, `CanQuery`, and `CanTouch` off: a loose Part would fall out of the world with its billboard, and `CanQuery` on would put it in the raycast that validates unit placement.
Its appearance stays as authored.

`BaseHealthController` writes the number on the client on every `UpdateBaseHealth`, the same event `MobController` uses to shake the screen when an enemy escapes.
It finds the label by name among the Part's descendants and falls back to the first `TextLabel` it finds, so rearranging the frame inside the billboard does not break it.
The Part replicates before its children, so the search retries for a few frames until the billboard arrives.

`UpdateBaseHealth` only fires when the health **changes**, and the map reaches the client long before the first leak.
So as soon as the controller finds the label, it asks for the current value with `RequestBaseHealth`.

The health itself belongs to the server: `MobService:mobEscaped` subtracts the difficulty's `MobDamage`, and the maximum is the difficulty's `BaseHealth` (`common/server/Config/Difficulty.luau`).

### Bounding box

Each map has a Part named **`BoundingBox`** that says where the map is, and both kinds of [weather](../common/weather.md) fit themselves to it.
Only `Position` and `Size` are read: the boxes are axis-aligned.

`WeatherService` only sees the Workspace, so `LoadMap` clones the box into `workspace.Map` with `CanQuery` off, so it stays out of the footstep raycast and the placement check.

A map without the box falls back to measuring its geometry, using `WeatherConfig.BoundsFolders` (`Terrain` and `Path`, so locked scenery does not count) and `WeatherConfig.MaxPartFootprint` (512 studs).
This is a fallback only, and its heuristics fail badly on some maps: `Snowy` has two 2048×2048 `Ice` planes inside its own `Terrain`, and `Volcano` keeps its water there.
The measured `Volcano` comes out at 500×500 against the 147×109 of the authored box.

The measurement respects rotation: the half-extent of a rotated Part's bounding box is `|R| * halfSize`, not `Size / 2`.

### Map lighting

`LoadMap` applies the map's `Lighting` folder through [`LightingService`](../common/lighting.md) instead of clearing `Lighting` by hand:

```lua
local preset = LightingService:Register(MapLighting, LightingConfig.MapPrefix .. Name)
LightingService:Apply(preset)
```

`Register` exists because of replication.
Maps live in `ServerStorage`, which does not replicate, so the folder is cloned into `Assets.Lighting` (as `Map_Farm`, `Map_Cave`, and so on) before it is applied.
Without that clone, the client would have nowhere to read the target values of the transition from.
A map without the folder keeps the lighting authored in the place.

When the service starts, it registers the folder of **every** map, not only the one being loaded (`MapService:registerMapLighting`).
That lets the `lighting` command switch between map lightings to compare them in game.

A folder with **no attributes** is valid: the `Lighting` properties stay the same and only the instances change.
For a map to define the whole lighting, put the attributes on its folder.
Because "applied and nothing changed" and "not applied" look the same, `Apply` logs (in Studio) how many properties and instances it applied, `LoadMap` warns when a map has no folder, and `lightinglist` shows the same from inside the game.

## Configuration

| Key | Value | Effect |
| --- | --- | --- |
| `MapConfig.MAPS` | Farm, Desert, Snowy, SnowyCastle, Mountain, Cave, Volcano, Beach, Swamp, Pale Garden | The maps, their display names, images, music, and `WinsRequired` |
| `MapConfig.SPAWN_HEIGHT_OFFSET` | `5` | Studs above the `SpawnLocation` center where players are placed |
| `MapConfig.SPAWN_FALLBACK_RADIUS` | `25` | Horizontal distance from the spawn beyond which a character is moved back |
| `MapConfig.BASE_HEALTH_PART` | `"BaseHP"` | Name of the base health Part in each map |
| `MapConfig.BASE_HEALTH_LABEL` | `"Value"` | Name of the `TextLabel` that shows the number |
| `WeatherConfig.BoundsPartName` | `"BoundingBox"` | Name of the map's bounding box Part |
| `WeatherConfig.BoundsFolders` | `{ "Terrain", "Path" }` | Folders measured when a map has no bounding box |
| `WeatherConfig.MaxPartFootprint` | `512` | Parts larger than this are ignored by the fallback measurement |
| `LightingConfig.MapPrefix` | `"Map_"` | Prefix of the lighting presets registered from maps |

## Studio setup

Each folder in `ServerStorage.Maps` needs, at its root, next to `Content`:

- a `SpawnLocation`;
- a `BaseHP` Part with a `BillboardGui` and a `TextLabel` named `Value`;
- a `BoundingBox` Part covering the playable area;
- a `Lighting` folder (optional) in the [preset format](../common/lighting.md#presets).

## Known issues

- The lighting folders use different names for the same effect (`Blur [Realism Mod]` in one map and `Blur` in another, `SunRays` against `SunRays [Realism Mod]`).
  Interpolation matches by name, so instead of one effect turning into the other, one fades to zero and the other fades in.
  Standardizing the names makes the transition shorter and smoother.
- Several lighting folders have **two** children named `Atmosphere`.
  The second one is ignored, here and by the engine itself.
- The `Desert` map's `DisplayName` is `"Dessert"` in `MapConfig`.
