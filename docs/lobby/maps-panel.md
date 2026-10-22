# Maps panel

The panel where a player picks the map for the next match (`StarterGui.ChooseMaps`), opened from the portals.
The same ScreenGui also holds the [community maps panel](community-maps.md), opened from the build portals.

**Runs in:** Lobby
**Code:** [`ChooseMapsController`](../../Lobby/src/Controllers/ChooseMapsController.luau), [`PortalController`](../../Lobby/src/Controllers/PortalController.luau), [`PortalService`](../../Lobby/src/Services/PortalService.luau), [`MapConfig`](../../common/shared/Config/SharedConfig/MapConfig.luau)

## How it works

Each map card is a clone of the `ChooseMaps.Lobby.Scroll.Map` template.
The chosen map is marked by the **`CheckMark`** frame authored in the template: `ChooseMapsController` only toggles its `Visible`.
A template without `CheckMark` still works, with nothing to light.
The chosen card also grows a little (`UIScale`).

While the panel is open, the rest of the Lobby UI leaves the screen (see [Interface visibility](../common/interface-visibility.md)).

### Maps unlock with wins

Each map requires a number of **wins** (`WinsRequired` in `MapConfig.MAPS`), shown by the `Locked` frame authored in each template.
The controller turns on its `Visible`, disables the button underneath (`Active` and `AutoButtonColor`), and writes the remaining wins in its `MaxPlrs` label.

| # | Map | `WinsRequired` |
| ---: | --- | ---: |
| 1 | Farm | open |
| 2 | Desert | 2 |
| 3 | Snowy | 3 |
| 4 | Snowy Castle | 4 |
| 5 | Mountains | 5 |
| 6 | Cave | 6 |
| 7 | Volcano | 8 |
| 8 | Beach | 11 |
| 9 | Swamp | 13 |
| 10 | Pale Garden | 16 |

- **All three change together**: a live button under a drawn padlock would be a map that looks locked and opens on click.
  `Active = false` already stops `Activated`; `Select` checks again because it is public API.
- **The text counts what is missing**: `"2 MORE WINS REQUIRED"` with zero wins, `"1 MORE WINS REQUIRED"` with one.
- **The list order is `WinsRequired` itself.**
  `getOrderedMaps` sorts by wins and breaks ties by key, and each card's `LayoutOrder` is its position.
  A new 7-win map slots between Cave and Volcano by itself.
- **The lock repaints by itself.**
  Wins come from the replica (`Stats.Wins`), through the `OnChange` of `Stats`, so a player returning with one more win sees the map unlock without reopening the panel.
  Without a replica yet, wins count as zero.
- **The lock is not just a drawing.**
  The client picks the map, and a map name is something any client can send, so `PortalService:CreateGroup` checks the same rule with the same config before opening the group.
  The client makes the choice; the server grants the permission, as with deck slots and level.
