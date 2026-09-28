local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

local OFF = "off"

return function(_context, weather : string, duration : number?)
	local WeatherService = Framework:Get("WeatherService", false, true)

	if string.lower(weather) == OFF then
		local ok, message = WeatherService:Clear(duration)
		if not ok then
			return "Could not clear the weather: " .. message
		end
		return message
	end

	local ok, message = WeatherService:Apply(weather, duration)
	if ok then
		return message
	end

	-- The name is not validated on the client on purpose (see the type), so the list
	-- of options only appears here, where the truth is known.
	local available = WeatherService:GetNames()
	if #available == 0 then
		return string.format("Could not apply the weather: %s (and Assets.Weathers is empty).", message)
	end

	return string.format("Could not apply the weather: %s Available: %s, %s.",
		message, table.concat(available, ", "), OFF)
end
