local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

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

	O raio nao tira vida: ele atordoa. Quem leva em cheio para por `Stun.Direct`
	(20s, a wave inteira), e o choque salta para quem estiver perto, que para por
	`Stun.Chain` (5s). Unidade `Electric` e a excecao que faz o clima valer a pena
	para alguem: alem do bonus passivo do `Effects.Thunder`, levar o raio **nao** a
	atordoa -- a carrega com dano e cooldown menor por `Charge.Duration`. Os numeros
	estao todos em `WeatherConfig.Thunder`.
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
function ThunderService:pickTarget(unitName : string?, skipImmune : boolean?)
	local unitService = self.Services.UnitService
	local units = unitService and unitService.PlacedUnits
	if not units or #units == 0 then
		return nil
	end

	--[[
		Unidade imune ao trovao sai do sorteio em vez de ser sorteada e ignorada.

		Ela nao seria atordoada de qualquer jeito, e deixa-la no bolo estragaria o
		pity: cada raio gasto numa Magic contaria como "acertou uma unidade" e a
		chance voltaria ao piso sem nada ter acontecido na tela.

		Vale so para o raio do clima. O comando `strike` continua alcancando
		qualquer unidade, porque testar o visual numa Magic e legitimo.
	]]
	local matches = {}
	for _, entry in units do
		if unitName and entry.unitName ~= unitName then continue end
		if skipImmune and WeatherConfig.IsImmune(Config.Weather, entry.unitName) then continue end

		table.insert(matches, entry)
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

--[[ EFEITO DO RAIO ]]

--[=[
	Unidades ao alcance do arco, a partir de um ponto.

	`hit` é quem já levou choque nesta descarga — nem alvo, nem ponte. Sem isso o
	arco voltaria para quem acabou de acertar e o salto nunca terminaria.
]=]
function ThunderService:findChainTargets(origin : Vector3, hit : { [string]: boolean })
	local unitService = self.Services.UnitService
	local units = unitService and unitService.PlacedUnits
	if not units then
		return {}
	end

	local radius = Config.Stun.Radius or 0
	local found = {}

	for _, entry in units do
		if hit[entry.unitId] then continue end
		if WeatherConfig.IsImmune(Config.Weather, entry.unitName) then continue end

		if (entry.cf.Position - origin).Magnitude <= radius then
			table.insert(found, entry)
		end
	end

	return found
end

--[=[
	O que uma unidade ganha por ser tocada pelo raio.

	Atordoamento para todo mundo, menos para quem é `Electric`: essa leva a carga no
	lugar, com dano acima e cooldown abaixo do normal por alguns segundos. É o outro
	lado do trovão — para a maioria das unidades ele é uma wave perdida, e para
	Electric é a melhor wave da partida.

	A Electric continua servindo de ponte para o arco: o salto parte dela como de
	qualquer outra unidade atingida.
]=]
function ThunderService:applyHit(entry, duration : number)
	local unitService = self.Services.UnitService
	if not unitService then return end

	if not WeatherConfig.HasClass(entry.unitName, "Electric") then
		unitService:StunUnit(entry, duration)
		return
	end

	local charge = Config.Charge
	if not charge then return end

	unitService:ChargeUnit(entry, charge.Damage, charge.AttackSpeed, charge.Duration or 0)
end

--[=[
	A descarga inteira, a partir da unidade que o raio pegou em cheio.

	O salto anda em camadas: quem está no raio da unidade atingida leva `Chain`,
	quem está no raio *dessas* leva na camada seguinte, até `Hops` camadas. Com o
	`Hops = 1` de hoje só existe uma camada, mas a busca é escrita em largura
	porque o número é config — e uma implementação recursiva sem controle de
	visitados iria e voltaria entre duas unidades vizinhas para sempre.

	Cada unidade só é tocada uma vez por descarga, e o atordoamento do salto é
	muito mais curto que o do acerto direto (5s contra 20s): um raio bem colocado
	tem que doer, não apagar o mapa.

	Devolve os arcos desenhados, para o cliente ligar as unidades com o mesmo asset
	do raio.
]=]
function ThunderService:chainFrom(entry)
	local stun = Config.Stun
	if not stun then return {} end

	local hit = { [entry.unitId] = true }
	local links = {}

	local frontier = { entry }
	local hops = math.max(0, stun.Hops or 0)
	local maxTargets = stun.MaxTargets or math.huge

	for _ = 1, hops do
		local nextFrontier = {}

		for _, source in frontier do
			local targets = self:findChainTargets(source.cf.Position, hit)

			for index, target in targets do
				if index > maxTargets then break end

				hit[target.unitId] = true
				self:applyHit(target, stun.Chain or 0)
				table.insert(nextFrontier, target)

				table.insert(links, {
					fromId = source.unitId,
					toId = target.unitId,
					from = source.cf.Position,
					to = target.cf.Position,
				})
			end
		end

		if #nextFrontier == 0 then break end
		frontier = nextFrontier
	end

	return links
end

--[[ RAIOS ]]

local function broadcast(position : Vector3, unitId : string?)
	for _, player in Players:GetPlayers() do
		Framework:Fire("LightningStrike", player, position, unitId)
	end
end

-- Os arcos do salto, para o cliente ligar uma unidade a outra com o mesmo asset
-- do raio. Lista vazia nao vira evento.
local function broadcastChain(links)
	if #links == 0 then return end

	for _, player in Players:GetPlayers() do
		Framework:Fire("LightningChain", player, links)
	end
end

--[=[
	Raio em cima de uma unidade. Devolve a entrada atingida, ou nil se nao havia
	alvo — e o que o comando `strike` usa para dizer em quem caiu.

	Vai o `unitId` junto da posicao: o cliente refina para o pe exato do modelo, que
	ele mede da caixa da unidade. A posicao daqui e so o fallback de quando o modelo
	ainda nao replicou.
]=]
function ThunderService:strikeUnit(unitName : string?, skipImmune : boolean?)
	local entry = self:pickTarget(unitName, skipImmune)
	if not entry then
		return nil
	end

	broadcast(entry.cf.Position, entry.unitId)

	--[[
		O visual sai primeiro e o efeito depois, na mesma linha de execucao: os dois
		chegam no mesmo quadro, e a ordem so decide qual evento o cliente processa
		antes. O raio na frente e o que faz o realce do atordoamento aparecer *com* o
		clarao em vez de um piscar antes dele.
	]]
	local stun = Config.Stun
	if stun and not WeatherConfig.IsImmune(Config.Weather, entry.unitName) then
		self:applyHit(entry, stun.Direct or 0)
		broadcastChain(self:chainFrom(entry))
	end

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
	local hasUnits = self:pickTarget(nil, true) ~= nil

	if hasUnits and math.random() < self.UnitChance then
		if self:strikeUnit(nil, true) then
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
		-- Tempo de partida: o atordoamento que este clima aplica ja encolhe com a
		-- velocidade (o `UnitService` marca o prazo no mesmo relogio), entao a
		-- cadencia tem que encolher junto -- senao acelerar seria uma forma de
		-- levar menos clima por wave.
		self:step(GameClock.Now())
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
	Framework:Listen("LightningChain", function() end)
end

return ThunderService
