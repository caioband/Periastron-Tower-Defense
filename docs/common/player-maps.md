# Player maps

The maps players build in the Map Editor, and the API every place uses to find and read them by key.

**Runs in:** AFK · Game · Lobby · Map Editor (server only)
**Code:** [`PlayerMapService`](../../common/server/Services/PlayerMapService.luau), [`Config.PlayerMaps`](../../common/server/Config/PlayerMaps.luau), [`Config.Data`](../../common/server/Config/Data.luau) (`Template.PlayerMaps`), [`MapStore`](../../MapEditor/src/Server/MapStore.luau) (editor)

## How it works

A player map is split in two:

- **The index** lives in the player's profile, under `PlayerMaps`.
  It says which maps and prefabs the player owns (name, dates, object count) and which maps they marked.
  It goes through `DataService`, so it is saved, replicated, and session-locked like the rest of the profile.
- **The content** lives in its own DataStore, `Config.PlayerMaps.STORE_NAME`, one key per map or prefab.
  The key carries the owner, so any place can read a map from the key alone, without opening the owner's profile.

```lua
PlayerMaps = {
    Maps = { [mapId] = { Name, Created, Modified, Count, Published? } },  -- maps this player created
    Prefabs = { [prefabId] = { Name, Created, Count } },                  -- their prefabs
    Favorites = { [mapKey] = { Added } },                                 -- keys of any map, theirs or another player's
    Likes = { [mapKey] = { Added } },                                     -- community maps they liked
}
```

### Keys

| Kind | Key | Content |
| --- | --- | --- |
| Map | `map_<userId>_<mapId>` | The encoded map (`Serializer.encodeMap` in the editor) |
| Prefab | `prefab_<userId>_<prefabId>` | `{ v, id, name, owner, objects }` |

Build keys with `PlayerMapService.MapKey` / `PrefabKey` and read them with `ParseKey`; never assemble one by hand.
An id is 1 to 24 letters, digits, `_`, or `-` (`ValidId`).

Every write passes the owner's user id to `UpdateAsync`, so a GDPR erasure request for that player finds their maps.

### Content first, index second

The editor writes the content and only then the index entry.
If the content save fails, the list never shows a map that is not on disk.
If the index write fails after the content landed, the map is on disk but not listed; saving again fixes it.

Deleting goes the other way: the entry leaves the index first, then the content is removed.
Content left behind by a failed removal is only wasted space.

### Saving when the player leaves

The editor saves an open map on leave and on shutdown through `DataService:OnBeforeRelease`, which runs while the profile is still open.
A plain `PlayerRemoving` would race `DataService`'s own and could write the index after the session closed.
On shutdown the editor's `BindToClose` keeps the server up (up to 25 s) until those saves land.

### Studio without API access

When the DataStore cannot be opened in Studio, the content is kept in memory and `UsingMemory` is `true`; the editor warns the player.
Everything is gone when the server stops.
The profile goes through ProfileStore's own mock in that case.

`Published` and `Likes` belong to the community catalog; see [Community maps](community-maps.md).

## Configuration

`Config.PlayerMaps` (server only):

| Key | Default | Effect |
| --- | --- | --- |
| `STORE_NAME` | `"PlayerMaps_v1"` | The DataStore with the content. Changing it orphans every saved map. |
| `RETRIES` | `3` | Attempts per DataStore call, with 1 s, 2 s, ... between them |
| `MAX_VALUE_BYTES` | `3_800_000` | Largest value written to one key (Roblox refuses over 4 MB) |
| `MAX_FAVORITES` | `200` | Entries in `PlayerMaps.Favorites` |

How many maps and prefabs a player may keep is the editor's rule: `MAX_MAPS_PER_PLAYER` and `MAX_PREFABS` in `ReplicatedStorage.MapEditor.Config`.

## Usage

```lua
local PlayerMapService = Framework:Get("PlayerMapService")

-- Keys
local key = PlayerMapService.MapKey(userId, mapId)       -- "map_123_abc", or nil for a bad id
local info = PlayerMapService.ParseKey(key)              -- { Kind = "map", UserId = 123, Id = "abc" }

-- Content, from any place
local ok, value = PlayerMapService:GetAsync(key)          -- value is nil when nothing is stored
local values, failed = PlayerMapService:GetManyAsync({ keyA, keyB })
local ok, reason, detail = PlayerMapService:SetAsync(key, value)
local ok, reason = PlayerMapService:RemoveAsync(key)

-- Index of a player on this server
local data = PlayerMapService:GetData(player)            -- read only; nil while the profile is not open
local data = PlayerMapService:AwaitData(player, 10)
PlayerMapService:Update(player, function(value)
    value.Maps[mapId].Name = "New name"
    return value
end)

-- Index of anyone (live if they are here, otherwise their saved profile)
local ok, data = PlayerMapService:GetPlayerDataAsync(userId)

-- Favorites (map keys only)
PlayerMapService:AddFavorite(player, key)                -- false, "Full" at MAX_FAVORITES
PlayerMapService:RemoveFavorite(player, key)
PlayerMapService:IsFavorite(player, key)
```

Failed async calls answer `false, reason, detail`, with `reason` from `PlayerMapService.REASONS`:

| Reason | Meaning |
| --- | --- |
| `InvalidKey` | Not a `map_` / `prefab_` key (or, for favorites, not a map key) |
| `Unavailable` | The DataStore could not be opened |
| `TooLarge` | Over `MAX_VALUE_BYTES`; `detail` is the size in bytes |
| `NotEncodable` | The value cannot become JSON |
| `Failed` | Every retry failed; `detail` is the last error |
| `NotLoaded` | The player's profile is not open on this server |
| `Full` | `Favorites` is at `MAX_FAVORITES` |

### Adding to the index

A new list goes in as one more key under `Template.PlayerMaps`; reconcile creates it on older profiles.
A new field goes inside an entry's table, so no migration is needed.
Write the profile only through `PlayerMapService:Update`, or the replica and `DataService.Signals.DataUpdated` never hear about it.

## Design notes

- **Why the content is not in the profile.** A map can reach megabytes, and the profile, which every system shares, has a 4 MB ceiling.
  Out of the profile, a map is also readable from any place without a session on the owner's profile.
- **Why one key per prefab.** It lets a prefab be read by key like a map.
  The editor reads them all at once (`GetManyAsync`) the first time and caches the list per player; only the server holding the player's profile writes their content, so the cache cannot go stale.
- **Decoding stays in the editor.** The service stores the content as given; `Serializer` in `ReplicatedStorage.MapEditor` knows the format.
  A place that needs to build a map from its content has to share that code first.

## Known issues

- If the profile is lost while the player is in the editor (another server took it), the leave save fails for lack of an index, and the last changes since the previous save are lost.
