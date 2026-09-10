--[[
	Configuração compartilhada — replicada para o cliente.

	Só entra aqui o que o cliente legitimamente precisa ler. O que é sigiloso
	(chave de DataStore, template de perfil, tabelas de wave, odds de summon,
	lista de admins) vive em `ServerScriptService.Config`.
]]

type Shared = {
	UnitStats : typeof(require(script.UnitStats)),
	RarityConfig : typeof(require(script.RarityConfig)),
	CrateConfig : typeof(require(script.CrateConfig)),
	MapConfig : typeof(require(script.MapConfig)),
	PortalConfig : typeof(require(script.PortalConfig)),
	Mob : typeof(require(script.Mob)),
	TargetPriority : typeof(require(script.TargetPriority)),
	LevelConfig : typeof(require(script.LevelConfig)),
	DifficultyUnlockConfig : typeof(require(script.DifficultyUnlockConfig)),
	IndexConfig : typeof(require(script.IndexConfig)),
	Cmdr : typeof(require(script.Cmdr)),
	SellValue : number,
	SellRefundRatio : number,
}

local Shared : Shared = {
	SellValue = 50,
	SellRefundRatio = 0.5,
	MobReward = { Min = 2, Max = 5 },
	ArrowConfig = {
		Speed = 80,
		Count = 2,
		Stagger = 1,
		YOffset = 0.2,
		Buffer = 0.6,
	},
}
for _, module in script:GetChildren() do
	local requiredInfo = require(module)

	Shared[module.Name] = requiredInfo
end
return Shared :: Shared
