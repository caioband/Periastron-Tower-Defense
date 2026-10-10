# Next event sign

A sign in the Lobby shows the name of the next Roblox experience event and a countdown to it, and its prompt lets the player RSVP.

**Runs in:** Lobby (client)
**Code:** [`NextEventController`](../../Lobby/src/Controllers/NextEventController.luau)

## How it works

The event is a Roblox experience event (created on the Creator Hub), read by id with `SocialService:GetExperienceEventAsync` when the client starts and again every `REFRESH_INTERVAL` (5 minutes), so a new title or start time shows up without a rejoin.

- **Name:** `DisplayTitle` (the title in the player's language), or `Title` when it is empty, in `EventName`.
- **Countdown:** time until `StartTime` in `Timer`, as `02 Days : 05 Hours : 13 Minutes : 09 Seconds`, updated every second against `workspace:GetServerTimeNow()`.
- **Prompt:** triggering `ProximityPrompt` opens Roblox's RSVP prompt (`SocialService:PromptRsvpToEventAsync`).
  Once the player is going, the prompt reads `Notified ✓`; it stays enabled, so the same prompt lets them cancel.

**The sign only shows before the event starts.** `BillboardGui` and `ProximityPrompt` are disabled (locally) while the event is loading or cannot be read, once it has started (RSVP no longer works then), when it is cancelled, and after it ends.

Every environment uses the same id (`EVENT_ID`).
Roblox only answers `GetExperienceEventAsync` for events of the current universe, so in QA the Production event comes back empty and the sign stays hidden there.

`StartTime` comes as date parts, and the docs do not give its time zone; it is read as UTC.
Every read prints the start it understood, in the client console (`log:Info`):

```text
next event "Halloween Update" starts 2026-10-31T17:00:00Z (read as UTC), in 27 Days : 22 Hours : 14 Minutes : 03 Seconds
```

If the countdown is off by whole hours from the event page, the time zone assumption is wrong.

Streaming can take the part out of the world and bring it back, so the controller binds the sign every time it appears.

## Configuration

Constants at the top of `NextEventController`:

| Key | Default | Effect |
| --- | --- | --- |
| `EVENT_ID` | `"2141559620710302327"` | The event, the same in every environment |
| `REFRESH_INTERVAL` | `300` | Seconds between reads of the event |
| `TIMER_FORMAT` | `"%02d Days : %02d Hours : %02d Minutes : %02d Seconds"` | The countdown text |
| `NOTIFIED_TEXT` | `"Notified ✓"` | The prompt's text once the player is going; before that it keeps the text authored in Studio (`Notify`) |

To point the sign at a new event, change `EVENT_ID`.

## Studio setup

| Piece | Name |
| --- | --- |
| Part | `Workspace.NEXTEVENT` |
| BillboardGui | `NEXTEVENT.BillboardGui` |
| Name label | `BillboardGui.EventName` |
| Countdown label | `BillboardGui.Timer` |
| Prompt | `NEXTEVENT.ProximityPrompt` |

## Known issues

- The event only exists in Production, and `SocialService` may not answer in a Studio playtest, so the sign can only be seen working in the published Production Lobby.
- The `BillboardGui` is enabled in Studio, so its placeholder text can show for a moment before the controller binds; disabling it in Studio avoids that.
