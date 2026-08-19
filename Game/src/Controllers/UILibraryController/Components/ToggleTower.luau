local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)
local CardUpgrade = Interface:WaitForChild("CardUpgrade")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Utils.UIUtil)

local Maid = require(Vendor.Maid)
local Spring = require(Vendor.Spring)
local Me = require(Vendor.Me)

local Framework = Me.new()

local module = {}
module.currentUnit = nil

--[=[
	Numero com no maximo `decimals` casas e sem zeros sobrando: 12.00 -> "12",
	0.75 -> "0.75". So mexe na parte decimal, entao 100 continua "100".
]=]
local function formatNumber(value : number, decimals : number?) : string
	local text = string.format("%." .. (decimals or 0) .. "f", value)

	if text:find("%.") then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end

	return text
end

--[=[
	Stats do card sao numeros pequenos (dano por segundo, alcance); acima de mil
	vale mais abreviar do que mostrar a casa decimal.
]=]
local function formatStat(value : number) : string
	if value >= 1000 then
		return UIUtil.formatAbbreviated(math.floor(value + 0.5))
	end

	return formatNumber(value, 1)
end

function module:create(unitModel, ...)
	if self.maid then
		self.maid:Destroy()
		self.maid = nil
	end

	if self.tasks then
		for index, taskInst in self.tasks do
			task.cancel(taskInst)
			self.tasks[index] = nil
		end
	end

	self.maid = Maid.new()
	self.currentUnit = unitModel

	local sellButton = CardUpgrade:FindFirstChild("Sell")
	if sellButton and self.sellConnection then
		self.sellConnection:Disconnect()
		self.sellConnection = nil
	end

	if sellButton and unitModel then
		self.sellConnection = sellButton.MouseButton1Up:Connect(function()
			local unitId = unitModel:GetAttribute("UnitID")
			Framework:Fire("SellUnit", unitId)
			self:destroy()
		end)
		self.maid:GiveTask(function()
			if self.sellConnection then
				self.sellConnection:Disconnect()
				self.sellConnection = nil
			end
		end)
	end

	local upgradeButton = CardUpgrade:FindFirstChild("UpgradeCost")
	if self.upgradeConnection then
		self.upgradeConnection:Disconnect()
		self.upgradeConnection = nil
	end

	if upgradeButton and unitModel then
		self.upgradeConnection = upgradeButton.MouseButton1Up:Connect(function()
			local level = unitModel:GetAttribute("Upgrades") or 0
			if SharedConfig.UnitUpgradeConfig:IsMaxed(level) then return end
			local unitId = unitModel:GetAttribute("UnitID")
			Framework:Fire("UpgradeUnit", unitId)
		end)
		self.maid:GiveTask(function()
			if self.upgradeConnection then
				self.upgradeConnection:Disconnect()
				self.upgradeConnection = nil
			end
		end)
	end

	if unitModel then
		-- Upgrade muda dano/alcance/cooldown e o custo do proximo nivel; o dano total
		-- chega em lote do servidor algumas vezes por segundo.
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("Upgrades"):Connect(function()
			self:refresh()
		end))
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("DamageDone"):Connect(function()
			self:refreshDamageDone()
		end))
	end

	self:refresh()

	CardUpgrade.Position = UDim2.fromScale(1.2, CardUpgrade.Position.Y.Scale)

	Spring.target(CardUpgrade, .65, 4, {
		Position = UDim2.fromScale(0.85, CardUpgrade.Position.Y.Scale)
	})
	CardUpgrade.Visible = true
end

--[=[
	Preenche todo o card com os dados da unidade selecionada. Cada label leva o
	sufixo que o designer deixou no StarterGui, so o numero e trocado.
]=]
function module:refresh()
	local unitModel = self.currentUnit

	local upgradeLabel = CardUpgrade.UpgradeCost:FindFirstChild("TextLabel")
	local sellLabel = CardUpgrade.Sell:FindFirstChild("TextLabel")

	if not unitModel or not unitModel.Parent then
		if upgradeLabel then upgradeLabel.Text = "" end
		if sellLabel then sellLabel.Text = "SELL" end
		return
	end

	local unitName = unitModel.Name
	local level = unitModel:GetAttribute("Upgrades") or 0
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local unitStats = SharedConfig.UnitStats[unitName]

	CardUpgrade.Info.UnitName.Text = unitName
	CardUpgrade.Info.UnitLevel.Text = "LVL." .. level

	if upgradeLabel then
		if upgradeConfig:IsMaxed(level) then
			upgradeLabel.Text = "MAX"
		else
			upgradeLabel.Text = "$" .. UIUtil.formatAbbreviated(upgradeConfig:GetCost(unitName, level))
		end
	end

	-- Mesma conta do servidor no `SellUnit`: parte do que foi investido volta.
	if sellLabel then
		local invested = upgradeConfig:GetInvested(unitName, level)
		local refund = math.floor(invested * SharedConfig.SellRefundRatio)
		sellLabel.Text = "SELL $" .. UIUtil.formatAbbreviated(refund)
	end

	-- Farm nao ataca: o lugar do dano por segundo mostra a renda por wave.
	local farm = unitStats and unitStats.Farm
	if farm then
		local income = math.floor((farm.Income or 0) * upgradeConfig:GetDamageMultiplier(unitName, level) + 0.5)
		CardUpgrade.DamagePerSecond.Text = "$" .. UIUtil.formatAbbreviated(income) .. " INCOME"
	else
		CardUpgrade.DamagePerSecond.Text = formatStat(upgradeConfig:GetDPS(unitName, level)) .. " DPS"
	end

	CardUpgrade.AttackSpeed.Text = formatNumber(upgradeConfig:GetCooldown(unitName, level), 2) .. " COOLDOWN"
	CardUpgrade.Range.Text = formatStat(upgradeConfig:GetRange(unitName, level)) .. " RANGE"

	self:refreshDamageDone()
end

function module:refreshDamageDone()
	local unitModel = self.currentUnit
	if not unitModel or not unitModel.Parent then return end

	local total = math.floor((unitModel:GetAttribute("DamageDone") or 0) + 0.5)
	CardUpgrade.DmgDone.Text = UIUtil.formatAbbreviated(total) .. " DMG DONE"
end

function module:destroy()
	self.currentUnit = nil
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
