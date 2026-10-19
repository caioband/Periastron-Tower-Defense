# Map Editor place

The Map Editor place: an in-game builder where players lay out a map, draw the enemy routes, check them, playtest them, and export the result in the format the Game loads from `ServerStorage.Maps`.

For the repository layout and what is shared between the places, see [Repository overview](../architecture/overview.md).

## Not on the framework (yet)

Unlike the Lobby, the Game, and the AFK place, the Map Editor does not mount `common/` or `vendor/` and does not use the [`Me` framework](../architecture/me-framework.md):

- The server starts from its own `Main` Script, not from `ServerScriptService.Server`, and requires its modules directly.
- Client and server talk through their own remotes, `ReplicatedStorage.MapEditor.Remotes.Request` (a RemoteFunction) and `Push` (a RemoteEvent), which `Main` creates on start. Warp is not used.
- Maps live in a DataStore of their own (`Config.DATASTORE_NAME`), not in the player profile.
- Logs go through `warn`, not `Shared.Util.Log`.

For the same reason the place has no `wally.toml` and no `Packages/`: nothing it runs comes from Wally.

`Shared/PathUtil.luau` and `Shared/PlacementUtil.luau` are trimmed copies of `common/shared/Util/PathUtil.luau` and `PlacementUtil.luau` (no `Log`, no comments).
The editor uses them to validate and playtest routes exactly as the Game's `MobService` walks them, so keep them in step when the originals change.

## What is specific to this place

| Folder | Mounted at | Contents |
| --- | --- | --- |
| `src/ClientBoot/` | `StarterPlayerScripts.MapEditor` | Entry LocalScript (`init.client.luau`) and the editor modules under it: `Editor`, `UI`, `State`, `History`, `Selection`, `Placement`, `Gizmos`, `RouteView`, `BuildCamera`, `Geometry`, `Net`, `Signal`, `Maid` |
| `src/Server/` | `ServerScriptService.MapEditor` | `Main` (entry Script and request handlers), `SessionService`, `MapStore`, `MapValidation`, `PlaytestService`, `PeriMapAdapter`, `TemplateBuilder`, `RateLimiter` |
| `src/Shared/` | `ReplicatedStorage.MapEditor` | Code and config the server and the client both read: `Config`, `Catalog`, `PeriAssets`, `Serializer`, `RouteModel`, `MapRules`, `InstanceFactory`, `PathUtil`, `PlacementUtil` |

`src/ClientBoot/` keeps the editor modules next to `init.client.luau` because they are children of the LocalScript in the place (`script:WaitForChild("Editor")`, `script.Parent.<Module>`).
Likewise, `Main` reaches the server modules through `script.Parent`.

The nodes keep the names the place already uses (`MapEditor`), so syncing into the existing place replaces its scripts instead of creating a second copy.

## Outside the repository

Everything that is not code lives only in the place:

- `ServerStorage.MapEditorAssets`: the props copied from the Game's maps (`Peri`, one child per prop, listed through `PeriAssets`) and optional overrides for the catalog's building blocks.
  On start, `TemplateBuilder` turns them into `ReplicatedStorage.MapEditor.Templates`.
  The two `Script`s inside `MapEditorAssets.Peri.RadioStand` belong to that model, so they stay in the place too.
- `ServerStorage.MapEditorImports`: Game-format map folders the editor can import.
  Exports go to `ServerStorage.MapEditorExports`, which `Main` creates when missing.
- The map, lighting, and any GUI not built by `UI`.

## Running it

```bash
cd MapEditor && rojo serve
```

In Studio without API access, `MapStore` keeps maps in memory for the session and says so in the Output and in a toast.
Enable **Game Settings > Security > Enable Studio Access to API Services** to save for real.
