local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs:WaitForChild("SharedConfig"))

local ids = SharedConfig.SkinConfig.ordered()

return function(registry)
	registry:RegisterType("skinName", registry.Cmdr.Util.MakeEnumType("SkinName", ids))
	registry:RegisterType("skinAction", registry.Cmdr.Util.MakeEnumType("SkinAction", { "give", "take", "equip", "unequip" }))
end