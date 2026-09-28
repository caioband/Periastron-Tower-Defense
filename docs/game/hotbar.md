# Hotbar

The hand of cards at the bottom of the screen (`StarterGui.Interface.TowerContainer`).
It holds the deck built in the Lobby plus any [round cards](round-card-shop.md#the-card-in-the-hotbar) bought during the match.

**Runs in:** Game
**Code:** [`Card` component](../../Game/src/Controllers/UILibraryController/Components/Card.luau), [`CardController`](../../Game/src/Controllers/CardController.luau), [`UnitService`](../../Game/src/Services/UnitService.luau), [`DeckConfig`](../../common/shared/Config/SharedConfig/DeckConfig.luau), [`CardConfig`](../../common/shared/Config/SharedConfig/CardConfig.luau)

## How it works

### The hand is the Lobby deck

The **deck** decides what enters the hotbar (`EquippedUnits` in the profile; see `DeckConfig` and [Deck](../lobby/deck.md)).
Only units in a slot enter, and each card's count is that slot's `Amount`, not the whole inventory.

- **Server** (`UnitService:initPlayerCards`): builds `SessionCards` from the deck.
  `getCardCount` refuses placements, so the deck is what actually limits the match.
- **Client** (`CardController`): builds the hand with `DeckConfig.unitList`, in slot order and without gaps.
  `CardController` decides which cards appear, their counts, and which one is selected; the `Card` component draws them.

Both sides read the same profile with the same functions, so they reach the same deck without a new event.
A player who **never built a deck** gets an automatic one (`DeckConfig.autoDeck`, called by `resolve`): rarest units first, cards dealt in turns up to `CardLimit`.
The automatic deck is **not saved**; it only lasts for the session.

The deck is read when the round starts, so giving a unit mid-round (for example with the `units` command) only shows up next round.

### Visibility

`TowerContainer` is hidden until the match starts, and `DifficultyController` controls it:

| Moment | Signal | Hotbar |
| --- | --- | --- |
| client loaded, round not started | initial state in `construct` | hidden |
| vote open | `DifficultySelection` with `locked = nil` | hidden |
| vote closed | `DifficultySelection` with `locked` / `DifficultyLocked` | visible |
| `ResetRound` (play again) | `DifficultySelection` with `locked = nil` | hidden |

`locked` says whether a difficulty was chosen; `active` does not work for that, because it is also `false` between rounds.

A player who joins a running round gets the state at once: `DifficultyService:syncPlayer` waits for the `ClientReady` tag (set by `DataService` when the client fires `Loaded`) and sends that player a `DifficultySelection`.
Without it, the vote would never talk to them and their hotbar would stay hidden all match.

The `1`–`6` shortcuts follow the same visibility: `InputBegan` returns early while `TowerContainer` is invisible.
The tutorial can also hold the hotbar hidden during a step (`HideDeck` in `TutorialConfig`).

### Card art

Each card is an `ImageLabel` whose image is the whole card: frame, illustration, and background.
The ids are in `CardConfig.Images`, keyed by the `UnitStats` name, which is not always the name on the art: the **Rocketeer** card belongs to `Rocket`, and the **Gladiator** card to `Sword`.
A wrong key breaks nothing; the unit just shows the art authored on the `CardWrapper` template.

### The arc

`TowerContainer` has **one** authored `CardWrapper`, used as a template.
The component removes it from the screen on first use and clones one per card.

The container's `UIListLayout` spreads the **wrappers** horizontally.
The component draws the **card's Y position inside its wrapper**, which creates the downward arc without fighting the layout.

A card drops by the **square** of its distance to the vertex, measured in **card heights** (`card.Size.Y.Scale`), so resizing the card in Studio opens or closes the whole arc.
The curve is normalized to the farthest card, so the card at the end always drops `ARC_SPREAD`.
The vertex is the middle of the hand: one card when the count is odd, the **two** middle cards when it is even.

| Cards | Y of each |
| --- | --- |
| 6 (even) | `0.730 0.577 0.500 0.500 0.577 0.730` |
| 5 (odd) | `0.730 0.558 0.500 0.558 0.730` |

Tilt comes from the same distance, signed and normalized the same way: cards left of the vertex lean left, cards to the right lean right, and the end card reaches `ARC_TILT` (8°).

Whenever a card enters or leaves, or the selection changes, the whole hand re-settles over `ARC_TOTAL_TIME` (0.3 s).
`ARC_STAGGER_SHARE` (40%) of that time staggers the start of each card from left to right, and the rest is each card's duration, so a hand of two and a hand of six finish at the same moment.
The delay lives in the `TweenInfo` and not in a `task.delay`, so canceling a tween cancels the wait too.
On the first draw the hand appears already arranged, with no animation.

### Scale, dimming, and order

Each card's `UIScale` has three states, and the largest wins:

| State | Scale |
| --- | --- |
| idle | 1 |
| **selected** (in hand) | 1.1 (`SELECTED_SCALE`) |
| under the mouse | 1.2 (`HOVER_SCALE`) |

Every change uses the same 0.2 s tween.
**Selection does not move the arc**; scale shows which card is in hand.

Selecting a card plays `CardFlip` through `MusicController:PlaySFX`, the same sound as the Lobby deck panel.
It plays only when a card **enters** the hand, not when it is released.
It is not `SelectSound`, which belongs to selecting a unit already on the map (`UnitPlacementController:selectUnit`).

With a card selected, **the others dim**, with their contents and their counters.
Dimming is a fraction of the way to full transparency (`base + (1 - base) * DIM_AMOUNT`, with `DIM_AMOUNT = 0.35`), so it compounds with what the piece already had: a card out of stock at 0.25 goes to 0.51, and an invisible button stays at 1.
The base values are read from the fresh clone, so "back to normal" is exactly what the designer authored.
One function (`_applyTransparency`) combines both reasons a piece dims (out of stock, another card selected) so they do not overwrite each other.

Cards overlap, so a growing card also comes forward (`ZIndex`): the hovered card above all, the selected card above its neighbors.

### A growing card pushes its neighbors

Changing a card's scale **or size** re-settles the hand, and each card's new position accounts for that growth.
The card that grew stays in place, and the width it gained is returned as space to both sides, half each (`PUSH_SHARE = 1` returns all of it), so the hand stays centered.

With six 156 px cards, the second hovered (1.2) and the fourth selected (1.1):

```text
card 1  scale 1.0   -27.5 px
card 2  scale 1.2    -9.2 px   <- grew
card 3  scale 1.0    +9.2 px
card 4  scale 1.1   +18.4 px   <- grew
card 5  scale 1.0   +27.5 px
card 6  scale 1.0   +27.5 px
```

The shift goes into the card's X offset inside its wrapper, so `UIListLayout` still owns the wrappers.
The width used is the authored `Size`, never `AbsoluteSize`: mid-tween the absolute size is halfway, and the push would chase its own effect.

### Counters live outside the cards

The `Count` label is not a child of the card: it lives in a single layer (`CountLayer`), so every counter sits on the same plane, in front of every card.
`Interface` uses `ZIndexBehavior.Sibling`, where a descendant never draws above its parent's sibling, so a counter inside a card was hidden by the next card.

The link is recomputed every frame (`_followCounts`): the counter's center comes from where it sat inside the card (read from the template), rotated by the card's tilt and measured on the card's **absolute size**, which already includes `UIScale`.

The layer is the last child of `TowerContainer`, so it also takes a slot in `UIListLayout`.
Its width cancels that slot: with the layout's −12 px padding, a +12 px cell followed by −12 px adds up to zero.

Normal-state colors (the cost outline, the counter color) are read from the template.
Without cash for the cost, the card turns red (`NoCash`).

### A card with no units leaves the hand

When a unit's count reaches zero, its card drops out of the hand over 0.5 s (`EXIT_DROP`, in card heights, so it fully leaves the screen at any resolution).
The gap closes only **when the drop finishes** (the other cards' `_layout` runs from the tween's `Completed`), and then the rest re-settle.

When the unit is available again, the reverse happens: the gap opens at once and the card rises back into place over 0.5 s.
Leaving accelerates (Quad In); returning decelerates (Quad Out).

A card out of the hand counts for nothing: no arc slot, no shortcut key (`1`–`6` number what is on screen), and its counter hides too.
The counter lives in the top layer, not the wrapper, so hiding the wrapper does not hide it; `_setPresence` handles both halves.
A card that starts with no units (while the hand is being built) enters directly in the out state.

## Configuration

| Constant | Value | Effect |
| --- | --- | --- |
| `ARC_SPREAD` | `0.23` | How far the end card drops, in card heights |
| `ARC_TILT` | `8` | Tilt of the end card, in degrees |
| `ARC_TOTAL_TIME` | `0.3` | Duration of a full re-settle |
| `ARC_STAGGER_SHARE` | `0.4` | Share of the re-settle spent staggering |
| `SELECTED_SCALE` / `HOVER_SCALE` | `1.1` / `1.2` | Card scale when selected / hovered |
| `DIM_AMOUNT` | `0.35` | How much the other cards dim |
| `PUSH_SHARE` | `1` | Share of a card's growth returned as space to its neighbors |
| `EXIT_DROP` | `1.2` | How far a card with no units drops, in card heights |
