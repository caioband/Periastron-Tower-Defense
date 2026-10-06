# Tutorial match

The scripted five-wave match a new player plays after accepting the [tutorial](../common/tutorial.md).
Each step opens on a wave, points at one thing, and holds the wave until the player does it.

**Runs in:** Game
**Code:** [`TutorialMatchService`](../../Game/src/Services/TutorialMatchService.luau), [`TutorialStepController`](../../Game/src/Controllers/TutorialStepController.luau), [`ButtonGateController`](../../common/client/Controllers/ButtonGateController.luau), [`TutorialConfig`](../../common/shared/Config/SharedConfig/TutorialConfig.luau)

## How it works

A server is a tutorial match when the first player's `TeleportData` carries the `Tutorial` flag, or, in Studio, when the `StudioMap` attribute on `ServerStorage.Maps` names the tutorial map (`TutorialConfig.Match.Map`).
From then on, `TutorialMatchService` runs the script in `TutorialConfig.Match.Steps`, and `TutorialStepController` draws each step on the client (dialog, [highlight and arrow](../common/ui-guidance.md), and the button whitelist).

The server enforces the script: `CanPlace`, `CanUse`, `CanBuy`, `CanSell`, and `CanUpgrade` refuse anything outside the current step.
Upgrading and selling are refused for the whole match (see [Upgrade card](upgrade-card.md#tutorial-match)).

### Steps

| Step | Wave | Unlocks |
| --- | --- | --- |
| `ClickReady` | 0 | `Interface.ReadyWave` |
| `PlaceFirst` | 1 | `@Card`: the unit card in the hotbar |
| `BuyReport` | 2 | `RoundCardShop.RCSFrame.CardShop` and `@Offer` |
| `UseReport` | 3 | `@Hand`: the round card already in hand |
| `UseSpeed` | 4 | `Interface.Speed` and `@SpeedOptions` |
| `PlaceRest` | 5 | `@Deck`: the whole hotbar, which this step unlocks |
| `BackToLobby` | end | `ResultScreen.MainScreen.Lobby` |

`ClickReady` hides the hotbar (`HideDeck`) while the player learns the Ready button.

- **The shop opens once.**
  In the tutorial, the [round card shop](round-card-shop.md) calendar does not apply: the step's `OpenShop` opens it, and only `BuyReport` declares it.
  `CardShopService` asks `TutorialMatchService:ShopIsScripted()` before `IsShopWave`, because the tutorial preset has no interval of its own and would fall back to 4, reopening the shop on top of the speed step.
- **The speed button does not open a panel.**
  It clones itself once per step and places the clones **next to it**, under the same parent, so unlocking the button does not unlock the options; `@SpeedOptions` asks `SpeedController` for the list.
  When the menu opens, the highlight slides from the button to the step's option, and back if the menu closes.
  The step's `Index` is 2, which is **1.5x**: 2x needs a game pass, and a step that holds the wave behind a purchase is a dead end.
- **The closing step pays for its own cards.**
  `PlaceRest` (wave 5, cover the free spots before the boss) declares `GrantCash = 500`, given by `TutorialMatchService:grantCash` when the step opens: the 250 for the two Archers left in the deck (125 each), plus 250 of slack so the player cannot softlock.
  It is a gift, not the `Ensure` safety net (`ensureCash`, which only tops up to the price of a required card): it comes in whole, once, and `Granted` stores the `Id` so a step reopened does not pay twice.

Wave 1 asks for the **Slingshot**, the only card allowed until wave 5 (`AllowedUnits`): the tutorial teaches weather, the shop, and speed with one tower on screen.

### The lock belongs to the match, not the step

Once a step is done, its whitelist stays until the next one opens; otherwise the pause between two waves would be the moment to leave the script.
What ends when a step is done is the **valve deadline**, not the lock (see [the valve](../common/tutorial.md#only-what-the-step-asks-for-is-clickable-buttongatecontroller)).

### Respawn

Dying closes no step: it stays open on the server, holding the wave if needed, but everything with `ResetOnSpawn` is gone.
`TutorialStepController` listens to `CharacterAdded` and reapplies the open step: the whitelist is recounted against the new tree, the arrows are rebuilt, and the highlight returns.
**The dialog comes first**: if it is coming back, the highlight waits for it to end, as it would the first time.
In the match there is little to redo, because `Interface` (hotbar, Ready, Speed) has no `ResetOnSpawn`.

## Configuration

Each entry in `TutorialConfig.Match.Steps` can declare:

| Field | Effect |
| --- | --- |
| `Id` | the step name, also used as the analytics funnel step |
| `Wave` | the wave the step opens on |
| `Lines` | the dialog shown first |
| `Buttons` | the whitelist of clickable buttons; a step without it locks nothing |
| `BlockedButtons` | buttons subtracted from the whitelist (wins over `Buttons`), for when the whitelist is a whole panel |
| `Highlight`, `Point`/`Points` | what to highlight and where to point the arrow (`Map.PlacementPoints`) |
| `Hold` | whether the step holds the wave until done |
| `OpenShop` | opens the round card shop on this step |
| `GrantCash` | cash given to everyone when the step opens |
| `HideDeck` | hides `Interface.TowerContainer` during the step |
| `ButtonRelease` | this step's valve deadline, when the default does not fit |
