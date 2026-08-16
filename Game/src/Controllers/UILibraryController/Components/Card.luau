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

-- Cores originais da UI (StarterGui.Interface.TowerContainer.CardN.Frame).
local DEFAULT_COST_STROKE = Color3.fromRGB(98, 82, 139)
local DEFAULT_COUNT_STROKE = Color3.fromRGB(81, 38, 141)
local DEFAULT_COUNT_IMAGE = Color3.fromRGB(255, 255, 255)

-- Sem unidades sobrando: carta apagada em cinza claro.
local NO_STOCK_STROKE = Color3.fromRGB(190, 190, 190)
local NO_STOCK_TRANSPARENCY = 0.25

-- Sem dinheiro para o custo: carta em vermelho, mas sem apagar.
local NO_CASH_COLOR = Color3.fromRGB(255, 70, 70)

local module = {}
module.baseRotations = nil
module.counts = {}
module.cash = 0

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

local function getCardParts(button)
	local frame = button:FindFirstChild("Frame")
	if not frame then return nil end

	local imageLabel = frame:FindFirstChild("ImageLabel")
	local countHolder = imageLabel and imageLabel:FindFirstChild("Count")
	local countLabel = countHolder and countHolder:FindFirstChild("Count")
	local costLabel = frame:FindFirstChild("Cost")

	return {
		Cost = costLabel,
		CostStroke = costLabel and costLabel:FindFirstChildOfClass("UIStroke"),
		Image = imageLabel,
		CountHolder = countHolder,
		CountLabel = countLabel,
		CountStroke = countLabel and countLabel:FindFirstChildOfClass("UIStroke"),
	}
end

-- Estado visual da carta: sem estoque tem prioridade sobre falta de dinheiro,
-- ja que sem unidade a carta nao pode ser usada de jeito nenhum.
local function resolveCardState(unitName)
	if not unitName then return "Available" end

	local count = module.counts[unitName] or 0
	if count <= 0 then return "NoStock" end

	local stats = SharedConfig.UnitStats[unitName]
	local cost = stats and stats.Cost or 0
	if module.cash < cost then return "NoCash" end

	return "Available"
end

local function applyCardState(button, parts)
	local unitName = button:GetAttribute("Unit")
	if not unitName then return end

	parts = parts or getCardParts(button)
	if not parts then return end

	local state = resolveCardState(unitName)
	if button:GetAttribute("CardState") == state then return end
	button:SetAttribute("CardState", state)

	local transparency = state == "NoStock" and NO_STOCK_TRANSPARENCY or 0
	if parts.Image then parts.Image.ImageTransparency = transparency end
	if parts.CountHolder then parts.CountHolder.ImageTransparency = transparency end

	local costStrokeColor = DEFAULT_COST_STROKE
	local countImageColor = DEFAULT_COUNT_IMAGE
	local countStrokeColor = DEFAULT_COUNT_STROKE

	if state == "NoStock" then
		costStrokeColor = NO_STOCK_STROKE
	elseif state == "NoCash" then
		costStrokeColor = NO_CASH_COLOR
		countImageColor = NO_CASH_COLOR
		countStrokeColor = NO_CASH_COLOR
	end

	if parts.CostStroke then parts.CostStroke.Color = costStrokeColor end
	if parts.CountHolder then parts.CountHolder.ImageColor3 = countImageColor end
	if parts.CountStroke then parts.CountStroke.Color = countStrokeColor end
end

local function setCardCount(button, count)
	local parts = getCardParts(button)
	if not parts then return end

	if parts.CountLabel then
		parts.CountLabel.Text = tostring(count or 0) .. "x"
	end

	applyCardState(button, parts)
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

	self.counts = Counts or {}

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
			-- O TowerContainer so tem Card1..Card5; o jogador pode possuir mais
			-- unidades que isso, entao as excedentes nao tem slot.
			if not button then continue end

			local name = Cards[i]
			button:SetAttribute("Unit", name)
			-- A carta pode ter trocado de unidade; invalida o estado visual antigo.
			button:SetAttribute("CardState", nil)
			setCardCost(button, name)
			setCardCount(button, self.counts[name])
			restoreRotation(button)

			button.Visible = true
			task.wait(.25)
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
	self.counts[unitName] = count

	for _, button in TowerContainer:GetChildren() do
		if button:IsA("TextButton") and button:GetAttribute("Unit") == unitName then
			setCardCount(button, count)
		end
	end
end

function module:setCash(cash : number)
	self.cash = cash or 0

	for _, button in TowerContainer:GetChildren() do
		if button:IsA("TextButton") then
			applyCardState(button)
		end
	end
end

function module:destroy()
end

return module
