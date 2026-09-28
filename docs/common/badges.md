# Badges

Roblox badges are awarded through a single service.

**Runs in:** Game · Lobby
**Code:** [`BadgeService`](../../common/server/Services/BadgeService.luau), [`WelcomeBadgeService`](../../Lobby/src/Services/WelcomeBadgeService.luau), [`Config.Badges`](../../common/server/Config/Badges.luau)

## How it works

Badge ids live in `common/server/Config/Badges.luau` (`Name = BadgeId`), and the only way to award one is `BadgeService:Award(player, "Name")`.

- It checks `UserHasBadgeAsync` before `AwardBadge`, to save quota on players who already have it, and caches the answer for the session.
- It retries each call up to 3 times (`MAX_ATTEMPTS`).
- It does nothing in Studio, where Roblox does not award badges.
- `Award` yields on the network; callers that should not wait use `task.spawn`.

| Name | When | Awarded by |
| --- | --- | --- |
| `Welcome` | First time in the game | `WelcomeBadgeService` (Lobby), on `PlayerAdded` |

"First time" is stored by the badge itself, not the profile, so changing `PROFILE_KEY` does not award it again.

## Adding a badge

1. Create the badge on the Creator Hub, in the same universe.
2. Add a line to `Config.Badges`.
3. Call `BadgeService:Award` where the achievement happens.
