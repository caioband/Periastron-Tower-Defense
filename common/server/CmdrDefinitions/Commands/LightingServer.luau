local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs:WaitForChild("SharedConfig"))
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

local Config = SharedConfig.LightingConfig

local function listAvailable(LightingService) : string
	local root = LightingService.Root
	if not root then
		return ""
	end

	local names = {}
	for _, folder in root:GetChildren() do
		if folder:IsA("Folder") then
			table.insert(names, folder.Name)
		end
	end
	table.sort(names)

	return table.concat(names, ", ")
end

return function(_context, preset : string, duration : number?)
	local LightingService = Framework:Get("LightingService", false, true)

	-- Before reading `.Root`: `GetCurrent` is what guarantees the service already
	-- built the presets folder.
	local previous = LightingService:GetCurrent()

	if not LightingService:GetPreset(preset) then
		local available = listAvailable(LightingService)
		if available == "" then
			return string.format("There is no preset named '%s', and Assets.Lighting is empty.", preset)
		end

		return string.format("There is no preset named '%s'. Available: %s.", preset, available)
	end

	-- Reapplying the current preset is a legitimate request here: it is how you test
	-- a folder that was just edited in Studio.
	local force = previous == preset

	if not LightingService:Apply(preset, duration, force) then
		return string.format("Could not apply '%s' -- check the server output.", preset)
	end

	local seconds = duration or Config.Transition.Time
	local howLong = if seconds <= 0 then "no transition" else string.format("%.4gs transition", seconds)

	if force then
		return string.format("Reapplied '%s' (%s).", preset, howLong)
	end

	return string.format("Lighting: %s -> %s (%s).", previous or "?", preset, howLong)
end
