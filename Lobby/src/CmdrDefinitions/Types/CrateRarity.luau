--[[
	cmdr type "crateRarity" / "crateRarities".

	Registered on the server through Registry:RegisterTypesIn, which replicates this
	module into ReplicatedStorage.CmdrClient.Types so the client registers it too.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = Configs:WaitForChild("SharedConfig")

local CrateConfig = require(SharedConfig:WaitForChild("CrateConfig"))

return function(registry)
	local Util = registry.Cmdr.Util

	local rarityType = Util.MakeEnumType("CrateRarity", CrateConfig.RARITIES)

	registry:RegisterType("crateRarity", rarityType)
	registry:RegisterType("crateRarities", Util.MakeListableType(rarityType))
end
