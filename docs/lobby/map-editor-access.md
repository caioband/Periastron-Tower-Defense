# Map Editor access

A prompt by the build portals sends the player straight to a private server of the Map Editor (build mode) of the current environment, with no map open.

**Runs in:** Lobby (server)
**Code:** [`MapEditorTeleportService`](../../Lobby/src/Services/MapEditorTeleportService.luau)

## How it works

Triggering `Workspace.Map.BuildPortals.MapEditorAccess.ProximityPrompt` teleports the player to a new private server (`ShouldReserveServer`) of `Environment.GetPlaceId("MapEditor")`, for them alone, so a QA Lobby sends to the QA editor and Production to Production (see [Environments](../common/environments.md)).
The server ignores repeat triggers from the same player for 10 seconds, and logs (in every server) the environment and the place id it sent the player to.
In Studio the prompt only warns, since teleports do not work there.

The prompt is turned off when:

- the environment has no `MapEditor` id in `EnvironmentConfig`, or
- community maps are disabled there (`CommunityMapService:IsEnabled()`: QA always, Production while `CommunityMaps.PRODUCTION_ENABLED` is on), the same switch as the panel's Edit button.

The Edit button in the [Community maps panel](community-maps.md) also goes to the Map Editor, but opens one of the player's maps (`TeleportData.OpenMap`); this prompt opens none.

`MapEditorAccess` is a `Part`, so `PortalService` and `PortalController`, which only take the `Model`s of `BuildPortals`, never treat it as a portal.

## Configuration

The names are constants at the top of `MapEditorTeleportService`, not in `SharedConfig`, because only the Lobby has the prompt.

| Constant | Default | Effect |
| --- | --- | --- |
| `MAP_NAME`, `FOLDER_NAME`, `PART_NAME`, `PROMPT_NAME` | `Map`, `BuildPortals`, `MapEditorAccess`, `ProximityPrompt` | Where the prompt is |
| `WAIT_TIMEOUT` | `30` | Seconds to wait for each of them before giving up with a warning |
| `TELEPORT_COOLDOWN` | `10` | Seconds before the same player can trigger the teleport again |

## Studio setup

The part, its `BillboardGui`, and the prompt are authored in the Lobby map; the prompt's text and distance are set there.
