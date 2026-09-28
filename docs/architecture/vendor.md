# Vendored libraries

These libraries do not come from Wally; they were copied into the original place by hand and now live in `vendor/` (and `common/client/Satchel/`).
Do not edit them except to fix a bug, and note any local patch here.

| Library | Where | Source |
| --- | --- | --- |
| Me (framework) | `vendor/shared/Me.luau` | @raiarxyzdev |
| Warp 1.0.14 | `vendor/shared/Warp` | @Eternity_Devs |
| Maid | `vendor/shared/Maid.luau` | Quenty-style |
| Spring (`spr`) | `vendor/shared/Spring.luau` | Fraktality/spr |
| Observers | `vendor/shared/Observers` | sleitnick/observers |
| Replica | `vendor/shared/ReplicaClient.luau`, `vendor/ReplicaShared/`, `vendor/server/ReplicaServer.luau` | MAD STUDIO |
| ProfileStore | `vendor/server/ProfileStore.luau` | MAD STUDIO (loleris) |
| Satchel 1.4.1 | `common/client/Satchel/` | @WinnersTakesAll (MPL-2.0) |
| HyperText 4.2.0 | `vendor/shared/HyperText` | @lopjoss (MIT); only `RichTextController` talks to it |

`ReplicaClient` and `ReplicaServer` hardcode `game.ReplicatedStorage.ReplicaShared`.
That is why `vendor/ReplicaShared` is mapped to exactly that path in both places: do not rename it.

## Wally packages

Each place declares its Wally dependencies in its own `wally.toml`:

| Package | Version | Used by |
| --- | --- | --- |
| `evaera/promise` | 4.0.0 | many Services and Controllers |
| `sleitnick/signal` | 2.0.1 | `DataService`, `DataController`, and others |
| `1foreverhd/topbarplus` | 3.4.0 | Satchel |
| `evaera/cmdr` | 1.11.0 | `CmdrService`, `CmdrController` |

## Outside the repository

`ReplicatedStorage.vfx` (the VFX plugin runtime, including the `LightningBeams` addon) exists only in the Game place in Studio; it has no `$path` in the project and is not tracked by git.
It refuses to run outside the client, and the Lobby does not use it.
Edit it only in Studio, and save and publish the Game place afterward, or the change is lost.

### Local patch: `LightningBeams` leak

The `LightningBeams` addon leaked on the client: every Electro arc left sparks alive, because `vfx.util`'s `pool:give` does not unparent pieces and the addon's `Parent` checks never saw a dead bolt.
Our patch makes teardown depend on a `_Destroyed` flag instead:

- `LightningBeams.Lightning` and `LightningImageHandleAdornment`: `Destroy` is idempotent through `self._Destroyed`.
- `LightningBeams.LightningSparks`: the Heartbeat destroys the spark once `LightningBolt._Destroyed` is set.
- `LightningBeams` (the addon): the `SparkRate` loop also stops on `bolt._Destroyed`.

Each patched spot is marked with a `PATCH Periastron` comment (four in total, one per module).
The patch has been lost once because the place was not saved.
On any lag report involving lightning (Electro or Thunder), first search the `vfx` sources for `PATCH Periastron` and check that all four are there.
