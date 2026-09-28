# Units

How placed units attack: the server-side attack cycle, projectiles, hits on several enemies, damage over time, chained lightning, and the Entrepreneur farm.

**Runs in:** Game
**Code:** [`UnitService`](../../Game/src/Services/UnitService.luau), [`MobService`](../../Game/src/Services/MobService.luau), [`Unit` class](../../common/shared/Classes/Unit.luau), [`ProjectileController`](../../Game/src/Controllers/ProjectileController.luau), [`VFXController`](../../Game/src/Controllers/VFXController.luau), [`UnitStats`](../../common/shared/Config/SharedConfig/UnitStats.luau), [`UnitAttackConfig`](../../common/shared/Config/SharedConfig/UnitAttackConfig.luau), [`UnitUpgradeConfig`](../../common/shared/Config/SharedConfig/UnitUpgradeConfig.luau)

The roster is defined in `UnitStats`: Archer, Archmage, Azure, Berserker, Electro, Entrepreneur, Frostione, Pyre, Rocket, Slasher, Slingshot, Subspace Tripminer, and Sword.
The header of `UnitStats` documents every field and the balance rules (such as the damage-per-cost cap in rule 1).

## The attack cycle

An attack is always a single server-side request.
`UnitService` records `lastAttack`, waits for the windup (the step's `HitTime` in `UnitAttackConfig`), and applies the `Hits` from `UnitStats`, one every `HitInterval`.
The client only plays the animation (`Unit:playAttackVisual`).

### Irregular hits: `HitTimes`

Regular spacing does not fit every combo.
The Berserker's four hits land at 0.4333 s, 1.2667 s, 2.3833 s, and 2.5667 s of its `Attack` animation: 0.83 s apart, then 1.12 s, then 0.18 s.
For that, an attack step accepts `HitTimes`, a list of instants, instead of `HitTime`:

```lua
["Berserker"] = {
    AttackSequence = {
        { Animation = "Attack", HitTimes = { 0.4333, 1.2667, 2.3833, 2.5667 }, Duration = 2.9 },
    },
},
```

When the list is present, it decides: the number of hits is its length and the intervals are the differences between the instants.
`HitTime` and `HitInterval` are ignored for that unit.
`Hits` in `UnitStats` must still equal `#HitTimes`, because the card's DPS comes from it.

**The numbers are the animation's `Hit` markers, copied by hand.**
The server applies the damage and has no `AnimationTrack` to listen to.
If you move a marker in Moon Animator, update the list here too, and `Duration`, which is the animation length.

**The cooldown counts the whole animation.**
`Cooldown` is from the start of one attack to the start of the next, so the Berserker's `2.9 + 3.1 = 6` includes 3.1 s standing still after the animation.
That window is the same `swingWindow` the server sends, so the client never squeezes the animation and the recovery is visible.

`Duration` covers the opposite case.
If a round card of attack speed shortens the cycle below the animation, the client shrinks the gesture to fit and the server scales the instants by the same factor (`UnitService:executeAttack`).
Otherwise the end of the combo would land after the next attack had started.

### Health bars show the damage that landed

The client does not receive each enemy's health on every hit.
It keeps a copy (`MobHealth` in `MobController`, written once on `SpawnClientMob`) and subtracts the number carried by `AttackVisual`.
Nothing corrects that copy later, so the number sent must be exactly what the server applied.

That is why `UnitService:creditHit` sends what `MobService:DamageMob` **returned**, not what the unit asked for.
`DamageMob` applies multipliers the caller does not see (the brittle effect of the Staff of Azure Ever Ice and the bleeding wound), and cuts a lethal hit to the health that was left.
A hit that touched nobody (the target died during the windup) is left out, because `DamageMob` returns 0.

Damage without an attacking unit reaches the client through `MobDamageTick`: burn and bleed ticks, and each enemy hit by a Tripminer mine (the mine has no `AttackVisual`).

## Projectiles

A unit that shoots declares a `Projectile` in `UnitStats`, and both sides read it.
The client draws the flight (`ProjectileController`, called by `Unit:playAttackVisual`) and the server decides who takes damage (`UnitService:executeAttack`).
**The projectile on screen never decides damage**: it can miss visually after the hit has already been credited.

### Origin

A projectile starts at the unit's `RootPart` (`Unit:projectileOrigin`).
There is no offset in code on purpose: if a unit should shoot from higher up (the bow tip, a barrel), that is a part in its model, not a number added for every unit.
Reading the root is also safer than reading the pivot: `GetPivot` follows `WorldPivot`, which moves with the animation pose once the `PrimaryPart` is lost.

### Piercing arrows: `Subtype = "Piercing"`

Only the Archer uses it.
The attack is no longer "the target" but **the line** from the unit, through where the target will be, out to the unit's **range**.
Everyone on that line takes damage, including enemies behind the target.

| Piece | Where |
| --- | --- |
| Who is on the line | `MobService:GetMobsAlongLine(origin, through, length, width)` |
| The damage | the `pierce` branch of `executeAttack`, before the single-target branch |
| The drawing | `ProjectileController:_flyThrough` |

`PierceFalloff` (0.1 on the Archer) makes each enemy pierced take 10% less than the previous one.
The falloff is **compounded**: 16 damage becomes `16, 14, 13, 12, 10, 9, 9, 8`, so eight enemies in a row take **91** instead of 128.
Compounding never reaches zero, where subtracting 10 points each time would make the 11th take nothing and the 12th take negative damage.
Rounding is the same as `getDamage` (`math.floor(x + 0.5)`) with a floor of 1.

Three rules matter:

- **The line is measured on the horizontal plane.**
  Units stand on platforms and enemies walk on the ground, so a 3D check would call an enemy on the path "far from the line" just for being lower.
- **The direction is frozen when the shot fires.**
  A normal projectile homes in on its target; a piercing one must draw the line the other enemies are hit along.
  `onArrive` fires when it **passes** where the target was.
- **It aims at the predicted position** (`PredictPosition`), the same one the client used.

If the target leaves the line between aiming and firing (it turned a corner during the windup), it still takes the hit.

### Impact bursts

A projectile with an attachment named `Explosion` bursts on arrival; one without it just disappears.
It is a property of the asset, so hanging the attachment on a new projectile is enough.

The `PyreProjectile` has two attachments: `Ball`, whose **enabled** emitters draw the trail, and `Explosion`, whose **disabled** emitters only fire on impact through `Emit`.
On arrival, `ProjectileController` stops the trail, fires the burst, and makes the shell invisible and anchored (the template is unanchored and the flight loop just released it).
The part is destroyed after the burst emitters' longest `Lifetime`.
That delay uses `task.delay` and not `GameClock`, because `ParticleEmitter` does not know the match speed.

Only an arrival bursts.
A projectile that runs out its 3 s `MAX_FLIGHT_TIME` without reaching anyone disappears silently, and piercing projectiles (`_flyThrough`) never burst.

## Hitting several enemies

There are four ways one attack hits more than one enemy:

| Mechanism | Who it hits | Falloff |
| --- | --- | --- |
| Area (`AOE`) | everyone within the radius of the aim point | none per target; `HitFalloff` per hit in a combo |
| Piercing arrow | everyone on the line | `PierceFalloff` per enemy |
| Cleave (round card) | everyone on the line of the swing | `Falloff` per enemy (see [Round cards](round-cards.md)) |
| Chain (`Chain`) | enemies reached by jumping from one to the next | none |

### Areas that weaken with each hit: `HitFalloff`

Each of the Berserker's four hits is an area with radius 3, and each hits less than the previous one:

```lua
AOE = { Radius = 3 },
HitFalloff = 0.1,
```

| Hit | Fraction of full | Damage (base 39) |
| --- | --- | --- |
| 1st (0.4333 s) | 100% | 39 |
| 2nd (1.2667 s) | 90% | 35 |
| 3rd (2.3833 s) | 81% | 32 |
| 4th (2.5667 s) | 72.9% | 28 |

The combo is worth 3.44 full hits instead of 4.
The falloff is **per hit, not per target**: everyone in the area of the second hit takes the same 32.
It is compounded, like `PierceFalloff`, and rounding happens once, when the damage is applied.
The field works for any unit with several `Hits`, spaced by `HitInterval` or `HitTimes`; without it, every hit in the cycle is worth the same (as the Azure's are).

### Chain lightning (Electro)

```lua
["Electro"] = {
    Damage = 18,
    Cooldown = 2.5,                                -- fixed; upgrades do not change it
    Chain = { Targets = 4, Radius = 8 },
    Stun  = { Duration = 0.3, MaxDuration = 0.5 },
}
```

The first link is the target the tower's priority picked.
From there the bolt jumps to the closest enemy **to the last one hit** that is not in the chain yet and is within `Radius` of it, up to `Targets` enemies or until nobody is in reach (`MobService:GetChainTargets`).

**The radius is measured from each enemy, not from the unit.**
Three jumps of 8 studs reach 24 studs from a unit with range 10, so the better the map lines enemies up, the farther the chain goes.
In exchange, it dies at a gap: an isolated enemy 35 studs from the previous one gets nothing.

**There is no falloff per enemy.**
The fourth takes the same 18 as the first.
Its price is in `Targets` and `Cooldown`; change those if the unit gets too strong.
A full chain is 28.8 DPS (9.6 per 100 cash, within rule 1 of `UnitStats`); against a single target it is 7.2 DPS, one of the weakest in the roster.

Each link also **stops in place** briefly:

| Field | What it does | Where |
| --- | --- | --- |
| `Stun` | takes the enemy out of the movement loop | `MobService:StunMob` |
| `Slow` | changes the speed it walks at | `MobService:ApplySlow` |

Both are generic fields any unit can declare, applied by `creditDamage` to every link that took damage.
The Electro declares only `Stun`.
The stun grows linearly with level through `UnitUpgradeConfig:GetStunDuration`, which reads `Stun.MaxDuration`:

| Level | 0 | 1 | 2 | 3 | 4 | 5 |
| --- | --- | --- | --- | --- | --- | --- |
| Stun (s) | 0.30 | 0.34 | 0.38 | 0.42 | 0.46 | 0.50 |

That is 12% to 20% of the cycle: a stumble, not crowd control.
Stopping enemies for real is what the Time Stop round card is for.

**The server picks the links and fires the drawing on the animation marker.**
`HitTime = 1.05` in `UnitAttackConfig` is the `Hit` marker of the `Attack` animation.
On the same line where the chain applies damage, the server fires `ChainLightning` with the links in jump order.

| Listener | What it does |
| --- | --- |
| `VFXController` | an arc from the unit to the first link and from each link to the next |
| `MobController` | the yellow highlight (`255, 200, 60`) on each enemy while the stun lasts |

The arc uses the same asset as the weather lightning (`WeatherConfig.Thunder.Asset`, through `spawnBeam`).
The ends use the enemy models once they have replicated, because the client simulates enemy movement and the server position is a few frames behind.

The weather asset is authored as a bolt from the sky: a `CraterVFX` tag with 40 debris pieces, plus `CameraShake` and `ImpactFrames`.
Per link, that would mean four camera shakes and 160 debris pieces on every attack.
`spawnBeam` accepts an optional `impact`, and only the chain passes one (`CHAIN_IMPACT` in `VFXController`): a smaller crater (6 debris in a radius of 3), without shake or impact frames.
Those two are turned off by **removing** the attribute, which is how the addon checks for them (`if not attr then return end`); setting it to zero would still enable the effect.
Changes are made on the clone only.

The Electro is the first `Electric` unit, so it is the one that uses the Thunder weather bonuses (see [Weather in a match](weather-in-match.md)) and the Electric round cards.

## Damage over time

### Burn (Pyre)

The Pyre fires a single `PyreProjectile` for 15 damage with `AOE = { Radius = 3 }`, and every enemy hit starts burning: 3 damage every 0.5 s for 10 s (`UnitStats.Pyre.Burn`, applied by `MobService:ApplyBurn`).

- **A burn does not stack or refresh.**
  Hitting an enemy that is already burning, from the same Pyre or another, only deals the hit damage.
  A new burn starts only after the current one ends (`mob.BurningUntil`).
- **The area spreads the burn, not only the damage.**
  `creditDamage` runs once per enemy hit, so in a tight group one shot can set four enemies burning, each on its own timer.
- The ticks are credited to whoever started the burn.
- The server fires `MobBurning` only when a new burn starts; `VFXController:PlayBurning` welds `Assets.VFX.BurningVFX` to the enemy (through `playMobStatus`, the same path as the Frostione freeze).

The burn does not scale with upgrades or weather; only the Fire Hazard round card changes it.
The Pyre's cost (150), range (10), and cooldown (2.1 s, just above its 2.033 s animation) are provisional.

### Bleed (Slasher, Berserker)

Every Slasher hit makes the target bleed: 1 damage per second for 5 ticks (`UnitStats.Slasher.Bleed`, applied by `MobService:ApplyBleed`).
Burn and bleed share `MobService:applyDamageOverTime` and its rules: no stacking, no refresh, ticks credited to whoever opened the wound.
Bleeding has its own timer (`mob.BleedingUntil`), so an enemy can burn and bleed at once, and its own drawing (`Assets.VFX.BleedVFX` through `MobBleeding` and `VFXController:PlayBleeding`).

Bleeding also opens a **wound**: while it lasts, **all** damage the enemy takes is worth 30% more (`Bleed.Vulnerability = 1.3`, stored in `mob.BleedVulnerability`).
`MobService:DamageMob` applies it, like the brittle effect of the Staff of Azure Ever Ice: it is the enemy that is weaker, not a tower buff, so it counts for any source.
That is the Slasher's real value: it marks targets for the rest of the team.
Two Slashers on the same target do not double anything.

The **Berserker** bleeds through the same path, with 4 damage per second for 5 ticks and the same 30% wound (`UnitStats.Berserker.Bleed`).
`creditDamage` applies it to every enemy in each hit's area.
Because bleeding does not stack, only the first of the four hits opens the wound; the other three deal their hit damage plus 30%.

## Entrepreneur: the farm with an aura

The Entrepreneur does not attack.
At the end of each wave it pays its owner what `UnitUpgradeConfig:GetIncome` returns for its level (`Incomes` in `UnitUpgradeConfig`; `Farm.Income` in `UnitStats` is level 0).

It also has an **aura**: every allied unit within its range earns a percentage more cash on top of what it earns **from damage and kills**.
It works for any owner (a neighbor's tower near my farm earns more too), and the bonus goes to the owner of *that tower*.

### The radius is the `Range`

The aura radius is the Entrepreneur's `Range` from `UnitUpgradeConfig:GetRange`: the same circle the player sees when selecting the farm, weather included.
There is no separate `Radius` on purpose; with two numbers, one would lie about the other.

Only the percentage is configured, in `UnitStats.Entrepreneur.Farm.Aura`:

```lua
Aura = { Bonus = 0.10, BonusPerUpgrade = 0.05, MaxBonus = 0.30 },
```

- **Auras stack:** two level-0 farms covering the same tower give 20%.
- `BonusPerUpgrade` is added, not multiplied, so the card can show round percentages.
- `MaxBonus` caps the total, which is what limits stacking.
  It is why levels 4 and 5 both give 30%: the last upgrade buys income and range, not aura.

`UnitUpgradeConfig:GetAuraBonus(unitName, level)` does the math, and both the server and the card read it.
It is the only getter in `UnitUpgradeConfig` that does **not** take `weather`: the bonus is economy, and economy does not follow the weather (`payFarmUnits` also pays income without weather).

| Level | 0 | 1 | 2 | 3 | 4 | 5 |
| --- | --- | --- | --- | --- | --- | --- |
| Income per wave | 60 | 75 | 95 | 120 | 150 | 225 |
| Aura | 10% | 15% | 20% | 25% | 30% | 30% |
| Range | 4 | 5 | 5 | 6 | 7 | 8 |

### On the upgrade card

A farm does not attack, so its attack speed line is reused for the bonus, as the DPS line is reused for the income:

```text
$60 PER WAVE          (DamagePerSecond)
10% PER UNIT BONUS    (AttackSpeed)
4 RANGE               (Range: the aura radius)
```

The [next-level preview](upgrade-card.md) works for free, because it uses the same formatters with `level + 1`.
"PER WAVE" says when the income arrives, and "PER UNIT" says the bonus is a percentage of what *each* unit in range earns, not money the farm pays.
A farm without `Aura` shows its cooldown again: `formatCooldownOrBonus` checks for the bonus, not the unit name.

### How the money flows

`UnitService:getAuraBonus` adds up the farms that reach a unit and returns the fraction.
It is **frozen at the start of the attack**, with damage and range (`executeAttack`), so selling the farm mid-combo does not change the hits of that cycle.
For Tripminer mines, the distance is measured to the **unit**, not the mine.

The fraction goes through `MobService:DamageMob(..., cashBonus)` into both the damage reward and the kill reward.
The list of aura sources (`AuraSources`) is rebuilt every frame in `stepCombat`, which already scans every unit, so there is no state to invalidate when units are placed, sold, or the round restarts.

Rewards are small integers: 15% of a 3-cash kill is 0.45.
`MobService:applyCashBonus` keeps the remainder per player (`BonusRemainder`) and pays it once it passes 1, so a small bonus pays slowly instead of never.
The remainder resets when the round restarts and when the player leaves.

### The effect

Each time a unit earns extra cash, the server fires `AuraBonusVFX` with the `unitId`, and `VFXController:PlayAuraBonus` clones `Assets.VFX.MoneyEntrepreneur` **inside the unit's `HumanoidRootPart`**, so it follows the model without a weld.
The `vfx` module handles `EmitCount`, `EmitDelay`, and cleanup from the asset itself.

The effect is throttled per unit (`AURA_VFX_COOLDOWN`, 0.35 s): a Rocket inside the aura would otherwise send ten effects in the same frame.
The bonus still applies to **every** hit; only the visual is spaced out.

## Subspace Tripminer mines

The Tripminer does not shoot: it plants mines on the path, up to `Tripmine.BaseLimit` (3) plus `LimitPerUpgrade` (1) per level, capped at `MaxLimit` (6).
Planting (`UnitService:stepTripminer`) and triggering (`stepTripmines`) run on [`GameClock`](match-speed.md#gameclock).

### Throw, landing, and arming

A throw has two instants, both in match time:

1. **End of the windup** (`HitTime`, 1.15 s): the mine leaves the hand, the server fires `TripmineThrown`, and the client starts the arc.
2. **`ThrowTime` later** (0.35 s): the mine lands **and arms**.

`ThrowTime` lives in `UnitStats["Subspace Tripminer"].Tripmine` and travels in the event, so both sides spend the same number and the arc ends on the frame the trigger turns on, at any speed.
`pendingMines` releases a slot only on landing, so a mine in the air already counts toward the limit.
The arc reads the clock every frame, so speeding up the match with a mine in the air shortens what is left of its flight.

A mine arms on landing but not at full strength: it explodes for 35% of its damage (`Tripmine.Charge.StartDamage`) and rises linearly to 100% over 5 s (`Tripmine.Charge.Time`).
Stepped on at 2.5 s, it deals 67.5%.
Landing records `armedAt`, and `stepTripmines` applies `mineChargeFactor` on top of the full damage (upgrades, weather, and cards included).

### The trigger is a crossing, not a point

An enemy moves `CurrentSpeed * dt` per frame, and `dt` is already scaled by the match speed.
At high speed and a low server frame rate, one frame's step is longer than the trigger's diameter (`TriggerRadius`, 2.5 studs), and an enemy could walk through a mine untouched.
The fastest enemy moves about 57 studs/s (the `CourageBearer` on Nightmare with its turn gimmick fully stacked); at 3x and 20 fps that is 8.6 studs per frame.

`MobService:GetMobCrossing` asks **who passed near the mine this frame**, testing the distance from the mine to the segment the enemy walked.
`MobService` stores `mob.LastDistance` at the start of each Heartbeat, and the previous position is cached per frame, like the current one, so the cost stays linear.

The damage radius (`GetMobsInRadius`, `AOE.Radius` 6 studs) is still a snapshot at the moment of the explosion: with a 12-stud diameter it has plenty of margin.
A splash is a snapshot; a trigger is a crossing.

### The explosion happens on the ground

The server arms the mine on landing and the client spends the same `ThrowTime` drawing the arc, so normally the flight is over when `TripmineTriggered` arrives.
A speed change during a flight reaches the client one network trip later, though, and during that gap its arc runs slower than the server's timer.
`TripmineController:endArc` closes the gap: the trigger ends the arc and puts the model at its resting place before emitting.
`clearUnitMines` calls the same function without `snap`, since the model is going away.

### Cleanup

An exploded mine is removed after `EXPLOSION_LIFETIME` (5 s) of **real** time, 1 s after the asset's longest particle.
Particles do not follow the match clock, so speeding up the cleanup would cut the smoke short.
The only path that skips the scheduled removal is a model already destroyed (the unit sold or the round reset, through `clearUnitMines`).

Planting costs the unit's 5 s cooldown in match time, so at higher speed it plants more often per real second while cleanup stays at 5 s:

| Speed | Plants every | Exploded models alive |
| --- | --- | --- |
| 1x | 5.0 s real | 1 |
| 2x | 2.5 s real | 2 |
| 3x | 1.7 s real | 3 |

They are invisible (`Transparency = 1` on the frame of the explosion) and carry 12 `ParticleEmitter`s each.
A max-level Tripminer at 3x keeps about 9 models under `workspace.CurrentCamera` (6 armed plus 3 fading).
That is expected, not a leak: each has its own deadline.

## Design notes

- **Falloffs compound.**
  `PierceFalloff`, `HitFalloff`, and the Cleave `Falloff` all multiply by `1 - falloff` at each step, so they never reach zero or go negative.
- **The piercing arrow changes the balance math on maps that line enemies up.**
  The Archer's effective DPS is 8.0 times the number of enemies on the line; against a single enemy it is unchanged.
  If it becomes the obvious pick on some map, tune `Damage`, not the subtype.
- **The Berserker uses hand-made `Cooldowns` instead of `CooldownMultiplier`.**
  Its recovery is its identity: the ladder (6.00 → 5.80 → 5.50 → 5.25 → 5.10 → 4.80) shortens only the wait, never the animation, so even at max level 1.9 s of recovery remain.
  The 10% per level that Sword and Slasher get would cut the recovery to 0.58 s.
- **The Electro's cooldown is fixed;** upgrades buy damage, range, and stun.
- **The stun highlight lasts exactly as long as the stun.**
  Outliving its cause would make the player think the enemy is still stuck.
