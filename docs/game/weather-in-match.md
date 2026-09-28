# Weather in a match

During a match, `WeatherRoundService` decides **whether**, **which**, and **when** weather happens, and each weather changes how units and enemies fight.
Turning a weather model on and off is the shared [`WeatherService`](../common/weather.md).

**Runs in:** Game
**Code:** [`WeatherRoundService`](../../Game/src/Services/WeatherRoundService.luau), [`ThunderService`](../../Game/src/Services/ThunderService.luau), [`SnowService`](../../Game/src/Services/SnowService.luau), [`WeatherWarningController`](../../Game/src/Controllers/WeatherWarningController.luau), [`WeatherIndicatorController`](../../Game/src/Controllers/WeatherIndicatorController.luau), [`WeatherFeedbackController`](../../Game/src/Controllers/WeatherFeedbackController.luau), [`VFXController`](../../Game/src/Controllers/VFXController.luau), [`WeatherConfig`](../../common/shared/Config/SharedConfig/WeatherConfig.luau)

## Scheduling

On every wave start (`WaveService`'s `WaveStarted`), `WeatherRoundService:OnWaveStarted` does three things, in order:

1. removes the weather in the sky if its duration is over;
2. turns on the weather scheduled for this wave;
3. if nothing is scheduled or active, rolls a die, and on success picks a weather from the map's pool and **announces** it `LeadWaves` waves ahead.

The announcement is the point of the system.
Weather never arrives by surprise: the player sees three waves ahead what is coming, which turns weather from bad luck into a decision (time to sell what will be useless and place what will shine).

Only one weather at a time: the die is not rolled while one is scheduled or active.
A weather that would land after the preset's last wave is not announced.

**Duration** (`WeatherConfig.Round.Duration`): a weather stays for 4 waves and leaves at the start of the fifth.
Starting on wave 10, it lasts through wave 13 and is gone on 14.
While it lasts the die is not rolled, so the next announcement can only come from the wave the previous weather left.

**Pool per map** (`WeatherConfig.MapPools`), keyed by the map name in `MapConfig.MAPS`; a map not in the table has no weather.

| Map | Weathers |
| --- | --- |
| `Farm` | Fog, Wind, Thunder, Rain |
| `Desert` | Sandstorm, Drought |
| `Volcano` | Drought, Fog |
| `Cave` | Fog |
| `SnowyCastle` | Snow, Wind, Fog, Rain |
| `Mountain` | Snow, Wind, Fog, Thunder, Drought, Rain |
| `Snowy` | Snow, Wind, Fog |
| `Swamp` | Fog, Rain |
| `Beach` | Wind, Rain, Thunder, Drought |
| `Pale Garden` | Fog, Rain, Sandstorm, Snow, Thunder, Wind |

**Chance per difficulty** (`WeatherChance` in `Config.Difficulty`): 10% on Easy, 15% on Medium, 22% on Hard, 30% on Impossible, and 40% on Nightmare (0 in the tutorial, whose weather is scripted).
Since the die is only rolled with a clear sky, the number is not "how many waves have weather" but how quickly the next weather comes after the previous one leaves.

The [Weather Report](round-cards.md#the-instant-effects) round card clears the weather from the current wave only (`SkipCurrentWave`); `resumeActive` brings it back on the next wave if it has waves left.

### The on-screen warning

The name the player reads comes from `WeatherConfig.Warning.DisplayNames`, which today has one entry: `Snow` in code is **BLIZZARD** on screen.
Renaming the Model would drag along every map pool, the `weather` command, and the effect tables, only for the player to read the same word.

The warning is `StarterGui.Interface.WeatherWarning`, a `TextLabel` with a `UIStroke`.
`WeatherWarningController` only builds the sentence; [`WarningController`](../common/screen-warnings.md) animates it (and shares the label with the server restart warning).
Players who join mid-match ask for the pending warning with `RequestWeatherWarning`.

## The weather indicator

Two **sibling** pieces in `StarterGui.Interface`, wired by `WeatherIndicatorController`:

```text
Interface
├── WeatherButton        (ImageButton: the weather icon and the toggle)
│   └── New              (optional: the "open this" badge)
└── IndicatorWeather     (the panel; its UIScale is the animation)
    ├── WeatherImg       (ImageLabel: the same icon)
    ├── WeatherName      (TextLabel: "BLIZZARD")
    ├── Duration         (TextLabel: "WEATHER ENDS IN 3 WAVES")
    └── Container        (UIListLayout: one line per effect)
```

- **The button is a toggle**: pressed, the panel grows in through its `UIScale`; pressed again, it shrinks out.
  No reading time is counted; the player closes it.
  Hover and press come from the `AnimatedButton` tag that `UILibraryController` observes.
- **With no weather, there is no indicator**: the button hides and the panel closes.
- **The `New` badge insists until the panel is opened.**
  The optional `New` child of the button (name in `WeatherConfig.Indicator.Gui`) lights with the button until the panel has been opened **this match**.
  `Open()` retires it, whatever opened the panel.
  The state (`PanelSeen`) lives on the client and resets on `RoundRestarted`; nothing touches the profile.

### Effect lines

The lines in `Container` come from `WeatherConfig.Indicator.Details`, one per effect, written by [`RichTextController`](../common/rich-text.md) one after another (`Line.Stagger`).
The controller colors **pieces**, not the whole line: the number in blue (`Colors.Buff`) or red (`Colors.Debuff`), and the unit class in its class color (`Colors.Classes`).
The sign of the number picks blue or red, and `Kind` on the line overrides it when the sign misleads (`+40% ENEMY HP` grows and is bad for the player).
An unsigned number (`20s UNIT STUN`) is a debuff.

**Lines are only written with the panel at its rest scale**, never while it grows in.
Rich text stores the box size at render time and scales the text by the ratio between the current size and that one, and a child's `AbsoluteSize` is already multiplied by the panel's `UIScale`.
Writing mid-growth would memorize a nearly closed box, and the line would end up screen-sized (or not appear, if the scale was still zero).
The gate is `writeLinesWhenSettled`, and the rest scale is the one authored in the `UIScale`.

**Text size is measured from the box, not written in pixels**, which is what makes the panel work on phones.
`RichTextController:FitSize` does the math (see [Rich text](../common/rich-text.md)), tuned in `Indicator.Line.Fit`: `MaxRows = 2` and `WidthPerChar = 1` (Press Start 2P is almost monospaced).
The size is computed **once**, from the longest sentence, and used for every line.
The reserve line height is also a fraction (`HeightScale = 0.2`: five lines fill the `Container`), and rotating the phone rewrites the list (`ResizeDebounce`).

**The panel can grow with the screen, and today it does not**: its rest scale is `clamp(screenHeight / Responsive.ReferenceHeight, Min, Max)`, with `Min` and `Max` at 1.
`ReferenceHeight` is a screen **height** in pixels: the height at which the panel already has the desired size.
The **button** is left out, because its `UIScale` is where `AnimatedButton` writes hover.

`WeatherName` and `Duration` are plain labels whose typography belongs to the designer.
The controller turns on their `TextScaled` **capped at the authored size** with a `UITextSizeConstraint`; a label already scaled is left alone, and `Indicator.Labels.Scale = false` turns this off.

An optional line template, a `Container` child named `Line`, is cloned per effect (and never shown itself); without it, the controller creates a Frame `Line.Height` pixels tall.
Typography comes from `Indicator.Text` in both cases.

### Duration

`WeatherDuration` carries the weather name and the **target wave** (`ActiveUntilWave`), not "waves left".
The panel may open waves later and recomputes with the current wave (`SetWave`), counting the running one: a 4-wave weather that just started says "ENDS IN 4 WAVES" and its last wave says "ENDS IN 1 WAVE".
The name travels along because `WeatherDuration` and `WeatherChanged` are separate events with no guaranteed order (see [Events](../architecture/me-framework.md#events-are-not-ordered-with-each-other)).
Weather turned on by the `weather` command has no duration, and the label is hidden.
Players who join mid-storm ask with `RequestWeatherDuration`.

The list is **not the weather's documentation**: it is what the player needs to play the wave.
Magic's immunity to lightning exists in `Effects` but is not a line.

## Classes and effects

Each unit has a `Class` in `UnitStats`: `Melee`, `Ranged`, `Magic`, `Fire`, `Ice`, or `Electric` (a list is accepted for a unit with two classes).
It is the only place the class is written; `WeatherConfig.GetClasses` reads it.

| Unit | Class |
| --- | --- |
| Archer, Rocket, Slingshot | Ranged |
| Berserker, Entrepreneur, Slasher, Sword | Melee |
| Archmage, Subspace Tripminer | Magic |
| Electro | Electric |
| Frostione | Ice |
| Pyre | Fire |
| Azure | none yet |

A unit without `Class` still works: it only receives what a weather does to `All`.

Effects live in `WeatherConfig.Effects` and are **always multipliers** (0.7 means "down 30%"), so an effect weighs the same on a level 0 unit and a level 5 unit.

| Weather | Effect |
| --- | --- |
| **Fog** | range of every unit × 0.7; Magic suffers 1.5 times the cut (45%), so × 0.55 |
| **Wind** | enemy speed × 1.3; Melee attack speed × 1.3 |
| **Drought** | enemy health × 1.4; Fire +30% damage and +20% attack speed; Ice loses 60% damage, attack speed, and range |
| **Snow** (shown as "BLIZZARD") | attack speed of every unit × 0.6; Ice × 1.25 damage **and** attack speed; one unit frozen for 10 s every 30 s; Magic is immune |
| **Thunder** | lightning stuns; Electric gains 10% passive damage and a charge when struck; Magic is immune |
| **Sandstorm** | damage, attack speed, and range of every unit × 0.7; Magic is immune |
| **Rain** | **disables** every Fire unit; attack speed of every unit × 0.65 (Magic × 0.475); placing an Ice unit costs 25% less |

Precedence rules:

- **`Units.<Class>` replaces `Units.All`** for that stat, which is why Fog writes 0.55 for Magic instead of letting 0.7 and 0.55 multiply.
  The replacement is **per stat**: Rain's Ice entry only writes `Cost`, and Ice's attack speed still comes from `All`.
- **`Immune` takes the unit out of the weather entirely**: no debuff, no class buff, no freeze, no lightning, no disabling.

**`Disable` is not a multiplier.**
Rain turns Fire off: the unit stops attacking while the weather lasts, and `UnitService` skips it in the attack loop.
It is not a stun: it has no timer, no yellow highlight, and cannot be shortened; the unit returns when the weather leaves.

**`Cost` is the placement price**, applied through `UnitUpgradeConfig:GetPlaceCost`, the same function the server charges in `PlaceUnit` and the hotbar card shows.
Changing weather rewrites every card's price (`Card.refreshWeather`).

> **Selling does not follow the discount.**
> The server stores the **list** price in `entry.invested`, even when it charged less, because both sides compute the sell value from `GetInvested` and the client does not know what each unit actually cost (`invested` is not replicated).
> In practice the discount is still only an advantage: buying at 75 and selling at 50 is never a profit.

The multipliers enter `UnitUpgradeConfig`, not each caller: every getter takes an optional `weather` last.

```lua
UnitUpgradeConfig:GetRange("Slingshot", 0)          -- 12
UnitUpgradeConfig:GetRange("Slingshot", 0, "Fog")   -- 8.4
UnitUpgradeConfig:GetCooldown("Slasher", 0, "Wind") -- 0.85 / 1.3
```

That is what makes server and client agree: the range `UnitService` uses to find targets, the circle `UnitPlacementController` draws, and the card numbers all come from the same function.

Nobody pushes weather into combat.
`UnitService` reads the weather from `WeatherService` once per frame and `MobService` checks there whether it changed, so turning weather on is the only step, and the `weather` command produces exactly the same match as the round does.
On the client, the source is `WeatherController:GetCurrent()`, and whoever must redraw (range circle, card) listens to `WeatherChanged`.

Enemy health only applies at spawn: changing `MaxHealth` mid-walk would heal or kill the enemy.
Speed applies at once, including enemies already walking, or two identical enemies would walk at different paces in the same wave.
Farm income is left out on purpose: it is not combat, and the sandstorm cut would change the economy.

## Snow freeze

While `Snow` is active, `SnowService` picks a unit every 30 s (`Effects.Snow.Freeze.Interval`) and freezes it for 10 s (`Freeze.Duration`).
Freezing is the same stun as lightning (`UnitService:StunUnit`).
Units immune to the weather are **left out of the draw**, instead of being picked and not frozen; otherwise a map full of Magic would go waves with nothing happening.

`UnitStunned` carries a third argument, `source`: the weather that caused the stun.
`VFXController` looks up `Effects.<source>.Freeze` instead of comparing the name with `"Snow"`, so lightning and enemy gimmicks keep only the yellow highlight from `UnitPlacementController`.

**The drawing is the same as the Frostione freeze on enemies**: `Freeze.Asset` is `IcedVFX`, played by `VFXController:playModelStatus`.
Particles go to the `HumanoidRootPart` welded to the `Torso`, and the asset's Highlight moves to the unit model's root, painting the whole body.
A frozen unit does **not** get the yellow highlight, so the colors do not mix.

The duration used is the one the server **actually applied** (it arrives in `UnitStunned`), not `Freeze.Duration`: the longer deadline wins in `StunUnit`.
At the end the emitters stop, the Highlight leaves at once, and the part is destroyed after the last particles' tail.
Freezing a unit that is already frozen replaces the drawing instead of stacking two, and selling the unit cleans everything with the model.
The Staff of Healing ends it early through `StopFreeze` (`stopModelStatus`).

## Buffs and debuffs on the unit

Every unit the weather affects shows it above itself, drawn by `WeatherFeedbackController` on the client:

- a **Highlight** on the model (`WeatherHighlight`): light blue (`120, 200, 255`) when the effects help, red (`255, 70, 70`) when they hurt, both at 0.75 transparency for fill and outline;
- a **head billboard** (`Assets.UI.BuffDebuffBillboard`, an Attachment with a `BillboardGui`) with one icon per changed stat, in the order damage → range → cooldown → money.

The controller decides nothing: icons and colors come from `WeatherConfig.Feedback`, the same config the server takes its combat multipliers from.
[Round cards](round-cards.md#buffs-and-debuffs-on-the-unit) add their own layers to the same display.

| Stat | Multiplier > 1 | Multiplier < 1 |
| --- | --- | --- |
| `Damage` | `BuffDamage` | `DebuffDamage` |
| `Range` | `BuffRange` | `DebuffRange` |
| `AttackSpeed` | `BuffCooldown` | `DebuffCooldown` |

`AttackSpeed` shows as **cooldown** because that is how the card shows it: higher attack speed is a shorter cooldown, so `AttackSpeed > 1` lights the *buff* icon.

The asset has every label set to `Visible = true` in Studio: the controller turns on what the unit feels and **turns off the rest**.
`Cost` stays off the billboard: it is not a state of a placed unit but the price of a new one, and the hotbar card already shows it.

- **A disabled unit** (Fire in rain) shows a single icon, `DebuffCooldown` (`Feedback.Disabled`), plus the red Highlight: the message is "this one is not attacking".
- **An immune unit** (Magic, in today's weathers) gets nothing.
- **Buff and debuff on the same unit** make the Highlight **red**: the loss is what must be seen from afar.

Both pieces live **inside the unit model**, so selling or restarting the round cleans them up.
The controller finds them by name instead of tracking them in a table.
The Highlight has its own name so it does not fight the others the unit gets: green for selection, yellow for stun, cyan for a lightning charge.
An icon the config asks for that the asset lacks simply does not appear, with one warning in Studio.

## Lightning (Thunder)

With `Thunder` active, a bolt falls every `Interval` (5 s).
Where it lands is drawn: on a placed unit, or at a random point inside the map's `BoundingBox`.
`ThunderService` keeps the rhythm and draws; `VFXController` draws the bolt on the client.

**The chance of hitting a unit is a pity system**: it starts at `UnitChance` (0.15), rises by `UnitChanceStep` (0.15) with each bolt that hits the ground, and resets when one hits a unit.
The ladder is 0.15 → 0.30 → … → 1.00, so the seventh bolt is guaranteed.
Simulated over 20,000 runs: an average of 2.9 bolts until a hit (about 15 s), worst case 7 (about 35 s).

The chance does not rise when there is no unit on the map, and turning the weather off resets clock and pity.
Units immune to thunder (Magic) are **left out of the draw**; spending a bolt on them would reset the pity with nothing happening on screen.

A ground point draws X and Z inside the box and takes Y from a downward raycast, because terrain height varies.
The `BoundingBox` does not get in the way, because `LoadMap` clones it with `CanQuery` off.

The split between server and client is required: `ReplicatedStorage.vfx` **refuses to run outside the client**, and drawing on the server makes everyone see the same bolt in the same place.

The event sends the position and, when the target is a unit, the `unitId`.
The client prefers the `unitId`: it measures the foot from the model's real box, while the server only knows the placement CFrame.

The asset (`Assets.VFX.LightningBeam`) is an **Attachment** (the bolt's start) with a child Attachment **`B`** (the end); having a single-letter child is how the `LightningBeams` addon recognizes a bolt.

- **End** (`B`): the unit's foot, the center of the bottom of its box (not `GetPivot`, which would be mid-body).
- **Start**: the height of the weather part in `workspace.Weather`, so the bolt comes down from the cloud; without an active weather, `StrikeHeight` above the foot.

The asset ships with `EmitRepeat = -1` (how the plugin marks a looping preview); the controller passes `EmitRepeat = 0` explicitly.
The module's `maxLifetime` would be zero here, because the addon creates the ParticleEmitters at runtime, so the clone's lifetime is its `Duration` attribute plus `Cleanup`.

### Stun, chain, and charge

A bolt does not deal damage: it **stuns**.
A direct hit stops the unit for `Stun.Direct` (20 s, the whole wave), and the shock **jumps** to units within `Stun.Radius` (12 studs), which stop for `Stun.Chain` (5 s).
The gap between the two is deliberate: a well-placed bolt must hurt, not switch off half the map.
`Hops` is how many layers the jump can travel (1 today) and `MaxTargets` caps each layer; each unit is touched once per discharge.

`Electric` is the exception that makes the weather worth something: besides the 10% passive damage, being struck (directly or by a jump) **does not stun it**.
It **charges** it with +50% damage (`Charge.Damage = 1.5`) and +50% attack speed (`Charge.AttackSpeed = 1.5`, which divides the cooldown) for `Charge.Duration` (4 s), and it still relays the jump.
The temporary buff lives in `entry.Charge`, outside `UnitUpgradeConfig`, which only knows numbers that apply to everyone.
Charging again before it ends renews the timer instead of stacking.

On the client, `UnitStunned` paints the unit yellow and `UnitCharged` cyan; both come from the same bolt and happen side by side.
Jumps are drawn with the same asset (`VFXController:spawnBeam`) between the units' mid-bodies, without their own impact.

To test without waiting, the `strike` command calls `ThunderService:strikeUnit` directly: it forces a unit hit, skips the pity, and can target any unit (Magic included).

## Configuration

| Key | Value | Effect |
| --- | --- | --- |
| `WeatherConfig.Round.LeadWaves` | `3` | How far ahead a weather is announced |
| `WeatherConfig.Round.Duration` | `4` | Waves a weather lasts |
| `WeatherConfig.Round.TransitionTime` | `3` | Seconds of lighting transition |
| `WeatherConfig.MapPools` | see above | Weathers per map |
| `WeatherChance` | `Config.Difficulty` presets | Chance per wave of an announcement |
| `WeatherConfig.Effects` | see above | Multipliers, immunities, disabling, snow freeze |
| `WeatherConfig.Thunder.Interval` | `5` | Seconds between bolts |
| `WeatherConfig.Thunder.UnitChance` / `UnitChanceStep` | `0.15` / `0.15` | Pity system |
| `WeatherConfig.Thunder.Stun` | `Direct = 20`, `Chain = 5`, `Radius = 12`, `Hops = 1`, `MaxTargets = 4` | Lightning stun |
| `WeatherConfig.Thunder.Charge` | `Damage = 1.5`, `AttackSpeed = 1.5`, `Duration = 4` | Electric charge |
| `WeatherConfig.Thunder.StrikeHeight` / `Cleanup` | `90` / `3` | Bolt start without weather; extra lifetime |
| `WeatherConfig.Warning.DisplayNames` | `Snow = "BLIZZARD"` | On-screen names |
| `WeatherConfig.Indicator` | see the module | Indicator GUI names, icons, lines, and sizing |
| `WeatherConfig.Feedback` | see the module | Billboard asset, icons, colors |
