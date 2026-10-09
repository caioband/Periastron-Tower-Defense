--[[
	cmdr type "runeName": a rune `Id` from `SharedConfig.RuneConfig` (`Shards`).

	Built from the config, so a new rune shows up in tab completion without
	touching this file. Cmdr's `MakeEnumType` does fuzzy matching: `sh` already
	resolves to `Shards`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs:WaitForChild("SharedConfig"))

local ids = {}
for _, rune in SharedConfig.RuneConfig.Runes do
	table.insert(ids, rune.Id)
end

return function(registry)
	registry:RegisterType("runeName", registry.Cmdr.Util.MakeEnumType("RuneName", ids))
end
