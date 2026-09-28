# Logging

`Log` is the single way first-party code writes to the Output.
It keeps production consoles quiet and gives every message the same `[Module]` prefix.

**Runs in:** Game · Lobby, on the server and the client
**Code:** [`Shared.Util.Log`](../../common/shared/Util/Log.luau)

## How it works

`Log.new(tag)` returns a logger whose messages start with `[tag]`.
Each method decides whether to print based on `RunService:IsStudio()`, read once when the module loads.

| Method | Prints in Studio | Prints in live servers | Output |
| --- | --- | --- | --- |
| `Debug(...)` | Yes | No | `print` |
| `StudioWarn(...)` | Yes | No | `warn` |
| `Warn(...)` | Yes | Yes | `warn` |
| `StudioWarnOnce(key, ...)` | Once per key | No | `warn` |
| `WarnOnce(key, ...)` | Once per key | Once per key | `warn` |

The *Once* variants remember keys per tag, so two modules that create `Log.new("X")` share the same memory.

Arguments are passed through the way `print` and `warn` take them.
`Log` does not format anything: build the message with string interpolation or `string.format` before calling.

## Usage

```lua
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local log = Log.new("MapService")

log:Debug("map loaded:", mapName)
log:StudioWarn(`map '{name}' has no SpawnLocation; no spawn fallback.`)
log:Warn(string.format("teleport of %s to the lobby failed (%s).", player.Name, tostring(err)))
log:StudioWarnOnce(assetName, `could not find '{assetName}' in Assets.UI.`)
```

Modules inside `Shared.Util` require it as `require(script.Parent.Log)`.

A module can create more than one logger to split its output, as `UnitService` does with `Log.new("UnitService/Place")` for placement decisions.

`Log.IsStudio()` exposes the same flag for code that gates more than a log line.

## Choosing a level

See [Log messages](../architecture/conventions.md#log-messages) in the conventions for the rule.
In short, `Warn` is reserved for data, monetization, teleports, and server failures that switch a feature off for real players.
Everything else is `StudioWarn` or `Debug`.

## Design notes

- `Log` is a Util and not a Service of the [`Me` framework](../architecture/me-framework.md) because Services exist only on the server, and client code logs too.
  Roblox also has a built-in `LogService`, and a module with the same name would be confusing.
- Client code has no use for `Warn`: a warning in a player's client only reaches that player's console.
- The `viewdata` Cmdr command keeps a raw `print`, because its output was requested by an admin and must reach the server log in live servers.
