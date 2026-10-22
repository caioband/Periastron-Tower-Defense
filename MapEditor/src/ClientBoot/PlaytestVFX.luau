--[[
	The match's own attack effects in a playtest: projectiles, the per-unit VFX of
	UnitVFXConfig (placement, attack, hit), the Electro's chain, the Archmage's meteor
	and beam, the Tripminer's mines, the Bonfire's beam, and the burn, bleed, freeze,
	charge, ring slow and aura cash on enemies and units.

	It drives the Game's controllers, mounted under `GameVFX` by default.project.json,
	without starting them through the Me framework (whose client loads the empty
	`PlayerScripts.Client.Controllers` the project mounts for it): their `Controllers` get stand-ins that find playtest
	towers and enemies by the `PlaytestTowerId` and `PlaytestEnemyId` attributes
	PlaytestService writes. The server says what happened through the `PlaytestFx`
	push (PlaytestCombat's hooks); a swing's projectile timing is
	Unit:playAttackVisual's. Animations stay on the server, which plays them.

	VFXController needs `ReplicatedStorage.vfx`, mounted from `vendor/vfx`. Without
	it projectiles, mines and the Bonfire beam still play.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SharedConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig"))
local UnitStats = SharedConfig.UnitStats
local UnitAttackConfig = SharedConfig.UnitAttackConfig

local GameVFX = script.Parent:WaitForChild("GameVFX")
local Push = ReplicatedStorage:WaitForChild("MapEditor"):WaitForChild("Remotes"):WaitForChild("Push")

local PlaytestVFX = {}

-- Lookups ---------------------------------------------------------------------------

local function playtestFolder(name: string): Instance?
	local root = workspace:FindFirstChild("MapEditorPlaytest")
	return root and root:FindFirstChild(name)
end

local function byAttribute(folderName: string, attribute: string): { [any]: Model }
	local found = {}
	local folder = playtestFolder(folderName)
	if folder then
		for _, child in folder:GetChildren() do
			local id = child:GetAttribute(attribute)
			if id ~= nil and child:IsA("Model") then
				found[id] = child
			end
		end
	end
	return found
end

local function towerModel(id: any): Model?
	return id ~= nil and byAttribute("Towers", "PlaytestTowerId")[id] or nil
end

local function enemyModel(id: any): Model?
	local model = id ~= nil and byAttribute("Enemies", "PlaytestEnemyId")[id] or nil
	return if model and model.Parent then model else nil
end

-- What the Game's controllers read from UnitPlacementController and MobController.
local placementStandIn = setmetatable({}, {
	__index = function(_, key)
		if key == "createdClasses" then
			local classes = {}
			for id, model in byAttribute("Towers", "PlaytestTowerId") do
				classes[model] = { unitId = id, model = model }
			end
			return classes
		elseif key == "classesById" then
			local classes = {}
			for id, model in byAttribute("Towers", "PlaytestTowerId") do
				classes[id] = { unitId = id, model = model }
			end
			return classes
		end
		return nil
	end,
})

local mobsStandIn = setmetatable({}, {
	__index = function(_, key)
		if key == "SpawnedMobs" then
			return byAttribute("Enemies", "PlaytestEnemyId")
		end
		return nil
	end,
})

-- Controllers -----------------------------------------------------------------------

local Projectiles = require(GameVFX:WaitForChild("ProjectileController"))
Projectiles:buildLibrary()

local Tripmines = require(GameVFX:WaitForChild("TripmineController"))
Tripmines.Controllers = {
	UnitPlacementController = placementStandIn,
	MusicController = { PlaySFX = function() end },
}

local Bonfire = require(GameVFX:WaitForChild("BonfireController"))
Bonfire.Controllers = { MobController = mobsStandIn }

local Effects = nil
if ReplicatedStorage:WaitForChild("vfx", 5) then
	Effects = require(GameVFX:WaitForChild("VFXController"))
	Effects.Controllers = { UnitPlacementController = placementStandIn, MobController = mobsStandIn }
	Effects.FrozenAuraPending = {}
	Effects.StaticUntil = {}
	Effects:buildLibrary()
else
	warn("[MapEditor] ReplicatedStorage.vfx is missing: playtest hit effects are off. Check that Rojo mounts vendor/vfx.")
end

local function trigger(unitName: string, event: string, context)
	if Effects then
		Effects:Trigger(unitName, event, context)
	end
end

-- Swings (Unit:playAttackVisual, minus the animation the server plays) ---------------

local function swing(data)
	local model = towerModel(data.unit)
	local stats = model and UnitStats[model.Name]
	if not model or not stats then
		return
	end
	local name = model.Name
	local attackConfig = UnitAttackConfig[name]
	local sequence = attackConfig and attackConfig.AttackSequence
	local step = sequence and sequence[data.step]
	local target = enemyModel(data.mob)
	local lastTargetPos = target and target:GetPivot().Position

	local function fireHit()
		if not model.Parent then
			return
		end
		local live = if target and target.Parent then target else nil
		if live then
			lastTargetPos = live:GetPivot().Position
		end
		if stats.Projectile then
			if not live and not lastTargetPos then
				return
			end
			local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
			if not root then
				return
			end
			Projectiles:Fire(root.Position, live, stats.Projectile, function(impactPos)
				trigger(name, "OnAttack", { unitModel = model, mobModel = live, position = impactPos })
			end, lastTargetPos)
		elseif live then
			trigger(name, "OnAttack", { unitModel = model, mobModel = live })
		end
	end

	local function scheduleHits()
		fireHit()
		for i = 2, stats.Hits or 1 do
			task.delay((stats.HitInterval or 0) * (i - 1), fireHit)
		end
	end

	local hitTimes = step and step.HitTimes
	if hitTimes then
		-- The same squeeze the server applies (`Duration` against the attack window).
		local window = data.window or 0
		local duration = step.Duration or 0
		local fit = if window > 0 and duration > window then duration / window else 1
		for _, at in hitTimes do
			task.delay(at / fit, fireHit)
		end
	elseif step and (step.HitTime or 0) > 0 then
		task.delay(step.HitTime, scheduleHits)
	else
		scheduleHits()
	end
end

-- Bonfire beam (BonfireController's beam, without its animations) --------------------

local beams = {}

local function bonfire(data)
	local model = towerModel(data.unit)
	local visual = beams[data.unit]
	if data.state ~= "Fire" or not model then
		if visual then
			Bonfire:destroyBeam(visual)
			beams[data.unit] = nil
		end
		return
	end
	if not visual or visual.model ~= model then
		visual = { model = model, class = { setTarget = function() end } }
		beams[data.unit] = visual
	end
	visual.want = { state = data.state, stage = data.stage, mobId = data.mob }
	local stage = UnitAttackConfig.Bonfire.BeamStages
	local def = stage[data.stage] or stage[#stage]
	if visual.beamName ~= def.Beam then
		Bonfire:destroyBeam(visual)
		Bonfire:buildBeam(visual, def.Beam)
	end
end

RunService.RenderStepped:Connect(function()
	for id, visual in beams do
		if not visual.model.Parent then
			Bonfire:destroyBeam(visual)
			beams[id] = nil
		else
			Bonfire:updateBeam(visual, visual.want)
		end
	end
end)

-- Mines (TripmineController) -----------------------------------------------------------

local function removeMine(unitId, mineId)
	Tripmines:endArc(mineId)
	local mine = Tripmines.Mines[mineId]
	Tripmines.Mines[mineId] = nil
	if Tripmines.MinesByUnit[unitId] then
		Tripmines.MinesByUnit[unitId][mineId] = nil
	end
	if mine then
		mine:Destroy()
	end
end

local function clearAll()
	for id, visual in beams do
		Bonfire:destroyBeam(visual)
		beams[id] = nil
	end
	Tripmines:clearAllMines()
end

-- Dispatch -----------------------------------------------------------------------------

local handlers = {
	swing = swing,
	bonfire = bonfire,

	place = function(data)
		local model = towerModel(data.unit)
		if model then
			trigger(model.Name, "OnPlace", { unitModel = model })
		end
	end,

	hit = function(data)
		local model = towerModel(data.unit)
		if model then
			trigger(model.Name, "OnHit", { mobModel = enemyModel(data.mob), position = data.position, unitId = data.unit })
		end
	end,

	chain = function(data)
		if Effects then
			Effects:PlayChainLightning(data.arc)
		end
	end,

	meteor = function(data)
		if Effects then
			Effects:PlayMeteor(data.unit, data.aim, data.fallTime, data.height, data.mob)
		end
	end,

	archLightning = function(data)
		if Effects then
			Effects:PlayArchmageLightning(data.unit, data.through, data.duration)
		end
	end,

	mineThrown = function(data)
		Tripmines:spawnMine(data.unit, data.mine, data.cf, data.throwTime)
	end,

	mineGone = function(data)
		if data.exploded then
			Tripmines:triggerMine(data.unit, data.mine)
		else
			removeMine(data.unit, data.mine)
		end
	end,

	burning = function(data)
		if Effects then
			Effects:PlayBurning(data.mob, data.duration)
		end
	end,

	bleeding = function(data)
		if Effects then
			Effects:PlayBleeding(data.mob, data.duration)
		end
	end,

	iced = function(data)
		if Effects then
			Effects:PlayIced(data.mob, data.duration)
		end
	end,

	static = function(data)
		if Effects then
			Effects:PlayStatic(data.mob, data.remaining, data.burst == true)
		end
	end,

	auraSlow = function(data)
		if Effects then
			Effects:SetFrozenAura(data.mob, data.on == true)
		end
	end,

	auraBonus = function(data)
		if Effects then
			Effects:PlayAuraBonus(data.unit)
		end
	end,
}

Push.OnClientEvent:Connect(function(kind, data)
	if kind == "Playtest" and typeof(data) == "table" and data.state == "Stopped" then
		clearAll()
		return
	end
	if kind ~= "PlaytestFx" or typeof(data) ~= "table" then
		return
	end
	local handler = handlers[data.kind]
	if handler then
		local ok, err = pcall(handler, data)
		if not ok then
			warn("[MapEditor] playtest effect", data.kind, "failed:", err)
		end
	end
end)

return PlaytestVFX
