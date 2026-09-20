--[[
	Configuração exclusiva do servidor.

	Monta em `ServerScriptService.Config` — NUNCA na ReplicatedStorage. Nada aqui
	é replicado para o cliente: chave de DataStore, template de perfil, tabelas de
	wave, odds de summon, pools das crates, a lista de admins do Cmdr e a
	numeração do funil de analytics.

	Dado que o cliente precisa legitimamente ver vive em
	`ReplicatedStorage.Shared.Config.SharedConfig`.
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
}

local ServerConfig : ServerConfig = {}
for _, module in script:GetChildren() do
	local requiredInfo = require(module)

	ServerConfig[module.Name] = requiredInfo
end
return ServerConfig :: ServerConfig
