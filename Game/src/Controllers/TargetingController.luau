local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Framework = require(Vendor.Me).new()
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local TargetPriority = SharedConfig.TargetPriority
local PathUtil = require(Shared:WaitForChild("Util"):WaitForChild("PathUtil"))
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

-- See `MobService`'s `NODE_PROGRESS_REFRESH`: both sides reread the enemy's node
-- at the same pace.
local NODE_PROGRESS_REFRESH = 0.1

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
-- Each enemy's progress along the path, per model: { value, clock }.
TargetingController.MobProgress = {}

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

	self.MobProgress[mobModel] = nil
end

--[=[
	The path nodes, borrowed from `MobController`: it builds the routes on the client,
	and building them again here would give two copies of the same geometry.

	A non-yielding lookup, cached the first time it succeeds: this controller and
	`MobController` reference each other, and waiting for one another in `init` would
	block both.
]=]
function TargetingController:getNodeDistances()
	if not self.mobController then
		self.mobController = Framework:Get("MobController", false, false)
	end

	return self.mobController and self.mobController:getNodeDistances()
end

--[=[
	How far the enemy has gone along the path, cached for the same reason as on the
	server: the math runs per unit and per enemy, and an enemy's node does not change
	every frame.
]=]
function TargetingController:getMobPathProgress(mob, position : Vector3, nodeDistances)
	-- Match time, as on the server: sped up, the enemy walks more per real second, and
	-- a cache tied to the wall clock would age out of step.
	local now = GameClock.Now()
	local cached = self.MobProgress[mob]

	if cached and now - cached.clock < NODE_PROGRESS_REFRESH then
		return cached.value
	end

	local value = PathUtil.GetNodeProgress(nodeDistances, position)
	self.MobProgress[mob] = { value = value, clock = now }

	return value
end

--[=[
	The target the unit faces. The server decides damage; this is only where the unit
	looks, which is why the criterion must be the SAME on both sides, and it comes
	from the shared `TargetPriority`. Each enemy's health is read from the attribute
	`MobController` keeps on the model.
]=]
function TargetingController:FindBestTarget(unitPosition, maxRange, priority)
	local bestMob = nil
	local best = nil

	-- Only `Farthest` looks at the path; the other modes do not even ask for the list.
	local nodeDistances = TargetPriority.UsesPathProgress(priority) and self:getNodeDistances() or nil

	for _, mob in ipairs(self.ActiveMobs) do
		if not mob or not mob.Parent then continue end

		local mobPosition = mob:GetPivot().Position
		local distance = (mobPosition - unitPosition).Magnitude
		if distance > maxRange then continue end

		local candidate = { distance = distance, health = mob:GetAttribute("Health") or 0 }

		if nodeDistances then
			-- From the model's center to the ground, which is where the server measures from.
			local pathPosition = mobPosition - Vector3.new(0, mob:GetAttribute("PathOffsetY") or 0, 0)
			candidate.progress = self:getMobPathProgress(mob, pathPosition, nodeDistances)
		end

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
