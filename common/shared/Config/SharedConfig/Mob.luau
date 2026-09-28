--[[
	Each enemy's base health. What reaches the enemy is this health multiplied by
	difficulty and wave: `HealthMultiplier * HealthGrowth^(wave-1)`; see
	`MobService:SpawnWave`.

	These numbers match the Hard spreadsheet (`Config.Wave`): its total health per
	wave column was computed with them, so changing them shifts the whole curve.
	The health spread between types is on purpose (the Squire is fragile and fast,
	the Guard is fat and slow), and the mix of types per wave is what makes the
	curve rise, not the size of a single enemy.

	See docs/game/enemies.md.
]]

local Mob = {}

--[[
	Reference speed, in studs per second. An enemy's speed is `BaseSpeed * enemy
	SpeedMultiplier * preset SpeedMultiplier * SpeedGrowth^(wave-1)`, capped at
	`SpeedGrowthCap`; see `MobService:SpawnWave` and `Config.Difficulty`.
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
			--[[
				The Redcliff Champion's signature move: at half health it stops, strikes,
				and a random unit is stunned.

				The scope exists because the Astral boss has its own
				(`HealthThresholdRush`, below), and both fired at the same 50%: the
				Sentinel played `Attack` and `Rush` together and stood still for 1.3 s
				right as the dash started. **One boss, one move.**

				`ExceptModelSet`, not a list of who has it: this is the boss's **default**
				move, and Easy is the only set that swapped it for its own. Written the
				positive way, each new folder left its boss mute until someone added the
				name, which happened three times before the key changed.

				Bosses that inherit it today (Sky Knight, Korblox Death Raider, Overseer
				King) have no `Attack` animation, so the 1.3 s pause plays without a
				gesture. Each leaves the inheritance when it gets its own move, the path
				the Astral Sentinel already took.
			]]
			{
				Type = "HealthThresholdStunRandomUnit",
				ExceptModelSet = "Easy",
				Threshold = 0.5,
				StunDuration = 15,
				AnimTime = 1.3,
				Once = true,
			},

			--[[
				The Astral Sentinel's dash: at half health it plays `Rush` and takes off.

				`MarkerTime` is where the `Action` marker falls in the animation: 0.5667 s
				of the 3.25 s of `rbxassetid://98921075157550`, measured from the
				published asset. The server keeps time, not the real marker on the client:
				the buff is match state, so it must happen the same for everyone and cannot
				depend on a client reporting that the animation got there. The client plays
				the same animation at the same instant, so the dash lands on the right frame.

				**If `Rush` is re-exported, this number must be measured again**: it is the
				only place the code knows by heart something that lives in the asset.
			]]
			{
				Type = "HealthThresholdRush",
				ModelSet = "Easy",
				Threshold = 0.5,
				Animation = "Rush",
				MarkerTime = 0.5667,

				-- `RushScale = 1 + Amount`, so 1 is double speed.
				Amount = 1,

				Duration = 3,
				Once = true,
			},
		},
	},
}

--[[
	Which model each enemy wears, per difficulty.

	Models live in `Assets.Entities.Difficulties.<set>`, and each set is a **reskin
	per slot**: the entity list above is still the truth (same health, speed, and
	gimmicks), and the set only says which model to draw in each one's place.
	Changing difficulty does not change the match, it changes the cast.

	Keys are entity names and values are model names. Anything not in the table uses
	the entity's own name, which is the case for most of `Hard`.

	`Hard` is the fallback: a difficulty without `ModelSet` (or with one not in the
	folder) falls into it, so it is the only set that **must** have all nine.
]]
Mob.DefaultModelSet = "Hard"

Mob.ModelSets = {
	-- Identity, except the winged one: the entity has been `WingedSquire` since the
	-- spreadsheet and the model is `WingedRedcliff`. While both names exist, this
	-- line links them; without it `FindFirstChild` fails and the enemy spawns
	-- wearing another model.
	Hard = {
		WingedSquire = "WingedRedcliff",
	},

	--[[
		The Astral cast, eight models for nine slots.

		The order follows the ruler `Weakest`/`Strongest` draws in the Workspace:
		models are lined up from weakest to strongest, and the line matches
		`Config.Wave`'s `SPAWN_ORDER` step by step.

		One slot is left over, and `AstralAdventurer` repeats, on the Enforcer. The
		reasoning is about reading the screen: the Enforcer and the Champion appear
		together in the last wave, so giving the boss's model to the Enforcer would
		take away the boss's one moment to be unmistakable. Repeating the lower step
		costs two similar elites; repeating the top would cost the boss.
	]]
	--[[
		The Sky cast, eight models for nine slots.

		Same ruler and reasoning as Easy: the lower step repeats (`SkyGuardian`, on
		the Enforcer), so the boss stays the only one with its look in the wave where
		both appear.
	]]
	Medium = {
		Traveler = "SkyBirdWarrior",
		RedcliffPawn = "SkyLeader",
		RedcliffSquire = "SkyWindAxe",
		RedcliffGuard = "SkyStealther",
		WallSmasher = "SkyFlyingGoon",
		CourageBearer = "SkyMage",
		WingedSquire = "SkyGuardian",
		RedcliffEnforcer = "SkyGuardian",
		RedcliffChampion = "SkyKnight",
	},

	--[[
		The Korblox cast, nine models for nine slots; none repeats.
	]]
	Impossible = {
		Traveler = "KorbloxMage",
		RedcliffPawn = "KorbloxSkeleton",
		RedcliffSquire = "KorbloxGeneral",
		RedcliffGuard = "KorbloxGremlin",
		WallSmasher = "KorbloxImperium",
		CourageBearer = "KorbloxSkeletonDefender",
		WingedSquire = "KorbloxElder",
		RedcliffEnforcer = "KorbloxDeathspeaker",
		RedcliffChampion = "KorbloxDeathRaider",
	},

	--[[
		The Overseer cast, nine models for nine slots; none repeats.

		Same ruler as Easy: models are lined up between the Workspace's `Weakest` and
		`Strongest`, and the line matches `Config.Wave`'s `SPAWN_ORDER` step by step.
	]]
	Nightmare = {
		Traveler = "OverseerMinion",
		RedcliffPawn = "OverseerWanderer",
		RedcliffSquire = "OverseerOrb",
		RedcliffGuard = "OverseerGuard",
		WallSmasher = "OverseerCharger",
		CourageBearer = "OverseerWingwalker",
		WingedSquire = "OverseerMage",
		RedcliffEnforcer = "OverseerKnight",
		RedcliffChampion = "OverseerKing",
	},

	Easy = {
		Traveler = "AstralInitiate",
		RedcliffPawn = "AstralWizard",
		RedcliffSquire = "AstralKnight",
		RedcliffGuard = "AstralGuardia",
		WallSmasher = "AstralNecromancer",
		CourageBearer = "AstralSentry",
		WingedSquire = "AstralAdventurer",
		RedcliffEnforcer = "AstralAdventurer",
		RedcliffChampion = "AstralSentinel",
	},
}

--[=[
	The gimmicks of `entityName` that apply in set `setName`.

	A gimmick without `ModelSet` applies everywhere; with `ModelSet`, it only fires
	in the set that names it. That is what lets **each enemy of each cast have its
	own move**: the Astral Sentinel dashes, the Redcliff Champion stuns a tower, and
	neither does the other's.

	There are two keys, and choosing between them matters:

	  - `ModelSet` -- **only** in the named sets. For a move that belongs to that cast.
	  - `ExceptModelSet` -- in every set **except** the named ones. For the entity's
	    default move that some cast replaced with its own.

	Both accept a name or a list.

	The second exists because the first has a silent trap: the filter is by **model
	set**, not difficulty, so a difficulty that gets its own folder leaves the `Hard`
	fallback and at once loses everything scoped there. It happened three times in a
	row (Nightmare, Medium, and Impossible), and the symptom is silent: no error, the
	move just stops.

	Written the negative way, the default becomes **inheriting**: a new cast is born
	with the entity's move and only loses it when someone says it has its own.

	For an enemy to **swap** moves between casts, both sides must be scoped: a new
	`Easy` gimmick coexists with an unscoped one instead of replacing it. That is what
	the boss's two moves do below.

	This **loosens** the rule that changing difficulty only changes the cast, so the
	exception is declared in a visible key instead of an `if` in some handler.
	Whoever reads the entity sees which gimmicks do not apply everywhere.
]=]
function Mob.GetGimmicks(setName : string?, entityName : string)
	local entity = Mob.Entities[entityName]
	if not entity or not entity.Gimmicks then return {} end

	local set = setName or Mob.DefaultModelSet
	local allowed = {}

	--- Whether `scope` (a name, a list, or nil) names this match's set.
	local function names(scope) : boolean
		if scope == nil then return false end
		if type(scope) == "table" then return table.find(scope, set) ~= nil end
		return scope == set
	end

	for _, gimmick in entity.Gimmicks do
		local only = gimmick.ModelSet
		local applies = (only == nil or names(only)) and not names(gimmick.ExceptModelSet)

		if applies then
			table.insert(allowed, gimmick)
		end
	end

	return allowed
end

--[=[
	The model `entityName` wears in set `setName`.

	An unknown set falls back to the default, and an entity without an entry uses
	its own name. Never returns nil: the caller is picking a child of a folder, and a
	wrong name there becomes a warning, not an error.
]=]
function Mob.GetModelName(setName : string?, entityName : string) : string
	local set = Mob.ModelSets[setName or ""] or Mob.ModelSets[Mob.DefaultModelSet]
	return (set and set[entityName]) or entityName
end

return Mob
