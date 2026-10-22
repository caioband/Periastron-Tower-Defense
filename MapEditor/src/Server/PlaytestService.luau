--[[
	Playtest harness, running Peri's real data.

	The map is exported through PeriMapAdapter and loaded with a mirror of Peri's
	MapService:LoadMap (Content.Map -> workspace.Map, Nodes ->
	workspace.PathScriptable.Nodes + PublishNodeCounts, BaseHP and BoundingBox
	forced inert). Routes come from the same PathUtil.BuildRoutes MobService uses.

	A test opens in the "Setup" phase: the client shows PlaytestSetup, the player
	picks a difficulty, a start wave and a loadout, and `configure` applies the
	preset from ServerScriptService.Config.Difficulty (cash, base health, leak
	damage, wave pacing). Waves come from Config.Wave.GetSpawns, so every
	difficulty (Endless included) spawns exactly what its table says, with the
	real health, speed, reward and spawn delays. Enemies and towers are the models
	in ReplicatedStorage.Shared.Assets, and enemies wear the game's own health bar
	(Assets.UI.HealthAttachment). Towers read UnitStats through UnitUpgradeConfig
	at their current level, so damage, range, cooldown, slow, income, upgrade cost
	and sell value follow the same getters the match uses; target priority uses
	SharedConfig.TargetPriority. Model attributes `Upgrades`, `TargetPriority` and
	`DamageDone` mirror what UnitService writes, for the upgrade card.

	The editor's own Instances are parked in ServerStorage for the duration and
	the saved map table is never touched, so nothing from the test can leak into
	the map data. Peri loads into the fixed names workspace.Map and
	workspace.PathScriptable, so one playtest runs per server at a time.
]]
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local PathUtil = require(Shared.PathUtil)
local PlacementUtil = require(Shared.PlacementUtil)
local MapRules = require(Shared.MapRules)

local PeriMapAdapter = require(script.Parent.PeriMapAdapter)
local MapValidation = require(script.Parent.MapValidation)

local PeriShared = ReplicatedStorage:WaitForChild("Shared")
local SharedConfigModule = PeriShared:WaitForChild("Config"):WaitForChild("SharedConfig")
local SharedConfig = require(SharedConfigModule)
local Mob = SharedConfig.Mob
local UnitStats = SharedConfig.UnitStats
local UnitUpgradeConfig = SharedConfig.UnitUpgradeConfig
local TargetPriority = SharedConfig.TargetPriority

local Assets = PeriShared:WaitForChild("Assets")
local UnitAssets = Assets:WaitForChild("Units")
local EntityAssets = Assets:WaitForChild("Entities")
local DifficultyAssets = EntityAssets:WaitForChild("Difficulties")

local PeriConfig = ServerScriptService:WaitForChild("Config")
local Difficulty = require(PeriConfig:WaitForChild("Difficulty"))
local Wave = require(PeriConfig:WaitForChild("Wave"))
local Data = require(PeriConfig:WaitForChild("Data"))

local PERI = Config.PERI
local PT = Config.PLAYTEST

local LOADOUT_SIZE = 6
local MAX_TOWERS = 40
local ENDLESS_WAVE_CAP = 1000
local SELL_RATIO = SharedConfig.SellRefundRatio or 0.5
local CASH_PER_DAMAGE = Data.CASH_PER_DAMAGE or 0.15
local PUSH_INTERVAL = 0.25
local TOWER_TAG = "PlaytestTowerId"

type Session = any

local PlaytestService = {}
local active = nil

local templateCache = {}

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

-- Models ---------------------------------------------------------------------

local function findEntityTemplate(name: string): Model?
	local entity = Mob.Entities[name]
	if entity and entity.Folder then
		local folder = DifficultyAssets:FindFirstChild(entity.Folder)
		local model = folder and folder:FindFirstChild(name)
		if model and model:IsA("Model") then
			return model
		end
	end
	for _, folder in DifficultyAssets:GetChildren() do
		local model = folder:FindFirstChild(name)
		if model and model:IsA("Model") then
			return model
		end
	end
	return nil
end

local function templateInfo(model: Model)
	local cached = templateCache[model]
	if cached then
		return cached
	end
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	local cf, size = model:GetBoundingBox()
	local lift = 1.2
	if root and root:IsA("BasePart") then
		lift = root.Position.Y - (cf.Position.Y - size.Y / 2)
	end
	local info = { lift = lift, height = size.Y }
	templateCache[model] = info
	return info
end

local function findAnimation(model: Instance, names: { string }): Animation?
	for _, name in names do
		local anim = model:FindFirstChild(name)
		if anim and anim:IsA("Animation") then
			return anim
		end
	end
	return nil
end

local function firstAttackAnimation(model: Instance): Animation?
	local anim = findAnimation(model, { "Attack", "Slash1", "Attack2", "StartAttack", "MoneyWave", "Meteor", "Lighting" })
	if anim then
		return anim
	end
	for _, child in model:GetChildren() do
		if child:IsA("Animation") and child.Name ~= "Idle" and child.Name ~= "Walk" then
			return child
		end
	end
	return nil
end

local function animatorFor(model: Model): Animator
	local controller = model:FindFirstChildOfClass("AnimationController")
	if not controller then
		controller = Instance.new("AnimationController")
		controller.Parent = model
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end
	return animator
end

local function rig(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not root or not root:IsA("BasePart") then
		return nil
	end
	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
			d.Anchored = d == root
		end
	end
	return root
end

local function playLoop(animator: Animator, animation: Animation?, speed: number?): AnimationTrack?
	if not animation then
		return nil
	end
	local ok, track = pcall(animator.LoadAnimation, animator, animation)
	if not ok or not track then
		return nil
	end
	track.Looped = true
	track:Play(0.1)
	if speed then
		track:AdjustSpeed(speed)
	end
	return track
end

local function healthBar(root: BasePart, name: string)
	local folder = Assets:FindFirstChild("UI")
	local template = folder and folder:FindFirstChild("HealthAttachment")
	if not template then
		return nil
	end
	local attachment = template:Clone()
	attachment.Parent = root
	local billboard = attachment:FindFirstChildOfClass("BillboardGui")
	if not billboard then
		return nil
	end
	billboard.Enabled = true
	local bar = billboard:FindFirstChild("Bar")
	local mobName = billboard:FindFirstChild("MobName")
	if mobName and mobName:IsA("TextLabel") then
		mobName.Text = name
	end
	return {
		clip = bar and bar:FindFirstChild("ScaleThis"),
		text = bar and bar:FindFirstChildOfClass("TextLabel"),
	}
end

local HEALTH_TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function setHealthBar(enemy, instant: boolean?)
	local ui = enemy.healthUi
	if not ui then
		return
	end
	local ratio = math.clamp(enemy.health / math.max(enemy.maxHealth, 1), 0, 1)
	local target = UDim2.new(ratio, 0, 1, 0)
	if ui.clip then
		if instant then
			ui.clip.Size = target
		else
			TweenService:Create(ui.clip, HEALTH_TWEEN_INFO, { Size = target }):Play()
		end
	end
	if ui.text then
		ui.text.Text = math.ceil(math.max(enemy.health, 0)) .. "/" .. enemy.maxHealth
	end
end

-- Stats ------------------------------------------------------------------------

local function placedCounts(state): { [string]: number }
	local counts = {}
	for _, tower in state.towers do
		counts[tower.name] = (counts[tower.name] or 0) + 1
	end
	return counts
end

local function stats(state): { [string]: any }
	local nextIn = 0
	if state.nextAt then
		nextIn = math.max(0, math.ceil(state.nextAt - os.clock()))
	end
	return {
		state = "Running",
		phase = state.phase,
		difficulty = state.preset and state.preset.Name or nil,
		wave = state.wave,
		maxWaves = state.maxWaves,
		cash = math.floor(state.cash),
		baseHealth = math.max(0, math.ceil(state.baseHealth)),
		maxHealth = state.maxHealth,
		alive = #state.enemies,
		killed = state.killed,
		leaked = state.leaked,
		towers = #state.towers,
		maxTowers = MAX_TOWERS,
		routes = #state.routes,
		spawning = state.runners > 0,
		nextIn = nextIn,
		loadout = state.loadout,
		placed = placedCounts(state),
	}
end

local function setBaseLabel(state)
	if state.label then
		state.label.Text = tostring(math.max(0, math.ceil(state.baseHealth)))
	end
end

local function push(state)
	for _, tower in state.towers do
		tower.model:SetAttribute("DamageDone", math.floor(tower.damageDealt))
	end
	state.session.push("Playtest", stats(state))
end

-- Enemies -------------------------------------------------------------------------

local function spawnEnemy(state, entry, routeIndex: number, waveNumber: number)
	local template = findEntityTemplate(entry.Entity)
	local smooth = state.routes[routeIndex].smooth
	local start = PathUtil.GetPositionAtDistance(smooth, 0) or Vector3.zero

	local model: Model
	local lift = 1.2
	if template then
		model = template:Clone()
		lift = templateInfo(template).lift
	else
		model = Instance.new("Model")
		local part = Instance.new("Part")
		part.Name = "HumanoidRootPart"
		part.Size = Vector3.new(1.6, 2.4, 1.6)
		part.Color = Color3.fromHex("C4281C")
		part.Parent = model
		lift = 1.2
	end
	model.Name = entry.Entity
	local root = rig(model) :: BasePart
	root.CFrame = CFrame.new(start + Vector3.new(0, lift, 0))
	model.Parent = state.enemiesFolder

	local reference = Mob.Entities[entry.Entity]
	local referenceSpeed = Mob.BaseSpeed * ((reference and reference.SpeedMultiplier) or 1)
	local speed = entry.Speed or referenceSpeed

	local track = nil
	if template then
		local walk = findAnimation(model, { "Walk" }) or EntityAssets:FindFirstChild("Walk")
		track = playLoop(animatorFor(model), walk :: Animation?, math.clamp(speed / math.max(referenceSpeed, 0.1), 0.5, 2.5))
	end

	local health = entry.Health or (reference and reference.Health) or 1
	local enemy = {
		model = model,
		root = root,
		name = entry.Entity,
		route = routeIndex,
		distance = 0,
		health = health,
		maxHealth = health,
		refHealth = (reference and reference.Health) or health,
		speed = speed,
		reward = entry.Reward or 1,
		lift = lift,
		wave = waveNumber,
		boss = Mob.IsBoss(entry.Entity),
		track = track,
		healthUi = healthBar(root, entry.Entity),
	}
	setHealthBar(enemy, true)
	table.insert(state.enemies, enemy)
	state.waveAlive[waveNumber] = (state.waveAlive[waveNumber] or 0) + 1
	return enemy
end

local function removeEnemy(state, enemy)
	local index = table.find(state.enemies, enemy)
	if index then
		table.remove(state.enemies, index)
	end
	state.waveAlive[enemy.wave] = math.max(0, (state.waveAlive[enemy.wave] or 1) - 1)
	if enemy.model then
		enemy.model:Destroy()
	end
end

local function damageEnemy(state, enemy, amount: number, tower)
	if enemy.health <= 0 or amount <= 0 then
		return
	end
	local landed = math.min(amount, enemy.health)
	enemy.health -= landed
	local healthRatio = math.max(1, enemy.maxHealth / math.max(enemy.refHealth, 1e-3))
	state.cash += landed * CASH_PER_DAMAGE / healthRatio
	if tower then
		tower.damageDealt += landed
	end
	setHealthBar(enemy)
	if enemy.health <= 0 then
		state.cash += enemy.reward
		state.killed += 1
		removeEnemy(state, enemy)
	end
end

-- Towers --------------------------------------------------------------------------

local function flash(from: Vector3, to: Vector3, parent: Instance, color: Color3)
	local beam = Instance.new("Part")
	beam.Name = "Shot"
	inert(beam)
	beam.Material = Enum.Material.Neon
	beam.Color = color
	local length = (to - from).Magnitude
	beam.Size = Vector3.new(0.15, 0.15, math.max(length, 0.05))
	beam.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2)
	beam.Parent = parent
	task.delay(0.08, function()
		beam:Destroy()
	end)
end

local CLASS_COLORS = {
	Ranged = Color3.fromHex("F5CD30"),
	Melee = Color3.fromHex("FFFFFF"),
	Magic = Color3.fromHex("B48CFF"),
	Fire = Color3.fromHex("FF7A2F"),
	Ice = Color3.fromHex("8FE3FF"),
	Electric = Color3.fromHex("FFF36B"),
}

local function flatDistance(a: Vector3, b: Vector3): number
	return ((a - b) * Vector3.new(1, 0, 1)).Magnitude
end

local function towerRange(tower): number
	return tower.range or 0
end

local function refreshTowerStats(tower)
	local name, level = tower.name, tower.level
	tower.damage = UnitUpgradeConfig:GetDamage(name, level)
	tower.cooldown = UnitUpgradeConfig:GetCooldown(name, level)
	tower.range = UnitUpgradeConfig:GetRange(name, level)
	tower.income = UnitUpgradeConfig:GetIncome(name, level)
	tower.slow = if tower.stats.SlowAura then UnitUpgradeConfig:GetAuraSlow(name, level) else 0
	tower.model:SetAttribute("Upgrades", level)
	tower.model:SetAttribute("TargetPriority", tower.priority)
	tower.model:SetAttribute("Range", tower.range)
end

local function pickTarget(state, tower)
	local best, bestCandidate = nil, nil
	local range = towerRange(tower)
	for _, enemy in state.enemies do
		if enemy.health > 0 then
			local distance = flatDistance(enemy.root.Position, tower.position)
			if distance <= range then
				local candidate = { distance = distance, health = enemy.health, progress = enemy.distance }
				if TargetPriority.IsBetter(tower.priority, candidate, bestCandidate) then
					best, bestCandidate = enemy, candidate
				end
			end
		end
	end
	return best
end

local function face(tower, point: Vector3)
	local position = tower.root.Position
	local flat = Vector3.new(point.X, position.Y, point.Z)
	if (flat - position).Magnitude > 1e-3 then
		tower.root.CFrame = CFrame.lookAt(position, flat)
	end
end

local function hitTargets(state, tower, target)
	local s = tower.stats
	local list = { target }
	if s.AOE and s.AOE.Radius then
		list = {}
		for _, enemy in state.enemies do
			if enemy.health > 0 and flatDistance(enemy.root.Position, target.root.Position) <= s.AOE.Radius then
				table.insert(list, enemy)
			end
		end
	elseif s.Chain and s.Chain.Targets then
		list = { target }
		local last = target
		for _ = 2, s.Chain.Targets do
			local nextEnemy, nextDistance = nil, math.huge
			for _, enemy in state.enemies do
				if enemy.health > 0 and not table.find(list, enemy) then
					local d = flatDistance(enemy.root.Position, last.root.Position)
					if d <= (s.Chain.Radius or 0) and d < nextDistance then
						nextEnemy, nextDistance = enemy, d
					end
				end
			end
			if not nextEnemy then
				break
			end
			table.insert(list, nextEnemy)
			last = nextEnemy
		end
	end
	return list
end

local function attack(state, tower, target)
	local s = tower.stats
	local hits = math.max(1, s.Hits or 1)
	local interval = s.HitInterval or 0
	local origin = tower.root.Position + Vector3.new(0, 0.6, 0)
	local color = CLASS_COLORS[s.Class or ""] or Color3.fromHex("F5CD30")
	face(tower, target.root.Position)
	if tower.attackTrack then
		tower.attackTrack:Play(0.05)
	end
	for hit = 1, hits do
		local function strike()
			if active ~= state then
				return
			end
			local victim = target
			if victim.health <= 0 then
				victim = pickTarget(state, tower)
				if not victim then
					return
				end
			end
			for _, enemy in hitTargets(state, tower, victim) do
				flash(origin, enemy.root.Position, state.effectsFolder, color)
				damageEnemy(state, enemy, tower.damage, tower)
			end
		end
		if hit == 1 or interval <= 0 then
			strike()
		else
			task.delay(interval * (hit - 1), strike)
		end
	end
end

local function slowAt(state, position: Vector3): number
	local slow = 0
	for _, tower in state.towers do
		if tower.slow > 0 and flatDistance(position, tower.position) <= towerRange(tower) then
			slow = math.max(slow, tower.slow)
		end
	end
	return slow
end

-- Waves ---------------------------------------------------------------------------

local function waveCash(state, waveNumber: number)
	local income = Wave.GetWaveCash(waveNumber)
	for _, tower in state.towers do
		income += math.floor((tower.income or 0) + 0.5)
	end
	state.cash += income
end

local function isFinalWave(state, waveNumber: number): boolean
	return state.maxWaves > 0 and waveNumber >= state.maxWaves
end

local function runWave(state, waveNumber: number)
	local spawns = Wave.GetSpawns(waveNumber, state.preset.Name)
	state.runners += 1
	state.waveRunning[waveNumber] = true
	task.spawn(function()
		local routeCursor = 0
		for _, entry in spawns do
			for i = 1, entry.Amount or 1 do
				if active ~= state or state.phase == "Lost" then
					state.runners -= 1
					state.waveRunning[waveNumber] = nil
					return
				end
				routeCursor += 1
				local routeIndex = ((routeCursor - 1) % #state.routes) + 1
				spawnEnemy(state, entry, routeIndex, waveNumber)
				local last = i == (entry.Amount or 1)
				local delay = if last and entry.GroupDelay then entry.GroupDelay else entry.SpawnDelay
				task.wait(delay or 0.35)
			end
		end
		state.runners -= 1
		state.waveRunning[waveNumber] = nil
	end)
end

local function startNextWave(state): (boolean, string?)
	if state.phase == "Setup" then
		return false, "Pick a difficulty and towers first."
	end
	if state.phase == "Lost" then
		return false, "The base fell. Stop the test to try again."
	end
	if state.phase == "Won" then
		return false, "Every wave is cleared."
	end
	local nextWave = state.wave + 1
	if state.maxWaves > 0 and nextWave > state.maxWaves then
		return false, "No more waves in " .. state.preset.Name .. "."
	end
	if #state.routes == 0 then
		return false, "The map has no route."
	end
	state.wave = nextWave
	state.nextAt = nil
	state.phase = "Wave"
	state.pendingWaves[nextWave] = true
	runWave(state, nextWave)
	push(state)
	return true, nil
end

local function settleWaves(state)
	for waveNumber in state.pendingWaves do
		if not state.waveRunning[waveNumber] and (state.waveAlive[waveNumber] or 0) == 0 then
			state.pendingWaves[waveNumber] = nil
			waveCash(state, waveNumber)
			if isFinalWave(state, waveNumber) then
				state.phase = "Won"
				state.nextAt = nil
				state.session.push("Toast", { text = string.format("%s cleared: all %d waves.", state.preset.Name, state.maxWaves), kind = "ok" })
				return
			end
		end
	end
	if state.phase == "Wave" and next(state.pendingWaves) == nil then
		state.phase = "Intermission"
		state.nextAt = os.clock() + (state.preset.WaveInterval or 1.25)
	end
end

-- Loop ----------------------------------------------------------------------------

local function step(state, dt: number)
	if state.phase == "Setup" or state.phase == "Lost" then
		return
	end
	local now = os.clock()

	for i = #state.enemies, 1, -1 do
		local enemy = state.enemies[i]
		if not enemy or enemy.health <= 0 then
			continue
		end
		local smooth = state.routes[enemy.route].smooth
		local slow = slowAt(state, enemy.root.Position)
		enemy.distance += enemy.speed * (1 - slow) * dt
		if enemy.distance >= smooth.length then
			removeEnemy(state, enemy)
			state.leaked += 1
			state.baseHealth = math.max(0, state.baseHealth - (state.preset.MobDamage or 0))
			setBaseLabel(state)
			if state.baseHealth <= 0 and (state.preset.MobDamage or 0) > 0 then
				state.phase = "Lost"
				state.nextAt = nil
				state.session.push("Toast", { text = string.format("Base destroyed on wave %d.", state.wave), kind = "error" })
				return
			end
		else
			local position = PathUtil.GetPositionAtDistance(smooth, enemy.distance) :: Vector3
			local ahead = PathUtil.GetPositionAtDistance(smooth, math.min(smooth.length, enemy.distance + 0.5)) :: Vector3
			local lift = Vector3.new(0, enemy.lift, 0)
			local flat = (ahead - position) * Vector3.new(1, 0, 1)
			if flat.Magnitude > 1e-3 then
				enemy.root.CFrame = CFrame.lookAt(position + lift, position + lift + flat)
			else
				enemy.root.CFrame = CFrame.new(position + lift)
			end
		end
	end

	for _, tower in state.towers do
		if (tower.damage or 0) <= 0 then
			continue
		end
		if now - tower.lastShot < (tower.cooldown or 1) then
			continue
		end
		local target = pickTarget(state, tower)
		if target then
			tower.lastShot = now
			attack(state, tower, target)
		end
	end

	settleWaves(state)

	if state.phase == "Intermission" and state.nextAt and now >= state.nextAt then
		startNextWave(state)
	end
end

-- API -------------------------------------------------------------------------------

function PlaytestService.isActive(session: Session?): boolean
	if not active then
		return false
	end
	return session == nil or active.session == session
end

function PlaytestService.options(): { [string]: any }
	local list = {}
	for _, name in Difficulty.Order do
		local preset = Difficulty.Presets[name]
		if preset then
			table.insert(list, {
				name = name,
				maxWaves = if preset.Endless then 0 else preset.MaxWaves,
				startingCash = preset.StartingCash,
				baseHealth = preset.BaseHealth,
			})
		end
	end
	return {
		difficulties = list,
		default = Difficulty.Default,
		loadoutSize = LOADOUT_SIZE,
		endlessCap = ENDLESS_WAVE_CAP,
	}
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

	local root = Instance.new("Folder")
	root.Name = "MapEditorPlaytest"
	local enemiesFolder = Instance.new("Folder")
	enemiesFolder.Name = "Enemies"
	enemiesFolder.Parent = root
	local towersFolder = Instance.new("Folder")
	towersFolder.Name = "Towers"
	towersFolder.Parent = root
	local effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "Effects"
	effectsFolder.Parent = root
	root.Parent = workspace

	local label: TextLabel? = nil
	if mapClone then
		local baseHP = mapClone:FindFirstChild(PERI.BaseHealthPart)
		local found = baseHP and baseHP:FindFirstChild(PERI.BaseHealthLabel, true)
		if found and found:IsA("TextLabel") then
			label = found
		end
	end

	local state = {
		session = session,
		export = export,
		mapClone = mapClone,
		spawnClone = spawnClone,
		rootFolder = root,
		enemiesFolder = enemiesFolder,
		towersFolder = towersFolder,
		effectsFolder = effectsFolder,
		routes = routes,
		enemies = {},
		towers = {},
		nextTowerId = 0,
		phase = "Setup",
		preset = nil,
		wave = 0,
		maxWaves = 0,
		cash = 0,
		baseHealth = 0,
		maxHealth = 0,
		killed = 0,
		leaked = 0,
		runners = 0,
		waveRunning = {},
		waveAlive = {},
		pendingWaves = {},
		nextAt = nil,
		loadout = {},
		label = label,
		grid = gridParts(mapClone),
	}
	active = state
	setBaseLabel(state)

	local lastPush = 0
	state.connection = RunService.Heartbeat:Connect(function(dt)
		step(state, dt)
		local now = os.clock()
		if now - lastPush > PUSH_INTERVAL then
			lastPush = now
			push(state)
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

function PlaytestService.configure(session: Session, raw: any): (boolean, string?)
	local state = active
	if not state or state.session ~= session then
		return false, "No playtest running."
	end
	if state.phase ~= "Setup" then
		return false, "This test is already set up."
	end
	if typeof(raw) ~= "table" then
		return false, "Malformed request."
	end

	local name = raw.difficulty
	if typeof(name) ~= "string" or not table.find(Difficulty.Order, name) or not Difficulty.Exists(name) then
		return false, "Pick a difficulty."
	end
	local preset = Difficulty.Get(name)
	local maxWaves = if preset.Endless then 0 else preset.MaxWaves
	local cap = if maxWaves > 0 then maxWaves else ENDLESS_WAVE_CAP

	local startWave = tonumber(raw.startWave)
	if not startWave or startWave ~= startWave then
		return false, "Enter a start wave."
	end
	startWave = math.clamp(math.floor(startWave), 1, cap)

	if typeof(raw.towers) ~= "table" then
		return false, "Pick at least one tower."
	end
	local loadout = {}
	for _, unit in raw.towers do
		if typeof(unit) == "string" and UnitStats[unit] and UnitAssets:FindFirstChild(unit) and not table.find(loadout, unit) then
			table.insert(loadout, unit)
		end
		if #loadout >= LOADOUT_SIZE then
			break
		end
	end
	if #loadout == 0 then
		return false, "Pick at least one tower."
	end

	local cash = preset.StartingCash or Data.STARTING_CASH or 500
	for w = 1, startWave - 1 do
		cash += Wave.GetWaveCash(w)
	end

	state.preset = preset
	state.maxWaves = maxWaves
	state.wave = startWave - 1
	state.cash = cash
	state.baseHealth = preset.BaseHealth or 100
	state.maxHealth = state.baseHealth
	state.loadout = loadout
	state.phase = "Ready"
	setBaseLabel(state)
	push(state)
	return true, nil
end

function PlaytestService.spawnWave(session: Session): (boolean, string?)
	local state = active
	if not state or state.session ~= session then
		return false, "No playtest running."
	end
	return startNextWave(state)
end

function PlaytestService.checkTower(position: Vector3, grid: { BasePart }, towers: { any }, mapRoot: Instance?): (boolean, string?)
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
		if flatDistance(tower.position, position) < PT.TowerMinSpacing then
			return false, "Too close to another tower."
		end
	end

	if PlacementUtil.FindBlockingCharacter(cf, PT.TowerSize) then
		return false, "A player is standing there."
	end

	return true, nil
end

local function facePath(state, position: Vector3): CFrame
	local best, bestDistance = nil, math.huge
	for _, route in state.routes do
		for _, point in route.smooth.points do
			local d = flatDistance(point, position)
			if d < bestDistance then
				best, bestDistance = point, d
			end
		end
	end
	if best and bestDistance > 1e-3 then
		return CFrame.lookAt(position, Vector3.new(best.X, position.Y, best.Z))
	end
	return CFrame.new(position)
end

function PlaytestService.placeTower(session: Session, raw: any, unitName: any): (boolean, string?)
	local state = active
	if not state or state.session ~= session then
		return false, "No playtest running."
	end
	if state.phase == "Setup" then
		return false, "Finish the playtest setup first."
	end
	if state.phase == "Lost" then
		return false, "The base fell."
	end
	if typeof(unitName) ~= "string" or not table.find(state.loadout, unitName) then
		return false, "Pick a tower card first."
	end
	local unitStats = UnitStats[unitName]
	local template = UnitAssets:FindFirstChild(unitName)
	if not unitStats or not template or not template:IsA("Model") then
		return false, "Unknown tower."
	end
	if #state.towers >= MAX_TOWERS then
		return false, "Tower limit reached for this test."
	end
	local cost = UnitUpgradeConfig:GetPlaceCost(unitName)
	if state.cash < cost then
		return false, string.format("Not enough cash: %s costs $%d.", unitName, cost)
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

	state.cash -= cost
	state.nextTowerId += 1
	local id = state.nextTowerId

	local model = template:Clone()
	model.Name = unitName
	model:SetAttribute(TOWER_TAG, id)
	local root = rig(model) :: BasePart
	local lift = templateInfo(template).lift
	local position = hit.Position + Vector3.new(0, lift, 0)
	root.CFrame = facePath(state, position)

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanQuery = true
		end
	end
	model:SetAttribute("GroundY", hit.Position.Y)

	model.Parent = state.towersFolder

	local animator = animatorFor(model)
	playLoop(animator, findAnimation(model, { "Idle" }))
	local attackAnimation = firstAttackAnimation(model)
	local attackTrack = nil
	if attackAnimation then
		local loaded, track = pcall(animator.LoadAnimation, animator, attackAnimation)
		if loaded and track then
			track.Looped = false
			track.Priority = Enum.AnimationPriority.Action
			attackTrack = track
		end
	end

	local tower = {
		id = id,
		name = unitName,
		model = model,
		root = root,
		position = hit.Position,
		stats = unitStats,
		level = 0,
		priority = TargetPriority.Default,
		lastShot = 0,
		damageDealt = 0,
		attackTrack = attackTrack,
	}
	refreshTowerStats(tower)
	table.insert(state.towers, tower)
	push(state)
	return true, nil
end

local function findTower(session: Session, id: any)
	local state = active
	if not state or state.session ~= session then
		return nil, nil, "No playtest running."
	end
	if typeof(id) ~= "number" then
		return state, nil, "Pick a tower."
	end
	for index, tower in state.towers do
		if tower.id == id then
			return state, tower, index
		end
	end
	return state, nil, "That tower is gone."
end

function PlaytestService.upgradeTower(session: Session, id: any): (boolean, string?)
	local state, tower, err = findTower(session, id)
	if not tower then
		return false, err
	end
	if state.phase == "Lost" then
		return false, "The base fell."
	end
	if UnitUpgradeConfig:IsMaxed(tower.level) then
		return false, tower.name .. " is already max level."
	end
	local cost = UnitUpgradeConfig:GetCost(tower.name, tower.level)
	if state.cash < cost then
		return false, string.format("Not enough cash: the upgrade costs $%d.", cost)
	end
	state.cash -= cost
	tower.level += 1
	refreshTowerStats(tower)
	push(state)
	return true, nil
end

function PlaytestService.cyclePriority(session: Session, id: any): (boolean, string?)
	local state, tower, err = findTower(session, id)
	if not tower then
		return false, err
	end
	tower.priority = TargetPriority.Next(tower.priority)
	tower.model:SetAttribute("TargetPriority", tower.priority)
	push(state)
	return true, nil
end

function PlaytestService.sellTower(session: Session, id: any): (boolean, string?)
	local state, tower, index = findTower(session, id)
	if not tower then
		return false, index
	end
	local refund = math.floor(UnitUpgradeConfig:GetInvested(tower.name, tower.level) * SELL_RATIO)
	table.remove(state.towers, index)
	tower.model:Destroy()
	state.cash += refund
	push(state)
	return true, string.format("Sold %s for $%d.", tower.name, refund)
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
	state.rootFolder:Destroy()
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
	session.push("Playtest", {
		state = "Stopped",
		killed = state.killed,
		leaked = state.leaked,
		baseHealth = math.max(0, math.ceil(state.baseHealth)),
		wave = state.wave,
	})
	return true
end

return PlaytestService