local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.WeatherConfig.Thunder
local WeatherConfig = SharedConfig.WeatherConfig

--[[
	Raios do clima de trovao.

	Enquanto o clima do `Config.Weather` estiver ligado, cai um raio a cada
	`Config.Interval` segundos. Onde ele cai e sorteado: ou em cima de uma unidade
	posicionada, ou num ponto qualquer dentro da BoundingBox do mapa.

	A chance de acertar unidade e um pity — sobe a cada raio que cai no chao e volta
	ao piso quando um acerta. Sem isso, com chance fixa baixa daria para passar a
	partida inteira sem ver um raio em unidade nenhuma; e com chance fixa alta o
	clima viraria uma metralhadora nas torres.

	O servidor so decide **quando** e **onde**: o desenho e do `VFXController`,
	porque o modulo `ReplicatedStorage.vfx` e client-only. Sortear aqui e o que faz
	todo mundo ver o mesmo raio no mesmo lugar.

	Fica na Game porque depende do `UnitService` e do mapa carregado. O clima em si
	e compartilhado (`common/server/Services/WeatherService`).

	Hoje o raio e so visual: nao tira vida nem atordoa. O gancho para isso seria no
	`strikeUnit`, ao lado do `Framework:Fire`.
]]

local ThunderService = {
	Services = {
		WeatherService = {},
		UnitService = {}
	}
}

ThunderService.NextStrike = nil :: number?
ThunderService.UnitChance = Config.UnitChance

--[[ ALVOS ]]

--[=[
	Uma unidade posicionada qualquer, ou nil se nao houver nenhuma.

	`unitName` restringe a um tipo de unidade — o comando `strike` usa isso para
	testar o raio numa unidade especifica em vez de esperar a sorte.
]=]
function ThunderService:pickTarget(unitName : string?)
	local unitService = self.Services.UnitService
	local units = unitService and unitService.PlacedUnits
	if not units or #units == 0 then
		return nil
	end

	if not unitName then
		return units[math.random(1, #units)]
	end

	local matches = {}
	for _, entry in units do
		if entry.unitName == unitName then
			table.insert(matches, entry)
		end
	end

	if #matches == 0 then
		return nil
	end

	return matches[math.random(1, #matches)]
end

function ThunderService:getMap() : Instance?
	return workspace:FindFirstChild(WeatherConfig.TargetName)
end

--[=[
	Um ponto no chao dentro da caixa do mapa.

	X e Z saem sorteados da caixa; o Y vem de um raio para baixo, porque o terreno
	tem altura variavel e largar o raio no fundo da caixa deixaria ele enterrado nas
	partes altas. A propria BoundingBox nao atrapalha a consulta: o `LoadMap` a clona
	com `CanQuery` desligado.
]=]
function ThunderService:pickGround() : Vector3?
	local target = self:getMap()
	if not target then
		return nil
	end

	local weatherService = self.Services.WeatherService
	if not weatherService then
		return nil
	end

	local center, size = weatherService:GetMapBounds(target)
	if not center or not size then
		return nil
	end

	local x = center.X + (math.random() - 0.5) * size.X
	local z = center.Z + (math.random() - 0.5) * size.Z
	local top = center.Y + size.Y / 2
	local bottom = center.Y - size.Y / 2

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { target }

	local result = workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, bottom - top, 0), params)

	-- Buraco no mapa (ou ponto fora da geometria): o fundo da caixa serve.
	return result and result.Position or Vector3.new(x, bottom, z)
end

--[[ RAIOS ]]

local function broadcast(position : Vector3, unitId : string?)
	for _, player in Players:GetPlayers() do
		Framework:Fire("LightningStrike", player, position, unitId)
	end
end

--[=[
	Raio em cima de uma unidade. Devolve a entrada atingida, ou nil se nao havia
	alvo — e o que o comando `strike` usa para dizer em quem caiu.

	Vai o `unitId` junto da posicao: o cliente refina para o pe exato do modelo, que
	ele mede da caixa da unidade. A posicao daqui e so o fallback de quando o modelo
	ainda nao replicou.
]=]
function ThunderService:strikeUnit(unitName : string?)
	local entry = self:pickTarget(unitName)
	if not entry then
		return nil
	end

	broadcast(entry.cf.Position, entry.unitId)
	return entry
end

-- Raio num ponto qualquer do mapa. Devolve onde caiu, ou nil se nao deu para medir.
function ThunderService:strikeGround() : Vector3?
	local position = self:pickGround()
	if not position then
		return nil
	end

	broadcast(position, nil)
	return position
end

--[=[
	Um raio do clima: sorteia entre unidade e chao, e mexe no pity.

	Acertou unidade, a chance volta ao piso. Caiu no chao **tendo unidade no mapa**,
	sobe um degrau. Sem unidade nenhuma a chance fica parada — ver o comentario do
	`UnitChance` no config.
]=]
function ThunderService:rollStrike()
	local hasUnits = self:pickTarget() ~= nil

	if hasUnits and math.random() < self.UnitChance then
		if self:strikeUnit() then
			self.UnitChance = Config.UnitChance
			return
		end
	end

	self:strikeGround()

	if hasUnits then
		self.UnitChance = math.min(Config.MaxUnitChance, self.UnitChance + Config.UnitChanceStep)
	end
end

--[=[
	O compasso.

	O relogio so anda com o clima ligado, e zera quando ele sai — assim ligar o
	trovao nao dispara um raio atrasado da vez anterior, e o primeiro raio sempre
	espera um intervalo inteiro em vez de cair junto com a troca de clima. O pity
	tambem reseta: o clima novo comeca do piso.
]=]
function ThunderService:step(now : number)
	local weatherService = self.Services.WeatherService
	local active = weatherService and weatherService:GetCurrent() == Config.Weather

	if not active then
		self.NextStrike = nil
		self.UnitChance = Config.UnitChance
		return
	end

	if not self.NextStrike then
		self.NextStrike = now + Config.Interval
		return
	end

	if now < self.NextStrike then
		return
	end

	self.NextStrike = now + Config.Interval
	self:rollStrike()
end

function ThunderService:construct()
	RunService.Heartbeat:Connect(function()
		self:step(os.clock())
	end)
end

function ThunderService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function ThunderService:init()
	Framework:Listen("LightningStrike", function() end)
end

return ThunderService
