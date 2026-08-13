local Difficulty = require(script.Parent.Difficulty)

local Wave = {}

local CYCLE_ENTITIES = {
	"Traveler",
	"RedcliffPawn",
	"RedcliffSquire",
	"RedcliffGuard",
	"WallSmasher",
	"CourageBearer",
	"WingedSquire",
	"RedcliffEnforcer",
	"RedcliffChampion",
}

local BOSS_ENTITY = "RedcliffChampion"
local STANDARD_AMOUNT = 3
local BOSS_AMOUNT = 1

local ENTITY_DATA = {
	Traveler = { Reward = 10, SpawnDelay = 0.85 },
	RedcliffPawn = { Reward = 15, SpawnDelay = 0.85 },
	RedcliffSquire = { Reward = 18, SpawnDelay = 0.75 },
	RedcliffGuard = { Reward = 30, SpawnDelay = 1 },
	WallSmasher = { Reward = 20, SpawnDelay = 0.8 },
	CourageBearer = { Reward = 20, SpawnDelay = 0.8 },
	WingedSquire = { Reward = 40, SpawnDelay = 0.8 },
	RedcliffEnforcer = { Reward = 90, SpawnDelay = 1.1 },
	RedcliffChampion = { Reward = 250, SpawnDelay = 1 },
}

local CYCLE_LENGTH = #CYCLE_ENTITIES

local function scaleAmount(amount : number, waveNumber : number, preset, isBoss : boolean?)
	if isBoss then
		return math.max(1, math.floor((amount * preset.BossAmountMultiplier) + 0.5))
	end

	local growth = math.min((waveNumber - 1) * preset.AmountGrowth, preset.AmountGrowthCap)
	return math.max(1, math.floor((amount * preset.AmountMultiplier) + growth + 0.5))
end

local function buildSpawnEntry(entity : string, amount : number, waveNumber : number, preset, isBoss : boolean?)
	local data = ENTITY_DATA[entity]
	return {
		Entity = entity,
		Amount = scaleAmount(amount, waveNumber, preset, isBoss),
		Reward = math.max(1, math.floor((data.Reward * preset.RewardMultiplier) + 0.5)),
		SpawnDelay = math.max(0.1, data.SpawnDelay * preset.SpawnDelayMultiplier),
	}
end

function Wave.GetSpawns(waveNumber : number, difficultyName : string?)
	local preset = Difficulty.Get(difficultyName)
	local position = ((waveNumber - 1) % CYCLE_LENGTH) + 1
	local entity = CYCLE_ENTITIES[position]

	if entity == BOSS_ENTITY then
		local worseEntity = CYCLE_ENTITIES[position - 1]

		return {
			buildSpawnEntry(worseEntity, STANDARD_AMOUNT, waveNumber, preset),
			buildSpawnEntry(BOSS_ENTITY, BOSS_AMOUNT, waveNumber, preset, true),
		}
	end

	return {
		buildSpawnEntry(entity, STANDARD_AMOUNT, waveNumber, preset),
	}
end

return Wave
