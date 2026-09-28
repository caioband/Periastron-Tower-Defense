# Round cards

One-use cards bought with round cash during a match.
This page covers the catalog, which cards a player can be offered, how a card is used, and what it does.
The in-match shop that sells them is described in [Round card shop](round-card-shop.md); players unlock cards in the [Lobby card shop](../lobby/round-card-shop.md).

**Runs in:** Game (cards are unlocked in the Lobby)
**Code:** [`RoundCardConfig`](../../common/shared/Config/SharedConfig/RoundCardConfig.luau), [`CardModifier`](../../common/shared/Config/SharedConfig/CardModifier.luau), [`CardShopService`](../../Game/src/Services/CardShopService.luau), [`CardModifierService`](../../Game/src/Services/CardModifierService.luau), [`CardModifierController`](../../Game/src/Controllers/CardModifierController.luau), [`RoundCardShopController`](../../Game/src/Controllers/RoundCardShopController.luau), [`WeatherFeedbackController`](../../Game/src/Controllers/WeatherFeedbackController.luau), [`RoundCardStarterService`](../../common/server/Services/RoundCardStarterService.luau)

## The catalog

`RoundCardConfig.Cards` defines every card.
Each entry says **how it is used** (`Use`), **what it does** (`Effect` and `Params`), and **its art**.

| Card | Price | Use | Effect | What it does |
| --- | ---: | --- | --- | --- |
| Time Stop | 350 | Instant | `TimeStop` | Freezes every enemy for 4 s |
| Time Acceleration | 250 | Instant | `TimeAcceleration` | Match speed goes to 3x for 15 s |
| Weather Report | 300 | Instant | `WeatherReport` | Clears the weather for the current wave only |
| Money Bag | 400 | Instant | `GrantCash` | Gives 500 cash |
| Trumpet | 400 | Instant | `Modifier` | Every unit attacks 15% faster for 30 s |
| Overcharge | 350 | Instant | `Modifier` | Electric +25% damage; every other unit −11% |
| Watt's Up? | 400 | Instant | `Modifier` | Electric +15% damage, range, and attack speed |
| Punch Line | 300 | Instant | `Modifier` | Melee +25% damage, 25% slower |
| Axecellent! | 300 | Instant | `Modifier` | Melee 15% faster, Ranged 15% slower |
| Cleave It To Me! | 400 | Instant | `Modifier` | Melee also hits the enemy behind the target |
| Abrakadabra | 300 | Instant | `Modifier` | Magic +0.1% damage per Magic unit placed |
| Iceolated | 250 | Instant | `Modifier` | Ice +25% attack speed with no unit nearby |
| Ice To Meet You | 350 | Instant | `Modifier` | Ice 50% faster; units near them 50% slower |
| Chill Out | 250 | Instant | `Modifier` | Ice slows 10% harder |
| Fire Hazard | 250 | Instant | `Modifier` | Burning enemies take +20% burn damage |
| No Pain, No Gain | 250 | Instant | `Modifier` | Under 20% base health, every unit +20% damage |
| Staff of Azure Ever Ice | 400 | Instant | `ChillEnemies` | Slows every enemy 50% for 10 s (75% and brittle during snow) |
| Bloxy Cola | 200 | Unit | `Modifier` | Doubles one unit's attack speed for 10 s |
| Bloxiade | 200 | Unit | `Modifier` | Doubles one unit's damage for 10 s |
| Staff of Healing | 300 | Area | `Cleanse` | Clears stuns in an area and grants 10 s of stun immunity |
| Celestial Staff | 500 | Area | `Modifier` | Magic 1.2x damage and 1.1x attack speed in the ring; others weakened |
| Staff of Robux Royalty | 450 | Area | `Modifier` | 1.1x hit income and 1.15x farm income in the ring, at 0.8x damage and attack speed |
| Staff of the Winds | 450 | Area | `Modifier` | Ranged 1.1x damage and 1.2x range in the ring; others 0.8x damage |
| Zippers | 150 | Move | `MoveUnit` | Moves one placed unit to another valid spot |

Chill Out and Fire Hazard are global multipliers that `MobService` reads (`ApplySlow` and `ApplyBurn`), so they affect the Frostione's slow stacks and the Pyre's burn.

## Which cards a player is offered

The draw does not scan the catalog; it scans what the player has unlocked.
Unlocked cards are stored in the profile's `Data.RoundCards`.
Four filters run in sequence:

| Filter | Where | Removes |
| --- | --- | --- |
| registered effect | `CardShopService:_pool` | a card whose `Effect` is not in `CardShopService.Effects`, for everyone (with a Studio warning) |
| unlocked | `CardShopService:_poolFor` | a card **this** player has not bought in the Lobby |
| resting | `CardShopService:_poolFor` | a timed card they used at the previous shop opening |
| spent | `CardShopService:_poolFor` | a single-use card they already bought this match |

A player with no unlocked card gets no offer, and their previous offer is cleared; otherwise the new `Token` would refuse every click on the old one as an expired offer.
A profile that has not loaded counts as empty.

### Starter cards

A new profile starts with six unlocked cards (`RoundCardShopConfig.STARTER_CARDS`): Time Stop, Time Acceleration, Weather Report, Trumpet, Bloxy Cola, and Bloxiade.
Without them, a new player would never see a shop and could not connect that to a Lobby shop they have not visited.
Bloxy Cola and Bloxiade are there so the kit includes a targeted card.
Emptying the list closes the offer for anyone who never bought a card; that is a design decision.

**The kit is backfilled.**
`DataService`'s reconcile creates `RoundCards` when it is missing but leaves an existing key alone, so a card added to the list would only reach accounts created afterward.
`RoundCardStarterService` (in `common/`, because both places open profiles) adds any missing starter card on every `PlayerDataLoaded`.
A player who already bought one with shards is neither touched nor refunded.

### Timed cards rest

**A card whose effect expires on its own sits out one shop opening.**
Used at the wave 4 offer, it cannot be drawn at wave 8 and returns at wave 12.
`CardShopService:_rest` writes `Token + 1` into `Resting[userId][cardId]`, and `_poolFor` skips it until the current opening passes that number.
It is per player.

A card counts as timed when `Params.Duration > 0` (`_isTemporary`), not from a hand-written list.
Today that is Time Stop, Time Acceleration, Trumpet, Staff of Azure Ever Ice, Bloxy Cola, and Bloxiade.
The Staff of Healing is **not** timed, even with its 10 s of immunity, because that number is `Params.Immunity`.

Rest is counted in shop openings, not waves or seconds: what is scarce is the offer.
Nothing shows on screen; from a three-card offer the player cannot tell what was not drawn.

### Stacking cards are single-use

**A card that would stack with itself leaves the player's pool on purchase and does not return this match.**
`CardShopService:_isStacking` requires all three conditions, read from the config:

1. its effect is a **field rule** (`Effect = "Modifier"`), and `CardModifierService` accepts two copies of the same record, which multiply;
2. it has **no duration**, so the rule lasts until the end of the round;
3. it draws **no area**, so it changes the whole map.

Together they are the one case where buying the same card again is always the best play: Overcharge twice is 1.56x Electric damage, three times is 1.95x.
The other cards limit themselves: a timed card expires, an area card cannot overlap the same player's area, and a non-`Modifier` card does not stack rules.
Today eleven cards are single-use: Overcharge, Watt's Up?, Punch Line, Axecellent!, Cleave It To Me!, Abrakadabra, Iceolated, Ice To Meet You, Chill Out, Fire Hazard, and No Pain, No Gain.

**The mark is set on purchase, not on use** (`_spend`, called from `Buy`).
Otherwise a player could hold three Overcharges and use them at once.
`Use` marks again, in case a card reached the hand some other way.

It lasts for the match, not the profile.
The pool shrinks as a build takes shape, so a player with few unlocks may get fewer than three cards or none; `Draw` returns what there is.
The starter kit has no stacking cards, so a new player always has a shop.

## How a card is used

`Use` says what the card needs between the hotbar click and the effect:

| `Use` | Clicking the card in the hotbar… | Example |
| --- | --- | --- |
| `Instant` | uses it | Time Stop, Money Bag, Trumpet |
| `Unit` | asks for a tower; the next click on the map picks it | Bloxy Cola, Bloxiade |
| `Area` | asks for a spot; a ring follows the pointer | the staffs |
| `Move` | asks for both, in order: the tower and the destination | Zippers |

A card without `Use` is `Instant`.

**A card being aimed is a card in hand**: the hotbar grows it (`setSelectedRound`) and dims its neighbors, as it does for an equipped unit.
There is no panel or cancel button; clicking the card again cancels (Esc also works on PC).
The right mouse button is left out on purpose: on PC it turns the camera.

While aiming, **world clicks belong to the card**: `RoundCardShopController` locks tower selection in `UnitPlacementController` (`setPointerLocked`, which drops the ghost, the selected tower, and any equipped unit card) and unlocks it when aiming ends, however it ends.

The card is spent only when the server confirms the use, and **a refused target does not spend it**: `CardShopService:Use` checks the target before removing the card from the hand.

## What a card does

Most cards **leave a rule on the field**, and those rules have their own grammar: `SharedConfig.CardModifier`.
That is why eight effects in `CardShopService.Effects` cover the two dozen cards: most use `Effect = "Modifier"` and describe their records in `Params.Modifiers`:

```lua
-- Electric hits 25% harder; everything else, 11% weaker.
Params = {
    Modifiers = {
        { Classes = { "Electric" }, Stats = { Damage = 1.25 } },
        { Classes = { "Electric" }, Exclude = true, Stats = { Damage = 0.89 } },
    },
},
```

A record filters by class (`Classes` / `Exclude`), by type (`Farm`), by unit (`Target = true`, filled with the chosen tower), by area (`Zone = true`, filled with where the player drew the ring), or by neighborhood (`Condition = "Isolated"` / `"NearClass"`, recounted every combat frame).
`Duration` sets a lifetime in match time; **without it, the rule lasts until the end of the round**.
Non-numeric behavior goes in `Flags` (today only `Cleave`).

A new card that only changes numbers needs no code: it is one entry in `RoundCardConfig`.
A card with new behavior needs an entry and a function in `CardShopService.Effects` named after its `Effect`.

**`CardModifierService` owns the list**: it prunes expired records and replicates the whole list to clients (`RoundCardModifiers`).
The client needs it to draw the staff rings and to show the **real** range on the selection circle and the card, using the same function the server uses.

Combat reads the multipliers once per frame (`UnitService:refreshCardModifiers`), not once per question: two conditions scan the whole neighborhood, and asking per unit and per stat would multiply that scan by five.

### The instant effects

- **Time Stop** uses the same `StunnedUntil` as the boss gimmick: the Heartbeat loop only adds distance once the match clock passes it.
  The 4 s are match time, so at 2x they are 2 real seconds and freeze the same distance at any speed.
  `MobService.FreezeUntil` is stored so enemies that spawn during the freeze **spawn frozen**.
  Two overlapping Time Stops extend the window, and a `FreezeToken` makes sure only the last thaw counts.
- **Time Acceleration** uses `SpeedService:SetOverride` (see [Match speed](match-speed.md#overrides)): 3x for 15 **real** seconds, with its own `GameSpeedOverride` event, separate from `GameSpeedChanged`.
- **Weather Report** clears the weather from **the current wave only** (`WeatherRoundService:SkipCurrentWave`), through `WeatherService:Clear`, so weather turned on by the `weather` command also goes.
  It is an umbrella for one wave, not a cancellation: `Active` and `ActiveUntilWave` are kept, and on the next wave `OnWaveStarted` brings the weather back through `resumeActive` if it still has waves left.
  A player who wants all three waves of a storm clear buys three cards; bought on the weather's last wave, the weather simply ends there.
  A scheduled warning is not touched either: the announced weather arrives on its wave.
  With a clear sky, the card is still spent and does nothing (the effect only logs "there was no weather on").

## The two rings

- **The aiming ring** is the neutral placement circle (`Assets.UI.AOE.Ring`), colored by target type.
  It exists only between clicking the card and clicking the map.
- **The ground ring** is the card's art (`Assets.VFX.Rings`, chosen by its `Ring` field: `Celestial`, `Robux`, `Windy`, `Healing`, or `Base` by default).
  It appears where the player clicked, **with the same radius they saw while aiming**, and lives as long as the effect.

The radius comes from the replicated `Zone`, so the two never disagree.
The model's scale is measured from the `<name>_Ring` part inside it, not the model's bounding box, which includes emitters and attachments.

The Staff of Healing leaves no zone (its effect is instant), but its immunity lasts 10 s, so it declares a modifier with no `Stats`: it *is* the ring, and lives and dies with the immunity it represents.

## Buffs and debuffs on the unit

What a card does to a tower shows **on the tower**, with the same highlight and head billboard weather uses (`WeatherFeedbackController`; see [Weather in a match](weather-in-match.md#buffs-and-debuffs-on-the-unit)).
The vocabulary (asset, colors, and icons) is `WeatherConfig.Feedback.Stats`: damage, range, cooldown, and **money** (`BuffEco` / `DebuffEco`, one icon for both `Income` and `HitIncome`).

Three layers **multiply**, per stat:

1. the weather;
2. the cards already used (the `CardModifierController` list);
3. the **preview**: a card being aimed and not yet used.

The icon that lights is the net effect: fog (0.7 range) with the Staff of the Winds (1.2) gives 0.84 and lights `DebuffRange`, not both icons.
`Kind` is `Debuff` whenever there is any debuff, which is normal inside a staff ring.

**The preview is the point.**
Dragging an area card's ring across the map lights each tower it reaches with what it will feel; for a single-target card, the tower under the pointer lights up.
The scan runs every frame while aiming, so it is cheap on purpose: the world is built once per scan, the ring only redoes the preview after moving more than `PREVIEW_STEP`, and each tower compares a signature before rewriting its billboard.

**The tower under the pointer turns yellow** while a card is looking for a target.
`WeatherFeedbackController` paints it (with the preview icons) for cards that change stats, and `RoundCardShopController` for cards that do not (Zippers).
The color lives in `Targeting.Colors.Unit` and both read it, so there is only one highlight.

When a card lands on a tower, the server fires `AppliedVFX` (`Assets.VFX.EffectUnitAppliedVFX`, attached to the `HumanoidRootPart` and emitted by `VFXController`) for everyone, and only after the effect succeeded.

## Areas cannot overlap

**Two areas from the same player cannot touch.**
The aiming ring turns red (`Targeting.Colors.Blocked`) where it would touch an area that player already drew, and a click there does nothing: the card stays in hand with aiming open.
The math compares center distance against the sum of radii, ignoring `Y`, and runs in two places on purpose: `CardModifierController:FindZoneOverlap` paints, `CardModifierService:FindZoneOverlap` refuses.
Both read the same replicated list.

Without the rule, stacking three staffs on the same towers multiplied all three buffs, and the decision the card sells (*where* to draw the ring) disappeared.
**Only the player's own areas count**: in a room of four, blocking ground because of someone else's staff would take the few good spots from whoever came later.
`CardModifierService:Apply` stores `OwnerUserId` on the modifier only for this question.
Expired zones do not hold ground: the read goes through `GetActive`, which prunes them.
