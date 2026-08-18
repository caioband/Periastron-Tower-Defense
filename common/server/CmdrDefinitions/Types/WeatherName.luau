--[[
	cmdr type "weatherName".

	Registrado no servidor por `Registry:RegisterTypesIn`, que replica este módulo
	para `ReplicatedStorage.CmdrClient.Types` — é o que faz o autocomplete existir
	no console do cliente.

	A lista sai de `Assets.Weathers` em tempo real. `off` entra junto porque desligar
	é o outro lado do mesmo comando, e ter que lembrar de um segundo nome de comando
	só para isso atrapalharia justamente quem está testando.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs:WaitForChild("SharedConfig"))

local Config = SharedConfig.WeatherConfig

local OFF = "off"

--[[
	Sempre `FindFirstChild`: no Lobby a pasta pode nem existir, e aí o autocomplete
	fica só com o `off` em vez de derrubar o console.
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
			Quem recusa nome inválido é o servidor, não isto: quando o console abre, o
			cliente pode ainda não ter recebido `Assets.Weathers`, e barrar um clima que
			existe seria pior do que deixar o WeatherService responder que não achou.
		]]
		Parse = function(text: string)
			return text
		end,
	})
end
