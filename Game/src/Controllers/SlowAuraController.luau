local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local Me = require(Vendor.Me)

local Framework = Me.new()

-- How often the rings are checked against the field, in real seconds. A ring follows an
-- upgrade, a weather change, or a sold tower within this, which reads as instant.
local REFRESH_INTERVAL = 0.2

-- The Workspace folder holding the rings. Local, not replicated: each client draws its own.
local CONTAINER_NAME = "SlowAuraRings"

--[=[
	The rings of units with `SlowAura` in `UnitStats` (the Cryomancer): the art in
	`Assets.VFX.Rings` on the ground around the unit, at the radius where the server
	slows enemies.

	The server rules the slow (`UnitService:stepSlowAuras`); this only draws it. The
	radius comes from `UnitPlacementController:getUnitRange`, the same circle the
	selection shows, weather and cards included, so the ring and the slow cannot
	disagree on where the edge is.

	A unit whose level gives no slow (`UnitUpgradeConfig:GetAuraSlow` at 0) draws no
	ring: a ring on the ground promises a slow that is not there.

	Polled instead of driven by events, like `BonfireController`: the inputs (placed
	units, their level attribute, weather, cards) each change through a different path,
	and comparing a handful of numbers a few times a second is cheaper than wiring all
	of them.
]=]
local SlowAuraController = {
	Controllers = {
		UnitPlacementController = {},
		CardModifierController = {},
	},

	-- unit model -> { ring, radius }: what is drawn now.
	rings = {},
}

function SlowAuraController:container() : Instance
	local existing = workspace:FindFirstChild(CONTAINER_NAME)
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = CONTAINER_NAME
	folder.Parent = workspace

	return folder
end

-- The ground under the unit: where its dotted line sits, which placement already
-- raycast. The pivot is the fallback, for a unit drawn before its line.
local function groundCenter(placement, model : Model) : Vector3
	local data = placement.dottedLineData and placement.dottedLineData[model]

	return data and data.centerPos or model:GetPivot().Position
end

function SlowAuraController:removeRing(model : Model)
	local state = self.rings[model]
	if not state then return end

	if state.ring then
		state.ring:Destroy()
	end

	self.rings[model] = nil
end

function SlowAuraController:refresh()
	local placement = self.Controllers.UnitPlacementController
	local cards = self.Controllers.CardModifierController
	local classes = placement and placement.createdClasses

	-- `start` can tick before `init` resolved the controllers (Me spawns both).
	if not classes or not cards or not cards.CreateRing then return end

	local seen = {}

	for model, class in classes do
		if not model.Parent then continue end

		local stats = SharedConfig.UnitStats[model.Name]
		local aura = stats and stats.SlowAura
		if not aura then continue end

		local level = model:GetAttribute("Upgrades") or 0
		if SharedConfig.UnitUpgradeConfig:GetAuraSlow(model.Name, level) <= 0 then continue end

		seen[model] = true

		local center = groundCenter(placement, model)
		local radius = placement:getUnitRange(model.Name, level, model:GetPivot().Position, class.unitId)
		local state = self.rings[model]

		if not state then
			local ring = cards:CreateRing(aura.Ring, radius, center, self:container())
			self.rings[model] = { ring = ring, radius = radius }
		elseif state.ring and math.abs(state.radius - radius) > 0.01 then
			cards:ResizeRing(state.ring, radius)
			state.radius = radius
		end
	end

	-- Sold, moved (Zippers swaps the model), or back to no slow.
	for model in self.rings do
		if not seen[model] then
			self:removeRing(model)
		end
	end
end

function SlowAuraController:start()
	local elapsed = REFRESH_INTERVAL

	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < REFRESH_INTERVAL then return end
		elapsed = 0

		self:refresh()
	end)
end

function SlowAuraController:init()
	for name, _ in self.Controllers do
		self.Controllers[name] = Framework:Get(name, false, true)
	end
end

return SlowAuraController
