--[[
	cmdr type "unitName".

	Registered on the server by `Registry:RegisterTypesIn`, which replicates this
	module to `ReplicatedStorage.CmdrClient.Types`: that is what makes autocomplete
	exist in the client console.

	The list comes from `SharedConfig.UnitStats`, the game's unit catalog. It is not
	the list of *placed* units: that is server state, and rejecting an existing name
	here would be worse than letting the command answer that there are none of that
	type on the map.

	It lives in `common/` because both places use it: Game through `strike` (a unit
	on the map) and both through `units` (the profile inventory, which the Lobby
	builds decks from). The `UnitStats` it reads is shared, so nothing here depends
	on a one-sided service.

	> A unit with a space in its name needs quotes on the command line:
	> `units add me "Subspace Tripminer" 3`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs:WaitForChild("SharedConfig"))

local function getNames(): { string }
	local names = {}

	for unitName in SharedConfig.UnitStats do
		table.insert(names, unitName)
	end
	table.sort(names)

	return names
end

return function(registry)
	registry:RegisterType("unitName", {
		Transform = function(text: string)
			return text
		end,

		Validate = function(text: string)
			if text == "" then
				return false, "Unit name is empty."
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

		Parse = function(text: string)
			return text
		end,
	})
end
