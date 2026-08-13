local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor.Me)
local Framework = Me.new()

local SELECTED_TRANSPARENCY = 0
local IDLE_TRANSPARENCY = 0.4

local DifficultyController = {
	Buttons = {}
}

function DifficultyController:updateUI(state)
	local board = self.board
	if not board then return end

	board.Visible = state.active == true

	local countdown = board:FindFirstChild("Countdown")
	if countdown then
		countdown.Text = tostring(state.timeLeft or 0) .. "s"
	end

	local votes = state.votes or {}

	for name, button in self.Buttons do
		local isSelected = state.selected == name

		if not state.selected or isSelected then
			button.ImageTransparency = SELECTED_TRANSPARENCY
		else
			button.ImageTransparency = IDLE_TRANSPARENCY
		end

		local voteLabel = button:FindFirstChild("VoteCount")
		if voteLabel then
			voteLabel.Text = tostring(votes[name] or 0)
		end
	end
end

function DifficultyController:construct()
	local screen = PlayerGui:WaitForChild("Difficulty", 60)
	if not screen then return end

	self.board = screen:WaitForChild("DifficultyBoard", 60)
	if not self.board then return end

	self.board.Visible = false

	for _, child in self.board:GetChildren() do
		if child:IsA("ImageButton") then
			self.Buttons[child.Name] = child

			child.MouseButton1Click:Connect(function()
				Framework:Fire("SelectDifficulty", child.Name)
			end)
		end
	end

	Framework:Listen("DifficultySelection", function(state)
		self:updateUI(state)
	end)

	Framework:Listen("DifficultyLocked", function(difficultyName)
		self.Locked = difficultyName
		self.board.Visible = false
	end)
end

function DifficultyController:start()
end

function DifficultyController:init()
	self:construct()
end

return DifficultyController
