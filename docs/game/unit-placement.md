# Unit placement

How a player places a unit: the placement ghost, what blocks a position, and the mouse and touch flows.
The client paints the ghost green or red and the server accepts or refuses; both must give the same answer.

**Runs in:** Game
**Code:** [`UnitPlacementController`](../../Game/src/Controllers/UnitPlacementController.luau), [`UnitService`](../../Game/src/Services/UnitService.luau), [`CollisionService`](../../Game/src/Services/CollisionService.luau), [`PlacementUtil`](../../common/shared/Util/PlacementUtil.luau), [`PointerUtil`](../../common/shared/Util/PointerUtil.luau)

## What blocks a position

The same rules run on both sides, and `PlacementUtil` holds the shared ones.
There are four checks, in this order:

1. **Path:** `GetPartsInPart` against parts tagged `Grid`, using the unit's box stretched `PathClearance` studs downward.
2. **Generic obstruction** (client only): any world part inside the ghost's `PrimaryPart`.
   Accessories never show up here, because `CollisionService` turns off their `CanQuery`.
3. **Characters:** `PlacementUtil.FindBlockingCharacter`, using the unit's full bounding box.
4. **Minimum distance** to another placed unit.

The server also checks the player's cash and remaining cards (`PlaceUnit` in `UnitService`).
In Studio, every refusal is logged by the `UnitService/Place` and `UnitPlacementController` loggers.

### The path (tag `Grid`)

Parts tagged `Grid` are the path: thin rails (0.25 studs) lying on the map's floor.
The rule is simple: a unit never stands on the path.

```lua
local probeCF, probeSize = PlacementUtil.PathProbe(cf, unitBounds)
-- the unit's box plus a column of PlacementUtil.PathClearance studs under it
```

The client uses this box every 0.05 s to paint the ghost, and the server uses the same box in `PlaceUnit`.
The server is the authority; the client only avoids offering a spot that will be refused.

The column under the unit (`PathClearance`, 4 studs: the tallest enemy, with margin) closes a gap.
Testing only the unit's volume, anything that lifted it above the rail (the corner of a rock, a 25 cm step, the side of a ledge over the path) took the path out of the box.

### Characters

A unit is never placed inside a player, including yourself.
The box is the unit's **full** bounding box: the ghost is drawn at 80% scale, but the whole unit will occupy the ground.
Accessories do not count: hats and wings stick out far from the body and would refuse a spot that looks empty.

Only player characters count.
Enemies do not exist as models on the server (`MobController` clones them on the client), so blocking them only on the client would paint the ghost red where the server would accept it.
Placed units are already covered by the minimum distance.

The floor raycast excludes only the ghost and the local player: aiming at another player still rests the ghost on them, and check 3 paints it red.
The floor raycast does **not** filter `Grid` parts, because they are the visible floor of the path; ignoring them would draw a unit accepted in the air standing on the path.
`replicatePlacedUnit`'s ground snap is capped (`MAX_GROUND_SNAP`, 1 stud): it only corrects the ~20 cm between the 80% ghost and the full-size unit.

## The ghost does not collide

Three measures, and the first is the one that matters:

1. **The `PlacementGhost` collision group.**
   Ghost parts join a group that collides with nothing, itself included.
   `CollisionService` registers it, because `PhysicsService:RegisterCollisionGroup` only runs on the server; the registration replicates and `UnitPlacementController` only assigns it.
   The group name lives in `PlacementUtil.GhostCollisionGroup`.
2. **`CanCollide = false`** on every part, as a fallback in case the group was not registered.
3. **`EvaluateStateMachine = false`** on the Humanoid, set **before** parenting to the Workspace.
   Entering a new state (Running, Landed…) makes the Humanoid turn the torso's `CanCollide` back on, and entering the Workspace triggers the first evaluation.

The Humanoid **must** stay: because of a [long-standing engine bug](https://devforum.roblox.com/t/highlight-does-not-work-with-transparency-on-non-humanoid-models/2731329), a `Highlight` does not render on transparent parts of a model without a Humanoid, and the ghost is semi-transparent.
Without it, the green and red highlight disappears.

> ⚠️ **Nothing but the ghost may join `PlacementGhost`.**
> Placement queries use `OverlapParams` in the `Default` group, and the params' group is what counts.
> A world part inside `PlacementGhost` would be invisible to those queries: terrain the ghost passes through without turning red.

**Characters have their own group, `Character`** (`PlacementUtil.CharacterCollisionGroup`).
Every BasePart of every player character joins it, including accessories that arrive after `CharacterAdded` (a `DescendantAdded` stays connected).
The group is registered **before** the loop that makes the ghost non-collidable with every group, because a new group starts out colliding with the existing ones.
Check this again if a third group is ever added.

The same pass turns off `CanQuery` on every accessory part.
The problem with accessories was never physics; it was queryable parts far from the body.
Turning it off on the part makes the rule hold for every query in the game.
`FindBlockingCharacter` still queries in `Default`, which the `Character` group collides with, so a player standing on a spot still blocks it.

## Mouse and touch

Pointing (the ghost, selecting a placed unit, hovering an enemy) goes through [`PointerUtil`](../common/controls.md#pointerutil), so the same code works with a mouse and a touchscreen.

- **PC:** the ghost follows the cursor, `R` rotates, a click confirms.
- **Touch:** a finger drags the ghost, two buttons in the thumb cluster do `ROTATE` and `LOCK`, and **a double tap places**.
  Tapping the equipped card again cancels, as on PC.

### `LOCK`

| | Unlocked | Locked |
| --- | --- | --- |
| Drag | moves the ghost | turns the camera |
| Tap | moves the ghost | nothing |
| Double tap | places | places (on the ghost) |

Unlocked, the whole screen is a placement surface and the camera does not turn.
Locked, the ghost freezes and dragging turns the camera again, so the player can look around without pushing the unit.

**Locking freezes a world position, not a screen point.**
The camera moves with the player, so the same screen point would land elsewhere after two steps.
While `lockedPosition` exists, the loop does **not** raycast again; it builds `targetCF` from the anchor plus `currentRotation`, so `ROTATE` still works while locked.
The anchor is `targetCF`, the position that passed the checks and would be sent to the server.
Validation keeps running on the anchor every `OVERLAP_CHECK_INTERVAL`, because the world changes under a still ghost.

### Taking the drag away from the camera

The default camera's touch pan is bound by `PlayerModule` through `ContextActionService`.
Placement binds its own action on top (`BindActionAtPriority` with `Enum.ContextActionPriority.High`) and returns `Sink` while unlocked, `Pass` while locked (it still needs the taps for the double tap).
Nothing in `PlayerModule` is touched.

`ContextActionService` delivers a touch even when it lands on a button, so `isOverInterface` checks with `GetGuiObjectsAtPosition`; otherwise pressing `ROTATE` would move the ghost under the button.

### The double tap

The two taps must come within `DOUBLE_TAP_WINDOW` (0.45 s) and `DOUBLE_TAP_RADIUS` (55 px) of each other, and a drag does not count as a tap.
Locked, the second tap must also land **on the ghost**, within a radius that follows the ghost's size on screen (at least `GHOST_TAP_MIN_RADIUS`, 60 px).
Unlocked, that test is skipped: the first tap already moved the ghost there, and the ghost chases its target by lerp, so it may still be on its way.

The "not here" signal is the ghost's green or red `Highlight`.

### Sending the target, not the ghost

What goes to the server is `targetCF`, the position that passed the checks, not `ghostCF`, which chases it by interpolation.
With a mouse the difference was invisible; with touch, the player lifts the finger and taps again while the ghost is still moving, and the unit would spawn mid-way.

## Configuration

| Key | Where | Value |
| --- | --- | --- |
| `PathClearance` | `PlacementUtil` | `4` studs under the unit |
| `GhostCollisionGroup` | `PlacementUtil` | `"PlacementGhost"` |
| `CharacterCollisionGroup` | `PlacementUtil` | `"Character"` |
| `MAX_GROUND_SNAP` | `UnitPlacementController` | `1` stud |
| `DOUBLE_TAP_WINDOW` / `DOUBLE_TAP_RADIUS` | `UnitPlacementController` | `0.45` s / `55` px |
| `GHOST_TAP_MIN_RADIUS` | `UnitPlacementController` | `60` px |

## Known issues

- **Surfaces more than 4 studs above the path** (bridges, roofs, cave ledges) still accept units.
  This is on purpose: blocking them would remove real building space (most roofs on SnowyCastle).
  To block them, replace the finite column with a ray down to the floor.
- **The CFrame comes from the client.**
  The server checks path, characters, distance, cash, and cards, but not whether the unit rests on something: aiming at a wall still leaves the unit floating next to it.
