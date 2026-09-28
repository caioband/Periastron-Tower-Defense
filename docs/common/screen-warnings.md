# Screen warnings

The big warning in the middle of the screen, shared by the weather announcement and the server restart warning.

**Runs in:** Game · Lobby
**Code:** [`WarningController`](../../common/client/Controllers/WarningController.luau), [`ServerRestartService`](../../common/server/Services/ServerRestartService.luau), [`ServerRestartController`](../../common/client/Controllers/ServerRestartController.luau), [`WarningConfig`](../../common/shared/Config/SharedConfig/WarningConfig.luau)

## How it works

`StarterGui.Interface.WeatherWarning` is a single `TextLabel`, and two owners write to it: the [upcoming weather](../game/weather-in-match.md#the-on-screen-warning) and the server restart.
Only `WarningController` touches the label; owners send the finished sentence:

```lua
WarningController:Show("WARNING! SERVER RESTART FOR GAME UPDATE IN 2 MINUTES", {
    Priority = WarningConfig.Priority.Restart,
    Hold = 8,
})
```

The text slides down from `SlideOffset` above its target while the transparency of the text **and its stroke** goes from 1 to 0, holds for `Hold` seconds, and leaves the same way.
The target is the position authored in Studio, so moving the label needs no code change.
The stroke fades with the text; otherwise a solid outline would sit behind invisible letters.

**Priority settles which owner gets the label.**
A warning replaces the current one when it ties or wins on priority (`Weather` = 1, `Restart` = 2) and is refused when it loses: the wave 8 weather does not erase "the server will restart in 1 minute".
`Hide` takes the same priority as "clear only mine", which is how `RoundRestarted` clears the weather warning without taking the restart warning.

The [skip wave prompt](../game/skip-wave.md#animation) uses the same animation.

## Server restart warning

When Roblox schedules this server's end (a published update, maintenance, moderation, memory), `game.ServerRestartScheduled` fires **on the server** with `restartTime` (a `DateTime`) and `source` (an `Enum.CloseReason`).
`ServerRestartService` forwards it to clients, and `ServerRestartController` writes to the label:

```text
WARNING! SERVER RESTART FOR GAME UPDATE IN 2 MINUTES
WARNING! SERVER RESTART FOR ROBLOX MAINTENANCE IN 45 SECONDS
WARNING! SERVER RESTARTING FOR MODERATION            (under 5 s left)
```

`WarningConfig.Restart.Sources` turns the reason into text, separating a **developer** restart (`DeveloperUpdate`, `DeveloperShutdown` → "GAME UPDATE") from a **Roblox** one (`RobloxMaintenance`, `Moderation`, `OutOfMemory`, `ServerEmpty`, `Unknown`).
A reason the engine adds later falls back to `DefaultSource` instead of showing nothing.

- **The seconds remaining cross the network, not the time.**
  `restartTime` is UTC and the player's clock is unreliable.
  The server subtracts on every send, so a player joining two minutes later gets two minutes less, and the client anchors the deadline on `os.clock()`, which is monotonic.
- **The warning comes back.**
  A restart is scheduled minutes ahead and an 8-second sentence mid-wave is easy to miss, so `WarningConfig.Restart.Reminders` (5 min, 2 min, 1 min, 30 s, 10 s) shows it again with the new number.
  A mark that would overlap the previous warning is skipped.
- Players who join after the schedule ask for it with `RequestServerRestart`.

The event cannot be triggered for real without publishing an update, so the `restartwarning` [admin command](admin-commands.md#restartwarning) goes through the same `ServerRestartService:Schedule` without scheduling anything.

## Configuration

| Key | Value | Effect |
| --- | --- | --- |
| `WarningConfig.Label` | `SlideOffset = 0.06`, `Hold = 5`, … | The label name, animation, and default hold |
| `WarningConfig.Priority` | `Weather = 1`, `Restart = 2` | Who wins the label |
| `WarningConfig.Restart.Hold` | `8` | Seconds a restart warning stays |
| `WarningConfig.Restart.Reminders` | `{ 300, 120, 60, 30, 10 }` | Seconds left at which the warning returns |
| `WarningConfig.Restart.Sources` / `DefaultSource` | | Reason → text |

The weather sentences live in `WeatherConfig.Warning`.
