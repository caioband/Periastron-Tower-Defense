local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

--[[
	Maps live in ServerStorage, not ReplicatedStorage.

	That changes one important thing for anyone working here: the client sees no map
	at all, only the clone this service puts in `workspace.Map`. So
	`CollectionService:GetTagged("Grid")` on the client returns exactly the parts of the
	map in play, not every map's parts combined.

	See docs/game/maps.md.
]]
local Maps = ServerStorage:WaitForChild("Maps")

-- An attribute on the `Maps` folder that forces the map in a Studio play. See `getStudioMap`.
local STUDIO_MAP_ATTRIBUTE = "StudioMap"

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local MapConfig = SharedConfig.MapConfig
local TutorialConfig = SharedConfig.TutorialConfig

local PathUtil = require(Shared.Util.PathUtil)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("MapService")

local LightingConfig = SharedConfig.LightingConfig
local WeatherConfig = SharedConfig.WeatherConfig

local ExampleService = {
	Services = {
		LightingService = {},
		DataService = {},
		IndexService = {},
	}
}

--[=[
	Waits for a service to appear in the loader, with a limit.

	A yielding `Framework:Get` would wait forever if the service did not exist, and an
	`init` silently stuck would be worse than loading the map without lighting.
	`Me:Load` finishes in much less than this.
]=]
local function waitForService(name : string, timeout : number?)
	local deadline = os.clock() + (timeout or 5)

	repeat
		local service = Framework:Get(name)
		if service then
			return service
		end
		task.wait()
	until os.clock() >= deadline

	return nil
end

--[=[
	Any map among those MapConfig offers that actually exists in the folder. The config
	rules because it is the only thing the Lobby can read about maps: drawing something
	outside it would give a map the portal does not know how to show.
]=]
function ExampleService:pickRandomMap() : string?
	local candidates = {}
	for _, name in MapConfig.getOrderedMaps() do
		if Maps:FindFirstChild(name) then
			table.insert(candidates, name)
		end
	end

	-- Empty or stale config: better to fall back to what exists in the folder than
	-- to load no map at all.
	if #candidates == 0 then
		log:Warn("no MapConfig map exists in ServerStorage.Maps; picking straight from the folder.")
		for _, folder in Maps:GetChildren() do
			table.insert(candidates, folder.Name)
		end
	end

	if #candidates == 0 then
		return nil
	end

	return candidates[math.random(1, #candidates)]
end

--[=[
	The map the group chose in the Lobby, if it came.

	The Lobby's `PortalService` attaches `{ Map = ... }` to the TeleportData of a single
	TeleportAsync call for the whole group, so any player on the server carries the
	same choice. `resolveMap` validates against MapConfig and normalizes the case; an
	unknown name returns nil and falls back to the random draw.
]=]
--[=[
	The map name this server accepts loading.

	It is `MapConfig.resolveMap` **plus** the tutorial map, which stays out of
	`MapConfig` on purpose: there, it would enter the end-of-match draw and the Lobby's
	choice screen, and nobody wants to land on the tutorial map by chance.

	Without this, both the `StudioMap = "Tutorial"` attribute and the Lobby's
	TeleportData would be refused as an "unknown name" and the server would draw
	another map, with the tutorial running on a map that lacks its `PlacementPoints`.
]=]
function ExampleService:resolveMapName(mapName : string?) : string?
	local tutorialMap = TutorialConfig.Match.Map

	if typeof(mapName) == "string" and string.lower(mapName) == string.lower(tutorialMap) then
		return if Maps:FindFirstChild(tutorialMap) then tutorialMap else nil
	end

	return MapConfig.resolveMap(mapName)
end

function ExampleService:getTeleportedMap(player : Player) : string?
	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	if not success or typeof(joinData) ~= "table" then
		return nil
	end

	local teleportData = joinData.TeleportData
	if typeof(teleportData) ~= "table" then
		return nil
	end

	local resolved = self:resolveMapName(teleportData.Map)
	if resolved and not Maps:FindFirstChild(resolved) then
		log:Warn(string.format("the Lobby asked for '%s', which MapConfig knows but does not exist in ServerStorage.Maps.", resolved))
		return nil
	end

	return resolved
end

--[=[
	The map requested by the `StudioMap` attribute on the `ServerStorage.Maps` folder,
	to test a specific map in Studio without depending on the draw.

	Only `resolveStartingMap` reads this, and only in Studio: the real server still
	obeys the Lobby. It goes through the same validation as TeleportData: a name
	outside MapConfig or without a folder warns and falls back to the draw, instead of
	starting with no map.
]=]
function ExampleService:getStudioMap() : string?
	local requested = Maps:GetAttribute(STUDIO_MAP_ATTRIBUTE)
	if typeof(requested) ~= "string" or requested == "" then
		return nil
	end

	local resolved = self:resolveMapName(requested)
	if not resolved or not Maps:FindFirstChild(resolved) then
		log:StudioWarn(string.format("the %s attribute asks for '%s', which is not in MapConfig or does not exist in ServerStorage.Maps; picking at random.",
			STUDIO_MAP_ATTRIBUTE, requested))
		return nil
	end

	return resolved
end

--[=[
	Decides which map to load.

	Studio has no TeleportData, so `StudioMap` applies (see `getStudioMap`) and, without
	it, it draws and moves on, with no warning, so every test's output stays clean. On a
	real server the map is expected to come from the Lobby; if it does not, it warns and
	draws.

	Yields: on a server it needs a player to read JoinData, and the first only arrives
	after boot.
]=]
function ExampleService:resolveStartingMap() : string?
	if RunService:IsStudio() then
		return self:getStudioMap() or self:pickRandomMap()
	end

	local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()

	local mapName = self:getTeleportedMap(player)
	if mapName then
		return mapName
	end

	log:Warn("server has no valid map in TeleportData; picking at random.")
	return self:pickRandomMap()
end

--[=[
	The map folder's first `SpawnLocation`: the one named `SpawnLocation` at the root
	(the one `LoadMap` clones) and, without it, the first one at any level of the
	folder.
]=]
local function findMapSpawn(MapInstance : Instance) : SpawnLocation?
	local direct = MapInstance:FindFirstChild("SpawnLocation")
	if direct and direct:IsA("SpawnLocation") then
		return direct
	end

	return MapInstance:FindFirstChildWhichIsA("SpawnLocation", true)
end

--[=[
	Stores where the character should appear on the map that just loaded and moves
	anyone already in play there.

	The cloned `SpawnLocation` already handles the common case; this is the safety net
	under it. Roblox picks among **all** enabled SpawnLocations in the Workspace, and
	one forgotten in the place (or a character spawned before the map existed) puts the
	player off the map.

	Only the position comes from the SpawnLocation; rotation keeps only the yaw, so a
	tilted spawn does not spawn the character crooked.
]=]
function ExampleService:setSpawnFallback(MapInstance : Instance)
	local spawn = findMapSpawn(MapInstance)
	if not spawn then
		self.SpawnCFrame = nil
		log:StudioWarn(string.format("map '%s' has no SpawnLocation; no spawn fallback.", MapInstance.Name))
		return
	end

	local position = spawn.Position + Vector3.new(0, MapConfig.SPAWN_HEIGHT_OFFSET, 0)
	local look = spawn.CFrame.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	end

	self.SpawnCFrame = CFrame.lookAt(position, position + look.Unit)

	for _, player in Players:GetPlayers() do
		if player.Character then
			task.spawn(self.ensureAtSpawn, self, player.Character)
		end
	end
end

--[=[
	Moves the character to `SpawnCFrame` if it is outside the spawn radius.

	Waits for `HumanoidRootPart` and one `Heartbeat`: `CharacterAdded` may arrive
	before Roblox positions the character, and moving before that would be undone.
]=]
function ExampleService:ensureAtSpawn(character : Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root or not root:IsA("BasePart") then
		return
	end

	RunService.Heartbeat:Wait()

	local target = self.SpawnCFrame
	if not target or not character.Parent then
		return
	end

	local offset = (root.Position - target.Position) * Vector3.new(1, 0, 1)
	if offset.Magnitude <= MapConfig.SPAWN_FALLBACK_RADIUS then
		return
	end

	root.AssemblyLinearVelocity = Vector3.zero
	character:PivotTo(target)
end

--[=[
	Hooks `ensureAtSpawn` up to every character that spawns, respawns included.

	Connected in `init` before deciding the map: with no map yet, `SpawnCFrame` is nil
	and `ensureAtSpawn` does nothing; anyone who spawned in that window is caught by
	`setSpawnFallback` when the map arrives.
]=]
function ExampleService:watchSpawns()
	local function watch(player : Player)
		player.CharacterAdded:Connect(function(character)
			self:ensureAtSpawn(character)
		end)
	end

	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
end

function ExampleService:LoadMap(Name : string)
	local MapInstance = Maps:FindFirstChild(Name)
	if not MapInstance then return end

	self.CurrentMapName = Name

	local MapContent = MapInstance:FindFirstChild("Content")
	if MapContent then
		local Map = MapContent:FindFirstChild("Map")
		local Clone = Map:Clone()
		Clone.Parent = workspace

		--[=[
			The BoundingBox is a sibling of Content in the map folder, but its consumer
			is WeatherService, which only sees the Workspace, so it comes in with the map.

			Inert on purpose: `CanQuery` off takes it out of the footstep raycast and unit
			placement validation, which sweep what is on top of the map.
		]=]
		local Bounds = MapInstance:FindFirstChild(WeatherConfig.BoundsPartName)
		if Bounds and Bounds:IsA("BasePart") then
			local BoundsClone = Bounds:Clone()
			BoundsClone.Anchored = true
			BoundsClone.CanCollide = false
			BoundsClone.CanQuery = false
			BoundsClone.CanTouch = false
			BoundsClone.Transparency = 1
			BoundsClone.Parent = Clone
		else
			log:StudioWarn(string.format("map '%s' has no '%s' Part; weather falls back to the computed box.",
				Name, WeatherConfig.BoundsPartName))
		end

		--[=[
			BaseHP is a sibling of Content like the BoundingBox, and comes in with the map
			for the same reason: its billboard is the only place the player sees the base
			health, and of the map the client only sees what is in `workspace.Map`.

			The clone is forced anchored and inert: a loose Part would fall out of the
			world taking the billboard with it, and `CanQuery` on would put it in the
			raycast that validates unit placement, which sweeps exactly what is on top of
			the map. The appearance stays as authored. `BaseHealthController`, on the
			client, writes the number.
		]=]
		--[=[
			`PlacementPoints` are siblings of Content, like the BoundingBox and BaseHP, and
			come in for the same reason: their consumers (the tutorial script, to know
			where the unit must go, and the arrow that points at the spot) only see what is
			in `workspace.Map`.

			The parts come in inert. They are ground marks, not scenery: colliding would
			push the player, and `CanQuery` on would put them in the placement validation
			raycast: the spot's mark would refuse the very unit it asks for.

			A map without the folder warns about nothing: only the tutorial's has it.
		]=]
		local Points = MapInstance:FindFirstChild("PlacementPoints")
		if Points then
			local PointsClone = Points:Clone()

			for _, part in PointsClone:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
				end
			end

			PointsClone.Parent = Clone
		end

		local BaseHP = MapInstance:FindFirstChild(MapConfig.BASE_HEALTH_PART)
		if BaseHP and BaseHP:IsA("BasePart") then
			local BaseHPClone = BaseHP:Clone()
			BaseHPClone.Anchored = true
			BaseHPClone.CanCollide = false
			BaseHPClone.CanQuery = false
			BaseHPClone.CanTouch = false
			BaseHPClone.Parent = Clone
		else
			log:StudioWarn(string.format("map '%s' has no '%s' Part; the base health will not show anywhere.",
				Name, MapConfig.BASE_HEALTH_PART))
		end
	end

	local Spawn = MapInstance:FindFirstChild("SpawnLocation")
	if Spawn then
		local SpawnClone = Spawn:Clone()
		SpawnClone.Enabled = true
		SpawnClone.Parent = workspace
	end

	self:setSpawnFallback(MapInstance)

	local Nodes = MapInstance:FindFirstChild("Nodes")
	if Nodes then
		local transparency = self.Debug and 0.5 or 1

		for _, Node : Instance in Nodes:GetChildren() do
			local Clone = Node:Clone()

			-- A node can be a Part (a point) or a Folder with a whole segment inside,
			-- when the map has a fork. A Folder has no Transparency, so the property is
			-- applied to the BaseParts.
			if Clone:IsA("BasePart") then
				Clone.Transparency = transparency
			end
			for _, descendant in Clone:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Transparency = transparency
				end
			end

			Clone.Parent = workspace.PathScriptable.Nodes
		end

		-- The client builds the routes from these replicated nodes and needs to know
		-- when pieces stopped missing. See `PathUtil.WaitForNodes`.
		PathUtil.PublishNodeCounts(workspace.PathScriptable.Nodes)
	end

	--[=[
		The map's lighting goes through LightingService.

		`Register` clones the folder into `Assets.Lighting` before applying, and that
		clone is what makes the transition possible: maps live in ServerStorage, which
		does not replicate, so without it the client would have nowhere to read the
		target values from.

		A map without the folder keeps the lighting authored in the place: `Snowy` is
		like that today.
	]=]
	local MapLighting = MapInstance:FindFirstChild("Lighting")
	if not MapLighting then
		-- Said out loud because in the console it is indistinguishable from "the service failed".
		log:StudioWarn(string.format("map '%s' has no Lighting folder; the lighting stays as it was.", Name))
		return
	end

	local LightingService = self.Services.LightingService
	if not LightingService or not LightingService.Register then
		log:Warn("LightingService unavailable; the map lighting was not applied.")
		return
	end

	local presetName = LightingConfig.MapPrefix .. Name

	-- `registerMapLighting` normally already registered everyone in init; this covers
	-- a LoadMap of a map that showed up later.
	if not LightingService:GetPreset(presetName) then
		presetName = LightingService:Register(MapLighting, presetName) or presetName
	end

	LightingService:Apply(presetName)
end

--[=[
	Registers EVERY map's `Lighting` folder as a preset, not only the loaded map's.

	Maps live in ServerStorage and do not replicate; `Register` clones each folder into
	`Assets.Lighting`, which is what lets the client see all of them. Without this the
	`lighting` command could only offer the one for the map in play, and switching
	lighting to test needs exactly the others.

	It is six small instances per map; the cost of replicating all of them is
	irrelevant next to being able to compare one with another in play.
]=]
function ExampleService:registerMapLighting() : number
	local LightingService = self.Services.LightingService
	if not LightingService or not LightingService.Register then
		return 0
	end

	local registered = 0
	local missing = {}

	for _, map in Maps:GetChildren() do
		local mapLighting = map:FindFirstChild("Lighting")
		if not mapLighting then
			table.insert(missing, map.Name)
			continue
		end

		if LightingService:Register(mapLighting, LightingConfig.MapPrefix .. map.Name) then
			registered += 1
		end
	end

	if #missing > 0 then
		log:StudioWarn(string.format("left out of the presets for having no Lighting folder: %s.", table.concat(missing, ", ")))
	end

	return registered
end

function ExampleService:construct()
	Framework:Listen("RequestMapMusic", function(player : Player)
	--	if not self.CurrentMapName then return end
		-- The track's name, not the map's: the other side looks for the Sound by exact
		-- name, and not every track is named after the map folder
		-- (see `MapConfig.getMusic`).
		Framework:Fire("PlayMapMusic", player, MapConfig.getMusic(self.CurrentMapName))
	end)

	self:watchIndex()
end

--[=[
	This server's map enters the Index of everyone playing.

	"Played for the first time" is here: the match server is reserved and starts
	already knowing the map (`resolveStartingMap`), so being in it **is** playing:
	there is no round to wait for, and someone who leaves on the first wave also
	played.

	Hooked to `PlayerDataLoaded` and not `PlayerAdded` because the Index is a profile
	write: with no open profile there is nowhere to save. Both sides are covered:
	players joining later through the signal, players already in through the sweep.
]=]
function ExampleService:watchIndex()
	local dataService = self.Services.DataService
	local indexService = self.Services.IndexService

	if not dataService or not indexService then
		log:Warn("no DataService/IndexService; the map does not enter the Index.")
		return
	end

	local function record(player : Player)
		if not self.CurrentMapName then return end

		indexService:UnlockMap(player, self.CurrentMapName)
	end

	dataService.Signals.PlayerDataLoaded:Connect(record)

	for _, player in Players:GetPlayers() do
		if dataService.Profiles and dataService.Profiles[player] then
			record(player)
		end
	end
end

function ExampleService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function ExampleService:init()

	Framework:Listen("PlayMapMusic", function() end)

	--[[
		LightingService comes in here, before deciding the map, on purpose: this is the
		last moment when yielding the thread costs nothing. Once the map is decided,
		LoadMap runs inside PlayerAdded and can no longer stop (see below), and `start`,
		which would normally resolve dependencies, runs after this `init`.
	]]
	self.Services.LightingService = waitForService("LightingService")
	if not self.Services.LightingService then
		log:Warn("LightingService did not load; the map will load without changing the lighting.")
	else
		-- Every map becomes a preset, not only the one to be loaded: that is what lets the
		-- `lighting` command switch between lightings to compare.
		local registered = self:registerMapLighting()
		log:Debug(string.format("%d map lighting(s) registered in Assets.Lighting.", registered))
	end

	--[[
		Loaded as soon as there is a way to decide, not under a fixed name.

		On a server this waits for the first player (that is where JoinData comes
		from). Nothing that depends on the map runs before: `MobService:getRoutes()` only
		builds the path on the first wave, and `WaveService` does not even start the
		round until a player is ready. The `SpawnLocation` also arrives in time: LoadMap
		does not yield at all, so it finishes inside PlayerAdded itself, before the
		character spawns.
	]]
	self:watchSpawns()

	local mapName = self:resolveStartingMap()
	if not mapName then
		log:Warn("no map available to load.")
		return
	end

	self:LoadMap(mapName)
	log:Debug(string.format("map loaded: %s", mapName))
end

return ExampleService
