local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local ServerVendor = ServerScriptService:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

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
	self.Callbacks = {}

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local profileLoaded = false
		self.Services.DataService:Get(player, function()
			profileLoaded = true
		end)
		if not profileLoaded then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local purchaseKey = "P_" .. tostring(receiptInfo.PurchaseId)

		local alreadyGranted = false
		self.Services.DataService:Update(player, "PurchaseHistory", function(history)
			history = history or {}
			alreadyGranted = history[purchaseKey] == true
			return history
		end)
		if alreadyGranted then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		local callback = self.Callbacks[tostring(receiptInfo.ProductId)]
		if not callback then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local granted = false
		local ok = pcall(function()
			granted = callback(player, receiptInfo) ~= false
		end)
		if not ok or not granted then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		self.Services.DataService:Update(player, "PurchaseHistory", function(history)
			history = history or {}
			history[purchaseKey] = true
			return history
		end)

		if not self.Services.DataService:Save(player) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

function MonetizationService:RegisterProduct(productId, callback)
	self.Callbacks[tostring(productId)] = callback
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
