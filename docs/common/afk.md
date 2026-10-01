# AFK detection

Marks a player AFK after five minutes without input or as soon as they leave the game window, and tells the server.
`PlaytimeService` uses it to stop counting `Stats.TimePlayed` while the player is AFK in the Lobby.

**Runs in:** Game · Lobby
**Code:** [`AfkController`](../../common/client/Controllers/AfkController.luau), [`AfkService`](../../common/server/Services/AfkService.luau), [`AfkConfig`](../../common/shared/Config/SharedConfig/AfkConfig.luau)

## How it works

`AfkController` runs on the client and marks the player AFK when either of these is true:

- the window lost focus (Alt-Tab, minimized, or the app went to the background on mobile);
- there has been no input for `IdleSeconds`.

Input counts when it reaches `InputBegan` (keys, clicks, taps, gamepad buttons, chat typing) or `InputChanged` for the mouse, the wheel, touch drags, and the sticks past `ThumbstickDeadzone`.
Any input, or getting focus back, makes the player active again right away.

The controller sends `AfkChanged(isAfk)` to the server only when the state changes.
`AfkService` stores it, sets the `Afk` attribute on the `Player` while they are AFK, and fires `Signals.AfkChanged(player, isAfk)`.

Every player starts active.
Teleporting between the Lobby and the Game starts the state over.

### Playtime

Where `PausePlaytime` is `true`, `PlaytimeService` freezes the player's clock when they go AFK and resumes it when they come back.
The time spent AFK is never written; nothing is written on the switch itself, so going AFK and back does not touch the profile.
The leaderboard keeps its one-minute write.

`PlaytimeService` tells the places apart by the `Place` attribute each Rojo project sets on `ServerScriptService.Services`, not by `PlaceId`, so QA copies of the Lobby pause too.
In the AFK place it does not count at all: time there goes to `Stats.TimeInAfkArea` (see [AFK area](../afk/afk-area.md)).

## Configuration

`ReplicatedStorage.Shared.Config.SharedConfig.AfkConfig`:

| Key | Default | Effect |
| --- | --- | --- |
| `IdleSeconds` | `300` | Seconds without input before the player is AFK. |
| `FocusLossIsAfk` | `true` | Losing window focus marks the player AFK at once. |
| `CheckInterval` | `1` | How often the client rechecks the idle timer, in seconds. |
| `ThumbstickDeadzone` | `0.2` | Stick magnitude below which stick movement is not input. |
| `Attribute` | `"Afk"` | Attribute set to `true` on the `Player` while AFK, and removed when they come back. |
| `PausePlaytime` | `{ Lobby = true, Game = false }` | Places where `Stats.TimePlayed` stops while the player is AFK. |

## Usage

On the server:

```lua
local afkService = Framework:Get("AfkService")

if afkService:IsAfk(player) then
	-- ...
end

afkService.Signals.AfkChanged:Connect(function(player : Player, isAfk : boolean)
	-- ...
end)
```

On the client, `AfkController:IsAfk()` returns the local player's state.
To read anyone's state without a dependency, including other players from a client, check `player:GetAttribute("Afk") == true`.

## Design notes

- **The client decides.** Input and window focus only exist on the client, so the server has nothing to check a report against.
  `Player.Idled` is not used: it is client-only as well, only fires after about two minutes, and measures the same input.
- **No heartbeat.** A periodic "still here" message would cost traffic and prove nothing, because an exploiter can send it just as well.
- **Focus loss counts at once.** A player can leave the window focused and walk away, which is why the idle timer exists too, but a player who switched to another window is not playing.

## Known issues

- An exploiter can stay active by never sending the report, and an autoclicker defeats any input-based check.
  Do not use this state for anything worth more than what a player can already fake.
- The client assumes the window is focused when it loads.
  A player who teleports in while tabbed out stays active until they come back to the window or the idle timer runs out.
- A player watching the game on a second monitor, without focus, counts as AFK.
