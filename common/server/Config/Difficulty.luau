--[[
	The difficulty presets.

	What each wave spawns (which enemies, how many, with what health and speed) is
	not here: it is written wave by wave in `Config.Waves`, one module per preset,
	and the number of waves in that module is the preset's `MaxWaves`. A preset
	without a module stops the server at boot. The enemies' look comes with them:
	each entity is its own model (see `SharedConfig.Mob`), so a preset has no cast
	of its own to declare.

	What stays here is the rest of the match: the base, the economy, the rewards, the
	weather, and the pacing between waves. `RewardMultiplier` and
	`SpawnDelayMultiplier` still scale each entity's cash per kill and spawn interval
	(see `Config.Wave`), unless a wave entry sets its own.

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

local Waves = require(script.Parent.Waves)

local Difficulty = {}

Difficulty.Default = "Medium"

Difficulty.Order = {
	"Easy",
	"Medium",
	"Hard",
	"Impossible",
	"Nightmare",
	"Endless",
}

Difficulty.Presets = {
	--[[
		The tutorial.

		**Left out of `Order` on purpose**: it is not a difficulty that gets voted on,
		it is the one the tutorial match imposes. `Difficulty.Get` finds any preset in
		the table, so being off the voting list does not make it unreachable.

		The numbers are for a match the player **must** win: few, weak enemies (see
		`Config.Waves.Tutorial`) and a base that takes no damage. Losing here would
		take effort. `StartingCash` covers the whole tutorial deck
		(Slingshot 175 + Archer 150 x2 = 475) with room to spare, because the player
		places one unit on wave 1 and the other two on wave 5, and running out of
		money mid-script is the only way they could get stuck.

		`WeatherChance = 0` because the tutorial's weather is scripted:
		`TutorialMatchService` turns it on at wave 3, not the roll.

		`WinCash`/`WinShards` are the complete-run reward, and `computeReward` arrives
		at them in full when the 5 waves are won: 50 coins and 1 shard, as requested.
	]]
	Tutorial = {
		WeatherChance = 0,
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
	},

	Easy = {
		WeatherChance = 0.10,
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
	},

	Medium = {
		WeatherChance = 0.15,
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
	},

	Hard = {
		WeatherChance = 0.22,
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
	},

	Impossible = {
		WeatherChance = 0.30,
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
	},

	Nightmare = {
		WeatherChance = 0.40,
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
	},

	Endless = {
		Endless = true,
		RewardWaves = 50,
		RewardCurve = {
			EarlyUntil = 30,   -- waves 1-30 pay EarlyWeight per wave
			EarlyWeight = 0.5, -- half the old per-wave rate
			RampUntil = 35,    -- waves 31-35 ramp from EarlyWeight up to 1.0
			LateGrowth = 0.04, -- each wave past 35 adds +0.04 to that wave's weight, uncapped
		},
		WeatherChance = 0.30,
		RewardMultiplier = 0.85,
		WinCash = 900,
		WinShards = 5,
		WinXpMultiplier = 2.5,
		SpawnDelayMultiplier = 0.9,
		StartingCash = 400,
		BaseHealth = 100,
		MobDamage = 25,
		IntermissionTime = 40,
		WaveInterval = 1.25,
	},


}

for name, preset in Difficulty.Presets do
	preset.Name = name

	if preset.Endless then
		preset.MaxWaves = math.huge
		continue
	end

	-- The match is as long as its wave table; see `Config.Waves`.
	preset.MaxWaves = Waves.Count(name)
	if preset.MaxWaves == 0 then
		error(`Config.Difficulty: preset "{name}" has no wave table in Config.Waves`, 0)
	end
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
