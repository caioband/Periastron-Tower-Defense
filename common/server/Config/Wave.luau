local Difficulty = require(script.Parent.Difficulty)

local Wave = {}

--[[
	Each wave's composition.

	The table below is the Hard spreadsheet ("PTD - Hard Difficulty - Redcliff
	Knights", kept outside the repo) transcribed: 25 hand-designed waves, with the
	count of each enemy per wave. It is the source of truth for composition: Hard
	uses the spreadsheet row by row, without multiplying any count.

	The spreadsheet's total-health column, however, is only the floor: each enemy's
	health still grows with the wave (see item 3 below), so Hard's wave 25 weighs
	more than the 1,925 the spreadsheet adds up to.

	The other difficulties come from this same table in two ways, and only these:

	  1. Length. Each preset has its own `MaxWaves`, and wave N of a preset with M
	     waves reads position `1 + (N-1)/(M-1) * 24` of the table. Easy crosses the
	     25 rows in 15 waves (skipping compositions), Nightmare in 35 (interpolating
	     between neighboring rows). The ends always match: wave 1 is row 1 and the
	     last wave is row 25, the boss row.

	  2. The preset multipliers: `AmountMultiplier` on count and `RewardMultiplier`
	     on cash per kill.

	  3. Health, which MobService computes separately: `HealthMultiplier *
	     HealthGrowth^(wave-1)`. Growth is per wave, so the same table row weighs
	     more at the end of the match than at the start, and more still on the hard
	     presets, which grow faster.

	See docs/game/enemies.md.
]]

local BOSS_ENTITY = "RedcliffChampion"

--[[
	Spawn order within a wave. MobService's loop walks the entries in sequence, so
	this list decides who enters first: weakest to strongest, with the boss last.
]]
local SPAWN_ORDER = {
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

--[[
	Cash per kill and the interval between one spawn and the next, per enemy.

	Rewards are the main source of income (damage pays 0.15 per effective point; see
	`Config.Data`), and they are tuned for Hard to yield about 9,000 cash over the
	25 waves: enough for about ten upgraded units, starting from the initial 400.
]]
local ENTITY_DATA = {
	Traveler = { Reward = 3, SpawnDelay = 0.35 },
	RedcliffPawn = { Reward = 5, SpawnDelay = 0.35 },
	RedcliffSquire = { Reward = 4, SpawnDelay = 0.3 },
	RedcliffGuard = { Reward = 9, SpawnDelay = 0.4 },
	WallSmasher = { Reward = 7, SpawnDelay = 0.32 },
	CourageBearer = { Reward = 7, SpawnDelay = 0.32 },
	WingedSquire = { Reward = 18, SpawnDelay = 0.32 },
	RedcliffEnforcer = { Reward = 45, SpawnDelay = 0.45 },
	RedcliffChampion = { Reward = 250, SpawnDelay = 1 },
}

--[[
	Count of each enemy per wave, straight from the Hard spreadsheet. The boss only
	appears on the last row, and the preset's `BossAmountMultiplier` decides how many
	of it actually enter.
]]
local WAVE_TABLE = {
	{ Traveler = 4, RedcliffSquire = 2 },
	{ Traveler = 6, RedcliffSquire = 3 },
	{ Traveler = 8, RedcliffPawn = 2, RedcliffSquire = 4 },
	{ Traveler = 8, RedcliffPawn = 3, RedcliffSquire = 6 },
	{ Traveler = 6, RedcliffPawn = 4, RedcliffSquire = 6, RedcliffGuard = 2 },
	{ Traveler = 4, RedcliffPawn = 5, RedcliffSquire = 5, RedcliffGuard = 4 },
	{ Traveler = 5, RedcliffPawn = 6, RedcliffSquire = 5, RedcliffGuard = 5 },
	{ Traveler = 6, RedcliffPawn = 7, RedcliffSquire = 6, RedcliffGuard = 6 },
	{ Traveler = 7, RedcliffPawn = 8, RedcliffSquire = 7, RedcliffGuard = 7 },
	{ Traveler = 8, RedcliffPawn = 9, RedcliffSquire = 8, RedcliffGuard = 8 },
	{ Traveler = 6, RedcliffPawn = 9, RedcliffSquire = 8, RedcliffGuard = 7, WallSmasher = 1, CourageBearer = 2 },
	{ Traveler = 5, RedcliffPawn = 10, RedcliffSquire = 9, RedcliffGuard = 8, WallSmasher = 2, CourageBearer = 2 },
	{ Traveler = 4, RedcliffPawn = 11, RedcliffSquire = 9, RedcliffGuard = 9, WallSmasher = 2, CourageBearer = 3 },
	{ Traveler = 3, RedcliffPawn = 12, RedcliffSquire = 10, RedcliffGuard = 10, WallSmasher = 3, CourageBearer = 3 },
	{ Traveler = 2, RedcliffPawn = 12, RedcliffSquire = 11, RedcliffGuard = 11, WallSmasher = 4, CourageBearer = 3, WingedSquire = 1 },
	{ Traveler = 2, RedcliffPawn = 13, RedcliffSquire = 11, RedcliffGuard = 12, WallSmasher = 4, CourageBearer = 4, WingedSquire = 2 },
	{ Traveler = 1, RedcliffPawn = 14, RedcliffSquire = 12, RedcliffGuard = 13, WallSmasher = 5, CourageBearer = 4, WingedSquire = 2 },
	{ RedcliffPawn = 15, RedcliffSquire = 13, RedcliffGuard = 14, WallSmasher = 5, CourageBearer = 4, WingedSquire = 3, RedcliffEnforcer = 1 },
	{ RedcliffPawn = 15, RedcliffSquire = 13, RedcliffGuard = 14, WallSmasher = 6, CourageBearer = 5, WingedSquire = 3, RedcliffEnforcer = 1 },
	{ RedcliffPawn = 16, RedcliffSquire = 14, RedcliffGuard = 15, WallSmasher = 6, CourageBearer = 5, WingedSquire = 4, RedcliffEnforcer = 2 },
	{ RedcliffPawn = 16, RedcliffSquire = 14, RedcliffGuard = 15, WallSmasher = 5, CourageBearer = 4, WingedSquire = 3, RedcliffEnforcer = 2 },
	{ RedcliffPawn = 17, RedcliffSquire = 15, RedcliffGuard = 16, WallSmasher = 7, CourageBearer = 6, WingedSquire = 4, RedcliffEnforcer = 3 },
	{ RedcliffPawn = 17, RedcliffSquire = 15, RedcliffGuard = 16, WallSmasher = 6, CourageBearer = 5, WingedSquire = 4, RedcliffEnforcer = 3 },
	{ RedcliffPawn = 18, RedcliffSquire = 16, RedcliffGuard = 17, WallSmasher = 8, CourageBearer = 7, WingedSquire = 5, RedcliffEnforcer = 3 },
	{ RedcliffPawn = 9, RedcliffSquire = 10, RedcliffGuard = 12, WallSmasher = 2, CourageBearer = 3, WingedSquire = 5, RedcliffEnforcer = 3, RedcliffChampion = 1 },
}

local TABLE_LENGTH = #WAVE_TABLE

--[=[
	Where the wave falls in the table. Returns a fractional number between 1 and 25:
	the integer part is the row, and the fraction is how far it has moved toward the
	next.
]=]
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

--[=[
	Where this wave falls in the composition table.

	The normal math spreads the preset's waves over the **whole** table: wave 1 is
	the first row and the last wave is the last row, with the middle interpolated.
	That is what makes Easy (15 waves) and Nightmare (35) walk the same curve at
	different paces.

	`TableRows` shortens the stretch used. It is for a short preset that is **not** a
	whole game sped up: the tutorial has 5 waves, and without this its wave 2 would
	land on table row 7, twelve enemies with Guard and Pawn in the second minute of
	someone who has never played. With `TableRows = 5`, the five waves are the first
	five rows, in order, which is the ramp the table was designed to have.
]=]
local function tablePosition(waveNumber : number, preset)
	local total = preset.MaxWaves or TABLE_LENGTH
	local rows = math.clamp(preset.TableRows or TABLE_LENGTH, 1, TABLE_LENGTH)

	if total <= 1 then
		return rows
	end

	local clamped = math.clamp(waveNumber, 1, total)
	return 1 + ((clamped - 1) / (total - 1)) * (rows - 1)
end

--[=[
	How many enemies of this type the wave brings, interpolating between the two
	neighboring table rows. Zero means the type does not appear in this wave.
]=]
local function amountAt(entity : string, position : number, preset, scale : number?) : number
	local lower = math.clamp(math.floor(position), 1, TABLE_LENGTH)
	local upper = math.min(lower + 1, TABLE_LENGTH)
	local alpha = position - lower

	local from = WAVE_TABLE[lower][entity] or 0
	local to = WAVE_TABLE[upper][entity] or 0
	local interpolated = from + ((to - from) * alpha)

	return math.max(0, math.floor((interpolated * (preset.AmountMultiplier or 1) * (scale or 1)) + 0.5))
end

local function buildSpawnEntry(entity : string, amount : number, preset)
	local data = ENTITY_DATA[entity]
	return {
		Entity = entity,
		Amount = amount,
		Reward = math.max(1, math.floor((data.Reward * preset.RewardMultiplier) + 0.5)),
		SpawnDelay = math.max(0.05, data.SpawnDelay * preset.SpawnDelayMultiplier),
	}
end

--[=[
	Whether the wave brings the boss. The client does not see this config (it is
	server-only), so whoever needs to know gets the answer along with the `SetWave`
	event; the boss music depends on it.

	The boss closes the match: it is the table's last row, and every preset's last
	wave lands on it.
]=]
function Wave.HasBoss(waveNumber : number, difficultyName : string?)
	local preset = Difficulty.Get(difficultyName)
	return waveNumber >= (preset.MaxWaves or TABLE_LENGTH)
end

--- Whether the entity is the boss. `MobService` asks, since it counts the bosses
--- each player took down (the "Defeat 70 bosses" contract).
function Wave.IsBoss(entityName : string?) : boolean
	return entityName == BOSS_ENTITY
end

function Wave.GetSpawns(waveNumber : number, difficultyName : string?)
	local preset = Difficulty.Get(difficultyName)
	local position = tablePosition(waveNumber, preset)
	local spawns = {}

	--[[
		`BossWaveOnly` leaves the boss wave with **only** the boss.

		It is for the tutorial: its last wave is the first time the player sees a boss,
		and teaching that amid ten regular enemies teaches two things at once. On
		normal presets the escort is part of the challenge, which is why the key is
		optional instead of a rule.
	]]
	local bossOnly = preset.BossWaveOnly == true and Wave.HasBoss(waveNumber, difficultyName)

	if not bossOnly then
		for _, entity in SPAWN_ORDER do
			if entity == BOSS_ENTITY then
				continue
			end

			--[[
				`WaveAmountScale` is the weight of **one** wave, on top of the curve. It
				exists for scripted waves: the tutorial's wave 3 coincides with the
				player's first weather ever, and the curve plus the weather debuff made it
				the hardest of the five.
			]]
			local scale = preset.WaveAmountScale and preset.WaveAmountScale[waveNumber]
			local amount = amountAt(entity, position, preset, scale)
			if amount > 0 then
				table.insert(spawns, buildSpawnEntry(entity, amount, preset))
			end
		end
	end

	if Wave.HasBoss(waveNumber, difficultyName) then
		local bossAmount = math.max(1, math.floor(((WAVE_TABLE[TABLE_LENGTH][BOSS_ENTITY] or 1)
			* (preset.BossAmountMultiplier or 1)) + 0.5))

		table.insert(spawns, buildSpawnEntry(BOSS_ENTITY, bossAmount, preset))
	end

	return spawns
end

return Wave
