local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig")
local Mob = require(SharedConfig:WaitForChild("Mob"))

local EndlessWaves = {}

--[[ TUNING ]]
local HEALTH = { Start = 0.6, EarlyGrowth = 1.13, LateFrom = 25, LateGrowth = 1.09 }
local SPEED = { Start = 0.9, PerWave = 0.03, Max = 2.6 }
local BOSS_INTERVAL = 5       -- boss waves repeat every N waves after the first boss wave
local BOSS_EXTRA_EVERY = 10   -- +1 boss per faction every N waves after its first
local NEWEST_WEIGHT = 2       -- share weight of the newest faction (others are 1)

-- Astral and Sky have no elite model: their winged model stands in, with the elite's stats and pay.
local ELITE_STAND_IN = { Health = 120, SpeedMultiplier = 1 / 1.75, Reward = 45, SpawnDelay = 0.45 }

local FACTIONS = {
	{
		Name = "Astral", MinWave = 1, BossWave = 30, StandIn = true,
		Units = {
			Runt = "AstralInitiate", Grunt = "AstralWizard", Runner = "AstralKnight",
			Guard = "AstralGuardia", Charger = "AstralNecromancer", Sprinter = "AstralSentry",
			Winged = "AstralAdventurer", Elite = "AstralAdventurer", Boss = "AstralSentinel",
		},
	},
	{
		Name = "Sky", MinWave = 6, BossWave = 35, StandIn = true,
		Units = {
			Runt = "SkyBirdWarrior", Grunt = "SkyLeader", Runner = "SkyWindAxe",
			Guard = "SkyStealther", Charger = "SkyFlyingGoon", Sprinter = "SkyMage",
			Winged = "SkyGuardian", Elite = "SkyGuardian", Boss = "SkyKnight",
		},
	},
	{
		Name = "Redcliff", MinWave = 11, BossWave = 40,
		Units = {
			Runt = "Traveler", Grunt = "RedcliffPawn", Runner = "RedcliffSquire",
			Guard = "RedcliffGuard", Charger = "WallSmasher", Sprinter = "CourageBearer",
			Winged = "WingedRedcliff", Elite = "RedcliffEnforcer", Boss = "RedcliffChampion",
		},
	},
	{
		Name = "Korblox", MinWave = 16, BossWave = 45,
		Units = {
			Runt = "KorbloxMage", Grunt = "KorbloxSkeleton", Runner = "KorbloxGeneral",
			Guard = "KorbloxGremlin", Charger = "KorbloxImperium", Sprinter = "KorbloxSkeletonDefender",
			Winged = "KorbloxElder", Elite = "KorbloxDeathspeaker", Boss = "KorbloxDeathRaider",
		},
	},
	{
		Name = "Overseer", MinWave = 25, BossWave = 50,
		Units = {
			Runt = "OverseerMinion", Grunt = "OverseerWanderer", Runner = "OverseerOrb",
			Guard = "OverseerGuard", Charger = "OverseerCharger", Sprinter = "OverseerWingwalker",
			Winged = "OverseerMage", Elite = "OverseerKnight", Boss = "OverseerKing",
		},
	},
}

-- Spawn order is this list's order. Count = min(Cap, floor(Base + Per * (wave - From))).
local SLOTS = {
	{ Key = "Runt",     From = 1,  Base = 6, Per = 1.2,  Cap = 30 },
	{ Key = "Grunt",    From = 2,  Base = 2, Per = 1.1,  Cap = 40 },
	{ Key = "Runner",   From = 1,  Base = 2, Per = 1.0,  Cap = 35 },
	{ Key = "Guard",    From = 3,  Base = 1, Per = 0.9,  Cap = 40 },
	{ Key = "Charger",  From = 7,  Base = 1, Per = 0.6,  Cap = 25 },
	{ Key = "Sprinter", From = 7,  Base = 1, Per = 0.5,  Cap = 22 },
	{ Key = "Winged",   From = 12, Base = 1, Per = 0.45, Cap = 22 },
	{ Key = "Elite",    From = 20, Base = 1, Per = 0.4,  Cap = 16 },
}

for _, faction in FACTIONS do
	for key, entity in faction.Units do
		assert(Mob.Entities[entity], `Config.EndlessWaves: {faction.Name}.{key} -> unknown entity {entity}`)
	end
end

local FIRST_BOSS_WAVE = FACTIONS[1].BossWave
local cache = {}

local function healthMultiplier(wave : number) : number
	local value = HEALTH.Start * HEALTH.EarlyGrowth ^ (math.min(wave, HEALTH.LateFrom) - 1)
	if wave > HEALTH.LateFrom then
		value *= HEALTH.LateGrowth ^ (wave - HEALTH.LateFrom)
	end
	return value
end

local function speedFactor(wave : number) : number
	return math.min(SPEED.Start + SPEED.PerWave * (wave - 1), SPEED.Max)
end

local function slotCount(slot, wave : number) : number
	if wave < slot.From then return 0 end
	return math.min(slot.Cap, math.floor(slot.Base + slot.Per * (wave - slot.From)))
end

local function speedOf(reference, factor : number) : number
	return math.floor(Mob.BaseSpeed * reference.SpeedMultiplier * factor * 100 + 0.5) / 100
end

local function build(wave : number, preset)
	local hm, sf = healthMultiplier(wave), speedFactor(wave)

	local active = {}
	for _, faction in FACTIONS do
		if wave >= faction.MinWave then
			table.insert(active, faction)
		end
	end

	local newest = active[#active]
	local totalWeight = 0
	for _, faction in active do
		totalWeight += if faction == newest then NEWEST_WEIGHT else 1
	end

	local list = {}

	for _, slot in SLOTS do
		local count = slotCount(slot, wave)
		if count <= 0 then continue end

		for _, faction in active do
			local weight = if faction == newest then NEWEST_WEIGHT else 1
			local amount = math.floor(count * weight / totalWeight + 0.5)
			if amount == 0 and faction == newest then amount = 1 end
			if amount <= 0 then continue end

			local entity = faction.Units[slot.Key]
			local reference = Mob.Entities[entity]
			local entry = { Entity = entity, Amount = amount }

			if slot.Key == "Elite" and faction.StandIn then
				reference = ELITE_STAND_IN
				entry.Reward = math.max(1, math.floor(ELITE_STAND_IN.Reward * preset.RewardMultiplier + 0.5))
				entry.SpawnDelay = math.max(0.05, ELITE_STAND_IN.SpawnDelay * preset.SpawnDelayMultiplier)
			end

			entry.Health = math.max(1, math.floor(reference.Health * hm + 0.5))
			entry.Speed = speedOf(reference, sf)
			table.insert(list, entry)
		end
	end

	-- Bosses: every BOSS_INTERVAL waves from the first boss wave, each faction from its own BossWave.
	if wave >= FIRST_BOSS_WAVE and (wave - FIRST_BOSS_WAVE) % BOSS_INTERVAL == 0 then
		for _, faction in FACTIONS do
			if wave < faction.BossWave then continue end

			local entity = faction.Units.Boss
			local reference = Mob.Entities[entity]

			table.insert(list, {
				Entity = entity,
				Amount = 1 + (wave - faction.BossWave) // BOSS_EXTRA_EVERY,
				Health = math.max(1, math.floor(reference.Health * hm + 0.5)),
				Speed = speedOf(reference, sf),
			})
		end
	end

	return list
end

function EndlessWaves.Get(wave : number, preset)
	if typeof(wave) ~= "number" or wave < 1 or wave % 1 ~= 0 then
		return nil
	end

	local cached = cache[wave]
	if not cached then
		cached = build(wave, preset)
		cache[wave] = cached
	end

	return cached
end

return EndlessWaves