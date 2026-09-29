--[[
	Medium's twenty waves.

	The cast has no elite model, so `SkyGuardian` also fills that role: the entries
	with an explicit `Reward` and `SpawnDelay` are the elite's: its pay (45 per kill)
	and its slower spawn pace (0.45 s), already multiplied by this preset's
	`RewardMultiplier` and `SpawnDelayMultiplier`.

	The format is in `Config.Waves` (the `init.luau` next to this file): the key is the
	wave number, and each wave is a list whose order is the spawn order. `Health` is
	the enemy's health and `Speed` is in studs per second, both final values before
	weather. The difficulty's wave count is how many waves this table has.
]]

return {
	[1] = {
		{ Entity = "SkyBirdWarrior", Amount = 6, Health = 6, Speed = 4 },
		{ Entity = "SkyWindAxe", Amount = 3, Health = 7, Speed = 6 },
	},
	[2] = {
		{ Entity = "SkyBirdWarrior", Amount = 10, Health = 6, Speed = 4.02 },
		{ Entity = "SkyLeader", Amount = 1, Health = 12, Speed = 4.02 },
		{ Entity = "SkyWindAxe", Amount = 5, Health = 7, Speed = 6.04 },
	},
	[3] = {
		{ Entity = "SkyBirdWarrior", Amount = 12, Health = 6, Speed = 4.05 },
		{ Entity = "SkyLeader", Amount = 4, Health = 13, Speed = 4.05 },
		{ Entity = "SkyWindAxe", Amount = 8, Health = 8, Speed = 6.07 },
	},
	[4] = {
		{ Entity = "SkyBirdWarrior", Amount = 10, Health = 6, Speed = 4.07 },
		{ Entity = "SkyLeader", Amount = 6, Health = 13, Speed = 4.07 },
		{ Entity = "SkyWindAxe", Amount = 9, Health = 8, Speed = 6.11 },
		{ Entity = "SkyStealther", Amount = 2, Health = 26, Speed = 2.33 },
	},
	[5] = {
		{ Entity = "SkyBirdWarrior", Amount = 6, Health = 7, Speed = 4.1 },
		{ Entity = "SkyLeader", Amount = 8, Health = 13, Speed = 4.1 },
		{ Entity = "SkyWindAxe", Amount = 8, Health = 8, Speed = 6.15 },
		{ Entity = "SkyStealther", Amount = 6, Health = 26, Speed = 2.34 },
	},
	[6] = {
		{ Entity = "SkyBirdWarrior", Amount = 8, Health = 7, Speed = 4.12 },
		{ Entity = "SkyLeader", Amount = 9, Health = 13, Speed = 4.12 },
		{ Entity = "SkyWindAxe", Amount = 8, Health = 8, Speed = 6.18 },
		{ Entity = "SkyStealther", Amount = 8, Health = 27, Speed = 2.36 },
	},
	[7] = {
		{ Entity = "SkyBirdWarrior", Amount = 10, Health = 7, Speed = 4.15 },
		{ Entity = "SkyLeader", Amount = 11, Health = 14, Speed = 4.15 },
		{ Entity = "SkyWindAxe", Amount = 10, Health = 8, Speed = 6.22 },
		{ Entity = "SkyStealther", Amount = 10, Health = 27, Speed = 2.37 },
	},
	[8] = {
		{ Entity = "SkyBirdWarrior", Amount = 12, Health = 7, Speed = 4.17 },
		{ Entity = "SkyLeader", Amount = 13, Health = 14, Speed = 4.17 },
		{ Entity = "SkyWindAxe", Amount = 12, Health = 8, Speed = 6.26 },
		{ Entity = "SkyStealther", Amount = 12, Health = 28, Speed = 2.38 },
	},
	[9] = {
		{ Entity = "SkyBirdWarrior", Amount = 9, Health = 7, Speed = 4.2 },
		{ Entity = "SkyLeader", Amount = 14, Health = 14, Speed = 4.2 },
		{ Entity = "SkyWindAxe", Amount = 12, Health = 9, Speed = 6.29 },
		{ Entity = "SkyStealther", Amount = 11, Health = 29, Speed = 2.4 },
		{ Entity = "SkyFlyingGoon", Amount = 2, Health = 21, Speed = 4.2 },
		{ Entity = "SkyMage", Amount = 3, Health = 21, Speed = 10.49 },
	},
	[10] = {
		{ Entity = "SkyBirdWarrior", Amount = 7, Health = 7, Speed = 4.22 },
		{ Entity = "SkyLeader", Amount = 16, Health = 15, Speed = 4.22 },
		{ Entity = "SkyWindAxe", Amount = 14, Health = 9, Speed = 6.33 },
		{ Entity = "SkyStealther", Amount = 13, Health = 29, Speed = 2.41 },
		{ Entity = "SkyFlyingGoon", Amount = 3, Health = 22, Speed = 4.22 },
		{ Entity = "SkyMage", Amount = 4, Health = 22, Speed = 10.55 },
	},
	[11] = {
		{ Entity = "SkyBirdWarrior", Amount = 5, Health = 7, Speed = 4.25 },
		{ Entity = "SkyLeader", Amount = 17, Health = 15, Speed = 4.25 },
		{ Entity = "SkyWindAxe", Amount = 14, Health = 9, Speed = 6.37 },
		{ Entity = "SkyStealther", Amount = 14, Health = 30, Speed = 2.43 },
		{ Entity = "SkyFlyingGoon", Amount = 4, Health = 22, Speed = 4.25 },
		{ Entity = "SkyMage", Amount = 5, Health = 22, Speed = 10.62 },
	},
	[12] = {
		{ Entity = "SkyBirdWarrior", Amount = 3, Health = 8, Speed = 4.27 },
		{ Entity = "SkyLeader", Amount = 18, Health = 15, Speed = 4.27 },
		{ Entity = "SkyWindAxe", Amount = 16, Health = 9, Speed = 6.41 },
		{ Entity = "SkyStealther", Amount = 16, Health = 30, Speed = 2.44 },
		{ Entity = "SkyFlyingGoon", Amount = 6, Health = 23, Speed = 4.27 },
		{ Entity = "SkyMage", Amount = 5, Health = 23, Speed = 10.68 },
		{ Entity = "SkyGuardian", Amount = 1, Health = 61, Speed = 6.41 },
	},
	[13] = {
		{ Entity = "SkyBirdWarrior", Amount = 3, Health = 8, Speed = 4.3 },
		{ Entity = "SkyLeader", Amount = 20, Health = 16, Speed = 4.3 },
		{ Entity = "SkyWindAxe", Amount = 17, Health = 9, Speed = 6.45 },
		{ Entity = "SkyStealther", Amount = 18, Health = 31, Speed = 2.46 },
		{ Entity = "SkyFlyingGoon", Amount = 6, Health = 23, Speed = 4.3 },
		{ Entity = "SkyMage", Amount = 6, Health = 23, Speed = 10.74 },
		{ Entity = "SkyGuardian", Amount = 3, Health = 62, Speed = 6.45 },
	},
	[14] = {
		{ Entity = "SkyBirdWarrior", Amount = 1, Health = 8, Speed = 4.32 },
		{ Entity = "SkyLeader", Amount = 22, Health = 16, Speed = 4.32 },
		{ Entity = "SkyWindAxe", Amount = 19, Health = 10, Speed = 6.49 },
		{ Entity = "SkyStealther", Amount = 20, Health = 32, Speed = 2.47 },
		{ Entity = "SkyFlyingGoon", Amount = 8, Health = 24, Speed = 4.32 },
		{ Entity = "SkyMage", Amount = 6, Health = 24, Speed = 10.81 },
		{ Entity = "SkyGuardian", Amount = 4, Health = 64, Speed = 6.49 },
		{ Entity = "SkyGuardian", Amount = 1, Health = 191, Speed = 2.47, Reward = 50, SpawnDelay = 0.495 },
	},
	[15] = {
		{ Entity = "SkyLeader", Amount = 23, Health = 16, Speed = 4.35 },
		{ Entity = "SkyWindAxe", Amount = 20, Health = 10, Speed = 6.52 },
		{ Entity = "SkyStealther", Amount = 21, Health = 33, Speed = 2.49 },
		{ Entity = "SkyFlyingGoon", Amount = 9, Health = 24, Speed = 4.35 },
		{ Entity = "SkyMage", Amount = 7, Health = 24, Speed = 10.87 },
		{ Entity = "SkyGuardian", Amount = 5, Health = 65, Speed = 6.52 },
		{ Entity = "SkyGuardian", Amount = 2, Health = 195, Speed = 2.49, Reward = 50, SpawnDelay = 0.495 },
	},
	[16] = {
		{ Entity = "SkyLeader", Amount = 24, Health = 17, Speed = 4.38 },
		{ Entity = "SkyWindAxe", Amount = 21, Health = 10, Speed = 6.56 },
		{ Entity = "SkyStealther", Amount = 22, Health = 33, Speed = 2.5 },
		{ Entity = "SkyFlyingGoon", Amount = 9, Health = 25, Speed = 4.38 },
		{ Entity = "SkyMage", Amount = 8, Health = 25, Speed = 10.94 },
		{ Entity = "SkyGuardian", Amount = 6, Health = 67, Speed = 6.56 },
		{ Entity = "SkyGuardian", Amount = 3, Health = 200, Speed = 2.5, Reward = 50, SpawnDelay = 0.495 },
	},
	[17] = {
		{ Entity = "SkyLeader", Amount = 24, Health = 17, Speed = 4.4 },
		{ Entity = "SkyWindAxe", Amount = 21, Health = 10, Speed = 6.6 },
		{ Entity = "SkyStealther", Amount = 23, Health = 34, Speed = 2.52 },
		{ Entity = "SkyFlyingGoon", Amount = 8, Health = 25, Speed = 4.4 },
		{ Entity = "SkyMage", Amount = 7, Health = 25, Speed = 11 },
		{ Entity = "SkyGuardian", Amount = 5, Health = 68, Speed = 6.6 },
		{ Entity = "SkyGuardian", Amount = 3, Health = 204, Speed = 2.52, Reward = 50, SpawnDelay = 0.495 },
	},
	[18] = {
		{ Entity = "SkyLeader", Amount = 26, Health = 17, Speed = 4.43 },
		{ Entity = "SkyWindAxe", Amount = 23, Health = 10, Speed = 6.64 },
		{ Entity = "SkyStealther", Amount = 24, Health = 35, Speed = 2.53 },
		{ Entity = "SkyFlyingGoon", Amount = 10, Health = 26, Speed = 4.43 },
		{ Entity = "SkyMage", Amount = 8, Health = 26, Speed = 11.07 },
		{ Entity = "SkyGuardian", Amount = 6, Health = 69, Speed = 6.64 },
		{ Entity = "SkyGuardian", Amount = 5, Health = 208, Speed = 2.53, Reward = 50, SpawnDelay = 0.495 },
	},
	[19] = {
		{ Entity = "SkyLeader", Amount = 27, Health = 18, Speed = 4.45 },
		{ Entity = "SkyWindAxe", Amount = 24, Health = 11, Speed = 6.68 },
		{ Entity = "SkyStealther", Amount = 25, Health = 36, Speed = 2.55 },
		{ Entity = "SkyFlyingGoon", Amount = 11, Health = 27, Speed = 4.45 },
		{ Entity = "SkyMage", Amount = 10, Health = 27, Speed = 11.14 },
		{ Entity = "SkyGuardian", Amount = 7, Health = 71, Speed = 6.68 },
		{ Entity = "SkyGuardian", Amount = 5, Health = 213, Speed = 2.55, Reward = 50, SpawnDelay = 0.495 },
	},
	[20] = {
		{ Entity = "SkyLeader", Amount = 14, Health = 18, Speed = 4.48 },
		{ Entity = "SkyWindAxe", Amount = 15, Health = 11, Speed = 6.72 },
		{ Entity = "SkyStealther", Amount = 18, Health = 36, Speed = 2.56 },
		{ Entity = "SkyFlyingGoon", Amount = 3, Health = 27, Speed = 4.48 },
		{ Entity = "SkyMage", Amount = 5, Health = 27, Speed = 11.2 },
		{ Entity = "SkyGuardian", Amount = 8, Health = 73, Speed = 6.72 },
		{ Entity = "SkyGuardian", Amount = 5, Health = 218, Speed = 2.56, Reward = 50, SpawnDelay = 0.495 },
		{ Entity = "SkyKnight", Amount = 1, Health = 1633, Speed = 2.24 },
	},
}
