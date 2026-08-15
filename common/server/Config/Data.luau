-- Este modulo vive em ServerScriptService.Config, entao o caminho ate o config
-- compartilhado precisa ser absoluto (antes era `script.Parent.Parent`, quando
-- ele ficava dentro de ReplicatedStorage.Shared.Config).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig")
local CrateConfig = require(SharedConfig:WaitForChild("CrateConfig"))

return {
	PROFILE_KEY = "profi555",
	Template = {
		Stats = {
			Wins = 0,
			Cash = 0,

			-- Moeda premium. Perfis antigos ganham a chave pelo reconcile do
			-- DataService, entao nao precisa migracao.
			Shards = 0,
			XP = 0,
		},

		Inventory = {
			-- { [Rarity] = amount } for every rarity in CrateConfig.RARITIES
			Crates = CrateConfig.createEmptyCrates(),
		},

		PurchaseHistory = {},
		Index = {},
		Units = {
			["Entrepreneur"] = 2,
			["Slingshot"] = 2,
			["Subspace Tripminer"] = 2,
			["Sword"] = 2,
			["Rocket"] = 2,
		},
		EquippedUnits = {}
	},

	STARTING_CASH = 500,

	--[[
		Recompensa de fim de partida. Os tres sao escalados pela fracao de waves
		sobrevividas e pelos multiplicadores da dificuldade.
	]]
	BASE_WINNING_CASH = 1000,
	BASE_WINNING_SHARDS = 30,
	BASE_WINNING_XP = 200,

	-- Shards so comecam a cair depois desta fracao da run, e dai crescem por uma
	-- curva em vez de linearmente: e a moeda cara, entao quase todo o ganho vem de
	-- chegar perto do fim. Com 0.5 e curva 2, largar na metade rende zero e a
	-- wave 12 de 15 rende ~36% do total.
	SHARD_WAVE_THRESHOLD = 0.5,
	SHARD_CURVE = 2,

	MAX_WAVES = 15,
	CASH_PER_DAMAGE = 1,
	CASH_PER_KILL_MIN = 3,
	CASH_PER_KILL_MAX = 6,
	MAX_DATA_TIME_OUT = 20,
}
