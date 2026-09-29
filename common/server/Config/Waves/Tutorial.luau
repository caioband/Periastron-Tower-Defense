--[[
	The tutorial's five waves: the first five rows of the Hard spreadsheet at half the
	count, with weak enemies. The match is one the player must win.

	Wave 3 has half the enemies of the curve because it is the player's first weather
	(`TutorialMatchService` turns it on), and wave 5 is the boss alone, with little
	health: the first time someone sees a boss should not be amid ten regular enemies.

	The boss is still itself (same slowness, same gimmick, same bar), it just is not a
	wall. Its 59 health is tuned for the script's finale, which exists so the player
	sees the three towers working together: at 49 it fell before that happened. The
	base takes no damage in the tutorial (`MobDamage = 0`), so more health never
	threatens the run.

	The format is in `Config.Waves` (the `init.luau` next to this file): the key is the
	wave number, and each wave is a list whose order is the spawn order. `Health` is
	the enemy's health and `Speed` is in studs per second, both final values before
	weather. The difficulty's wave count is how many waves this table has.
]]

return {
	[1] = {
		{ Entity = "Traveler", Amount = 2, Health = 2, Speed = 3.4 },
		{ Entity = "RedcliffSquire", Amount = 1, Health = 2, Speed = 5.1 },
	},
	[2] = {
		{ Entity = "Traveler", Amount = 3, Health = 2, Speed = 3.4 },
		{ Entity = "RedcliffSquire", Amount = 2, Health = 2, Speed = 5.1 },
	},
	[3] = {
		{ Entity = "Traveler", Amount = 2, Health = 2, Speed = 3.4 },
		{ Entity = "RedcliffPawn", Amount = 1, Health = 4, Speed = 3.4 },
		{ Entity = "RedcliffSquire", Amount = 1, Health = 2, Speed = 5.1 },
	},
	[4] = {
		{ Entity = "Traveler", Amount = 4, Health = 2, Speed = 3.4 },
		{ Entity = "RedcliffPawn", Amount = 2, Health = 4, Speed = 3.4 },
		{ Entity = "RedcliffSquire", Amount = 3, Health = 2, Speed = 5.1 },
	},
	[5] = {
		{ Entity = "RedcliffChampion", Amount = 1, Health = 59, Speed = 1.7 },
	},
}
