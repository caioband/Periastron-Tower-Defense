local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("PumpkinDropService")

local PumpkinConfig = SharedConfig.PumpkinConfig
local EventConfig = SharedConfig.EventCurrencyConfig
local MobConfig = SharedConfig.Mob
local WaveConfig = ServerConfig.Wave

local REASON = "Pumpkin"
local MAX_VERTICAL_GAP = 25

--[[
	Event pumpkins: each wave owes `PumpkinConfig.PerWave[difficulty]` event currency,
	split at random across that wave's kills, and every pumpkin owed is guaranteed to
	drop.

	MobService has no death signal, so this wraps `SpawnWave` (wave start) and
	`removeMob` (every enemy leaving the map, killed or escaped), and watches
	`ActiveMobs` for new enemies so each one is tied to the wave that spawned it.
	A skipped wave's leftovers keep counting toward their own wave.

	Each player gets their own copy of every drop (`Pending`), collected by walking
	into it on their client and checked here by distance.
]]

local PumpkinDropService = {
	Services = {
		MobService = {},
		WaveService = {},
		DataService = {},
		EventCurrencyService = {},
	},
}

--[[ INTERNAL ]]

-- How many of `left` pumpkins this kill drops, with `remaining` wave enemies still
-- unresolved (this one included). The last enemy takes everything left.
local function roll(left : number, remaining : number) : number
	if left <= 0 then
		return 0
	end

	if remaining <= 1 then
		return left
	end

	local chance = 1 / remaining
	local count = 0

	for _ = 1, left do
		if math.random() < chance then
			count += 1
		end
	end

	return count
end

local function isActive() : boolean
	return PumpkinConfig.Enabled == true and EventConfig.Enabled == true
end

function PumpkinDropService:_countSpawns(waveNumber : number, preset) : number
	local total = 0

	for _, entry in WaveConfig.GetSpawns(waveNumber, preset.Name) do
		if MobConfig.Entities[entry.Entity] then
			total += entry.Amount or 1
		end
	end

	return total
end

function PumpkinDropService:_beginWave(mobService, waveNumber : number)
	self.Wave = nil

	if not isActive() then
		return
	end

	-- A community map drops no pumpkins: anyone can publish an easy one.
	local waveService = self.Services.WaveService
	if waveService and waveService:isCommunityMatch() then
		return
	end

	local preset = mobService:getDifficulty()
	local amount = preset and PumpkinConfig.PerWave[preset.Name] or 0
	if amount <= 0 then
		return
	end

	local total = self:_countSpawns(waveNumber, preset)
	if total <= 0 then
		return
	end

	self.Wave = {
		Number = waveNumber,
		Total = total,
		Tagged = 0,
		Remaining = total,
		Left = amount,
		LastKill = nil,
		Token = self.RoundToken,
	}
end

-- Wave enemies are inserted with no `LastDistance`; converts arrive with one.
function PumpkinDropService:_onMobAdded(mob)
	local wave = self.Wave
	if not wave or wave.Tagged >= wave.Total then
		return
	end

	if mob.LastDistance ~= nil then
		return
	end

	wave.Tagged += 1
	self.MobWave[mob] = wave
end

function PumpkinDropService:_onMobRemoved(mobService, mobId : string, mob)
	local wave = self.MobWave[mob]
	if not wave then
		return
	end

	self.MobWave[mob] = nil

	if wave.Token ~= self.RoundToken then
		return
	end

	local remaining = wave.Remaining
	wave.Remaining = math.max(0, remaining - 1)

	if (mob.Health or 0) <= 0 then
		local position = mobService:getMobPosition(mobId)

		if position then
			wave.LastKill = position

			local amount = roll(wave.Left, remaining)
			if amount > 0 then
				wave.Left -= amount
				self:_drop(position, amount)
			end
		end
	end

	if wave.Remaining == 0 and wave.Left > 0 then
		local left = wave.Left
		wave.Left = 0

		if wave.LastKill then
			self:_drop(wave.LastKill, left)
		else
			self:_grantAll(left)
		end
	end
end

function PumpkinDropService:_grantAll(amount : number)
	local currency = self.Services.EventCurrencyService
	if not currency then
		return
	end

	for _, player in Players:GetPlayers() do
		currency:Add(player, amount, REASON)
	end
end

function PumpkinDropService:_drop(position : Vector3, amount : number)
	self.NextId += 1
	local id = self.NextId
	local token = self.RoundToken

	local payload = {
		Id = id,
		Amount = amount,
		X = position.X,
		Y = position.Y,
		Z = position.Z,
	}

	for _, player in Players:GetPlayers() do
		local drops = self.Pending[player.UserId]
		if not drops then
			drops = {}
			self.Pending[player.UserId] = drops
		end

		drops[id] = { Amount = amount, Position = position }
		Framework:Fire("PumpkinDropped", player, payload)
	end

	task.delay(PumpkinConfig.Lifetime, function()
		if self.RoundToken == token then
			self:_expire(id)
		end
	end)
end

-- Closes one player's drop without a pickup: paid if `AwardUncollected`, gone otherwise.
function PumpkinDropService:_settle(player : Player, id : number, entry)
	local awarded = false

	if PumpkinConfig.AwardUncollected then
		local currency = self.Services.EventCurrencyService
		if currency then
			local _, _, err = currency:Add(player, entry.Amount, REASON)
			awarded = err == nil
		end
	end

	Framework:Fire("PumpkinRemoved", player, id, awarded, entry.Amount)
end

function PumpkinDropService:_expire(id : number)
	for userId, drops in self.Pending do
		local entry = drops[id]
		if entry then
			drops[id] = nil

			local player = Players:GetPlayerByUserId(userId)
			if player then
				self:_settle(player, id, entry)
			end
		end
	end
end

function PumpkinDropService:_flushPlayer(player : Player)
	local drops = self.Pending[player.UserId]
	if not drops then
		return
	end

	self.Pending[player.UserId] = nil

	for id, entry in drops do
		self:_settle(player, id, entry)
	end
end

function PumpkinDropService:_flushAll()
	self.RoundToken += 1
	self.Wave = nil
	table.clear(self.MobWave)

	for _, player in Players:GetPlayers() do
		self:_flushPlayer(player)
	end

	table.clear(self.Pending)
end

function PumpkinDropService:_collect(player : Player, id : any)
	if typeof(id) ~= "number" then
		return
	end

	local drops = self.Pending[player.UserId]
	local entry = drops and drops[id]
	if not entry then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local offset = root.Position - entry.Position
	local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
	if flat > PumpkinConfig.CollectRadius + PumpkinConfig.ServerCollectTolerance or math.abs(offset.Y) > MAX_VERTICAL_GAP then
		return
	end

	local currency = self.Services.EventCurrencyService
	if not currency then
		return
	end

	local _, _, err = currency:Add(player, entry.Amount, REASON)
	if err then
		log:Warn(`pumpkin for {player.Name} not paid: {err}`)
		return
	end

	drops[id] = nil
	Framework:Fire("PumpkinCollected", player, id, entry.Amount)
end

function PumpkinDropService:_hook()
	local mobService = self.Services.MobService
	if not mobService or mobService.__PumpkinHooked then
		return
	end

	mobService.__PumpkinHooked = true

	local service = self

	local spawnWave = mobService.SpawnWave
	mobService.SpawnWave = function(ms, waveNumber, ...)
		local ok, err = pcall(service._beginWave, service, ms, waveNumber)
		if not ok then
			log:Warn(`wave {tostring(waveNumber)} setup failed: {err}`)
		end

		return spawnWave(ms, waveNumber, ...)
	end

	local removeMob = mobService.removeMob
	mobService.removeMob = function(ms, mobId, ...)
		local mob = ms.ActiveMobs[mobId]
		if mob then
			local ok, err = pcall(service._onMobRemoved, service, ms, mobId, mob)
			if not ok then
				log:Warn(`drop roll failed: {err}`)
			end
		end

		return removeMob(ms, mobId, ...)
	end

	local activeMobs = mobService.ActiveMobs
	if getmetatable(activeMobs) ~= nil then
		log:Warn("MobService.ActiveMobs already has a metatable; pumpkins will not drop.")
		return
	end

	setmetatable(activeMobs, {
		__newindex = function(tbl, key, value)
			rawset(tbl, key, value)

			if typeof(value) == "table" then
				local ok, err = pcall(service._onMobAdded, service, value)
				if not ok then
					log:Warn(`enemy tag failed: {err}`)
				end
			end
		end,
	})
end

--[[ LIFECYCLE ]]

function PumpkinDropService:construct()
	self:_hook()

	local waveService = self.Services.WaveService
	if waveService and waveService.Signals then
		waveService.Signals.RoundStarted:Connect(function()
			self:_flushAll()
		end)

		waveService.Signals.RoundClosed:Connect(function()
			self:_flushAll()
		end)
	end

	local dataService = self.Services.DataService
	if dataService and dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player)
			self:_flushPlayer(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		task.defer(function()
			self.Pending[player.UserId] = nil
		end)
	end)
end

function PumpkinDropService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function PumpkinDropService:init()
	self.Pending = {}
	self.MobWave = setmetatable({}, { __mode = "k" })
	self.NextId = 0
	self.RoundToken = 0
	self.Wave = nil

	Framework:Listen("PumpkinDropped", function() end)
	Framework:Listen("PumpkinCollected", function() end)
	Framework:Listen("PumpkinRemoved", function() end)

	Framework:Listen("CollectPumpkin", function(player, id)
		self:_collect(player, id)
	end)
end

return PumpkinDropService