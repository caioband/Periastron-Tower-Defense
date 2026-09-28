local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("WeatherService")

local Config = SharedConfig.WeatherConfig

-- Each apply is logged (Studio only) for the same reason as in LightingService:
-- fitting a Part on a map without `Terrain` gives a legitimate but surprising
-- result, and without the numbers you cannot tell which box was measured.

--[[
	The weather on the map in play.

	A weather is a Model in `Assets.Weathers` with one or more particle Parts and a
	`Lighting` folder. This service fits **each Part** to the loaded map the way its
	tag asks (`AreaWeather` or `SkyWeather`), and hands the folder to
	`LightingService`, which changes the lighting, so weather gets its interpolated
	transition for free.

	A weather can be both kinds: rain has a cloud layer in the sky and rain falling
	inside the play area, and the two measure different boxes of the map. See
	`WeatherConfig.Tags`.

		local Weather = Framework:Get("WeatherService")

		Weather:Apply("Snow")        -- transition at Lighting's default time
		Weather:Apply("Thunder", 4)  -- over 4s
		Weather:Clear()              -- removes it and restores the previous lighting

	It lives in `common/` because Weathers is shared. In practice only Game has
	`workspace.Map`, and without a map `Apply` refuses and says so.

	See docs/common/weather.md.
]]

local WeatherService = {
	Services = {
		LightingService = {}
	}
}

WeatherService.Current = nil :: string?
WeatherService.Container = nil :: Folder?

--[[
	The lighting preset from before the weather, so `Clear` has somewhere to return.
	It is only recorded on the first apply: switching weathers must not turn the
	"before" into the previous weather.
]]
WeatherService.RestorePreset = nil :: string?

--[[
	Tells clients which weather is active.

	`WeatherController` listens, so the background sound comes and goes with it:
	particles and lighting arrive on their own (replication and `LightingApplied`),
	but audio is local to each client.
]]
local function broadcastWeather(name: string?)
	for _, player in Players:GetPlayers() do
		Framework:Fire("WeatherChanged", player, name)
	end
end

--[[ MAP BOX ]]

--[[
	A Part's AABB, respecting its rotation.

	`Position ± Size/2` would only hold for an axis-aligned Part, and rotated terrain
	is common. The half-extent of a rotated box's AABB is `|R| * halfSize`, which is
	what the lines below do.
]]
local function partBounds(part: BasePart): (Vector3, Vector3)
	local cf, size = part.CFrame, part.Size
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2

	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()

	local extent = Vector3.new(
		math.abs(r00) * hx + math.abs(r01) * hy + math.abs(r02) * hz,
		math.abs(r10) * hx + math.abs(r11) * hy + math.abs(r12) * hz,
		math.abs(r20) * hx + math.abs(r21) * hy + math.abs(r22) * hz
	)

	return cf.Position - extent, cf.Position + extent
end

--[[
	The smallest box covering the BaseParts in `sources`, discarding those larger
	than `maxFootprint` in X or Z. Also returns how many were discarded.
]]
local function measureIn(sources: { Instance }, maxFootprint: number): (Vector3?, Vector3?, number)
	local minV, maxV
	local skipped = 0

	for _, source in sources do
		for _, descendant in source:GetDescendants() do
			if not descendant:IsA("BasePart") then continue end

			if descendant.Size.X > maxFootprint or descendant.Size.Z > maxFootprint then
				skipped += 1
				continue
			end

			local lo, hi = partBounds(descendant)
			minV = if minV then minV:Min(lo) else lo
			maxV = if maxV then maxV:Max(hi) else hi
		end
	end

	return minV, maxV, skipped
end

--[=[
	The map box: center, size, and a label for what was measured.

	`wholeMap` picks what counts, and the difference is the tags' own semantics:

	- **Sky** measures the whole map, background scenery included. The sky layer
	  covers everything visible, and ground painted to the horizon is part of that:
	  covering only the play area would leave a 93-stud patch over a visible world of
	  2048. The peak comes from here too: "the highest point of the loaded map", with
	  no cropping.
	- **Area** measures only `BoundsFolders`, and also discards parts larger than
	  `MaxPartFootprint`. Snow and rain happen where the game is played; measuring the
	  background would give a box 20x larger and spread the particles until they
	  vanish.
]=]
function WeatherService:GetMapBounds(target: Instance, wholeMap: boolean?): (Vector3?, Vector3?, string)
	--[[
		A box authored in the map wins, for both weather kinds. It is exact, while
		measuring the map depends on guessing what is background scenery, and both
		heuristics below fail precisely on maps whose background lives inside
		`Terrain` (the computed `Volcano` gives 500x500; its box is 147x109).

		Rotation is ignored: the boxes are axis-aligned.
	]]
	local authored = target:FindFirstChild(Config.BoundsPartName)
	if authored and authored:IsA("BasePart") then
		return authored.Position, authored.Size, Config.BoundsPartName
	end

	if wholeMap then
		local minV, maxV = measureIn({ target }, math.huge)
		if not minV or not maxV then
			return nil, nil, "whole map"
		end

		return (minV + maxV) / 2, maxV - minV, "whole map"
	end

	local sources = {}
	for _, folderName in Config.BoundsFolders do
		local folder = target:FindFirstChild(folderName)
		if folder then
			table.insert(sources, folder)
		end
	end

	local measured = table.concat(Config.BoundsFolders, "+")
	if #sources == 0 then
		sources = { target }
		measured = "whole " .. target.Name
	end

	local minV, maxV, skipped = measureIn(sources, Config.MaxPartFootprint)

	-- Nothing left standing after the cut: a small map made of a single part must
	-- still work.
	if not minV or not maxV then
		minV, maxV = measureIn(sources, math.huge)
		measured ..= " (no floor cut)"
	elseif skipped > 0 then
		measured ..= string.format(" (-%d floor)", skipped)
	end

	if not minV or not maxV then
		return nil, nil, measured
	end

	return (minV + maxV) / 2, maxV - minV, measured
end

--[[ FITTING ]]

--[=[
	Which of the two boxes this Part goes into: `"Area"`, `"Sky"`, or `nil`.

	The **Part's** tag wins. Without it the Model's applies, and only when the Model
	says a single thing: in a two-kind weather there is no way to guess which one an
	untagged Part belongs to. That is what lets single-tag weathers (one tag on the
	Model, untagged Parts) keep working without being reauthored.
]=]
function WeatherService:_partKind(model: Model, part: BasePart): string?
	if CollectionService:HasTag(part, Config.Tags.Area) then
		return "Area"
	end

	if CollectionService:HasTag(part, Config.Tags.Sky) then
		return "Sky"
	end

	local isArea = CollectionService:HasTag(model, Config.Tags.Area)
	local isSky = CollectionService:HasTag(model, Config.Tags.Sky)

	if isArea and not isSky then
		return "Area"
	end

	if isSky and not isArea then
		return "Sky"
	end

	return nil
end

--[=[
	The map box, measured at most once per kind.

	The two kinds measure different things (see `GetMapBounds`), and a mixed weather
	needs both, but a sky Part and an area Part must not come from two different
	measurements of the same map, nor cost two sweeps when the weather is a single
	kind.
]=]
function WeatherService:_boundsReader(target: Instance)
	local cache = {}

	return function(kind: string): (Vector3?, Vector3?, string)
		local entry = cache[kind]

		if not entry then
			-- Sky measures the whole map, Area only the play area.
			entry = table.pack(self:GetMapBounds(target, kind == "Sky"))
			cache[kind] = entry
		end

		return entry[1], entry[2], entry[3]
	end
end

--[=[
	The Part comes from the asset with `CanCollide = true`. Stretched to cover the
	map, it would become an invisible wall over the play area, and with `CanQuery`
	on, the footstep raycast and unit placement validation would hit it.
]=]
local function makeIntangible(instance: Instance)
	for _, part in instance:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
		end
	end
end

--[=[
	Fits **one** Part to the box its kind asks for. Returns a description of what it
	did, for the log and for the command's answer.
]=]
function WeatherService:_fitPart(model: Model, part: BasePart, kind: string, center: Vector3, size: Vector3): string
	if kind == "Area" then
		part.Size = size
		part.CFrame = CFrame.new(center)

		return string.format("area %.0fx%.0fx%.0f at (%.0f, %.0f, %.0f)",
			size.X, size.Y, size.Z, center.X, center.Y, center.Z)
	end

	-- The layer's thickness is the authored one; what follows the map is X and Z.
	local thickness = part.Size.Y
	local offset = model:GetAttribute(Config.HeightOffsetAttribute) or Config.SkyHeightOffset
	local peak = center.Y + size.Y / 2

	part.Size = Vector3.new(size.X, thickness, size.Z)
	part.CFrame = CFrame.new(center.X, peak + offset, center.Z)

	return string.format("sky %.0fx%.0f (thickness %.0f) at (%.0f, %.0f, %.0f), map center, %.0f above the peak %.0f",
		size.X, size.Z, thickness,
		part.CFrame.Position.X, part.CFrame.Position.Y, part.CFrame.Position.Z,
		offset, peak)
end

--[=[
	Fits **every** Part of the weather, each one in its kind's box. Returns a
	description of what it did, or `nil` plus the reason when nothing ended up fitted.

	Only direct children count: the ParticleEmitters live inside the Parts, and a
	nested decorative geometry is not a weather layer.

	A lone Part that does not fit takes down the whole weather (the single-Part
	weather case, which the command needs to report); with several, the one that
	fails is left out with a warning and the others load. Half a weather on screen
	is easier to diagnose than none, and the warning says which one is missing.
]=]
function WeatherService:_fit(model: Model, bounds): (string?, string?)
	local parts = {}
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end

	if #parts == 0 then
		return nil, "has no BasePart to fit"
	end

	local fitted = {}
	local failures = {}

	for _, part in parts do
		local kind = self:_partKind(model, part)
		if not kind then
			table.insert(failures, string.format("%s has neither the %s nor the %s tag (the weather has both kinds, so each Part must declare its own)",
				part.Name, Config.Tags.Area, Config.Tags.Sky))
			continue
		end

		local center, size, measured = bounds(kind)
		if not center or not size then
			table.insert(failures, string.format("%s (%s): the map has no BasePart in %s", part.Name, kind, measured))
			continue
		end

		table.insert(fitted, self:_fitPart(model, part, kind, center, size))
	end

	if #fitted == 0 then
		return nil, table.concat(failures, "; ")
	end

	for _, failure in failures do
		log:StudioWarn(`"{model.Name}": {failure}.`)
	end

	return table.concat(fitted, " + "), nil
end

--[[ API ]]

function WeatherService:GetContainer(): Folder
	local container = self.Container
	if container and container.Parent then
		return container
	end

	container = workspace:FindFirstChild(Config.ContainerName) :: Folder
	if not container then
		local folder = Instance.new("Folder")
		folder.Name = Config.ContainerName
		folder.Parent = workspace
		container = folder
	end

	self.Container = container
	return container
end

function WeatherService:GetRoot(): Folder?
	local current: Instance? = ReplicatedStorage

	for _, name in Config.AssetsPath do
		if not current then return nil end
		current = current:FindFirstChild(name)
	end

	return current :: Folder?
end

function WeatherService:GetWeather(name: string): Model?
	local root = self:GetRoot()
	if not root then return nil end

	local model = root:FindFirstChild(name)
	if not model or not model:IsA("Model") then
		return nil
	end

	return model
end

function WeatherService:GetNames(): { string }
	local names = {}

	local root = self:GetRoot()
	if not root then
		return names
	end

	for _, model in root:GetChildren() do
		if model:IsA("Model") then
			table.insert(names, model.Name)
		end
	end

	table.sort(names)
	return names
end

function WeatherService:GetCurrent(): string?
	return self.Current
end

--[=[
	Turns the weather on over the loaded map.

	`transitionTime` is passed to LightingService; `0` is a hard cut. Returns
	`(ok, message)`; the message is what the command shows.
]=]
function WeatherService:Apply(name: string, transitionTime: number?): (boolean, string)
	local model = self:GetWeather(name)
	if not model then
		return false, string.format("weather '%s' does not exist in Assets.Weathers.", name)
	end

	local isArea = CollectionService:HasTag(model, Config.Tags.Area)
	local isSky = CollectionService:HasTag(model, Config.Tags.Sky)
	if not isArea and not isSky then
		return false, string.format("weather '%s' has neither the %s nor the %s tag.", name, Config.Tags.Area, Config.Tags.Sky)
	end

	local target = workspace:FindFirstChild(Config.TargetName)
	if not target then
		return false, string.format("there is no '%s' in the Workspace to fit the weather to.", Config.TargetName)
	end

	local clone = model:Clone()
	if not clone then
		return false, string.format("weather '%s' cannot be cloned (Archivable = false?).", name)
	end

	local fitted, reason = self:_fit(clone, self:_boundsReader(target))
	if not fitted then
		clone:Destroy()
		return false, string.format("weather '%s' did not fit: %s.", name, reason or "unknown reason")
	end

	makeIntangible(clone)

	-- One weather at a time: the previous one leaves before the new one enters.
	local container = self:GetContainer()
	container:ClearAllChildren()
	clone.Parent = container

	-- The Lighting folder is optional: a weather can be particles only.
	local applied = "no Lighting folder"
	local lightingFolder = clone:FindFirstChild("Lighting")

	if lightingFolder then
		local LightingService = self.Services.LightingService

		if LightingService and LightingService.Register then
			if not self.Current then
				self.RestorePreset = LightingService:GetCurrent()
			end

			local preset = LightingService:Register(lightingFolder, Config.PresetPrefix .. name)
			if preset and LightingService:Apply(preset, transitionTime) then
				applied = string.format("preset %s", preset)
			else
				applied = "the Lighting folder failed (see the Output)"
			end
		else
			applied = "LightingService unavailable"
		end

		-- `Register` already stored its copy in `Assets.Lighting`. Lighting effects
		-- inside a Folder in the Workspace do nothing, so leaving the original
		-- hanging in the clone would only replicate dead weight.
		lightingFolder:Destroy()
	end

	self.Current = name
	broadcastWeather(name)

	-- `fitted` already carries the size and center of each fitted Part, one per kind.
	log:Debug(string.format("'%s' applied | %s | %s", name, fitted, applied))

	return true, string.format("Weather: %s | %s | %s.", name, fitted, applied)
end

--[=[
	Removes the weather and restores the lighting from before it.
]=]
function WeatherService:Clear(transitionTime: number?): (boolean, string)
	if not self.Current then
		return false, "no weather is on."
	end

	local previous = self.Current
	self:GetContainer():ClearAllChildren()
	self.Current = nil
	broadcastWeather(nil)

	local restore = self.RestorePreset
	self.RestorePreset = nil

	if restore then
		local LightingService = self.Services.LightingService
		if LightingService and LightingService.Apply then
			LightingService:Apply(restore, transitionTime)
		end
	end

	log:Debug(string.format("'%s' removed | lighting restored to %s", previous, restore or "(nothing recorded)"))

	return true, string.format("Weather off (was %s; lighting restored to %s).", previous, restore or "what it was before")
end

--[[ LIFECYCLE ]]

function WeatherService:construct()
	Framework:Listen("RequestWeather", function(player: Player)
		Framework:Fire("WeatherChanged", player, self.Current)
	end)
end

function WeatherService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function WeatherService:init()
	Framework:Listen("WeatherChanged", function() end)
end

return WeatherService
