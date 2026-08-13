local Mob = {}

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
