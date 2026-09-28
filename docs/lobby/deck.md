# Deck

The loadout panel (`StarterGui.HUD.CardUI`), where a player chooses which unit cards go into the next match.
The deck becomes the Game [hotbar](../game/hotbar.md).

**Runs in:** Lobby
**Code:** [`DeckController`](../../Lobby/src/Controllers/DeckController.luau), [`DeckService`](../../Lobby/src/Services/DeckService.luau), [`DeckConfig`](../../common/shared/Config/SharedConfig/DeckConfig.luau), [`CardConfig`](../../common/shared/Config/SharedConfig/CardConfig.luau), [`LevelConfig`](../../common/shared/Config/SharedConfig/LevelConfig.luau)

## How it works

The `HUDFrame.Deck` button opens and closes the panel.
Opening tweens `CardUI`'s `UIScale` from 0 to its authored scale (read from the GUI at bind time).

While open, the loadout is **alone on screen**, like the shops and contracts: it asks [`InterfaceController`](../common/interface-visibility.md) to hide the other ScreenGuis and blurs the background with the shared `UIBlur`.
`CardUI` lives inside `HUD`, so the request leaves `HUD` out and `DeckController` hides its siblings (`HUDFrame`, `HUDMiddle`, `HUDLeft`) itself (only those that were visible, and only those come back on close).
The `Deck` button hides too, and `CardUI`'s X closes the panel.

### One card per click

The deck is counted in **cards**, not units.
`EquippedUnits` is an array of **slots**, one per `CardWrapper` in `EquippedCards`: each entry is `{ Unit = name, Amount = count }` or `false` when empty.
The array is always dense (`MAX_SLOTS` entries), so it survives the DataStore round trip without becoming a dictionary.

**A slot is fixed.**
Removing a unit's last card empties its slot and moves nothing else; the next new unit takes the first gap, not the end.
Profiles in the older format (an array of names with repeats) are still read: `sanitize` converts them, grouping in order of first appearance.

- Clicking an **inventory** card only **selects** it and shows its details in `SelectionPanel`.
- **`EquipToggle`** adds one card of the selected unit to the deck per click.
- Clicking a **deck** card removes one.
- **On PC, right-clicking an inventory card** selects and equips one card in a single click (`MouseButton2Click`, which only real right clicks fire; touch and gamepad keep the plain select).

`CardFlip` (through `MusicController:PlaySFX`) plays when a card **changes sides**, in both directions; selecting plays nothing.

The button is only `Equip`, in its authored green, and it equips the second and third copies too.
When no copy is left (the whole unit is in the deck), it is **hidden**; unequipping is only through the deck card.

Three caps, all checked on the client (for instant feedback) and again on the server (which decides): the player's copies of that unit, the profile's `CardLimit`, and the **unlocked** slots.
A refusal shows the `ErrorLabel` for a few seconds (no free slot uses the authored text; the other two have their own).

`CardsLimit` shows `cards/limit` (`7/15`).
The limit lives in the profile (`CardLimit`, starting at `DeckConfig.DEFAULT_CARD_LIMIT` = 15) because it grows with the player; the `CardSlots` [game pass](../common/gamepasses.md) adds 5 on read.
`DeckService:SetLimit` raises the cap and cleans the deck afterward, so a lower cap never leaves extra cards.

### The last three slots unlock by level

| Slot | Unlocks at level |
| ---: | ---: |
| 1, 2, 3 | from the start |
| 4 | 5 |
| 5 | 15 |
| 6 | 25 |

`DeckConfig.SLOT_UNLOCK_LEVELS` is the only thing to change to rethink the pace: the padlock text, the equip cap, and the deck cleanup all come from it.

**Level is not stored**: it is derived from `Stats.XP` through `LevelConfig:Resolve`, as in the [HUD](hud.md).
Server and client reach the same slot count without exchanging anything (`DeckConfig.unlockedFor(profile)` on both sides).
The client computes it only to draw the padlock and refuse the click early; `DeckService` decides.

On screen, each `CardWrapper` has a `LockedFrame` covering a locked slot (the last three are visible in Studio, the state of a level 1 player).
`LockText` is written at render time (`Unlocked at Level 5`) from the config, not from the authored text.
A locked slot **keeps its `EmptyCard` visible under the cover**, so the padlock sits on a slot frame instead of a hole; only `Card` hides.
The draw order comes from the GUI (`ZIndexBehavior.Sibling`, with `LockedFrame` after `EmptyCard` and a higher `ZIndex`).

The panel redraws when `Stats` changes, not only when the deck changes, so a level-up shows right away.

**A card in a locked slot leaves the deck.**
`sanitize` cuts by the slot cap as it cuts by `CardLimit`, mostly for profiles from when all six slots were free: the cards return to the inventory (`Units` is untouched).
The deck is **not repacked**; the slot stays empty.

`autoDeck` (for players who never built one) and the match hotbar come from the same `DeckConfig.resolve`, which reads the level from the profile, so neither hands out a unit the deck could not hold.

### The flying card

Every change is a **copy of the clicked card** that travels for 0.8 s to its destination: from the inventory to the unit's slot, or from the slot back to the inventory.
The clone is decoration: its buttons start `Interactable = false` and its `Count` is **destroyed**, since the source number is stale the moment the clone leaves.
It lives in `CardUI` with a high `ZIndex` (the only place from which it can cross the scrolling list and the deck frame), and position and size become `CardUI` scale (`_rectToScale`), so it works at any resolution.
The name and image are rewritten on the clone, because the source may be a hidden slot still showing another unit.

**The side the card left changes at once; the side it lands on waits for the landing.**
Clicking an inventory card decrements its row immediately (and removes it if it was the last copy), and the slot swaps `EmptyCard` for `Card` when the card arrives, along with `Count` and `CardsLimit`.
Clicking a deck card is the opposite.
The change is already saved in the profile at the click; the flight is only how it is shown.

The two sides render separately (`_renderInventory` and `_renderSlots`, each with its own maid), and **what waits is the card, not the panel**: `_landedDeck` (the `Projected` deck without equips still in the air) and `_landedTally` (equipped cards plus those flying back) let each flight hold only its own slot or row.
A hidden inventory row is a normal render output: a unit with no spare copy but a card flying back gets its wrapper with an invisible `Card`, which opens the gap it will land in.
`_inventoryTarget` waits one frame before measuring, because `UIGridLayout` positions a new wrapper at the end of the frame.

**Rapid clicks count**: each click launches another card, and several can fly at once.
Whether a click is valid is decided by **`Projected`**, the deck counting what is in the air (what the server has already saved), not by the screen, which is deliberately a little behind.
The destination slot (the unit's slot if it is in the deck, or the first free one) and the three caps come from it.
With nothing in the air, `Projected` resyncs with the profile; a server refusal undoes only that click and makes its card vanish mid-flight.

### Card art

The `Card` (inventory, slot, and detail panel) is an `ImageLabel` whose image is the whole card, from `CardConfig.Images`: the same art as the Game hotbar.
`writeCardImage` writes it from three places: `writeCardName` (inventory and slots), `_dressClone`, and the detail panel.
A unit without an id keeps the art authored in the GUI (today the Slasher's).
The free slot's `EmptyCard` has its own art.

### The rest of the panel

**The inventory** (`CardUI.Inventory.ScrollingFrame`) has one card per unit with a spare copy (owned minus equipped), sorted from highest to lowest rarity and alphabetically within a rarity.
The authored `CardWrapper` is the **template** and disappears at bind.
A unit no longer in `UnitStats` is left out, with a single warning.

When a row leaves the list, the following rows **do not jump**: each wrapper moves instantly (as `UIGridLayout` dictates), and its `Card` is offset by the difference between the two cells so it stays put on screen, then animates back (`_slideCard`).
The difference comes from the grid math (`_cellOffset`), not `AbsolutePosition`, which is stale right after changing `LayoutOrder`.

The list is updated **in place**, never rebuilt: each row has its own maid, and a redraw only creates new rows, removes empty ones, and rewrites the counters.
Rebuilding every wrapper used to make the inventory **flicker on each landing**.

**The opening animation** animates the `Card` inside each wrapper (the grid owns the wrappers): each card starts at `Position = (0, 0)` with **every descendant fully transparent** and falls to its authored position, restoring the transparency each object had.
Cards enter staggered, with a capped delay in the `TweenInfo`.
Only on **opening**; a redraw with the panel open puts cards straight in place.

**The six slots** (`CardUI.EquippedCards`) show `Card` when filled and `EmptyCard` when free, including under `LockedFrame`.
`EmptyCard` copies the same slot's `Card` `Rotation` at bind, so the designer's tilt applies to both.

**The detail panel** (`SelectionPanel.Container`) is only visible with a card selected.
Its numbers are the unit's **without upgrades or weather** (neither exists in the Lobby), in the same format as the Game [upgrade card](../game/upgrade-card.md): `X DMG` (or `$X INCOME` for farms), `X.XX COOLDOWN`, `X RANGE`, plus the `ClassIcon`.
The name's outline takes the rarity color.

`DeckConfig.sanitize` cleans the list on every read: units that left `UnitStats`, copies beyond what the player owns, units in slots not yet unlocked, and cards beyond `CardLimit` are dropped.
That keeps an old profile from holding a ghost card forever.

## Configuration

| Key | Value | Effect |
| --- | --- | --- |
| `DeckConfig.MAX_SLOTS` | `6` | Number of deck slots |
| `DeckConfig.SLOT_UNLOCK_LEVELS` | `{ 1, 1, 1, 5, 15, 25 }` | Level that unlocks each slot |
| `DeckConfig.DEFAULT_CARD_LIMIT` | `15` | Starting total card cap |
