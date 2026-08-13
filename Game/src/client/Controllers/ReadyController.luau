local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor.Me)
local Framework = Me.new()

local ReadyController = {}

function ReadyController:updateUI(state)
	local button = self.button
	if not button then return end

	button.Visible = state.active == true

	local mainLabel = button:FindFirstChild("TextLabel")
	if mainLabel then
		mainLabel.Text = state.isReady and "READIED" or "READY"
	end

	local playersReady = button:FindFirstChild("PlayersReady")
	if playersReady then
		playersReady.Text = string.format("%d/%d", state.ready or 0, state.total or 0)
	end

	local countdown = button:FindFirstChild("Countdown")
	if countdown then
		countdown.Text = tostring(state.timeLeft or 0) .. "s"
	end
end

function ReadyController:construct()
	local Interface = PlayerGui:WaitForChild("Interface", 60)
	if not Interface then return end

	self.button = Interface:WaitForChild("ReadyWave", 60)
	if not self.button then return end

	self.button.Visible = false

	self.button.MouseButton1Click:Connect(function()
		Framework:Fire("ReadyWave")
	end)

	Framework:Listen("WaveIntermission", function(state)
		self:updateUI(state)
	end)
end

function ReadyController:start()
end

function ReadyController:init()
	self:construct()
end

return ReadyController
