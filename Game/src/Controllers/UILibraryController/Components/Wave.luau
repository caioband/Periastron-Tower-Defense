local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)
local WaveCounter = Interface:WaitForChild("WaveCounter")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Spring = require(Vendor.Spring)

local module = {}

function module:set(num)
	WaveCounter.Number.Text = tostring(num)
end

function module:destroy()
	if self.maid then
		self.maid:Destroy()
	end

	if not self.tasks then
		self.tasks = {}
	end

	self.maid = nil

	Spring.target(CardUpgrade, .65, 4, {
		Position = UDim2.fromScale(1.2, CardUpgrade.Position.Y.Scale)
	})

	local conn
	conn = task.delay(1, function()
		CardUpgrade.Visible = false
		self.delayTask = nil
		table.remove(self.tasks, table.find(self.tasks, conn))
	end)
	table.insert(self.tasks, conn)
end

return module
