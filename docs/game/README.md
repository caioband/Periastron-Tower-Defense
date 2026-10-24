# Game place

The match place, "Periastron TD: Main Game".
Players arrive here from the Lobby with a map and a deck, vote on a difficulty, and play the waves.

For the repository layout and what is shared between the places, see [Repository overview](../architecture/overview.md).

## What is specific to this place

| Folder | Mounted at | Contents |
| --- | --- | --- |
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | Entry LocalScript |
| `src/Controllers/` | `Client.Controllers.Game` | BaseHealth, Card, CardModifier, Difficulty, Loading, MapCutscene, Mob, Projectile, Ready, Result, RoundCardShop, SkipPrompt, Speed, Targeting, Tripmine, TutorialStep, UILibrary, UnitPlacement, VFX, Wave, WeatherFeedback, WeatherIndicator, WeatherWarning |
| `src/Services/` | `ServerScriptService.Services.Game` | CardModifier, CardShop, Collision, ContractTracker, Difficulty, Leaderstats, Map, MapCutscene, MatchStats, Mob, Skip, Snow, Speed, Thunder, TutorialMatch, Unit, Wave, WeatherRound |
| `src/CmdrDefinitions/Commands/` | `ServerScriptService.CmdrDefinitions.Commands.Game` | `roundcash`, `roundshop`, `strike` |

Commands that depend on a Game-only service live here and not in `common/`.
`strike` needs `ThunderService`; in the Lobby, `Framework:Get` with yield would wait for it forever.

## Pages

| Page | What it covers |
| --- | --- |
| [Maps](maps.md) | Loading a map, spawn fallback, base health display, the map bounding box, map lighting |
| [Unit placement](unit-placement.md) | Where a unit may be placed, mouse and touch controls, the placement ghost |
| [Units](units.md) | Attacks, projectiles, damage over time, chained lightning, the Entrepreneur farm |
| [Enemies](enemies.md) | Model sets per difficulty, gimmicks, the contract for a new enemy model |
| [Waves](waves.md) | The hard-coded wave tables per difficulty: order, count, health, and speed |
| [Upgrade card](upgrade-card.md) | The upgrade panel, next-level preview, target priority |
| [Hotbar](hotbar.md) | The deck brought from the Lobby and the card arc |
| [Map cutscenes](map-cutscenes.md) | A map's intro before the first round and its outro on the way to the Lobby |
| [Difficulty vote](difficulty-vote.md) | The `DifficultyBoard` vote |
| [Skip wave](skip-wave.md) | The skip prompt and its vote |
| [Match speed](match-speed.md) | The speed button and `GameClock` |
| [Round cards](round-cards.md) | Cards used during a match and what each one does |
| [Round card shop](round-card-shop.md) | The in-match card shop |
| [Weather in a match](weather-in-match.md) | Scheduled weather, the indicator, weather effects, snow freeze, lightning |
| [Rewards](rewards.md) | Wave cash, leaderstats, end-of-match and early-leave rewards |
| [Tutorial match](tutorial-match.md) | The scripted five-wave tutorial |
| [Community matches](community-matches.md) | Building a published Map Editor map at runtime, and its smaller rewards |

## Outside the repository

These live only in the `.rbxl`, because they are content and not code:

- `ReplicatedStorage.Shared.Assets`: models, UI, VFX, and animations.
- `ServerStorage.Maps`: one folder per map.
- The ScreenGuis in `StarterGui`.
- `ReplicatedStorage.vfx`: the VFX plugin runtime (see [Vendored libraries](../architecture/vendor.md#outside-the-repository)).

The project nodes that contain them use `$ignoreUnknownInstances: true`.
`ServerStorage` does not appear in `default.project.json` at all: Rojo only manages what is declared, so the maps folder is never touched.

Maps stay in `ServerStorage` on purpose, so they do not replicate and the client only knows the map that `MapService` cloned into `workspace.Map`.
In practice, `CollectionService:GetTagged("Grid")` on the client returns exactly the path parts in play.
On the server it also returns the parts of every stored map, so server code that reads the tag must filter by `workspace.Map` (as `UnitService:getGridParts` does).

Several packages that were installed in the place but required by no script (`Knit`, `Comm`, `Component`, `EnumList`, `Input`, `Option`, `Streamable`, `TableUtil`, `Timer`, `Trove`) were moved to `ServerStorage._Backup_UnusedCode`.

## Known issues

- `src/Controllers/UILibraryController/Components/Wave.luau`: `module:destroy()` references `CardUpgrade`, which does not exist in that file (it was pasted from `ToggleTower.luau`).
  It errors if `destroy()` is ever called.
- The Workspace holds loose enemy and unit models (Azuron, Rocketeer, Azure, sword, slasher, slingshot, and others, with no tags) and the empty `Cards` and `Upgrade` ScreenGuis.
  They were left untouched.
