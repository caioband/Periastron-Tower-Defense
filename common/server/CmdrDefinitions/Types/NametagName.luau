local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs:WaitForChild("SharedConfig"))

local ids = SharedConfig.NametagConfig.ordered()

return function(registry)
	registry:RegisterType("nametagName", registry.Cmdr.Util.MakeEnumType("NametagName", ids))
	registry:RegisterType("nametagAction", registry.Cmdr.Util.MakeEnumType("NametagAction", { "give", "take", "equip", "unequip" }))
end