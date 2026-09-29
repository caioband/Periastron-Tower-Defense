local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local Settings = require(ServerScriptService:WaitForChild("Config"):WaitForChild("EnemyWeatherChange"))
local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("EnemyWeatherChangeService")

local WeatherConfig = SharedConfig.WeatherConfig

local POLL_INTERVAL = 0.1

local function fireAll(event : string, ...)
	for _, player in Players:GetPlayers() do
		Framework:Fire(event, player, ...)
	end
end

local EnemyWeatherChangeService = {
	Services = {
		MobService = {},
		WeatherService = {},
		WeatherRoundService = {},
	},

	Records = {},
	Tracked = setmetatable({}, { __mode = "k" }),
	EnemySet = {},

	Caster = nil,
	Override = nil,
	Underlying = nil,
}

function EnemyWeatherChangeService:isAlive(record) : boolean
	return self.Services.MobService.ActiveMobs[record.MobId] == record.Mob
end

function EnemyWeatherChangeService:getTransition() : number
	return Settings.TransitionTime or WeatherConfig.Round.TransitionTime
end

-- While the mage's weather is up, Apply/Clear from the round are held in Underlying.
function EnemyWeatherChangeService:installGuard()
	local weatherService = self.Services.WeatherService
	if not weatherService or weatherService.EnemyWeatherGuarded then return end

	local this = self
	local originalApply = weatherService.Apply
	local originalClear = weatherService.Clear

	self.RealApply = function(name : string, transitionTime : number?)
		return originalApply(weatherService, name, transitionTime)
	end

	self.RealClear = function(transitionTime : number?)
		return originalClear(weatherService, transitionTime)
	end

	weatherService.Apply = function(service, name : string, transitionTime : number?)
		if not this.Override or not service:GetWeather(name) then
			return originalApply(service, name, transitionTime)
		end

		this.Underlying = name
		return true, string.format("Weather: %s is waiting behind the enemy's weather.", name)
	end

	weatherService.Clear = function(service, transitionTime : number?)
		if not this.Override then
			return originalClear(service, transitionTime)
		end

		this.Underlying = nil
		return true, "the enemy's weather stays; the sky underneath is now clear."
	end

	weatherService.EnemyWeatherGuarded = true
end

function EnemyWeatherChangeService:candidates(current : string?) : { string }
	local weatherService = self.Services.WeatherService
	local roundService = self.Services.WeatherRoundService
	local excluded = Settings.Exclude or {}
	local names, seen = {}, {}

	local function add(list)
		for _, name in list do
			if name ~= current
				and not seen[name]
				and not table.find(excluded, name)
				and weatherService:GetWeather(name)
			then
				seen[name] = true
				table.insert(names, name)
			end
		end
	end

	if Settings.Pool == "Map" then
		add(WeatherConfig.GetPool(roundService and roundService:GetMapName()))
	end

	if #names == 0 and (Settings.Pool == "All" or Settings.FallbackToAll) then
		add(weatherService:GetNames())
	end

	return names
end

function EnemyWeatherChangeService:changeWeather() : boolean
	local current = self.Services.WeatherService:GetCurrent()
	local names = self:candidates(current)

	while #names > 0 do
		local name = table.remove(names, math.random(1, #names))
		local ok, message = self.RealApply(name, self:getTransition())

		if ok then
			if not self.Override then
				self.Underlying = current
			end

			self.Override = name
			fireAll("EnemyWeatherOverride", name)
			log:Debug(string.format("'%s' put in the sky (was %s).", name, tostring(current)))
			return true
		end

		log:StudioWarn(string.format("could not apply '%s' (%s).", name, tostring(message)))
	end

	return false
end

function EnemyWeatherChangeService:restore()
	if not self.Override then return end

	local weatherService = self.Services.WeatherService
	local underlying = self.Underlying

	self.Override = nil
	self.Underlying = nil

	local transition = self:getTransition()

	if underlying then
		if weatherService:GetCurrent() ~= underlying then
			local ok = self.RealApply(underlying, transition)
			if not ok then
				self.RealClear(transition)
			end
		end
	elseif weatherService:GetCurrent() then
		self.RealClear(transition)
	end

	log:Debug(string.format("sky restored to %s.", tostring(underlying)))
end

function EnemyWeatherChangeService:playCast(record)
	local mobId, mob = record.MobId, record.Mob
	local mobService = self.Services.MobService

	local castTime = math.max(0, Settings.CastTime or 0)
	local stopping = castTime > 0 and Settings.StopWhileCasting == true

	if stopping then
		mob.StunnedUntil = math.max(mob.StunnedUntil or 0, GameClock.Now() + castTime)
		fireAll("UpdateMobSpeed", mobId, 0)
	end

	if Settings.EnemyAnim then
		fireAll("MobPlayAnim", mobId, Settings.EnemyAnim)
	end

	if Settings.VFX and castTime > 0 then
		fireAll("EnemyWeatherChangeVFX", mobId, Settings.VFX, castTime)
	end

	if stopping then
		GameClock.Delay(castTime, function()
			if mobService.ActiveMobs[mobId] ~= mob then return end
			if (mob.StunnedUntil or 0) <= GameClock.Now() then
				fireAll("UpdateMobSpeed", mobId, mob.CurrentSpeed)
			end
		end)
	end
end

function EnemyWeatherChangeService:beginCast(record)
	record.Cast = true
	self.Caster = record

	self:playCast(record)

	GameClock.Delay(math.max(0, Settings.ApplyDelay or 0), function()
		if self.Caster ~= record or not self:isAlive(record) then return end

		if not self:changeWeather() then
			log:Warn("no weather could be applied (no map loaded, or an empty pool).")
		end
	end)
end

function EnemyWeatherChangeService:nextInLine()
	for _, record in self.Records do
		if record.Ready and not record.Cast and self:isAlive(record) then
			return record
		end
	end
	return nil
end

function EnemyWeatherChangeService:onCasterGone()
	self.Caster = nil

	local nextRecord = self:nextInLine()
	if nextRecord then
		self:beginCast(nextRecord)
	else
		self:restore()
	end
end

function EnemyWeatherChangeService:step()
	local mobService = self.Services.MobService
	if not mobService or not mobService.ActiveMobs then return end

	local now = GameClock.Now()

	for mobId, mob in mobService.ActiveMobs do
		if not self.Tracked[mob] and self.EnemySet[mob.Name] then
			local record = {
				MobId = mobId,
				Mob = mob,
				SpawnedAt = now,
				Ready = false,
				Cast = false,
			}
			self.Tracked[mob] = record
			table.insert(self.Records, record)
		end
	end

	for _, record in self.Records do
		if not record.Ready and now - record.SpawnedAt >= (Settings.GraceTime or 5) then
			record.Ready = true
		end
	end

	local casterGone = false
	for index = #self.Records, 1, -1 do
		local record = self.Records[index]
		if not self:isAlive(record) then
			table.remove(self.Records, index)
			self.Tracked[record.Mob] = nil

			if record == self.Caster then
				casterGone = true
			end
		end
	end

	if casterGone then
		self:onCasterGone()
	end

	if not self.Caster then
		local nextRecord = self:nextInLine()
		if nextRecord then
			self:beginCast(nextRecord)
		end
	end
end

function EnemyWeatherChangeService:GetOverride() : string?
	return self.Override
end

function EnemyWeatherChangeService:ResetRound()
	table.clear(self.Records)
	table.clear(self.Tracked)
	self.Caster = nil
	self:restore()
end

function EnemyWeatherChangeService:start()
	for name in self.Services do
		self.Services[name] = Framework:Get(name)
	end

	for _, enemy in Settings.Enemies do
		self.EnemySet[enemy] = true
	end

	Framework:Listen("EnemyWeatherChangeVFX", function() end)
	Framework:Listen("EnemyWeatherOverride", function() end)

	self:installGuard()

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt : number)
		elapsed += dt
		if elapsed < POLL_INTERVAL then return end
		elapsed = 0

		self:step()
	end)
end

function EnemyWeatherChangeService:init()
end

return EnemyWeatherChangeService