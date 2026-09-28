# Match speed

The `Interface.Speed` button speeds up the whole match, and `GameClock` is what makes every gameplay duration follow it.

**Runs in:** Game
**Code:** [`SpeedController`](../../Game/src/Controllers/SpeedController.luau), [`SpeedService`](../../Game/src/Services/SpeedService.luau), [`GameClock`](../../common/shared/Util/GameClock.luau), [`SpeedConfig`](../../common/shared/Config/SharedConfig/SpeedConfig.luau)

## How it works

### The button

The button's art shows **the speed the match is at now**.
Clicking it expands the options: the button clones itself once per remaining step in `SpeedConfig.Steps`, each clone with its step's art, sliding out along the X axis.
Clicking a clone requests that speed and closes the options; clicking the original (the current step) just closes them.

| Step | Scale | Requires |
| --- | --- | --- |
| 1 | 1x (default) | |
| 2 | 1.5x | |
| 3 | 2x | the `Speed` game pass |

A step with a `Gamepass` (a key of `GamepassConfig.PASSES`, not the id) appears locked (a black veil and a padlock) for players without the pass, and clicking it opens the purchase prompt instead.
`SpeedController.purchased` covers the round trip after a purchase, so the player is not prompted again before the profile updates.

The button has the same press "pop" as the Lobby HUD buttons: it shrinks to 0.9 while pressed (`Circular`) and springs back (`Back`), playing `UIClick` on release.

### The speed belongs to the server

The whole simulation (enemies walking, towers attacking, waves spawning) runs on the server, so either everyone plays faster or nobody does.
Clicking speeds up the match for everyone, and every player's button art changes at the same moment.

The client **requests the step it wants** (`SetGameSpeed(index)`), not "advance one": two players clicking at once both land on 1.5x instead of pushing each other to 2x.
`SpeedService` validates the index (`SpeedConfig.IsValid`), ignores repeated clicks from the same player within `CLICK_COOLDOWN` (0.15 s), and fires `GameSpeedChanged` to the room.
The local art changes only on that confirmation.

`SpeedService` is round-scoped in `WaveService`, so **a new match starts at 1x**.

### Overrides

`SpeedService:SetOverride(scale, duration)` imposes a scale outside the button for `duration` **real** seconds; the Time Acceleration round card uses it for 3x, which is not a button step.
The button keeps showing the room's step, and only the clock changes.
When the override expires, the clock returns to whatever step is active *then*, since someone may have clicked during it.

### `GameClock`

There is no "×2" rule spread across the game's durations.
Gameplay compares instants against a clock, and speed changes **the source of "now"**: `GameClock` adds `dt * scale` on every Heartbeat, so cooldowns, stuns, buffs, and spawn cadence shrink together without touching any config value.

```lua
local now = GameClock.Now()          -- instead of os.clock()
local step = GameClock.Scaled(dt)    -- a Heartbeat dt in match time
GameClock.Wait(3)                    -- task.wait in match time
```

- **It starts at `os.clock()` on purpose.**
  Much code does `now - (entry.lastAttack or 0)`, relying on a large number on one side and zero on the other to mean "never attacked, may attack now".
  A clock starting at zero would make a new unit wait one extra cooldown.
- **`Wait` re-checks every frame** instead of converting to real seconds at the call, so changing speed during a 3 s wait shortens what is left of it.
- **The minimum scale is 0.01**: with zero, `Wait` would never return.
- **Each machine has its own copy**, and `SpeedService` keeps them in sync by broadcasting every change.
  The client needs it because `MobController` moves enemy models by `speed * GameClock.Scaled(dt)`, the same scaled `dt` `MobService` uses; otherwise the server would deliver an enemy to the base while its model was still mid-path.

| Where | What shrinks |
| --- | --- |
| `MobService` | distance walked per frame, spawn cadence (`SpawnDelay`), gimmick stuns |
| `UnitService` | attack cooldown, windup, `HitInterval`, stuns and charge |
| `WaveService` | the pause between waves (`WaveInterval`) |
| `ThunderService` / `SnowService` | the interval between lightning strikes and between freezes |
| `MobController` | enemy steps on screen and their animation speed |
| `Classes.Unit` | the attack animation and client-side hit waits |
| `TargetingController` | the path-progress cache, at the server's pace |
| `TripmineController` | the thrown mine's arc (see [Units](units.md#subspace-tripminer-mines)) |

### What stays in real time, on purpose

- **The intermission before a wave** (`runIntermission`): it is time for the player to build, and the `ReadyWave` button already shortens it.
- **Path arrows** (`getArrowLeadTime`): `WaveController` animates them in screen time; shortening only the server side would put enemies on the map with the arrow mid-route.
- **VFX, result screens, and network throttles** (damage flush, aura VFX): speeding those up takes reading time away from the player without speeding up the match.
- **Particle cleanup** (for example `EXPLOSION_LIFETIME` in `TripmineController`): particles do not follow the match clock.

Farm income is paid **per wave** (`payFarmUnits` on `Signals.Ended`), not per second, and end-of-match rewards are per wave survived, so speed changes the pace of a match, not what it pays.

## Known issues

- **The `Speed` game pass is only enforced on the client.**
  `SpeedService:SetIndex` validates the index but does not check whether the requesting player owns the pass, so a modified client can request 2x without it.
