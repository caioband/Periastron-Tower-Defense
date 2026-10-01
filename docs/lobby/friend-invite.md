# Friend invite suggestion

A while after a player arrives in the Lobby, a Roblox notification suggests one of their online friends and offers to invite them.

**Runs in:** Lobby
**Code:** [`FriendInviteService`](../../Lobby/src/Services/FriendInviteService.luau), [`FriendInviteController`](../../Lobby/src/Controllers/FriendInviteController.luau), [`friendinvite`](../../Lobby/src/CmdrDefinitions/Commands/FriendInvite.luau), [`friendinvitestats`](../../Lobby/src/CmdrDefinitions/Commands/FriendInviteStats.luau), [`ProfileEditService`](../../common/server/Services/ProfileEditService.luau), [`Config.Data`](../../common/server/Config/Data.luau) (`FriendInvites`)

## How it works

1. When the client is ready (`DataService:Get`), `FriendInviteService` waits `PROMPT_DELAY` seconds and sends `FriendInvitePrompt`, then sends it again every `PROMPT_INTERVAL` seconds while the player stays in the Lobby.
   A beat is skipped while the tutorial has the player's attention: `Tutorial = false` (the offer is pending) or the shop step after the tutorial match (`TutorialService.Returned`, cleared when that unboxing ends).
2. The payload carries `Exclude` (friends suggested in the last hour), `Preferred` (friends with history: most accepted invites first, then most `Invite` clicks, ties in random order), and `LaunchData`.
3. `FriendInviteController` asks Roblox for the online friends (`Player:GetFriendsOnline`, which only works on the client) and drops those on this server and those in `Exclude`.
4. It picks the first `Preferred` friend still eligible; with none, any eligible friend at random.
   With no eligible friend it shows nothing.
5. It reports the pick (`FriendInviteShown`) and shows a CoreGui notification (`SendNotification`) with the friend's headshot, `Invite`, and `Decline`, for 20 seconds.
6. `Invite` reports the click (`FriendInviteAnswered`) and opens Roblox's invite prompt aimed at that friend (`SocialService:PromptGameInvite` with `ExperienceInviteOptions.InviteUser`), with `LaunchData` set to `LAUNCH_DATA`.
   `Decline` and the timeout only close the notification.

Each friend still sits out `COOLDOWN` after being shown, so a player with few friends online soon gets no notification until one comes back into the draw.

### Accepted invites

When a player joins the Lobby, the service reads their `GetJoinData()`:

- `ReferredByPlayerId` is the player who invited them, set by Roblox for invites and share links.
- `LaunchData` equal to `LAUNCH_DATA` means the invite came from our notification.

| Source | Counted as |
| --- | --- |
| Invite from our notification | `System` |
| Any other invite or share link from that player | `Manual` |
| Either | `Total` |

The count goes to the **inviter's** profile, under the joining player's `UserId`, through `ProfileEditService`'s `increment` operation.
It reaches the inviter wherever they are: on this server right away, on another server (any place) by `MessageAsync`, or offline through a short session (see [Admin commands](../common/admin-commands.md#players-on-another-server-or-offline)).
It counts once per join, because the join data only belongs to that join; going to a match and back is a teleport and carries no referral.

## Profile

`FriendInvites`, keyed by the friend's `UserId` as a string:

| Key | Value | Written when |
| --- | --- | --- |
| `Invited` | `{ [UserId] = times }` | The player clicks `Invite` |
| `Accepted` | `{ [UserId] = { System, Manual, Total } }` | That friend joins the Lobby from an invite this player sent |
| `Shown` | `{ [UserId] = os.time() }` | The friend is suggested; expired entries are removed on the next write |

The server only accepts `Shown` right after a prompt it sent and only for a real friend (`IsFriendsWith`), and it only counts `Invite` for the friend shown last, once.

## Configuration

Constants at the top of each module:

| Key | Default | Module | Effect |
| --- | --- | --- | --- |
| `PROMPT_DELAY` | `30` | Service | Seconds after the client is ready before the first suggestion |
| `PROMPT_INTERVAL` | `120` | Service | Seconds between suggestions after the first |
| `COOLDOWN` | `3600` | Service | Seconds a suggested friend stays out of the draw |
| `DURATION` | `20` | Controller | Seconds the notification stays up |
| `TITLE`, `TEXT`, `INVITE_BUTTON`, `DECLINE_BUTTON` | `"%s is online!"`, `"Invite them to play with you?"`, `Invite`, `Decline` | Controller | Notification text |
| `INVITE_MESSAGE` | `"Come play Periastron Tower Defense with me!"` | Controller | Message in Roblox's invite prompt |
| `LAUNCH_DATA` | `"FriendInvite"` | Service | The mark on our invites; the client gets it in the prompt payload |
| `STATS_LINES` | `20` | Service | Friends listed by `friendinvitestats` |

## Usage

`friendinvite [players] [ignoreCooldown]` (alias `invitefriend`) sends the suggestion now, outside the automatic schedule (which keeps running).
It is open to every tester in QA (see [Admin commands](../common/admin-commands.md)).
It goes through the same draw and writes the profile like the real thing, so running it again goes through the rest of the friend list; `ignoreCooldown` set to `true` puts friends suggested in the last hour back in.

`friendinvitestats [player]` (alias `invitestats`) prints a player's history: the totals (`Invite` clicks, accepted `System`, `Manual`, `Total`, friends in cooldown) and up to `STATS_LINES` friends in the order the draw prefers them.
The player must be on the server; for anyone else, use `viewdata`.
It is open to every tester in QA too.

To test an accepted invite you need two accounts in the QA experience: A runs `friendinvite`, clicks `Invite`, B accepts it, and `friendinvitestats` on A shows B under `System`.

## Design notes

- Roblox does not tell a game who a player talks to or plays with most, so the game learns it: an accepted invite says more than a click, so it ranks first, and each `Invite` click raises that friend after that.
- The cooldown starts when a friend is shown, whatever the answer, so the suggestions go through the whole friend list instead of repeating one friend.

## Known issues

- `Invited` counts the click, not a sent invite: Roblox does not tell the game whether the player sent it from the prompt. `Accepted` is the reliable number.
- Only joins that land in the Lobby are counted. An invite always starts there unless the friend follows the inviter into a server of another place, which Roblox does not allow for the reserved match servers.
- Roblox's invite prompt does not send real invites from Studio; test it in the QA server.
