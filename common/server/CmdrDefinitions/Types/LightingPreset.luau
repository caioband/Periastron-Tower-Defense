--[[
	cmdr type "lightingPreset".

	Registrado no servidor por `Registry:RegisterTypesIn`, que replica este módulo
	para `ReplicatedStorage.CmdrClient.Types` — é por isso que o autocomplete
	funciona no console do cliente.

	A lista sai de `Assets.Lighting` em tempo real, e não de uma tabela fixa: os
	presets de mapa (`Map_Farm`, `Map_Cave`, …) só existem depois que o
	`MapService` registra o mapa carregado, e o baseline `Default` é montado pelo
	servidor na entrada.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs:WaitForChild("SharedConfig"))

local Config = SharedConfig.LightingConfig

--[[
	A pasta pode ainda não existir quando o console abre (o servidor cria no
	primeiro uso do LightingService), então aqui é sempre `FindFirstChild`: sem ela
	o autocomplete fica vazio em vez de travar o console.
]]
local function getPresetsRoot(): Folder?
	local current: Instance? = ReplicatedStorage

	for _, name in Config.PresetsPath do
		if not current then return nil end
		current = current:FindFirstChild(name)
	end

	return current :: Folder?
end

local function getPresetNames(): { string }
	local names = {}

	local root = getPresetsRoot()
	if not root then
		return names
	end

	for _, preset in root:GetChildren() do
		if preset:IsA("Folder") then
			table.insert(names, preset.Name)
		end
	end

	table.sort(names)
	return names
end

return function(registry)
	registry:RegisterType("lightingPreset", {
		Transform = function(text: string)
			return text
		end,

		Validate = function(text: string)
			if text == "" then
				return false, "Preset name is empty."
			end

			return true
		end,

		Autocomplete = function(text: string)
			local matches = {}
			local lowered = string.lower(text)

			for _, name in getPresetNames() do
				if string.find(string.lower(name), lowered, 1, true) then
					table.insert(matches, name)
				end
			end

			return matches
		end,

		--[[
			O nome é validado no servidor, não aqui: quando o console abre, o cliente
			pode ainda não ter recebido `Assets.Lighting`, e recusar um preset que
			existe seria pior do que deixar o `LightingService` responder que não achou.
		]]
		Parse = function(text: string)
			return text
		end,
	})
end
