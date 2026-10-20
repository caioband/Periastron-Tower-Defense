# Data and profiles

Every place runs the same `DataService`, from `common/server/Services`: one ProfileStore session per player, replicated to that player through Replica, and a single hook for anything that must happen before the session closes.

**Runs in:** AFK · Game · Lobby · Map Editor
**Code:** [`DataService`](../../common/server/Services/DataService.luau), [`ProfileEditService`](../../common/server/Services/ProfileEditService.luau), [`DataController`](../../common/client/Controllers/DataController.luau), [`Config.Data`](../../common/server/Config/Data.luau)

## How it works

### Sessions

`DataService:CreatePlayer` opens the session `Player_<UserId>` in the ProfileStore named by `Config.Data.PROFILE_KEY` (today `PROD_KEY_2`).
The profile is reconciled against `Config.Data.Template`: missing keys are created, existing ones are left alone.
A Replica (`PlayerData`) carries the data to the player's client, where `DataController` exposes it (`ReplicaLoaded`).

- A player who leaves while the profile is loading has the session released at once, instead of it staying locked until the server closes.
- `DataService` registers a `MessageHandler` on every session, which is how edits from other servers arrive (see below).
- If the session ends while the player is still on the server (another server took the profile), the player is **kicked** with "Your data was opened somewhere else. Please rejoin."
  Otherwise they would keep playing without anything being saved.
  This does not fire during shutdown, where `BindToClose` closes the sessions.

### Reading and writing

```lua
DataService:Get(player, function(data) ... end)            -- waits for the profile
DataService:Update(player, "Stats", function(stats)          -- read-modify-write
    stats.Cash += 100
    return stats
end)
```

`Update` warns and does nothing if the profile is not loaded, and keeps the existing data if the callback returns `nil`.

`DataService:Save(player)` forces a save and **yields until it is on disk** (up to `SAVE_TIMEOUT`), returning `true` or `false`.
ProfileStore's own `Save` only starts one, so `DataService` stamps the data (`SaveStamp`) and waits for a save that carries the stamp; an autosave already in flight does not count.
`ProcessReceipt` and gifting rely on it; code that does not need to wait calls it in a `task.spawn`.
Every write through `Update` also fires `Signals.DataUpdated(player, key, value)`; server code that reacts to a change listens there instead of watching the profile.

### What changes per place

The place comes from the `Place` attribute that each place's `default.project.json` sets on `ServerScriptService.Services` (`Lobby`, `Game`, `Afk`, or `MapEditor`), not from `PlaceId`, so QA copies behave like the place itself.
`Config.Data.Places` holds two settings per place:

| Place | `ReadyTag` | `WaitForClient` |
| --- | --- | --- |
| Lobby | `Loaded` | `true` |
| Game | `ClientReady` | `false` |
| AFK | `Loaded` | `true` |
| Map Editor | `Loaded` | `false` (its client does not run the framework, so nobody fires `Loaded`) |

- `ReadyTag` is the tag `DataService` puts on the player when their client fires `Loaded`. The Game's `WaveService`, `DifficultyService`, and others wait on `ClientReady`.
- With `WaitForClient`, `Get` only hands out the profile after the player has `ReadyTag`, for up to `MAX_DATA_TIME_OUT` seconds. Without it, `Get` answers as soon as the profile is open.

A place with no entry in `Config.Data.Places` logs a warning and answers `Get` right away, since waiting on a tag nobody sets would never hand out the profile.

### Before the session closes: `OnBeforeRelease`

```lua
DataService:OnBeforeRelease(function(player) ... end, order)
```

Registers something to run with the profile still open, just before the session closes.
Every exit goes through `DataService:Destroy`: the `PlayerRemoving` of a player who leaves and the `BindToClose` of a server shutdown.
Registering here covers both and does not depend on the order in which services connected their own `PlayerRemoving`; anything written after `EndSession` is lost.

`order` (0 by default) is for callbacks that must **read** the profile after everyone who still writes to it: they run from lowest to highest, and in registration order within the same number.
`LeaderboardService` uses `1` to read the profile with the final playtime from `PlaytimeService` (see [Leaderboards](leaderboards.md)).

Each callback runs in a `pcall`: an error must not stop the session from closing, or the profile stays locked and the player cannot join another server.

The Game's early-leave reward uses this hook (see [Rewards](../game/rewards.md#design-notes)).

### Editing a profile from anywhere: `ProfileEditService`

Admin commands (`cash`, `shards`, `units`) edit profiles through `ProfileEditService`, whether the player is on this server, another one, or offline (see [Admin commands](admin-commands.md#players-on-another-server-or-offline)).

- **On this server:** `DataService:Update`, immediately.
- **Session open elsewhere:** `MessageAsync`; that server's `DataService` applies the edit in its `MessageHandler` and saves.
- **No session:** the same message, plus a short session that consumes it and closes.
  If the player joins right then, whoever opens the profile first applies the edit, once.
- While a short session is open, a player joining **this** server waits for it (`DataService.OfflineSessions`, up to `OFFLINE_SESSION_WAIT` = 20 s), because ProfileStore refuses to open the same key twice on one server.

Invalid edit messages are discarded (and logged).

Besides `set`/`add`/`remove` on a number, an operation can be `increment`: it walks a nested path under the key and adds to several counters at once.
Only keys marked `Increment = true` in its `KEYS` take it, and they take nothing else.
The [friend invite suggestion](../lobby/friend-invite.md) uses it to credit an accepted invite to the inviter (`FriendInvites.Accepted`).

## Configuration

| Key | Where | Effect |
| --- | --- | --- |
| `PROFILE_KEY` | `Config.Data` | The ProfileStore name; changing it starts every player from the template |
| `Template` | `Config.Data` | The default profile; new keys are added to existing profiles on load |
| `MAX_DATA_TIME_OUT` | `Config.Data` | How long `Get` waits for a profile |
| `SAVE_TIMEOUT` | `Config.Data` | How long `Save` waits for its save before answering `false` |

The profile key and template live in the server-only config (see [Configuration](../architecture/configuration.md)).
Old stores can still be read with the [`viewdata`](admin-commands.md#viewdata) command.
