local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(Configs.Server)

local RANDOM = Random.new()

local util = {}

function util:_getBanner(name : string)
	return ServerConfig.Summon.BANNERS[name]
end

function util:_getCostOfBanner(name : string)
	local banner = ServerConfig.Summon.BANNERS[name]
	if not banner then
		return nil
	end

	return banner.Cost, banner.Currency or "Cash"
end

function util:_getPool(name : string)
	return ServerConfig.Summon.ITEMS[name]
end

function util:rollUnit(name : string)
	local pool = ServerConfig.Summon.ITEMS[name]
	if not pool then
		return nil
	end

	local totalWeight = 0
	for _, item in pool do
		totalWeight += (item.Weight or 0)
	end

	if totalWeight <= 0 then
		return nil
	end

	local roll = RANDOM:NextNumber(0, totalWeight)
	local cumulative = 0
	for _, item in pool do
		cumulative += (item.Weight or 0)
		if roll <= cumulative then
			return item
		end
	end

	return pool[#pool]
end

return util
