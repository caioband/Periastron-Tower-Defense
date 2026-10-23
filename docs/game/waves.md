# Waves

Every wave of every difficulty is written out by hand: which enemies, in what order, how many, and with what health and speed.

**Runs in:** Game
**Code:** [`Config.Waves`](../../common/server/Config/Waves/init.luau), [`Config.Wave`](../../common/server/Config/Wave.luau), [`MobService`](../../Game/src/Services/MobService.luau), [`Config.Difficulty`](../../common/server/Config/Difficulty.luau)

## How it works

### One table per difficulty

`common/server/Config/Waves/` has one module per preset in `Config.Difficulty`, named after it: `Tutorial`, `FallPart1`, `Easy`, `Medium`, `Hard`, `Impossible`, `Nightmare`.
It is server config (`ServerScriptService.Config.Waves`), so no client ever sees a wave before it spawns.

```lua
return {
	[1] = {
		{ Entity = "Traveler", Amount = 8, Health = 10, Speed = 4.4 },
		{ Entity = "RedcliffSquire", Amount = 4, Health = 12, Speed = 6.6 },
	},
	[2] = { ... },
}
```

- **The key is the wave number**, from 1 with no gaps.
  The number of waves in the table **is** the difficulty's `MaxWaves`; `Config.Difficulty` reads it from here instead of declaring it.
- **Each wave is a list, and the list order is the spawn order.**
  The first entry spawns all of its enemies before the second starts.
  The same entity can appear in more than one entry, to interleave groups.
- **`Health` and `Speed` are final values**: health points and studs per second.
  The only thing applied on top is the weather (health at spawn, speed while it lasts).
- **The boss wave is any wave with a boss entity in it** (`Boss = true` in `SharedConfig.Mob`; `Config.Wave.HasBoss`), which is what switches the music.
  A boss can appear mid-match.

| Field | Required | Meaning |
| --- | --- | --- |
| `Entity` | yes | A key of `SharedConfig.Mob.Entities`, which is also the model's name; any cast, on any difficulty |
| `Amount` | yes | How many enemies of this entry spawn (whole number, at least 1) |
| `Health` | yes | Health of each enemy, before weather |
| `Speed` | yes | Studs per second of each enemy, before weather and gimmicks |
| `Reward` | no | Cash per kill; overrides the entity's value |
| `SpawnDelay` | no | Seconds until the next enemy; overrides the entity's value |
| `GroupDelay` | no | Seconds after the entry's last enemy, before the next entry starts; without it, that gap is the `SpawnDelay` |

Without `Reward` or `SpawnDelay`, `Config.Wave` uses the entity's value in `ENTITY_DATA` times the preset's `RewardMultiplier` or `SpawnDelayMultiplier`.
An override is the final value, with no multiplier; so is `GroupDelay`.
Easy and Medium use it for `AstralAdventurer` and `SkyGuardian` where they stand in for the elite slot (see [Enemies](enemies.md)).

### Checked at boot

`Config.Waves` checks every table as it loads: missing or non-numeric wave keys, empty waves, unknown entities, amounts that are not whole numbers, and health or speed that are not above zero.
`Config.Wave` also checks that every entity used has a reward and a spawn delay somewhere, and `Config.Difficulty` checks that every preset has a table.
A mistake stops the server at boot with the file, wave, and entry in the message, instead of breaking a wave mid-match.

### Enemy reference stats

`SharedConfig.Mob.Entities` still has a `Health` and a `SpeedMultiplier` per entity, but they are the **reference**, not what spawns.
The server uses them in two places:

- **Cash per damage.**
  Each enemy stores `HealthScale`: its health (weather included) over its reference health.
  `MobService:awardDamageReward` divides by it, so a point of damage pays the same on any wave and any difficulty, and drought does not turn into a cash bonus.
  `AstralAdventurer` and `SkyGuardian` have the winged slot's reference (40) even where they stand in for the elite (120), so damage on those entries pays a third of what the elite paid; most hits pay the 1-cash floor either way.
- **Enemies born outside a wave.**
  A Deathspeaker convert (`SuffocateAbilityService`) takes its entity's stats from the current wave when the wave has that entity (`MobService:GetWaveStats`).
  Otherwise it takes the reference stats scaled like the enemy it came from.

The client also reads the reference speed to pick between the `SlowWalk` and `FastWalk` animations; that never depended on the wave.

### Where the numbers came from

The tables were generated from the formula they replaced, so the first version plays the same as before:

- The Hard spreadsheet ("PTD - Hard Difficulty - Redcliff Knights", kept outside the repo) had 25 rows of counts per enemy.
  Each difficulty walked those rows at its own pace (Easy in 15 waves, Nightmare in 35, interpolating between rows) and multiplied the counts.
- Health was the entity's reference times `HealthMultiplier * HealthGrowth^(wave-1)`; speed was the reference times `SpeedMultiplier * SpeedGrowth^(wave-1)`, capped at `SpeedGrowthCap`.
- The tutorial used only the first five rows, halved wave 3 (the first weather), and made wave 5 the boss alone at 18% health.
- Every difficulty used the same nine slots dressed in its own cast of models; the tables list each cast's own entities (see [Enemies](enemies.md)).

Speeds were rounded to two decimals, which moves them by less than 0.5%.
From here on the tables are the source of truth; edit them wave by wave.

Hard was later rebalanced from "Hard V2" (`hardV2speedtest_2`, outside the repo): its enemies, counts, and timings (`Time_Between` as `SpawnDelay`, `Time_Until_Next_Group` as `GroupDelay`) replaced the old ones, while health and speed stayed per wave, since V2 does not set them. The header of `Waves/Hard.luau` has the details.

## Configuration

| Key | Where | Effect |
| --- | --- | --- |
| `<Difficulty>.luau` | `Config.Waves` | Every wave of that difficulty |
| `ENTITY_DATA` | `Config.Wave` | Default cash per kill and spawn delay per entity |
| `RewardMultiplier`, `SpawnDelayMultiplier` | `Config.Difficulty` presets | Scale the defaults above for entries without an override |
| `Boss` | `SharedConfig.Mob` entities | Which entities make a wave a boss wave |
| `Mob.Entities` | `SharedConfig.Mob` | One entity per model: folder, reference health and speed, boss flag, gimmicks |

To add a difficulty, add the preset to `Config.Difficulty` and a module with the same name to `Config.Waves`.
