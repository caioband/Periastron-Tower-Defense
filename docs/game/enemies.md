# Enemies

Each difficulty dresses the same nine enemy entities in its own set of models, and a gimmick can belong to one set only.

**Runs in:** Game
**Code:** [`MobService`](../../Game/src/Services/MobService.luau), [`MobController`](../../Game/src/Controllers/MobController.luau), [`SharedConfig.Mob`](../../common/shared/Config/SharedConfig/Mob.luau), [`Config.Difficulty`](../../common/server/Config/Difficulty.luau)

## How it works

### Model sets: a reskin per slot

Enemy models live in `ReplicatedStorage.Shared.Assets.Entities.Difficulties.<set>`, one folder per set:

| Set | Theme | Models |
| --- | --- | --- |
| `Hard` | Redcliff | 9 |
| `Easy` | Astral | 8 |
| `Medium` | Sky | 8 |
| `Impossible` | Korblox | 9 |
| `Nightmare` | Overseer | 9 |

The nine entities in `SharedConfig.Mob.Entities` are the source of truth for the match: health, speed, and gimmicks come from there on every difficulty.
The set only says which model to draw in place of each entity.
That allows a new visual theme without touching the wave tables, the balance, or `IsBoss`.

`SharedConfig.Mob.ModelSets` maps entity to model for each set.
An entity missing from the table uses its own name, which is the case for eight of the nine in `Hard`; the exception is `WingedSquire`, whose model is named `WingedRedcliff`.

| Slot (`SPAWN_ORDER`) | Hard | Easy | Medium | Impossible | Nightmare |
| --- | --- | --- | --- | --- | --- |
| 1 | Traveler | AstralInitiate | SkyBirdWarrior | KorbloxMage | OverseerMinion |
| 2 | RedcliffPawn | AstralWizard | SkyLeader | KorbloxSkeleton | OverseerWanderer |
| 3 | RedcliffSquire | AstralKnight | SkyWindAxe | KorbloxGeneral | OverseerOrb |
| 4 | RedcliffGuard | AstralGuardia | SkyStealther | KorbloxGremlin | OverseerGuard |
| 5 | WallSmasher | AstralNecromancer | SkyFlyingGoon | KorbloxImperium | OverseerCharger |
| 6 | CourageBearer | AstralSentry | SkyMage | KorbloxSkeletonDefender | OverseerWingwalker |
| 7 | WingedSquire | AstralAdventurer | SkyGuardian | KorbloxElder | OverseerMage |
| 8 | RedcliffEnforcer | AstralAdventurer | SkyGuardian | KorbloxDeathspeaker | OverseerKnight |
| 9 | RedcliffChampion | AstralSentinel | SkyKnight | KorbloxDeathRaider | OverseerKing |

`Easy` and `Medium` have eight models for nine slots, so one repeats in each, always the **lower** step (slot 8, the Enforcer).
The Enforcer and the Champion appear together in the last wave, and giving the boss's model to the Enforcer would take away the one moment the boss must be unmistakable.

The order of each set follows the ruler drawn by the `Workspace.Weakest` and `Workspace.Strongest` parts: models are lined up between them from weakest to strongest.
**The ruler is art documentation only; nothing reads it at runtime.**
To reorder a set, edit `ModelSets`.

### Which set a match uses

Each difficulty names its set in `Difficulty.ModelSet`.
Easy, Medium, Impossible, and Nightmare have their own; Hard and the Tutorial use `Mob.DefaultModelSet` (`"Hard"`).
`MobService:SpawnWave` reads it once per wave and sends the set name in the `SpawnClientMob` payload, next to the entity name.

The set name travels instead of the client asking for the difficulty, because `Config.Difficulty` is server config.
It is the **set name** and not the resolved model name, so the `Name` the client gets is still the entity's, which the rest of `MobController` (such as `getAverageSpeed`) relies on.

`MobController.resolveMobModel` falls back in three steps: the requested set, the default set, then `EnemyRig`.
An incomplete set is an art mistake: the enemy shows up wearing another model with a warning in Studio, and the match goes on.

### Gimmicks scoped to a set

A gimmick can carry a set filter.
`Mob.GetGimmicks(set, entity)` applies it, called by `SpawnWave` **once per wave entry**; per-enemy state stays in `GimmickState`.
This lets every enemy in every set have its own move, on any of the nine slots, and keeps the exception visible on the entity instead of inside a handler.

| Key | Applies | Use it for |
| --- | --- | --- |
| `ModelSet` | **only** in the named sets | a move that belongs to one set |
| `ExceptModelSet` | in every set **except** the named ones | the entity's default move, which some set replaced |

Both accept a name or a list.

> **Rule of thumb:** a move a set gained is `ModelSet`; a move a set lost is `ExceptModelSet` on the old move.
> Never a growing list of the sets that inherit it.

The filter is by set, not by difficulty.
With `ModelSet` only, a difficulty that gets its own folder leaves the `Hard` fallback and silently loses every move scoped there; that happened three times in a row (Nightmare, Medium, Impossible).
Written the negative way, a new set **inherits** the entity's move until someone says it has its own.

Scoping one move does not unscope another: a new `Easy` move *coexists* with an unscoped one.
For an enemy to **swap** moves between sets, both moves need a key, as the boss's two do.

| Entity | Move | Scope |
| --- | --- | --- |
| WallSmasher | `PerTurnSpeedMultiplier` | every set |
| CourageBearer | `PerTurnSpeedMultiplier` | every set |
| RedcliffChampion | `HealthThresholdStunRandomUnit` | every set except `Easy` |
| RedcliffChampion | `HealthThresholdRush` | `Easy` only |

### `HealthThresholdRush` (the Astral Sentinel's dash)

At half health, the `Easy` boss plays `Rush` and dashes: **double speed for 3 seconds**, starting at the animation's `Action` marker.
The field is `Amount`, applied as `RushScale = 1 + Amount`, so `1` means double.

The server times the dash with `MarkerTime` (0.5667 s of the 3.25 s animation `rbxassetid://98921075157550`), the same way the Champion's stun uses `AnimTime = 1.3`.
Speed is match state, and match state never comes from a client message: with N players there would be N messages at N pings, and one tampered client could speed up everyone's boss.
The client plays the same animation at the same moment, so the dash lines up on screen.

`RushScale` is its own factor in `computeSpeed`, separate from the stack-based `SpeedScale` and from `CurrentSpeed`, so it can expire after 3 seconds without taking an ice slow that started during it.

One-off animations reach the client through `MobPlayAnim(mobId, name)` and `playOneShotAnimation(mobId, name)`, which keeps one track per name in `movement.oneShotTracks` so `applyTimeScale` reaches all of them at 2x speed.

## Configuration

| Key | Where | Effect |
| --- | --- | --- |
| `Mob.Entities` | `SharedConfig.Mob` | The nine entities: health, speed, boss flag, gimmicks |
| `Mob.ModelSets` | `SharedConfig.Mob` | Entity → model name per set |
| `Mob.DefaultModelSet` | `SharedConfig.Mob` | `"Hard"`: the fallback set |
| `ModelSet` | `Config.Difficulty` presets | The set each difficulty uses |

## Studio setup

A model added to any set needs:

- **An R6 rig** with the usual part names (`Head`, `Torso`, `Left Arm`…) and `HumanoidRootPart` as `PrimaryPart`.
  `createEntity` unanchors everything but the root, removes the `Humanoid`, and moves the model by its pivot.
- **A walk animation:** either the `SlowWalk` + `FastWalk` pair (so `updateWalkAnimation` switches stride with speed, as the Wall Smasher and Courage Bearer do) or a single `Walk`.
  Without either, the generic `Entities.Walk` plays, so the enemy never slides across the map in a T-pose.
- **`Attack`**, if the slot has a gimmick that plays an attack (today only the Champion).
- **A compatible bounding box.**
  Height can vary (`PathOffsetY` is computed at runtime), but a model that is too wide is removed by `checkIsOnGrid` in the movement loop.

If the `Rush` animation is re-exported, measure `MarkerTime` again: it is the only place in the code that hardcodes a number from inside an asset.
Use `KeyframeSequenceProvider:GetKeyframeSequenceAsync(id)` and find the `KeyframeMarker` named `Action`.

## Known issues

- Three bosses still inherit the Champion's stun: Sky Knight, Korblox Death Raider, and Overseer King.
  None of them has an `Attack` animation, so the 1.3 s pause plays with no gesture.
  Each should leave the inheritance once it gets its own move, as the Astral Sentinel did.
- Many new models have no published `Animation` and fall back to the generic walk.
  At the last count, per slot: 4 of 9 in `Easy`, 8 of 9 in `Medium` (only `SkyKnight` has its own), 8 of 9 in `Impossible` (only `KorbloxDeathRaider`), and 7 of 9 in `Nightmare`.
  Publishing and attaching the animation is art work; no code changes are needed.
- None of the models in the newer sets has the `SlowWalk`/`FastWalk` pair.
