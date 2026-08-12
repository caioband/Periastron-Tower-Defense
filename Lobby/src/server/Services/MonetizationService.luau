local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(Configs.Server)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local MonetizationService = {
	Services = {
		DataService = {},
	}
}

function MonetizationService:construct()
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local ProductId = receiptInfo.ProductId
		local Player = Players:GetPlayerByUserId(receiptInfo.PlayerId)

		local didFindProfile
		self.Services.DataService:Get(Player, function(profile)
			didFindProfile = true
		end)
		if not didFindProfile then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local foundCallback : () -> () = self.Callbacks[tostring(ProductId)]
		if not foundCallback then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		task.spawn(foundCallback, Player)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

function MonetizationService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function MonetizationService:RecalibratePasses(Player : Player)
	self.Services.DataService:Get(Player, function(Profile)
		local GamePasses = Profile.Data.Gamepasses or {}

	end)
end

function MonetizationService:init()

end

return MonetizationService
