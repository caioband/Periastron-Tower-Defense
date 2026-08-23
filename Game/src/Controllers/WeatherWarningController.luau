local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local WeatherConfig = SharedConfig.WeatherConfig
local WarningConfig = SharedConfig.WarningConfig
local Config = WeatherConfig.Warning

--[[
	O aviso de que vem clima por aí.

	O servidor manda `WeatherWarning` com o nome do clima e quantas waves faltam;
	daqui sai só a frase — quem a coloca na tela, anima e resolve disputa com outros
	avisos é o `WarningController`.

	Um aviso novo derruba o anterior. Na prática isso quase não acontece: o servidor
	não agenda um clima enquanto houver outro agendado ou no ar.
]]

local WeatherWarningController = {
	Controllers = {
		WarningController = {}
	}
}

--[=[
	Mostra o aviso de um clima.

	`wavesAhead` vem do servidor porque é ele que vai cumprir o prazo; o cliente só
	escolhe entre a frase no plural e a de uma wave só.
]=]
function WeatherWarningController:Show(weatherName : string, wavesAhead : number)
	local warning = self.Controllers.WarningController
	if not warning then return end

	local displayName = WeatherConfig.GetDisplayName(weatherName)
	local text = if wavesAhead <= 1
		then string.format(Config.TextOne, displayName)
		else string.format(Config.Text, displayName, wavesAhead)

	warning:Show(text, { Priority = WarningConfig.Priority.Weather })
end

--[=[
	Tira o aviso de clima da tela na hora. É o que o recomeço de round precisa: o
	aviso do round anterior não pode continuar lá.

	Passa a própria prioridade para não levar junto um aviso mais importante — o
	restart do servidor não tem nada a ver com o round ter recomeçado.
]=]
function WeatherWarningController:Hide()
	local warning = self.Controllers.WarningController
	if not warning then return end

	warning:Hide(WarningConfig.Priority.Weather)
end

--[[ CICLO DE VIDA ]]

function WeatherWarningController:construct()
	Framework:Listen("WeatherWarning", function(weatherName : string, wavesAhead : number)
		if typeof(weatherName) ~= "string" then return end
		self:Show(weatherName, tonumber(wavesAhead) or WeatherConfig.Round.LeadWaves)
	end)

	Framework:Listen("RoundRestarted", function()
		self:Hide()
	end)

	-- Quem entra no meio da partida com um clima ja avisado precisa ver o aviso.
	Framework:Fire("RequestWeatherWarning")
end

function WeatherWarningController:start()
end

function WeatherWarningController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WeatherWarningController
