# Badges

Roblox badges are awarded through a single service.

**Runs in:** Game · Lobby
**Code:** [`BadgeService`](../../common/server/Services/BadgeService.luau), [`WelcomeBadgeService`](../../Lobby/src/Services/WelcomeBadgeService.luau), [`Config.Badges`](../../common/server/Config/Badges.luau)

## How it works

Badge ids live in `common/server/Config/Badges.luau`, one table per environment (`Production`, `QA`), each `Name = BadgeId`, and the only way to award one is `BadgeService:Award(player, "Name")`.
A badge belongs to one universe and `AwardBadge` fails for any other, so each environment has its own copy of every badge, and `BadgeService` reads the table of the environment it runs in (`Environment.Name`).
A name missing from an environment is not awarded there (a Studio warning says so).

- It checks `UserHasBadgeAsync` before `AwardBadge`, to save quota on players who already have it, and caches the answer for the session.
- It retries each call up to 3 times (`MAX_ATTEMPTS`).
- It does nothing in Studio, where Roblox does not award badges.
- `Award` yields on the network; callers that should not wait use `task.spawn`.

| Name | When | Awarded by |
| --- | --- | --- |
| `Welcome` | First time in the game | `WelcomeBadgeService` (Lobby), on `PlayerAdded` |
| `Endless50`, `Endless100`, `Endless500` | Clearing Endless wave 50, 100, or 500 | `WaveService` (Game) |

| Name | Production | QA |
| --- | --- | --- |
| `Welcome` | `4332443148752915` | none |
| `Endless50` | `4228908685267059` | `2249316883951209` |
| `Endless100` | `1605331559426040` | `3646245258483763` |
| `Endless500` | `4006978802217848` | `3294432140963604` |

"First time" is stored by the badge itself, not the profile, so changing `PROFILE_KEY` does not award it again.

## Adding a badge

1. Create the badge on the Creator Hub, in each universe (Production and QA).
2. Add a line to each environment's table in `Config.Badges`.
3. Call `BadgeService:Award` where the achievement happens.
