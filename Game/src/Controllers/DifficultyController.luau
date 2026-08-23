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

local function formatClock(seconds : number)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

function DifficultyController:updateClock(state)
	local clock = self.clock
	if not clock then return end

	clock.Visible = state.active == true
	clock.Time.Text = formatClock(state.timeLeft or 0)
end

--[=[
	A hotbar so aparece com a dificuldade ja decidida. Antes disso nao ha partida
	nenhuma — o servidor esta esperando todo mundo carregar, ou a votacao esta
	aberta — e as cartas nao teriam onde ser colocadas.
]=]
function DifficultyController:setHotbarVisible(visible : boolean)
	if self.hotbar then
		self.hotbar.Visible = visible
	end
end

function DifficultyController:updateUI(state)
	self:updateClock(state)
	self:setHotbarVisible(state.locked ~= nil)

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
	local Interface = PlayerGui:WaitForChild("Interface", 60)
	local clock = Interface and Interface:WaitForChild("Clock", 60)
	if clock and clock:FindFirstChild("Time") then
		self.clock = clock
		clock.Visible = false
	end

	local hotbar = Interface and Interface:WaitForChild("TowerContainer", 60)
	if hotbar then
		self.hotbar = hotbar

		-- Escondida de saida: o cliente costuma terminar de carregar antes de o
		-- servidor abrir a votacao, e ate o primeiro estado chegar nao ha partida.
		hotbar.Visible = false
	end

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

		self:setHotbarVisible(true)

		if self.clock then
			self.clock.Visible = false
		end
	end)
end

function DifficultyController:start()
end

function DifficultyController:init()
	self:construct()
end

return DifficultyController
