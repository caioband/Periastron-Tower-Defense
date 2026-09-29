local SuffocateAbility = {}

SuffocateAbility.Enemies = {
	"KorbloxDeathspeaker",
}

SuffocateAbility.Threshold = 0.7
SuffocateAbility.CastTime = 1.5
SuffocateAbility.StopWhileCasting = true
SuffocateAbility.EnemyAnim = "Suffocate"

SuffocateAbility.UnitAnim = "Suffocated"
SuffocateAbility.Duration = 4
SuffocateAbility.StunUnit = false
SuffocateAbility.ExceptUnits = {}

SuffocateAbility.Spawn = {
	Entity = "KorbloxSkeleton",
	Reward = 0,
}

return SuffocateAbility