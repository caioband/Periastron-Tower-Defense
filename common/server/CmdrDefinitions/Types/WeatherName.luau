--[[
	cmdr type "weatherName".

	Registered on the server by `Registry:RegisterTypesIn`, which replicates this
	module to `ReplicatedStorage.CmdrClient.Types`: that is what makes autocomplete
	exist in the client console.

	The list comes from `Assets.Weathers` live. `off` is included because turning
	off is the other side of the same command, and having to remember a second
	command name just for that would get in the way of exactly the people testing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs:WaitForChild("SharedConfig"))

local Config = SharedConfig.WeatherConfig

local OFF = "off"

--[[
	Always `FindFirstChild`: in the Lobby the folder may not even exist, and then
	autocomplete shows only `off` instead of crashing the console.
]]
local function getNames(): { string }
	local names = { OFF }

	local current: Instance? = ReplicatedStorage
	for _, name in Config.AssetsPath do
		if not current then return names end
		current = current:FindFirstChild(name)
	end

	if not current then
		return names
	end

	local found = {}
	for _, model in current:GetChildren() do
		if model:IsA("Model") then
			table.insert(found, model.Name)
		end
	end
	table.sort(found)

	for _, name in found do
		table.insert(names, name)
	end

	return names
end

return function(registry)
	registry:RegisterType("weatherName", {
		Transform = function(text: string)
			return text
		end,

		Validate = function(text: string)
			if text == "" then
				return false, "Weather name is empty."
			end

			return true
		end,

		Autocomplete = function(text: string)
			local matches = {}
			local lowered = string.lower(text)

			for _, name in getNames() do
				if string.find(string.lower(name), lowered, 1, true) then
					table.insert(matches, name)
				end
			end

			return matches
		end,

		--[[
			The server rejects invalid names, not this: when the console opens, the
			client may not have received `Assets.Weathers` yet, and blocking a weather
			that exists would be worse than letting WeatherService answer that it was
			not found.
		]]
		Parse = function(text: string)
			return text
		end,
	})
end
