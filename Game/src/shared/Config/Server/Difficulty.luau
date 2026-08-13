local Difficulty = {}

Difficulty.Default = "Medium"

Difficulty.Order = {
	"Easy",
	"Medium",
	"Hard",
	"Extreme",
	"Impossible",
}

Difficulty.Presets = {
	Easy = {
		HealthMultiplier = 0.75,
		HealthGrowth = 1.015,
		SpeedMultiplier = 0.9,
		AmountMultiplier = 0.85,
		AmountGrowth = 0.05,
		AmountGrowthCap = 2,
		BossAmountMultiplier = 1,
		RewardMultiplier = 1.35,
		WinCashMultiplier = 0.5,
		SpawnDelayMultiplier = 1.25,
		StartingCash = 750,
		BaseHealth = 200,
		MobDamage = 15,
		IntermissionTime = 60,
		WaveInterval = 5,
	},

	Medium = {
		HealthMultiplier = 1,
		HealthGrowth = 1.03,
		SpeedMultiplier = 1,
		AmountMultiplier = 1,
		AmountGrowth = 0.1,
		AmountGrowthCap = 4,
		BossAmountMultiplier = 1,
		RewardMultiplier = 1,
		WinCashMultiplier = 1,
		SpawnDelayMultiplier = 1,
		StartingCash = 500,
		BaseHealth = 100,
		MobDamage = 20,
		IntermissionTime = 60,
		WaveInterval = 3,
	},

	Hard = {
		HealthMultiplier = 1.45,
		HealthGrowth = 1.045,
		SpeedMultiplier = 1.1,
		AmountMultiplier = 1.25,
		AmountGrowth = 0.2,
		AmountGrowthCap = 6,
		BossAmountMultiplier = 1,
		RewardMultiplier = 0.85,
		WinCashMultiplier = 1.75,
		SpawnDelayMultiplier = 0.9,
		StartingCash = 400,
		BaseHealth = 75,
		MobDamage = 25,
		IntermissionTime = 45,
		WaveInterval = 3,
	},

	Extreme = {
		HealthMultiplier = 2.1,
		HealthGrowth = 1.06,
		SpeedMultiplier = 1.2,
		AmountMultiplier = 1.6,
		AmountGrowth = 0.35,
		AmountGrowthCap = 9,
		BossAmountMultiplier = 2,
		RewardMultiplier = 0.7,
		WinCashMultiplier = 2.75,
		SpawnDelayMultiplier = 0.8,
		StartingCash = 350,
		BaseHealth = 50,
		MobDamage = 25,
		IntermissionTime = 40,
		WaveInterval = 2,
	},

	Impossible = {
		HealthMultiplier = 3.25,
		HealthGrowth = 1.08,
		SpeedMultiplier = 1.35,
		AmountMultiplier = 2.2,
		AmountGrowth = 0.5,
		AmountGrowthCap = 12,
		BossAmountMultiplier = 3,
		RewardMultiplier = 0.55,
		WinCashMultiplier = 4,
		SpawnDelayMultiplier = 0.65,
		StartingCash = 300,
		BaseHealth = 25,
		MobDamage = 25,
		IntermissionTime = 30,
		WaveInterval = 1.5,
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
