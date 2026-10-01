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

		-- The one that knows a unit's real range: the table's, with weather and round
		-- cards. See the aiming loop.
		UnitPlacementController = {},
	}
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

--[=[
	`MobController`, borrowed: it owns each enemy's walk, and the path distance the
	priorities compare comes from it (`GetPathDistance`).

	A non-yielding lookup, cached the first time it succeeds: this controller and
	`MobController` reference each other, and waiting for one another in `init` would
	block both.
]=]
function TargetingController:getMobController()
	if not self.mobController then
		self.mobController = Framework:Get("MobController", false, false)
	end

	return self.mobController
end

--[=[
	The target the unit faces. The server decides damage; this is only where the unit
	looks, which is why the criterion must be the SAME on both sides, and it comes
	from the shared `TargetPriority`. Each enemy's health is read from the attribute
	`MobController` keeps on the model, and its progress from `GetPathDistance`, the
	client's twin of the server's `mob.Distance`.
]=]
function TargetingController:FindBestTarget(unitPosition, maxRange, priority)
	local bestMob = nil
	local best = nil

	local mobController = self:getMobController()

	for _, mob in ipairs(self.ActiveMobs) do
		if not mob or not mob.Parent then continue end

		local mobPosition = mob:GetPivot().Position
		local distance = (mobPosition - unitPosition).Magnitude
		if distance > maxRange then continue end

		local candidate = {
			distance = distance,
			health = mob:GetAttribute("Health") or 0,
			progress = mobController and mobController:GetPathDistance(mob) or 0,
		}

		if TargetPriority.IsBetter(priority, candidate, best) then
			best = candidate
			bestMob = mob
		end
	end

	return bestMob
end

function TargetingController:StartLoop()
	RunService.Heartbeat:Connect(function()
		local totalUnits = #self.ActiveUnits
		if totalUnits == 0 then return end

		-- One read per frame: the fog's range applies to every unit in the slice, and
		-- querying per unit would only waste.
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
				--[[
					Range goes through `UnitPlacementController` so round cards apply to it:
					the server aims with the card-adjusted range, and this loop makes the
					model look at the target. Diverging would have the unit facing an enemy
					it cannot reach (or with its back to one it can).
				]]
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