--[[
	The match's tower combat, for the playtest.

	A port of Game/src/Services/UnitService.luau (targeting, attack delay, windup and
	`HitTimes`, hit shapes, falloffs, Tripminer, Bonfire, the Archmage combo, slow and
	farm auras), the enemy half of Game/src/Services/MobService.luau (DamageMob with
	resistances and its cash, slow, stun, burn, bleed, frost, static, knockback,
	teleport and the enemy gimmicks), BardService:Step and NecromancerService, so a
	tower in a playtest deals the same damage, at the same instants, to the same
	enemies as in a match. A rule changed there must be changed here too.

	Left out because a playtest has none of them: weather, round cards, the thunder
	charge, game speed and the per-frame target scan budget.

	Units are measured the way the match measures them: from the placed CFrame
	(ground plus half the model height, see `UnitPlacementController`) to the
	enemy's point on the path, in 3D; auras and the Bard ring are flat.

	The playtest owns every Instance. This module keeps the numbers and calls back
	through `state.hooks` for anything that shows on screen.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PathUtil = require(ReplicatedStorage:WaitForChild("MapEditor").PathUtil)

local PeriShared = ReplicatedStorage:WaitForChild("Shared")
local SharedConfig = require(PeriShared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local GameClock = require(PeriShared:WaitForChild("Util"):WaitForChild("GameClock"))
local Mob = SharedConfig.Mob
local UnitStats = SharedConfig.UnitStats
local UnitUpgradeConfig = SharedConfig.UnitUpgradeConfig
local TargetPriority = SharedConfig.TargetPriority

local UnitAttackConfig = SharedConfig.UnitAttackConfig
local ResistanceConfig = SharedConfig.ResistanceConfig
local WeatherConfig = SharedConfig.WeatherConfig

local Data = require(ServerScriptService:WaitForChild("Config"):WaitForChild("Data"))

local CASH_PER_DAMAGE = Data.CASH_PER_DAMAGE or 0.15
local CASH_PER_KILL_MIN = Data.CASH_PER_KILL_MIN or 6
local CASH_PER_KILL_MAX = Data.CASH_PER_KILL_MAX or 12

local PIERCE_WIDTH = 2
local AURA_VFX_COOLDOWN = 0.35
local BONFIRE_IDLE_SCAN_INTERVAL = 0.1
local DEFAULT_CONTACT_RADIUS = 1.5
local DEFAULT_STACK_PER_MODE = 4
local BARD_STATS = { "Damage", "Range", "AttackSpeed" }

local PlaytestCombat = {}

local function hook(state, name: string, ...)
	local fn = state.hooks[name]
	if fn then
		return fn(...)
	end
	return nil
end

-- An enemy the playtest still simulates. A lost or stopped test freezes, like the
-- match's game over clearing `ActiveMobs`.
local function live(state, enemy): boolean
	return enemy ~= nil and enemy.alive and not state.stopped and state.phase ~= "Lost"
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Routes ---------------------------------------------------------------------------

function PlaytestCombat.prepareRoutes(routes)
	for _, route in routes do
		local turns, total = {}, 0
		local positions = route.positions or {}
		for i = 2, #positions do
			total += (positions[i] - positions[i - 1]).Magnitude
			if i < #positions then
				table.insert(turns, total)
			end
		end
		route.turnDistances = turns
	end
end

local function nodeDistancesAlongSmooth(route)
	if route.nodeSmoothDistances then
		return route.nodeSmoothDistances
	end
	local smooth = route.smooth
	local distances = {}
	for _, position in route.positions or {} do
		local best, bestSquared = 1, math.huge
		for index, point in smooth.points do
			local offset = point - position
			local squared = offset:Dot(offset)
			if squared < bestSquared then
				best, bestSquared = index, squared
			end
		end
		table.insert(distances, smooth.cumulative[best] or 0)
	end
	route.nodeSmoothDistances = distances
	return distances
end

-- Positions (MobService:getMobPosition, cached per frame) ---------------------------

local function positionOf(state, enemy): Vector3?
	if not enemy.alive then
		return nil
	end
	if enemy.posFrame ~= state.frame then
		enemy.posFrame = state.frame
		enemy.pos = PathUtil.GetPositionAtDistance(state.routes[enemy.route].smooth, enemy.distance)
	end
	return enemy.pos
end
PlaytestCombat.positionOf = positionOf

local function previousPositionOf(state, enemy): Vector3?
	if not enemy.alive then
		return nil
	end
	return PathUtil.GetPositionAtDistance(state.routes[enemy.route].smooth, enemy.lastDistance or enemy.distance)
end

local function moveTo(enemy, distance: number)
	enemy.distance = distance
	enemy.lastDistance = distance
	enemy.posFrame = nil
end

local function bestInRange(state, position: Vector3, range: number, priority: string?)
	local best, bestCandidate = nil, nil
	for _, enemy in state.enemies do
		local pos = positionOf(state, enemy)
		if not pos then
			continue
		end
		local distance = (pos - position).Magnitude
		if distance > range then
			continue
		end
		local candidate = { distance = distance, health = enemy.health, progress = enemy.distance }
		if TargetPriority.IsBetter(priority, candidate, bestCandidate) then
			best, bestCandidate = enemy, candidate
		end
	end
	return best
end

local function inRadius(state, position: Vector3, radius: number)
	local result = {}
	for _, enemy in state.enemies do
		local pos = positionOf(state, enemy)
		if pos and (pos - position).Magnitude <= radius then
			table.insert(result, enemy)
		end
	end
	return result
end

local function alongLine(state, origin: Vector3, through: Vector3, length: number, width: number)
	local heading = flat(through - origin)
	if heading.Magnitude < 1e-4 then
		return {}
	end
	local direction = heading.Unit
	local found = {}
	for _, enemy in state.enemies do
		local pos = positionOf(state, enemy)
		if not pos then
			continue
		end
		local offset = flat(pos - origin)
		local along = offset:Dot(direction)
		if along < 0 or along > length then
			continue
		end
		if (offset - direction * along).Magnitude <= width then
			table.insert(found, { enemy = enemy, along = along })
		end
	end
	table.sort(found, function(a, b)
		return a.along < b.along
	end)
	local result = {}
	for _, item in found do
		table.insert(result, item.enemy)
	end
	return result
end

local function chainTargets(state, start, maxTargets: number?, radius: number?)
	local chain = { start }
	local limit = math.max(1, math.floor(maxTargets or 1))
	local reach = math.max(0, radius or 0)
	local current = positionOf(state, start)
	if limit <= 1 or reach <= 0 or not current then
		return chain
	end
	local visited = { [start] = true }
	while #chain < limit do
		local nextEnemy, nextPos, nextDistance = nil, nil, nil
		for _, enemy in state.enemies do
			if visited[enemy] then
				continue
			end
			local pos = positionOf(state, enemy)
			if not pos then
				continue
			end
			local distance = (pos - current).Magnitude
			if distance <= reach and (not nextDistance or distance < nextDistance) then
				nextEnemy, nextPos, nextDistance = enemy, pos, distance
			end
		end
		if not nextEnemy then
			break
		end
		visited[nextEnemy] = true
		current = nextPos
		table.insert(chain, nextEnemy)
	end
	return chain
end

local function distanceToSegment(point: Vector3, a: Vector3, b: Vector3): number
	local p, fa = flat(point), flat(a)
	local segment = flat(b - a)
	local lengthSquared = segment:Dot(segment)
	if lengthSquared < 1e-6 then
		return (p - fa).Magnitude
	end
	local t = math.clamp((p - fa):Dot(segment) / lengthSquared, 0, 1)
	return (p - (fa + segment * t)).Magnitude
end

local function crossing(state, position: Vector3, radius: number)
	for _, enemy in state.enemies do
		local current = positionOf(state, enemy)
		if not current then
			continue
		end
		local previous = previousPositionOf(state, enemy) or current
		if distanceToSegment(position, previous, current) <= radius then
			return enemy
		end
	end
	return nil
end

-- Enemy state (MobService) -----------------------------------------------------------

local function refreshSpeed(enemy)
	local slowed = math.min(enemy.slowScale, enemy.auraSlowScale)
	enemy.currentSpeed = enemy.baseSpeed * enemy.speedScale * slowed * enemy.rushScale
end

function PlaytestCombat.initEnemy(state, enemy)
	enemy.alive = true
	enemy.speedScale = 1
	enemy.slowScale = 1
	enemy.auraSlowScale = 1
	enemy.rushScale = 1
	enemy.stunnedUntil = 0
	enemy.lastDistance = enemy.distance
	enemy.gimmicks = Mob.GetGimmicks and Mob.GetGimmicks(enemy.name) or {}
	enemy.gimmickState = {}
	enemy.nextTurnIndex = 1
	enemy.turnDistances = state.routes[enemy.route].turnDistances
	refreshSpeed(enemy)
end

local function stunEnemy(state, enemy, duration: number?)
	if not live(state, enemy) then
		return
	end
	local seconds = math.max(0, duration or 0)
	if seconds <= 0 then
		return
	end
	local untilTime = GameClock.Now() + seconds
	if untilTime > enemy.stunnedUntil then
		enemy.stunnedUntil = untilTime
	end
end

local function applySlow(state, enemy, amount: number?, duration: number?)
	if not live(state, enemy) then
		return
	end
	duration = math.max(0, duration or 0)
	local effective = math.clamp(amount or 0, 0, 0.95)
	if duration <= 0 or effective <= 0 then
		return
	end
	local scale = 1 - effective
	if scale < enemy.slowScale then
		enemy.slowScale = scale
	end
	enemy.slowToken = (enemy.slowToken or 0) + 1
	local token = enemy.slowToken
	refreshSpeed(enemy)
	GameClock.Delay(duration, function()
		if enemy.alive and enemy.slowToken == token then
			enemy.slowScale = 1
			refreshSpeed(enemy)
		end
	end)
end

local function applyFrost(state, enemy, frost, sourceTower)
	if not live(state, enemy) or typeof(frost) ~= "table" then
		return
	end
	local now = GameClock.Now()
	if now < (enemy.frostImmuneUntil or 0) then
		return
	end
	local stacks = enemy.frostStacks
	if not stacks then
		stacks = {}
		enemy.frostStacks = stacks
	end
	local key = sourceTower or "_"
	local stack = stacks[key]
	if not stack then
		stack = { count = 0, token = 0 }
		stacks[key] = stack
	end
	stack.count += 1
	stack.token += 1

	if stack.count >= math.max(1, frost.FreezeStacks or 4) then
		local duration = math.max(0, frost.FreezeDuration or 0)
		table.clear(stacks)
		enemy.frostImmuneUntil = now + duration + math.max(0, frost.FreezeImmunity or 0)
		enemy.slowToken = (enemy.slowToken or 0) + 1
		enemy.slowScale = 1
		refreshSpeed(enemy)
		stunEnemy(state, enemy, duration)
		hook(state, "fx", { kind = "iced", mob = enemy.id, duration = duration })
		return
	end

	applySlow(state, enemy, frost.Slow, frost.Duration)
	local token = stack.token
	GameClock.Delay(math.max(0, frost.Duration or 0), function()
		if enemy.alive and stacks[key] == stack and stack.token == token then
			stacks[key] = nil
		end
	end)
end

local function applyStatic(state, enemy, static, stun: number?)
	if not live(state, enemy) or typeof(static) ~= "table" then
		return
	end
	local duration = math.max(0, static.Duration or 0)
	if duration <= 0 then
		return
	end
	local now = GameClock.Now()
	local charged = now < (enemy.staticUntil or 0)
	enemy.staticUntil = now + duration
	enemy.static = static
	enemy.staticStun = math.max(0, stun or 0)
	if charged then
		hook(state, "fx", { kind = "static", mob = enemy.id, remaining = duration, burst = true })
		return
	end
	enemy.staticToken = (enemy.staticToken or 0) + 1
	local token = enemy.staticToken
	local interval = math.max(0.1, static.Interval or 1)
	local function pulse()
		if not live(state, enemy) or enemy.staticToken ~= token then
			return
		end
		local remaining = (enemy.staticUntil or 0) - GameClock.Now()
		if remaining <= 0 then
			return
		end
		stunEnemy(state, enemy, enemy.staticStun)
		hook(state, "fx", { kind = "static", mob = enemy.id, remaining = remaining, burst = true })
		GameClock.Delay(interval, pulse)
	end
	pulse()
end

local function staticBonus(enemy, unitName: string): (number, number)
	local static = enemy.static
	if not enemy.alive or not static or GameClock.Now() >= (enemy.staticUntil or 0) then
		return 1, 1
	end
	local stats = UnitStats[unitName]
	if not stats or stats.Static or not WeatherConfig.HasClass(unitName, "Electric") then
		return 1, 1
	end
	return static.ElectricDamage or 1, static.ElectricStun or 1
end

local function teleportBack(state, enemy): boolean
	if not live(state, enemy) then
		return false
	end
	local route = state.routes[enemy.route]
	local target = 0
	for _, distance in nodeDistancesAlongSmooth(route) do
		if distance < enemy.distance - 0.5 and distance > target then
			target = distance
		end
	end
	if target >= enemy.distance then
		return false
	end
	moveTo(enemy, target)
	return true
end

local function knockback(state, enemy, distance: number?, cooldown: number?, bossScale: number?): boolean
	if not live(state, enemy) then
		return false
	end
	local push = distance or 0
	if push <= 0 then
		return false
	end
	local now = GameClock.Now()
	if now < (enemy.knockbackUntil or 0) then
		return false
	end
	if bossScale and Mob.IsBoss(enemy.name) then
		push *= bossScale
	end
	local target = math.max(0, enemy.distance - push)
	if target >= enemy.distance then
		return false
	end
	enemy.knockbackUntil = now + (cooldown or 0)
	moveTo(enemy, target)
	return true
end

local function knockbackArea(state, enemy, center: Vector3?, config): number
	local limit = config.MaxTargets or 1
	local targets = {}
	if enemy.alive then
		table.insert(targets, enemy)
	end
	if center and config.Radius then
		local distances, nearby = {}, {}
		for _, other in inRadius(state, center, config.Radius) do
			if other ~= enemy then
				distances[other] = ((positionOf(state, other) :: Vector3) - center).Magnitude
				table.insert(nearby, other)
			end
		end
		table.sort(nearby, function(a, b)
			return distances[a] < distances[b]
		end)
		for _, other in nearby do
			if #targets >= limit then
				break
			end
			table.insert(targets, other)
		end
	end
	local pushed = 0
	for _, target in targets do
		if knockback(state, target, config.Distance, config.Cooldown, config.BossScale) then
			pushed += 1
		end
	end
	return pushed
end

-- Cash (MobService:applyCashBonus / awardDamageReward / awardKillReward) ------------

local function cashWithBonus(state, amount: number, bonus: number?, scale: number?): number
	local factor = scale or 1
	if amount <= 0 or (factor == 1 and (not bonus or bonus <= 0)) then
		return amount
	end
	local scaled = amount * factor
	local carried = (state.bonusRemainder or 0) + scaled + scaled * (bonus or 0)
	local whole = math.floor(carried)
	state.bonusRemainder = carried - whole
	return whole
end

local stunRandomTower

local Gimmicks = {
	PerTurnSpeedMultiplier = {
		OnTurn = function(state, enemy, gimmick)
			local stacks = enemy.gimmickState[gimmick] or 0
			if not gimmick.MaxStacks or stacks < gimmick.MaxStacks then
				stacks += 1
				enemy.gimmickState[gimmick] = stacks
			end
			enemy.speedScale = math.max(0.1, 1 + stacks * (gimmick.Amount or 0))
			refreshSpeed(enemy)
		end,
	},

	HealthThresholdRush = {
		OnDamage = function(state, enemy, gimmick)
			if gimmick.Once and enemy.gimmickState[gimmick] then
				return
			end
			if enemy.health > enemy.maxHealth * (gimmick.Threshold or 0.5) then
				return
			end
			enemy.gimmickState[gimmick] = true
			hook(state, "enemyAnimation", enemy, gimmick.Animation or "Rush")
			enemy.rushToken = (enemy.rushToken or 0) + 1
			local token = enemy.rushToken
			GameClock.Delay(math.max(0, gimmick.MarkerTime or 0), function()
				if not enemy.alive or enemy.rushToken ~= token then
					return
				end
				enemy.rushScale = 1 + (gimmick.Amount or 0)
				refreshSpeed(enemy)
				GameClock.Delay(math.max(0, gimmick.Duration or 0), function()
					if enemy.alive and enemy.rushToken == token then
						enemy.rushScale = 1
						refreshSpeed(enemy)
					end
				end)
			end)
		end,
	},

	HealthThresholdStunRandomUnit = {
		OnDamage = function(state, enemy, gimmick)
			if gimmick.Once and enemy.gimmickState[gimmick] then
				return
			end
			if enemy.health > enemy.maxHealth * (gimmick.Threshold or 0.5) then
				return
			end
			enemy.gimmickState[gimmick] = true
			local freezeTime = gimmick.AnimTime or 0
			enemy.stunnedUntil = math.max(enemy.stunnedUntil, GameClock.Now() + freezeTime)
			hook(state, "enemyAnimation", enemy, "Attack")
			GameClock.Delay(freezeTime, function()
				if live(state, enemy) then
					stunRandomTower(state, gimmick.StunDuration or 0)
				end
			end)
		end,
	},
}

--[=[
	MobService:DamageMob. Bleed vulnerability and the resistance table scale the hit,
	rounded only when they changed it; the enemy loses the full hit but the return,
	the cash and the damage scoreboard count only what it had left.
]=]
local function damageEnemy(state, enemy, damage: number, classes, cashBonus: number?, cashScale: number?): number
	if not live(state, enemy) then
		return 0
	end
	local vulnerability = 1
	if GameClock.Now() < (enemy.bleedingUntil or 0) then
		vulnerability = enemy.bleedVulnerability or 1
	end
	local element = ResistanceConfig.GetMultiplier(enemy.name, classes)
	if element <= 0 then
		return 0
	end
	local base = damage or 10
	local incoming = base * vulnerability * element
	if incoming ~= base then
		incoming = math.max(1, math.floor(incoming + 0.5))
	end
	local effective = math.min(enemy.health, incoming)
	enemy.health -= incoming

	local scale = enemy.healthScale
	if not scale or scale <= 0 then
		scale = 1
	end
	local reward = math.max(1, math.floor(effective * CASH_PER_DAMAGE / scale))
	state.cash += cashWithBonus(state, reward, cashBonus, cashScale)

	for _, gimmick in enemy.gimmicks do
		local handler = Gimmicks[gimmick.Type]
		if handler and handler.OnDamage then
			handler.OnDamage(state, enemy, gimmick)
		end
	end

	hook(state, "healthChanged", enemy)
	if enemy.health <= 0 then
		local kill = enemy.reward or math.random(CASH_PER_KILL_MIN, CASH_PER_KILL_MAX)
		state.cash += cashWithBonus(state, kill, cashBonus, cashScale)
		state.killed += 1
		enemy.alive = false
		hook(state, "removed", enemy)
	end
	return effective
end

local function damageOverTime(state, enemy, damage: number?, ticks: number?, interval: number?, kind)
	if not live(state, enemy) then
		return
	end
	local tickDamage = damage or 0
	local tickCount = math.floor(ticks or 0)
	local every = interval or 1
	if tickDamage <= 0 or tickCount <= 0 or every <= 0 then
		return
	end
	local now = GameClock.Now()
	if now < (enemy[kind.untilKey] or 0) then
		return
	end
	enemy[kind.untilKey] = now + tickCount * every
	if kind.vulnerability then
		enemy.bleedVulnerability = math.max(1, kind.vulnerability)
	end
	hook(state, "fx", { kind = kind.fx, mob = enemy.id, duration = tickCount * every })
	task.spawn(function()
		for _ = 1, tickCount do
			GameClock.Wait(every)
			if not live(state, enemy) then
				return
			end
			damageEnemy(state, enemy, math.max(1, math.floor(tickDamage + 0.5)), kind.class)
		end
	end)
end

function PlaytestCombat.advanceEnemy(state, enemy, dt: number, now: number)
	enemy.lastDistance = enemy.distance
	if now >= enemy.stunnedUntil then
		enemy.distance += enemy.currentSpeed * dt
		local turns = enemy.turnDistances
		while turns and enemy.nextTurnIndex <= #turns and enemy.distance >= turns[enemy.nextTurnIndex] do
			for _, gimmick in enemy.gimmicks do
				local handler = Gimmicks[gimmick.Type]
				if handler and handler.OnTurn then
					handler.OnTurn(state, enemy, gimmick)
				end
			end
			enemy.nextTurnIndex += 1
		end
	end
end

-- Towers (UnitService) ----------------------------------------------------------------

function PlaytestCombat.initTower(tower)
	tower.placed = true
	tower.lastAttack = 0
	tower.stunnedUntil = 0
	tower.attackStep = 0
	tower.damageDealt = 0
end

function PlaytestCombat.removeTower(state, tower)
	tower.placed = false
	for mine in tower.mines or {} do
		hook(state, "mineRemoved", mine, false)
	end
	tower.mines = nil
	tower.bonfire = nil
	hook(state, "bonfire", tower)
end

local function multiplier(tower, stat: string): number
	local bard = tower.bardMult
	return (bard and bard[stat]) or 1
end

function PlaytestCombat.getRange(tower): number
	return UnitUpgradeConfig:GetRange(tower.name, tower.level) * multiplier(tower, "Range")
end
local getRange = PlaytestCombat.getRange

local function getCooldown(tower): number
	local cooldown = UnitUpgradeConfig:GetCooldown(tower.name, tower.level)
	local speed = multiplier(tower, "AttackSpeed")
	if speed > 0 then
		cooldown /= speed
	end
	return cooldown
end

local function getRawDamage(tower, stats): number
	return (stats.Damage or 0) * UnitUpgradeConfig:GetDamageMultiplier(tower.name, tower.level) * multiplier(tower, "Damage")
end

local function getDamage(tower, stats): number
	return math.floor(getRawDamage(tower, stats) + 0.5)
end

local function attackConfigOf(name: string)
	return UnitAttackConfig[name]
end

function stunRandomTower(state, duration: number)
	local towers = state.towers
	if #towers == 0 or duration <= 0 then
		return
	end
	local tower = towers[math.random(1, #towers)]
	local untilTime = GameClock.Now() + duration
	if tower.stunnedUntil >= untilTime then
		return
	end
	tower.stunnedUntil = untilTime
	hook(state, "towerStunned", tower, duration)
end

local function addDamageDone(tower, amount: number)
	if tower and amount > 0 then
		tower.damageDealt += amount
	end
end

local function auraBonus(state, tower): number
	local bonus = 0
	for _, source in state.auraSources do
		if source ~= tower and (source.origin - tower.origin).Magnitude <= getRange(source) then
			bonus += UnitUpgradeConfig:GetAuraBonus(source.name, source.level)
		end
	end
	return bonus
end

-- NecromancerService ------------------------------------------------------------------

local function atLevel(value, level: number)
	if type(value) == "table" then
		if #value == 0 then
			return nil
		end
		return value[math.clamp(level + 1, 1, #value)]
	end
	return value
end

local function segmentDistance(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3): number
	local p1, q1 = Vector2.new(a0.X, a0.Z), Vector2.new(a1.X, a1.Z)
	local p2, q2 = Vector2.new(b0.X, b0.Z), Vector2.new(b1.X, b1.Z)
	local d1, d2, r = q1 - p1, q2 - p2, p1 - p2
	local a, e, f = d1:Dot(d1), d2:Dot(d2), d2:Dot(r)
	if a <= 1e-6 and e <= 1e-6 then
		return r.Magnitude
	end
	local s, t
	if a <= 1e-6 then
		s = 0
		t = math.clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)
		if e <= 1e-6 then
			t = 0
			s = math.clamp(-c / a, 0, 1)
		else
			local b = d1:Dot(d2)
			local denom = a * e - b * b
			s = if denom > 1e-6 then math.clamp((b * f - c * e) / denom, 0, 1) else 0
			t = (b * s + f) / e
			if t < 0 then
				t = 0
				s = math.clamp(-c / a, 0, 1)
			elseif t > 1 then
				t = 1
				s = math.clamp((b - c) / a, 0, 1)
			end
		end
	end
	return ((p1 + d1 * s) - (p2 + d2 * t)).Magnitude
end

local function tryConvert(state, tower, victim)
	local config = UnitStats[tower.name].Necromancy
	if not config or not victim.name then
		return
	end
	if config.ExcludeBosses and Mob.IsBoss(victim.name) then
		return
	end
	if config.Exclude and table.find(config.Exclude, victim.name) then
		return
	end
	local route = state.routes[victim.route] or state.routes[1]
	if not route or route.smooth.length <= 0 then
		return
	end

	local health = config.Health or {}
	local minimum = math.max(1, health.Min or 1)
	local maximum = math.max(minimum, health.Max or math.huge)
	local raw = (victim.maxHealth or 1) * (atLevel(health.Scale, tower.level) or 0) + (atLevel(health.Flat, tower.level) or 0)
	local maxHealth = math.clamp(math.floor(raw + 0.5), minimum, maximum)

	local minion = {
		name = victim.name,
		tower = tower,
		route = route,
		distance = route.smooth.length,
		speed = (victim.baseSpeed or Mob.BaseSpeed) * (victim.speedScale or 1) * (config.SpeedScale or 1),
		health = maxHealth,
		maxHealth = maxHealth,
		contactRadius = config.ContactRadius or DEFAULT_CONTACT_RADIUS,
		classes = WeatherConfig.GetClasses(tower.name),
		ignored = {},
	}
	table.insert(state.minions, minion)
	hook(state, "minionSpawned", minion)
end

local function stepMinions(state, dt: number)
	for index = #state.minions, 1, -1 do
		local minion = state.minions[index]
		local smooth = minion.route.smooth
		local from = PathUtil.GetPositionAtDistance(smooth, minion.distance)
		minion.distance = math.max(0, minion.distance - minion.speed * dt)
		local to = PathUtil.GetPositionAtDistance(smooth, minion.distance)

		if from and to then
			for _, enemy in table.clone(state.enemies) do
				if minion.ignored[enemy] or not enemy.alive then
					continue
				end
				local current = positionOf(state, enemy)
				if not current then
					continue
				end
				local previous = previousPositionOf(state, enemy) or current
				if segmentDistance(from, to, previous, current) <= minion.contactRadius then
					local enemyHealth = enemy.health
					local dealt = damageEnemy(state, enemy, math.max(1, math.ceil(minion.health)), minion.classes, 0)
					if dealt <= 0 then
						minion.ignored[enemy] = true
					else
						if minion.tower.placed then
							addDamageDone(minion.tower, dealt)
						end
						minion.health = math.max(0, minion.health - math.min(minion.health, enemyHealth))
						hook(state, "minionHit", minion)
					end
					if minion.health <= 0 then
						break
					end
				end
			end
		end

		if minion.health <= 0 or minion.distance <= 0 then
			table.remove(state.minions, index)
			hook(state, "minionRemoved", minion)
		else
			hook(state, "minionMoved", minion, to)
		end
	end
end

-- Hits (UnitService:creditDamage / creditHit) -----------------------------------------

local function creditDamage(state, tower, enemy, damage: number, bonus: number): number
	local stats = UnitStats[tower.name]
	local before = positionOf(state, enemy)
	local frostCenter = stats.Frost and stats.Frost.Radius and before
	local knockbackCenter = stats.Knockback and stats.Knockback.Radius and before
	local necromancyVictim = stats.Necromancy and enemy.alive and {
		name = enemy.name,
		maxHealth = enemy.maxHealth,
		route = enemy.route,
		baseSpeed = enemy.baseSpeed,
		speedScale = enemy.speedScale,
	}

	local staticDamage, staticStun = staticBonus(enemy, tower.name)
	if staticDamage ~= 1 then
		damage = math.max(1, math.floor(damage * staticDamage + 0.5))
	end

	local dealt = damageEnemy(state, enemy, damage, WeatherConfig.GetClasses(tower.name), bonus, 1)
	addDamageDone(tower, dealt)

	-- UnitService:playAuraVFX: the money burst, at most once per AURA_VFX_COOLDOWN.
	if dealt > 0 and bonus > 0 and os.clock() - (tower.lastAuraVFX or 0) >= AURA_VFX_COOLDOWN then
		tower.lastAuraVFX = os.clock()
		hook(state, "fx", { kind = "auraBonus", unit = tower.id })
	end

	if necromancyVictim and dealt > 0 and not enemy.alive then
		tryConvert(state, tower, necromancyVictim)
	end

	if dealt <= 0 then
		return dealt
	end

	if stats.Slow then
		applySlow(state, enemy, stats.Slow.Amount, stats.Slow.Duration)
	end
	if stats.Burn then
		damageOverTime(state, enemy, stats.Burn.Damage, stats.Burn.Ticks, stats.Burn.Interval, {
			untilKey = "burningUntil",
			class = "Fire",
			fx = "burning",
		})
	end
	if stats.Bleed then
		damageOverTime(state, enemy, stats.Bleed.Damage, stats.Bleed.Ticks, stats.Bleed.Interval, {
			untilKey = "bleedingUntil",
			class = "Melee",
			fx = "bleeding",
			vulnerability = stats.Bleed.Vulnerability or 1,
		})
	end
	if stats.Knockback then
		local now = GameClock.Now()
		if now >= (tower.knockbackReadyAt or 0) and knockbackArea(state, enemy, knockbackCenter, stats.Knockback) > 0 then
			tower.knockbackReadyAt = now + (stats.Knockback.UnitCooldown or 0)
		end
	end

	local stunDuration = UnitUpgradeConfig:GetStunDuration(tower.name, tower.level) * staticStun
	if stunDuration > 0 then
		stunEnemy(state, enemy, stunDuration)
	end
	if stats.Static then
		applyStatic(state, enemy, stats.Static, UnitUpgradeConfig:GetStaticStun(tower.name, tower.level))
	end
	if stats.Frost then
		applyFrost(state, enemy, stats.Frost, tower)
		local radius = UnitUpgradeConfig:GetFrostRadius(tower.name, tower.level)
		if frostCenter and radius > 0 then
			for _, nearby in inRadius(state, frostCenter, radius) do
				if nearby ~= enemy then
					applyFrost(state, nearby, stats.Frost, tower)
				end
			end
		end
	end
	return dealt
end

-- `hits` keeps where each enemy stood before the damage, for the shot effect.
local function creditHit(state, tower, hits, enemy, damage: number, bonus: number): number
	local position = positionOf(state, enemy)
	local dealt = creditDamage(state, tower, enemy, damage, bonus)
	if dealt > 0 and position then
		table.insert(hits, position)
	end
	return dealt
end

-- Attacks (UnitService:executeAttack / executeCombo / getAttackDelay) -----------------

local function getAttackDelay(tower): number
	local attackConfig = attackConfigOf(tower.name)
	local sequence = attackConfig and attackConfig.ChainSequence and attackConfig.AttackSequence
	local current = tower.attackStep or 0
	if not sequence or #sequence == 0 or current == 0 then
		return getCooldown(tower)
	end
	local step = sequence[current]
	local animation = step and step.Duration or 0
	if current < #sequence then
		return math.max(animation, attackConfig.ChainDelay or 0)
	end
	return animation + getCooldown(tower)
end

local function executeCombo(state, tower, stats, step, target)
	local combo = stats.Combo and stats.Combo[step.Combo]
	if not combo then
		return
	end
	local origin = tower.origin
	local bonus = auraBonus(state, tower)
	local damage = combo.Damage and getDamage(tower, combo) or 0
	local range = getRange(tower)
	local aimPos = target and positionOf(state, target)

	local function targetPosition()
		return target and live(state, target) and positionOf(state, target) or nil
	end

	task.spawn(function()
		GameClock.Wait(step.HitTime or 0)
		if state.stopped then
			return
		end

		if step.Combo == "Meteor" then
			local startPos = targetPosition() or aimPos
			if not startPos then
				return
			end
			local fallTime = combo.FallTime or 1
			hook(state, "meteor", tower, startPos, fallTime, combo.Height or 15, target)
			local impact, remaining = startPos, fallTime
			while remaining > 0 do
				local wait = math.min(0.1, remaining)
				GameClock.Wait(wait)
				remaining -= wait
				impact = targetPosition() or impact
			end
			local radius = UnitUpgradeConfig:GetMeteorRadius(tower.name, tower.level)
			local hits = {}
			for _, enemy in inRadius(state, impact, radius) do
				creditHit(state, tower, hits, enemy, damage, bonus)
			end
		elseif step.Combo == "Lightning" then
			local through = targetPosition() or aimPos
			if not through then
				return
			end
			local window = math.max(0, (step.HitEnd or step.HitTime or 0) - (step.HitTime or 0))
			local interval = math.max(0.05, combo.Interval or 0.1)
			local ticks = math.max(1, math.floor(window / interval + 1e-6))
			local stunDuration = combo.Stun or 0
			local stunLockout = combo.StunLockout or 0
			local stunned = {}
			hook(state, "lightning", tower, through, range, window)
			for tick = 1, ticks do
				local hits = {}
				for _, enemy in alongLine(state, origin, through, range, combo.Width or PIERCE_WIDTH) do
					creditHit(state, tower, hits, enemy, damage, bonus)
					if stunDuration > 0 and not stunned[enemy] and enemy.alive then
						local now = GameClock.Now()
						if now >= (enemy.archmageStunLockUntil or 0) then
							stunned[enemy] = true
							enemy.archmageStunLockUntil = now + stunLockout
							stunEnemy(state, enemy, stunDuration)
						end
					end
				end
				if tick < ticks then
					GameClock.Wait(interval)
				end
			end
		elseif step.Combo == "Teleport" then
			if target then
				teleportBack(state, target)
			end
		end
	end)
end

local function executeAttack(state, tower, stats, target)
	local origin = tower.origin
	local damage = getDamage(tower, stats)
	local bonus = auraBonus(state, tower)
	local aoe = stats.AOE
	local projectile = stats.Projectile
	local pierce = projectile and projectile.Subtype == "Piercing" and projectile or nil
	local chain = stats.Chain
	local range = getRange(tower)
	local totalHits = stats.Hits or 1

	local attackConfig = attackConfigOf(tower.name)
	local sequence = attackConfig and attackConfig.AttackSequence
	local stepIndex, step, windup = 1, nil, 0
	if sequence and #sequence > 0 then
		stepIndex = ((tower.attackStep or 0) % #sequence) + 1
		tower.attackStep = stepIndex
		step = sequence[stepIndex]
		windup = step.HitTime or 0
	end

	local swingWindow = getCooldown(tower)

	if step and step.Combo then
		swingWindow = step.Duration or swingWindow
		hook(state, "swing", tower, stepIndex, swingWindow, target)
		executeCombo(state, tower, stats, step, target)
		return
	end

	local schedule = nil
	if step and step.HitTimes and #step.HitTimes > 0 then
		local duration = step.Duration or 0
		local squeeze = (swingWindow > 0 and duration > swingWindow) and (duration / swingWindow) or 1
		schedule = table.create(#step.HitTimes)
		for index, at in step.HitTimes do
			schedule[index] = at / squeeze
		end
		totalHits = #schedule
		windup = schedule[1]
	end

	local hitFalloff = math.clamp(stats.HitFalloff or 0, 0, 1)

	hook(state, "swing", tower, stepIndex, swingWindow, target)

	task.spawn(function()
		if windup > 0 then
			GameClock.Wait(windup)
		end
		for i = 1, totalHits do
			if state.stopped or state.phase == "Lost" then
				return
			end

			local hitDamage = damage
			if hitFalloff > 0 and i > 1 then
				hitDamage = math.max(1, math.floor(damage * (1 - hitFalloff) ^ (i - 1) + 0.5))
			end

			local resolved = target
			if resolved and not resolved.alive then
				resolved = bestInRange(state, origin, range, tower.priority)
			end
			local predicted = resolved and positionOf(state, resolved)

			local hits = {}
			if chain and resolved then
				-- The bolt the client draws: each link where it stood before the damage.
				local arc = { unitId = tower.id, origin = origin, targets = {} }
				for _, enemy in chainTargets(state, resolved, chain.Targets, chain.Radius) do
					table.insert(arc.targets, { mobId = enemy.id, position = positionOf(state, enemy) })
					creditHit(state, tower, hits, enemy, hitDamage, bonus)
				end
				hook(state, "fx", { kind = "chain", arc = arc })
			elseif aoe then
				for _, enemy in inRadius(state, predicted or origin, aoe.Radius) do
					creditHit(state, tower, hits, enemy, hitDamage, bonus)
				end
				if #hits == 0 and resolved then
					creditHit(state, tower, hits, resolved, hitDamage, bonus)
				end
			elseif pierce and resolved then
				local along = predicted and alongLine(state, origin, predicted, range, pierce.PierceWidth or PIERCE_WIDTH) or {}
				local falloff = math.clamp(pierce.PierceFalloff or 0, 0, 1)
				for index, enemy in along do
					local scaled = hitDamage
					if falloff > 0 and index > 1 then
						scaled = math.max(1, math.floor(hitDamage * (1 - falloff) ^ (index - 1) + 0.5))
					end
					creditHit(state, tower, hits, enemy, scaled, bonus)
				end
				if #hits == 0 then
					creditHit(state, tower, hits, resolved, hitDamage, bonus)
				end
			elseif resolved then
				creditHit(state, tower, hits, resolved, hitDamage, bonus)
			end

			hook(state, "shot", tower, hits, resolved or target)

			if i < totalHits then
				GameClock.Wait(schedule and (schedule[i + 1] - schedule[i]) or stats.HitInterval)
			end
		end
	end)
end

-- Tripminer (UnitService:stepTripminer / stepTripmines) -------------------------------

local function randomPathPointInRange(state, tower): Vector3?
	local origin = tower.origin
	local range = getRange(tower)
	local candidates = {}
	for _, route in state.routes do
		local smooth = route.smooth
		if smooth and smooth.points and #smooth.points >= 2 and smooth.length > 0 then
			local d = 0
			while d <= smooth.length do
				local p = PathUtil.GetPositionAtDistance(smooth, d)
				if p and flat(p - origin).Magnitude <= range then
					table.insert(candidates, { smooth = smooth, distance = d })
				end
				d += 1
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	local pick = candidates[math.random(1, #candidates)]
	local smooth = pick.smooth
	local distance = math.clamp(pick.distance + (math.random() - 0.5), 0, smooth.length)
	local point = PathUtil.GetPositionAtDistance(smooth, distance) :: Vector3
	local ahead = PathUtil.GetPositionAtDistance(smooth, math.min(smooth.length, distance + 0.5)) :: Vector3
	local direction = flat(ahead - point)
	if direction.Magnitude < 0.001 then
		local behind = PathUtil.GetPositionAtDistance(smooth, math.max(0, distance - 0.5)) :: Vector3
		direction = flat(point - behind)
	end
	local offset = Vector3.zero
	if direction.Magnitude > 0.001 then
		offset = direction.Unit:Cross(Vector3.yAxis) * ((math.random() - 0.5) * 3)
	end
	return point + offset + Vector3.new(0, 0.35, 0)
end

local function mineCount(tower): number
	local total = tower.pendingMines or 0
	for _ in tower.mines or {} do
		total += 1
	end
	return total
end

local function stepTripminer(state, tower, stats, now: number)
	local config = stats.Tripmine
	tower.mines = tower.mines or {}
	local cooldown = getCooldown(tower)
	if now - tower.lastAttack < cooldown then
		return
	end
	local limit = math.min((config.BaseLimit or 3) + tower.level * (config.LimitPerUpgrade or 1), config.MaxLimit or math.huge)
	if mineCount(tower) >= limit then
		return
	end
	local position = randomPathPointInRange(state, tower)
	if not position then
		return
	end

	tower.lastAttack = now
	tower.pendingMines = (tower.pendingMines or 0) + 1

	local attackConfig = attackConfigOf(tower.name)
	local sequence = attackConfig and attackConfig.AttackSequence
	local windup = sequence and sequence[1] and sequence[1].HitTime or 0
	local throwTime = config.ThrowTime or 0
	state.nextMineId = (state.nextMineId or 0) + 1
	local mine = {
		id = state.nextMineId,
		position = position,
		cf = CFrame.new(position) * CFrame.Angles(0, math.random() * math.pi * 2, 0),
		tower = tower,
	}

	hook(state, "swing", tower, 1, cooldown, nil)

	GameClock.Delay(windup, function()
		if not tower.placed or state.stopped then
			tower.pendingMines = math.max(0, (tower.pendingMines or 1) - 1)
			return
		end
		hook(state, "mineThrown", mine, throwTime)
		GameClock.Delay(throwTime, function()
			tower.pendingMines = math.max(0, (tower.pendingMines or 1) - 1)
			if not tower.placed or state.stopped then
				hook(state, "mineRemoved", mine, false)
				return
			end
			mine.armedAt = GameClock.Now()
			tower.mines[mine] = true
		end)
	end)
end

local function stepTripmines(state, now: number)
	if #state.enemies == 0 then
		return
	end
	for _, tower in state.towers do
		local stats = UnitStats[tower.name]
		local config = stats and stats.Tripmine
		if not config or not tower.mines then
			continue
		end
		for mine in tower.mines do
			if not crossing(state, mine.position, config.TriggerRadius or 2.5) then
				continue
			end
			tower.mines[mine] = nil
			local factor = 1
			local charge = config.Charge
			if charge and (charge.Time or 0) > 0 then
				local start = math.clamp(charge.StartDamage or 1, 0, 1)
				factor = start + (1 - start) * math.clamp((now - (mine.armedAt or now)) / charge.Time, 0, 1)
			end
			local damage = math.floor(getDamage(tower, stats) * factor + 0.5)
			local radius = config.AOE and config.AOE.Radius or 6
			local bonus = auraBonus(state, tower)
			for _, enemy in inRadius(state, mine.position, radius) do
				creditDamage(state, tower, enemy, damage, bonus)
			end
			hook(state, "mineRemoved", mine, true)
		end
	end
end

-- Bonfire (UnitService:stepBonfire / stepBonfireBeam) --------------------------------

local function bonfireInterval(tower): number
	return math.max(0.05, getCooldown(tower))
end

local function bonfireSpent(tower, bonfire): boolean
	return (bonfire.damageDealt or 0) >= UnitUpgradeConfig:GetDamageCap(tower.name, tower.level)
end

local function stepBonfireBeam(state, tower, stats, bonfire, now: number)
	local progress = UnitUpgradeConfig:GetRampProgress(tower.name, tower.level, now - bonfire.fireStart)
	local interval = bonfireInterval(tower)
	local changed = false

	local stage = UnitUpgradeConfig:GetBeamStage(tower.name, progress)
	if stage ~= bonfire.stage then
		bonfire.stage = stage
		bonfire.nextTick = now
		changed = true
	end
	if math.abs(interval - (bonfire.interval or 0)) > 0.001 then
		bonfire.interval = interval
		changed = true
	end
	if changed then
		hook(state, "bonfire", tower)
	end

	local ticks = 0
	while now >= bonfire.nextTick and ticks < 4 do
		ticks += 1
		bonfire.nextTick += interval
		local raw = getRawDamage(tower, stats) * UnitUpgradeConfig:GetRampMultiplier(tower.name, progress) + (bonfire.carry or 0)
		local damage = math.max(1, math.floor(raw))
		bonfire.carry = math.max(0, raw - damage)
		local dealt = creditDamage(state, tower, bonfire.target, damage, auraBonus(state, tower))
		bonfire.damageDealt = (bonfire.damageDealt or 0) + dealt
		if bonfireSpent(tower, bonfire) then
			break
		end
	end
	if now >= bonfire.nextTick then
		bonfire.nextTick = now + interval
	end
end

local function stepBonfire(state, tower, stats, now: number)
	local attackConfig = attackConfigOf(tower.name)
	local tiredDuration = attackConfig and attackConfig.Tired and attackConfig.Tired.Duration or 0
	local chargeUpTime = stats.Beam and stats.Beam.ChargeUpTime or 0

	local bonfire = tower.bonfire
	if not bonfire then
		bonfire = { state = "Idle", stage = 1, untilTime = 0, nextScan = 0, nextTick = 0, fireStart = 0, damageDealt = 0 }
		tower.bonfire = bonfire
	end

	if bonfire.state == "Tired" then
		if now < bonfire.untilTime then
			return
		end
		if bonfireSpent(tower, bonfire) then
			bonfire.damageDealt = 0
		end
		bonfire.state = "Idle"
		bonfire.target = nil
		hook(state, "bonfire", tower)
	end

	local range = getRange(tower)
	local canFight = now >= tower.stunnedUntil and #state.enemies > 0 and not bonfireSpent(tower, bonfire)

	local target = bonfire.target
	local targetValid = false
	if canFight and target and target.alive then
		local pos = positionOf(state, target)
		targetValid = pos ~= nil and (pos - tower.origin).Magnitude <= range
	end

	if canFight and not targetValid and (bonfire.state ~= "Idle" or now >= bonfire.nextScan) then
		bonfire.nextScan = now + BONFIRE_IDLE_SCAN_INTERVAL
		local best = bestInRange(state, tower.origin, range, tower.priority)
		if best then
			target = best
			targetValid = true
		end
	end

	if bonfire.state == "Fire" then
		if not targetValid then
			bonfire.target = nil
			bonfire.stage = 1
			bonfire.state = "Tired"
			bonfire.untilTime = now + tiredDuration
			hook(state, "bonfire", tower)
			return
		end
		if target ~= bonfire.target then
			bonfire.target = target
			hook(state, "bonfire", tower)
		end
		stepBonfireBeam(state, tower, stats, bonfire, now)
		return
	end

	if bonfire.state == "Charge" then
		if not targetValid then
			bonfire.target = nil
			bonfire.state = "Idle"
			hook(state, "bonfire", tower)
			return
		end
		if target ~= bonfire.target then
			bonfire.target = target
			hook(state, "bonfire", tower)
		end
		if now < bonfire.untilTime then
			return
		end
	elseif bonfire.state == "Idle" then
		if not targetValid then
			return
		end
		bonfire.target = target
		if chargeUpTime > 0 then
			bonfire.state = "Charge"
			bonfire.untilTime = now + chargeUpTime
			hook(state, "bonfire", tower)
			return
		end
	end

	bonfire.state = "Fire"
	bonfire.fireStart = now
	bonfire.nextTick = now
	bonfire.stage = 1
	bonfire.carry = 0
	bonfire.interval = bonfireInterval(tower)
	hook(state, "bonfire", tower)
end

-- Auras (UnitService:stepSlowAuras, BardService:Step) ---------------------------------

local function stepSlowAuras(state, now: number)
	local slows = {}
	local any = false
	for _, tower in state.towers do
		local stats = UnitStats[tower.name]
		if not (stats and stats.SlowAura) or now < tower.stunnedUntil then
			continue
		end
		local amount = UnitUpgradeConfig:GetAuraSlow(tower.name, tower.level)
		if amount <= 0 then
			continue
		end
		any = true
		local center = tower.origin
		local range = getRange(tower)
		local rangeSquared = range * range
		for _, enemy in state.enemies do
			if amount <= (slows[enemy] or 0) then
				continue
			end
			local pos = positionOf(state, enemy)
			if pos then
				local dx, dz = pos.X - center.X, pos.Z - center.Z
				if dx * dx + dz * dz <= rangeSquared then
					slows[enemy] = amount
				end
			end
		end
	end
	if not any and not state.hadAuraSlows then
		return
	end
	state.hadAuraSlows = any
	for _, enemy in state.enemies do
		local scale = 1 - math.clamp(slows[enemy] or 0, 0, 0.95)
		if scale ~= enemy.auraSlowScale then
			local wasSlowed = enemy.auraSlowScale < 1
			enemy.auraSlowScale = scale
			refreshSpeed(enemy)
			if (scale < 1) ~= wasSlowed then
				hook(state, "fx", { kind = "auraSlow", mob = enemy.id, on = scale < 1 })
			end
		end
	end
end

local function canReceiveBuff(name: string): boolean
	local stats = UnitStats[name]
	return stats ~= nil and not (stats.Support or stats.Farm or stats.SlowAura)
end

local function stepBards(state, now: number)
	local active = {}
	for _, tower in state.towers do
		local support = UnitStats[tower.name] and UnitStats[tower.name].Support
		if not support then
			continue
		end
		tower.bardMult = nil
		if now < tower.stunnedUntil then
			continue
		end
		local mode = if tower.bardMode and support.Modes[tower.bardMode] then tower.bardMode else support.Default
		local modeConfig = mode and support.Modes and support.Modes[mode]
		if not modeConfig then
			continue
		end
		local boost = UnitUpgradeConfig:GetSupportBoost(tower.name, tower.level, mode)
		if boost <= 0 then
			continue
		end
		local radius = getRange(tower)
		table.insert(active, {
			stat = modeConfig.Stat,
			boost = boost,
			stackPerMode = math.max(1, support.StackPerMode or DEFAULT_STACK_PER_MODE),
			x = tower.origin.X,
			z = tower.origin.Z,
			radiusSquared = radius * radius,
		})
	end

	for _, tower in state.towers do
		if UnitStats[tower.name] and UnitStats[tower.name].Support then
			continue
		end
		tower.bardMult = nil
		if #active == 0 or not canReceiveBuff(tower.name) then
			continue
		end
		local totals, counts, any = {}, {}, false
		for _, slot in active do
			if (counts[slot.stat] or 0) >= slot.stackPerMode then
				continue
			end
			local dx, dz = tower.origin.X - slot.x, tower.origin.Z - slot.z
			if dx * dx + dz * dz <= slot.radiusSquared then
				any = true
				totals[slot.stat] = (totals[slot.stat] or 0) + slot.boost
				counts[slot.stat] = (counts[slot.stat] or 0) + 1
			end
		end
		if any then
			local mult = {}
			for _, stat in BARD_STATS do
				mult[stat] = 1 + (totals[stat] or 0)
			end
			tower.bardMult = mult
		end
	end
end

-- Frame (UnitService:stepCombat) -------------------------------------------------------

function PlaytestCombat.step(state, dt: number, now: number)
	stepBards(state, now)

	table.clear(state.auraSources)
	for _, tower in state.towers do
		local farm = UnitStats[tower.name] and UnitStats[tower.name].Farm
		if farm and farm.Aura then
			table.insert(state.auraSources, tower)
		end
	end

	stepTripmines(state, now)
	stepSlowAuras(state, now)

	for _, tower in table.clone(state.towers) do
		local stats = UnitStats[tower.name]
		if not stats then
			continue
		end
		if stats.Beam then
			stepBonfire(state, tower, stats, now)
			continue
		end
		if stats.Farm or stats.SlowAura or stats.Support then
			continue
		end
		if stats.Tripmine then
			if now >= tower.stunnedUntil then
				stepTripminer(state, tower, stats, now)
			end
			continue
		end
		if #state.enemies == 0 or now < tower.stunnedUntil or now - tower.lastAttack < getAttackDelay(tower) then
			continue
		end

		local range = getRange(tower)
		local target = tower.target
		local targetValid = false
		if target and target.alive then
			local pos = positionOf(state, target)
			targetValid = pos ~= nil and (pos - tower.origin).Magnitude <= range
		end
		local best = bestInRange(state, tower.origin, range, tower.priority)
		if best then
			target = best
			targetValid = true
		elseif not targetValid then
			target = nil
		end
		tower.target = target

		if targetValid then
			tower.lastAttack = now
			executeAttack(state, tower, stats, target)
		end
	end

	stepMinions(state, dt)
end

function PlaytestCombat.new(state)
	state.frame = 0
	state.auraSources = {}
	state.minions = {}
	state.bonusRemainder = 0
	state.hadAuraSlows = false
end

return PlaytestCombat
