# Community maps

The catalog of maps players published from the Map Editor: what other players see of each map, its counters, and the orderings the Lobby lists them by.

**Runs in:** Lobby · Map Editor (server only); the service loads in every place but only those two call it
**Code:** [`CommunityMapService`](../../common/server/Services/CommunityMapService.luau), [`Config.CommunityMaps`](../../common/server/Config/CommunityMaps.luau), [`Config.Data`](../../common/server/Config/Data.luau) (`Template.PlayerMaps.Likes`)

The Lobby panel is described in [Community maps panel](../lobby/community-maps.md); publishing, in the [Map Editor](../mapeditor/README.md#publishing).
The map content itself stays where [Player maps](player-maps.md) puts it.

## How it works

Publishing is opt-in: only maps their owner published appear, never every saved map.

Three stores, all named after `Config.CommunityMaps.STORE_NAME`:

| Store | Key | Content |
| --- | --- | --- |
| DataStore `<STORE_NAME>` | the map key (`map_<userId>_<mapId>`) | The entry: `Name`, `Description`, `OwnerName`, `Owner`, `Count` (objects), `Published`, `Updated`, `Listed`, and one number per counter |
| DataStore `<STORE_NAME>` | `catalog` | `{ [mapKey] = { N = name, O = author } }` for every listed map, which search reads |
| OrderedDataStore `<STORE_NAME>_<Stat>` | the map key | The same counter as the entry, which sorts the Featured tab |

The counters are `Config.CommunityMaps.STATS`: `Likes`, `Visits`, `Favorites`, and `Plays`.

On the player's side, in the profile through `PlayerMapService`:

- `PlayerMaps.Maps[mapId].Published` is the time the map went public, and is absent while it is not.
- `PlayerMaps.Likes` holds the keys of the maps the player liked, capped at `MAX_LIKES`.
- `PlayerMaps.Favorites` is the list that already existed, capped at `MAX_FAVORITES`.

### Publishing and unpublishing

- **Publish** filters the name and the description with `TextService`, writes the entry (keeping the counters of a map published before), writes every ordering, adds the map to the catalog, and stamps `Published` in the profile.
- **Saving or renaming** a published map updates its name and object count in the entry, and the catalog when the name changed (`Refresh`).
- **Unpublish** removes the map from the orderings and the catalog and marks the entry `Listed = false`.
  The counters stay, so publishing again keeps the likes.
- **Deleting** a published map unpublishes it and erases the entry.

### Counters are buffered

A like, a favorite, or a visit changes the profile at once but only adds to `Deltas` on the server.
Every `FLUSH_INTERVAL` (and on shutdown) each map gets one `UpdateAsync` with the sum, then its orderings get the new totals.
A failed write keeps its changes for the next flush; a map that is no longer listed drops them.
What the server sends adds its own pending deltas, so a player sees their click land immediately.

- **Likes** and **favorites** count +1 / −1 when the player's state flips; liking or favoriting twice does not count twice.
- **Visits** count when a player opens a map's details, once per player, map, and server.
- **Plays** count once per Game server that loads the map (see [Community matches](../game/community-matches.md)).

### Listing

`List(player, { Tab, Stat, Ascending, Search, Page })` answers `{ Maps, Page, HasMore }`, `PAGE_SIZE` maps at a time.

| Tab | Source | Sorted by |
| --- | --- | --- |
| `Featured` | The OrderedDataStore of `Stat` | The DataStore, in `Ascending` order |
| `Featured` with a search | The catalog: names and authors that contain the text | In memory |
| `YourMaps` | The player's own maps with `Published` | In memory |
| `Favorites` | The player's `Favorites` | In memory |

A search inside `YourMaps` or `Favorites` filters those lists by name and author.
Unlisted maps (unpublished since being marked) are skipped.

Reads are cached for every player on the server: a sorted listing for `QUERY_CACHE_TIME`, a map's entry for `META_CACHE_TIME`, and the catalog for `QUERY_CACHE_TIME`.
Another server sees a new map or new totals once its copy expires.

### Network

The client sends `CommunityMapsRequest(requestId, action, payload)` and gets `CommunityMapsResponse({ Id, Ok, Data, Reason })`.
Warp does not order events, so the client matches answers by `Id`.

| Action | Payload | Answer |
| --- | --- | --- |
| `List` | `{ Tab, Stat, Ascending, Search, Page }` | `{ Maps, Page, HasMore }` |
| `Like` | `{ Key, Value }` | Whether the player likes it now |
| `Favorite` | `{ Key, Value }` | Whether it is a favorite now |
| `Visit` | `{ Key }` | Nothing |
| `Edit` | `{ Key }` | Nothing; the owner is teleported to the Map Editor with `TeleportData.OpenMap` |

A map sent to the client is `{ Key, Name, Description, Creator, Owner, Count, Published, Likes, Visits, Favorites, Plays }`.
A player may have `MAX_PENDING_REQUESTS` requests waiting on the DataStore; more answer `Busy`, and the client retries.

### Studio without API access

As in [Player maps](player-maps.md), the stores fall back to memory and `UsingMemory` is `true`.
The Lobby and the Map Editor are separate servers, so a map published in a Studio editor session does not show in a Studio Lobby session.

## Configuration

`Config.CommunityMaps` (server only):

| Key | Default | Effect |
| --- | --- | --- |
| `STORE_NAME` | `"CommunityMaps_v1"` | Name of the entry store and prefix of the ordered stores. Changing it empties the catalog. |
| `CATALOG_KEY` | `"catalog"` | The entry with every listed map's name and author |
| `STATS` | `Likes`, `Visits`, `Favorites`, `Plays` | Counters and orderings. The Lobby's filter buttons use the same names. |
| `DEFAULT_STAT` / `DEFAULT_ASCENDING` | `"Likes"` / `false` | What a request without a valid order gets |
| `PAGE_SIZE` | `20` | Maps per page |
| `QUERY_CACHE_TIME` | `60` | Seconds a sorted listing and the catalog are reused |
| `META_CACHE_TIME` | `60` | Seconds a map's entry is reused |
| `FLUSH_INTERVAL` | `30` | Seconds between counter writes |
| `RETRIES` | `3` | Attempts per DataStore call |
| `MAX_LIKES` | `1000` | Entries in `PlayerMaps.Likes` |
| `MAX_SEARCH_LENGTH` | `40` | Longest search text |
| `MAX_DESCRIPTION_LENGTH` | `200` | Longest description |
| `MAX_SEARCH_RESULTS` | `100` | Maps a catalog search can answer |
| `MAX_PENDING_REQUESTS` | `2` | Requests per player waiting on the DataStore |
| `PRODUCTION_ENABLED` | `false` | Whether community groups and the edit button work outside QA (`IsEnabled`) |
| `REWARD_MULTIPLIER` | `0.5` | What a community match pays (see [Community matches](../game/community-matches.md)) |

## Usage

```lua
local CommunityMapService = Framework:Get("CommunityMapService")

-- Map Editor
CommunityMapService:Publish(player, mapId, { Name = name, Description = text, Count = objects })
CommunityMapService:Refresh(player, mapId, { Name = name, Count = objects })
CommunityMapService:Unpublish(player, mapId)          -- keeps the counters
CommunityMapService:Unpublish(player, mapId, true)    -- the map was deleted
CommunityMapService:IsPublished(player, mapId)

-- Anywhere on the server
CommunityMapService:List(player, { Tab = "Featured", Stat = "Visits", Ascending = false, Page = 1 })
CommunityMapService:SetLiked(player, key, true)
CommunityMapService:SetFavorite(player, key, false)
CommunityMapService:Visit(player, key)
CommunityMapService:CountPlay(key)                    -- the Game, once per match
CommunityMapService:GetListedEntry(key)               -- entry, or nil and why
CommunityMapService:IsEnabled()                       -- QA, or PRODUCTION_ENABLED
CommunityMapService:Edit(player, key)                 -- owner to the Map Editor
```

Failures answer `false, reason`, with `reason` from `CommunityMapService.REASONS` (`InvalidKey`, `NotSaved`, `NotFound`, `NotLoaded`, `Full`, `Filtered`, `Failed`, `Busy`, `Invalid`, `Disabled`, `NotOwner`).

## Design notes

- **Why OrderedDataStores.** Sorting every published map by a counter is the one thing a DataStore cannot do; one ordered store per counter pages through them in either direction.
- **Why a catalog entry for search.** DataStores cannot search text, and reading every entry to search would cost one read per map.
  Names and authors only change on publish, rename, and unpublish, so a single key holds up to tens of thousands of maps without write contention.
- **Why buffer the counters.** A popular map would otherwise take one write per click from every server, beyond the per-key write limit.
- **Why the description is filtered at publish.** The text is shown to everyone, and filtering once keeps the Lobby from calling the filter for every row it shows.

## Known issues

- The catalog keeps the author's name as it was at publish; a renamed account shows the old name until the map is published again.
- A GDPR erasure finds the entries (they carry the owner's user id), but not the author's name inside the shared catalog entry.
- The Featured tab may show a page with fewer than `PAGE_SIZE` maps when entries in the ordering were unpublished on another server and that server's ordering removal failed.
