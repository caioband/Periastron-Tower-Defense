local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local DEFAULT_STACK_PER_MODE = 4
local STAT_ORDER = { "Damage", "Range", "AttackSpeed" }

local function fireAll(event : string, ...)
	for _, player in Players:GetPlayers() do
		Framework:Fire(event, player, ...)
	end
end

local function supportOf(unitName : string?)
	local stats = unitName and SharedConfig.UnitStats[unitName]
	return stats and stats.Support
end

local function canReceiveBuff(unitName : string) : boolean
	local stats = SharedConfig.UnitStats[unitName]
	if not stats then return false end
	if stats.Support or stats.Farm or stats.SlowAura then return false end
	return true
end

local BardService = {
	Services = {
		UnitService = {},
	},
	Active = {},
	Totals = {},
	Icons = {},
	Counts = {},
	Aggregate = {},
}

function BardService:GetMode(entry) : string?
	local support = supportOf(entry.unitName)
	if not support then return nil end

	local mode = entry.BardMode
	if mode and support.Modes[mode] then
		return mode
	end

	return support.Default
end

function BardService:GetCooldownLeft(entry, now : number?) : number
	return math.max(0, (entry.BardReadyAt or 0) - (now or GameClock.Now()))
end

function BardService:broadcast(entry, onlyPlayer : Player?)
	local mode = self:GetMode(entry)
	if not mode then return end

	local left = self:GetCooldownLeft(entry)

	if onlyPlayer then
		Framework:Fire("BardModeChanged", onlyPlayer, entry.unitId, mode, left)
		return
	end

	fireAll("BardModeChanged", entry.unitId, mode, left)
end

function BardService:SetMode(player : Player, unitId : any, mode : any)
	if typeof(unitId) ~= "string" or typeof(mode) ~= "string" then return end

	local unitService = self.Services.UnitService
	local entry = unitService and unitService.UnitsById[unitId]
	if not entry or entry.ownerUserId ~= player.UserId then return end

	local support = supportOf(entry.unitName)
	if not support or not support.Modes[mode] then return end

	local now = GameClock.Now()
	if now < (entry.BardReadyAt or 0) then return end
	if self:GetMode(entry) == mode then return end

	entry.BardMode = mode
	entry.BardReadyAt = now + (support.SwapCooldown or 10)

	self:broadcast(entry)
end

function BardService:buffPayload(entry)
	local sent = entry.BardSent
	if not sent or #sent == 0 then
		return false
	end

	local payload = {}

	for index, buff in sent do
		payload[index] = {
			Stat = buff.Stat,
			Boost = buff.Boost,
			Icon = buff.Icon,
			Count = buff.Count,
			Capped = buff.Capped,
		}
	end

	return payload
end

function BardService:aggregateChanged(entry, aggregate, count : number) : boolean
	local sent = entry.BardSent
	local sentCount = sent and #sent or 0

	if sentCount ~= count then
		return true
	end

	for index = 1, count do
		local was = sent[index]
		local now = aggregate[index]

		if was.Stat ~= now.Stat
			or was.Boost ~= now.Boost
			or was.Icon ~= now.Icon
			or was.Count ~= now.Count
			or was.Capped ~= now.Capped
		then
			return true
		end
	end

	return false
end

function BardService:Step(now : number, weather : string?)
	local unitService = self.Services.UnitService
	local units = unitService and unitService.PlacedUnits
	if not units then return end

	local active = self.Active
	local activeCount = 0

	for _, entry in ipairs(units) do
		local support = supportOf(entry.unitName)
		if not support then continue end

		entry.BardMult = nil

		if SharedConfig.WeatherConfig.IsDisabled(weather, entry.unitName) then continue end
		if now < (entry.StunnedUntil or 0) then continue end

		local mode = self:GetMode(entry)
		local modeConfig = mode and support.Modes[mode]
		if not modeConfig then continue end

		local boost = SharedConfig.UnitUpgradeConfig:GetSupportBoost(entry.unitName, entry.upgrades or 0, mode)
		if boost <= 0 then continue end

		local radius = unitService:getRange(entry, weather)
		local position = entry.cf.Position

		activeCount += 1
		local slot = active[activeCount]
		if not slot then
			slot = {}
			active[activeCount] = slot
		end

		slot.Stat = modeConfig.Stat
		slot.Icon = modeConfig.Icon
		slot.Boost = boost
		slot.StackPerMode = math.max(1, support.StackPerMode or DEFAULT_STACK_PER_MODE)
		slot.X = position.X
		slot.Z = position.Z
		slot.RadiusSquared = radius * radius
	end

	local totals = self.Totals
	local icons = self.Icons
	local counts = self.Counts
	local aggregate = self.Aggregate
	local changes = nil

	for _, entry in ipairs(units) do
		if supportOf(entry.unitName) then continue end

		local aggregateCount = 0

		if activeCount > 0 and canReceiveBuff(entry.unitName) then
			local at = entry.cf.Position
			local any = false

			for _, stat in STAT_ORDER do
				totals[stat] = 0
				icons[stat] = nil
				counts[stat] = 0
			end

			for index = 1, activeCount do
				local slot = active[index]
				local stat = slot.Stat

				if (counts[stat] or 0) >= slot.StackPerMode then continue end

				local dx, dz = at.X - slot.X, at.Z - slot.Z

				if dx * dx + dz * dz <= slot.RadiusSquared then
					any = true
					totals[stat] = (totals[stat] or 0) + slot.Boost
					icons[stat] = icons[stat] or slot.Icon
					counts[stat] = (counts[stat] or 0) + 1
				end
			end

			if any then
				local mult = entry.BardMultCache
				if not mult then
					mult = {}
					entry.BardMultCache = mult
				end

				for _, stat in STAT_ORDER do
					local total = totals[stat] or 0

					mult[stat] = 1 + total

					if total > 0 then
						aggregateCount += 1

						local item = aggregate[aggregateCount]
						if not item then
							item = {}
							aggregate[aggregateCount] = item
						end

						local support = SharedConfig.UnitStats.Bard and SharedConfig.UnitStats.Bard.Support
						local limit = (support and support.StackPerMode) or DEFAULT_STACK_PER_MODE

						item.Stat = stat
						item.Boost = total
						item.Icon = icons[stat]
						item.Count = counts[stat] or 0
						item.Capped = (counts[stat] or 0) >= limit
					end
				end

				entry.BardMult = mult
			else
				entry.BardMult = nil
			end
		else
			entry.BardMult = nil
		end

		if self:aggregateChanged(entry, aggregate, aggregateCount) then
			local sent = {}

			for index = 1, aggregateCount do
				local item = aggregate[index]
				sent[index] = {
					Stat = item.Stat,
					Boost = item.Boost,
					Icon = item.Icon,
					Count = item.Count,
					Capped = item.Capped,
				}
			end

			entry.BardSent = if aggregateCount > 0 then sent else nil

			changes = changes or {}
			changes[entry.unitId] = self:buffPayload(entry)
		end
	end

	if changes then
		fireAll("BardBuffs", changes)
	end
end

function BardService:start()
	for name in self.Services do
		self.Services[name] = Framework:Get(name)
	end

	Framework:Listen("BardModeChanged", function() end)
	Framework:Listen("BardBuffs", function() end)

	Framework:Listen("SetBardMode", function(player, unitId, mode)
		self:SetMode(player, unitId, mode)
	end)

	Framework:Listen("ClientReady", function(player)
		local unitService = self.Services.UnitService
		if not unitService then return end

		local snapshot = nil

		for _, entry in ipairs(unitService.PlacedUnits) do
			if supportOf(entry.unitName) then
				self:broadcast(entry, player)
			elseif entry.BardSent then
				snapshot = snapshot or {}
				snapshot[entry.unitId] = self:buffPayload(entry)
			end
		end

		if snapshot then
			Framework:Fire("BardBuffs", player, snapshot)
		end
	end)
end

function BardService:init()
end

return BardService