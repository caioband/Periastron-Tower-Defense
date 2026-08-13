local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(Configs.Server)
local PathUtil = require(Shared.Util.PathUtil)

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local WaveConfig = ServerConfig.Wave

local Framework = Me.new()

local DataConfig = ServerConfig.Data

local INTERMISSION_TIME = 60
local WAVE_INTERVAL = 3
local SELECTION_TIME = 15
local MAX_WAVES = DataConfig.MAX_WAVES
local BASE_WINNING_CASH = DataConfig.BASE_WINNING_CASH

local WaveService = {
	Services = {
		MobService = {},
		DifficultyService = {},
		DataService = {}
	},
	Signals = {
		Ended = Signal.new()
	},
	ReadyPlayers = {},
	GameOver = false
}

function WaveService:setWave(waveCount : number)
	self.WaveCount = waveCount

	for _, Player in Players:GetPlayers() do
		Framework:Fire("SetWave", Player, self.WaveCount)
	end

end

function WaveService:waitForAllPlayers()
	while true do
		local allReady = true
		for _, player in Players:GetPlayers() do
			if not player:HasTag("ClientReady") then
				allReady = false
			end
		end

		if allReady and #Players:GetPlayers() > 0 then
			break
		end
		task.wait(0.5)
	end
end

function WaveService:timeLeft()
	if not self.IntermissionEndsAt then return 0 end
	return math.max(0, math.ceil(self.IntermissionEndsAt - os.clock()))
end

function WaveService:allReady()
	local players = Players:GetPlayers()
	if #players == 0 then return false end
	for _, player in players do
		if not self.ReadyPlayers[player.UserId] then
			return false
		end
	end
	return true
end

function WaveService:broadcastReadyState(timeLeft)
	local readyCount = 0
	local total = 0
	for _, player in Players:GetPlayers() do
		total += 1
		if self.ReadyPlayers[player.UserId] then
			readyCount += 1
		end
	end
	for _, player in Players:GetPlayers() do
		Framework:Fire("WaveIntermission", player, {
			active = self.IntermissionActive == true,
			ready = readyCount,
			total = total,
			timeLeft = timeLeft,
			isReady = self.ReadyPlayers[player.UserId] == true,
		})
	end
end

function WaveService:runIntermission(duration)
	self.ReadyPlayers = {}
	self.IntermissionActive = true
	self.IntermissionEndsAt = os.clock() + duration

	self:broadcastReadyState(self:timeLeft())

	local lastShown = nil
	while os.clock() < self.IntermissionEndsAt do
		if self:allReady() then break end
		local remaining = self:timeLeft()
		if remaining ~= lastShown then
			lastShown = remaining
			self:broadcastReadyState(remaining)
		end
		task.wait(0.2)
	end

	self.IntermissionActive = false
	self.ReadyPlayers = {}
	self:broadcastReadyState(0)
end

function WaveService:computeReward(preset)
	local wavesSurvived = math.clamp(self.WaveCount or 0, 0, MAX_WAVES)
	local multiplier = preset and preset.WinCashMultiplier or 1
	local amount = BASE_WINNING_CASH * (wavesSurvived / MAX_WAVES) * multiplier
	return math.max(0, math.floor(amount + 0.5))
end

function WaveService:onRoundEnded(won : boolean)
	local preset = self.Difficulty or self.Services.DifficultyService:GetSelected()
	local reward = self:computeReward(preset)
	local dataService = self.Services.DataService

	for _, player in Players:GetPlayers() do
		if dataService then
			dataService:Update(player, "Stats", function(stats)
				stats.Cash = (stats.Cash or 0) + reward
				return stats
			end)
		end

		if won then
			Framework:Fire("Win", player)
		end

		Framework:Fire("RoundReward", player, {
			won = won,
			reward = reward,
			wavesSurvived = math.clamp(self.WaveCount or 0, 0, MAX_WAVES),
			maxWaves = MAX_WAVES,
		})
	end
end

function WaveService:getArrowLeadTime()
	local cfg = SharedConfig.ArrowConfig
	local smooth = self.Services.MobService:getSmoothPath()
	local traversal = smooth.length / cfg.Speed
	local lastArrowFinish = (cfg.Count - 1) * cfg.Stagger + traversal
	return lastArrowFinish + cfg.Buffer
end

function WaveService:construct()
	local endedSignal = self.Signals.Ended

	Framework:Listen("ReadyWave", function(player)
		if not self.IntermissionActive then return end
		if self.ReadyPlayers[player.UserId] then
			self.ReadyPlayers[player.UserId] = nil
		else
			self.ReadyPlayers[player.UserId] = true
		end
		self:broadcastReadyState(self:timeLeft())
	end)

	task.spawn(function()
		self:waitForAllPlayers()

		local preset = self.Services.DifficultyService:RunSelection(SELECTION_TIME)
		self.Difficulty = preset

		self:runIntermission(preset.IntermissionTime or INTERMISSION_TIME)

		local won = false
		while not self.GameOver do
			self:setWave((self.WaveCount or 0) + 1)
			task.wait(self:getArrowLeadTime())
			self.Services.MobService:SpawnWave(self.WaveCount)

			endedSignal:Wait()
			if self.GameOver then break end

			if self.WaveCount >= MAX_WAVES then
				won = true
				self.GameOver = true
				break
			end

			task.wait(preset.WaveInterval or WAVE_INTERVAL)
		end

		self:onRoundEnded(won)
	end)
end

function WaveService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function WaveService:init()
	Framework:Listen("SetWave", function() end)
	Framework:Listen("WaveIntermission", function() end)
	Framework:Listen("Win", function() end)
	Framework:Listen("RoundReward", function() end)
end

return WaveService
