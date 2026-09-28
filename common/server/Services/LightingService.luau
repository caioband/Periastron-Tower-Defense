local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local LightingUtil = require(Utils.LightingUtil)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("LightingService")

local Config = SharedConfig.LightingConfig

-- Each apply is logged (Studio only) because "the preset was applied" cannot be
-- checked by looking at Lighting afterward: if a preset declares no attributes,
-- the correct result is that nothing changes.

--[[
	Switches the Lighting preset.

	A preset is a Folder in `ReplicatedStorage.Shared.Assets.Lighting`: its
	attributes become `Lighting` properties, and its children become the instances
	inside it (Sky, Atmosphere, ColorCorrection…). `Apply` clones the folder, clears
	Lighting, and moves the clone's contents in.

	The cut here is hard, on purpose: the server is the truth, and a player who joins
	mid-match must receive the final state directly. `LightingController` smooths it
	on the client.

		local Lighting = Framework:Get("LightingService")

		Lighting:Apply("Blizzard")        -- transition at the default time
		Lighting:Apply("Foggy", 4)        -- 4s transition
		Lighting:Apply("Foggy", 0)        -- no transition

	It lives in `common/` because both places use it.

	See docs/common/lighting.md.
]]

local LightingService = {
	Services = {},
}

LightingService.Current = nil :: string?
LightingService.Root = nil :: Folder?

-- The current preset had its contents replaced by a `Register`: the next `Apply`
-- on it must take effect instead of hitting the "already this one" shortcut.
LightingService._dirty = false

--[[ SETUP ]]

--[[
	A loose Folder inside Lighting is a preset authored in the place (that is how
	Main Game keeps `FoggyLightning` and `BlizzardLightning`). They must be moved
	out: `Apply`'s clear would take both with it, and the client could not read the
	transition's source values from inside `Lighting`.
]]
function LightingService:_migrateAuthoredPresets(root: Folder)
	for _, child in Lighting:GetChildren() do
		if not child:IsA("Folder") then continue end
		if child:GetAttribute(Config.KeepAttribute) == true then continue end

		if root:FindFirstChild(child.Name) then
			log:StudioWarn(`preset "{child.Name}" already exists in Assets.Lighting; the Folder with the same name inside Lighting was ignored.`)
			continue
		end

		child.Parent = root
	end
end

--[[
	Builds the baseline preset from the Lighting authored in the place: current
	properties become attributes, and remaining children become clones inside it.

	Without this, the first switch would have nothing to tween from: the client
	reads the source values from the previous preset, and before the first call
	there would be none.
]]
function LightingService:_captureBaseline(root: Folder): string
	local name = Config.BaselineName

	if root:FindFirstChild(name) then
		return name
	end

	local folder = Instance.new("Folder")
	folder.Name = name

	for propertyName, value in LightingUtil.ReadInstance(Lighting) do
		folder:SetAttribute(propertyName, value)
	end

	-- What is marked to survive the clear is left out: it will already be there when
	-- the baseline is reapplied, and adding it to the preset would duplicate it.
	for _, child in Lighting:GetChildren() do
		if child:GetAttribute(Config.KeepAttribute) == true then continue end
		child:Clone().Parent = folder
	end

	folder.Parent = root
	return name
end

function LightingService:_setup()
	if self.Root then return end

	local root = LightingUtil.GetPresetsRoot(true)
	if not root then
		log:Warn("could not create the presets folder; the service stays inert.")
		return
	end

	self.Root = root
	self:_migrateAuthoredPresets(root)
	self.Current = self:_captureBaseline(root)
end

--[[ API ]]

function LightingService:GetPreset(name: string): Folder?
	self:_setup()

	local root = self.Root
	if not root then return nil end

	local preset = root:FindFirstChild(name)
	if not preset or not preset:IsA("Folder") then
		return nil
	end

	return preset
end

function LightingService:GetCurrent(): string?
	self:_setup()
	return self.Current
end

--[[
	Registers as a preset a Folder outside `Assets.Lighting`: a map's `Lighting`
	folder in `ServerStorage`, for example.

	The clone into the presets folder is what makes the transition possible:
	`ServerStorage` does not replicate, so without it the client would have nowhere
	to read the target values from. Returns the name the preset was registered
	under, to pass to `Apply`.
]]
function LightingService:Register(folder: Instance, name: string?): string?
	self:_setup()

	local root = self.Root
	if not root then return nil end

	if not folder:IsA("Folder") then
		log:StudioWarn(`"{folder:GetFullName()}" is not a Folder; it cannot be registered as a preset.`)
		return nil
	end

	local presetName = name or folder.Name

	local existing = root:FindFirstChild(presetName)
	if existing then
		existing:Destroy()
	end

	local clone = folder:Clone()
	clone.Name = presetName
	clone.Parent = root

	if presetName == self.Current then
		self._dirty = true
	end

	return presetName
end

--[[
	Makes Lighting match the preset and notifies clients.

	`transitionTime` only travels to the client: here the switch is always immediate.
	`0` asks for a hard cut on the client too.

	`force` reapplies even if the preset is already current, for someone who just
	edited the folder's contents and wants to see the result (that is what the
	`lighting` command does).
]]
function LightingService:Apply(name: string, transitionTime: number?, force: boolean?): boolean
	local preset = self:GetPreset(name)
	if not preset then
		log:StudioWarn(`preset "{name}" does not exist in Assets.Lighting.`)
		return false
	end

	if name == self.Current and not self._dirty and not force then
		return true
	end
	self._dirty = false

	local clone = preset:Clone()
	if not clone then
		-- `Archivable = false` on the folder makes Clone return nil.
		log:StudioWarn(`preset "{name}" cannot be cloned (Archivable = false?); nothing was applied.`)
		return false
	end

	local removed = 0
	for _, child in Lighting:GetChildren() do
		if child:GetAttribute(Config.KeepAttribute) ~= true then
			child:Destroy()
			removed += 1
		end
	end

	local added = {}
	for _, child in clone:GetChildren() do
		child.Parent = Lighting
		table.insert(added, `{child.Name} ({child.ClassName})`)
	end
	clone:Destroy()

	-- A property the preset does not declare stays as it was: a preset can change
	-- only the fog without repeating the whole lighting setup.
	local written = {}
	for propertyName, value in LightingUtil.ReadPresetAttributes(preset) do
		local ok, err = pcall(function()
			(Lighting :: any)[propertyName] = value
		end)

		if ok then
			table.insert(written, propertyName)
		else
			log:StudioWarn(`preset "{name}" could not write Lighting.{propertyName}: {err}`)
		end
	end

	--[[
		Worth logging even when everything went right: without it, "applied and
		changed nothing" and "did not apply" look identical in the console, and a
		preset with no attributes produces the first case quite legitimately.
	]]
	log:Debug(string.format('preset "%s" applied | %d Lighting propert(ies): %s | %d instance(s) inside: %s | %d removed',
		name,
		#written, #written > 0 and table.concat(written, ", ") or "none (the folder declares no attributes)",
		#added, #added > 0 and table.concat(added, ", ") or "none",
		removed))

	if #written == 0 and #added == 0 then
		log:StudioWarn(`preset "{name}" is empty: no attributes and no children, so applying it changes nothing.`)
	end

	local previous = self.Current
	self.Current = name

	local duration = transitionTime or Config.Transition.Time
	for _, player in Players:GetPlayers() do
		Framework:Fire("LightingApplied", player, previous, name, duration)
	end

	return true
end

--[[ LIFECYCLE ]]

function LightingService:construct()
	-- A client asking which preset it should start with: answer without a transition,
	-- because its Lighting already arrived replicated in the final state.
	Framework:Listen("RequestLighting", function(player)
		local current = self:GetCurrent()
		if not current then return end

		Framework:Fire("LightingApplied", player, current, current, 0)
	end)
end

function LightingService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:_setup()
	self:construct()

	if Config.DefaultPreset then
		self:Apply(Config.DefaultPreset, 0)
	end
end

function LightingService:init()
	Framework:Listen("LightingApplied", function() end)
end

return LightingService
