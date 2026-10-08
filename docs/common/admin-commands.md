# Admin commands

The Cmdr admin console runs in both places.
This page lists every command, who may run them, and how the currency, unit, and data commands behave.

**Runs in:** Game · Lobby
**Code:** [`CmdrService`](../../common/server/Services/CmdrService.luau), [`CmdrController`](../../common/client/Controllers/CmdrController.luau), [`common/server/CmdrDefinitions`](../../common/server/CmdrDefinitions), [`ProfileEditService`](../../common/server/Services/ProfileEditService.luau), [`CurrencyService`](../../common/server/Services/CurrencyService.luau), [`Config.Cmdr`](../../common/server/Config/Cmdr.luau)

## Commands

Commands that depend on a service from one place only live in that place's folder: `strike` needs `ThunderService`, which only exists in the Game, and in the Lobby `Framework:Get` with yield would wait for it forever.

| Command | Aliases | Arguments | Place | What it does |
| --- | --- | --- | --- | --- |
| `lighting` | `setlighting` | `<preset> [seconds]` | both | Applies a lighting preset to everyone; tab completes names; seconds omitted = config default, `0` = instant |
| `lightinglist` | `lightings` | | both | Lists the presets in `Assets.Lighting` and what each declares |
| `weather` | `setweather` | `<weather\|off> [seconds]` | both | Turns a weather on for the loaded map; `off` clears it |
| `restartwarning` | `testrestart` | `<reason> [seconds]` | both | Rehearses the server restart warning (restarts nothing) |
| `cash` | `money`, `coins` | `<action> <players> <amount>` | both | Saved Cash (`Stats.Cash`, the Lobby currency); the player may be offline |
| `shards` | `shard` | `<action> <players> <amount>` | both | Saved Shards (`Stats.Shards`, the premium currency) |
| `units` | `unit`, `giveunit`, `inventory` | `<action> <players> <unit> [amount]` | both | The saved unit inventory (`Units` in the profile) |
| `level` | `levels`, `setlevel`, `lvl` | `<action> <players> <amount>` | both | The profile's level, written as `Stats.XP` (see [`level`](#level)) |
| `viewdata` | `inspectdata`, `olddata` | `<player> [store] [date]` | both | Reads a saved profile (read-only; the player may be offline) |
| `dialog` | `testdialog` | `[players] [auto]` | both | Plays the test line in the dialog box; players omitted = everyone; `auto` advances by itself |
| `richtext` | `textlab` | `[players]` | both | Opens the rich text workbench (run again to close); players omitted = you |
| `tutorial` | `tutorialprompt` | `[players]` | both | Sends the tutorial offer (writes nothing to the profile) |
| `tutorialreset` | `resettutorial` | `[players]` | both | Clears the profile's `Tutorial` flag so the offer shows again |
| `tutorialshop` | `tutorial2` | `[players]` | both | Runs the Lobby half of the tutorial (the shop until the Crate of Beginnings is bought) |
| `highlight` | `spotlight` | `[path] [players]` | both | Darkens the screen except the GuiObject at the path (for example `HUD.HUDLeft.Shop`); no path clears it |
| `arrow` | `indicator` | `[x,y,z] [players]` | both | Points the indicator arrow at a position; no position clears it |
| `gift` | `giftpass` | `<players> <item>` | both | QA/Studio: runs a [gift](gifting.md) receipt with a fake purchase (no Robux) and logs every check; the player may be offline |
| `giftreset` | `resetgifts` | `[players]` | both | QA/Studio: removes gifted passes and clears the gift tables of players on this server |
| `datareset` | `resetdata` | `[players]` | both | QA/Studio: resets the whole profile to a new player's (only `PurchaseHistory` survives) and kicks the player to rejoin fresh; players on this server |
| `roundcash` | `sessioncash` | `<action> <players> <amount>` | Game | The round cash that pays for towers |
| `roundshop` | `cardshop`, `rcs` | `[players]` | Game | Opens the [round card shop](../game/round-card-shop.md) offer now and redraws it |
| `strike` | `lightning`, `thunderstrike` | `[unit]` | Game | Drops a lightning bolt on a placed unit |
| `setcrates` | `setcrate` | `<players> <rarity> <amount>` | Lobby | Sets how many crates of a rarity a player owns |
| `unbox` | `openbox` | `<players> <rarity>` | Lobby | Rolls a crate and plays the unboxing for the whole server |
| `friendinvite` | `invitefriend` | `[players] [ignoreCooldown]` | Lobby | Sends the [friend invite suggestion](../lobby/friend-invite.md) now; players omitted = you |
| `friendinvitestats` | `invitestats` | `[player]` | Lobby | Prints the player's invite history: clicks and accepted invites (System, Manual, Total) per friend |

Cmdr's built-in groups are registered too (`DEFAULT_COMMAND_GROUPS`: `DefaultUtil`, `DefaultAdmin`, `DefaultDebug`, `Help`).

## Who may run commands

Permission is decided on the server: the `BeforeRun` hook calls `CmdrService:CanRun` for every command, and the client only uses the same answer (through `RequestCmdrAccess`) to decide whether to show the console.
Checked in this order:

| Path | Configured by |
| --- | --- |
| Studio | `ALLOW_IN_STUDIO` |
| User id list | `ADMIN_USER_IDS` |
| Place owner | automatic: the user, or rank ≥ `CREATOR_GROUP_MIN_RANK` in the owning group |
| Extra group | `GROUP_ID` + `GROUP_MIN_RANK` |
| Tester in QA (only `QA_COMMANDS`) | `QA_COMMANDS`, when `Environment.IsQA()` |

This place belongs to a group, so `game.CreatorId` is the **group's** id; the owner check compares the player's rank in that group.
`CREATOR_GROUP_MIN_RANK` is 255 (the group owner only); lower it to include the group's admins.

### Testers in QA

In the [QA environment](environments.md), **every player is a tester** and may run the commands in `QA_COMMANDS`, keyed by the command's `Name`:

| Command | Place |
| --- | --- |
| `cash` | both |
| `shards` | both |
| `units` | both |
| `level` | both |
| `roundcash` | Game |
| `friendinvite` | Lobby |
| `friendinvitestats` | Lobby |
| `datareset` | both |
| `tutorialreset` | both |
| `help` | both |

Testers can aim them at any player, online or offline, like admins (`datareset` and `tutorialreset` only reach players on the same server).
QA is a separate universe with its own DataStores, so this never touches a production profile.
In Production, `QA_COMMANDS` does nothing.
A tester's console shows only these commands (and only the ones registered in the current place).
`help` lists only those too, since `CmdrController` removes every other command from the client's registry.

### Other non-admins

`COMMAND_PERMISSIONS` can open single commands to non-admins by group rank, keyed by the command's `Name` (not an alias or group).
**It is empty on purpose: outside QA, only admins run commands.**
With no accessible command, `GetAccessibleCommands` returns an empty list and the console does not show for them.

## Currency, unit, and level commands

There are **three** currencies, and two of them are the same account in different places:

| Command | Changes | Lives |
| --- | --- | --- |
| `cash` | the profile's `Stats.Cash` | saved; the Lobby currency, for summons and cheaper crates |
| `shards` | the profile's `Stats.Shards` | saved; the premium currency, for expensive crates |
| `roundcash` | `MobService.SessionCash` | only while the round lasts |

The action is `set`, `add`, or `remove`, with tab completion (`s`, `a`, and `r` resolve).
None of them goes below zero: a `remove` that would pass zero stops at zero.
The reply shows each player's before and after, so a `remove` that hit the floor and a `set` to the current value do not look like "nothing happened".

`cash`, `shards`, `units`, and `level` write through `ProfileEditService`, which reads and writes in the same operation (`CurrencyService:Apply` for currencies), so `add` adds to the value that is there now.
`roundcash` goes through `MobService`'s `addCash`/`spendCash` instead of writing the table, because they fire `UpdateCash`; otherwise the on-screen counter would stay stale until the next kill.

### `units`

`units` changes the profile's `Units`: **how many** of each unit the player owns.
The amount defaults to 1, and nothing goes below zero.

`Units` is the inventory; `EquippedUnits` is which of them sit in deck slots.
The command changes only the first **on purpose**: `DeckConfig.sanitize` runs on every deck read and already caps each slot's `Amount` by what the player owns, so removing units empties the slot by itself.
A unit that reaches zero **leaves the table** instead of becoming `= 0`, which is what a profile that never had the unit looks like; `DeckConfig` treats both the same way (`owned[unitName] or 0`).

The name is case-insensitive (`units add me slasher 3` works) and the reply uses the official spelling.
Names with spaces need quotes: `units add me "Subspace Tripminer" 3`.

⚠️ **In the Game, a round already started does not change.**
Match cards are copied from the profile in `UnitService:initPlayerCards` when the round starts, so units given mid-round only appear next round or after a `ResetRound`.
In the Lobby the effect is immediate: the deck reads the profile on every replica change.

The `unitName` argument type lives in `common/server/CmdrDefinitions/Types` because it only reads `UnitStats`; `strike` uses it too.

### `level`

The level is never saved: it is always derived from the accumulated `Stats.XP` through `LevelConfig:Resolve`.
So `level` does the math in levels and writes XP: `ProfileEditService` (`editLevel`) resolves the current level, applies the action, clamps the result to 1..`LevelConfig.MAX_LEVEL`, and sets `Stats.XP` to the start of that level (`LevelConfig:GetTotalXPForLevel`, zero progress in it).

- `level set me 10` puts the player at the start of level 10, even when they are already at 10 (the way to zero the progress).
- `level add me 3` from level 5 at 80% lands at the start of level 8: the progress in the old level is not carried over.
- When the level does not change (`remove` at level 1, `add` at the max) the XP stays as it was.

Everything that depends on level (deck slots, difficulty unlocks, the HUD bar, the HIGHEST LEVEL leaderboard) reads `Stats.XP`, so it follows by itself.
The reply shows levels, not XP: `caioband Stats.Level 5 -> 8`.

### Players on another server or offline

`cash`, `shards`, `units`, and `level` accept a **username or `#UserId`** (the Cmdr `playerIds` type), whether the player is on this server, another one, or offline.
`me`, `all`, and `others` still work for players on this server.
`ProfileEditService` picks the path:

| Where the profile is | What happens | Reply |
| --- | --- | --- |
| On this server | `DataService:Update`, immediately | `before -> after` |
| Session open on another server (or a crashed one) | `MessageAsync`; that server's `DataService` applies it and saves within seconds | `sent to their server` |
| No session | the same message, plus a short session that consumes it and closes | `before -> after (offline, saved)` |
| No profile at all | nothing (probably a typo) | `has no profile` |

With no session, the value also goes as a message: if the player joins right then, whoever opens the profile first applies the edit, once.
While the short session is open, a player joining **this** server waits for it to close (`DataService.OfflineSessions`).
See [Data and profiles](data-and-profiles.md).

## `viewdata`

`viewdata` uses `ProfileStore:GetAsync`: it opens no session, locks nothing, and saves nothing.
`store` omitted (or `current`) is today's `PROFILE_KEY`; an old key (`PROD_KEY_1`) reads what was left there after the key changed.
With `date` (`YYYY-MM-DD[THH:MM]` UTC), `VersionQuery` returns the last version saved up to that moment.
DataStore keeps each key's versions for 30 days, so an older date only finds the current version, if it predates the date.
The output goes to the Cmdr console and, in full, to the server log (F9 → Server).
In Studio it only reads the real store if API access is enabled.

## Lighting and weather commands

- `lightinglist` shows how many properties and instances each preset declares, marks the current one with `>`, and flags empty presets: the quick way to see why a preset "did nothing".
- `lighting` on the current preset reapplies it on purpose, to test a folder just edited in Studio.
- The `lightingPreset` type builds its completion from `Assets.Lighting` at the moment, not a fixed list: map presets only exist after `MapService` registers the loaded map.
- `strike` without an argument picks any placed unit; with a type (`strike Sword`) it picks among units of that type and says which one was hit.
  Names with spaces need quotes (`strike "Subspace Tripminer"`).
  Completion offers the whole `UnitStats` catalog; the server answers with the real list when it finds none.

## `restartwarning`

`restartwarning` goes through the same path as the engine event, so what shows on screen is exactly what would show on the day (see [Server restart warning](screen-warnings.md#server-restart-warning)).
The reason is an `Enum.CloseReason` name with tab completion; seconds omitted means 5 minutes.
