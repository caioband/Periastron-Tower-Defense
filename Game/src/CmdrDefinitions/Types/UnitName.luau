--[[
	cmdr type "unitName".

	Registrado no servidor por `Registry:RegisterTypesIn`, que replica este modulo
	para `ReplicatedStorage.CmdrClient.Types` — e o que faz o autocomplete existir no
	console do cliente.

	A lista sai do `SharedConfig.UnitStats`, que e o catalogo de unidades do jogo.
	Nao e a lista das unidades *posicionadas*: essa e estado de servidor, e recusar
	aqui um nome que existe seria pior do que deixar o comando responder que nao ha
	nenhuma daquele tipo no mapa.
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
