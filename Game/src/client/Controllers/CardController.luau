local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local DEFAULT_HOTBAR_TEMPLATE = {
	[1] = "Slasher",
	[2] = "Azure",
	[3] = "Subspace Tripminer",
	[4] = "Sword",
	[5] = "Rocket",
}

local ExampleController = {
	Controllers = {
		DataController = {},
		UnitPlacementController = {},
		UILibraryController = {},
	},
	CardCounts = {},
}

function ExampleController:setUnequipState()
	self.Equipped = nil
end

function ExampleController:replicateUnitsToHotbar()

end

function ExampleController:construct()
	local function onDataPacketReceived()
		local Replica = self.Controllers.DataController:GetReplica()
		local Profile = Replica.Data

		local Hotbar = {}
		for unitName, _ in pairs(Profile.Units or {}) do
			table.insert(Hotbar, unitName)
		end
		table.sort(Hotbar)
		if #Hotbar <= 0 then Hotbar = DEFAULT_HOTBAR_TEMPLATE end
		self.Controllers.UILibraryController:doComponent("Card", "set", Hotbar, self.CardCounts, function(unitName : string)
			print("Attempting to equip unit:", unitName)

			if (self.CardCounts[unitName] or 0) <= 0 then return end

			if self.Equipped and self.Equipped == unitName then
				self.Equipped = nil
				self.Controllers.UnitPlacementController:unequip()
				return
			end
			if self.Equipped then
				self.Controllers.UnitPlacementController:unequip()
			end
			self.Controllers.UnitPlacementController:visualize(unitName)
			self.Equipped = unitName
		end)
	end


	self.Controllers.DataController:OnConnectChange({"EquippedUnits"}, function()
		onDataPacketReceived()
	end)
	self.Controllers.DataController:OnConnectChange({"Units"}, function()
		onDataPacketReceived()
	end)

	Framework:Listen("UpdateCardCounts", function(unitName, count)
		self.CardCounts[unitName] = count
		self.Controllers.UILibraryController:doComponent("Card", "setCount", unitName, count)
	end)
	Framework:Fire("RequestCardCounts")

	task.spawn(function()
		onDataPacketReceived()
	end)
end

function ExampleController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

function ExampleController:init()

end

return ExampleController
