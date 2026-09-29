local SuffocateAbility = {}

SuffocateAbility.Enemies = {
	"KorbloxDeathspeaker",
}

SuffocateAbility.Threshold = 0.7
SuffocateAbility.CastTime = 1.75
SuffocateAbility.StopWhileCasting = true
SuffocateAbility.EnemyAnim = "Suffocate"

SuffocateAbility.UnitAnim = "Suffocated"
SuffocateAbility.UnitVFX = "BleedVFX"
SuffocateAbility.Duration = 1.5
SuffocateAbility.FadeTime = 0.6
SuffocateAbility.ExceptUnits = {}

SuffocateAbility.Spawn = {
	Entity = "KorbloxSkeleton",
	Reward = 0,
}

return SuffocateAbility