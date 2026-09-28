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
	The warning that weather is on the way.

	The server sends `WeatherWarning` with the weather name and how many waves are
	left; only the sentence comes from here. `WarningController` puts it on screen,
	animates it, and resolves conflicts with other warnings.

	A new warning replaces the previous one. In practice this almost never happens:
	the server does not schedule a weather while another is scheduled or active.

	See docs/game/weather-in-match.md.
]]

local WeatherWarningController = {
	Controllers = {
		WarningController = {}
	}
}

--[=[
	Shows a weather's warning.

	`wavesAhead` comes from the server because the server keeps the deadline; the
	client only picks between the plural sentence and the single-wave one.
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
	Removes the weather warning from the screen immediately. It is what a round
	restart needs: the previous round's warning must not stay there.

	It passes its own priority so it does not take a more important warning with it:
	the server restart has nothing to do with the round restarting.
]=]
function WeatherWarningController:Hide()
	local warning = self.Controllers.WarningController
	if not warning then return end

	warning:Hide(WarningConfig.Priority.Weather)
end

--[[ LIFECYCLE ]]

function WeatherWarningController:construct()
	Framework:Listen("WeatherWarning", function(weatherName : string, wavesAhead : number)
		if typeof(weatherName) ~= "string" then return end
		self:Show(weatherName, tonumber(wavesAhead) or WeatherConfig.Round.LeadWaves)
	end)

	Framework:Listen("RoundRestarted", function()
		self:Hide()
	end)

	-- A player who joins mid-match with a weather already announced needs to see the warning.
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
