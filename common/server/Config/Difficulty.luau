--[[
	The difficulty presets.

	The wave spreadsheet in `Config.Wave` handles composition (how many enemies and
	of which type), and each preset only scales its size: `HealthMultiplier`,
	`AmountMultiplier`, and `BossAmountMultiplier` fatten the wave without changing
	what is inside. Up to Medium the boss count stays at 1; from Hard up all three
	grow together, up to 6.75x health, 5.25x enemies, and 9x bosses at the top.

	Progression has two sources, and they add up. Besides wave size, `HealthGrowth`
	handles each enemy's health and compounds per wave: an enemy's health on wave N
	is `HealthMultiplier * HealthGrowth^(N-1)`. The harder the difficulty, the faster
	that interest runs: 1.5% per wave on Easy and 5% on Nightmare, which on each
	preset's last wave gives 1.2x on Easy and 5.2x on Nightmare.

	The exponent is per wave, so long presets accumulate more: that is deliberate,
	but it is also what blows up fast if someone raises these numbers. For
	reference: at 1.08 this field made the top preset's last wave have enemies 44x
	beefier than the first wave's.

	Speed follows the same idea with much smaller numbers: `SpeedMultiplier` is the
	preset's floor, `SpeedGrowth` is how much it rises per wave, and
	`SpeedGrowthCap` is the ceiling that accumulation can reach. The cap exists
	because speed breaks faster than health: an enemy that is too fast crosses a
	tower's range between one shot and the next, and some enemies also multiply
	their own speed (the Wall Smasher gains 30% per turn, up to five times).

	`BaseHealth` divided by `MobDamage` is how many leaks the player can take: 12 on
	Easy, 7 on Medium, 5 on Hard, 4 on Impossible, and 3 on Nightmare.

	`WinCash` and `WinShards` are the reward for **a complete run**, already in
	currency and not a multiplier: what Nightmare pays reads straight off the table,
	with no need to multiply by a base in another file. A player who leaves early
	gets a proportional share (see `WaveService.computeReward`): coins are linear in
	the fraction of waves, and shards only start after half the run and then follow a
	curve, so the expensive currency goes to those who get close to the end. XP is
	the only one still computed as base times multiplier (`Data.BASE_WINNING_XP`
	times `WinXpMultiplier`).

		| Difficulty  | Coins | Shards |
		| Easy        |   100 |      1 |
		| Medium      |   225 |      2 |
		| Hard        |   450 |      3 |
		| Impossible  |   685 |      4 |
		| Nightmare   |   900 |      5 |

	`WeatherChance` is the chance, per wave, of a weather warning; the weather itself
	arrives three waves later (see `WeatherConfig.Round`). The die is only rolled when
	no weather is scheduled or active, so the number is not "how many waves have
	weather": it is how quickly the next one shows up after the previous one ends.
	With today's values, Easy gets one every ~10 free waves and Nightmare every
	~2.5, which, together with the higher presets being longer, is what makes
	difficulty also change how unpredictable the map is.

	See docs/game/difficulty-vote.md.
]]

local Difficulty = {}

Difficulty.Default = "Medium"

Difficulty.Order = {
	"Easy",
	"Medium",
	"Hard",
	"Impossible",
	"Nightmare",
}

Difficulty.Presets = {
	--[[
		The tutorial.

		**Left out of `Order` on purpose**: it is not a difficulty that gets voted on,
		it is the one the tutorial match imposes. `Difficulty.Get` finds any preset in
		the table, so being off the voting list does not make it unreachable.

		The numbers are for a match the player **must** win: enemies with a third of
		the health, half the count, a base with 500 health, and enemy damage at 5.
		Losing here would take effort. `StartingCash` covers the whole tutorial deck
		(Slingshot 175 + Archer 150 x2 = 475) with room to spare, because the player
		places one unit on wave 1 and the other two on wave 5, and running out of
		money mid-script is the only way they could get stuck.

		`WeatherChance = 0` because the tutorial's weather is scripted:
		`TutorialMatchService` turns it on at wave 3, not the roll.

		`WinCash`/`WinShards` are the complete-run reward, and `computeReward` arrives
		at them in full when the 5 waves are won: 50 coins and 1 shard, as requested.
	]]
	Tutorial = {
		--[[
			The five waves are the **first** five table rows, not the whole table
			squeezed into five; see `TableRows` in `Config.Wave`. Without this, the
			tutorial's wave 2 came with twelve enemies, including Guard and Pawn.
		]]
		TableRows = 5,

		--[[
			Wave 5 is only the boss, and a weak boss.

			`BossWaveOnly` removes the escort (see `Config.Wave.GetSpawns`): the first
			time someone sees a boss should not be amid ten regular enemies.

			`BossHealthMultiplier` applies on top of `HealthMultiplier`, and the number
			is small on purpose: the Champion's 900 health × the difficulty's 0.35 ×
			this 0.18 gives about 57, which three towers take down. The boss is still
			itself (same slowness, same gimmick, same bar), it just is not a wall.

			0.18 rather than 0.15: at 0.15 the boss fell too quickly for the script's
			finale, which exists precisely so the player sees the three towers working
			together. The extra 20% fattens the fight without coming close to
			threatening the base, which in the tutorial takes no damage at all
			(`MobDamage = 0`).
		]]
		BossWaveOnly = true,
		BossHealthMultiplier = 0.18,

		--[[
			Wave 3 is the weather wave: it arrives with the sky turned and the player
			learning to use the card that clears it. Half the enemies, because that is
			already two lessons.
		]]
		WaveAmountScale = { [3] = 0.5 },

		WeatherChance = 0,
		HealthMultiplier = 0.35,
		HealthGrowth = 1.01,
		SpeedMultiplier = 0.85,
		SpeedGrowth = 1,
		SpeedGrowthCap = 1,
		AmountMultiplier = 0.5,
		BossAmountMultiplier = 1,
		RewardMultiplier = 1.5,
		WinCash = 50,
		WinShards = 1,
		WinXpMultiplier = 0.5,
		SpawnDelayMultiplier = 1.4,
		StartingCash = 500,
		BaseHealth = 500,

		--[[
			The tutorial base does not die.

			Zero damage per escaped enemy is the way to say "infinite health" that
			keeps the bar **full** on screen, instead of an absurd number written on
			it: someone learning to place their first tower should not discover losing
			before discovering playing.

			It is zero, not a giant `BaseHealth`, because the math is the usual one
			(`MobService:mobEscaped`) and still applies: no new path, no exception
			scattered through the code. The `or` that reads this field treats zero as a
			value, not as absence, so it arrives intact.
		]]
		MobDamage = 0,

		IntermissionTime = 45,
		WaveInterval = 1.5,
		MaxWaves = 5,
	},

	Easy = {
		--[[
			The Astral cast instead of Redcliff (see `SharedConfig.Mob.ModelSets`).

			It is only the models: the wave, health, and gimmicks are the same any
			other preset reads from the same entity table. Presets without this key use
			`Hard`, the fallback.
		]]
		ModelSet = "Easy",

		WeatherChance = 0.10,
		HealthMultiplier = 0.5,
		HealthGrowth = 1.015,
		SpeedMultiplier = 0.9,
		SpeedGrowth = 1.004,
		SpeedGrowthCap = 1.15,
		AmountMultiplier = 0.7,
		BossAmountMultiplier = 1,
		RewardMultiplier = 1.35,
		WinCash = 100,
		WinShards = 1,
		WinXpMultiplier = 0.75,
		SpawnDelayMultiplier = 1.25,
		StartingCash = 750,
		BaseHealth = 180,
		MobDamage = 15,
		IntermissionTime = 60,
		WaveInterval = 1.25,
		MaxWaves = 15,
	},

	Medium = {
		--[[
			The Sky cast (see `SharedConfig.Mob.ModelSets`). As with Nightmare, leaving
			the `Hard` fallback means gimmicks scoped there do not reach this
			difficulty, which is why the boss stun lists all three sets.
		]]
		ModelSet = "Medium",

		WeatherChance = 0.15,
		HealthMultiplier = 1.2,
		HealthGrowth = 1.022,
		SpeedMultiplier = 1,
		SpeedGrowth = 1.006,
		SpeedGrowthCap = 1.25,
		AmountMultiplier = 1.5,
		BossAmountMultiplier = 1,
		RewardMultiplier = 1.1,
		WinCash = 225,
		WinShards = 2,
		WinXpMultiplier = 1,
		SpawnDelayMultiplier = 1.1,
		StartingCash = 500,
		BaseHealth = 140,
		MobDamage = 20,
		IntermissionTime = 60,
		WaveInterval = 1.25,
		MaxWaves = 20,
	},

	Hard = {
		WeatherChance = 0.22,
		HealthMultiplier = 2,
		HealthGrowth = 1.03,
		SpeedMultiplier = 1.1,
		SpeedGrowth = 1.008,
		SpeedGrowthCap = 1.35,
		AmountMultiplier = 2,
		BossAmountMultiplier = 2,
		RewardMultiplier = 1,
		WinCash = 450,
		WinShards = 3,
		WinXpMultiplier = 1.4,
		SpawnDelayMultiplier = 1,
		StartingCash = 400,
		BaseHealth = 125,
		MobDamage = 25,
		IntermissionTime = 45,
		WaveInterval = 1.25,
		MaxWaves = 25,
	},

	Impossible = {
		-- The Korblox cast (see `SharedConfig.Mob.ModelSets`).
		ModelSet = "Impossible",

		WeatherChance = 0.30,
		HealthMultiplier = 3.625,
		HealthGrowth = 1.04,
		SpeedMultiplier = 1.2,
		SpeedGrowth = 1.01,
		SpeedGrowthCap = 1.5,
		AmountMultiplier = 3.25,
		BossAmountMultiplier = 5,
		RewardMultiplier = 0.85,
		WinCash = 685,
		WinShards = 4,
		WinXpMultiplier = 1.8,
		SpawnDelayMultiplier = 0.9,
		StartingCash = 350,
		BaseHealth = 100,
		MobDamage = 25,
		IntermissionTime = 40,
		WaveInterval = 1.25,
		MaxWaves = 30,
	},

	Nightmare = {
		--[[
			The Overseer cast (see `SharedConfig.Mob.ModelSets`).

			Since `Hard` is not the fallback here, no gimmick scoped to it reaches
			this difficulty, which is why the boss stun lists both sets.
		]]
		ModelSet = "Nightmare",

		WeatherChance = 0.40,
		HealthMultiplier = 6.75,
		HealthGrowth = 1.05,
		SpeedMultiplier = 1.35,
		SpeedGrowth = 1.012,
		SpeedGrowthCap = 1.7,
		AmountMultiplier = 5.25,
		BossAmountMultiplier = 9,
		RewardMultiplier = 0.7,
		WinCash = 900,
		WinShards = 5,
		WinXpMultiplier = 2.5,
		SpawnDelayMultiplier = 0.8,
		StartingCash = 300,
		BaseHealth = 75,
		MobDamage = 25,
		IntermissionTime = 30,
		WaveInterval = 1.25,
		MaxWaves = 35,
	},
}

for name, preset in Difficulty.Presets do
	preset.Name = name
end

function Difficulty.Exists(name : string?)
	return typeof(name) == "string" and Difficulty.Presets[name] ~= nil
end

function Difficulty.Get(name : string?)
	if Difficulty.Exists(name) then
		return Difficulty.Presets[name]
	end

	return Difficulty.Presets[Difficulty.Default]
end

return Difficulty
