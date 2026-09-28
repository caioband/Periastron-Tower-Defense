# Tutorial

The tutorial offer in the Lobby, the scripted tutorial match, the shop flow back in the Lobby, and the analytics funnel that measures it.
The match script itself is described in [Tutorial match](../game/tutorial-match.md).

**Runs in:** Lobby (offer and shop flow) · Game (match)
**Code:** [`TutorialService`](../../common/server/Services/TutorialService.luau), [`TutorialController`](../../common/client/Controllers/TutorialController.luau), [`TutorialShopController`](../../common/client/Controllers/TutorialShopController.luau), [`ButtonGateController`](../../common/client/Controllers/ButtonGateController.luau), [`AnalyticsService`](../../common/server/Services/AnalyticsService.luau), [`TutorialConfig`](../../common/shared/Config/SharedConfig/TutorialConfig.luau), [`Config.Analytics`](../../common/server/Config/Analytics.luau)

## How it works

### The offer

A player who has never done the tutorial gets the offer on arriving in the Lobby, through the [dialog box](dialog.md):

```text
Hello, {name in an orange gradient}, welcome to Periastron Tower Defense
Would you like to play a Tutorial?
```

When the second line finishes typing, two buttons appear: `SURE!` on the right and `NO THANKS` on the left.
While the choice is open, clicking elsewhere does not close the box (`DialogController:hasChoice`).

**There is one profile key:** `Tutorial`, at the top of the template (`common/server/Config/Data.luau`).
`false` means "not done yet", which every new profile has, and every old profile gets through `DataService`'s reconcile.

- **Declining writes `true` immediately**: a refusal is an answer, not a postponement.
- The other path that writes it is `TutorialService:Complete(player)`, called from the Game by `WaveService` when the five waves are won (`onRoundEnded`, on victory).

| Piece | Where | What it does |
| --- | --- | --- |
| `TutorialService` | `common/server/Services` | reads the key on `PlayerDataLoaded`, sends `TutorialPrompt`, receives `TutorialAnswered`, has `:Start` and `:Complete` |
| `TutorialController` | `common/client/Controllers` | builds the lines, plays them through `DialogController`, answers the server, calls `:OnAnswer` |
| `TutorialConfig` | `SharedConfig` | the lines, font, size, button text, the delay before speaking, and the match script |

**Lobby only.**
The gate is `Environment.IsPlace("Lobby")`: `PlaceId` against the Lobby id of the current [environment](environments.md), so the QA Lobby offers it too.
In an unpublished place `PlaceId` is 0 and the offer does not appear by itself; the `tutorial` [admin command](admin-commands.md) goes through the same `:Prompt` and writes nothing.

**Where the tutorial starts.**
On the client, `TutorialController:OnAnswer(fn)` is called with `true` or `false` and returns an unsubscribe function.
On the server, `TutorialService:Start(player)` teleports the player to the tutorial map with the `Tutorial` flag in `TeleportData`.
From there, `TutorialMatchService` runs the [tutorial match](../game/tutorial-match.md).

The offer uses Press Start 2P, which is almost monospaced and about twice as wide per character as the renderer's default font, so `TutorialConfig.Text.Size` is 20 instead of the `Dialogue` preset's 24.

### Back in the Lobby: the shop flow

After the victory, the player returns to the Lobby with a `TutorialDone` ticket and `TutorialShopController` runs a seven-beat flow, each beat pointing at **the only clickable thing** at that moment:

1. a congratulations line;
2. the shop button;
3. the Crate of Beginnings buy button, once the shop opens;
4. the shop closes and the backpack button is pointed at;
5. the first crate in the backpack, once it opens (one click);
6. the backpack closes and the unboxing runs with the screen locked;
7. a goodbye line.

**The server starts it** (`TutorialShopPrompt`) and guarantees the epic unit from this crate; the client asks for no rarity.
The flow can be run on demand with the `tutorialshop` command.

A respawn restarts the flow instead of patching it, because the Lobby's `HUD`, `ShopUI`, and `crateui` all have `ResetOnSpawn`: before the purchase, from the start; after it, from the second half (`Start(fromCrate)`).

### Only what the step asks for is clickable (`ButtonGateController`)

Both the match steps and the Lobby flow declare a **whitelist**, and every `GuiButton` in `PlayerGui` outside it (and not a parent or child of something in it, nor in `TutorialConfig.ButtonGate.Always`) stops accepting clicks: `Active` and `Selectable` go to `false` and are restored at the end.

Aliases starting with `@` exist because some pieces are cloned at runtime and have no fixed path; they become **functions** the gate calls on every scan (and may return a list).
`@Highlight` follows whatever the [highlight](ui-guidance.md#highlight) is wrapping.

The lock is on buttons, not on the highlight's `BlockInput`, on purpose: that covers the screen with frames that also eat the drag that turns the camera.

> **The valve.**
> The lock exists to keep the player on the script, not to trap them: if a step's whitelist misses the button the step asks for, nothing can re-enable it.
> After `ButtonGate.Release` seconds (240) with a step **open**, the lock drops by itself and a Studio warning says why.
> The number is generous on purpose: a valve that fires in a normal match is a bug, and the floor is how long a first-time player takes, not a developer.
> A step can set its own `ButtonRelease` (`BackToLobby` uses 600, since it is the only step with no next step to re-lock the screen).

None of this is a game rule: the server still refuses what it refuses (`CanPlace`, `CanUse`, `CanBuy`, `CanSell`, `CanUpgrade`).
The lock is interface guidance; a tampered client can unlock its own screen and gain nothing.

## The analytics funnel

The new player's path is measured as a Roblox **onboarding funnel** of 13 steps, from the offer in the Lobby to the opened crate on return.
It answers "at which step do players give up".

| # | Step | Sent by |
| --- | --- | --- |
| 1 | `PromptShown` | `TutorialService:offer` (the offer went out) |
| 2 | `Accepted` | `TutorialService`, on `TutorialAnswered` |
| 3 | `MatchJoined` | `TutorialMatchService:watchPlayers` |
| 4–9 | `ClickReady`, `PlaceFirst`, `BuyReport`, `UseReport`, `UseSpeed`, `PlaceRest` | `TutorialMatchService:CompleteStep` |
| 10 | `MatchWon` | `WaveService:onRoundEnded` |
| 11 | `BackToLobby` | `TutorialService:shopPrompt` (the teleport ticket) |
| 12 | `CrateBought` | `TutorialService:watchShop` |
| 13 | `CrateOpened` | the client, through `TutorialShopFinished` |

- **Steps 4 to 9 are the script's `Id`s**, passed straight to `LogFunnelStep` with no translation table to fall out of date.
- **The list order is the number** (`ServerConfig.Analytics.Funnel.Onboarding`): add new steps at the end, or the dashboard starts comparing numbers that mean something else.
- **Why an onboarding funnel and not a session funnel:** it needs no `funnelSessionId`, so it crosses Lobby → Game → Lobby without an id travelling in `TeleportData`.
  It counts only the first time per user, which matches the `Tutorial` key and keeps `tutorialreset` from inflating the dashboard.
- **Two things the funnel cannot say are events** (`LogCustomEvent`): `TutorialDeclined` (clicking NO THANKS and ignoring the box both stop at step 1) and `TutorialAbandoned` (a match left midway).
  The event value is the wave, and the open step's `Id` goes in `CustomField01`.
  `TutorialMatchService.Won`, set by `NoteWon()`, tells an abandon from the teleport back, since both leave through `PlayerRemoving`.
- **Step 13 is the only one born on the client**, because only the client sees the unboxing end.
  It fires at the end of `TutorialShopController:run`, not in `:finish()`, which also runs when the flow aborts.
  The server checks who the notice belongs to.
- **Test commands stay out of the dashboard.**
  `tutorial` and `tutorialshop` go through `:Prompt` and `:PromptShop`, which log nothing; steps 12 and 13 only count for players marked in `TutorialService.Returned`, set only by the `TutorialDone` ticket.

| Piece | Where | What it does |
| --- | --- | --- |
| `AnalyticsService` | `common/server/Services` | the only code that talks to Roblox's `AnalyticsService`: `:LogFunnelStep` and `:LogEvent` |
| `Analytics` | `ServerConfig` | the ordered step list and event names |

**Nothing is sent from Studio or from the client** (a Roblox rule: events only count from a server in a published place).
`AnalyticsService` checks `RunService:IsStudio()` and `PlaceId == 0` and, instead of dropping the call, logs `(studio) step N "Name"` with `log:Debug`, which is how the whole script is checked in Studio.
Every engine call runs in a `pcall`: telemetry that breaks a tutorial step is worse than no telemetry.

## Studio setup

The dashboard only exists after Analytics is enabled for the universe in the Creator Hub, and it takes a few hours to fill.
The Studio Output confirms the path; the Creator Hub only confirms that events arrived.
