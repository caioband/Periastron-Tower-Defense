# Map cutscenes

A map can play a [cutscene](../common/cutscenes.md) before its first round (the **intro**) and another when a player goes back to the Lobby after a win (the **outro**).
The match waits for them: the difficulty vote opens after the intro, and the teleport leaves after the outro.

**Runs in:** Game
**Code:** [`MapCutsceneService`](../../Game/src/Services/MapCutsceneService.luau), [`MapCutsceneController`](../../Game/src/Controllers/MapCutsceneController.luau), [`WaveService`](../../Game/src/Services/WaveService.luau)

## How it works

### Intro

1. `WaveService:runRound` waits for the players and for the map, then calls `MapCutsceneService:PlayIntro()`, which yields.
2. The service looks up the map in `MAP_CUTSCENES`.
   It returns at once for a community map, a map without an intro, or a second round on the same server.
3. It clones the baked scene from `ServerStorage.Cutscenes` into `ReplicatedStorage.Cutscenes`, with a `DescendantCount` attribute.
   Then it fires `PlayMapCutscene` (scene name, token) to every player.
4. The service returns once every player answers `MapCutsceneFinished` or leaves.
   Then it destroys the replicated clone, and the vote opens.

### Outro

1. On the results screen, the Lobby button fires `RequestLobbyTeleport`, and `WaveService:sendToLobby` calls `MapCutsceneService:PlayOutro(player)`.
   The outro only plays if the match was **won**: the service records how it ended from `WaveService.Signals.MatchFinished` (`won`), which fires before the results screen reaches anyone.
   After a loss, `PlayOutro` returns at once and the teleport leaves as before.
2. The outro plays for **that player alone**, and the teleport leaves when it returns.
   Players who leave together each get their own session.
3. It plays once per player.
   If the teleport fails and the player clicks again, the request goes straight to the teleport.
   A second click while the outro is playing is ignored (`PlayOutro` answers `false`), and the first request teleports.

The outro's clone is replicated when a won match ends, so it has already arrived when someone clicks.
It stays until the server closes, because anyone may leave from then on.

The outro ends on black: the screen fades to black in the scene's last half second and stays black until the teleport takes the player.
Without that, the results screen would show again for a moment between the scene and the teleport.
If the teleport fails (`LobbyTeleportFailed`), the black screen goes away and the Lobby button comes back.

### On the client

`MapCutsceneController` handles both cutscenes the same way:

1. It waits for the scene to finish replicating and for the loading screen to leave.
2. If the scene has a `PlayerRig` attribute, it dresses that rig as its own player (see [Dressing a rig as the player](../common/cutscenes.md#dressing-a-rig-as-the-player)).
   Each player sees themselves in the rig.
3. It plays the scene `STAGE_OFFSET` studs away from where it was authored, far from every map.
4. It answers `MapCutsceneFinished` with the token.

A client always answers, even when the scene fails to replicate or play.
If a client never answers, the server gives up after the scene's `Duration` plus `LOAD_MARGIN`.

Warp drops an event that reaches a client before its `Listen` exists.
So the client also fires `RequestMapCutscene` once it listens, and the server sends again every cutscene that client is still owed.
The token keeps the client from playing one twice.

## Configuration

| Key | Value | Effect |
| --- | --- | --- |
| `MAP_CUTSCENES` (service) | `AutumnValley` → Intro `Cutscene1_Perieperifall`, Outro `Cutscene2_Part4` | Which baked scenes each map plays |
| `LOAD_MARGIN` (service) | `45` s | Extra time the server waits beyond the scene's `Duration` |
| `STAGE_OFFSET` (controller) | `(6000, 0, 6000)` | How far from its authored spot the scene plays |
| `REPLICATION_TIMEOUT` (controller) | `30` s | How long the client waits for the scene to arrive |
| `LOADING_TIMEOUT` (controller) | `60` s | How long the client waits for the loading screen to leave |

## Studio setup

- The sources live in `ServerStorage.CutsceneSources`, and the baked scenes in `ServerStorage.Cutscenes`.
  See [Cutscenes](../common/cutscenes.md#studio-setup) for how to assemble and bake them.
- `PlayerRig` (string attribute on the source scene) names the rig that becomes the player.
  `Cutscene1_Perieperifall` has `PlayerRig = "numsei1"`.
  The bake copies it to the baked scene.
- To test in Studio, set `StudioMap = "AutumnValley"` on `ServerStorage.Maps` (see [Maps](maps.md#picking-the-map)).

## Known issues

- The map music keeps playing under the cutscenes.
- There is no skip button yet.
- A player who joins while the intro is playing does not see it.
- The play-again vote counts everyone still in the server, so a player watching the outro holds a restart until their teleport leaves.
