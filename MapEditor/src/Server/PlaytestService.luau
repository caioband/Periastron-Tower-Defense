--!strict
--[[
	Playtest harness.

	The map is exported through PeriMapAdapter and loaded with a mirror of Peri's
	MapService:LoadMap (Content.Map -> workspace.Map, Nodes ->
	workspace.PathScriptable.Nodes + PublishNodeCounts, BaseHP and BoundingBox
	forced inert). Routes come from the same PathUtil.BuildRoutes MobService uses,
	enemies advance by distance along the smoothed route like MobService, and
	tower placement uses Peri's PlacementUtil.PathProbe against Grid parts.

	The editor's own Instances are parked in ServerStorage for the duration and
	the saved map table is never touched, so nothing from the test can leak into
	the map data. Peri loads into the fixed names workspace.Map and
	workspace.PathScriptable, so one playtest runs per server at a time.
]]
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local PathUtil = require(Shared.PathUtil)
local PlacementUtil = require(Shared.PlacementUtil)
local MapRules = require(Shared.MapRules)

local PeriMapAdapter = require(script.Parent.PeriMapAdapter)
local MapValidation = require(script.Parent.MapValidation)

local PERI = Config.PERI
local PT = Config.PLAYTEST

type Session = any

type Enemy = { part: BasePart, route: number, distance: number, health: number }
type Tower = { part: BasePart, position: Vector3, lastShot: number }

type State = {
	session: Session,
	export: Folder,
	parked: Instance?,
	mapClone: Instance?,
	spawnClone: Instance?,
	enemiesFolder: Folder,
	routes: { any },
	enemies: { Enemy },
	towers: { Tower },
	baseHealth: number,
	killed: number,
	leaked: number,
	spawning: boolean,
	connection: RBXScriptConnection?,
	label: TextLabel?,
	grid: { BasePart },
}

local PlaytestService = {}
local active: State? = nil

local function templates(): Instance
	return Shared:WaitForChild("Templates")
end

local function holding(): Folder
	local f = ServerStorage:FindFirstChild("MapEditorRuntime")
	if not f then
		f = Instance.new("Folder")
		f.Name = "MapEditorRuntime"
		f.Parent = ServerStorage
	end
	return f :: Folder
end

local function pathScriptableNodes(): Folder
	local ps = workspace:FindFirstChild("PathScriptable")
	if not ps then
		ps = Instance.new("Folder")
		ps.Name = "PathScriptable"
		ps.Parent = workspace
	end
	local nodes = (ps :: Instance):FindFirstChild("Nodes")
	if not nodes then
		nodes = Instance.new("Folder")
		nodes.Name = "Nodes"
		nodes.Parent = ps
	end
	return nodes :: Folder
end

local function inert(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

--[[ Mirror of MapService:LoadMap for a map folder, without lighting. ]]
local function loadMapFolder(mapFolder: Folder): (Instance?, Instance?)
	local content = mapFolder:FindFirstChild("Content")
	local clone: Instance? = nil
	if content then
		local map = content:FindFirstChild("Map")
		if map then
			clone = map:Clone()
			;(clone :: Instance).Parent = workspace

			local bounds = mapFolder:FindFirstChild(PERI.BoundsPartName)
			if bounds and bounds:IsA("BasePart") then
				local b = bounds:Clone()
				inert(b)
				b.Transparency = 1
				b.Parent = clone
			end

			local points = mapFolder:FindFirstChild("PlacementPoints")
			if points then
				local p = points:Clone()
				for _, part in p:GetDescendants() do
					if part:IsA("BasePart") then
						inert(part)
					end
				end
				p.Parent = clone
			end

			local baseHP = mapFolder:FindFirstChild(PERI.BaseHealthPart)
			if baseHP and baseHP:IsA("BasePart") then
				local b = baseHP:Clone()
				inert(b)
				b.Parent = clone
			end
		end
	end

	local spawnClone: Instance? = nil
	local spawn = mapFolder:FindFirstChild("SpawnLocation")
	if spawn and spawn:IsA("SpawnLocation") then
		local s = spawn:Clone()
		s.Enabled = false
		s.Parent = workspace
		spawnClone = s
	end

	local nodes = mapFolder:FindFirstChild("Nodes")
	if nodes then
		local target = pathScriptableNodes()
		for _, node in nodes:GetChildren() do
			local c = node:Clone()
			if c:IsA("BasePart") then
				c.Transparency = 0.5
			end
			for _, d in c:GetDescendants() do
				if d:IsA("BasePart") then
					d.Transparency = 0.5
				end
			end
			c.Parent = target
		end
		PathUtil.PublishNodeCounts(target)
	end

	return clone, spawnClone
end

local function gridParts(mapRoot: Instance?): { BasePart }
	local parts = {}
	for _, part in CollectionService:GetTagged(PERI.GridTag) do
		if part:IsA("BasePart") and mapRoot and part:IsDescendantOf(mapRoot) then
			table.insert(parts, part)
		end
	end
	return parts
end

local function stats(state: State): { [string]: any }
	return {
		state = "Running",
		baseHealth = state.baseHealth,
		maxHealth = PT.BaseHealth,
		alive = #state.enemies,
		killed = state.killed,
		leaked = state.leaked,
		towers = #state.towers,
		maxTowers = PT.MaxTowers,
		routes = #state.routes,
		spawning = state.spawning,
	}
end

local function setBaseLabel(state: State)
	if state.label then
		state.label.Text = tostring(state.baseHealth)
	end
end

local function newEnemy(state: State, routeIndex: number): Enemy
	local part = Instance.new("Part")
	part.Name = "TestEnemy"
	part.Size = PT.EnemySize
	part.Color = Color3.fromHex("C4281C")
	part.Material = Enum.Material.SmoothPlastic
	inert(part)
	local start = PathUtil.GetPositionAtDistance(state.routes[routeIndex].smooth, 0) or Vector3.zero
	part.CFrame = CFrame.new(start + Vector3.new(0, PT.EnemySize.Y / 2, 0))
	part.Parent = state.enemiesFolder
	return { part = part, route = routeIndex, distance = 0, health = PT.EnemyHealth }
end

local function flash(from: Vector3, to: Vector3, parent: Instance)
	local beam = Instance.new("Part")
	beam.Name = "Shot"
	inert(beam)
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromHex("F5CD30")
	local length = (to - from).Magnitude
	beam.Size = Vector3.new(0.2, 0.2, length)
	beam.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2)
	beam.Parent = parent
	task.delay(0.08, function()
		beam:Destroy()
	end)
end

local function step(state: State, dt: number)
	local now = os.clock()

	for i = #state.enemies, 1, -1 do
		local enemy = state.enemies[i]
		local smooth = state.routes[enemy.route].smooth
		enemy.distance += PT.EnemySpeed * dt
		if enemy.distance >= smooth.length then
			enemy.part:Destroy()
			table.remove(state.enemies, i)
			state.leaked += 1
			state.baseHealth = math.max(0, state.baseHealth - 1)
			setBaseLabel(state)
		else
			local position = PathUtil.GetPositionAtDistance(smooth, enemy.distance) :: Vector3
			local ahead = PathUtil.GetPositionAtDistance(smooth, math.min(smooth.length, enemy.distance + 0.5)) :: Vector3
			local lift = Vector3.new(0, PT.EnemySize.Y / 2, 0)
			local flat = (ahead - position) * Vector3.new(1, 0, 1)
			if flat.Magnitude > 1e-3 then
				enemy.part.CFrame = CFrame.lookAt(position + lift, position + lift + flat)
			else
				enemy.part.CFrame = CFrame.new(position + lift)
			end
		end
	end

	for _, tower in state.towers do
		if now - tower.lastShot < PT.TowerCooldown then
			continue
		end
		local best, bestDistance = nil, -1
		for _, enemy in state.enemies do
			local offset = (enemy.part.Position - tower.position) * Vector3.new(1, 0, 1)
			if offset.Magnitude <= PT.TowerRange and enemy.distance > bestDistance then
				best, bestDistance = enemy, enemy.distance
			end
		end
		if best then
			tower.lastShot = now
			best.health -= PT.TowerDamage
			flash(tower.position + Vector3.new(0, PT.TowerSize.Y / 2, 0), best.part.Position, state.enemiesFolder)
			if best.health <= 0 then
				local index = table.find(state.enemies, best)
				if index then
					table.remove(state.enemies, index)
				end
				best.part:Destroy()
				state.killed += 1
			end
		end
	end
end

function PlaytestService.isActive(session: Session?): boolean
	if not active then
		return false
	end
	return session == nil or active.session == session
end

function PlaytestService.start(session: Session): (boolean, any)
	if active then
		if active.session == session then
			return false, "A playtest is already running."
		end
		return false, "Another player is playtesting on this server. Try again in a moment."
	end
	if session.busy then
		return false, "Wait for the map to finish loading."
	end

	local validation = MapValidation.run(session)
	if #validation.errors > 0 then
		return false, { reason = "Fix the blocking errors before testing.", validation = validation }
	end

	local export, report = PeriMapAdapter.export(session.map, "Playtest_" .. session.player.UserId, templates(), session.origin)
	export.Parent = holding()

	session.objectsFolder.Parent = holding()
	session.mode = "Playtest"
	session.folder:SetAttribute("Mode", "Playtest")

	local mapClone, spawnClone = loadMapFolder(export)
	local routes = PathUtil.BuildRoutes(pathScriptableNodes())

	local enemiesFolder = Instance.new("Folder")
	enemiesFolder.Name = "MapEditorPlaytest"
	enemiesFolder.Parent = workspace

	local label: TextLabel? = nil
	if mapClone then
		local baseHP = mapClone:FindFirstChild(PERI.BaseHealthPart)
		local found = baseHP and baseHP:FindFirstChild(PERI.BaseHealthLabel, true)
		if found and found:IsA("TextLabel") then
			label = found
		end
	end

	local state: State = {
		session = session,
		export = export,
		mapClone = mapClone,
		spawnClone = spawnClone,
		enemiesFolder = enemiesFolder,
		routes = routes,
		enemies = {},
		towers = {},
		baseHealth = PT.BaseHealth,
		killed = 0,
		leaked = 0,
		spawning = false,
		label = label,
		grid = gridParts(mapClone),
	}
	active = state
	setBaseLabel(state)

	local lastPush = 0
	state.connection = RunService.Heartbeat:Connect(function(dt)
		step(state, dt)
		local now = os.clock()
		if now - lastPush > 0.25 then
			lastPush = now
			session.push("Playtest", stats(state))
		end
	end)

	local lengths = {}
	for _, route in routes do
		table.insert(lengths, math.floor(route.smooth.length * 10) / 10)
	end

	return true, {
		stats = stats(state),
		export = report,
		validation = validation,
		lengths = lengths,
		gridParts = #state.grid,
	}
end

function PlaytestService.spawnWave(session: Session): (boolean, string?)
	local state = active
	if not state or state.session ~= session then
		return false, "No playtest running."
	end
	if state.spawning then
		return false, "A wave is already spawning."
	end
	if #state.routes == 0 then
		return false, "The map has no route."
	end
	state.spawning = true
	task.spawn(function()
		for i = 1, PT.EnemyCount do
			if active ~= state then
				return
			end
			local routeIndex = ((i - 1) % #state.routes) + 1
			table.insert(state.enemies, newEnemy(state, routeIndex))
			task.wait(PT.EnemySpacing)
		end
		state.spawning = false
	end)
	return true, nil
end

function PlaytestService.checkTower(position: Vector3, grid: { BasePart }, towers: { Tower }, mapRoot: Instance?): (boolean, string?)
	local cf = CFrame.new(position + Vector3.new(0, PT.TowerSize.Y / 2, 0))
	local probeCF, probeSize = PlacementUtil.PathProbe(cf, PT.TowerSize)
	local gridParams = OverlapParams.new()
	gridParams.FilterType = Enum.RaycastFilterType.Include
	gridParams.FilterDescendantsInstances = grid
	if #workspace:GetPartBoundsInBox(probeCF, probeSize, gridParams) > 0 then
		return false, "On the path."
	end

	if mapRoot then
		local obstruction = OverlapParams.new()
		obstruction.FilterType = Enum.RaycastFilterType.Include
		obstruction.FilterDescendantsInstances = { mapRoot }
		local shrunk = PT.TowerSize - Vector3.new(0.2, 0.4, 0.2)
		for _, part in workspace:GetPartBoundsInBox(cf * CFrame.new(0, 0.2, 0), shrunk, obstruction) do
			if part.CanCollide then
				return false, "Obstructed by " .. part.Name .. "."
			end
		end
	end

	for _, tower in towers do
		if ((tower.position - position) * Vector3.new(1, 0, 1)).Magnitude < PT.TowerMinSpacing then
			return false, "Too close to another tower."
		end
	end

	if PlacementUtil.FindBlockingCharacter(cf, PT.TowerSize) then
		return false, "A player is standing there."
	end

	return true, nil
end

function PlaytestService.placeTower(session: Session, raw: any): (boolean, string?)
	local state = active
	if not state or state.session ~= session then
		return false, "No playtest running."
	end
	if #state.towers >= PT.MaxTowers then
		return false, "Tower limit reached for this test."
	end
	local aim = MapRules.readVector(raw)
	if not aim then
		return false, "Invalid position."
	end
	local localAim = session.origin:PointToObjectSpace(aim)
	if not MapRules.inBounds(localAim) then
		return false, "Outside the map."
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { state.mapClone :: Instance }
	local hit = workspace:Raycast(aim + Vector3.new(0, 6, 0), Vector3.new(0, -20, 0), params)
	if not hit then
		return false, "Towers need ground under them."
	end

	local ok, reason = PlaytestService.checkTower(hit.Position, state.grid, state.towers, state.mapClone)
	if not ok then
		return false, reason
	end

	local part = Instance.new("Part")
	part.Name = "TestTower"
	part.Size = PT.TowerSize
	part.CFrame = CFrame.new(hit.Position + Vector3.new(0, PT.TowerSize.Y / 2, 0))
	part.Color = Color3.fromHex("0D69AC")
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanQuery = false
	part.Parent = state.enemiesFolder

	local ring = Instance.new("Part")
	ring.Name = "Range"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.05, PT.TowerRange * 2, PT.TowerRange * 2)
	ring.CFrame = CFrame.new(hit.Position + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Transparency = 0.85
	ring.Color = Color3.fromHex("6E99CA")
	inert(ring)
	ring.Parent = part

	table.insert(state.towers, { part = part, position = hit.Position, lastShot = 0 })
	return true, nil
end

function PlaytestService.stop(session: Session): boolean
	local state = active
	if not state or state.session ~= session then
		return false
	end
	active = nil

	if state.connection then
		state.connection:Disconnect()
	end
	state.enemiesFolder:Destroy()
	if state.mapClone then
		state.mapClone:Destroy()
	end
	if state.spawnClone then
		state.spawnClone:Destroy()
	end
	local nodes = pathScriptableNodes()
	nodes:ClearAllChildren()
	nodes:SetAttribute(PERI.NodeCountAttribute, nil)
	nodes:SetAttribute(PERI.PointCountAttribute, nil)
	state.export:Destroy()

	if session.folder.Parent then
		session.objectsFolder.Parent = session.folder
	else
		session.objectsFolder:Destroy()
	end
	session.mode = "Build"
	session.folder:SetAttribute("Mode", "Build")
	session.push("Playtest", { state = "Stopped", killed = state.killed, leaked = state.leaked, baseHealth = state.baseHealth })
	return true
end

return PlaytestService
