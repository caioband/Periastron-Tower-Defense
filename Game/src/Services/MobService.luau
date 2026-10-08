local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared.Util.PathUtil)
local GameClock = require(Shared.Util.GameClock)

local WaveConfig = ServerConfig.Wave
local DifficultyConfig = ServerConfig.Difficulty

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("MobService")

local BASE_MAX_HEALTH = 100
local MOB_DAMAGE = 20

-- How often an enemy's nearest node is looked up again. The same value is in
-- `TargetingController`: both sides must see the enemy on the same stretch of
-- path, or the tower aims at one and the damage goes to another.
local NODE_PROGRESS_REFRESH = 0.1

local function computeTurnDistances(positions)
	local turnDistances = {}
	local total = 0

	for i = 2, #positions do
		total += (positions[i] - positions[i - 1]).Magnitude
		if i < #positions then
			table.insert(turnDistances, total)
		end
	end

	return turnDistances
end

--[=[
	An enemy's speed now: the spawn base, times what its gimmicks accumulated, times what
	weather does, times what cards do.

	The factors are kept separate on purpose. Weather comes and goes mid-wave, and an
	enemy that already gained 30% per turn must keep that gain when the wind stops, which
	only works if the math is redone from the base instead of multiplying the current
	value.

	Cards add two factors for the same reason, and there are two because the two slows
	have different owners: `CardSpeedScale` belongs to the room (the Staff of Azure Ever
	Ice, which hits everyone at once) and `SlowScale` to the enemy (the slow an ice unit
	left on that enemy). One must not erase the other.

	`RushScale` is the burst the enemy gives itself (the Astral Sentinel's
	`HealthThresholdRush`). A separate factor for the same reason: it lasts three seconds
	and must go away on its own without taking along an ice slow that came in during it.

	`AuraSlowScale` is the Cryomancer's ring (`SetAuraSlows`), and it is the one slow
	that does **not** multiply: it competes with the other two together, and the
	enemy walks at whichever is slower. A 30% ring over a 30% frost is still 30%.

	See docs/game/enemies.md.
]=]
local function computeSpeed(self, mob)
	local slowed = math.min(
		(self.CardSpeedScale or 1) * (mob.SlowScale or 1),
		mob.AuraSlowScale or 1
	)

	return mob.BaseSpeed
		* (mob.SpeedScale or 1)
		* (self.WeatherSpeedScale or 1)
		* slowed
		* (mob.RushScale or 1)
end

--[=[
	Sends this enemy's current speed to everyone.

	A stopped enemy is left out: its client already got zero, and whatever releases it
	(`StunMob`, `FreezeAll`, the boss gimmick) resends the right speed when releasing.
	Sending here would make the model start walking on screen with the server still
	holding the enemy in place.
]=]
local function broadcastSpeed(self, mobId, mob)
	if (mob.StunnedUntil or 0) > GameClock.Now() then return end

	for _, player in Players:GetPlayers() do
		Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
	end
end

local GimmickHandlers = {
	PerTurnSpeedMultiplier = {
		OnTurn = function(self, mobId, mob, gimmick)
			local stacks = mob.GimmickState[gimmick] or 0
			local maxStacks = gimmick.MaxStacks
			if not maxStacks or stacks < maxStacks then
				stacks += 1
				mob.GimmickState[gimmick] = stacks
			end

			mob.SpeedScale = math.max(0.1, 1 + (stacks * (gimmick.Amount or 0)))
			mob.CurrentSpeed = computeSpeed(self, mob)

			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
			end
		end,
	},

	--[=[
		The half-health burst: plays the animation and, when it reaches the marker, the
		enemy speeds up for a while.

		The marker is **not** listened to on the client. The server counts, with the
		`MarkerTime` the config carries measured from the asset, for the same reason as
		the Champion gimmick's `AnimTime` below: speed is match state, and match state
		must not come from a client notification: that would be N notifications in a room
		of N players, each at its own ping, and one of them would be enough to speed up
		everyone's boss.

		Both deadlines run on the match clock, so at 2x the burst arrives in half the time,
		and so does the animation on the client, which runs at `TimeScale`.
	]=]
	HealthThresholdRush = {
		OnDamage = function(self, mobId, mob, gimmick)
			if gimmick.Once and mob.GimmickState[gimmick] then return end
			if mob.Health > mob.MaxHealth * (gimmick.Threshold or 0.5) then return end

			mob.GimmickState[gimmick] = true

			local animation = gimmick.Animation or "Rush"
			for _, player in Players:GetPlayers() do
				Framework:Fire("MobPlayAnim", player, mobId, animation)
			end

			-- One token per burst: with `Once` there is only one, but without it a second
			-- burst would have the first one's end erasing it midway.
			mob.RushToken = (mob.RushToken or 0) + 1
			local token = mob.RushToken

			GameClock.Delay(math.max(0, gimmick.MarkerTime or 0), function()
				if self.ActiveMobs[mobId] ~= mob or mob.RushToken ~= token then return end

				mob.RushScale = 1 + (gimmick.Amount or 0)
				mob.CurrentSpeed = computeSpeed(self, mob)
				broadcastSpeed(self, mobId, mob)

				GameClock.Delay(math.max(0, gimmick.Duration or 0), function()
					if self.ActiveMobs[mobId] ~= mob or mob.RushToken ~= token then return end

					mob.RushScale = 1
					mob.CurrentSpeed = computeSpeed(self, mob)
					broadcastSpeed(self, mobId, mob)
				end)
			end)
		end,
	},

	HealthThresholdStunRandomUnit = {
		OnDamage = function(self, mobId, mob, gimmick)
			if gimmick.Once and mob.GimmickState[gimmick] then return end
			if mob.Health > mob.MaxHealth * (gimmick.Threshold or 0.5) then return end

			mob.GimmickState[gimmick] = true

			local freezeTime = gimmick.AnimTime or 0
			mob.StunnedUntil = math.max(mob.StunnedUntil or 0, GameClock.Now() + freezeTime)

			for _, player in Players:GetPlayers() do
				Framework:Fire("MobPlayAttack", player, mobId)
				Framework:Fire("UpdateMobSpeed", player, mobId, 0)
			end

			GameClock.Delay(freezeTime, function()
				if self.ActiveMobs[mobId] ~= mob then return end

				-- A Time Stop or a longer ice may have come in meanwhile: then it releases
				-- the model, and `broadcastSpeed` stays quiet.
				broadcastSpeed(self, mobId, mob)

				local unitService = self.Services.UnitService
				if unitService then
					unitService:StunRandomUnit(gimmick.StunDuration or 0)
				end
			end)
		end,
	},
}

local MobService = {
	Services = {
		WaveService = {},
		UnitService = {},
		DataService = {},
		DifficultyService = {},
		WeatherService = {},
		CardModifierService = {},
		IndexService = {},
	},
	ActiveMobs = {},
	DebugParts = {},
	PositionCache = {},

	-- Where each enemy was at the start of the frame. See `getPreviousMobPosition`.
	PreviousPositionCache = {},

	FrameId = 0,
	BaseHealth = BASE_MAX_HEALTH,
	MaxBaseHealth = BASE_MAX_HEALTH,
	ActiveMobCount = 0,

	-- What the last wave spawned each entity with; see `GetWaveStats`.
	WaveStats = {},

	-- The active weather and what it does to enemy speed. Health has no
	-- equivalent field because it only applies at spawn; see `SpawnWave`.
	Weather = nil,
	WeatherSpeedScale = 1,

	--[[
		What round cards are doing to the whole room.

		`CardSpeedScale` is the Staff of Azure Ever Ice's global slow, and
		`BrittleMultiplier` is the "brittle" it leaves when used during snow: all damage
		entering an enemy goes through it.

		Both live in the service, not the enemy, because they also apply to enemies
		spawned during the window: the same reason as `FreezeUntil` below.
	]]
	CardSpeedScale = 1,
	CardSlowToken = 0,
	BrittleMultiplier = 1,
	BrittleToken = 0,
	SessionCash = {},
	SessionDamage = {},

	--[[
		The match scoreboard contracts read, by UserId:
		`{ Kills, BossKills, Stuns, Earned, Spent }`.

		It only counts what is **the player's**: kills and stuns belong to whoever owned the
		unit, and `Earned`/`Spent` are their match cash. It resets along with
		`SessionDamage`, at the start of each match, which is why `Earned` and `Spent` are
		"within a single match", which is what spending and earning contracts ask for.

		`ContractTrackerService` reads it, every so often and at the end of the round
		(`GetSessionStats`). A signal per hit would be one event per damage; a counter read
		in batches costs one sum.
	]]
	SessionStats = {},

	--[[
		Until when Time Stop holds everyone, on the match clock, and the token of the
		freeze in effect. Nil outside a freeze. See `FreezeAll`.
	]]
	FreezeUntil = nil,
	FreezeToken = 0,

	-- The fractional remainder of the aura bonus, per player. See `applyCashBonus`.
	BonusRemainder = {},
}

--[=[
	Turns weather effects on enemies on (or off, with nil).

	`WeatherRoundService` calls it, at the start of the wave where the weather comes in or
	leaves. Speed is recomputed for every enemy already walking and replicated right
	away: without that, enemies born before the wind would keep the old pace until the
	end of the path, and two identical enemies would walk at different speeds in the same
	wave.

	Health is not touched here on purpose: changing `MaxHealth` mid-walk would either heal
	the enemy or kill it on the spot, and both are worse than the next wave simply being
	born with the right value.
]=]
function MobService:ApplyWeather(weatherName : string?)
	self.Weather = weatherName
	self.WeatherSpeedScale = SharedConfig.WeatherConfig.GetMobMultiplier(weatherName, "Speed")

	for mobId, mob in self.ActiveMobs do
		local speed = computeSpeed(self, mob)
		if speed ~= mob.CurrentSpeed then
			mob.CurrentSpeed = speed

			-- A stopped enemy only stores the new speed: whatever releases it sends it.
			broadcastSpeed(self, mobId, mob)
		end
	end
end

function MobService:GetWeather() : string?
	return self.Weather
end

--[=[
	Stops every enemy on the map for `duration`. `CardShopService` calls it (the Time
	Stop card).

	The freeze is the same `StunnedUntil` the boss gimmick uses: the Heartbeat loop only
	adds distance once the match clock passes it. That means the freeze time is **match**
	time, not screen time: four seconds at 2x are two real seconds, the same as the rest
	of gameplay. It is the only way for the freeze to be worth the same amount of path
	walked at any speed.

	`FreezeUntil` is stored in the service because the wave may keep spawning during the
	freeze: an enemy born inside the window is born stopped, instead of Time Stop
	becoming "for those already on the map".

	`UpdateMobSpeed` to zero is the other side of the same thing: `MobController` moves
	the model on screen, and without it the model would keep walking until the server
	sent the position back.
]=]
function MobService:FreezeAll(duration : number?) : number
	duration = math.max(0, duration or 0)
	if duration <= 0 then return 0 end

	self.FreezeUntil = math.max(self.FreezeUntil or 0, GameClock.Now() + duration)

	local frozen = 0
	for mobId, mob in self.ActiveMobs do
		mob.StunnedUntil = math.max(mob.StunnedUntil or 0, self.FreezeUntil)
		frozen += 1

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, 0)
		end
	end

	--[[
		One token per freeze. Two overlapping Time Stops extend the window (`FreezeUntil`
		is a max), and then only the last thaw may count: without that the first would end
		in the middle of the second and restore enemy speed with the window still open.
	]]
	self.FreezeToken = (self.FreezeToken or 0) + 1
	local token = self.FreezeToken

	GameClock.Delay(self.FreezeUntil - GameClock.Now(), function()
		if self.FreezeToken ~= token then return end

		self.FreezeUntil = nil

		-- An enemy hit by an ice or a shock that goes beyond the Time Stop stays stopped:
		-- `broadcastSpeed` skips it, and its `StunMob` releases it at the right time.
		for mobId, mob in self.ActiveMobs do
			broadcastSpeed(self, mobId, mob)
		end
	end)

	return frozen
end

--[[ WHAT CARDS DO TO ENEMIES ]]

--[=[
	The global multiplier for a card stat (`Slow`, `Burn`).

	A shortcut so `CardModifier` does not spread around here: what this service cares
	about is a number, not the grammar that produced it.
]=]
function MobService:cardStat(stat : string) : number
	local service = self.Services.CardModifierService

	return service and service:GetGlobal(stat) or 1
end

--[=[
	Sends everyone's current speed to the clients.

	`MobController` moves the model on screen, with the speed the server sent last:
	without this the enemy would keep walking at the old pace until something else
	touched it.

	A frozen enemy is left out: its client already got zero, and sending the "real" speed
	in the middle of a Time Stop would make it walk.
]=]
function MobService:_broadcastSpeeds()
	local now = GameClock.Now()

	for mobId, mob in self.ActiveMobs do
		local speed = computeSpeed(self, mob)
		mob.CurrentSpeed = speed

		if (mob.StunnedUntil or 0) > now then continue end

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, speed)
		end
	end
end

--[=[
	Chills the whole room: every enemy walks `slow` slower for `duration`, and with
	`brittle` all damage entering them in the period is worth more. It is the Staff of
	Azure Ever Ice.

	`slow` is the **fraction removed**: 0.5 is "walks at half speed", 0.75 is "walks at a
	quarter". Written this way because that is how the card describes itself to the
	player, and translating to a scale in a single place avoids the confusion of reading
	"0.25" and thinking the card is weak.

	It also applies to enemies born during the window: the scale lives in the service and
	enters everyone's `computeSpeed`, like weather.

	Two overlapping cards: the **stronger** rules, and the deadline and token are the last
	one's. Multiplying both would make a second use during the first stop the whole room,
	which neither promised.
]=]
function MobService:ChillAll(slow : number?, duration : number?, brittle : number?) : number
	duration = math.max(0, duration or 0)
	if duration <= 0 then return 0 end

	local scale = 1 - math.clamp(slow or 0, 0, 0.95)

	if scale < (self.CardSpeedScale or 1) then
		self.CardSpeedScale = scale
	end

	self.CardSlowToken = (self.CardSlowToken or 0) + 1
	local slowToken = self.CardSlowToken

	self:_broadcastSpeeds()

	--[[
		Match time, not real time: the card's ten seconds are ten seconds of play, the same
		as Time Stop and stuns. At 3x they pass in a little over three wall-clock seconds,
		and that is what makes the card worth the same amount of path walked at any speed.
	]]
	GameClock.Delay(duration, function()
		if self.CardSlowToken ~= slowToken then return end

		self.CardSpeedScale = 1
		self:_broadcastSpeeds()
	end)

	if brittle and brittle > 1 then
		self.BrittleMultiplier = math.max(self.BrittleMultiplier or 1, brittle)

		self.BrittleToken = (self.BrittleToken or 0) + 1
		local brittleToken = self.BrittleToken

		GameClock.Delay(duration, function()
			if self.BrittleToken ~= brittleToken then return end

			self.BrittleMultiplier = 1
		end)
	end

	return self.ActiveMobCount
end

--[=[
	The slow a unit leaves on a single enemy.

	`amount` is the fraction removed, as in `ChillAll`, and the Chill Out card applies on
	top: `Slow` is a global multiplier, so 0.2 with the card on the field becomes 0.22.
	The 0.95 cap exists so no sum of cards stops an enemy for good: stopping enemies is
	Time Stop's job, and that costs another card.

	The **strongest rules**, not the most recent: a weak splash in the middle of a strong
	slow must not shorten the strong one. The deadline, however, is always the last hit's,
	or equal slows in sequence would never refresh.

	> Today the Frostione uses this, through `ApplyFrost`: the frost stacks' slow is this
	> one, and that is how the Chill Out card reaches it. The `UnitStats[name].Slow`
	> field, which calls this directly, still has no unit.
]=]
function MobService:ApplySlow(mobId : string, amount : number?, duration : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	duration = math.max(0, duration or 0)
	if duration <= 0 then return end

	local effective = math.clamp((amount or 0) * self:cardStat("Slow"), 0, 0.95)
	if effective <= 0 then return end

	local scale = 1 - effective
	if scale < (mob.SlowScale or 1) then
		mob.SlowScale = scale
	end

	mob.SlowToken = (mob.SlowToken or 0) + 1
	local token = mob.SlowToken

	mob.CurrentSpeed = computeSpeed(self, mob)

	if (mob.StunnedUntil or 0) <= GameClock.Now() then
		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
		end
	end

	GameClock.Delay(duration, function()
		-- The enemy may have died, and its table is no longer anywhere.
		if self.ActiveMobs[mobId] ~= mob or mob.SlowToken ~= token then return end

		mob.SlowScale = 1
		mob.CurrentSpeed = computeSpeed(self, mob)

		if (mob.StunnedUntil or 0) <= GameClock.Now() then
			for _, player in Players:GetPlayers() do
				Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
			end
		end
	end)
end

--[=[
	The Cryomancer's rings, for this frame: `slows` maps each enemy inside a ring to the
	strongest slow over it (the fraction removed). Any enemy missing from the map is
	outside every ring and walks free of them again, at once: no deadline, unlike
	`ApplySlow`.

	`UnitService:stepSlowAuras` calls it every frame, so the speed only goes out when an
	enemy's factor changes (it entered, left, or the ring was upgraded), never per frame.
	The Chill Out card (`Slow`) multiplies it, the same as `ApplySlow`.

	The factor competes with the other slows instead of stacking (see `computeSpeed`).

	Entering the first ring and leaving the last also fire `MobAuraSlowed`, which puts
	`FrozenAuraVFX` on the enemy and takes it off (`VFXController:SetFrozenAura`). A
	change of strength between rings does not: the effect is the same.
]=]
function MobService:SetAuraSlows(slows : { [string] : number })
	local cardSlow = self:cardStat("Slow")

	for mobId, mob in self.ActiveMobs do
		local previous = mob.AuraSlowScale or 1
		local scale = 1 - math.clamp((slows[mobId] or 0) * cardSlow, 0, 0.95)

		if scale ~= previous then
			mob.AuraSlowScale = scale
			mob.CurrentSpeed = computeSpeed(self, mob)

			broadcastSpeed(self, mobId, mob)

			local slowed = scale < 1
			if slowed ~= (previous < 1) then
				for _, player in Players:GetPlayers() do
					Framework:Fire("MobAuraSlowed", player, mobId, slowed)
				end
			end
		end
	end
end

--[=[
	A frost stack on an enemy: the hitting unit's `Frost` from `UnitStats`.

	**The count is per unit.** Each Frostione has its own stacks on this enemy
	(`mob.FrostStacks[unitId]`), and its hit only refreshes its own stacks' timer
	(`Frost.Duration`): two Frostiones on the same target do not close the four in half
	the time; each closes its own.

	The slow, however, is a single one: the enemy is `Frost.Slow` slower while **any**
	Frostione has a stack on it. It is `ApplySlow`'s, refreshed on any one's hit with the
	same deadline, so it ends with the last hit's stacks, and the Chill Out card enters
	through there.

	When a unit's count reaches `FreezeStacks`, the enemy freezes for `FreezeDuration`
	(`StunMob`, which counts toward its owner's stun contracts) and **every** count
	resets, slow included: once thawed, it walks at its usual pace.

	After that it is immune to frost for `FreezeImmunity` more seconds
	(`mob.FrostImmuneUntil`): no hit adds a stack while it is frozen **nor** during the
	grace period right after, whoever it comes from. That is what prevents an endless
	freeze: without the grace period, the window in which the enemy walks is only the
	time to rebuild the four stacks, which shrinks with the unit's cooldown (upgrades,
	snow weather, attack speed cards) to almost nothing.

	The freeze visual comes from here through `MobFrozen`, because only the server knows
	when the count completed.
]=]
function MobService:ApplyFrost(mobId : string, frost, sourceUserId : number?, sourceUnitId : string?)
	local mob = self.ActiveMobs[mobId]
	if not mob or typeof(frost) ~= "table" then return end

	local now = GameClock.Now()

	-- Frozen, or in the grace period right after thawing: the hit leaves no stack.
	if now < (mob.FrostImmuneUntil or 0) then return end

	local stacks = mob.FrostStacks
	if not stacks then
		stacks = {}
		mob.FrostStacks = stacks
	end

	-- Without an id, the caller did not say where the hit came from: it goes to a shared count.
	local key = sourceUnitId or "_"
	local state = stacks[key]
	if not state then
		state = { count = 0, token = 0 }
		stacks[key] = state
	end

	state.count += 1
	state.token += 1

	if state.count >= math.max(1, frost.FreezeStacks or 4) then
		local duration = math.max(0, frost.FreezeDuration or 0)
		local immunity = math.max(0, frost.FreezeImmunity or 0)

		table.clear(stacks)

		-- The immunity covers the whole freeze plus the grace period: until it
		-- expires, `ApplyFrost` exits on the first line.
		mob.FrostImmuneUntil = now + duration + immunity

		-- The slow leaves with the stacks. The new token invalidates the end the last
		-- `ApplySlow` scheduled, which would otherwise touch the speed again later.
		-- Comes before `StunMob` on purpose: `CurrentSpeed` is what it restores to the
		-- screen when the freeze ends.
		mob.SlowToken = (mob.SlowToken or 0) + 1
		mob.SlowScale = 1
		mob.CurrentSpeed = computeSpeed(self, mob)

		self:StunMob(mobId, duration, sourceUserId)

		for _, player in Players:GetPlayers() do
			Framework:Fire("MobFrozen", player, mobId, duration)
		end

		return
	end

	self:ApplySlow(mobId, frost.Slow, frost.Duration)

	local token = state.token
	GameClock.Delay(math.max(0, frost.Duration or 0), function()
		-- Died, the count reset in a freeze (this unit's table left), or this same unit
		-- hit again meanwhile: the deadline now is that hit's.
		if self.ActiveMobs[mobId] ~= mob or stacks[key] ~= state or state.token ~= token then return end

		stacks[key] = nil
	end)
end

--[=[
	Stops an enemy completely, for `duration` match seconds.

	It is the same `StunnedUntil` as Time Stop and the boss gimmick (the movement loop only
	advances with `now >= StunnedUntil`), but on a single enemy. It is not a slow: a slow
	changes speed, and this takes the enemy out of the loop. A unit can leave both on the
	same hit, though none does today: the Electro only stops.

	**The longer deadline rules, and the shorter does not touch it.** A 0.3s shock in the
	middle of a 5s Time Stop must not return the enemy to the path when the 0.3s end:
	hence the early exit above and the deadline check when releasing. Refreshing a shock
	that is still running only extends the deadline.

	`UpdateMobSpeed` to zero is the other side of this: `MobController` moves the model on
	screen, and without the notification it would keep walking until the server sent the
	position back.
]=]
function MobService:StunMob(mobId : string, duration : number?, sourceUserId : number?)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	duration = math.max(0, duration or 0)
	if duration <= 0 then return end

	local stunnedUntil = GameClock.Now() + duration

	-- Already stopped for longer than this shock would ask: there is nothing to do,
	-- and touching it would shorten the freeze of whoever came first.
	if stunnedUntil <= (mob.StunnedUntil or 0) then return end

	mob.StunnedUntil = stunnedUntil

	-- Only the shock that actually stopped the enemy counts for the unit's owner: one
	-- that left through the line above stunned nobody.
	local stats = self:_sessionStatsOf(sourceUserId)
	if stats then
		stats.Stuns += 1
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("UpdateMobSpeed", player, mobId, 0)
	end

	GameClock.Delay(duration, function()
		-- Died, or its table now belongs to another enemy with the same id.
		if self.ActiveMobs[mobId] ~= mob then return end

		-- A longer freeze took over during this one: it releases the enemy.
		if GameClock.Now() < (mob.StunnedUntil or 0) then return end

		for _, player in Players:GetPlayers() do
			Framework:Fire("UpdateMobSpeed", player, mobId, mob.CurrentSpeed)
		end
	end)
end

--[=[
	Sets an enemy on fire: `damage` every `interval` seconds, `ticks` times.

	Each tick goes through `DamageMob` like any other damage: it pays cash, counts toward
	the unit's scoreboard, and kills if it can. The Fire Hazard card applies to each tick,
	not the total: a burn already in the air charges more as soon as the card is used,
	instead of waiting for the next one.

	**It neither stacks nor refreshes**: a fire hit on an enemy already burning is ignored,
	whether from the same unit or another: it neither adds damage nor restarts the
	deadline. Only after the burn ends does a new hit light another. Without this, a fast
	fire unit would multiply its own DPS, and several on the same target would keep the
	fire lit forever.

	The ticks charge on behalf of whoever **lit** the fire: its `ownerUserId` takes the
	cash to the end, even if another player hits the target meanwhile.

	The visual comes from here through `MobBurning`, because only the server knows whether
	the hit lit a new fire or landed on something already burning. Today the Pyre burns.
]=]
function MobService:ApplyBleed(mobId : string, damage : number?, ticks : number?, interval : number?, ownerUserId : number?, vulnerability : number?)
	self:applyDamageOverTime(mobId, damage, ticks, interval, ownerUserId, {
		UntilKey = "BleedingUntil",
		Event = "MobBleeding",
		VulnerabilityKey = "BleedVulnerability",
		Vulnerability = vulnerability,
		DamageClass = "Melee",
	})
end

--[=[
	Makes an enemy bleed. It is burn under another name and visual: the same tick, owner,
	and **neither stacks nor refreshes** rules as `ApplyBurn`, with its own deadline
	(`BleedingUntil`): bleeding and burning coexist on the same target.

	What bleeding adds is the **open wound**: while the deadline runs, all damage entering
	the enemy is worth `vulnerability` times more (1.3 is "+30%"). This is not a tower
	buff (it is the enemy that is more fragile), so `DamageMob` charges it, along with the
	card's "brittle", and it applies to any source: another unit, area splash, tripmines,
	and the bleed's own ticks.

	The multiplier lives on the enemy (`BleedVulnerability`), not on the deadline, because
	the value belongs to whoever opened the wound: whoever refreshes the bleed later (only
	once the deadline ends, by the no-stacking rule) writes theirs on top.

	No card changes bleeding: Fire Hazard is for fire. The visual comes through
	`MobBleeding` (`BleedVFX`). Today the Slasher and the Berserker bleed, with the same 30%
	wound, and by the no-stacking rule the two together open a single wound.
]=]
function MobService:ApplyBleed(mobId : string, damage : number?, ticks : number?, interval : number?, ownerUserId : number?, vulnerability : number?)
	self:applyDamageOverTime(mobId, damage, ticks, interval, ownerUserId, {
		UntilKey = "BleedingUntil",
		Event = "MobBleeding",
		VulnerabilityKey = "BleedVulnerability",
		Vulnerability = vulnerability,
	})
end

--[=[
	The damage over time underneath `ApplyBurn` and `ApplyBleed`.

	`kind.UntilKey` is the deadline field on the enemy (one per effect, so the two do not
	block each other), `kind.Event` is the visual's notification, and `kind.CardStat` is
	the global card that multiplies each tick, when there is one. The on-screen tick is
	the same `MobDamageTick` for all: number and health bar do not depend on the effect.

	`kind.VulnerabilityKey` and `kind.Vulnerability` are for an effect that also makes the
	target more fragile while it lasts (today only bleeding): the number is stored on the
	enemy and `DamageMob` charges it, by the same `kind.UntilKey` deadline.
]=]
function MobService:applyDamageOverTime(mobId : string, damage : number?, ticks : number?, interval : number?, ownerUserId : number?, kind)
	local mob = self.ActiveMobs[mobId]
	if not mob then return end

	damage = damage or 0
	ticks = math.floor(ticks or 0)
	interval = interval or 1

	if damage <= 0 or ticks <= 0 or interval <= 0 then return end

	local now = GameClock.Now()
	if now < (mob[kind.UntilKey] or 0) then return end

	local duration = ticks * interval
	mob[kind.UntilKey] = now + duration

	-- Written along with the deadline, and never erased: readers check the deadline first,
	-- so a stale value from a bleed that already ended charges nothing.
	if kind.VulnerabilityKey then
		mob[kind.VulnerabilityKey] = math.max(1, kind.Vulnerability or 1)
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire(kind.Event, player, mobId, duration)
	end

	task.spawn(function()
		for _ = 1, ticks do
			GameClock.Wait(interval)

			if self.ActiveMobs[mobId] ~= mob then return end

			local multiplier = if kind.CardStat then self:cardStat(kind.CardStat) else 1
			local tick = math.max(1, math.floor(damage * multiplier + 0.5))
			local dealt = self:DamageMob(mobId, tick, ownerUserId, nil, nil, kind.DamageClass)
			
			-- `DamageMob` does not notify the screen: a regular hit's number and health bar
			-- come from the unit's `AttackVisual`, and a tick has no unit.
			if dealt > 0 then
				for _, player in Players:GetPlayers() do
					Framework:Fire("MobDamageTick", player, mobId, dealt)
				end
			end
		end
	end)
end

--[=[
	Every route of the current map, with the turn distances already computed.

	A map without a fork returns a single route, and everything that consumes this stays
	the same. With a fork, each combination becomes its own linear route: the enemy draws
	an index at spawn and carries it for the rest of its life.
]=]
function MobService:getRoutes()
	if not self.Routes then
		local routes = PathUtil.BuildRoutes(workspace.PathScriptable.Nodes)
		for _, route in routes do
			route.turnDistances = computeTurnDistances(route.positions)
		end
		self.Routes = routes
	end
	return self.Routes
end

--[=[
	The path nodes with each one's distance to the first, for the `Farthest` priority. It
	drops with the routes when the map changes.
]=]
function MobService:getNodeDistances()
	if not self.NodeDistances then
		self.NodeDistances = PathUtil.BuildNodeDistances(self:getRoutes())
	end
	return self.NodeDistances
end

--[=[
	How far the enemy has gone along the path, cached.

	The node sweep is cheap, but it runs per unit and per enemy: in a big wave with many
	towers on `Farthest` that becomes the product of the two. Since an enemy does not
	change node every frame, the math holds for `NODE_PROGRESS_REFRESH`.
]=]
function MobService:getMobPathProgress(mob, position : Vector3, nodeDistances)
	local now = GameClock.Now()

	if mob.NodeProgress and now - (mob.NodeProgressClock or 0) < NODE_PROGRESS_REFRESH then
		return mob.NodeProgress
	end

	mob.NodeProgress = PathUtil.GetNodeProgress(nodeDistances, position)
	mob.NodeProgressClock = now

	return mob.NodeProgress
end

--[=[
	Each route node's distance along the **smoothed** path, which is `mob.Distance`'s ruler.

	Rounded turns make the smoothed path a bit shorter than the raw polyline, so adding the
	raw segments would put the node a few studs ahead of where the enemy actually passes
	it. A node's distance is that of the smoothed point nearest to it.

	Cached on the route itself, which drops entirely when the map changes.
]=]
local function nodeDistancesAlongSmooth(route)
	if route.nodeSmoothDistances then
		return route.nodeSmoothDistances
	end

	local smooth = route.smooth
	local distances = {}

	for _, position in route.positions do
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

--[=[
	Throws an enemy back to the path's previous node: the last one it passed, or the start
	if it has not passed any. It is the Archmage's `Teleport`, and it applies to bosses too.

	Only `Distance` goes back. `NextTurnIndex` stays where it was on purpose, so turn
	gimmicks (the Wall Smasher speeding up) do not fire again when it passes the same turn.
	The client simulates the walk on its own, so `MobTeleported` carries the new distance
	for it to jump along.

	Returns whether the enemy actually went back.
]=]
function MobService:TeleportMobBack(mobId : string) : boolean
	local mob = self.ActiveMobs[mobId]
	if not mob then return false end

	local routes = self:getRoutes()
	local route = routes[mob.RouteIndex or 1] or routes[1]
	if not route then return false end

	-- A node less than half a stud behind is "where it is", not the previous one: an
	-- enemy standing on a node goes back to the one before it.
	local target = 0
	for _, distance in nodeDistancesAlongSmooth(route) do
		if distance < mob.Distance - 0.5 and distance > target then
			target = distance
		end
	end

	if target >= mob.Distance then return false end

	mob.Distance = target
	mob.LastDistance = target
	mob.NodeProgress = nil
	self.PositionCache[mobId] = nil
	self.PreviousPositionCache[mobId] = nil

	for _, player in Players:GetPlayers() do
		Framework:Fire("MobTeleported", player, mobId, target)
	end

	return true
end

function MobService:getSmoothPath(routeIndex : number?)
	local routes = self:getRoutes()
	local route = routes[routeIndex or 1] or routes[1]
	return route.smooth
end

function MobService:getDifficulty()
	local difficultyService = self.Services.DifficultyService
	if difficultyService and difficultyService.GetSelected then
		return difficultyService:GetSelected()
	end

	return DifficultyConfig.Get()
end

function MobService:ApplyDifficulty(preset)
	self.MaxBaseHealth = preset.BaseHealth or BASE_MAX_HEALTH
	self.BaseHealth = self.MaxBaseHealth
	self:broadcastBaseHealth()

	-- The match starts here: resets the damage scoreboard that decides the MVP, and the contracts' one.
	table.clear(self.SessionDamage)
	table.clear(self.SessionStats)

	for _, player in Players:GetPlayers() do
		self.SessionCash[player.UserId] = player.Name == "raixyzdev" and 1000000 or preset.StartingCash
		Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
	end
end

function MobService:initPlayerCash(player)
	local startingCash = player.Name == "raixyzdev" and 1000000 or self:getDifficulty().StartingCash
	self.SessionCash[player.UserId] = startingCash
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
end

function MobService:getCash(player)
	return self.SessionCash[player.UserId] or 0
end

function MobService:addCash(player, amount)
	if not player or not player.Parent then return end
	self.SessionCash[player.UserId] = (self.SessionCash[player.UserId] or 0) + amount
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])

	local stats = self:_sessionStatsOf(player.UserId)
	if stats and amount > 0 then
		stats.Earned += amount
	end
end

function MobService:spendCash(player, amount)
	if not player or not player.Parent then return end
	self.SessionCash[player.UserId] = math.max(0, (self.SessionCash[player.UserId] or 0) - amount)
	Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])

	local stats = self:_sessionStatsOf(player.UserId)
	if stats and amount > 0 then
		stats.Spent += amount
	end
end

--- The player's contract scoreboard for this match, created the first time.
function MobService:_sessionStatsOf(userId : number?)
	if not userId then return nil end

	local stats = self.SessionStats[userId]
	if not stats then
		stats = { Kills = 0, BossKills = 0, Stuns = 0, Earned = 0, Spent = 0 }
		self.SessionStats[userId] = stats
	end

	return stats
end

--[=[
	The player's contract scoreboard for this match (see `SessionStats`). Zeros for those
	who have done nothing yet, never nil, so readers can subtract directly.
]=]
function MobService:GetSessionStats(userId : number)
	return self.SessionStats[userId] or { Kills = 0, BossKills = 0, Stuns = 0, Earned = 0, Spent = 0 }
end

function MobService:broadcastBaseHealth()
	for _, player in Players:GetPlayers() do
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
	end
end

function MobService:removeMob(mobId)
	if not self.ActiveMobs[mobId] then return end
	self.ActiveMobs[mobId] = nil
	self.PositionCache[mobId] = nil
	self.PreviousPositionCache[mobId] = nil
	self.ActiveMobCount = math.max(0, self.ActiveMobCount - 1)

	for _, player in Players:GetPlayers() do
		Framework:Fire("KillClientMob", player, mobId)
	end

	if self.ActiveMobCount == 0 and self.AllMobsSpawned then
		self.Services.WaveService.Signals.Ended:Fire()
	end
end

function MobService:mobEscaped(mobId)
	if not self.ActiveMobs[mobId] then return end

	self.BaseHealth = math.max(0, self.BaseHealth - (self:getDifficulty().MobDamage or MOB_DAMAGE))
	self:broadcastBaseHealth()

	if self.BaseHealth <= 0 then
		self:onGameOver()
		return
	end

	self:removeMob(mobId)
end

function MobService:onGameOver()
	for mobId, _ in self.ActiveMobs do
		for _, player in Players:GetPlayers() do
			Framework:Fire("KillClientMob", player, mobId)
		end
	end
	table.clear(self.ActiveMobs)
	table.clear(self.PositionCache)
	table.clear(self.PreviousPositionCache)
	self.ActiveMobCount = 0
	self.AllMobsSpawned = false

	for _, player in Players:GetPlayers() do
		Framework:Fire("GameOver", player)
	end

	--[[
		Health does **not** return to full here: the base stays at zero until the next round
		(`ResetRound`/`ApplyDifficulty`).

		It was already zeroed and broadcast by `mobEscaped`, and healing it back would write
		the full number on the billboard right after game over. Worse: every
		`BaseHealth <= 0` guard in the service (the movement loop's cutoff, `SpawnWave`'s)
		would become dead code, because health would already be full when they were read.
	]]

	local waveService = self.Services.WaveService
	if waveService then
		waveService.GameOver = true
		waveService.Signals.Ended:Fire()
	end
end

--[=[
	Returns the service to its pre-match state. Called by WaveService in `ResetRound()`;
	it touches nothing that belongs to another service.

	Unlike `onGameOver`, there is no game-over notification here: enemies vanish from the
	clients and the damage scoreboard resets, without firing `GameOver`.
]=]
function MobService:ResetRound()
	for mobId, _ in self.ActiveMobs do
		for _, player in Players:GetPlayers() do
			Framework:Fire("KillClientMob", player, mobId)
		end
	end

	table.clear(self.ActiveMobs)
	table.clear(self.PositionCache)
	table.clear(self.PreviousPositionCache)
	table.clear(self.SessionDamage)
	table.clear(self.SessionStats)
	table.clear(self.BonusRemainder)
	table.clear(self.WaveStats)
	self.ActiveMobCount = 0
	self.AllMobsSpawned = false

	-- A Time Stop from the previous round must not freeze the next round's first wave.
	-- `FreezeToken` goes up so the scheduled thaw touches nothing anymore.
	self.FreezeUntil = nil
	self.FreezeToken = (self.FreezeToken or 0) + 1

	-- The same for cards: the Azure Ever Ice's slow and brittle belong to the
	-- match, and the tokens go up so each one's scheduled end does not wake later.
	self.CardSpeedScale = 1
	self.CardSlowToken = (self.CardSlowToken or 0) + 1
	self.BrittleMultiplier = 1
	self.BrittleToken = (self.BrittleToken or 0) + 1

	-- Routes are rebuilt on the next SpawnWave; dropping the cache avoids
	-- carrying stale geometry if the map changes between rounds.
	self.Routes = nil
	self.NodeDistances = nil

	self.BaseHealth = self.MaxBaseHealth
	self:broadcastBaseHealth()

	for _, player in Players:GetPlayers() do
		self:initPlayerCash(player)
	end
end

function MobService:PredictPosition(mobId)
	local mob = self.ActiveMobs[mobId]
	if not mob then return nil end

	return PathUtil.GetPositionAtDistance(self:getSmoothPath(mob.RouteIndex), mob.Distance)
end

--[=[
	Where the enemy was at the start of this frame.

	Cached per frame for the same reason as `getMobPosition`: the tripmine trigger asks,
	once per mine, and without a cache the math would become mines times enemies.

	Without `LastDistance` (the enemy spawned this frame), the answer is the current
	position: it has not moved yet, so its "segment" is a point.
]=]
function MobService:getPreviousMobPosition(mobId)
	local cached = self.PreviousPositionCache[mobId]
	if cached and cached.frame == self.FrameId then
		return cached.pos
	end

	local mob = self.ActiveMobs[mobId]
	if not mob then return nil end

	local pos = if mob.LastDistance
		then PathUtil.GetPositionAtDistance(self:getSmoothPath(mob.RouteIndex), mob.LastDistance)
		else self:getMobPosition(mobId)

	self.PreviousPositionCache[mobId] = { frame = self.FrameId, pos = pos }

	return pos
end

--[=[
	The shortest distance from `point` to segment `a`-`b`. Only the XZ plane matters:
	everything here moves on the ground, and the mine sits 0.35 stud above it.
]=]
local function distanceToSegment(point : Vector3, a : Vector3, b : Vector3) : number
	local flatPoint = Vector3.new(point.X, 0, point.Z)
	local flatA = Vector3.new(a.X, 0, a.Z)
	local segment = Vector3.new(b.X - a.X, 0, b.Z - a.Z)

	local lengthSquared = segment:Dot(segment)
	if lengthSquared < 1e-6 then
		return (flatPoint - flatA).Magnitude
	end

	local t = math.clamp((flatPoint - flatA):Dot(segment) / lengthSquared, 0, 1)

	return (flatPoint - (flatA + segment * t)).Magnitude
end

--[=[
	An enemy whose **path walked this frame** passed within `radius` of `position`, or
	nil. Which one does not matter: the tripmine trigger asks, and it only wants to know
	whether someone crossed.

	It differs from asking who is near now, and the difference only shows at speed: an
	enemy walks `CurrentSpeed * dt` per frame, and in that jump it can enter and leave the
	radius without ever being seen inside it. With the game at 3x and the server at 30Hz,
	Nightmare's fastest enemy takes steps of almost 6 studs, more than a tripmine
	trigger's diameter, which it then crosses unharmed.

	Testing the segment instead of the point takes the frame out of the equation: the
	mine explodes by **distance**, not by the luck of the frame landing on it.

	Returns the first that qualifies, without building a list: this runs once per mine per
	frame, and a table per call would be garbage to collect on each.
]=]
function MobService:GetMobCrossing(position : Vector3, radius : number) : string?
	for mobId, _ in self.ActiveMobs do
		local current = self:getMobPosition(mobId)
		if not current then continue end

		local previous = self:getPreviousMobPosition(mobId) or current

		if distanceToSegment(position, previous, current) <= radius then
			return mobId
		end
	end

	return nil
end

function MobService:processTurnGimmicks(mobId, mob)
	local turnDistances = mob.TurnDistances
	if not turnDistances then return end

	while mob.NextTurnIndex <= #turnDistances and mob.Distance >= turnDistances[mob.NextTurnIndex] do
		for _, gimmick in mob.Gimmicks do
			local handler = GimmickHandlers[gimmick.Type]
			if handler and handler.OnTurn then
				handler.OnTurn(self, mobId, mob, gimmick)
			end
		end
		mob.NextTurnIndex += 1
	end
end

function MobService:processDamageGimmicks(mobId, mob)
	for _, gimmick in mob.Gimmicks do
		local handler = GimmickHandlers[gimmick.Type]
		if handler and handler.OnDamage then
			handler.OnDamage(self, mobId, mob, gimmick)
		end
	end
end

function MobService:SpawnWave(waveNumber)
	local mobConfig = SharedConfig.Mob
	local preset = self:getDifficulty()
	local spawnList = WaveConfig.GetSpawns(waveNumber, preset.Name)

	--[[
		Health and speed come ready from the wave table (`Config.Waves`); the only thing
		on top is the weather's health, read once at the start of the wave: the weather in
		effect for the first enemy applies to all of the wave's, even if it leaves
		mid-walk. Weather speed is not here: it enters in `computeSpeed`, so it can leave
		later without taking along what the gimmicks added.
	]]
	local weatherHealth = SharedConfig.WeatherConfig.GetMobMultiplier(self.Weather, "Health")

	--[[
		Final health and the damage-reward scale, per entry, before the first spawn:
		`WaveStats` must know every entity of the wave from the start, not only the ones
		the spawn loop has reached (see `GetWaveStats`).
	]]
	self.WaveStats = {}

	for _, spawnEntry in spawnList do
		local entityDefinition = mobConfig.Entities[spawnEntry.Entity]
		if entityDefinition then
			local maxHealth = math.max(1, math.floor((spawnEntry.Health * weatherHealth) + 0.5))

			spawnEntry.MaxHealth = maxHealth

			--[[
				How much beefier than its reference health (`Mob.Entities`) the table and the
				weather made this enemy. The damage reward divides by it (see
				`awardDamageReward`): without that, income would grow with enemy health, and
				drought would make hitting enemies pay 40% more.
			]]
			spawnEntry.HealthScale = maxHealth / (entityDefinition.Health or maxHealth)

			self.WaveStats[spawnEntry.Entity] = {
				MaxHealth = maxHealth,
				BaseSpeed = spawnEntry.Speed,
				HealthScale = spawnEntry.HealthScale,
			}
		end
	end

	self.Routes = nil
	self.NodeDistances = nil
	local routes = self:getRoutes()

	self.AllMobsSpawned = false

	log:Debug(string.format("SpawnWave: wave=%d preset=%s spawns=%d base=%d routes=%d clock=%s",
		waveNumber, tostring(preset.Name), #spawnList, self.BaseHealth, #routes, tostring(GameClock.GetScale and GameClock.GetScale() or "?")))

	--[[
		The count is **not** reset here: a skipped wave (`WaveService:SkipWave`) spawns on
		top of the previous one's enemies, and resetting would make the leftovers subtract
		from the new wave's count: `Ended` would fire with living enemies on the map. The
		number is already the count of living enemies: spawning adds, `removeMob`
		subtracts, and the round reset zeroes it.
	]]

	task.spawn(function()
		for _, spawnEntry in spawnList do
			local entityDefinition = mobConfig.Entities[spawnEntry.Entity]
			if entityDefinition then
				-- Once per wave entry, not per enemy: the list is the same for all of
				-- this type, and what is per enemy (`GimmickState`) is the other table.
				local gimmicks = mobConfig.GetGimmicks(spawnEntry.Entity)
				local baseSpeed = spawnEntry.Speed
				local maxHealth = spawnEntry.MaxHealth

				for i = 1, (spawnEntry.Amount or 1) do
					if self.BaseHealth <= 0 then break end
					local mobId = HttpService:GenerateGUID(false)

					-- The fork is resolved here: the enemy draws which combination of paths
					-- it will take. Since each route is already a complete
					-- polyline, nothing needs to happen at the point where
					-- the paths split.
					local routeIndex = math.random(1, #routes)
					local route = routes[routeIndex]

					-- Spawning inside a Time Stop means spawning stopped: see `FreezeAll`.
					local frozenUntil = self.FreezeUntil or 0
					local spawnSpeed = baseSpeed * self.WeatherSpeedScale * (self.CardSpeedScale or 1)

					self.ActiveMobs[mobId] = {
						Name = spawnEntry.Entity,
						Health = maxHealth,
						MaxHealth = maxHealth,
						BaseSpeed = baseSpeed,
						SpeedScale = 1,

						-- The slow an ice unit leaves on this enemy. See
						-- `ApplySlow`.
						SlowScale = 1,
						CurrentSpeed = spawnSpeed,
						Distance = 0,
						StunnedUntil = frozenUntil,
						RouteIndex = routeIndex,
						PathLength = route.smooth.length,
						TurnDistances = route.turnDistances,
						NextTurnIndex = 1,
						Gimmicks = gimmicks,
						GimmickState = {},
						Reward = spawnEntry.Reward,
						HealthScale = spawnEntry.HealthScale,
					}
					self.ActiveMobCount += 1

					-- Everyone in the match saw it spawn, so it enters their Index.
					-- `UnlockEnemy` writes only the first time, so this costs a lookup.
					local indexService = self.Services.IndexService

					for _, player in Players:GetPlayers() do
						Framework:Fire("SpawnClientMob", player, {
							Id = mobId,
							Name = spawnEntry.Entity,
							Speed = if frozenUntil > GameClock.Now() then 0 else spawnSpeed,
							MaxHealth = maxHealth,
							Route = routeIndex,
						})

						if indexService then
							indexService:UnlockEnemy(player, spawnEntry.Entity)
						end
					end
					-- The group's last enemy waits the gap to the next group, when the
					-- wave table sets one (`GroupDelay` in `Config.Waves`).
					local isLast = i == (spawnEntry.Amount or 1)
					GameClock.Wait(if isLast and spawnEntry.GroupDelay then spawnEntry.GroupDelay else (spawnEntry.SpawnDelay or 1))
				end
			end
		end

		self.AllMobsSpawned = true

		if self.ActiveMobCount == 0 and self.BaseHealth > 0 then
			self.Services.WaveService.Signals.Ended:Fire()
		end
	end)
end

--[=[
	What the current wave spawns `entityName` with: `MaxHealth` (weather included),
	`BaseSpeed` (without weather), and `HealthScale`. Nil if the wave does not have
	that entity; if it has it in more than one entry, the last one wins.

	For enemies born outside the spawn loop, such as the Deathspeaker's converts
	(`SuffocateAbilityService`), which should match the wave they walk into.
]=]
function MobService:GetWaveStats(entityName : string)
	return self.WaveStats[entityName]
end

function MobService:getMobPosition(mobId)
	local cached = self.PositionCache[mobId]
	if cached and cached.frame == self.FrameId then
		return cached.pos
	end
	local pos = self:PredictPosition(mobId)
	self.PositionCache[mobId] = { frame = self.FrameId, pos = pos }
	return pos
end

--[=[
	The enemy the unit picks within range, by the criterion its owner left on the card's
	`Priority` button. The comparison lives in `TargetPriority`, shared with the client;
	see the module.

	Progress is `mob.Distance`, the exact distance walked along its route. The client
	rebuilds the same number in `MobController:GetPathDistance`.
]=]
function MobService:GetBestMobInRange(position : Vector3, range : number, priority : string?)
	local bestId = nil
	local best = nil

	for mobId, mob in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if not pos then continue end

		local dist = (pos - position).Magnitude
		if dist > range then continue end

		local candidate = {
			distance = dist,
			health = mob.Health or 0,
			progress = mob.Distance or 0,
		}

		if TargetPriority.IsBetter(priority, candidate, best) then
			best = candidate
			bestId = mobId
		end
	end

	return bestId
end

-- With no priority at all: the nearest. Callers that only want "who is there" (the
-- mine asking who stepped on it) still call through here.
function MobService:GetNearestMobInRange(position : Vector3, range : number)
	return self:GetBestMobInRange(position, range, TargetPriority.Nearest)
end

--[=[
	The bolt's chain: the aimed target and the neighbors it jumps through.

	It starts at `startMobId` and, at each step, jumps to the enemy **nearest to the last
	one touched** that is not in the chain yet and is at most `radius` from it. It stops
	when the chain reaches `maxTargets` or when nobody is left within the last jump's reach.

	**The radius is measured from the last enemy, not the unit**: that is what separates
	this from `GetMobsInRadius`. The chain moves along the path's queue and reaches well
	past the range of whoever fired it, while an area of the same size would only catch
	those bunched around the target.

	It comes out in the order the bolt passes, which is the order the client draws (an arc
	from each to the next) and the one a per-jump damage falloff would use, if one ever
	exists; today's unit has none.

	The aimed target always comes in the chain, even alone: the caller already decided it
	takes the hit, and an empty chain would mean a lost hit.
]=]
function MobService:GetChainTargets(startMobId : string, maxTargets : number?, radius : number?) : { string }
	local chain = { startMobId }

	local limit = math.max(1, math.floor(maxTargets or 1))
	local reach = math.max(0, radius or 0)
	if limit <= 1 or reach <= 0 then
		return chain
	end

	local current = self:getMobPosition(startMobId)
	if not current then
		return chain
	end

	local visited = { [startMobId] = true }

	while #chain < limit do
		local nextId, nextPos, nextDistance = nil, nil, nil

		for mobId in self.ActiveMobs do
			if visited[mobId] then continue end

			local pos = self:getMobPosition(mobId)
			if not pos then continue end

			local distance = (pos - current).Magnitude
			if distance > reach then continue end

			if not nextDistance or distance < nextDistance then
				nextId, nextPos, nextDistance = mobId, pos, distance
			end
		end

		-- The last in the chain is alone: the bolt dies there, even with jumps left.
		if not nextId then break end

		visited[nextId] = true
		current = nextPos
		table.insert(chain, nextId)
	end

	return chain
end

function MobService:GetMobsInRadius(position, radius)
	local result = {}
	for mobId, _ in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if pos and (pos - position).Magnitude <= radius then
			table.insert(result, mobId)
		end
	end
	return result
end

--[=[
	Who is on the line from `origin` through `through`, up to `length` studs away and at
	most `width` studs from the line.

	It is the piercing projectile's math: it does not stop at the target, so whoever comes
	**behind** it on the same line takes damage too. The line does not stop at the target
	either: it goes to the unit's range, which decides who is still close enough to be hit.

	**The math is on the plane, ignoring Y.** The unit stands on a platform and the enemy
	walks on the ground, so the line between them slopes down; measuring in 3D, an enemy
	on the path would be "far from the line" just for being lower than the tower, and the
	arrow would pass through it without taking health.

	It comes out sorted by distance along the line: the order the arrow passes them, the
	order the client draws, and the one a decreasing per-enemy damage would use, if one
	ever exists.
]=]
function MobService:GetMobsAlongLine(origin : Vector3, through : Vector3, length : number, width : number)
	local flat = Vector3.new(1, 0, 1)

	local heading = (through - origin) * flat
	if heading.Magnitude < 1e-4 then
		return {}
	end

	local direction = heading.Unit
	local found = {}

	for mobId, _ in self.ActiveMobs do
		local pos = self:getMobPosition(mobId)
		if not pos then continue end

		local offset = (pos - origin) * flat
		local along = offset:Dot(direction)

		-- Behind the unit, or past its range.
		if along < 0 or along > length then continue end

		if (offset - direction * along).Magnitude <= width then
			table.insert(found, { id = mobId, along = along })
		end
	end

	table.sort(found, function(a, b)
		return a.along < b.along
	end)

	local result = {}
	for _, entry in ipairs(found) do
		table.insert(result, entry.id)
	end

	return result
end

-- The match damage scoreboard. It keeps the name because the MVP is reported at the
-- end of the round, when the player may have already left the server.
function MobService:addDamageStat(userId, damage)
	if not userId or not damage or damage <= 0 then return end

	local entry = self.SessionDamage[userId]
	if not entry then
		local player = Players:GetPlayerByUserId(userId)
		entry = { damage = 0, name = player and player.DisplayName or "?" }
		self.SessionDamage[userId] = entry
	end

	entry.damage += damage
end

--[=[
	How much damage a player has dealt this match. Zero for those who have hit nothing
	yet, and for everyone after the round restarts: the scoreboard is cleared with the
	match.
]=]
function MobService:GetDamageDealt(userId : number?) : number
	local entry = userId and self.SessionDamage[userId]

	return entry and entry.damage or 0
end

function MobService:GetMVP()
	local best = nil
	local bestDamage = 0

	for userId, entry in self.SessionDamage do
		if entry.damage > bestDamage then
			bestDamage = entry.damage
			best = {
				userId = userId,
				name = entry.name,
				damage = math.floor(entry.damage + 0.5),
			}
		end
	end

	return best
end

--[=[
	Pays the damage that landed, discounting the wave's health inflation.

	Enemy health grows by difficulty and by wave, and without the discount income would
	grow with it: on Impossible, wave 27 has enemies 24x beefier than wave 1, so hitting
	them would pay 24x more for the same work, and damage would become the whole economy
	again. Dividing by the enemy's own `HealthScale` (its health over the entity's
	reference health, set at spawn), a point of damage is worth the same on any wave and
	any preset.
]=]
--[=[
	Adds the Entrepreneur aura's bonus to a reward, without losing the fractional part.

	Rewards are integers and almost all small: 15% of a kill worth 3 is 0.45, and 15% of
	the damage reward's floor of 1 is 0.15: rounded on the spot, both would vanish, and the
	aura would seem to do nothing exactly where it shows most.

	So the remainder is stored per player and becomes cash as soon as it passes 1. A small
	bonus pays slowly instead of never, and over a wave the total comes out equal to the
	full percentage.

	`bonus` is a fraction: 0.15 is "+15%". With no bonus, the reward comes back untouched.
]=]
function MobService:applyCashBonus(player, amount : number, bonus : number?, scale : number?) : number
	--[[
		The card scale applies **before** the aura bonus, not added to it: the aura is a
		fraction that stacks between farms (15% + 15% = 30%), and the Robux Royalty ring is
		a multiplier on the reward. Adding the two would turn "1.1x" into "+10 percentage
		points", which is another number.

		The scale's fractional remainder goes into the same bucket as the aura, which is why
		it is applied in here instead of on the already rounded reward: 1.1 of a reward of 1
		is 1.1, and rounding outside would throw the 10% away on every small hit, which is
		almost all of them.
	]]
	scale = scale or 1

	if amount <= 0 or (scale == 1 and (not bonus or bonus <= 0)) then
		return amount
	end

	local scaled = amount * scale
	local carried = (self.BonusRemainder[player.UserId] or 0) + scaled + (scaled * (bonus or 0))
	local whole = math.floor(carried)

	self.BonusRemainder[player.UserId] = carried - whole

	return whole
end

function MobService:awardDamageReward(killerUserId, damage, bonus : number?, cashScale : number?, healthScale : number?)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end

	local scale = healthScale
	if not scale or scale <= 0 then scale = 1 end

	local reward = math.max(1, math.floor((damage * ServerConfig.Data.CASH_PER_DAMAGE) / scale))
	self:addCash(player, self:applyCashBonus(player, reward, bonus, cashScale))
end

function MobService:awardKillReward(killerUserId, reward, bonus : number?, cashScale : number?)
	if not killerUserId then return end
	local player = Players:GetPlayerByUserId(killerUserId)
	if not player then return end
	local amount = reward or math.random(ServerConfig.Data.CASH_PER_KILL_MIN, ServerConfig.Data.CASH_PER_KILL_MAX)
	self:addCash(player, self:applyCashBonus(player, amount, bonus, cashScale))
end

--[=[
	Returns the damage that actually landed, so the caller can credit the unit (the
	upgrade card shows the per-unit total in `DmgDone`).
]=]
--[=[
	`cashBonus` is the Entrepreneur aura on the hitting unit: a fraction `UnitService`
	freezes at the start of the attack, along with damage and range. It applies to both
	rewards, damage and kill.
]=]
function MobService:DamageMob(mobId, damage, killerUserId, cashBonus : number?, cashScale : number?, damageClasses)
	local mob = self.ActiveMobs[mobId]
	if not mob then return 0 end

	--[[
		The Staff of Azure Ever Ice's "brittle" when used during snow: all damage entering
		an enemy is worth more while it lasts.

		It is here, on the game's single damage path, not on each unit: it is not a tower
		buff; the enemy is more fragile, and a tripmine shot or an area splash counts the
		same.

		The bleed's open wound (`ApplyBleed`) enters here for the same reason, but per enemy
		instead of per room: while `BleedingUntil` runs, everything hitting that target is
		worth `BleedVulnerability` times more, including the bleed's own ticks, which go
		through here like any other damage.
	]]
	local vulnerability = 1
	if GameClock.Now() < (mob.BleedingUntil or 0) then
		vulnerability = mob.BleedVulnerability or 1
	end

	--[[
		The enemy's resistance to the attacker's class and the elemental matchup
		(`ResistanceConfig`). 1 for untyped damage, enemies with no Resist/Element, and
		units with no Class. 0 means immune: no damage, no cash, no kill credit, and
		`creditDamage` skips the burn/slow/stun the hit would have left.
	]]
	local elementMultiplier = SharedConfig.ResistanceConfig.GetMultiplier(mob.Name, damageClasses)
	if elementMultiplier <= 0 then
		return 0
	end

	local base = damage or 10
	local incoming = base * (self.BrittleMultiplier or 1) * vulnerability * elementMultiplier
	if incoming ~= base then
		incoming = math.max(1, math.floor(incoming + 0.5))
	end

	-- Counts the damage that actually landed: a 70-damage hit on an enemy with 5 health is worth 5.
	-- It applies to both the MVP and cash: paying the hit's full value would reward
	-- overkill and turn damage into the match's whole economy.
	local effectiveDamage = math.min(mob.Health, incoming)
	self:addDamageStat(killerUserId, effectiveDamage)

	mob.Health -= incoming
	self:awardDamageReward(killerUserId, effectiveDamage, cashBonus, cashScale, mob.HealthScale)

	self:processDamageGimmicks(mobId, mob)

	if mob.Health <= 0 then
		self:awardKillReward(killerUserId, mob.Reward, cashBonus, cashScale)

		local stats = self:_sessionStatsOf(killerUserId)
		if stats then
			stats.Kills += 1

			if WaveConfig.IsBoss(mob.Name) then
				stats.BossKills += 1
			end
		end

		self:removeMob(mobId)
	end

	return effectiveDamage
end

function MobService:construct()
	Framework:Listen("UpdateCash", function() end)
	Framework:Listen("RequestCash", function(player)
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		else
			Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
		end
	end)
	Framework:Listen("SpawnClientMob", function() end)
	Framework:Listen("UpdateMobSpeed", function() end)
	Framework:Listen("MobFrozen", function() end)
	Framework:Listen("MobBurning", function() end)
	Framework:Listen("MobBleeding", function() end)
	Framework:Listen("MobAuraSlowed", function() end)
	Framework:Listen("MobDamageTick", function() end)
	Framework:Listen("MobTeleported", function() end)
	Framework:Listen("KillClientMob", function() end)
	Framework:Listen("HitClientMob", function() end)
	Framework:Listen("AttackVisual", function() end)
	Framework:Listen("MobPlayAttack", function() end)
	Framework:Listen("MobPlayAnim", function() end)
	Framework:Listen("UpdateBaseHealth", function() end)

	--[=[
		The current value, for a client that just found the base billboard on the map.

		`UpdateBaseHealth` only goes out when health changes, and the map reaches the client
		long before the first leak: without this request the number would stay at the text
		authored in the GUI until an enemy got through. Same reason as `RequestCash`.
	]=]
	Framework:Listen("RequestBaseHealth", function(player)
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
	end)
	Framework:Listen("GameOver", function() end)
	Framework:Listen("ReplicateUnit", function() end)
	Framework:Listen("Bridge", function() end)
	Framework:Listen("ClientReady", function(player)
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		else
			Framework:Fire("UpdateCash", player, self.SessionCash[player.UserId])
		end
		Framework:Fire("UpdateBaseHealth", player, self.BaseHealth, self.MaxBaseHealth)
		for mobId, mobData in self.ActiveMobs do
			Framework:Fire("SpawnClientMob", player, {
				Id = mobId,
				Name = mobData.Name,
				Speed = mobData.CurrentSpeed,
				MaxHealth = mobData.MaxHealth,
				Health = mobData.Health,
				Route = mobData.RouteIndex,
			})
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		self.FrameId += 1

		--[[
			The frame in match time. Sped up, the enemy walks more per real second without
			anyone touching its speed: it is the same `CurrentSpeed`, just multiplied by a
			larger `dt`. The client does the same math in `MobController`, with the scale
			`SpeedService` sent.
		]]
		dt = GameClock.Scaled(dt)

		local now = GameClock.Now()

		--[[
			Weather is checked here instead of being pushed by whoever turns it on.

			It is two table reads per frame, and in exchange enemy speed follows any weather
			change: the round's and the `weather` command's, which does not go through
			`WeatherRoundService`. An explicit push would only cover the first, and testing
			wind by hand would give a different match from the real one.
		]]
		local weatherService = self.Services.WeatherService
		local currentWeather = weatherService and weatherService:GetCurrent() or nil
		if currentWeather ~= self.Weather then
			self:ApplyWeather(currentWeather)
		end

		for mobId, mob in self.ActiveMobs do
			--[[
				Where it came from this frame. It is what lets the tripmine trigger test the
				**stretch walked** instead of the standing position: sped up, one frame's step
				exceeds the trigger's diameter and the enemy would cross the mine unharmed. See
				`GetMobCrossing`.

				Written even with the enemy stopped (frozen or stunned): then the segment is a
				point, which is the right answer for something that did not move.
			]]
			mob.LastDistance = mob.Distance

			if now >= mob.StunnedUntil then
				mob.Distance += mob.CurrentSpeed * dt
				self:processTurnGimmicks(mobId, mob)
			end

			-- Length per enemy: with a fork, the two sides need not have
			-- the same length.
			if mob.Distance >= mob.PathLength then
				self:mobEscaped(mobId)
				if self.BaseHealth <= 0 then break end
			end
		end
	end)

	if self.CanDebug then
		RunService.Heartbeat:Connect(function()
			for mobId, _ in self.ActiveMobs do
				local pos = self:PredictPosition(mobId)
				if not pos then continue end

				local part = self.DebugParts[mobId]
				if not part then
					part = Instance.new("Part")
					part.Size = Vector3.new(2, 2, 2)
					part.Color = Color3.new(1, 0, 0)
					part.Anchored = true
					part.CanCollide = false
					part.Transparency = 0.5
					part.Parent = workspace
					self.DebugParts[mobId] = part
				end
				part.Position = pos
			end

			for mobId, part in self.DebugParts do
				if not self.ActiveMobs[mobId] then
					part:Destroy()
					self.DebugParts[mobId] = nil
				end
			end
		end)
	end

end

function MobService:start()
	for ServiceName, _ in self.Services do
		self.Services[ServiceName] = Framework:Get(ServiceName)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if not self.SessionCash[player.UserId] then
			self:initPlayerCash(player)
		end
	end

	Players.PlayerAdded:Connect(function(player)
		self:initPlayerCash(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.SessionCash[player.UserId] = nil
		self.BonusRemainder[player.UserId] = nil
	end)

	self:construct()
end

function MobService:init()
end

return MobService
