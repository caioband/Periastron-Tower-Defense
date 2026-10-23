# Difficulty vote

Before the first wave, players vote on the difficulty on `StarterGui.Difficulty.DifficultyBoard`.

**Runs in:** Game
**Code:** [`DifficultyController`](../../Game/src/Controllers/DifficultyController.luau), [`DifficultyService`](../../Game/src/Services/DifficultyService.luau), [`Config.Difficulty`](../../common/server/Config/Difficulty.luau), [`DifficultyUnlockConfig`](../../common/shared/Config/SharedConfig/DifficultyUnlockConfig.luau)

## How it works

**The button instance's name is the vote.**
`DifficultyController` scans the board's `ImageButton` children and fires `SelectDifficulty(child.Name)`.
`DifficultyService` refuses any name that is not in the difficulty presets.
The same name keys `VoteCount` (`votes[name]`) and the highlight of your own vote.

Renaming a button in Studio changes which difficulty it votes for.
The six buttons must be named exactly `Easy`, `Medium`, `Hard`, `Impossible`, `Nightmare`, and `Endless`; the text the player reads lives in a `TextLabel` inside and is never read by code.

A player can only vote for difficulties they have unlocked (see [Difficulty locks](#difficulty-locks)); the server refuses the rest.

### Button audit

The server drops an invalid name without a log, and the board keeps showing six buttons, so a misnamed button fails silently.
`DifficultyController:auditButtons` checks, the first time a state arrives, that every button has a preset and every preset has a button, and warns in Studio otherwise.
The check lives there and not in the bind because the preset list is server config: it only reaches the client through `state.options` in `DifficultySelection`.

### The hotbar during the vote

`DifficultyController` also hides the hotbar until the difficulty is decided (see [Hotbar](hotbar.md#visibility)).

### Presets off the vote

Only the names in `Config.Difficulty.Order` are on the board, counted in the tally, or drawn by contracts and quests.
`Tutorial` and `FallPart1` (Fall PART 1, placeholder waves and numbers) are presets left out of `Order` on purpose: they can only be imposed, through `DifficultyService:Force`/`ForcePreset`.
How players get into Fall PART 1 is not decided yet.

## Difficulty locks

Easy and Medium are open to everyone.
The rest open with **either** of two things, whichever comes first:

| Difficulty | Wins | or Level |
| --- | --- | --- |
| Hard | 4 on Medium | 3 |
| Impossible | 4 on Hard | 6 |
| Nightmare | 6 on Impossible | 12 |
| Endless | 2 on Nightmare | 5 |

The two sources measure different things.
Wins on the difficulty below say the player **can handle** it: the short path for players doing well.
Level is the safety net: XP is earned on losses and abandoned runs too, so a player who loses a lot but plays a lot also gets there.

`Wins` counts the difficulty **below**, not the one being unlocked (there is no way to win on Nightmare before it opens), so the wins path is sequential while the level path can skip steps.

The table lives in `SharedConfig.DifficultyUnlockConfig`, not with the presets in the server-only `Config.Difficulty`: nothing in it is secret, and the client needs it to draw the padlock.

**Where wins are stored.**
`Stats.Wins` is still the total (what leaderstats and the [map locks](../lobby/maps-panel.md) read).
The difficulty lock reads `Stats.DifficultyWins` (`{ [difficulty] = count }`), written by `WaveService` in the same `:Update` as the victory.
The table starts empty and gains a key on the first win in that difficulty.
Old profiles get it through the reconcile, **empty**: wins from before the key have no difficulty recorded.
Level is not stored anywhere; it comes from `Stats.XP` through `LevelConfig:Resolve`.

**The rule runs on both sides.**
`DifficultyController` hides each button's `Locked` frame, restores the `Active`/`AutoButtonColor` the art authored, and writes what is missing on the label (`Locked.Time`: "4 more wins in Medium or Level 3").
`DifficultyService` refuses the vote with the same function.
Both are needed: a vote is a name, and any client can send a name.

Until the replica arrives, everything shows locked: guessing the other way would open Nightmare for a moment and slam it shut when the profile arrived.
A button without a `Locked` frame in the art is always open, which is how Easy and Medium declare themselves.

## Design notes

Two buttons once had swapped names (`Extreme` labeled IMPOSSIBLE and `Impossible` labeled NIGHTMARE).
Impossible could not be voted for, and Nightmare voters played and were paid as Impossible, with no error anywhere.
That is why the audit exists.
