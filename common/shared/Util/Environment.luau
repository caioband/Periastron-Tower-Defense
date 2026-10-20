--[[
	Which environment this server or client is running in, Production or QA, and
	the place ids that belong to it.

	The two environments are separate experiences (separate universes), each with
	its own Lobby and Game. The environment is read once, from `game.GameId` (the
	universe id), against `SharedConfig.EnvironmentConfig`.

		local Environment = require(Shared.Util.Environment)

		Environment.Name                   -- "Production" or "QA"
		Environment.GetPlaceId("Game")     -- the Game place of *this* universe
		Environment.IsPlace("Lobby")       -- is this server the Lobby of this universe?
		Environment.HasPlace("Afk")        -- does this universe have an AFK place?

	**Every teleport resolves its destination here.** A reserved server has to be
	in the caller's universe, so a QA Lobby that sent players to the production
	Game id would fail the teleport (or, without a reserved server, land them in
	production).

	**An unknown universe falls back to `EnvironmentConfig.FALLBACK`** and
	`Known` is `false`. That covers a loose `.rbxl` (`GameId == 0`), where there is
	nowhere to teleport anyway, and a universe that is missing from the config,
	which the server reports once with `log:Warn` because its teleports will fail.

	See docs/common/environments.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local Log = require(Shared.Util.Log)

local Config = SharedConfig.EnvironmentConfig
local log = Log.new("Environment")

export type EnvironmentName = "Production" | "QA"
export type PlaceName = "Lobby" | "Game" | "Afk" | "MapEditor"

local function resolve() : (EnvironmentName, boolean)
	for name, environment in Config.Environments do
		if environment.UniverseId == game.GameId then
			return name :: EnvironmentName, true
		end
	end

	if game.GameId == 0 then
		log:Debug(`unpublished place; using {Config.FALLBACK} place ids.`)
	elseif RunService:IsServer() then
		log:Warn(`universe {game.GameId} is not in EnvironmentConfig; using {Config.FALLBACK} place ids, so teleports will fail.`)
	end

	return Config.FALLBACK :: EnvironmentName, false
end

local name, known = resolve()
local places = Config.Environments[name].Places

local Environment = {
	-- "Production" or "QA". The fallback when the universe is unknown.
	Name = name,

	-- Whether `game.GameId` matched one of the environments in the config.
	Known = known,
}

--[[ API ]]

function Environment.IsProduction() : boolean
	return name == "Production"
end

function Environment.IsQA() : boolean
	return name == "QA"
end

--- Whether this environment has `place`. `Afk` and `MapEditor` are optional; check
--- before `GetPlaceId` with one of them.
function Environment.HasPlace(place : PlaceName) : boolean
	return places[place] ~= nil
end

--- The id of `place` in this environment. The id every teleport must use.
--- Errors when the environment does not have it (see `HasPlace`).
function Environment.GetPlaceId(place : PlaceName) : number
	local placeId = places[place]
	assert(placeId, `place '{tostring(place)}' is not configured for {name}`)

	return placeId
end

--- Whether this server or client is `place` of this environment. Always `false`
--- in an unpublished place, where `PlaceId` is 0, and for a place this
--- environment does not have.
function Environment.IsPlace(place : PlaceName) : boolean
	local placeId = places[place]

	return placeId ~= nil and game.PlaceId == placeId
end

--- The environment for a human to read: `"QA"`, or what an unknown universe
--- fell back to, so a console line never claims Production when it is not.
function Environment.Describe() : string
	if known then
		return name
	end

	return `unknown universe {game.GameId}, using {name} ids`
end

return Environment
