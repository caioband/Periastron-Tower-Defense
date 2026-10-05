--[[
	Hard's twenty-five waves, from the Hard V2 balance ("hardV2speedtest_2", kept
	outside the repo): its enemies, order, counts, and spawn timings, wave by wave.

	V2 does not set health or speed, so `Health` and `Speed` are still the previous
	table's (the "PTD - Hard Difficulty - Redcliff Knights" spreadsheet), per wave and
	per enemy. V2 only drops enemies from waves, never adds one a wave did not have,
	so every entry still has its own numbers.

	The timings are V2's `Time_Between` (`SpawnDelay`, seconds between two enemies of
	the group) and `Time_Until_Next_Group` (`GroupDelay`, the gap after the group's
	last enemy). The last group of a wave has no `GroupDelay`: nothing comes after it.
	One fix from the sheet: wave 5's Squire reads `025`, which Lua takes as 25 s; it
	is 0.25 here.

	The format is in `Config.Waves` (the `init.luau` next to this file): the key is the
	wave number, and each wave is a list whose order is the spawn order. `Health` is
	the enemy's health and `Speed` is in studs per second, both final values before
	weather. The difficulty's wave count is how many waves this table has.
]]

return {
	[1] = {
		{ Entity = "Traveler", Amount = 8, Health = 10, Speed = 4.4, SpawnDelay = 0.3, GroupDelay = 1 },
		{ Entity = "RedcliffSquire", Amount = 4, Health = 12, Speed = 6.6, SpawnDelay = 0.3 },
	},
	[2] = {
		{ Entity = "Traveler", Amount = 10, Health = 10, Speed = 4.44, SpawnDelay = 0.25, GroupDelay = 0.5 },
		{ Entity = "RedcliffSquire", Amount = 6, Health = 12, Speed = 6.65, SpawnDelay = 0.3 },
	},
	[3] = {
		{ Entity = "Traveler", Amount = 5, Health = 11, Speed = 4.47, SpawnDelay = 0.3, GroupDelay = 0.2 },
		{ Entity = "RedcliffPawn", Amount = 4, Health = 21, Speed = 4.47, SpawnDelay = 0.35, GroupDelay = 1 },
		{ Entity = "RedcliffSquire", Amount = 8, Health = 13, Speed = 6.71, SpawnDelay = 0.3 },
	},
	[4] = {
		{ Entity = "RedcliffPawn", Amount = 6, Health = 22, Speed = 4.51, SpawnDelay = 0.3, GroupDelay = 0.5 },
		{ Entity = "RedcliffSquire", Amount = 12, Health = 13, Speed = 6.76, SpawnDelay = 0.3 },
	},
	[5] = {
		{ Entity = "RedcliffPawn", Amount = 8, Health = 23, Speed = 4.54, SpawnDelay = 0.35, GroupDelay = 0.5 },
		{ Entity = "RedcliffSquire", Amount = 12, Health = 14, Speed = 6.81, SpawnDelay = 0.25, GroupDelay = 0.5 },
		{ Entity = "RedcliffGuard", Amount = 4, Health = 45, Speed = 2.6, SpawnDelay = 0.4 },
	},
	[6] = {
		{ Entity = "RedcliffPawn", Amount = 5, Health = 23, Speed = 4.58, SpawnDelay = 0.35, GroupDelay = 0.5 },
		{ Entity = "RedcliffSquire", Amount = 10, Health = 14, Speed = 6.87, SpawnDelay = 0.3, GroupDelay = 1 },
		{ Entity = "RedcliffGuard", Amount = 8, Health = 46, Speed = 2.62, SpawnDelay = 0.4 },
	},
	[7] = {
		{ Entity = "RedcliffSquire", Amount = 12, Health = 14, Speed = 6.92, SpawnDelay = 0.3, GroupDelay = 0.3 },
		{ Entity = "RedcliffGuard", Amount = 12, Health = 48, Speed = 2.64, SpawnDelay = 0.3 },
	},
	[8] = {
		{ Entity = "RedcliffSquire", Amount = 14, Health = 15, Speed = 6.98, SpawnDelay = 0.25, GroupDelay = 0.3 },
		{ Entity = "RedcliffGuard", Amount = 14, Health = 49, Speed = 2.66, SpawnDelay = 0.2 },
	},
	[9] = {
		{ Entity = "RedcliffPawn", Amount = 10, Health = 25, Speed = 4.69, SpawnDelay = 0.2, GroupDelay = 1 },
		{ Entity = "RedcliffSquire", Amount = 14, Health = 15, Speed = 7.03, SpawnDelay = 0.2, GroupDelay = 1 },
		{ Entity = "RedcliffGuard", Amount = 15, Health = 51, Speed = 2.68, SpawnDelay = 0.35 },
	},
	[10] = {
		{ Entity = "Traveler", Amount = 16, Health = 13, Speed = 4.73, SpawnDelay = 0.15, GroupDelay = 0.1 },
		{ Entity = "RedcliffSquire", Amount = 16, Health = 16, Speed = 7.09, SpawnDelay = 0.25, GroupDelay = 0.5 },
		{ Entity = "RedcliffGuard", Amount = 16, Health = 52, Speed = 2.7, SpawnDelay = 0.4 },
	},
	[11] = {
		{ Entity = "RedcliffGuard", Amount = 14, Health = 54, Speed = 2.72, SpawnDelay = 0.4, GroupDelay = 1 },
		{ Entity = "WallSmasher", Amount = 2, Health = 40, Speed = 4.76, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 4, Health = 40, Speed = 11.91, SpawnDelay = 0.32 },
	},
	[12] = {
		{ Entity = "RedcliffSquire", Amount = 10, Health = 17, Speed = 7.2, SpawnDelay = 0.1, GroupDelay = 1 },
		{ Entity = "RedcliffGuard", Amount = 12, Health = 55, Speed = 2.74, SpawnDelay = 0.3, GroupDelay = 1 },
		{ Entity = "WallSmasher", Amount = 4, Health = 42, Speed = 4.8, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 4, Health = 42, Speed = 12.01, SpawnDelay = 0.32 },
	},
	[13] = {
		{ Entity = "RedcliffSquire", Amount = 18, Health = 17, Speed = 7.26, SpawnDelay = 0.2, GroupDelay = 0.1 },
		{ Entity = "RedcliffGuard", Amount = 16, Health = 57, Speed = 2.77, SpawnDelay = 0.3, GroupDelay = 0.32 },
		{ Entity = "WallSmasher", Amount = 4, Health = 43, Speed = 4.84, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 6, Health = 43, Speed = 12.1, SpawnDelay = 0.32 },
	},
	[14] = {
		{ Entity = "RedcliffGuard", Amount = 12, Health = 59, Speed = 2.79, SpawnDelay = 0.15, GroupDelay = 1 },
		{ Entity = "WallSmasher", Amount = 6, Health = 44, Speed = 4.88, SpawnDelay = 0.3, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 6, Health = 44, Speed = 12.2, SpawnDelay = 0.32 },
	},
	[15] = {
		{ Entity = "RedcliffGuard", Amount = 22, Health = 61, Speed = 2.81, SpawnDelay = 0.1, GroupDelay = 0.5 },
		{ Entity = "WallSmasher", Amount = 8, Health = 45, Speed = 4.92, SpawnDelay = 0.3, GroupDelay = 0.5 },
		{ Entity = "CourageBearer", Amount = 6, Health = 45, Speed = 12.3, SpawnDelay = 0.3, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 2, Health = 121, Speed = 7.38, SpawnDelay = 0.32 },
	},
	[16] = {
		{ Entity = "WallSmasher", Amount = 10, Health = 47, Speed = 4.96, SpawnDelay = 0.25, GroupDelay = 0.3 },
		{ Entity = "CourageBearer", Amount = 8, Health = 47, Speed = 12.4, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 4, Health = 125, Speed = 7.44, SpawnDelay = 0.32 },
	},
	[17] = {
		{ Entity = "RedcliffGuard", Amount = 26, Health = 64, Speed = 2.86, SpawnDelay = 0.4, GroupDelay = 1 },
		{ Entity = "WallSmasher", Amount = 10, Health = 48, Speed = 5, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 8, Health = 48, Speed = 12.5, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 4, Health = 128, Speed = 7.5, SpawnDelay = 0.32 },
	},
	[18] = {
		{ Entity = "RedcliffGuard", Amount = 28, Health = 66, Speed = 2.88, SpawnDelay = 0.4, GroupDelay = 1 },
		{ Entity = "WallSmasher", Amount = 10, Health = 50, Speed = 5.04, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 8, Health = 50, Speed = 12.6, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 6, Health = 132, Speed = 7.56, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "RedcliffEnforcer", Amount = 2, Health = 397, Speed = 2.88, SpawnDelay = 0.45 },
	},
	[19] = {
		{ Entity = "WallSmasher", Amount = 12, Health = 51, Speed = 5.08, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 10, Health = 51, Speed = 12.7, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 6, Health = 136, Speed = 7.62, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "RedcliffEnforcer", Amount = 2, Health = 409, Speed = 2.9, SpawnDelay = 0.45 },
	},
	[20] = {
		{ Entity = "WallSmasher", Amount = 12, Health = 53, Speed = 5.12, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 10, Health = 53, Speed = 12.8, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 8, Health = 140, Speed = 7.68, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "RedcliffEnforcer", Amount = 4, Health = 421, Speed = 2.93, SpawnDelay = 0.45 },
	},
	[21] = {
		{ Entity = "WallSmasher", Amount = 10, Health = 54, Speed = 5.16, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 8, Health = 54, Speed = 12.9, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 6, Health = 144, Speed = 7.74, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "RedcliffEnforcer", Amount = 4, Health = 433, Speed = 2.95, SpawnDelay = 0.45 },
	},
	[22] = {
		{ Entity = "WallSmasher", Amount = 14, Health = 56, Speed = 5.2, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 12, Health = 56, Speed = 13, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 8, Health = 149, Speed = 7.8, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "RedcliffEnforcer", Amount = 6, Health = 446, Speed = 2.97, SpawnDelay = 0.45 },
	},
	[23] = {
		{ Entity = "WallSmasher", Amount = 12, Health = 57, Speed = 5.24, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 10, Health = 57, Speed = 13.11, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 8, Health = 153, Speed = 7.86, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "RedcliffEnforcer", Amount = 6, Health = 460, Speed = 3, SpawnDelay = 0.45 },
	},
	[24] = {
		{ Entity = "WallSmasher", Amount = 16, Health = 59, Speed = 5.28, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 14, Health = 59, Speed = 13.21, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 10, Health = 158, Speed = 7.93, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "RedcliffEnforcer", Amount = 6, Health = 474, Speed = 3.02, SpawnDelay = 0.45 },
	},
	[25] = {
		{ Entity = "RedcliffPawn", Amount = 18, Health = 41, Speed = 5.33, SpawnDelay = 0.1, GroupDelay = 1 },
		{ Entity = "RedcliffSquire", Amount = 20, Health = 24, Speed = 7.99, SpawnDelay = 0.1, GroupDelay = 1 },
		{ Entity = "RedcliffGuard", Amount = 24, Health = 81, Speed = 3.04, SpawnDelay = 0.1, GroupDelay = 1 },
		{ Entity = "WallSmasher", Amount = 4, Health = 61, Speed = 5.33, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "CourageBearer", Amount = 6, Health = 61, Speed = 13.32, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "WingedRedcliff", Amount = 10, Health = 163, Speed = 7.99, SpawnDelay = 0.32, GroupDelay = 1 },
		{ Entity = "RedcliffEnforcer", Amount = 6, Health = 488, Speed = 3.04, SpawnDelay = 0.45, GroupDelay = 1 },
		{ Entity = "RedcliffChampion", Amount = 2, Health = 3659, Speed = 2.66, SpawnDelay = 1 },
	},
}
