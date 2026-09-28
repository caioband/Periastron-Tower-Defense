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
	Counts how many of the folder's attributes the service will actually write to
	Lighting, which is not the total: a name outside `LightingConfig.Properties` is
	ignored when applying, and showing the total would suggest it counts.
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

		table.insert(lines, string.format("%s %-24s %d propert(ies), %d instance(s)%s",
			preset.Name == current and ">" or " ",
			preset.Name,
			declared,
			children,
			-- Applying a preset like this is legitimate and changes nothing; saying so here
			-- avoids a hunt for a bug that does not exist.
			(declared == 0 and children == 0) and "  <- empty, applying it does nothing" or ""))
	end

	return string.format("Presets in Assets.Lighting (> = current, default transition %.4gs):\n%s",
		Config.Transition.Time, table.concat(lines, "\n"))
end
