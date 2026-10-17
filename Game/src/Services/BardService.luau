local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Config = Shared:WaitForChild("Config")

local SharedConfig = require(Config.SharedConfig)
local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local DEFAULT_STACK_LIMIT = 2

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
	Sources = {},
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
		payload[index] = { Stat = buff.Stat, Boost = buff.Boost, Icon = buff.Icon }
	end

	return payload
end

function BardService:sourcesChanged(entry, sources, count : number) : boolean
	local sent = entry.BardSent
	local sentCount = sent and #sent or 0

	if sentCount ~= count then
		return true
	end

	for index = 1, count do
		local was = sent[index]
		local now = sources[index]

		if was.Stat ~= now.Stat or was.Boost ~= now.Boost or was.Icon ~= now.Icon then
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
		slot.StackLimit = math.max(1, support.StackLimit or DEFAULT_STACK_LIMIT)
		slot.X = position.X
		slot.Z = position.Z
		slot.RadiusSquared = radius * radius
	end

	local sources = self.Sources
	local changes = nil

	for _, entry in ipairs(units) do
		if supportOf(entry.unitName) then continue end

		local count = 0

		if activeCount > 0 and canReceiveBuff(entry.unitName) then
			local at = entry.cf.Position
			local limit = DEFAULT_STACK_LIMIT

			for index = 1, activeCount do
				local slot = active[index]
				local dx, dz = at.X - slot.X, at.Z - slot.Z

				if dx * dx + dz * dz <= slot.RadiusSquared then
					count += 1
					sources[count] = slot

					if count == 1 then
						limit = slot.StackLimit
					end

					if count >= limit then
						break
					end
				end
			end
		end

		if count > 0 then
			local mult = entry.BardMultCache
			if not mult then
				mult = {}
				entry.BardMultCache = mult
			end

			mult.Damage = 1
			mult.AttackSpeed = 1
			mult.Range = 1

			for index = 1, count do
				local slot = sources[index]
				mult[slot.Stat] = (mult[slot.Stat] or 1) + slot.Boost
			end

			entry.BardMult = mult
		else
			entry.BardMult = nil
		end

		if self:sourcesChanged(entry, sources, count) then
			local sent = {}

			for index = 1, count do
				local slot = sources[index]
				sent[index] = { Stat = slot.Stat, Boost = slot.Boost, Icon = slot.Icon }
			end

			entry.BardSent = if count > 0 then sent else nil

			changes = changes or {}
			changes[entry.unitId] = self:buffPayload(entry)
		end
	end

	table.clear(sources)

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

return BardService --s