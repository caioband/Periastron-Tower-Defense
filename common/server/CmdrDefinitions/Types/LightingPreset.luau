--[[
	cmdr type "lightingPreset".

	Registered on the server by `Registry:RegisterTypesIn`, which replicates this
	module to `ReplicatedStorage.CmdrClient.Types`: that is why autocomplete works in
	the client console.

	The list comes from `Assets.Lighting` live, not from a fixed table: map presets
	(`Map_Farm`, `Map_Cave`, …) only exist after `MapService` registers the loaded
	map, and the `Default` baseline is built by the server on startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs:WaitForChild("SharedConfig"))

local Config = SharedConfig.LightingConfig

--[[
	The folder may not exist yet when the console opens (the server creates it on
	LightingService's first use), so this is always `FindFirstChild`: without it,
	autocomplete stays empty instead of locking up the console.
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
			The name is validated on the server, not here: when the console opens, the
			client may not have received `Assets.Lighting` yet, and rejecting a preset
			that exists would be worse than letting `LightingService` answer that it
			was not found.
		]]
		Parse = function(text: string)
			return text
		end,
	})
end
