--[[
	Daily and weekly challenges: what each period draws, what it pays, and how a
	challenge is rebuilt anywhere from three numbers.

	**Same board everywhere, no storage.** A period's challenges come out of a
	`Random` seeded with the period number, so the Lobby server, every client, and
	the Game place all generate the exact same list without sending it anywhere.
	The teleport only carries `{ Kind, Period, Slot }`, and the Game rebuilds the
	challenge from this file: nothing in it can be forged by a client.

	Determinism rule: every list fed to the RNG is built in a fixed order (sorted
	unit names, `MapConfig.getOrderedMaps`, the arrays in `WeatherConfig.MapPools`,
	`MODIFIER_ORDER`). Never iterate a dictionary with `pairs` order into the RNG.
	Changing any of those lists, or `SALT`, changes the current period's board.

	**Periods roll over at fixed times (UTC)**, the same as contracts: daily at
	midnight, weekly on Monday 00:00 (the epoch was a Thursday, hence `Offset`).

	**Weather runs the whole match.** `weatherAt(challenge, wave)` says which
	weather is on for any wave, from wave 1, changing every `RotateWaves` waves
	and never repeating the previous block when the list has more than one.

	**Modifiers are preset scales.** Each one multiplies fields of the difficulty
	preset (`ServerScriptService.Config.Difficulty`), the same way the tutorial's
	`PresetOverrides` replaces them: no new match mechanic is needed to run them.

	Profile record (`DATA_KEY`): `{ [kind] = { Period, Done = { ["slot"] = true } } }`.
]]

local MapConfig = require(script.Parent.MapConfig)
local UnitStats = require(script.Parent.UnitStats)
local WeatherConfig = require(script.Parent.WeatherConfig)

local HOUR = 3600
local DAY = 24 * HOUR
local WEEK = 7 * DAY

local ChallengeConfig = {}

ChallengeConfig.DATA_KEY = "Challenges"

-- Changing this reshuffles every board, current period included.
ChallengeConfig.SALT = 7919

-- Seconds a player must wait between Play requests (covers a teleport in flight).
ChallengeConfig.PLAY_COOLDOWN = 5

-- Workspace attributes the Game place sets once the challenge is resolved, so
-- clients can rebuild it with `get` (banned cards, weather panel, rules screen).
ChallengeConfig.ATTRIBUTES = {
	Kind = "ChallengeKind",
	Period = "ChallengePeriod",
	Slot = "ChallengeSlot",
}

ChallengeConfig.KIND_ORDER = { "Daily", "Weekly" }

--[[
	Per kind:

	  - `Count`: challenges per period (the board's cards).
	  - `Length` / `Offset`: the period, as in `ContractConfig.KINDS`.
	  - `Difficulties`: preset names drawn from.
	  - `Maps.MinWins` / `Maps.MaxWins`: which maps qualify, by `WinsRequired`.
	    Maps do not repeat within a period while there are enough of them.
	  - `Bans`: how many random towers are banned (inclusive range). At least one
	    unit is always left unbanned.
	  - `Weather.Harsh`: only the map's weathers listed in `HARSH_WEATHERS`
	    (falls back to the full map pool when none are). `RotateWaves`: waves per
	    weather before the next one.
	  - `Modifiers`: how many entries of `MODIFIERS` are applied.
	  - `Rewards`: paid once per challenge per period (`RewardService:Grant`).
]]
ChallengeConfig.KINDS = {
	Daily = {
		Count = 3,
		Length = DAY,
		Offset = 0,

		Difficulties = { "Easy", "Medium" },
		Maps = { MinWins = 0 },
		Bans = { Min = 2, Max = 4 },
		Weather = { Harsh = false, RotateWaves = 4 },
		Modifiers = { Min = 0, Max = 0 },

		Rewards = { Cash = 300, Shards = 3 },
	},

	Weekly = {
		Count = 2,
		Length = WEEK,
		Offset = 4 * DAY,

		Difficulties = { "Hard", "Impossible", "Nightmare" },
		Maps = { MinWins = 5 },
		Bans = { Min = 5, Max = 8 },
		Weather = { Harsh = true, RotateWaves = 3 },
		Modifiers = { Min = 1, Max = 2 },

		Rewards = { Cash = 1500, Shards = 15, Crates = { Epic = 1 } },
	},
}

-- The weathers that count as harsh for weeklies.
ChallengeConfig.HARSH_WEATHERS = {
	Drought = true,
	Sandstorm = true,
	Snow = true,
	Thunder = true,
	Rain = true,
	Wind = true,
}

--[[
	Weekly modifiers. `Scale` multiplies preset fields; whole-number fields are
	rounded and kept at 1 or more, and a field that is 0 stays 0.
]]
ChallengeConfig.MODIFIERS = {
	GlassBase = { Name = "GLASS BASE", Scale = { BaseHealth = 0.6 } },
	TightBudget = { Name = "TIGHT BUDGET", Scale = { StartingCash = 0.7 } },
	ShortBreaks = { Name = "SHORT BREAKS", Scale = { IntermissionTime = 0.6 } },
	HeavyHits = { Name = "HEAVY HITS", Scale = { MobDamage = 1.4 } },
	LeanBounty = { Name = "LEAN BOUNTY", Scale = { RewardMultiplier = 0.8 } },
}

-- Draw order for modifiers (part of the determinism rule above).
ChallengeConfig.MODIFIER_ORDER = { "GlassBase", "TightBudget", "ShortBreaks", "HeavyHits", "LeanBounty" }

-- Units that are never banned (event-only, unreleased...).
ChallengeConfig.EXCLUDED_UNITS = {}

--[[ INTERNAL ]]

local function now() : number
	return workspace:GetServerTimeNow()
end

local function shuffle(list : { any }, rng : Random)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

local function pickMany(source : { any }, count : number, rng : Random) : { any }
	local pool = table.clone(source)
	shuffle(pool, rng)

	local picked = {}
	for index = 1, math.min(count, #pool) do
		picked[index] = pool[index]
	end

	return picked
end

local function eligibleMaps(rules) : { string }
	local minWins = rules.Maps.MinWins or 0
	local maxWins = rules.Maps.MaxWins

	local maps = {}
	for _, name in MapConfig.getOrderedMaps() do
		local wins = MapConfig.getWinsRequired(name)
		if wins >= minWins and (maxWins == nil or wins <= maxWins) then
			table.insert(maps, name)
		end
	end

	if #maps == 0 then
		return MapConfig.getOrderedMaps()
	end

	return maps
end

local function bannableUnits() : { string }
	local units = {}

	for name, stats in UnitStats do
		if typeof(name) == "string" and typeof(stats) == "table" and stats.Rarity ~= nil
			and not ChallengeConfig.EXCLUDED_UNITS[name] then
			table.insert(units, name)
		end
	end

	table.sort(units)
	return units
end

local function weathersFor(mapName : string, harsh : boolean) : { string }
	local pool = WeatherConfig.GetPool(mapName)
	if not harsh then
		return table.clone(pool)
	end

	local list = {}
	for _, weather in pool do
		if ChallengeConfig.HARSH_WEATHERS[weather] then
			table.insert(list, weather)
		end
	end

	if #list == 0 then
		return table.clone(pool)
	end

	return list
end

local function isInteger(value : any) : boolean
	return typeof(value) == "number" and value == value and value == math.floor(value)
end

-- [ "Kind:Period" ] = generated list. Small and cleared when it grows.
local Cache = {}
local CacheSize = 0
local CACHE_LIMIT = 16

--[[ PERIODS ]]

function ChallengeConfig.isKind(kind : any) : boolean
	return typeof(kind) == "string" and ChallengeConfig.KINDS[kind] ~= nil
end

function ChallengeConfig.periodOf(kind : string, at : number?) : number
	local rules = ChallengeConfig.KINDS[kind]
	return math.floor(((at or now()) - rules.Offset) / rules.Length)
end

function ChallengeConfig.currentPeriod(kind : string) : number
	return ChallengeConfig.periodOf(kind, now())
end

--- The server time (seconds) when `period` of `kind` ends.
function ChallengeConfig.endsAt(kind : string, period : number) : number
	local rules = ChallengeConfig.KINDS[kind]
	return rules.Offset + (period + 1) * rules.Length
end

--- Seconds left in the current period of `kind`.
function ChallengeConfig.remaining(kind : string) : number
	return math.max(ChallengeConfig.endsAt(kind, ChallengeConfig.currentPeriod(kind)) - now(), 0)
end

function ChallengeConfig.id(kind : string, period : number, slot : number) : string
	return `{kind}:{period}:{slot}`
end

--[[ GENERATION ]]

export type Challenge = {
	Id : string,
	Kind : string,
	Period : number,
	Slot : number,
	Map : string,
	Difficulty : string,
	Weathers : { string },
	RotateWaves : number,
	Bans : { string },
	Banned : { [string] : boolean },
	Modifiers : { string },
	Rewards : { [string] : any },
	Seed : number,
}

--[=[
	Every challenge of `kind` in `period`, in slot order. Frozen: read, never write.
]=]
function ChallengeConfig.generate(kind : string, period : number) : { Challenge }
	local key = `{kind}:{period}`
	local cached = Cache[key]
	if cached then
		return cached
	end

	local rules = ChallengeConfig.KINDS[kind]
	if not rules or not isInteger(period) then
		return {}
	end

	local kindIndex = table.find(ChallengeConfig.KIND_ORDER, kind) or 0
	local seed = (period * 131 + kindIndex * 977 + ChallengeConfig.SALT) % 2147483647
	local rng = Random.new(seed)

	local maps = eligibleMaps(rules)
	shuffle(maps, rng)

	local units = bannableUnits()
	local list = {}

	for slot = 1, rules.Count do
		local map = maps[(slot - 1) % #maps + 1]
		local difficulty = rules.Difficulties[rng:NextInteger(1, #rules.Difficulties)]

		local banCount = math.clamp(rng:NextInteger(rules.Bans.Min, rules.Bans.Max), 0, math.max(#units - 1, 0))
		local bans = pickMany(units, banCount, rng)

		local banned = {}
		for _, unit in bans do
			banned[unit] = true
		end

		local modifierCount = math.clamp(rng:NextInteger(rules.Modifiers.Min, rules.Modifiers.Max), 0, #ChallengeConfig.MODIFIER_ORDER)
		local modifiers = pickMany(ChallengeConfig.MODIFIER_ORDER, modifierCount, rng)

		list[slot] = table.freeze({
			Id = ChallengeConfig.id(kind, period, slot),
			Kind = kind,
			Period = period,
			Slot = slot,
			Map = map,
			Difficulty = difficulty,
			Weathers = table.freeze(weathersFor(map, rules.Weather.Harsh)),
			RotateWaves = math.max(1, rules.Weather.RotateWaves or 1),
			Bans = table.freeze(bans),
			Banned = table.freeze(banned),
			Modifiers = table.freeze(modifiers),
			Rewards = rules.Rewards,
			Seed = rng:NextInteger(1, 1073741823),
		})
	end

	table.freeze(list)

	if CacheSize >= CACHE_LIMIT then
		table.clear(Cache)
		CacheSize = 0
	end

	Cache[key] = list
	CacheSize += 1

	return list
end

--- One challenge, or nil when the slot does not exist.
function ChallengeConfig.get(kind : any, period : any, slot : any) : Challenge?
	if not ChallengeConfig.isKind(kind) or not isInteger(period) or not isInteger(slot) then
		return nil
	end

	if slot < 1 or slot > ChallengeConfig.KINDS[kind].Count then
		return nil
	end

	return ChallengeConfig.generate(kind, period)[slot]
end

--- The current period's board for `kind`.
function ChallengeConfig.current(kind : string) : { Challenge }
	return ChallengeConfig.generate(kind, ChallengeConfig.currentPeriod(kind))
end

--[=[
	Rebuilds a challenge from teleport data `{ Kind, Period, Slot }`. Only the current
	period and the one before it are accepted, so a match that runs past a rollover
	still counts, and an old or forged reference does not.
]=]
function ChallengeConfig.resolveRef(ref : any, at : number?) : Challenge?
	if typeof(ref) ~= "table" or not ChallengeConfig.isKind(ref.Kind) or not isInteger(ref.Period) then
		return nil
	end

	local current = ChallengeConfig.periodOf(ref.Kind, at)
	if ref.Period ~= current and ref.Period ~= current - 1 then
		return nil
	end

	return ChallengeConfig.get(ref.Kind, ref.Period, ref.Slot)
end

--[[ RULES ]]

function ChallengeConfig.isBanned(challenge : Challenge?, unitName : string?) : boolean
	return challenge ~= nil and unitName ~= nil and challenge.Banned[unitName] == true
end

--[=[
	The weather on for `wave` (1-based), or nil when the map has no weathers.
	Changes every `RotateWaves` waves; with two or more weathers, a block never
	repeats the one before it.
]=]
function ChallengeConfig.weatherAt(challenge : Challenge?, wave : number) : string?
	if not challenge then
		return nil
	end

	local weathers = challenge.Weathers
	local count = #weathers
	if count == 0 then
		return nil
	end

	if count == 1 then
		return weathers[1]
	end

	local block = math.floor((math.max(math.floor(wave), 1) - 1) / challenge.RotateWaves)

	local function pick(index : number) : number
		return Random.new(challenge.Seed + 7777 + index * 31):NextInteger(1, count)
	end

	local chosen = pick(block)
	if block > 0 and chosen == pick(block - 1) then
		chosen = chosen % count + 1
	end

	return weathers[chosen]
end

--- A copy of `preset` with the challenge's modifiers applied.
function ChallengeConfig.applyModifiers(challenge : Challenge?, preset : { [string] : any }) : { [string] : any }
	local copy = table.clone(preset)
	if not challenge then
		return copy
	end

	for _, id in challenge.Modifiers do
		local modifier = ChallengeConfig.MODIFIERS[id]
		if not modifier then
			continue
		end

		for field, scale in modifier.Scale do
			local value = copy[field]
			if typeof(value) ~= "number" or value == 0 then
				continue
			end

			local scaled = value * scale
			if value == math.floor(value) then
				scaled = math.max(1, math.floor(scaled + 0.5))
			end

			copy[field] = scaled
		end
	end

	return copy
end

--- The display names of the challenge's modifiers, in order.
function ChallengeConfig.modifierNames(challenge : Challenge?) : { string }
	local names = {}

	for _, id in (challenge and challenge.Modifiers or {}) do
		local modifier = ChallengeConfig.MODIFIERS[id]
		table.insert(names, modifier and modifier.Name or string.upper(id))
	end

	return names
end

--[[ PROFILE ]]

function ChallengeConfig.createEmpty()
	local record = {}

	for _, kind in ChallengeConfig.KIND_ORDER do
		record[kind] = { Period = -1, Done = {} }
	end

	return record
end

--- Whether the profile record already has this challenge completed (and paid).
function ChallengeConfig.isCompleted(record : any, challenge : Challenge?) : boolean
	if typeof(record) ~= "table" or not challenge then
		return false
	end

	local entry = record[challenge.Kind]
	if typeof(entry) ~= "table" or entry.Period ~= challenge.Period or typeof(entry.Done) ~= "table" then
		return false
	end

	return entry.Done[tostring(challenge.Slot)] == true
end

return ChallengeConfig