--[[
	Every enemy in the game, one entity per model.

	The entity's name **is** the model's name: `KorbloxMage` spawns the
	`KorbloxMage` model, carries the `KorbloxMage` gimmicks, and is what the wave
	tables (`Config.Waves`, server-only) list. `Folder` says which folder of
	`Assets.Entities.Difficulties` holds the model; the folders are the casts
	(Redcliff, Astral, Sky, Korblox, Overseer), one per difficulty today, but any
	wave can use any entity.

	`Health` and `SpeedMultiplier` are the entity's **reference** stats, not what it
	spawns with: every wave entry writes its own health and speed. The server
	measures against them in two places: the damage reward divides by how far a
	spawned enemy's health is above its reference (so a point of damage pays the
	same on any wave), and an enemy born outside a wave, such as a Deathspeaker
	convert, scales from here. The client also reads the reference speed to pick the
	walk animation.

	Each cast is declared weakest to strongest, the order the `Workspace.Weakest` /
	`Workspace.Strongest` ruler lines the models up in. Slots that do the same job
	across casts share their reference stats and their gimmick; see
	docs/game/enemies.md.
]]

local Mob = {}

--[[
	Reference speed, in studs per second. An entity's reference speed is `BaseSpeed *
	SpeedMultiplier`; the speed it spawns with comes from its wave in `Config.Waves`.
]]
Mob.BaseSpeed = 4

--[[
	Gimmicks shared by several casts. They are only read at runtime (per-enemy state
	lives in the enemy's `GimmickState`), so one table can serve every entity that
	has the move.
]]

-- The charger: gains 30% speed on every turn of the path, up to five times.
local CHARGE = { Type = "PerTurnSpeedMultiplier", Amount = 0.3, MaxStacks = 5 }

-- The sprinter: starts fast and loses 15% speed on every turn, up to five times.
local TIRE = { Type = "PerTurnSpeedMultiplier", Amount = -0.15, MaxStacks = 5 }

--[[
	The Redcliff Champion's signature move: at half health it stops, strikes, and a
	random unit is stunned.

	The Sky Knight, the Korblox Death Raider, and the Overseer King have it too, but
	none of them has an `Attack` animation, so the 1.3 s pause plays without a
	gesture. Each should get its own move, as the Astral Sentinel did.
]]
local BOSS_STUN = {
	Type = "HealthThresholdStunRandomUnit",
	Threshold = 0.5,
	StunDuration = 15,
	AnimTime = 1.3,
	Once = true,
}

--[[
	The Astral Sentinel's dash: at half health it plays `Rush` and takes off.

	`MarkerTime` is where the `Action` marker falls in the animation: 0.5667 s of the
	3.25 s of `rbxassetid://98921075157550`, measured from the published asset. The
	server keeps time, not the real marker on the client: the buff is match state, so
	it must happen the same for everyone and cannot depend on a client reporting that
	the animation got there. The client plays the same animation at the same instant,
	so the dash lands on the right frame.

	**If `Rush` is re-exported, this number must be measured again**: it is the only
	place the code knows by heart something that lives in the asset.
]]
local SENTINEL_RUSH = {
	Type = "HealthThresholdRush",
	Threshold = 0.5,
	Animation = "Rush",
	MarkerTime = 0.5667,

	-- `RushScale = 1 + Amount`, so 1 is double speed.
	Amount = 1,

	Duration = 3,
	Once = true,
}

Mob.Entities = {
	-- Redcliff (`Hard`), used by Hard and the tutorial.
	Traveler = { Folder = "Hard", Health = 5, SpeedMultiplier = 1 },
	RedcliffPawn = { Folder = "Hard", Health = 10, SpeedMultiplier = 1 },
	RedcliffSquire = { Folder = "Hard", Health = 6, SpeedMultiplier = 1.5 },
	RedcliffGuard = { Folder = "Hard", Health = 20, SpeedMultiplier = 1 / 1.75 },
	WallSmasher = { Folder = "Hard", Health = 15, SpeedMultiplier = 1, Gimmicks = { CHARGE } },
	CourageBearer = { Folder = "Hard", Health = 15, SpeedMultiplier = 2.5, Gimmicks = { TIRE } },
	WingedRedcliff = { Folder = "Hard", Health = 40, SpeedMultiplier = 1.5 },
	RedcliffEnforcer = { Folder = "Hard", Health = 120, SpeedMultiplier = 1 / 1.75 },
	RedcliffChampion = { Folder = "Hard", Boss = true, Health = 900, SpeedMultiplier = 1 / 2, Gimmicks = { BOSS_STUN } },

	--[[
		Astral (`Easy`): eight models. `AstralAdventurer` fills both the winged slot
		and the elite slot of the other casts, so the Easy waves list it for both; the
		entries that stand in for the elite carry their own reward and spawn delay.
		It keeps the winged slot's reference stats.
	]]
	AstralInitiate = { Folder = "Easy", Health = 5, SpeedMultiplier = 1 },
	AstralWizard = { Folder = "Easy", Health = 10, SpeedMultiplier = 1 },
	AstralKnight = { Folder = "Easy", Health = 6, SpeedMultiplier = 1.5 },
	AstralGuardia = { Folder = "Easy", Health = 20, SpeedMultiplier = 1 / 1.75 },
	AstralNecromancer = { Folder = "Easy", Health = 15, SpeedMultiplier = 1, Gimmicks = { CHARGE } },
	AstralSentry = { Folder = "Easy", Health = 15, SpeedMultiplier = 2.5, Gimmicks = { TIRE } },
	AstralAdventurer = { Folder = "Easy", Health = 40, SpeedMultiplier = 1.5 },
	AstralSentinel = { Folder = "Easy", Boss = true, Health = 900, SpeedMultiplier = 1 / 2, Gimmicks = { SENTINEL_RUSH } },

	-- Sky (`Medium`): eight models; `SkyGuardian` doubles up like `AstralAdventurer`.
	SkyBirdWarrior = { Folder = "Medium", Health = 5, SpeedMultiplier = 1 },
	SkyLeader = { Folder = "Medium", Health = 10, SpeedMultiplier = 1 },
	SkyWindAxe = { Folder = "Medium", Health = 6, SpeedMultiplier = 1.5 },
	SkyStealther = { Folder = "Medium", Health = 20, SpeedMultiplier = 1 / 1.75 },
	SkyFlyingGoon = { Folder = "Medium", Health = 15, SpeedMultiplier = 1, Gimmicks = { CHARGE } },
	SkyMage = { Folder = "Medium", Health = 15, SpeedMultiplier = 2.5, Gimmicks = { TIRE } },
	SkyGuardian = { Folder = "Medium", Health = 40, SpeedMultiplier = 1.5 },
	SkyKnight = { Folder = "Medium", Boss = true, Health = 900, SpeedMultiplier = 1 / 2, Gimmicks = { BOSS_STUN } },

	-- Korblox (`Impossible`). The Deathspeaker's Suffocate is its own service; see
	-- `Config.SuffocateAbility`.
	KorbloxMage = { Folder = "Impossible", Health = 5, SpeedMultiplier = 1 },
	KorbloxSkeleton = { Folder = "Impossible", Health = 10, SpeedMultiplier = 1 },
	KorbloxGeneral = { Folder = "Impossible", Health = 6, SpeedMultiplier = 1.5 },
	KorbloxGremlin = { Folder = "Impossible", Health = 20, SpeedMultiplier = 1 / 1.75 },
	KorbloxImperium = { Folder = "Impossible", Health = 15, SpeedMultiplier = 1, Gimmicks = { CHARGE } },
	KorbloxSkeletonDefender = { Folder = "Impossible", Health = 15, SpeedMultiplier = 2.5, Gimmicks = { TIRE } },
	KorbloxElder = { Folder = "Impossible", Health = 40, SpeedMultiplier = 1.5 },
	KorbloxDeathspeaker = { Folder = "Impossible", Health = 120, SpeedMultiplier = 1 / 1.75 },
	KorbloxDeathRaider = { Folder = "Impossible", Boss = true, Health = 900, SpeedMultiplier = 1 / 2, Gimmicks = { BOSS_STUN } },

	-- Overseer (`Nightmare`).
	OverseerMinion = { Folder = "Nightmare", Health = 5, SpeedMultiplier = 1 },
	OverseerWanderer = { Folder = "Nightmare", Health = 10, SpeedMultiplier = 1 },
	OverseerOrb = { Folder = "Nightmare", Health = 6, SpeedMultiplier = 1.5 },
	OverseerGuard = { Folder = "Nightmare", Health = 20, SpeedMultiplier = 1 / 1.75 },
	OverseerCharger = { Folder = "Nightmare", Health = 15, SpeedMultiplier = 1, Gimmicks = { CHARGE } },
	OverseerWingwalker = { Folder = "Nightmare", Health = 15, SpeedMultiplier = 2.5, Gimmicks = { TIRE } },
	OverseerMage = { Folder = "Nightmare", Health = 40, SpeedMultiplier = 1.5 },
	OverseerKnight = { Folder = "Nightmare", Health = 120, SpeedMultiplier = 1 / 1.75 },
	OverseerKing = { Folder = "Nightmare", Boss = true, Health = 900, SpeedMultiplier = 1 / 2, Gimmicks = { BOSS_STUN } },
}

--- Whether the entity is a boss: its wave switches to the boss music, and killing it
--- counts for the "Defeat 70 bosses" contract.
function Mob.IsBoss(entityName : string?) : boolean
	local entity = entityName and Mob.Entities[entityName]
	return entity ~= nil and entity.Boss == true
end

--- The entity's gimmicks; an empty list if it has none.
function Mob.GetGimmicks(entityName : string)
	local entity = Mob.Entities[entityName]
	return (entity and entity.Gimmicks) or {}
end

return Mob
