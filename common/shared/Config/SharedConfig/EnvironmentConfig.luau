--[[
	The experiences the game is published to, one universe per environment, and
	the ids of the places inside each one.

	`Shared.Util.Environment` reads this table to find out, from `game.GameId`,
	which environment the server or client is running in, and which place ids a
	teleport should use there. Nothing else should read the ids directly.

	Every id here is public (it shows in the experience URL), so it is safe to
	replicate. The place keys, `Lobby`, `Game`, and `Afk`, are the same names the
	rest of the repository uses for the places. `Afk` is optional: an environment
	without it has no AFK place yet (`Environment.HasPlace`).

	See docs/common/environments.md.
]]

local module = {}

module.Environments = {
	Production = {
		UniverseId = 10340119210,
		Places = {
			Lobby = 132304466547289, -- "Periastron Tower Defense", the start place
			Game = 109030368179494, -- "Main Game"
			Afk = 80286820709620,
		},
	},

	QA = {
		UniverseId = 10767160215,
		Places = {
			Lobby = 80434020174775,
			Game = 131924395601623,
			Afk = 116470384978275, -- "AFK Station"
		},
	},
}

-- What an unknown universe is treated as: a loose `.rbxl` (`GameId == 0`) or a
-- universe missing from the table above. A teleport from there fails either way,
-- because a reserved server must be in the same universe as the caller.
module.FALLBACK = "Production"

return module
