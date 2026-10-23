local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local Settings = require(ServerScriptService:WaitForChild("Config"):WaitForChild("SuffocateAbility"))
local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local function fireAll(event : string, ...)
	for _, player in Players:GetPlayers() do
		Framework:Fire(event, player, ...)
	end
end

local SuffocateAbilityService = {
	Services = {
		MobService = {},
		UnitService = {},
	},
	Triggered = setmetatable({}, { __mode = "k" }),
	Suffocations = {},

	--[[
		The enemies born from a unit, and whose card they hold. When one leaves the
		match (killed or escaped), the card goes back to its owner's hand.
	]]
	Converts = {},
}

function SuffocateAbilityService:appliesTo(mob) : boolean
	return table.find(Settings.Enemies, mob.Name) ~= nil
end

function SuffocateAbilityService:pickVictim()
	local pool = {}
	for _, entry in self.Services.UnitService.PlacedUnits do
		if not entry.Suffocating and not table.find(Settings.ExceptUnits or {}, entry.unitName) then
			table.insert(pool, entry)
		end
	end
	if #pool == 0 then
		return nil
	end
	return pool[math.random(1, #pool)]
end

function SuffocateAbilityService:beginSuffocation(mobId : string, mob, entry)
	local duration = math.max(0.1, Settings.Duration or 4)
	local endsAt = GameClock.Now() + duration
	local previousStun = entry.StunnedUntil or 0
	local fadeTime = math.clamp(Settings.FadeTime or 0, 0, duration)

	entry.Suffocating = true
	entry.StunnedUntil = math.max(previousStun, endsAt)

	table.insert(self.Suffocations, {
		MobId = mobId,
		Mob = mob,
		Entry = entry,
		EndsAt = endsAt,
		FadeTime = fadeTime,
		FadeAt = endsAt - fadeTime,
		Fading = false,
		PreviousStun = previousStun,
		AppliedStun = entry.StunnedUntil,
	})

	fireAll("UnitSuffocate", entry.unitId, duration, Settings.UnitAnim or "Suffocated", Settings.UnitVFX or "")
end

function SuffocateAbilityService:playCast(mobId : string, mob)
	local mobService = self.Services.MobService
	local castTime = math.max(0, Settings.CastTime or 0)
	local stopping = castTime > 0 and Settings.StopWhileCasting ~= false

	if stopping then
		mob.StunnedUntil = math.max(mob.StunnedUntil or 0, GameClock.Now() + castTime)
		fireAll("UpdateMobSpeed", mobId, 0)
	end

	if Settings.EnemyAnim then
		fireAll("MobPlayAnim", mobId, Settings.EnemyAnim)
	end

	-- The cast effect on the mage. Its length is `CastVFXTime` when set, otherwise
	-- `CastTime`; the mage's pause above always uses `CastTime`.
	local vfxTime = math.max(0, Settings.CastVFXTime or castTime)
	if Settings.CastVFX and vfxTime > 0 then
		fireAll("SuffocateCastVFX", mobId, Settings.CastVFX, Settings.CastPart or "Right Arm", vfxTime)
	end

	if stopping then
		GameClock.Delay(castTime, function()
			if mobService.ActiveMobs[mobId] ~= mob then
				return
			end
			if (mob.StunnedUntil or 0) <= GameClock.Now() then
				fireAll("UpdateMobSpeed", mobId, mob.CurrentSpeed)
			end
		end)
	end
end

function SuffocateAbilityService:trigger(mobId : string, mob) : boolean
	local entry = self:pickVictim()
	if not entry then
		return false
	end

	self.Triggered[mob] = true
	self:beginSuffocation(mobId, mob, entry)
	self:playCast(mobId, mob)
	return true
end

function SuffocateAbilityService:Trigger(mobId : string) : boolean
	local mob = self.Services.MobService.ActiveMobs[mobId]
	if not mob or self.Triggered[mob] then
		return false
	end
	return self:trigger(mobId, mob)
end

function SuffocateAbilityService:removeUnit(entry)
	local unitService = self.Services.UnitService

	for index, placed in ipairs(unitService.PlacedUnits) do
		if placed == entry then
			table.remove(unitService.PlacedUnits, index)
			break
		end
	end

	unitService.UnitsById[entry.unitId] = nil
	fireAll("RemoveUnit", entry.unitId)
end

-- Places the convert on the route point nearest the suffocated unit. Returns its id
-- and record, or nil if nothing spawned.
function SuffocateAbilityService:spawnConverted(position : Vector3, sourceMob)
	local mobService = self.Services.MobService
	local spawn = Settings.Spawn

	local routes = mobService:getRoutes()
	local routeIndex, startDistance, bestSquared = 1, 0, math.huge
	for index, route in ipairs(routes) do
		local smooth = route.smooth
		for pointIndex, point in smooth.points do
			local dx = point.X - position.X
			local dz = point.Z - position.Z
			local squared = dx * dx + dz * dz
			if squared < bestSquared then
				bestSquared = squared
				routeIndex = index
				startDistance = smooth.cumulative[pointIndex] or 0
			end
		end
	end

	return mobService:SpawnOnPath(spawn.Entity, routeIndex, startDistance, sourceMob, spawn.Reward)
end

--[[
	Remembers which card a convert holds. Loans are left out: they never took a card
	from the hand, and selling one does not return a card either.
]]
function SuffocateAbilityService:trackConvert(mobId : string?, mob, entry)
	if not mobId or entry.loanUntilWave then
		return
	end

	table.insert(self.Converts, {
		MobId = mobId,
		Mob = mob,
		OwnerUserId = entry.ownerUserId,
		UnitName = entry.unitName,
	})
end

-- Returns the card of every convert that left the match since the last frame.
function SuffocateAbilityService:stepConverts()
	local activeMobs = self.Services.MobService.ActiveMobs

	for index = #self.Converts, 1, -1 do
		local convert = self.Converts[index]
		if activeMobs[convert.MobId] ~= convert.Mob then
			table.remove(self.Converts, index)

			-- An owner who left the server has no hand to return to.
			local owner = Players:GetPlayerByUserId(convert.OwnerUserId)
			if owner then
				self.Services.UnitService:incrementCardCount(owner, convert.UnitName)
			end
		end
	end
end

function SuffocateAbilityService:stepSuffocations()
	local mobService = self.Services.MobService
	local unitService = self.Services.UnitService
	local now = GameClock.Now()

	for index = #self.Suffocations, 1, -1 do
		local record = self.Suffocations[index]
		local entry = record.Entry

		if unitService.UnitsById[entry.unitId] ~= entry then
			table.remove(self.Suffocations, index)
		elseif mobService.ActiveMobs[record.MobId] ~= record.Mob then
			table.remove(self.Suffocations, index)
			entry.Suffocating = nil

			if (entry.StunnedUntil or 0) <= record.AppliedStun then
				entry.StunnedUntil = record.PreviousStun
			end

			fireAll("UnitSuffocateEnd", entry.unitId)
		elseif now >= record.EndsAt then
			table.remove(self.Suffocations, index)

			local position = entry.cf.Position
			self:removeUnit(entry)
			local convertId, convert = self:spawnConverted(position, record.Mob)
			self:trackConvert(convertId, convert, entry)
		else
			if record.FadeTime > 0 and not record.Fading and now >= record.FadeAt then
				record.Fading = true
				fireAll("UnitSuffocateFade", entry.unitId, record.EndsAt - now)
			end

			if (entry.StunnedUntil or 0) < record.EndsAt then
				entry.StunnedUntil = record.EndsAt
			end
		end
	end
end

function SuffocateAbilityService:step()
	local mobService = self.Services.MobService
	local unitService = self.Services.UnitService
	if not mobService or not unitService or not mobService.ActiveMobs or not unitService.PlacedUnits then
		return
	end

	local threshold = Settings.Threshold or 0.7
	for mobId, mob in mobService.ActiveMobs do
		if not self.Triggered[mob]
			and mob.Health > 0
			and mob.Health <= mob.MaxHealth * threshold
			and self:appliesTo(mob)
		then
			self:trigger(mobId, mob)
		end
	end

	self:stepSuffocations()
	self:stepConverts()
end

--[[
	Called by WaveService in `ResetRound()`. The round's enemies are already gone and
	UnitService reloads every hand from the deck, so nothing is owed: returning the
	converts' cards here would only add to a hand that is already full.
]]
function SuffocateAbilityService:ResetRound()
	table.clear(self.Suffocations)
	table.clear(self.Converts)
end

function SuffocateAbilityService:guardDamage()
	local unitService = self.Services.UnitService
	if not unitService or not unitService.creditDamage or unitService.SuffocateGuarded then
		return
	end

	local original = unitService.creditDamage
	unitService.creditDamage = function(service, entry, ...)
		if entry and entry.Suffocating then
			return 0
		end
		return original(service, entry, ...)
	end
	unitService.SuffocateGuarded = true
end

function SuffocateAbilityService:start()
	for name in self.Services do
		self.Services[name] = Framework:Get(name)
	end

	self:guardDamage()
	
	Framework:Listen("SuffocateCastVFX", function() end)
	Framework:Listen("UnitSuffocate", function() end)
	Framework:Listen("UnitSuffocateEnd", function() end)
	Framework:Listen("UnitSuffocateFade", function() end)

	RunService.Heartbeat:Connect(function()
		self:step()
	end)
end

function SuffocateAbilityService:init()
end

return SuffocateAbilityService