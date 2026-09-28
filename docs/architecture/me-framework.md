# The `Me` framework

`Me` loads every Service and Controller and carries the network events between them.
It is vendored in [`vendor/shared/Me.luau`](../../vendor/shared/Me.luau) and uses [Warp](vendor.md) underneath.

## How it works

`Me.new()` returns the framework object for the current side (server or client).
The boot scripts call `Framework:Load()`:

- **Server:** `common/server/Server/init.server.luau` loads every ModuleScript under `ServerScriptService.Services`.
- **Client:** `<place>/src/ClientBoot/init.client.luau` loads every ModuleScript under `PlayerScripts.Client.Controllers`.

`Load` walks the folder with `GetDescendants()`, so subfolders (`Common`, `Game`, `Lobby`) do not matter.
For each module it:

1. requires it (a module that returns a function is skipped);
2. spawns `module:init()` if it exists;
3. registers it in `Framework.Loaded` under the ModuleScript's name.

After every module is required, it spawns `module:start()` on each one.

Modules find each other by name with `Framework:Get("ModuleName")`.
Names must be unique across `Common` and the place folder.

`common/server/Server/ExampleService.luau` is a service template.
The framework does not load it, because it is a child of the `Server` script and not of `Services`; copy it into a `Services` folder to use it.

## Lifecycle convention

Services and Controllers follow the same shape:

```lua
local WeatherService = {
    Services = { LightingService = true },
}

function WeatherService:init()
    -- Runs while the other modules are still being required.
    -- Keep it light: declaring server events (see below) is the usual job.
    Framework:Listen("WeatherChanged", function() end)
end

function WeatherService:start()
    -- Every module is loaded by now: resolve dependencies, then construct.
    for Service in self.Services do
        self.Services[Service] = Framework:Get(Service)
    end

    self:construct()
end

function WeatherService:construct()
    -- Connect listeners and start the module's own work.
end
```

`Framework:Get(name)` without the yield flag returns `nil` when the module is not loaded.
`Framework:Get(name, false, true)` waits for it.
Only wait for a module that exists in the current place: in the Lobby, waiting for a Game-only service (such as `ThunderService`) waits forever.

## Events

```lua
Framework:Listen("RequestWeather", function(player) ... end) -- server receives
Framework:Fire("WeatherChanged", player, current)            -- server sends to one player
```

### Declare every server-to-client event on the server

A Warp event identifier is created on the **server**.
When the client calls `Framework:Listen("X")` and the server does not know `X` yet, the client's `Serdes.increment` **yields for 10 seconds** waiting for the attribute, warns `Serdes: X is taking too long to retrieve`, and returns `nil`.
`construct()` is a single function, so every `Listen` **after** that line waits too.
The symptom is not that the new event fails; it is that the rest of the controller disappears.

So every event that only the server fires has an empty `Listen` in the owning service, in `init()` or at the top of `construct()` (see `WeatherService`, `UnitService`, `MobService`):

```lua
Framework:Listen("UnitPriorityChanged", function() end) -- only so the event exists
```

Events the **client** fires do not need this: the server listens to them, and registering the real `Listen` creates the identifier.

### Events are not ordered with each other

Warp does not guarantee the order between two different events.
When two messages talk about the same state (for example, `WeatherChanged` and `WeatherDuration`), the later one must carry an id or name that says which state it belongs to, and the receiver must check it.
