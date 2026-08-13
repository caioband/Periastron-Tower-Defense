local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)
local TowerContainer = Interface:WaitForChild("TowerContainer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Spring = require(Vendor.Spring)

local module = {}
module.baseRotations = nil

local function ensureBaseRotations()
	if module.baseRotations then return end
	module.baseRotations = {}
	for _, btn in TowerContainer:GetChildren() do
		if btn:IsA("TextButton") then
			local frame = btn:FindFirstChild("Frame")
			if frame then
				module.baseRotations[btn.Name] = frame.Rotation
			end
		end
	end
end

local function restoreRotation(button)
	if not module.baseRotations then return end
	local frame = button:FindFirstChild("Frame")
	if frame and module.baseRotations[button.Name] then
		frame.Rotation = module.baseRotations[button.Name]
	end
end

local function setCardCost(button, unitName)
	local frame = button:FindFirstChild("Frame")
	if not frame then return end

	local stats = SharedConfig.UnitStats[unitName]
	local cost = stats and stats.Cost or 0

	local costLabel = frame:FindFirstChild("Cost")
	if not costLabel then return end
	costLabel.Text = "$" .. cost
end

local function setCardCount(button, count)
	local frame = button:FindFirstChild("Frame")
	if not frame then return end

	local imageLabel = frame:FindFirstChild("ImageLabel")
	if not imageLabel then return end

	local countHolder = imageLabel:FindFirstChild("Count")
	if not countHolder then return end

	local countLabel = countHolder:FindFirstChild("Count")
	if not countLabel then return end

	countLabel.Text = tostring(count or 0) .. "x"
end

local supportedKeybinds = {
	["One"] = 1,
	["Two"] = 2,
	["Three"] = 3,
	["Four"] = 4,
	["Five"] = 5,
}

function module:clean()
	local maid = self.maid
	if maid then
		maid:DoCleaning()
		self.maid = nil
	end

	return true
end

function module:set(Cards : {}, Counts : {}, callbackDo : (string) -> ())

	self:clean()

	ensureBaseRotations()

	print(Cards, "is the equipped cards")

	self.maid = Maid.new()

	for _, towerFrame in TowerContainer:GetChildren() do
		if not towerFrame:IsA("TextButton") then
			continue
		end
		local splitArg = string.split(towerFrame.Name, "Card")[2]
		local name = tonumber(splitArg)
		print(name, "is the name")

		if not name then continue end

		if not Cards[name] then continue end

		self.maid:GiveTask(towerFrame.Activated:Connect(function()
			callbackDo(towerFrame:GetAttribute("Unit"))
		end))
	end

	for num, info in Cards do
		local button = TowerContainer:FindFirstChild("Card" .. num)
		if button then
			button.Visible = false
			restoreRotation(button)
		end
	end

	if #Cards > 0 then
		for i = 1, #Cards do
			local button = TowerContainer:FindFirstChild("Card" .. i)

			local name = Cards[i]
			button:SetAttribute("Unit", name)
			setCardCost(button, name)
			setCardCount(button, Counts and Counts[name])
			restoreRotation(button)

			if button then
				button.Visible = true
				task.wait(.25)
			end
		end

		self.maid:GiveTask(UserInputService.InputBegan:Connect(function(input, gpe)
			if gpe then return end

			local keybind = supportedKeybinds[input.KeyCode.Name]
			if keybind ~= nil then
				local towerFrame = TowerContainer:FindFirstChild("Card" .. keybind)
				if towerFrame then
					callbackDo(towerFrame:GetAttribute("Unit"))
				end
			end
		end))
	end

	return true
end

function module:setCount(unitName : string, count : number)
	for _, button in TowerContainer:GetChildren() do
		if button:IsA("TextButton") and button:GetAttribute("Unit") == unitName then
			setCardCount(button, count)
		end
	end
end

function module:destroy()
end

return module
