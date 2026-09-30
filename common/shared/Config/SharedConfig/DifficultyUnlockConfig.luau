--[[
	The difficulty locks: who may vote for what.

	Easy and Medium are not in the table: **a difficulty without an entry is
	open**, and that is where every new player starts. The top three require one
	of two things, and **one** is enough:

		| Difficulty | Wins                | or Level |
		| Hard       | 4 on Medium         |        3 |
		| Impossible | 4 on Hard           |        6 |
		| Nightmare  | 6 on Impossible     |       12 |

	The two sources measure different things. Wins on the difficulty below say the
	player **can handle** it: the short path for players doing well. Level is the
	safety net: XP is earned on losses and abandoned runs too (see
	`WaveService.computeReward`), and wins alone would keep a struggling player on
	Medium forever.

	`Wins` counts the **difficulty below**, not the one being unlocked (there is no
	winning on Nightmare before it opens), so the wins path is sequential while the
	level path can skip steps.

	Wins per difficulty live in the profile's `Stats.DifficultyWins`
	(`{ [difficulty] = count }`), written only by `WaveService` at the end of a won
	run. Level is not stored: it comes from `Stats.XP` through `LevelConfig:Resolve`,
	as in the Lobby HUD.

	Nothing here is secret, so this file is in the shared config and not with the
	presets (`ServerScriptService.Config.Difficulty`). Both sides run the same math,
	as with maps: `DifficultyController` draws `Locked` with it and
	`DifficultyService` refuses the vote with it.

	See docs/game/difficulty-vote.md.
]]

local LevelConfig = require(script.Parent.LevelConfig)

local module = {}

--[=[
	The profile key where wins per difficulty live. Written here so `WaveService`
	and this module's reads cannot drift apart.
]=]
module.WINS_KEY = "DifficultyWins"

export type Requirement = {
	Wins : number,
	WinsIn : string,
	Level : number,
}

module.REQUIREMENTS = {
	Hard = { Wins = 4, WinsIn = "Medium", Level = 3 },
	Impossible = { Wins = 4, WinsIn = "Hard", Level = 6 },
	Nightmare = { Wins = 6, WinsIn = "Impossible", Level = 12 },
	Endless = { Wins = 2, WinsIn = "Nightmare", Level = 15 },
} :: { [string] : Requirement }

--[[ API ]]

--[=[
	What the difficulty requires, or nil when it is open.
]=]
function module.getRequirement(difficultyName : string?) : Requirement?
	if typeof(difficultyName) ~= "string" then
		return nil
	end

	return module.REQUIREMENTS[difficultyName]
end

--[=[
	How many wins the player has **on that** difficulty.

	A profile not loaded yet, or a key that does not exist yet, counts as zero:
	the same guess as maps, so only what is open shows open, never the reverse.
]=]
function module.winsIn(stats : { [string] : any }?, difficultyName : string?) : number
	if typeof(stats) ~= "table" or typeof(difficultyName) ~= "string" then
		return 0
	end

	local wins = stats[module.WINS_KEY]
	if typeof(wins) ~= "table" then
		return 0
	end

	return math.max(math.floor(tonumber(wins[difficultyName]) or 0), 0)
end

--[=[
	The profile's level, derived from accumulated XP. Without a profile, level 1.
]=]
function module.levelOf(stats : { [string] : any }?) : number
	local xp = typeof(stats) == "table" and stats.XP or 0

	return LevelConfig:Resolve(xp).Level
end

--[=[
	Whether this player may already pick the difficulty.

	Either requirement is enough. A difficulty with no requirement is always open,
	and an unknown name passes too: the caller already handled invalid names (the
	server's `DifficultyConfig.Exists`), and locking here would hide a button by
	mistake.
]=]
function module.isUnlocked(difficultyName : string?, stats : { [string] : any }?) : boolean
	local requirement = module.getRequirement(difficultyName)
	if not requirement then
		return true
	end

	if module.winsIn(stats, requirement.WinsIn) >= requirement.Wins then
		return true
	end

	return module.levelOf(stats) >= requirement.Level
end

--[=[
	How many wins are still missing on the wins path, or zero when the difficulty
	is open. The number the padlock text writes.
]=]
function module.winsMissing(difficultyName : string?, stats : { [string] : any }?) : number
	local requirement = module.getRequirement(difficultyName)
	if not requirement or module.isUnlocked(difficultyName, stats) then
		return 0
	end

	return math.max(requirement.Wins - module.winsIn(stats, requirement.WinsIn), 0)
end

--[=[
	The `Locked` text: "4 more wins in Medium or Level 3".

	Empty for an open or unlocked difficulty (the frame is not even on screen then).
	Both paths appear together on purpose: the player must see there is a way out
	that does not depend on winning.
]=]
function module.lockText(difficultyName : string?, stats : { [string] : any }?) : string
	local requirement = module.getRequirement(difficultyName)
	if not requirement or module.isUnlocked(difficultyName, stats) then
		return ""
	end

	local missing = module.winsMissing(difficultyName, stats)

	return string.format(
		"%d more %s in %s or Level %d",
		missing,
		missing == 1 and "win" or "wins",
		requirement.WinsIn,
		requirement.Level)
end

return module
