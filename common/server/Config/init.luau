--[[
	Server-only configuration.

	Mounted at `ServerScriptService.Config`, NEVER in ReplicatedStorage. Nothing here
	replicates to the client: the DataStore key, the profile template, wave tables,
	summon odds, crate pools, the Cmdr admin list, the analytics funnel numbering,
	and badge ids.

	Data the client legitimately needs lives in
	`ReplicatedStorage.Shared.Config.SharedConfig`.

	See docs/architecture/configuration.md.
]]

type ServerConfig = {
	Data : typeof(require(script.Data)),
	Wave : typeof(require(script.Wave)),
	Difficulty : typeof(require(script.Difficulty)),
	Summon : typeof(require(script.Summon)),
	Crate : typeof(require(script.Crate)),
	Cmdr : typeof(require(script.Cmdr)),
	Leaderboard : typeof(require(script.Leaderboard)),
	Analytics : typeof(require(script.Analytics)),
	Badges : typeof(require(script.Badges)),
}

local ServerConfig : ServerConfig = {}
for _, module in script:GetChildren() do
	local requiredInfo = require(module)

	ServerConfig[module.Name] = requiredInfo
end
return ServerConfig :: ServerConfig
