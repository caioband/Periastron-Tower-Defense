local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Framework = require(Vendor.Me).new()
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local TargetPriority = SharedConfig.TargetPriority

local TargetingController = {
	Controllers = {
		WeatherController = {},
		UnitPlacementController = {},
	}
}

TargetingController.ActiveUnits = {}
TargetingController.ActiveMobs = {}
TargetingController.SliceIndex = 1
TargetingController.UnitsPerFrame = 4

local scratchA = { distance = 0, health = 0, progress = 0 }
local scratchB = { distance = 0, health = 0, progress = 0 }

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
	self.ActiveMobs[mobModel] = true
end

function TargetingController:UnregisterMob(mobModel)
	self.ActiveMobs[mobModel] = nil
end

function TargetingController:ClearMobs()
	table.clear(self.ActiveMobs)
end

function TargetingController:getMobController()
	if not self.mobController then
		self.mobController = Framework:Get("MobController", false, false)
	end

	return self.mobController
end

function TargetingController:FindBestTarget(unitPosition, maxRange, priority)
	local bestMob = nil
	local best = nil
	local candidate = scratchA

	local mobController = self:getMobController()

	for mob in self.ActiveMobs do
		if not mob.Parent then
			self.ActiveMobs[mob] = nil
			continue
		end

		local distance = (mob:GetPivot().Position - unitPosition).Magnitude
		if distance > maxRange then continue end

		candidate.distance = distance
		candidate.health = mob:GetAttribute("Health") or 0
		candidate.progress = mobController and mobController:GetPathDistance(mob) or 0

		if TargetPriority.IsBetter(priority, candidate, best) then
			best = candidate
			bestMob = mob
			candidate = if candidate == scratchA then scratchB else scratchA
		end
	end

	return bestMob
end

function TargetingController:StartLoop()
	RunService.Heartbeat:Connect(function()
		local totalUnits = #self.ActiveUnits
		if totalUnits == 0 then return end

		local weatherController = self.Controllers.WeatherController
		local weather = weatherController and weatherController:GetCurrent() or nil

		local cycles = math.min(self.UnitsPerFrame, totalUnits)
		for _ = 1, cycles do
			if self.SliceIndex > totalUnits then
				self.SliceIndex = 1
			end

			local unitClass = self.ActiveUnits[self.SliceIndex]
			if unitClass and unitClass.model and unitClass.model.Parent then
				local unitPosition = unitClass.model:GetPivot().Position
				local placement = self.Controllers.UnitPlacementController
				local range = if placement
					then placement:getUnitRange(unitClass.name, unitClass.upgrades or 0, unitPosition, unitClass.unitId)
					else SharedConfig.UnitUpgradeConfig:GetRange(unitClass.name, unitClass.upgrades or 0, weather)

				local target = self:FindBestTarget(unitPosition, range, unitClass.model:GetAttribute("TargetPriority"))
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
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return TargetingController