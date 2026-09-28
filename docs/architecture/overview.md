# Repository overview

This repository holds both places of Periastron Tower Defense.
Code used by both places lives at the root; each place folder keeps only what belongs to it.

```text
common/     first-party code shared by both places
vendor/     third-party libraries that do not come from Wally
Game/       the "Periastron TD: Main Game" place (only what is specific to it)
Lobby/      the "Periastron Tower Defense" lobby place (only what is specific to it)
docs/       this documentation
```

See the [development setup](../../README.md#development-setup) in the root README to install the tools and sync the places.

## How the shared code is mounted

Each place has its own `default.project.json`, and both point back to the root with `../` paths.
Where a folder mixes shared code and place code, it becomes a Folder with two subfolders.
The [`Me` framework](me-framework.md) loads modules with `GetDescendants()`, so modules load the same way and `Framework:Get("ModuleName")` keeps working.

```text
StarterPlayerScripts.Client (LocalScript)   <- <place>/src/ClientBoot
├── Satchel                                 <- common/client/Satchel
└── Controllers
    ├── Common                              <- common/client/Controllers
    └── Game | Lobby                        <- <place>/src/Controllers

ServerScriptService
├── Server (Script)                         <- common/server/Server
├── Config (ModuleScript)                   <- common/server/Config      [server only]
├── Vendor                                  <- vendor/server
├── CmdrDefinitions
│   ├── Types
│   │   ├── Common                          <- common/server/CmdrDefinitions/Types
│   │   └── Lobby                           <- Lobby/src/CmdrDefinitions/Types
│   └── Commands
│       ├── Common                          <- common/server/CmdrDefinitions/Commands
│       └── Game | Lobby                    <- <place>/src/CmdrDefinitions/Commands
└── Services
    ├── Common                              <- common/server/Services
    └── Game | Lobby                        <- <place>/src/Services

ReplicatedStorage
├── Packages                                <- <place>/Packages (Wally)
├── ReplicaShared                           <- vendor/ReplicaShared
└── Shared
    ├── Vendor                              <- vendor/shared
    ├── Config                              <- common/shared/Config
    ├── Util                                <- common/shared/Util
    ├── Classes                             <- common/shared/Classes
    └── Assets                              (authored in the place; content, not code)
```

The Game has no place-specific Cmdr types, so its project has no `Types/Game` node.
A node that points at a folder git does not track would break a fresh clone.

Module names must be unique across `Common` and the place folder, because `Framework:Get` looks them up by name only.

## Rojo pitfalls

- **Rojo does not merge `$path` with children declared on the same node.**
  It creates two instances with the same name instead.
  That is why `Controllers` and `Services` are Folders declared with two subfolders, and why `src/ClientBoot/` contains only `init.client.luau`.
- **`$ignoreUnknownInstances` defaults to `true` on a node without `$path`, and to `false` on a node with `$path`.**
  `Controllers` and `Services` are declared with `$className` only, so they would inherit `true`.
  Rojo would then add new subfolders but never remove old loose scripts, and the place would run both versions at once.
  Every container node in the project therefore sets `"$ignoreUnknownInstances"` explicitly.

## What each place keeps

The place pages list what is specific to each place, its Wally dependencies, and what lives only in the `.rbxl`:

- [Game](../game/README.md)
- [Lobby](../lobby/README.md)

## Differences between the places (on purpose)

| File | Why |
| --- | --- |
| `src/ClientBoot/init.client.luau` | The Lobby fires `Framework:Fire("Loaded", true)` from the boot script; in the Game, `WaveController` fires it. |
| `src/Services/DataService.luau` | The Lobby waits for the `Loaded` tag before handing out the profile; the Game answers right away. |
| `src/Controllers/UILibraryController/` | The two places have different UIs. |

## Related pages

- [The `Me` framework](me-framework.md)
- [Configuration](configuration.md)
- [Vendored libraries](vendor.md)
- [Conventions](conventions.md)
