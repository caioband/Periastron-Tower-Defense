-- This module lives in ServerScriptService.Config, so the path to the shared
-- config must be absolute.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig")
local Mob = require(SharedConfig:WaitForChild("Mob"))

local Difficulty = require(script.Parent.Difficulty)
local Waves = require(script.Parent.Waves)

local Wave = {}

--[[
	What each wave spawns, read from the hard-coded tables in `Config.Waves`.

	Each difficulty has its own module there, with every wave written out: which
	entities, in what order, how many, and with what health and speed. This module
	only fills in what the tables leave to the entity (cash per kill and the delay
	between spawns) and answers the questions the rest of the server asks: what the
	wave spawns, whether it has a boss, and what each wave pays.

	See docs/game/waves.md.
]]

--[[
	Cash per kill and the interval between one spawn and the next, per entity. A
	wave entry can override either with its own `Reward` or `SpawnDelay`; without
	that, the value here is scaled by the preset's `RewardMultiplier` and
	`SpawnDelayMultiplier`.

	Slots that do the same job across casts pay the same: fodder 3-5, the Guard 9,
	the charger and the sprinter 7, the winged 18, the elite 45, the boss 250. The
	Astral and Sky casts have no elite model of their own, so their waves list the
	winged model in the elite's place with an explicit `Reward` and `SpawnDelay`.

	Rewards are the main source of income (damage pays 0.15 per effective point; see
	`Config.Data`), and they are tuned for Hard to yield about 9,000 cash over the
	25 waves: enough for about ten upgraded units, starting from the initial 400.
]]
local ENTITY_DATA = {
	-- Redcliff
	Traveler = { Reward = 3, SpawnDelay = 0.35 },
	RedcliffPawn = { Reward = 5, SpawnDelay = 0.35 },
	RedcliffSquire = { Reward = 4, SpawnDelay = 0.3 },
	RedcliffGuard = { Reward = 9, SpawnDelay = 0.4 },
	WallSmasher = { Reward = 7, SpawnDelay = 0.32 },
	CourageBearer = { Reward = 7, SpawnDelay = 0.32 },
	WingedRedcliff = { Reward = 18, SpawnDelay = 0.32 },
	RedcliffEnforcer = { Reward = 45, SpawnDelay = 0.45 },
	RedcliffChampion = { Reward = 250, SpawnDelay = 1 },

	-- Astral
	AstralInitiate = { Reward = 3, SpawnDelay = 0.35 },
	AstralWizard = { Reward = 5, SpawnDelay = 0.35 },
	AstralKnight = { Reward = 4, SpawnDelay = 0.3 },
	AstralGuardia = { Reward = 9, SpawnDelay = 0.4 },
	AstralNecromancer = { Reward = 7, SpawnDelay = 0.32 },
	AstralSentry = { Reward = 7, SpawnDelay = 0.32 },
	AstralAdventurer = { Reward = 18, SpawnDelay = 0.32 },
	AstralSentinel = { Reward = 250, SpawnDelay = 1 },

	-- Sky
	SkyBirdWarrior = { Reward = 3, SpawnDelay = 0.35 },
	SkyLeader = { Reward = 5, SpawnDelay = 0.35 },
	SkyWindAxe = { Reward = 4, SpawnDelay = 0.3 },
	SkyStealther = { Reward = 9, SpawnDelay = 0.4 },
	SkyFlyingGoon = { Reward = 7, SpawnDelay = 0.32 },
	SkyMage = { Reward = 7, SpawnDelay = 0.32 },
	SkyGuardian = { Reward = 18, SpawnDelay = 0.32 },
	SkyKnight = { Reward = 250, SpawnDelay = 1 },

	-- Korblox
	KorbloxMage = { Reward = 3, SpawnDelay = 0.35 },
	KorbloxSkeleton = { Reward = 5, SpawnDelay = 0.35 },
	KorbloxGeneral = { Reward = 4, SpawnDelay = 0.3 },
	KorbloxGremlin = { Reward = 9, SpawnDelay = 0.4 },
	KorbloxImperium = { Reward = 7, SpawnDelay = 0.32 },
	KorbloxSkeletonDefender = { Reward = 7, SpawnDelay = 0.32 },
	KorbloxElder = { Reward = 18, SpawnDelay = 0.32 },
	KorbloxDeathspeaker = { Reward = 45, SpawnDelay = 0.45 },
	KorbloxDeathRaider = { Reward = 250, SpawnDelay = 1 },

	-- Overseer
	OverseerMinion = { Reward = 3, SpawnDelay = 0.35 },
	OverseerWanderer = { Reward = 5, SpawnDelay = 0.35 },
	OverseerOrb = { Reward = 4, SpawnDelay = 0.3 },
	OverseerGuard = { Reward = 9, SpawnDelay = 0.4 },
	OverseerCharger = { Reward = 7, SpawnDelay = 0.32 },
	OverseerWingwalker = { Reward = 7, SpawnDelay = 0.32 },
	OverseerMage = { Reward = 18, SpawnDelay = 0.32 },
	OverseerKnight = { Reward = 45, SpawnDelay = 0.45 },
	OverseerKing = { Reward = 250, SpawnDelay = 1 },
}

--[[
	`Config.Waves` only knows `SharedConfig.Mob`, so an entity that exists there but
	not here would pass its check and then spawn with no reward. Checked at load,
	like the tables themselves; an entry with both overrides needs no data here.
]]
for difficultyName in Difficulty.Presets do
	for waveNumber, wave in Waves.Get(difficultyName) or {} do
		for index, entry in wave do
			if not ENTITY_DATA[entry.Entity] and (entry.Reward == nil or entry.SpawnDelay == nil) then
				error(`Config.Waves.{difficultyName}: wave {waveNumber}, entry {index}: `
					.. `{entry.Entity} has no Reward/SpawnDelay in Config.Wave's ENTITY_DATA`, 0)
			end
		end
	end
end

--[[
	The reward per completed wave, paid to ALL players in the match.

	It is team income: it does not depend on who hit, who killed, or who placed
	units. It pays once, when the wave actually ends; a lost wave (game over) does
	not pay.

	The reward is **cumulative**: each band says how much a wave adds over the
	previous one, and wave N's value is the sum of the steps of every wave up to it.
	With today's bands: 25, 50, 75... up to 250 on wave 10, then in steps of 50:
	300 on 11, 1,250 on 30.

	`UpTo` is the band's last wave; the last entry has no `UpTo` and applies from
	there on, which matters because `MaxWaves` varies by difficulty and Nightmare
	goes to wave 35 (1,500 there).
]]
Wave.CASH_TIERS = {
	{ UpTo = 10, Step = 25 },
	{ Step = 50 },
}

--[=[
	How much wave `waveNumber` pays each player. An invalid wave returns 0.
]=]
function Wave.GetWaveCash(waveNumber : number?) : number
	if typeof(waveNumber) ~= "number" or waveNumber < 1 then
		return 0
	end

	local total = 0
	local from = 1

	for _, tier in Wave.CASH_TIERS do
		local last = math.min(tier.UpTo or waveNumber, waveNumber)
		if last < from then break end

		total += (last - from + 1) * (tier.Step or 0)
		from = last + 1

		if from > waveNumber then break end
	end

	return total
end

local function getWave(waveNumber : number, difficultyName : string?)
	local preset = Difficulty.Get(difficultyName)
	local waves = Waves.Get(preset.Name)
	return (waves and waves[waveNumber]), preset
end

--[=[
	Whether the wave brings a boss (an entity with `Boss = true` in
	`SharedConfig.Mob`). The client does not see the wave tables (they are
	server-only), so whoever needs to know gets the answer along with the `SetWave`
	event; the boss music depends on it.

	It reads the wave itself, so a boss placed mid-match switches the music too.
]=]
function Wave.HasBoss(waveNumber : number, difficultyName : string?) : boolean
	local wave = getWave(waveNumber, difficultyName)
	if not wave then return false end

	for _, entry in wave do
		if Mob.IsBoss(entry.Entity) then
			return true
		end
	end

	return false
end

--- Whether the entity is a boss. `MobService` asks, since it counts the bosses each
--- player took down (the "Defeat 70 bosses" contract).
function Wave.IsBoss(entityName : string?) : boolean
	return Mob.IsBoss(entityName)
end

--[=[
	What the wave spawns, in spawn order: the table's entries with `Reward` and
	`SpawnDelay` filled in. A wave the difficulty does not have returns an empty
	list.
]=]
function Wave.GetSpawns(waveNumber : number, difficultyName : string?)
	local wave, preset = getWave(waveNumber, difficultyName)
	local spawns = {}

	for _, entry in wave or {} do
		local data = ENTITY_DATA[entry.Entity]

		table.insert(spawns, {
			Entity = entry.Entity,
			Amount = entry.Amount,
			Health = entry.Health,
			Speed = entry.Speed,
			Reward = entry.Reward
				or math.max(1, math.floor((data.Reward * preset.RewardMultiplier) + 0.5)),
			SpawnDelay = entry.SpawnDelay
				or math.max(0.05, data.SpawnDelay * preset.SpawnDelayMultiplier),
		})
	end

	return spawns
end

return Wave
