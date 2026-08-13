local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Framework = require(Vendor.Me).new()
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))

local TargetingController = {
	Controllers = {}
}

TargetingController.ActiveUnits = {}
TargetingController.ActiveMobs = {}
TargetingController.SliceIndex = 1
TargetingController.UnitsPerFrame = 4

function TargetingController:RegisterUnit(unitClass)
	table.insert(self.ActiveUnits, unitClass)
end

function TargetingController:UnregisterUnit(unitClass)
	local index = table.find(self.ActiveUnits, unitClass)
	if index then
		table.remove(self.ActiveUnits, index)
	end
end

function TargetingController:RegisterMob(mobModel)
	table.insert(self.ActiveMobs, mobModel)
end

function TargetingController:UnregisterMob(mobModel)
	local index = table.find(self.ActiveMobs, mobModel)
	if index then
		table.remove(self.ActiveMobs, index)
	end
end

function TargetingController:FindBestTarget(unitPosition, maxRange)
	for _, mob in ipairs(self.ActiveMobs) do
		if not mob or not mob.Parent then continue end
		if (mob:GetPivot().Position - unitPosition).Magnitude <= maxRange then
			return mob
		end
	end
	return nil
end

function TargetingController:StartLoop()
	RunService.Heartbeat:Connect(function()
		local totalUnits = #self.ActiveUnits
		if totalUnits == 0 then return end

		local cycles = math.min(self.UnitsPerFrame, totalUnits)
		for _ = 1, cycles do
			if self.SliceIndex > totalUnits then
				self.SliceIndex = 1
			end

			local unitClass = self.ActiveUnits[self.SliceIndex]
			if unitClass and unitClass.model and unitClass.model.Parent then
				local unitPosition = unitClass.model:GetPivot().Position
				local range = SharedConfig.UnitUpgradeConfig:GetRange(unitClass.name, unitClass.upgrades or 0)

				local target = self:FindBestTarget(unitPosition, range)
				unitClass:setTarget(target)
			else
				table.remove(self.ActiveUnits, self.SliceIndex)
				totalUnits = #self.ActiveUnits
				self.SliceIndex -= 1
			end

			self.SliceIndex += 1
		end
	end)
end

function TargetingController:construct()
	self:StartLoop()
end

function TargetingController:start()
end

function TargetingController:init()
	self:construct()
end

return TargetingController
