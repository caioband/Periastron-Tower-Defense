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
	BASE_WINNING_CASH = 1000,
	MAX_WAVES = 15,
	CASH_PER_DAMAGE = 1,
	CASH_PER_KILL_MIN = 3,
	CASH_PER_KILL_MAX = 6,
	MAX_DATA_TIME_OUT = 20,
}
