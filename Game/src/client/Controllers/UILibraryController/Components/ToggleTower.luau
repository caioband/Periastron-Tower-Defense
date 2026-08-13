local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)
local CardUpgrade = Interface:WaitForChild("CardUpgrade")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Spring = require(Vendor.Spring)
local Me = require(Vendor.Me)

local Framework = Me.new()

local SELL_CASH_VALUE = 50

local module = {}
module.currentUnit = nil

function module:create(unitModel, ...)
	if self.maid then
		self.maid:Destroy()
		self.maid = nil
	end

	if self.tasks then
		for index, taskInst in self.tasks do
			task.cancel(taskInst)
			self.tasks[index] = nil
		end
	end

	self.maid = Maid.new()
	self.currentUnit = unitModel

	local sellButton = CardUpgrade:FindFirstChild("Sell")
	if sellButton and self.sellConnection then
		self.sellConnection:Disconnect()
		self.sellConnection = nil
	end

	if sellButton and unitModel then
		self.sellConnection = sellButton.MouseButton1Up:Connect(function()
			local unitId = unitModel:GetAttribute("UnitID")
			Framework:Fire("SellUnit", unitId)
			self:destroy()
		end)
		self.maid:GiveTask(function()
			if self.sellConnection then
				self.sellConnection:Disconnect()
				self.sellConnection = nil
			end
		end)
	end

	local upgradeButton = CardUpgrade:FindFirstChild("UpgradeCost")
	if self.upgradeConnection then
		self.upgradeConnection:Disconnect()
		self.upgradeConnection = nil
	end

	if upgradeButton and unitModel then
		self.upgradeConnection = upgradeButton.MouseButton1Up:Connect(function()
			local level = unitModel:GetAttribute("Upgrades") or 0
			if SharedConfig.UnitUpgradeConfig:IsMaxed(level) then return end
			local unitId = unitModel:GetAttribute("UnitID")
			Framework:Fire("UpgradeUnit", unitId)
		end)
		self.maid:GiveTask(function()
			if self.upgradeConnection then
				self.upgradeConnection:Disconnect()
				self.upgradeConnection = nil
			end
		end)

		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("Upgrades"):Connect(function()
			self:refreshUpgrade()
		end))
	end

	self:refreshUpgrade()

	CardUpgrade.Position = UDim2.fromScale(1.2, CardUpgrade.Position.Y.Scale)

	Spring.target(CardUpgrade, .65, 4, {
		Position = UDim2.fromScale(0.85, CardUpgrade.Position.Y.Scale)
	})
	CardUpgrade.Visible = true
end

function module:refreshUpgrade()
	local unitModel = self.currentUnit
	local upgradeButton = CardUpgrade:FindFirstChild("UpgradeCost")
	if not upgradeButton then return end
	local label = upgradeButton:FindFirstChild("TextLabel")
	if not label then return end

	if not unitModel or not unitModel.Parent then
		label.Text = ""
		return
	end

	CardUpgrade.Info.UnitName.Text = unitModel.Name
	CardUpgrade.Info.UnitLevel.Text = "LVL." .. (unitModel:GetAttribute("Upgrades") or 0)

	local level = unitModel:GetAttribute("Upgrades") or 0
	if SharedConfig.UnitUpgradeConfig:IsMaxed(level) then
		label.Text = "MAX"
	else
		local cost = SharedConfig.UnitUpgradeConfig:GetCost(unitModel.Name, level)
		label.Text = "$" .. cost
	end
end

function module:destroy()
	self.currentUnit = nil
	if self.maid then
		self.maid:Destroy()
	end

	if not self.tasks then
		self.tasks = {}
	end

	self.maid = nil

	Spring.target(CardUpgrade, .65, 4, {
		Position = UDim2.fromScale(1.2, CardUpgrade.Position.Y.Scale)
	})

	local conn
	conn = task.delay(1, function()
		CardUpgrade.Visible = false
		self.delayTask = nil
		table.remove(self.tasks, table.find(self.tasks, conn))
	end)
	table.insert(self.tasks, conn)
end

return module
