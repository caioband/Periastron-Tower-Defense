# Map Editor place

The Map Editor place: an in-game builder where players lay out a map, draw the enemy routes, check them, playtest them, and export the result in the format the Game loads from `ServerStorage.Maps`.
Each universe has its own copy (`EnvironmentConfig`: `MapEditor = 131485363672766` in QA, `70918383889606` in Production).

For the repository layout and what is shared between the places, see [Repository overview](../architecture/overview.md).

## How it is put together

The **server** mounts `common/` and `vendor/` like the other places: every Service in `common/server/Services` loads, `DataService` opens the player's profile, and `PlayerMapService` stores the maps (see [Player maps](../common/player-maps.md)).
The editor itself is not a framework Service: it starts from its own `Main` Script, which takes `DataService` and `PlayerMapService` from `Me` and requires its modules directly.

The **client** does not run the framework.
The editor's LocalScript is the only client code, so no Controller from `common/client/Controllers` loads here.
Those Controllers wait on `ReplicatedStorage.Shared.Assets`, which this place does not have.
Because nothing fires `Loaded`, `Config.Data.Places.MapEditor` has `WaitForClient = false`.

Inside the editor, nothing else changed:

- Client and server talk through their own remotes, `ReplicatedStorage.MapEditor.Remotes.Request` (a RemoteFunction) and `Push` (a RemoteEvent), which `Main` creates on start. Warp is not used.
- Logs still go through `warn`, not `Shared.Util.Log`.

`common/mapeditor/PathUtil.luau` and `PlacementUtil.luau` are trimmed copies of `common/shared/Util/PathUtil.luau` and `PlacementUtil.luau` (no `Log`, no comments).
The editor uses them to validate and playtest routes exactly as the Game's `MobService` walks them, so keep them in step when the originals change.

`src/Server/PlaytestCombat.luau` is the same kind of copy for combat: a port of the Game's `UnitService`, the enemy half of `MobService`, `BardService:Step` and `NecromancerService`, so towers in a playtest hit as hard, as often and as widely as in a match. A combat change in the Game must be mirrored there.
It leaves out what a playtest has none of: weather, round cards, the thunder charge and game speed. Attack effects are the Game's own: the server sends `PlaytestFx` pushes and the client's `PlaytestVFX` plays them through the Game's `VFXController`, `ProjectileController`, `TripmineController` and `BonfireController`, which the project mounts under `StarterPlayerScripts.MapEditor.GameVFX` (plus an empty `StarterPlayerScripts.Client.Controllers`, so the Me framework they require starts on the editor client). `VFXController` also needs `ReplicatedStorage.vfx`, the third-party VFX module the Game's place keeps in Studio; the editor gets a copy from `vendor/vfx` (unmodified: its license requires that). If the Game's copy is updated, copy it into `vendor/vfx` again. On a Bard, the upgrade card's priority button swaps the song instead.
Where a test tower may stand is `common/mapeditor/TowerFootprint.luau`, the Game's placement rules (path, obstruction, spacing by model width, characters), asked by both the ghost and the server.
The loadout offers every unit with stats and a model, except those in `Config.PLAYTEST_EXCLUDED_UNITS` (the Azure today); the server refuses them too.

## What is specific to this place

| Folder | Mounted at | Contents |
| --- | --- | --- |
| `src/ClientBoot/` | `StarterPlayerScripts.MapEditor` | Entry LocalScript (`init.client.luau`) and the editor modules under it: `Editor`, `UI`, `State`, `History`, `Selection`, `Placement`, `Gizmos`, `RouteView`, `BuildCamera`, `Geometry`, `Net`, `Signal`, `Maid` |
| `src/Server/` | `ServerScriptService.MapEditor` | `Main` (entry Script and request handlers), `SessionService`, `MapStore`, `MapValidation`, `PlaytestService`, `PlaytestCombat`, `RateLimiter` |
| `../common/mapeditor/` | `ReplicatedStorage.MapEditor` | Code and config the server and the client both read: `Config`, `Catalog`, `PeriAssets`, `Serializer`, `RouteModel`, `MapRules`, `InstanceFactory`, `PathUtil`, `PlacementUtil`, `TowerFootprint`, and the server-only `PeriMapAdapter` and `TemplateBuilder` |

`common/mapeditor` is also mounted in the Game, at `ServerStorage.MapEditor`, which builds published maps with the same code (see [Community matches](../game/community-matches.md)).
`PeriMapAdapter` and `TemplateBuilder` find their siblings through `script.Parent`, so they work in both places; `Templates` is built next to them.

`src/ClientBoot/` keeps the editor modules next to `init.client.luau` because they are children of the LocalScript in the place (`script:WaitForChild("Editor")`, `script.Parent.<Module>`).
Likewise, `Main` reaches the server modules through `script.Parent`.

The nodes keep the names the place already uses (`MapEditor`), so syncing into the existing place replaces its scripts instead of creating a second copy.
The `Services` node sets `Place = "MapEditor"`.

There are no place-specific Services, Controllers, or Cmdr definitions, so the project has no `Services.MapEditor`, `Controllers`, `Commands.MapEditor`, or `Types.MapEditor` node.

## Saving

`MapStore` keeps the list of maps and prefabs in the profile (`PlayerMaps`) and their content in the shared DataStore, one key per item; see [Player maps](../common/player-maps.md).

- **Save** (button or Ctrl+S) writes the map. There is a 6 s cooldown between saves.
- **Autosave** runs every `AUTOSAVE_INTERVAL` (120 s) while building, once the map has been saved by hand at least once.
- **Exit** saves before leaving and refuses to leave if the save fails.
- **Leaving the game and shutdown** save through `DataService:OnBeforeRelease`, with the profile still open.

A map that was never saved by hand is not saved on autosave or on leave: the player has to press Save once.

Entering the editor waits up to 10 s for the profile; without it, the editor answers "Your data is still loading".

In Studio without API access, the content stays in memory until the server stops, and the editor says so in a toast and in the status bar.
Enable **Game Settings > Security > Enable Studio Access to API Services** to save for real.

## Publishing

The **Publish** button on a row of **My Maps** lists that map in the Lobby's Community Maps, with an optional description; see [Community maps](../common/community-maps.md).

- Only the open map can be published, and only once it is saved with no unsaved changes, no validation errors, and the whole enemy route on Path pieces.
  The Game hides an enemy that is not over a Path piece (`MobController` checks for a `Grid` part under it), so a spawn or base on the grass means enemies that never show.
- Saving a published map whose route leaves the Path pieces warns in a toast: the Game plays the saved content at once.
  On errors, the validation panel opens.
- A published row shows **Unpublish** instead, which takes the map out of the catalog and keeps its likes for the next publish.
- Saving or renaming a published map updates its name and object count in the catalog.
- Deleting a published map also removes it from the catalog.

A player sent here by the edit button of the Lobby's Community Maps (`TeleportData.OpenMap`) enters build mode with that map loaded.

**Exporting is not saving.** "Export current to Peri format" (developers only) builds a Game-format folder in `ServerStorage.MapEditorExports`, which only lasts while the server runs.

## Shared systems here

Every Service in `common/server/Services` loads here.
Systems that need content from the place (a board, a part reference, a GUI) log a warning and stay idle when it is missing, as they do in the other places.

- **Data.** `DataService` runs with the `MapEditor` entry of `Config.Data.Places`: `Get` answers as soon as the profile is open.
- **Playtime.** `PlaytimeService` does nothing here: time in the editor stays out of `Stats.TimePlayed`.
- **Leaderboards.** No board has `Place = "MapEditor"`, so nothing is drawn.

## Wally

The same four dependencies as the other places, with `wally.lock` pinned to the same resolved versions (Cmdr 1.12.0, Signal 2.0.3).
Only the server uses them here.

## Outside the repository

Everything that is not code lives only in the place:

- `ServerStorage.MapEditorAssets`: the props copied from the Game's maps (`Peri`, one child per prop, listed through `PeriAssets`) and optional overrides for the catalog's building blocks.
  On start, `TemplateBuilder` turns them into `ReplicatedStorage.MapEditor.Templates`.
  The folder is a Package, shared with the Game, which builds community maps from it.
  The two `Script`s inside `MapEditorAssets.Peri.RadioStand` belong to that model, so they stay in the place too.
- `ServerStorage.MapEditorImports`: Game-format map folders the editor can import.
  Exports go to `ServerStorage.MapEditorExports`, which `Main` creates when missing.
- The map, lighting, and any GUI not built by `UI`.

The place does not have the `ReplicatedStorage.Shared` Package: Rojo creates `Shared` as a plain Folder with the code only, and `Shared.Assets` does not exist here.

## Running it

```bash
cd MapEditor && wally install && rojo serve
```
