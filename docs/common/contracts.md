# Contracts

Hourly, daily, and weekly objectives with rewards, shown on the Lobby's contracts board (`StarterGui.Contracts`) and tracked in both places.

**Runs in:** Game · Lobby
**Code:** [`ContractService`](../../common/server/Services/ContractService.luau), [`ContractTrackerService`](../../Game/src/Services/ContractTrackerService.luau), [`ContractController`](../../Lobby/src/Controllers/ContractController.luau), [`CrateService`](../../Lobby/src/Services/CrateService.luau), [`ContractConfig`](../../common/shared/Config/SharedConfig/ContractConfig.luau)

## How it works

The board opens at `Workspace.ContractsBoard.TargetPart` (`ContractConfig.Board`), by [proximity](proximity-panel.md) (6 studs) or through the `Contracts` button in the HUD's left column (`HUD.HUDLeft.Wrapper.Contracts`), which takes the player there.
It has three sections, each with a countdown to the rollover:

| Period | Contracts | Rolls over (UTC) |
| --- | --- | --- |
| Hourly | 2 | every full hour |
| Daily | 3 | midnight |
| Weekly | 4 | Monday 00:00 |

The list, what each contract counts, and what it pays are in `SharedConfig.ContractConfig`, one contract per line.
The description ends with the progress: `Win 4 games in Volcano on Hard (1/4)`.

| Piece | Place | What it does |
| --- | --- | --- |
| `ContractService` | common | draws on rollover, records progress, writes in batches, claims and pays |
| `ContractTrackerService` | Game | turns the match into events (`Record`) |
| `CrateService` | Lobby | the `Unbox` event, with the rarity of the unit that came out |
| `ContractController` | Lobby | draws the board from the replica, takes the player there, sends CLAIM |

The profile stores `Data.Contracts = { Hourly|Daily|Weekly = { Period, Slots } }`.
Each slot has `{ Id, Params, Progress, Claimed }`, plus `Seen` for the login contract.

### Drawing

- **Per player, on rollover.**
  Every 2 s (and when the profile loads), each period is compared with the current one, and a period that rolled over is drawn again.
  Unclaimed contracts are lost with it.
- **Variety.**
  The previous period's contracts go to the back of the urn and only return when there are not enough new ones.
- **Locks.**
  A contract tied to a map or difficulty the player has not unlocked is not drawn (Volcano for a player with two wins, Nightmare for a level 1 player), and `Random` parameters draw only among unlocked options.
  `D_Stun676` only appears for players with a unit that stuns (`NeedsUnitStat = "Stun"`), and `{Class}` only among classes the player owns.

### What counts

Everything is **the player's own**: kills, damage, and stuns belong to whoever owns the unit, and cash is theirs.
Only weather and waves belong to the room.

| Event | Source |
| --- | --- |
| `Win` | `WaveService.Signals.MatchFinished`, with map, difficulty, full base, a friend in the room, and the classes **all** placed units shared |
| `Kill`, `BossKill`, `Stun`, `Damage` | `MobService.SessionStats` (and `SessionDamage`), read every 3 s |
| `MatchCashSpent`, `MatchCashEarned` | same, with `Mode = "Max"`: the best match, not the sum |
| `WaveReached` | `WaveService.Signals.WaveStarted` (`Max`) |
| `Weather` | `WeatherRoundService.Signals.WeatherStarted`: only weather that starts, not the warning |
| `MatchTime` | `MatchStatsService.Signals.Closed` (seconds) |
| `Unbox` | `CrateService:OpenCrate`; the `unbox` command and summons do not count |
| `Login` | the UTC day the player is online, marked every tick (`Distinct`) |

- **"With only {Class} units"** holds if every unit placed in the match had that class, including sold ones.
  A unit with no class breaks the condition.
- **"With 1 or more friends"** means a Roblox friend in the same match, checked when the player joins the server and kept until the win.

### Batched writes and claiming

`Record` only queues per player.
`Flush` writes everything in one `Update` of `Contracts` every 2 s, at the end of the match, and on leave.
Each entry remembers the period and the slot's `Id`, so progress on an expired contract never lands on its replacement.

CLAIM sends only `(period, slot)`.
The server flushes the queue, checks that the slot is complete and unpaid, marks it, and pays, with nothing that yields in between, so two clicks never pay twice.
The reward is paid by `RewardService`, the same as [codes](codes.md): it adds `Cash` (and `CoinsEarned`), `Shards`, and crates (through `CrateService:GiveCrates` in the Lobby, straight into the inventory elsewhere).

In the UI, coins and shards use the authored rows of `RewardsContainer`, and each crate becomes an `8x Fragmented Crate` text in `OtherReward`, cloned when there is more than one.
A paid slot also shows the `Claimed` stamp on its `TaskPaper`, following `slot.Claimed` from the replica: it appears on claim and disappears on rollover, when the button returns to `CLAIM`.

### The HUD button

The `Contracts` button drops the player **on top of the `TargetPart`** itself (the center of the radius; there is no separate landing marker as with the shops), `TeleportHeightOffset` (3 studs) above it, and zeroes their velocity.
The board still opens by hand through `EnterRange`, because the distance check only runs every `ProximityInterval` (0.2 s).
`ContractController` binds only the click, in its own maid (`HudMaid`), because the HUD is recreated on every respawn and `Contracts` is not.
The button's animation belongs to `HUDButtonController` (see [HUD](../lobby/hud.md)).

### Paid reroll

Each section header has a `RerollDice` button.
It opens a different developer product for each reroll of the period: the 1st reroll opens product 1, the 2nd product 2, and from the 7th on it stays on product 7 (`ContractConfig.Reroll.Products` and `rerollProduct`).
The count is `Contracts[kind].Rerolls` in the profile and resets on rollover.

The client only opens the prompt; the receipt does the reroll.
`ContractService` registers all 21 products with `MonetizationService` in both places (a pending receipt returns wherever the player is), and any product of a section rerolls that section.
`Reroll` redraws the **whole** section, including claimed slots, with progress reset and avoiding the contracts that were there.
The progress queue is flushed first, so it cannot land on an identical contract drawn into the same slot.
