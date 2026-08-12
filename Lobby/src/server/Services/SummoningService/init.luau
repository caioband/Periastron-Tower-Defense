local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(Configs.Server)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Shared.Me)

local SummoningUtil = require(script:WaitForChild("Util"))

local Framework = Me.new()

local SummoningService = {
	Services = {
		DataService = {},
	}
}

function SummoningService:summonUnit(Player : Player, bannerName : string)
	local cost, currency = SummoningUtil:_getCostOfBanner(bannerName)
	if not cost then
		Framework:Fire("SummonResult", Player, { Success = false, Reason = "InvalidBanner" })
		return
	end

	self.Services.DataService:Get(Player, function(data)
		local balance = data.Stats[currency] or 0
		if balance < cost then
			Framework:Fire("SummonResult", Player, { Success = false, Reason = "NotEnoughCurrency" })
			return
		end

		local rolledUnit = SummoningUtil:rollUnit(bannerName)
		if not rolledUnit then
			Framework:Fire("SummonResult", Player, { Success = false, Reason = "EmptyPool" })
			return
		end

		self.Services.DataService:Update(Player, "Stats", function(stats)
			stats[currency] = (stats[currency] or 0) - cost
			return stats
		end)

		self.Services.DataService:Update(Player, "Units", function(units)
			units[rolledUnit.Name] = (units[rolledUnit.Name] or 0) + 1
			return units
		end)

		Framework:Fire("SummonResult", Player, {
			Success = true,
			Banner = bannerName,
			Unit = rolledUnit.Name,
			Rarity = rolledUnit.Rarity,
		})
	end)
end

function SummoningService:construct()
	Framework:Listen("SummonUnit", function(Player : Player, bannerName : string)
		self:summonUnit(Player, bannerName)
	end)
end

function SummoningService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function SummoningService:init()

end

return SummoningService
