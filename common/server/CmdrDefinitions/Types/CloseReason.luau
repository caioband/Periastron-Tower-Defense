--[[
	cmdr type "closeReason".

	Os nomes de `Enum.CloseReason`, que é o que `game.ServerRestartScheduled` manda
	junto do horário. Existe para o `restartwarning` poder ensaiar cada motivo sem
	ninguém ter que digitar o nome exato de cabeça.

	Enum novo entra sozinho: a lista é lida da própria engine.
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

		-- Devolve o nome com a caixa da engine, e não a que foi digitada: é a chave
		-- de `WarningConfig.Restart.Sources`.
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
