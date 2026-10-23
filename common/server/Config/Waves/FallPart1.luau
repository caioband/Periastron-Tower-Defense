--[[
	Fall PART 1's waves. **Placeholder**: ten waves of the Astral cast on roughly
	Easy's curve, ending on the Astral Sentinel, so the mode runs start to finish
	while its real waves are written.

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
		{ Entity = "AstralInitiate", Amount = 5, Health = 3, Speed = 3.6 },
		{ Entity = "AstralWizard", Amount = 1, Health = 5, Speed = 3.6 },
		{ Entity = "AstralKnight", Amount = 3, Health = 3, Speed = 5.4 },
	},
	[3] = {
		{ Entity = "AstralInitiate", Amount = 5, Health = 3, Speed = 3.6 },
		{ Entity = "AstralWizard", Amount = 2, Health = 5, Speed = 3.6 },
		{ Entity = "AstralKnight", Amount = 4, Health = 3, Speed = 5.4 },
		{ Entity = "AstralGuardia", Amount = 1, Health = 10, Speed = 2.1 },
	},
	[4] = {
		{ Entity = "AstralWizard", Amount = 4, Health = 5, Speed = 3.6 },
		{ Entity = "AstralKnight", Amount = 4, Health = 3, Speed = 5.5 },
		{ Entity = "AstralGuardia", Amount = 3, Health = 10, Speed = 2.1 },
	},
	[5] = {
		{ Entity = "AstralWizard", Amount = 5, Health = 6, Speed = 3.7 },
		{ Entity = "AstralNecromancer", Amount = 2, Health = 15, Speed = 3.7 },
		{ Entity = "AstralGuardia", Amount = 3, Health = 12, Speed = 2.1 },
	},
	[6] = {
		{ Entity = "AstralKnight", Amount = 6, Health = 4, Speed = 5.5 },
		{ Entity = "AstralNecromancer", Amount = 3, Health = 16, Speed = 3.7 },
		{ Entity = "AstralSentry", Amount = 2, Health = 8, Speed = 9.2 },
	},
	[7] = {
		{ Entity = "AstralGuardia", Amount = 4, Health = 14, Speed = 2.1 },
		{ Entity = "AstralNecromancer", Amount = 3, Health = 17, Speed = 3.7 },
		{ Entity = "AstralSentry", Amount = 3, Health = 8, Speed = 9.3 },
		{ Entity = "AstralAdventurer", Amount = 1, Health = 20, Speed = 5.6 },
	},
	[8] = {
		{ Entity = "AstralKnight", Amount = 6, Health = 4, Speed = 5.6 },
		{ Entity = "AstralNecromancer", Amount = 4, Health = 18, Speed = 3.7 },
		{ Entity = "AstralSentry", Amount = 4, Health = 8, Speed = 9.3 },
		{ Entity = "AstralAdventurer", Amount = 2, Health = 22, Speed = 5.6 },
	},
	[9] = {
		{ Entity = "AstralNecromancer", Amount = 5, Health = 19, Speed = 3.8 },
		{ Entity = "AstralSentry", Amount = 5, Health = 9, Speed = 9.4 },
		{ Entity = "AstralAdventurer", Amount = 3, Health = 23, Speed = 5.7 },
	},
	[10] = {
		{ Entity = "AstralSentry", Amount = 8, Health = 5, Speed = 9.5 },
		{ Entity = "AstralAdventurer", Amount = 4, Health = 24, Speed = 5.7 },
		{ Entity = "AstralSentinel", Amount = 1, Health = 400, Speed = 1.9 },
	},
}
