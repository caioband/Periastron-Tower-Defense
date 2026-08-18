local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs:WaitForChild("SharedConfig"))
local LightingUtil = require(Utils:WaitForChild("LightingUtil"))
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

local Config = SharedConfig.LightingConfig

--[[
	Conta quantos atributos da pasta o service vai de fato escrever no Lighting —
	que não é o total de atributos: nome fora da lista de `LightingConfig.Properties`
	é ignorado na aplicação, e mostrar o total daria a entender que ele conta.
]]
local function countDeclared(preset : Folder) : number
	local total = 0
	for _ in LightingUtil.ReadPresetAttributes(preset) do
		total += 1
	end
	return total
end

return function(_context)
	local LightingService = Framework:Get("LightingService", false, true)

	local current = LightingService:GetCurrent()
	local root = LightingService.Root

	if not root then
		return "Assets.Lighting does not exist yet -- the LightingService has not started."
	end

	local presets = {}
	for _, preset in root:GetChildren() do
		if preset:IsA("Folder") then
			table.insert(presets, preset)
		end
	end

	if #presets == 0 then
		return "Assets.Lighting is empty."
	end

	table.sort(presets, function(a, b)
		return a.Name < b.Name
	end)

	local lines = {}
	for _, preset in presets do
		local declared = countDeclared(preset)
		local children = #preset:GetChildren()

		table.insert(lines, string.format("%s %-24s %d propriedade(s), %d instância(s)%s",
			preset.Name == current and ">" or " ",
			preset.Name,
			declared,
			children,
			-- Aplicar um preset assim é legítimo e não muda nada; dizer isso aqui
			-- evita a caçada por um bug que não existe.
			(declared == 0 and children == 0) and "  <- vazio, aplicar não faz nada" or ""))
	end

	return string.format("Presets em Assets.Lighting (> = atual, transição padrão %.4gs):\n%s",
		Config.Transition.Time, table.concat(lines, "\n"))
end
