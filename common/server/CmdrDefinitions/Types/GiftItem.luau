local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local GiftConfig = SharedConfig.GiftConfig

return function(registry)
	local keys = {}

	for key, item in GiftConfig.ITEMS do
		if GiftConfig.isEnabled(item) then
			table.insert(keys, key)
		end
	end

	table.sort(keys)

	registry:RegisterType("giftItem", registry.Cmdr.Util.MakeEnumType("GiftItem", keys))
end