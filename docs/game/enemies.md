# Enemies

Every enemy model is its own entity: the name the wave tables use is the model's name, and its gimmicks live on it.

**Runs in:** Game
**Code:** [`MobService`](../../Game/src/Services/MobService.luau), [`MobController`](../../Game/src/Controllers/MobController.luau), [`SharedConfig.Mob`](../../common/shared/Config/SharedConfig/Mob.luau), [`Config.Waves`](../../common/server/Config/Waves/init.luau)

## How it works

### One entity per model

Enemy models live in `ReplicatedStorage.Shared.Assets.Entities.Difficulties.<folder>`, one folder per cast:

| Folder | Cast | Models | Used by |
| --- | --- | --- | --- |
| `Hard` | Redcliff | 9 | Hard, Tutorial |
| `Easy` | Astral | 8 | Easy |
| `Medium` | Sky | 8 | Medium |
| `Impossible` | Korblox | 9 | Impossible |
| `Nightmare` | Overseer | 9 | Nightmare |

`SharedConfig.Mob.Entities` has one entry per model, keyed by the model's name, with:

- `Folder`: which folder above holds the model.
- `Health` and `SpeedMultiplier`: the **reference** stats. What an enemy spawns with comes from its [wave table](waves.md); the reference is what the damage reward and the Deathspeaker's converts measure against.
- `Boss`: whether it is a boss (boss music, the boss contract).
- `Gimmicks`: its moves.

`MobService` sends only the entity name in `SpawnClientMob`.
`MobController.resolveMobModel` looks the name up in its `Folder`; a missing model shows up as `EnemyRig` with a warning in Studio, and the match goes on.

Nothing ties a folder to a difficulty: a wave table can list any entity, so a difficulty can borrow another cast's enemy.

### Slots across casts

The casts were built as reskins of the same nine slots, and the entities still follow that line: slots that do the same job share their reference stats, reward, spawn delay, and gimmick.

| Slot | Redcliff | Astral | Sky | Korblox | Overseer |
| --- | --- | --- | --- | --- | --- |
| 1 | Traveler | AstralInitiate | SkyBirdWarrior | KorbloxMage | OverseerMinion |
| 2 | RedcliffPawn | AstralWizard | SkyLeader | KorbloxSkeleton | OverseerWanderer |
| 3 | RedcliffSquire | AstralKnight | SkyWindAxe | KorbloxGeneral | OverseerOrb |
| 4 | RedcliffGuard | AstralGuardia | SkyStealther | KorbloxGremlin | OverseerGuard |
| 5 (charger) | WallSmasher | AstralNecromancer | SkyFlyingGoon | KorbloxImperium | OverseerCharger |
| 6 (sprinter) | CourageBearer | AstralSentry | SkyMage | KorbloxSkeletonDefender | OverseerWingwalker |
| 7 (winged) | WingedRedcliff | AstralAdventurer | SkyGuardian | KorbloxElder | OverseerMage |
| 8 (elite) | RedcliffEnforcer | AstralAdventurer | SkyGuardian | KorbloxDeathspeaker | OverseerKnight |
| 9 (boss) | RedcliffChampion | AstralSentinel | SkyKnight | KorbloxDeathRaider | OverseerKing |

Astral and Sky have eight models, so `AstralAdventurer` and `SkyGuardian` fill both the winged and the elite slot.
They are one entity each, with the winged slot's reference stats; the wave entries that stand in for the elite carry an explicit `Reward` and `SpawnDelay` with the elite's values.
The repeat is on the lower step so the boss keeps the one moment it must be unmistakable: the elite and the boss appear together in the last wave.

Each cast is declared weakest to strongest in `Mob.Entities`, the order the `Workspace.Weakest` and `Workspace.Strongest` parts line the models up in.
**The ruler is art documentation only; nothing reads it at runtime.**

### Gimmicks

Gimmicks are declared on the entity, so each model has exactly the moves listed on it.
The moves several casts share are declared once at the top of `Mob.luau` and referenced from each entity; they are only read at runtime (per-enemy state stays in `GimmickState`), so sharing the table is safe.
`Mob.GetGimmicks(entity)` returns them, and `SpawnWave` calls it **once per wave entry**.

| Move | Entities |
| --- | --- |
| `PerTurnSpeedMultiplier` +30% (charger) | WallSmasher, AstralNecromancer, SkyFlyingGoon, KorbloxImperium, OverseerCharger |
| `PerTurnSpeedMultiplier` −15% (sprinter) | CourageBearer, AstralSentry, SkyMage, KorbloxSkeletonDefender, OverseerWingwalker |
| `HealthThresholdStunRandomUnit` | RedcliffChampion, SkyKnight, KorbloxDeathRaider, OverseerKing |
| `HealthThresholdRush` | AstralSentinel |

The Korblox Deathspeaker's Suffocate is not a gimmick: it is `SuffocateAbilityService`, configured in `Config.SuffocateAbility` by entity name.

The convert holds the victim's card.
When it leaves the match (killed or escaped), the card goes back to its owner's hand, at base level: upgrades and the cash spent on the unit are lost.
Loans never return a card, and an owner who left the server gets nothing.
`ResetRound` drops what is pending, since every hand is reloaded from the deck anyway.

To give an enemy its own move, change its `Gimmicks` list; no other entity is affected.

### `HealthThresholdRush` (the Astral Sentinel's dash)

At half health, the Astral Sentinel plays `Rush` and dashes: **double speed for 3 seconds**, starting at the animation's `Action` marker.
The field is `Amount`, applied as `RushScale = 1 + Amount`, so `1` means double.

The server times the dash with `MarkerTime` (0.5667 s of the 3.25 s animation `rbxassetid://98921075157550`), the same way the Champion's stun uses `AnimTime = 1.3`.
Speed is match state, and match state never comes from a client message: with N players there would be N messages at N pings, and one tampered client could speed up everyone's boss.
The client plays the same animation at the same moment, so the dash lines up on screen.

`RushScale` is its own factor in `computeSpeed`, separate from the stack-based `SpeedScale` and from `CurrentSpeed`, so it can expire after 3 seconds without taking an ice slow that started during it.

One-off animations reach the client through `MobPlayAnim(mobId, name)` and `playOneShotAnimation(mobId, name)`, which keeps one track per name in `movement.oneShotTracks` so `applyTimeScale` reaches all of them at 2x speed.

## Configuration

| Key | Where | Effect |
| --- | --- | --- |
| `Mob.Entities` | `SharedConfig.Mob` | One entry per model: folder, reference health and speed, boss flag, gimmicks |
| `ENTITY_DATA` | `Config.Wave` | Cash per kill and spawn delay per entity |
| `Enemies`, `Spawn.Entity` | `Config.SuffocateAbility` | Who casts Suffocate and what the convert becomes |

## Studio setup

A new model needs an entry in `Mob.Entities` with its name and `Folder`, plus a reward and spawn delay in `Config.Wave`'s `ENTITY_DATA`.
The model itself needs:

- **An R6 rig** with the usual part names (`Head`, `Torso`, `Left Arm`…) and `HumanoidRootPart` as `PrimaryPart`.
  `createEntity` unanchors everything but the root, removes the `Humanoid`, and moves the model by its pivot.
- **A walk animation:** either the `SlowWalk` + `FastWalk` pair (so `updateWalkAnimation` switches stride with speed, as the Wall Smasher and Courage Bearer do) or a single `Walk`.
  Without either, the generic `Entities.Walk` plays, so the enemy never slides across the map in a T-pose.
- **`Attack`**, if the entity has a gimmick that plays an attack (the boss stun).
- **A compatible bounding box.**
  Height can vary (`PathOffsetY` is computed at runtime), but a model that is too wide is removed by `checkIsOnGrid` in the movement loop.

If the `Rush` animation is re-exported, measure `MarkerTime` again: it is the only place in the code that hardcodes a number from inside an asset.
Use `KeyframeSequenceProvider:GetKeyframeSequenceAsync(id)` and find the `KeyframeMarker` named `Action`.

## Known issues

- Three bosses still use the Champion's stun: Sky Knight, Korblox Death Raider, and Overseer King.
  None of them has an `Attack` animation, so the 1.3 s pause plays with no gesture.
  Each should get its own move, as the Astral Sentinel did.
- Many new models have no published `Animation` and fall back to the generic walk.
  At the last count, per folder: 4 of 8 in `Easy`, 7 of 8 in `Medium` (only `SkyKnight` has its own), 8 of 9 in `Impossible` (only `KorbloxDeathRaider`), and 7 of 9 in `Nightmare`.
  Publishing and attaching the animation is art work; no code changes are needed.
- None of the models outside the `Hard` folder has the `SlowWalk`/`FastWalk` pair.
