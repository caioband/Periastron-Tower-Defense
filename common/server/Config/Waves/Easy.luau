--[[
	Easy's fifteen waves.

	The cast has no elite model, so `AstralAdventurer` also fills that role: the entries
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
		{ Entity = "AstralInitiate", Amount = 3, Health = 3, Speed = 3.6 },
		{ Entity = "AstralKnight", Amount = 1, Health = 3, Speed = 5.4 },
	},
	[2] = {
		{ Entity = "AstralInitiate", Amount = 5, Health = 3, Speed = 3.61 },
		{ Entity = "AstralWizard", Amount = 1, Health = 5, Speed = 3.61 },
		{ Entity = "AstralKnight", Amount = 3, Health = 3, Speed = 5.42 },
	},
	[3] = {
		{ Entity = "AstralInitiate", Amount = 5, Health = 3, Speed = 3.63 },
		{ Entity = "AstralWizard", Amount = 2, Health = 5, Speed = 3.63 },
		{ Entity = "AstralKnight", Amount = 4, Health = 3, Speed = 5.44 },
		{ Entity = "AstralGuardia", Amount = 1, Health = 10, Speed = 2.07 },
	},
	[4] = {
		{ Entity = "AstralInitiate", Amount = 3, Health = 3, Speed = 3.64 },
		{ Entity = "AstralWizard", Amount = 4, Health = 5, Speed = 3.64 },
		{ Entity = "AstralKnight", Amount = 4, Health = 3, Speed = 5.47 },
		{ Entity = "AstralGuardia", Amount = 3, Health = 10, Speed = 2.08 },
	},
	[5] = {
		{ Entity = "AstralInitiate", Amount = 4, Health = 3, Speed = 3.66 },
		{ Entity = "AstralWizard", Amount = 5, Health = 5, Speed = 3.66 },
		{ Entity = "AstralKnight", Amount = 4, Health = 3, Speed = 5.49 },
		{ Entity = "AstralGuardia", Amount = 4, Health = 11, Speed = 2.09 },
	},
	[6] = {
		{ Entity = "AstralInitiate", Amount = 5, Health = 3, Speed = 3.67 },
		{ Entity = "AstralWizard", Amount = 6, Health = 5, Speed = 3.67 },
		{ Entity = "AstralKnight", Amount = 5, Health = 3, Speed = 5.51 },
		{ Entity = "AstralGuardia", Amount = 5, Health = 11, Speed = 2.1 },
	},
	[7] = {
		{ Entity = "AstralInitiate", Amount = 4, Health = 3, Speed = 3.69 },
		{ Entity = "AstralWizard", Amount = 6, Health = 5, Speed = 3.69 },
		{ Entity = "AstralKnight", Amount = 6, Health = 3, Speed = 5.53 },
		{ Entity = "AstralGuardia", Amount = 5, Health = 11, Speed = 2.11 },
		{ Entity = "AstralNecromancer", Amount = 1, Health = 8, Speed = 3.69 },
		{ Entity = "AstralSentry", Amount = 1, Health = 8, Speed = 9.22 },
	},
	[8] = {
		{ Entity = "AstralInitiate", Amount = 3, Health = 3, Speed = 3.7 },
		{ Entity = "AstralWizard", Amount = 8, Health = 6, Speed = 3.7 },
		{ Entity = "AstralKnight", Amount = 6, Health = 3, Speed = 5.55 },
		{ Entity = "AstralGuardia", Amount = 6, Health = 11, Speed = 2.12 },
		{ Entity = "AstralNecromancer", Amount = 1, Health = 8, Speed = 3.7 },
		{ Entity = "AstralSentry", Amount = 2, Health = 8, Speed = 9.26 },
	},
	[9] = {
		{ Entity = "AstralInitiate", Amount = 2, Health = 3, Speed = 3.72 },
		{ Entity = "AstralWizard", Amount = 8, Health = 6, Speed = 3.72 },
		{ Entity = "AstralKnight", Amount = 7, Health = 3, Speed = 5.58 },
		{ Entity = "AstralGuardia", Amount = 7, Health = 11, Speed = 2.12 },
		{ Entity = "AstralNecromancer", Amount = 3, Health = 8, Speed = 3.72 },
		{ Entity = "AstralSentry", Amount = 2, Health = 8, Speed = 9.29 },
	},
	[10] = {
		{ Entity = "AstralInitiate", Amount = 1, Health = 3, Speed = 3.73 },
		{ Entity = "AstralWizard", Amount = 9, Health = 6, Speed = 3.73 },
		{ Entity = "AstralKnight", Amount = 8, Health = 3, Speed = 5.6 },
		{ Entity = "AstralGuardia", Amount = 9, Health = 11, Speed = 2.13 },
		{ Entity = "AstralNecromancer", Amount = 3, Health = 9, Speed = 3.73 },
		{ Entity = "AstralSentry", Amount = 3, Health = 9, Speed = 9.33 },
		{ Entity = "AstralAdventurer", Amount = 1, Health = 23, Speed = 5.6 },
	},
	[11] = {
		{ Entity = "AstralWizard", Amount = 11, Health = 6, Speed = 3.75 },
		{ Entity = "AstralKnight", Amount = 9, Health = 3, Speed = 5.62 },
		{ Entity = "AstralGuardia", Amount = 10, Health = 12, Speed = 2.14 },
		{ Entity = "AstralNecromancer", Amount = 4, Health = 9, Speed = 3.75 },
		{ Entity = "AstralSentry", Amount = 3, Health = 9, Speed = 9.37 },
		{ Entity = "AstralAdventurer", Amount = 2, Health = 23, Speed = 5.62 },
		{ Entity = "AstralAdventurer", Amount = 1, Health = 70, Speed = 2.14, Reward = 61, SpawnDelay = 0.5625 },
	},
	[12] = {
		{ Entity = "AstralWizard", Amount = 11, Health = 6, Speed = 3.76 },
		{ Entity = "AstralKnight", Amount = 10, Health = 4, Speed = 5.64 },
		{ Entity = "AstralGuardia", Amount = 10, Health = 12, Speed = 2.15 },
		{ Entity = "AstralNecromancer", Amount = 4, Health = 9, Speed = 3.76 },
		{ Entity = "AstralSentry", Amount = 4, Health = 9, Speed = 9.4 },
		{ Entity = "AstralAdventurer", Amount = 3, Health = 24, Speed = 5.64 },
		{ Entity = "AstralAdventurer", Amount = 1, Health = 71, Speed = 2.15, Reward = 61, SpawnDelay = 0.5625 },
	},
	[13] = {
		{ Entity = "AstralWizard", Amount = 12, Health = 6, Speed = 3.78 },
		{ Entity = "AstralKnight", Amount = 10, Health = 4, Speed = 5.66 },
		{ Entity = "AstralGuardia", Amount = 11, Health = 12, Speed = 2.16 },
		{ Entity = "AstralNecromancer", Amount = 4, Health = 9, Speed = 3.78 },
		{ Entity = "AstralSentry", Amount = 4, Health = 9, Speed = 9.44 },
		{ Entity = "AstralAdventurer", Amount = 2, Health = 24, Speed = 5.66 },
		{ Entity = "AstralAdventurer", Amount = 2, Health = 72, Speed = 2.16, Reward = 61, SpawnDelay = 0.5625 },
	},
	[14] = {
		{ Entity = "AstralWizard", Amount = 12, Health = 6, Speed = 3.79 },
		{ Entity = "AstralKnight", Amount = 11, Health = 4, Speed = 5.69 },
		{ Entity = "AstralGuardia", Amount = 11, Health = 12, Speed = 2.17 },
		{ Entity = "AstralNecromancer", Amount = 5, Health = 9, Speed = 3.79 },
		{ Entity = "AstralSentry", Amount = 4, Health = 9, Speed = 9.48 },
		{ Entity = "AstralAdventurer", Amount = 3, Health = 24, Speed = 5.69 },
		{ Entity = "AstralAdventurer", Amount = 2, Health = 73, Speed = 2.17, Reward = 61, SpawnDelay = 0.5625 },
	},
	[15] = {
		{ Entity = "AstralWizard", Amount = 6, Health = 6, Speed = 3.81 },
		{ Entity = "AstralKnight", Amount = 7, Health = 4, Speed = 5.71 },
		{ Entity = "AstralGuardia", Amount = 8, Health = 12, Speed = 2.18 },
		{ Entity = "AstralNecromancer", Amount = 1, Health = 9, Speed = 3.81 },
		{ Entity = "AstralSentry", Amount = 2, Health = 9, Speed = 9.52 },
		{ Entity = "AstralAdventurer", Amount = 4, Health = 25, Speed = 5.71 },
		{ Entity = "AstralAdventurer", Amount = 2, Health = 74, Speed = 2.18, Reward = 61, SpawnDelay = 0.5625 },
		{ Entity = "AstralSentinel", Amount = 1, Health = 554, Speed = 1.9 },
	},
}
