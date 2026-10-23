--[[
	Enemies that summon other enemies on a timer (`EnemySummonService`).

	Every `Interval` seconds of match time (sped up with the match, frozen with it),
	the caster stops, plays the Deathspeaker's `Suffocate` animation with its cast
	effect, and at the end of the cast `Count` enemies drawn from `Pool` climb out
	right behind it on the path.

	The summons' health and speed are the current wave's numbers when the wave has
	that enemy, otherwise they scale from the caster (see `MobService:SpawnOnPath`).
	They pay `Reward` per kill: zero, so keeping a necromancer alive is never a
	way to farm cash.
]]
local EnemySummon = {}

EnemySummon.Enemies = { "SpookyNecromancer" }

-- The first cast also waits a full `Interval` after the caster spawns.
EnemySummon.Interval = 10

EnemySummon.CastTime = 2.85
EnemySummon.StopWhileCasting = true
EnemySummon.EnemyAnim = "Suffocate"

-- The Deathspeaker's cast effect, on the same arm. Set `CastVFX` to nil to cast
-- without it.
EnemySummon.CastVFX = "SuffocateCast"
EnemySummon.CastPart = "Right Arm"

EnemySummon.Count = 2

-- Studs between each summon, counted backwards from the caster.
EnemySummon.Spacing = 2

-- The Fall PART 1 cast without the bosses and the elite (`HoodedVigilante`).
EnemySummon.Pool = {
	"HallowSlasher",
	"ScareCrow",
	"HoodedStalker",
	"CryingGhoul",
	"HallowWraith",
	"HallowSpectre",
}

EnemySummon.Reward = 0

return EnemySummon
