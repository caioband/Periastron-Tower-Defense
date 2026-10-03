--[[
	The Roblox badges the game awards. `BadgeService` (common) reads this.

	A badge belongs to one universe, and `AwardBadge` fails for a badge of another
	one, so the ids are per environment (`Shared.Util.Environment`): Production and
	QA each have their own copy of every badge. `BadgeService` reads the table of
	the environment it runs in. A name missing from an environment is not awarded
	there.

	Each entry is `Name = BadgeId`. The name is what code passes to
	`BadgeService:Award(player, "Name")`, and the id is the number shown in
	create.roblox.com → Badges.

	For a new badge: create it on the site in each universe, add a line to each
	environment here, and call `Award` from where the achievement happens (every
	place sees this table).

	See docs/common/badges.md.
]]

return {
	Production = {
		-- First time in the game. Awarded by the Lobby's `WelcomeBadgeService` on join.
		Welcome = 4332443148752915,

		-- Endless waves cleared. Awarded by the Game's `WaveService`.
		Endless50 = 4228908685267059,
		Endless100 = 1605331559426040,
		Endless500 = 4006978802217848,
	},

	QA = {
		Endless50 = 2249316883951209,
		Endless100 = 3646245258483763,
		Endless500 = 3294432140963604,
	},
}
