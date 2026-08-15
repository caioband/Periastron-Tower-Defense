local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)

local DifficultyConfig = ServerConfig.Difficulty

local Framework = Me.new()

local ALL_VOTED_GRACE = 2

local DifficultyService = {
	Services = {
		MobService = {}
	},
	Votes = {},
	Selected = nil,
	SelectionActive = false
}

function DifficultyService:GetSelected()
	return DifficultyConfig.Get(self.Selected)
end

function DifficultyService:timeLeft()
	if not self.SelectionEndsAt then return 0 end
	return math.max(0, math.ceil(self.SelectionEndsAt - os.clock()))
end

function DifficultyService:tally()
	local counts = {}
	for _, name in DifficultyConfig.Order do
		counts[name] = 0
	end

	for _, name in self.Votes do
		if counts[name] then
			counts[name] += 1
		end
	end

	return counts
end

function DifficultyService:allVoted()
	local players = Players:GetPlayers()
	if #players == 0 then return false end

	for _, player in players do
		if not self.Votes[player.UserId] then
			return false
		end
	end

	return true
end

function DifficultyService:winner()
	local counts = self:tally()
	local best = nil
	local bestCount = 0

	for _, name in DifficultyConfig.Order do
		if counts[name] > bestCount then
			best = name
			bestCount = counts[name]
		end
	end

	return best or DifficultyConfig.Default
end

function DifficultyService:broadcastSelectionState(timeLeft)
	local counts = self:tally()
	for _, player in Players:GetPlayers() do
		Framework:Fire("DifficultySelection", player, {
			active = self.SelectionActive == true,
			options = DifficultyConfig.Order,
			votes = counts,
			timeLeft = timeLeft,
			selected = self.Votes[player.UserId],
			locked = self.Selected,
		})
	end
end

function DifficultyService:RunSelection(duration)
	self.Votes = {}
	self.Selected = nil
	self.SelectionActive = true
	self.SelectionEndsAt = os.clock() + duration

	self:broadcastSelectionState(self:timeLeft())

	local lastShown = nil
	local shortened = false
	while os.clock() < self.SelectionEndsAt do
		if not shortened and self:allVoted() then
			shortened = true
			self.SelectionEndsAt = math.min(self.SelectionEndsAt, os.clock() + ALL_VOTED_GRACE)
		end

		local remaining = self:timeLeft()
		if remaining ~= lastShown then
			lastShown = remaining
			self:broadcastSelectionState(remaining)
		end
		task.wait(0.2)
	end

	self.Selected = self:winner()
	self.SelectionActive = false
	self:broadcastSelectionState(0)

	local preset = self:GetSelected()

	local mobService = self.Services.MobService
	if mobService then
		mobService:ApplyDifficulty(preset)
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("DifficultyLocked", player, preset.Name)
	end

	return preset
end

--[=[
	Devolve o service ao estado de antes da votacao. A dificuldade escolhida cai
	junto: o proximo round vota de novo.
]=]
function DifficultyService:ResetRound()
	table.clear(self.Votes)
	self.Selected = nil
	self.SelectionActive = false
	self.SelectionEndsAt = nil

	self:broadcastSelectionState(0)
end

function DifficultyService:construct()
	Framework:Listen("SelectDifficulty", function(player, difficultyName)
		if not self.SelectionActive then return end
		if not DifficultyConfig.Exists(difficultyName) then return end

		if self.Votes[player.UserId] == difficultyName then
			self.Votes[player.UserId] = nil
		else
			self.Votes[player.UserId] = difficultyName
		end

		self:broadcastSelectionState(self:timeLeft())
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.Votes[player.UserId] = nil
	end)
end

function DifficultyService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function DifficultyService:init()
	Framework:Listen("DifficultySelection", function() end)
	Framework:Listen("DifficultyLocked", function() end)
end

return DifficultyService
