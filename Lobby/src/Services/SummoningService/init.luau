local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local SummoningUtil = require(script:WaitForChild("Util"))

local Framework = Me.new()

local SummoningService = {
	Services = {
		DataService = {},
		IndexService = {},
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

		-- Mesmo gatilho da caixa: obter a unit e o que a descobre no Index.
		if self.Services.IndexService then
			self.Services.IndexService:UnlockUnit(Player, rolledUnit.Name)
		end

		Framework:Fire("SummonResult", Player, {
			Success = true,
			Banner = bannerName,
			Unit = rolledUnit.Name,
			-- O banner só define o peso; a raridade é a da própria unit.
			Rarity = SharedConfig.UnitStats[rolledUnit.Name].Rarity,
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
