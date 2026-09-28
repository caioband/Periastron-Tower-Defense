--[[
	The Roblox badges the game awards. `BadgeService` (common) reads this.

	Each entry is `Name = BadgeId`. The name is what code passes to
	`BadgeService:Award(player, "Name")`, and the id is the number shown in
	create.roblox.com → Badges. The badge must belong to this universe, or
	`AwardBadge` fails.

	For a new badge: create it on the site, add a line here, and call `Award` from
	where the achievement happens (both places see this table).

	See docs/common/badges.md.
]]

return {
	-- First time in the game. Awarded by the Lobby's `WelcomeBadgeService` on join.
	Welcome = 4332443148752915,
}
