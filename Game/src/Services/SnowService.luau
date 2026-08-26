local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Me = require(Vendor.Me)

local Framework = Me.new()

local WeatherConfig = SharedConfig.WeatherConfig

local WEATHER = "Snow"

--[[
	O congelamento da neve.

	Enquanto o clima `Snow` estiver no ar, de tempos em tempos uma unidade sorteada
	congela e para de atacar. O corte de cadência que todo mundo leva mora nos
	multiplicadores do `WeatherConfig.Effects.Snow`; aqui está só o compasso do
	congelamento, que é o único pedaço da neve que precisa de um relógio.

	Congelar é o mesmo atordoamento que o raio usa (`UnitService:StunUnit`) — o
	cliente já desenha o realce e a unidade já para de procurar alvo. O que muda é
	quem pode ser sorteado: quem é imune ao clima (Magic, hoje) fica fora do
	sorteio, e não apenas "é sorteado e não congela", senão um mapa com muitas
	unidades Magic passaria waves inteiras sem nada acontecer.

	Espelha o `ThunderService`: mesma forma, mesmo lugar, e o relógio zera junto com
	o clima para o primeiro congelamento sempre esperar um intervalo inteiro em vez
	de cair junto com a transição.
]]

local SnowService = {
	Services = {
		WeatherService = {},
		UnitService = {}
	}
}

SnowService.NextFreeze = nil :: number?

function SnowService:getConfig()
	local effects = WeatherConfig.GetEffects(WEATHER)
	return effects and effects.Freeze
end

--[=[
	Congela uma unidade sorteada. Devolve a entrada congelada, ou nil quando não
	havia ninguém elegível no mapa.
]=]
function SnowService:FreezeRandom()
	local config = self:getConfig()
	if not config then return nil end

	local unitService = self.Services.UnitService
	if not unitService then return nil end

	return unitService:StunRandomUnit(config.Duration or 0, WEATHER)
end

function SnowService:step(now : number)
	local config = self:getConfig()
	local weatherService = self.Services.WeatherService
	local active = config and weatherService and weatherService:GetCurrent() == WEATHER

	if not active then
		self.NextFreeze = nil
		return
	end

	local interval = config.Interval or 30

	if not self.NextFreeze then
		self.NextFreeze = now + interval
		return
	end

	if now < self.NextFreeze then
		return
	end

	self.NextFreeze = now + interval
	self:FreezeRandom()
end

function SnowService:construct()
	RunService.Heartbeat:Connect(function()
		-- Tempo de partida: o atordoamento que este clima aplica ja encolhe com a
		-- velocidade (o `UnitService` marca o prazo no mesmo relogio), entao a
		-- cadencia tem que encolher junto -- senao acelerar seria uma forma de
		-- levar menos clima por wave.
		self:step(GameClock.Now())
	end)
end

function SnowService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function SnowService:init()
end

return SnowService
