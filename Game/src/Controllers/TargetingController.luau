local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Framework = require(Vendor.Me).new()
local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local TargetPriority = SharedConfig.TargetPriority
local PathUtil = require(Shared:WaitForChild("Util"):WaitForChild("PathUtil"))

-- Ver `NODE_PROGRESS_REFRESH` do `MobService`: os dois lados releem o node do
-- mob no mesmo ritmo.
local NODE_PROGRESS_REFRESH = 0.1

local TargetingController = {
	Controllers = {
		WeatherController = {}
	}
}

TargetingController.ActiveUnits = {}
TargetingController.ActiveMobs = {}
TargetingController.SliceIndex = 1
TargetingController.UnitsPerFrame = 4
-- Avanco de cada mob pelo caminho, por modelo: { value, clock }.
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
	Os nodes do caminho, emprestados do `MobController` -- quem monta as rotas no
	cliente e ele, e montar de novo aqui daria duas copias da mesma geometria.

	Busca sem yield e guardada na primeira vez que der certo: este controller e o
	`MobController` se referenciam, e esperar um pelo outro no `init` travaria os
	dois.
]=]
function TargetingController:getNodeDistances()
	if not self.mobController then
		self.mobController = Framework:Get("MobController", false, false)
	end

	return self.mobController and self.mobController:getNodeDistances()
end

--[=[
	O quanto o mob ja andou do caminho, em cache pelo mesmo motivo do servidor: a
	conta roda por unidade e por mob, e o node do mob nao muda a cada quadro.
]=]
function TargetingController:getMobPathProgress(mob, position : Vector3, nodeDistances)
	local now = os.clock()
	local cached = self.MobProgress[mob]

	if cached and now - cached.clock < NODE_PROGRESS_REFRESH then
		return cached.value
	end

	local value = PathUtil.GetNodeProgress(nodeDistances, position)
	self.MobProgress[mob] = { value = value, clock = now }

	return value
end

--[=[
	O alvo que a unidade encara. Quem decide o dano e o servidor; aqui e so para
	onde a unidade olha -- por isso o criterio tem que ser o MESMO dos dois lados,
	e ele vem do `TargetPriority` compartilhado. A vida de cada mob e lida do
	atributo que o `MobController` mantem no modelo.
]=]
function TargetingController:FindBestTarget(unitPosition, maxRange, priority)
	local bestMob = nil
	local best = nil

	-- So o `Farthest` olha o caminho; nos outros modos nem se pede a lista.
	local nodeDistances = TargetPriority.UsesPathProgress(priority) and self:getNodeDistances() or nil

	for _, mob in ipairs(self.ActiveMobs) do
		if not mob or not mob.Parent then continue end

		local mobPosition = mob:GetPivot().Position
		local distance = (mobPosition - unitPosition).Magnitude
		if distance > maxRange then continue end

		local candidate = { distance = distance, health = mob:GetAttribute("Health") or 0 }

		if nodeDistances then
			-- Do centro do modelo para o chao, que e de onde o servidor mede.
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

		-- Uma leitura por quadro: o alcance da neblina vale para todas as unidades
		-- da fatia, e consultar por unidade so gastaria.
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
				local range = SharedConfig.UnitUpgradeConfig:GetRange(unitClass.name, unitClass.upgrades or 0, weather)

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
