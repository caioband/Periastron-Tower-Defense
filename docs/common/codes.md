# Codes

Players type a code on the codes panel (`SharedUIs.CodesGUI`) and get coins, shards, or crates.
Only members of the game's Roblox group can redeem, and every code has an expiry date.

**Runs in:** Game · Lobby · AFK
**Code:** [`CodeService`](../../common/server/Services/CodeService.luau), [`RewardService`](../../common/server/Services/RewardService.luau), [`CodeController`](../../common/client/Controllers/CodeController.luau), [`Config.Codes`](../../common/server/Config/Codes.luau), [`CodeConfig`](../../common/shared/Config/SharedConfig/CodeConfig.luau)

## How it works

The panel opens from the `Code` button on the [settings panel](settings.md), which closes the settings first.
It is a [proximity panel](proximity-panel.md) with no spot on the map, the same as the contracts board: the Cascade `OpenShop` in the Lobby (a scale tween elsewhere), the background blur, the rest of the UI hidden, and `Close` to leave.

The player types in `Codes.Frame.TextBox` and presses `Redeem` or Enter.
The client sends only the text; `CodeService` decides, in this order:

| Check | Fails with |
| --- | --- |
| The text is not empty and at most `MAX_LENGTH` characters | `Empty`, `Invalid` |
| One attempt every `ATTEMPT_COOLDOWN` seconds, valid or not, and one in flight | `Cooldown`, `Busy` |
| The profile is loaded | `NotLoaded` |
| The player is in `GROUP_ID` | `NotInGroup`, `GroupCheckFailed` |
| The code exists and `StartsAt` has passed | `Invalid` |
| `ExpiresAt` has not passed | `Expired` |
| The player has not redeemed it before | `AlreadyRedeemed` |

Then it writes the code into `Profile.RedeemedCodes` and pays through `RewardService`, with nothing that yields in between, so a double click never pays twice.

- **Codes ignore case and surrounding spaces.** `release` and ` RELEASE ` both match `RELEASE`.
- **A code that has not started looks like one that does not exist**, so a scheduled code cannot be found early.
- **The group comes first.** A player outside the group gets `NotInGroup` whatever they typed, and the client opens Roblox's join prompt (`GroupService:PromptJoinAsync`).
  After joining, they press `Redeem` again.
- **Joining mid-session works.** The server's `IsInGroup` is cached for the session, so on a "no" `CodeService` asks again with `GetGroupsAsync`, which is not cached.
- **"Like the game" is only text.** Roblox has no API to know whether a player liked the experience.

### Feedback

The answer goes on the panel's `Codes.Text` line, which the controller switches to `RichText`:

- **Success:** green, `Code redeemed!` and the rewards on a second line (`+500 Coins  +3 Shards  2x Fragmented Crate`), with the `Coins` sound.
- **Failure:** red, the reason's line from `CodeConfig.Messages`.
- **Closing the panel** puts the authored line back and empties the box.

The answer arrives as `CodeRedeemResult` with the request id the client sent, because Warp does not order events; an answer for an older attempt is ignored.

### The Redeem button

`Redeem.RedeemText` is a `TextLabel` (`RichText`, `TextScaled`, gold) that `RichTextController` writes `[gold]REDEEM[/gold]` into: gold letters with sparkles.
It is written the first time each copy of the screen opens, because the renderer draws nothing in a box that measures zero, and with `Fit` it waits for the open animation to finish before measuring.
If HyperText fails to load, the plain backend writes `REDEEM` into the label, and the label's own gold color and `TextScaled` still apply.

`Redeem` sits next to the panel art in `CodesContainer`, not inside it, and the Lobby's `OpenShop` grows only the art.
So the button follows the art's `UIScale` through its own `Size`, and its image fades with the art.
Its `UIScale` is left for the hover and press feedback.

## Configuration

Server only, in `ServerScriptService.Config.Codes`:

| Key | Default | Effect |
| --- | --- | --- |
| `GROUP_ID` | `660345753` | The group the player must be in |
| `ATTEMPT_COOLDOWN` | `2` | Seconds between two attempts by the same player |
| `MAX_LENGTH` | `32` | Longer input is `Invalid` |
| `Codes` | `RELEASE` | The codes, keyed in UPPERCASE |

Each code:

| Field | Required | Meaning |
| --- | --- | --- |
| `ExpiresAt` | yes | Unix time (UTC) when it stops working |
| `StartsAt` | no | Unix time (UTC) before which it does not exist |
| `Rewards` | yes | `{ Cash, Shards, Crates = { [rarity] = amount } }` |

Client texts and colors are in `SharedConfig.CodeConfig`: UI names (`Gui`), `REDEEM_MARKUP`, `SUCCESS_COLOR`, `ERROR_COLOR`, `REWARD_COLORS`, and `Messages`.

## Usage

Adding a code is one entry in `Config.Codes.Codes`:

```lua
SUMMER = {
    StartsAt = utc(2027, 1, 10, 15),   -- optional
    ExpiresAt = utc(2027, 2, 1),
    Rewards = { Cash = 1000, Shards = 10, Crates = { Epic = 2 } },
},
```

`utc(year, month, day, hour?, minute?)` is defined at the top of the file.
Crate keys are the `CrateConfig.CRATES` rarities: `Common`, `Rare`, `Epic`, `Legendary`.

`CodeController` has `Open`, `Close`, `Toggle`, and `IsOpen`.
`RewardService:Grant(player, rewards)` pays a bundle from any server system.

## Studio setup

| Piece | Name |
| --- | --- |
| Folder | `SharedUIs` (a Package: publish it to reach every place) |
| ScreenGui | `CodesGUI` |
| Frame that comes and goes (`Wrapper`) | `CodesContainer` |
| Art (`Panel`) | `Codes`, with `Close` and the `Text` line inside |
| Input | `Codes.Frame.TextBox` |
| Button | `CodesContainer.Redeem`, with the `RedeemText` label inside |
| Opens it | `SettingsGUI.SettingsContainer.Code` |

## Design notes

- The code list is server config because the list is the secret: a replicated list would show every unannounced code.
- `RewardService` exists so contracts and codes pay the same way; crates go through `CrateService` where it exists (the Lobby, which notifies the backpack) and straight into the inventory elsewhere.
- Redeemed codes are stored with the time they were redeemed, not just `true`, so support can answer "when did I get it".

## Known issues

- The open animation scales `Redeem` around its own center, not the panel's, so it grows in place instead of out of the panel.
