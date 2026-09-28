# Round card shop

Every few waves, each player gets an offer of **three drawn [round cards](round-cards.md)**.
A bought card costs round cash (`MobService` session cash, not the profile's `Cash`), goes to the hotbar, and is worth **one use**.

**Runs in:** Game
**Code:** [`CardShopService`](../../Game/src/Services/CardShopService.luau), [`RoundCardShopController`](../../Game/src/Controllers/RoundCardShopController.luau), [`Card` component](../../Game/src/Controllers/UILibraryController/Components/Card.luau), [`VFXController`](../../Game/src/Controllers/VFXController.luau), [`RoundCardConfig`](../../common/shared/Config/SharedConfig/RoundCardConfig.luau)

Round cards are not deck cards: they do not go through the profile, do not survive the round, and have nothing to do with `DeckConfig`.

| Where | What |
| --- | --- |
| `SharedConfig.RoundCardConfig` | the catalog, intervals per difficulty, GUI names, and animation timings |
| `Services/CardShopService` | drawing, charging, stock, and effects |
| `Controllers/RoundCardShopController` | everything on screen |

## How it works

### When the shop opens

On exact multiples of the difficulty's interval (`RoundCardConfig.Intervals`), triggered by `WaveService`'s `WaveStarted` signal: the shop arrives with the wave counter, not when enemies spawn.

| Difficulty | Interval | Shop waves |
| --- | --- | --- |
| Easy | 4 | 4, 8, 12 |
| Medium | 4 | 4, 8, 12, 16, 20 |
| Hard | 5 | 5, 10, 15, 20, 25 |
| Impossible | 6 | 6, 12, 18, 24, 30 |
| Nightmare | 6 | 6, 12, 18, 24, 30 |

Longer difficulties space the shop out on purpose: with a fixed interval, Nightmare (35 waves) would offer more than twice the cards of Easy (15).

**The offer is per player; the effect is for the room.**
Round cash is individual, so each player draws and pays their own, but a Time Stop freezes everyone's enemies.
One purchase per opening: the offer closes for whoever bought.

The draw is weighted (`Weight`) and **without replacement**: a drawn card leaves the urn and the other weights stay relative to each other.
A pool smaller than three shows what it has instead of repeating.

### The client decides nothing

The client does not draw, charge, or run effects.
It sends "I want to buy card X from the offer with token T" and "I want to use card U"; the server checks both against what it stored.

| Check | What it catches |
| --- | --- |
| the offer exists | a click after the shop closed |
| the `Token` matches | a late click on an offer the next shop wave replaced |
| the card was in that offer | a swapped id |
| cash covers it | two purchases at the same instant |
| the `uid` belongs to the player | using a card already spent |

The `uid` is per purchase, not per card, so the same card bought twice can be used twice.

A card **enters the hotbar only when `RoundCardBought` confirms**, and leaves only when `RoundCardUsed` confirms.
If refused, the `RoundCardState` that follows restores the screen to what the server knows, and the offer reappears.
`RequestRoundCardState` on bind covers players who join during an open offer or reload the interface.

`CardShopService` is round-scoped in `WaveService`: nothing carries over to the next match.

### The use gesture (`Visual`)

A card with a `Visual` plays an animation on the user's character, and **the animation** triggers the sound and particles, not a hardcoded `task.delay`.
Today only Time Stop has one:

```lua
Visual = {
    Animation = "rbxassetid://76323247675563",
    Marker = "TimeStop",
    Sound = "TimeStopSFX",   -- in SoundService
    VFX = "PlayerStopTime",  -- in Assets.VFX
    EffectDelay = 0.917,
    SoundDelay = 0.75,
}
```

There is **one** keyframe marker, and its **parameter** separates the two halves: `"Sound"` plays the sound and `"VFX"` emits the asset.
Re-animating the card in Moon Animator re-marks both without touching code.

- **The VFX clone is created on use, not on the marker**, attached to the `HumanoidRootPart` so it follows the player.
  Whoever attaches it owes either the burst or the cleanup, so `track.Stopped` collects the clone when the animation ends without reaching the marker.
  `VFXController` has the `AttachAsset` / `EmitAttached` pair for this.
- **The player is anchored during the gesture**, since walking under a time-stop pose would give away that nothing stopped.
  The previous `Anchored` state is read, not assumed.
  Unanchoring, collecting the clone, and disconnecting listeners live in the **same** `finish`, which runs once for all three endings (finished, cut, never played).
  `ANCHOR_TIMEOUT` (8 s) covers an animation that never loads and therefore never fires `Stopped`.
- **The track is raised to `AnimationPriority.Action`**, because an animation exported as `Idle` or `Core` would tie with the default `Animate` and do nothing.
- **The gesture starts on the server's confirmation** (`RoundCardUsed`), not on the click, so a refused use never leaves the character posing.

#### The effect waits for the burst (`EffectDelay`)

Time Stop's freeze waits for the `VFX` marker: 0.917 s of animation before enemies lock, so the effect reads as a consequence of the gesture.
**The delay runs on the server**: `CardShopService:Use` runs the effect in a `task.delay` of `Visual.EffectDelay`.
It uses real time, not `GameClock`, because the gesture does not speed up with the match.
What does not wait is the rest: the card leaves the hand and `RoundCardUsed` fires immediately.

`EffectDelay` and `SoundDelay` are copies of the marker times, and copies go stale.
When the server starts, `CardShopService:_auditVisualDelays` downloads each `Visual` card's `KeyframeSequence`, finds the markers, and warns (in Studio) if either copy is more than `EFFECT_DELAY_TOLERANCE` (0.05 s) off.
It only warns and never corrects the number from a web call; a failed download is silent.

#### The gesture is for the whole room

| What | How it reaches other screens |
| --- | --- |
| The animation on the character | **by itself**: the `Animator` replicates what the owner plays on their own body |
| The player standing still | **by itself**: the owner anchors the root they control |
| The sound (`TimeStopSFX`) | `RoundCardVisual` → `_playRemoteUseVisual` |
| The particles (`PlayerStopTime`) | `RoundCardVisual` → `_playRemoteUseVisual` |

`RoundCardUsed` goes only to the user (it changes their hand), and `RoundCardVisual` goes to everyone **except** the user, so the sound never plays twice.
Watchers have no keyframe markers (they see a replicated animation), which is why `SoundDelay` exists next to `EffectDelay`.
The path is generic: any card with a `Visual` replicates its gesture.

### Screen animation

1. **The button slides in from the right.**
   `RCSFrame` starts at `Position.X.Scale = 1` and eases (`Circular`) to its authored X.
2. **Docked, it sways.**
   `CardShop` lifts `IdleLift` pixels and swings between `+IdleSwing` and `-IdleSwing` degrees forever (`repeatCount = -1`, `reverses = true`), starting only after the slide ends.
   The offer lasts a few waves and the button sits at the edge, where it is easy to miss.
3. **Clicking tucks the button away and darkens the screen.**
   `RCSFrame` returns to `X.Scale = 1`, `CardShop` undoes the sway (`IdleReturn`), `Background` fades from 1 to its authored transparency (0.5), and the hotbar dims.
4. **Cards drop in, one every 0.5 s.**
   Each `CardTemplate` falls from `DropOffset` card heights above while its **image** fades in; only then does its content (title, description, price, outlines, shadow) fade in.
5. **Clicking outside the cards plays it backward**: content fades out (`CardReveal`), then each card rises while fading (`CardDrop`), one every `CardExitStagger`, much faster than the entrance.
   The backdrop leaves in `BackgroundFadeOut`.
   A card still dropping is canceled and rises from where it was.
6. **A purchase closes the shop**, and the backdrop disappears instantly.

**The button is spent on opening, not on purchase.**
Once clicked, it does not return for this offer, even after clicking outside or a refused purchase.
Only an offer with a different `token` shows it again (`OpenedToken`; `_applyState` calls `_showFrame` only for a new token).

**`UserInputService` listens for the outside click**, not `Background`.
A `GuiObject` only receives clicks nobody else wanted, and any `ScreenGui` with a higher `DisplayOrder` (the HUD, the hotbar) would eat them, leaving the shop impossible to close without buying.
A click on one of the three cards marks its own `InputObject`, and the check runs one frame later in a `task.defer`, because the order of two handlers on the same event is not guaranteed.
`Background` stays `Active` as a barrier, so a click with the shop open does not place a tower behind it.

Target transparencies are read from **each fresh clone** before any animation, so repainting in Studio is enough.
`GuiObject.Transparency` is excluded (it aliases `BackgroundTransparency`), as is any non-number `Transparency` (a `UIGradient`'s is a `NumberSequence`).
The authored `CardWrapper` inside `Background.RoundCardShop` becomes a template on first use.

### The card in the hotbar

The shop hands over only the **look**: a clone of the same template at `UDim2.fromScale(0.128, 1.07)` and **without the price tag**.
From `Card:addRound` on, the [hotbar](hotbar.md) treats it like any other card: it joins the arc, grows on hover, pushes and is pushed, dims, and gets a shortcut key.

| Field | Unit card | Round card |
| --- | --- | --- |
| `Kind` | `"Unit"` | `"Round"` |
| `Unit` | the unit name | `nil` |

An empty `Unit` keeps a round card out of everything that belongs to the deck: price, weather discount, counter, stock, and the notion of "selected unit".

- **`entry.Activate`:** clicks and shortcuts call `entry.Activate()`, which each origin fills in (a unit card equips the unit; a round card asks the server to use it).
- **`_isSelected`** checks `entry.Unit ~= nil`; otherwise `nil == nil` would mark every round card as selected when no unit is equipped.
- **`addRound` normalizes the anchor**: the shop template anchors at the corner (`0, 0`) and the hotbar at the center; without the change, the arc tilt and hover growth would pivot around the corner.
- **Entry and exit reuse the component's animations**: the card rises into its slot (`RESTORE_INFO`) and drops out when used (`EXIT_INFO`); the entry leaves the list only at the end of the drop.
- **`clean` keeps round cards.**
  `set` redraws the hotbar from the deck, and a bought card did not come from the deck.
  Round cards go back in the queue **after** the unit cards, and `_reindex` rewrites every `LayoutOrder`.
  `destroy` empties the whole hand.
- **Hiding the hand is the component's job.**
  While the shop is open, `Card:setHidden(true)` hides every card without anyone losing their place: each entry keeps its intent in `Present`, and `hidden` overrides it.
  Nothing writes the `TowerContainer`'s `Visible`, which [`DifficultyController` owns](hotbar.md#visibility).

## Usage

```text
roundshop [players]
```

Opens the offer immediately, without waiting for a shop wave, and redraws the three cards.
With no argument, it opens for the whole room.
Aliases: `cardshop`, `rcs`.

## Studio setup

`StarterGui.RoundCardShop` must have `ResetOnSpawn = false` (otherwise the GUI is recreated on every respawn and the controller holds an `RCSFrame` that is no longer on screen) and `DisplayOrder = 1` (with 0, the backdrop shares a layer with `Interface`).
