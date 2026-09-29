# Configuration

Configuration is split by who may see it.
Anything secret or server-only stays out of `ReplicatedStorage`.

| | Where | Contents |
| --- | --- | --- |
| **Server only** | `ServerScriptService.Config` ← `common/server/Config` | `Analytics`, `Badges` (name → BadgeId), `Cmdr` (`ADMIN_USER_IDS`, `GROUP_ID`, `ALLOW_IN_STUDIO`…), `Crate` (drop odds and pools), `Data` (`PROFILE_KEY` and the profile template), `Difficulty`, `Leaderboard`, `Summon`, `Wave`, `Waves` (one wave table per difficulty) |
| **Replicated** | `ReplicatedStorage.Shared.Config` ← `common/shared/Config` | `Client`, and `SharedConfig` with one module per system: unit stats and upgrades, crates, maps, weather, lighting, round cards, shops, tutorial, the cosmetic part of `Cmdr`, and so on |

`Summon` in the server config is not used by the Game; it stays for consistency between the places.

## Requiring config

On the server:

```lua
local ServerScriptService = game:GetService("ServerScriptService")

local Configs = Shared:WaitForChild("Config")                        -- replicated
local ServerConfigs = ServerScriptService:WaitForChild("Config")     -- server only
local ServerVendor = ServerScriptService:WaitForChild("Vendor")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)
```

On the client, only `Configs` exists.

## What the client gets instead

- **Mob animation data:** `SharedConfig.Mob` holds presentation stats only.
  The client already receives `Speed` and `MaxHealth` for each mob in the spawn packet.
- **Cmdr:** the client gets only the cosmetic keys (`ACTIVATION_KEYS`, `PLACE_NAME`) from `SharedConfig.Cmdr`.
  The console starts disabled until the server answers the `RequestCmdrAccess` event.
  Real authorization always happens in the server's `BeforeRun` hook in `CmdrService` (see [Admin commands](../common/admin-commands.md)).
- **Crate odds:** the client receives the real odds from the server through the `CrateOdds` event, never from a replicated table.

## Design notes

`ReplicatedStorage.Shared.Config.Server` used to replicate the DataStore key, the profile template, wave tables, summon odds, and the Cmdr admin list to every client.
Anything a client can read, an exploiter can read, so those tables moved to `ServerScriptService.Config`.
