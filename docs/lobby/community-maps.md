# Community maps panel

The panel where players browse the maps other players published from the Map Editor (`StarterGui.ChooseMaps.CommunityMaps`), opened from the build portals.

**Runs in:** Lobby
**Code:** [`CommunityMapsController`](../../Lobby/src/Controllers/CommunityMapsController.luau), [`PortalController`](../../Lobby/src/Controllers/PortalController.luau), [`CommunityMapService`](../../common/server/Services/CommunityMapService.luau)

The catalog, the counters, and the requests are described in [Community maps](../common/community-maps.md).

## How it works

Walking up to a portal in `Workspace.Map.BuildPortals` opens the panel, with the same animation as the [maps panel](maps-panel.md); walking away closes it.
`PortalController` checks both folders on the same beat and opens whichever panel belongs to the nearest portal.

**PLAY opens a group on the build portal**, like a match portal: `RequestCreateCommunityGroup(portalId, mapKey, playerCount)`.
`PortalService:CreateCommunityGroup` checks the map is still published, then the usual countdown, joining, cutscene, and teleport follow.
The teleport carries `CommunityMap = key` instead of `Map`, and the Game builds the map (see [Community matches](../game/community-matches.md)).
Build portals only take community groups, and challenge groups never take a build portal.
Only where `CommunityMapService:IsEnabled()`: QA always, Production while `PRODUCTION_ENABLED` is on.
While the panel is open, the rest of the Lobby UI leaves the screen (request `CommunityMaps`, see [Interface visibility](../common/interface-visibility.md)).

```text
BuildPortal ─► CommunityMaps
                ├─ tabs: Featured (default) · Your Maps · Favorites
                ├─ FilterTypes: Likes (default) · Visits · Favorites · Plays
                ├─ FilterSortTypes: Descending (default) · Ascending
                ├─ Search: applied when the box loses focus
                ├─ list: 20 maps per page; the next page loads near the bottom
                │    ├─ Like / Favorite: change at once, roll back if refused
                │    └─ arrow (ExpandDetailsButton): fills MapDetails
                └─ MapDetails: objects · visits · favorites · creator · description
                     ├─ PlayerCount: 1 to 4 players
                     ├─ PLAY: only with a map selected; opens the group
                     └─ EditButton: only on the player's own maps; goes to the Map Editor
```

- **Every opening starts over**: Featured, Likes, Descending, empty search, nothing selected.
- **Tabs** keep the filter and the search; the chosen tab grows (`TabScale`, a `UIScale` the controller creates).
- **Filter buttons** are rebuilt from the first `FilterWrapper` / `SortWrapper` in their frame, one per option, labelled by the controller.
  The chosen one wears `FILTER_SELECTED_IMAGE`.
- **Search** looks in the names and authors.
  In Featured it searches the whole catalog; in Your Maps and Favorites it filters those lists.
- **Like and Favorite** swap the button image (`LIKE_IMAGE` / `LIKED_IMAGE`, `FAVORITE_IMAGE` / `FAVORITED_IMAGE`) and the count on the row before the server answers.
  The state comes from the replica (`PlayerMaps.Likes` and `PlayerMaps.Favorites`), so a change made on another server shows too.
- **Opening the details** counts a visit (once per map per server) and keeps the details while the player switches tabs.
- **PLAY** fires `PlayRequested(key, playerCount)`, which `PortalController` sends as the group request.
- **The player count** starts at 1 on every opening.
  An authored `CommunityMaps.PlayerCount` frame (with `LowerPlrs`, `MaxPlrs`, `IncreasePlrs`) is used when there is one; otherwise the controller builds one on the top edge of `MapDetails` from the vanilla panel's controls.
- **EditButton** asks the server (`Edit`) to teleport the owner to the Map Editor with the map open; nothing happens where community maps are disabled.
- **A failed community match** sends the group back with `TeleportData.CommunityMapFailed`, and the panel's controller shows "THAT COMMUNITY MAP COULD NOT BE LOADED" through `WarningController`.
- **Loading, empty, and error** lines are a `Status` label the controller adds at the end of the list.
- A list answer for a tab, filter, or search no longer on screen is dropped (`ListToken`).
- The gamepad's B button closes the panel (registered with `GamepadController:RegisterPanel`).

## Studio setup

The ScreenGui is shared with the vanilla list (`ChooseMaps.Lobby`); each controller only leaves the ScreenGui disabled when the other panel is not visible.

| Instance | Purpose |
| --- | --- |
| `CommunityMaps.MapSelection.FeaturedMapsButton`, `YourMapsButton`, `FavoriteMapsButton` | The tabs |
| `MapSelection.FilterTypes.FilterWrapper.ImageButton.TextLabel` | Template of the counter buttons |
| `MapSelection.FilterSortTypes.SortWrapper.ImageButton.TextLabel` | Template of the direction buttons |
| `MapSelection.Search.TextBox` | The search box |
| `MapSelection.ScrollingFrame.MapWrapper` | Row template; `MapBanner` holds `MapName`, `Likes`, `LikeButton`, `FavoriteButton`, `ExpandDetailsButton`, `MapImage` |
| `CommunityMaps.MapDetails` | `ObjectCount`, `VisitCount`, `FavoriteCount`, `Creator`, `Description` (TextLabels), `PlayButton`, `EditButton` (ImageButtons), `PreviewFrame`, `MapImage` |
| `Workspace.Map.BuildPortals.Portal` | Same parts as a match portal; only `PortalEnterCFrame` is read |

The images of the toggles and filter buttons are constants at the top of `CommunityMapsController`.

`Activated` does not fire on a button with `Active = false`, so the controller switches `Active` on for every button it connects.

## Known issues

- Player maps have no thumbnail: `MapImage` keeps its authored image.
- The player-count stepper is built at runtime until one is authored in `CommunityMaps`.
