local SuffocateAbility = {}

SuffocateAbility.Enemies = {
	"KorbloxDeathspeaker",
}

SuffocateAbility.Threshold = 0.7
SuffocateAbility.CastTime = 2.85
SuffocateAbility.StopWhileCasting = true
SuffocateAbility.EnemyAnim = "Suffocate"

SuffocateAbility.CastVFX = "SuffocateCast"
SuffocateAbility.CastPart = "Right Arm"

SuffocateAbility.CastVFXTime = 2.85

SuffocateAbility.UnitAnim = "Suffocated"
SuffocateAbility.UnitVFX = "VictimVFX"
SuffocateAbility.Duration = 10
SuffocateAbility.FadeTime = 0.6
SuffocateAbility.ExceptUnits = {}

SuffocateAbility.Spawn = {
	Entity = "KorbloxSkeleton",
	Reward = 0,
}

return SuffocateAbility