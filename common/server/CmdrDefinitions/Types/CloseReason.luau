--[[
	cmdr type "closeReason".

	The names of `Enum.CloseReason`, which is what `game.ServerRestartScheduled` sends
	along with the time. It exists so `restartwarning` can rehearse each reason
	without anyone typing the exact name from memory.

	New enum items show up on their own: the list is read from the engine.
]]

local function getNames() : { string }
	local names = {}

	for _, item in Enum.CloseReason:GetEnumItems() do
		table.insert(names, item.Name)
	end
	table.sort(names)

	return names
end

return function(registry)
	registry:RegisterType("closeReason", {
		Transform = function(text : string)
			return text
		end,

		Validate = function(text : string)
			if text == "" then
				return false, "Close reason is empty."
			end

			for _, name in getNames() do
				if string.lower(name) == string.lower(text) then
					return true
				end
			end

			return false, string.format("'%s' is not an Enum.CloseReason. Try: %s.", text, table.concat(getNames(), ", "))
		end,

		Autocomplete = function(text : string)
			local matches = {}
			local lowered = string.lower(text)

			for _, name in getNames() do
				if string.find(string.lower(name), lowered, 1, true) then
					table.insert(matches, name)
				end
			end

			return matches
		end,

		-- Returns the name in the engine's casing, not the typed one: it is the key
		-- into `WarningConfig.Restart.Sources`.
		Parse = function(text : string)
			for _, name in getNames() do
				if string.lower(name) == string.lower(text) then
					return name
				end
			end

			return text
		end,
	})
end
