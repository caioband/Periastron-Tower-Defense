--[[
	The hard-coded waves, one module per difficulty.

	Each child module is named after a preset in `Config.Difficulty` and returns
	that difficulty's waves:

		return {
			[1] = {
				{ Entity = "Traveler", Amount = 8, Health = 10, Speed = 4.4 },
				{ Entity = "RedcliffSquire", Amount = 4, Health = 12, Speed = 6.6 },
			},
			[2] = { ... },
		}

	- The key is the wave number, from 1 with no gaps. How many waves the table has
	  is the difficulty's `MaxWaves`; `Config.Difficulty` reads it from here.
	- Each wave is a list, and the list order is the spawn order: the first entry
	  spawns all of its enemies before the second starts. The same entity can appear
	  more than once, to interleave groups.
	- `Entity` is a key of `SharedConfig.Mob.Entities`, which is also the name of
	  the model it spawns; its gimmicks and model folder come from there. Any
	  difficulty may use any entity, from any cast.
	- `Health` and `Speed` (studs per second) are the enemy's final values. Nothing
	  multiplies them except the weather, which applies on top at spawn.
	- `Reward` (cash per kill) and `SpawnDelay` (seconds until the next enemy) are
	  optional overrides. Without them, `Config.Wave` uses the entity's value times
	  the preset's `RewardMultiplier`/`SpawnDelayMultiplier`.
	- The boss wave is any wave with a boss entity in it (`Boss = true` in
	  `SharedConfig.Mob`; see `Config.Wave.HasBoss`).

	Every table is checked when this module loads, so a typo stops the server at
	boot instead of breaking a wave mid-match.

	See docs/game/waves.md.
]]

-- This module lives in ServerScriptService.Config, so the path to the shared
-- config must be absolute.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig")
local Mob = require(SharedConfig:WaitForChild("Mob"))

export type Entry = {
	Entity : string,
	Amount : number,
	Health : number,
	Speed : number,
	Reward : number?,
	SpawnDelay : number?,
}

export type WaveTable = { [number] : { Entry } }

local Waves = {}

local tables : { [string] : WaveTable } = {}

local function isPositive(value) : boolean
	return typeof(value) == "number" and value > 0 and value == value and value ~= math.huge
end

local function validate(difficultyName : string, waves : any)
	local function fail(message : string)
		error(`Config.Waves.{difficultyName}: {message}`, 0)
	end

	if typeof(waves) ~= "table" then
		fail("the module must return a table")
	end

	local count = 0
	for key in waves do
		if typeof(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			fail(`invalid wave key {tostring(key)}; keys are wave numbers starting at 1`)
		end
		count += 1
	end

	if count == 0 then
		fail("no waves")
	end

	for waveNumber = 1, count do
		local wave = waves[waveNumber]
		if wave == nil then
			fail(`wave {waveNumber} is missing; waves must run from 1 to {count} with no gaps`)
		end

		if typeof(wave) ~= "table" or #wave == 0 then
			fail(`wave {waveNumber} must be a non-empty list of spawns`)
		end

		for index, entry in wave do
			local where = `wave {waveNumber}, entry {index}`

			if typeof(index) ~= "number" or index > #wave then
				fail(`{where}: a wave is a list; its keys are the spawn order`)
			end

			if typeof(entry) ~= "table" then
				fail(`{where}: must be a table`)
			end

			if typeof(entry.Entity) ~= "string" or not Mob.Entities[entry.Entity] then
				fail(`{where}: unknown entity {tostring(entry.Entity)}`)
			end

			if not isPositive(entry.Amount) or entry.Amount % 1 ~= 0 then
				fail(`{where} ({entry.Entity}): Amount must be a whole number above 0`)
			end

			if not isPositive(entry.Health) then
				fail(`{where} ({entry.Entity}): Health must be above 0`)
			end

			if not isPositive(entry.Speed) then
				fail(`{where} ({entry.Entity}): Speed must be above 0`)
			end

			if entry.Reward ~= nil and (typeof(entry.Reward) ~= "number" or entry.Reward < 0) then
				fail(`{where} ({entry.Entity}): Reward must be 0 or more`)
			end

			if entry.SpawnDelay ~= nil and not isPositive(entry.SpawnDelay) then
				fail(`{where} ({entry.Entity}): SpawnDelay must be above 0`)
			end
		end
	end
end

for _, module in script:GetChildren() do
	if module:IsA("ModuleScript") then
		local waves = require(module)
		validate(module.Name, waves)
		tables[module.Name] = waves
	end
end

--- The difficulty's waves, or nil if it has no module.
function Waves.Get(difficultyName : string) : WaveTable?
	return tables[difficultyName]
end

--- How many waves the difficulty has; 0 if it has no module.
function Waves.Count(difficultyName : string) : number
	local waves = tables[difficultyName]
	return if waves then #waves else 0
end

return Waves
