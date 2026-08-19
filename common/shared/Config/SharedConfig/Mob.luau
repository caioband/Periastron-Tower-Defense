--[[
	A vida base de cada inimigo. O que chega no mob e a vida daqui multiplicada
	pela dificuldade e pela wave: `HealthMultiplier * HealthGrowth^(wave-1)`, ver
	`MobService:SpawnWave`.

	Estes numeros sao os da planilha do Dificil (`Config.Wave`): a coluna de vida
	total por wave dela foi calculada com eles, entao mexer aqui desloca a curva
	inteira. A variedade de vida entre os tipos e de proposito — o Squire e fragil
	e rapido, o Guard e gordo e lento — e a mistura de tipos por wave e o que faz a
	curva subir, nao o tamanho de um inimigo so.
]]

local Mob = {}

--[[
	Velocidade de referencia, em studs por segundo. A velocidade que o mob recebe e
	`BaseSpeed * SpeedMultiplier do inimigo * SpeedMultiplier do preset *
	SpeedGrowth^(wave-1)`, com teto no `SpeedGrowthCap` — ver `MobService:SpawnWave`
	e `Config.Difficulty`.
]]
Mob.BaseSpeed = 4

Mob.Entities = {
	Traveler = {
		Health = 5,
		SpeedMultiplier = 1,
	},

	RedcliffPawn = {
		Health = 10,
		SpeedMultiplier = 1,
	},

	RedcliffSquire = {
		Health = 6,
		SpeedMultiplier = 1.5,
	},

	RedcliffGuard = {
		Health = 20,
		SpeedMultiplier = 1 / 1.75,
	},

	WallSmasher = {
		Health = 15,
		SpeedMultiplier = 1,
		Gimmicks = {
			{ Type = "PerTurnSpeedMultiplier", Amount = 0.3, MaxStacks = 5 },
		},
	},

	CourageBearer = {
		Health = 15,
		SpeedMultiplier = 2.5,
		Gimmicks = {
			{ Type = "PerTurnSpeedMultiplier", Amount = -0.15, MaxStacks = 5 },
		},
	},

	WingedSquire = {
		Health = 40,
		SpeedMultiplier = 1.5,
	},

	RedcliffEnforcer = {
		Health = 120,
		SpeedMultiplier = 1 / 1.75,
	},

	RedcliffChampion = {
		Health = 900,
		SpeedMultiplier = 1 / 2,
		Gimmicks = {
			{
				Type = "HealthThresholdStunRandomUnit",
				Threshold = 0.5,
				StunDuration = 15,
				AnimTime = 1.3,
				Once = true,
			},
		},
	},
}

return Mob
