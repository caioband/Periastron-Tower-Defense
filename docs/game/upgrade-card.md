# Upgrade card

The panel that opens when a placed unit is selected: stats, next-level preview, sell and upgrade buttons, and the target priority button.

**Runs in:** Game
**Code:** [`ToggleTower`](../../Game/src/Controllers/UILibraryController/Components/ToggleTower.luau), [`UnitService`](../../Game/src/Services/UnitService.luau), [`TargetingController`](../../Game/src/Controllers/TargetingController.luau), [`UnitUpgradeConfig`](../../common/shared/Config/SharedConfig/UnitUpgradeConfig.luau), [`TargetPriority`](../../common/shared/Config/SharedConfig/TargetPriority.luau)

## How it works

The `UILibraryController/Components/ToggleTower.luau` component fills `StarterGui.Interface.CardUpgrade` for the selected unit.
Each `TextLabel` already carries its suffix from Studio (`DPS`, `COOLDOWN`, `RANGE`, `DMG DONE`), and the component only swaps the number.

| Label | Source |
| --- | --- |
| `Info.UnitName` / `Info.UnitLevel` | the model name and the `Upgrades` attribute |
| `UpgradeCost.TextLabel` | `UnitUpgradeConfig:GetCost`, or `MAX` at the last level |
| `Sell.TextLabel` | `GetInvested` × `SharedConfig.SellRefundRatio` (0.5) |
| `DamagePerSecond` | `GetDamage` (damage per hit, with weather); on a farm, the income per wave |
| `AttackSpeed` | `GetCooldown`, in seconds; on a farm with an aura, the aura bonus |
| `Range` | `GetRange` |
| `DmgDone` | the model's `DamageDone` attribute |
| `ClassIcon` | `ClassConfig.GetIcon`, from the unit's `Class` in `UnitStats` |
| `Info` (the image) | `CardConfig.GetIcon`, the unit's portrait |

The `DamagePerSecond` label actually shows **damage per hit**; the cooldown is on the same card.
`UnitUpgradeConfig:GetDPS` still exists, but no UI uses it.

- **`ClassIcon`** shows the unit's class art (`Melee`, `Ranged`, `Magic`, `Fire`, `Ice`, `Electric`), with ids in `ClassConfig.Icons`.
  The class itself is `UnitStats[name].Class`, the same one weather reads.
  A unit with two classes shows the **first**; a unit with no class (the Azure) hides the label.
  A new class is one line in `ClassConfig.Icons` and one in `WeatherConfig.ClassList`.
- **`Info`** is the frame that holds the name and level, and its image is the unit's **portrait** (`CardConfig.Icons`), a different art from the full hotbar card (`CardConfig.Images`).
  Keys are `UnitStats` names, not display names: the **Gladiator** portrait belongs to `Sword`, and the **Rocketeer**'s to `Rocket`.
  A unit without a portrait does **not** hide the frame (it holds the name and level); it falls back to the authored art, read once when the module loads, so the card never shows the previous unit's face.

Everything but `DmgDone` comes from `UnitUpgradeConfig`: the client repeats the server's math from the level.
Only the server knows `DmgDone`: `MobService:DamageMob` returns the damage that landed, `UnitService:addDamageDone` adds it to `entry.damageDone`, and a flush every 0.25 s sends a `unitId -> total` batch (`UnitDamageStats`) to every player.
Players who join mid-match get every total with `ClientReady`.
On the client, `UnitPlacementController` writes the `DamageDone` attribute on the model, and the card reacts to it.

### Next-level preview

Inside `DamagePerSecond`, `AttackSpeed`, and `Range` there is a second `TextLabel` (`DamagePerSecondUpgrade`, `CooldownUpgrade`, `RangeUpgrade`) with the value **after the next upgrade**.
It uses the same getters with `level + 1` and the current weather, so the preview matches what the server will use.

| Device | Behavior |
| --- | --- |
| Mouse | only while the pointer is over `UpgradeCost` |
| Touch (`PointerUtil.isTouchOnly`) | always visible |

At the last level the previews disappear.
They start invisible in Studio, and `destroy()` hides them with the card so the next unit does not open with the previous numbers.

### Opening and dragging

The card **grows in place**: its `UIScale` tweens from `0` to `1` with `Enum.EasingStyle.Elastic` on selection (`Out`) and back to `0` on deselection (`In`).
It becomes `Visible = false` only when the closing tween completes.
If another unit is selected mid-close, the old tween is canceled and `Completed` arrives as `Cancelled`, so it does not hide the card the new selection just opened.

The card can be **dragged** with a mouse or a finger from any point: background, texts, or its buttons (`Sell`, `UpgradeCost`, `Priority`, which must be in the list because they swallow input before it reaches the card).
Where the player drops it is where it opens from then on, for every unit, for the rest of the session.

- **A click is not a drag.**
  Movement becomes a drag only after `DRAG_THRESHOLD` (6 px).
  The click that ends a drag still reaches the buttons, so a `CLICK_BLOCK_TIME` window (0.15 s) swallows it; otherwise dragging by `SELL` would sell the unit.
- **`UserInputService` tracks the movement, not the card**, because the pointer leaves the card while dragging.
  On touch, the `InputObject` is the same from start to end, and comparing by identity stops a second finger from hijacking the drag.
  `WindowFocusReleased` also releases, so an alt-tab mid-drag does not leave the card stuck to the pointer.
- **The saved position is in scale, not pixels.**
  The drag math is in pixels, clamped to the `ScreenGui`, and only the result becomes scale, so the card stays in the same corner if the window resizes or the device rotates.
  The position lives in the client session; rejoining resets it.
- **`CardUpgrade.Active = true`.**
  An `ImageLabel` only receives input with it on, and it stops clicks from leaking into the world behind the card.

### Another player's unit

The card opens without `Sell`, `UpgradeCost`, and `Priority`, which only appear for the owner (the server refuses all three from anyone else anyway).
The rest stays: name, level, stats, priority, and damage done.
The next-level preview goes with the buttons.

The `Owned` attribute decides, written on the model by `UnitPlacementController` when the unit replicates.
Without the attribute, the answer is no.

### Tutorial match

In the tutorial, units cannot be upgraded or sold.
`UpgradeCost` and `Sell` stay on screen, locked, so the player learns where they are:

- `Interactable = false` closes them and `Active = false` goes with it;
- `AutoButtonColor` and `Selectable` are turned off so they look locked, not broken;
- the texts lose their `[E]` and `[X]` shortcuts, and the preview disappears.

The shortcuts follow automatically: `isButtonActive` reads the button's `Active` as well as `Visible`.
`Priority` is not locked, since changing targets costs nothing.

The tutorial's `StartingCash` covers the three towers in its deck; an upgrade would leave the final step without cash for the other two, and selling would return the Slingshot the script uses to teach weather, the shop, and speed.
The real refusal is on the server: `TutorialMatchService:CanUpgrade()` and `CanSell()`, checked by `UnitService` before charging and before refunding.

> **`Active` alone is no longer the switch.**
> The `CardUpgrade` and hotbar buttons have `InputSink = Enum.InputSink.Activate`, and writing `Active` does **not** write `InputSink`.
> Where a lock must hold, set `Interactable` too, and check the rule in code (`doUpgrade`, `doSell`, `AllowsCard`) instead of relying on a UI property.

### Jump button on touch

While the card is open on a touch device, the Roblox jump button is hidden (`ToggleTower:setJumpButtonHidden`), because the card opens over the corner where `TouchGui` draws `JumpButton`.
Only the button is hidden, not `controls:Disable()`, so the player can still walk.

`TouchGui` belongs to Roblox: its TouchJump module rewrites `Visible` on its own (respawn, sitting), and a respawn replaces the button.
The hiding is watched through `GetPropertyChangedSignal("Visible")` and `PlayerGui.DescendantAdded`, and on close the card restores the last state TouchJump asked for.

## Target priority

A click cycles the selected unit's priority through `TargetPriority.Order`:

| Mode | Button | Picks, within range |
| --- | --- | --- |
| `Closest` (default) | `CLOSEST` | the enemy closest to the unit |
| `Farthest` | `FARTHEST` | the enemy that has advanced the most along the path |
| `Weakest` | `WEAKEST` | the lowest current health |
| `Strongest` | `STRONGEST` | the highest current health |

Distance breaks ties in every mode, so the unit does not switch targets on every scan.

### `FARTHEST` measures the path, not the tower

"Farthest" is from the **start of the path**: the enemy that has walked the most is the one about to reach the base.
An enemy's progress is the distance from the first node to its nearest node, walking along the path (`PathUtil.GetNodeProgress`); a straight line would say an enemy went backward on maps that loop near the spawn.

The node list comes from `PathUtil.BuildNodeDistances`, built on the routes `BuildRoutes` already expands, so sub-paths and forks come in order.
A node on several routes enters once, with the smallest distance, so enemies on different branches are comparable.

| Side | Where | Position measured |
| --- | --- | --- |
| Server (decides damage) | `MobService:GetBestMobInRange` | the path point at `mob.Distance` |
| Client (turns the unit) | `TargetingController:FindBestTarget` | the model pivot minus the `PathOffsetY` attribute |

`PathOffsetY` is half the enemy's height, written by `MobController` at spawn.
Without it, the client would measure from the model center and the server from the ground, and they would pick different nodes near the middle of a segment.

The node scan only runs for `Farthest` (`TargetPriority.UsesPathProgress`), and the result is cached per enemy for `NODE_PROGRESS_REFRESH` (0.1 s) on both sides.
Until the whole path has replicated to the client, the client falls back to the farthest enemy from the tower.

### How a change travels

The button sends `SetUnitPriority` with the **target mode** (not "the next one").
`UnitService` checks the owner and the mode, stores it in `entry.priority`, clears the current target (otherwise the new priority would only apply when the current enemy left range), and fires `UnitPriorityChanged` to everyone.
The client writes it to the model's `TargetPriority` attribute, which drives both the button text and `TargetingController`.
The button never shows a priority the server has not confirmed.

Both sides compare with the same `TargetPriority.IsBetter`; the client reads each enemy's health from the `Health` attribute `MobController` keeps on the model.

On a farm, the button is hidden, since it targets nothing.
The `[V]` shortcut in the mockup is not wired.
