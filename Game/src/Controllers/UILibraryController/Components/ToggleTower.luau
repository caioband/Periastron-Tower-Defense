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
local TargetPriority = SharedConfig.TargetPriority
local ClassConfig = SharedConfig.ClassConfig
local UIUtil = require(Utils.UIUtil)
local PointerUtil = require(Utils.PointerUtil)

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
	Stats do card sao numeros pequenos (dano, alcance); acima de mil
	vale mais abreviar do que mostrar a casa decimal.
]=]
local function formatStat(value : number) : string
	if value >= 1000 then
		return UIUtil.formatAbbreviated(math.floor(value + 0.5))
	end

	return formatNumber(value, 1)
end

--[=[
	Cada label de stat do card tem um irmao menor logo abaixo, deixado no
	StarterGui, que mostra o valor que a unidade vai ter depois do proximo upgrade.
	A ordem aqui e {label que ja existia, previa dele}.
]=]
local PREVIEW_LABELS = {
	{ stat = "DamagePerSecond", preview = "DamagePerSecondUpgrade" },
	{ stat = "AttackSpeed", preview = "CooldownUpgrade" },
	{ stat = "Range", preview = "RangeUpgrade" },
}

local function getPreviewLabel(entry) : TextLabel?
	local stat = CardUpgrade:FindFirstChild(entry.stat)
	return stat and stat:FindFirstChild(entry.preview)
end

local function hidePreviewLabels()
	for _, entry in PREVIEW_LABELS do
		local label = getPreviewLabel(entry)
		if label then
			label.Visible = false
		end
	end
end

--[[
	O clima entra nos numeros de combate do card.

	E o mesmo motivo do circulo de alcance no chao: durante a neblina a unidade
	procura alvo num raio menor, e um card que continuasse mostrando o alcance
	seco estaria mentindo sobre a unidade que o jogador esta olhando. Quem
	redesenha o card na troca de clima e o `UnitPlacementController`.
]]
local function getWeather()
	local weatherController = Framework:Get("WeatherController", false, false)
	return weatherController and weatherController:GetCurrent() or nil
end

--[=[
	Dano por golpe, ou a renda por wave quando a unidade e uma Farm -- que nao
	ataca. Mesma conta para o nivel atual e para a previa do proximo.
]=]
local function formatDamageOrIncome(unitName : string, level : number, weather) : string
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local unitStats = SharedConfig.UnitStats[unitName]
	local farm = unitStats and unitStats.Farm

	if farm then
		local income = math.floor((farm.Income or 0) * upgradeConfig:GetDamageMultiplier(unitName, level) + 0.5)
		return "$" .. UIUtil.formatAbbreviated(income) .. " INCOME"
	end

	return formatStat(upgradeConfig:GetDamage(unitName, level, weather)) .. " DMG"
end

--[=[
	O botao de pulo do Roblox no celular, se estiver na tela. `TouchGui` so existe
	em aparelho de toque, e nasce de novo a cada respawn -- por isso ele e
	procurado na hora, e nunca guardado.
]=]
local function findJumpButton() : GuiObject?
	local touchGui = PlayerGui:FindFirstChild("TouchGui")
	local controlFrame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local button = controlFrame and controlFrame:FindFirstChild("JumpButton")

	return button and button:IsA("GuiObject") and button or nil
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
		-- `Activated` e nao `MouseButton1Up`: no toque, se o dedo escorrega para fora
		-- do botao antes de soltar, o MouseButton1Up nao chega e a venda se perde.
		self.sellConnection = sellButton.Activated:Connect(function()
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
		self.upgradeConnection = upgradeButton.Activated:Connect(function()
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

	--[[
		Previa do proximo nivel.

		No PC ela so aparece com o mouse em cima do custo de upgrade: o jogador ve
		o que o dinheiro compra antes de gastar, e o card fica limpo no resto do
		tempo. No celular nao existe "pairar por cima" -- o dedo ou esta apertando
		ou nao esta na tela --, entao la os numeros ficam sempre visiveis.
	]]
	self.previewHovered = false

	if upgradeButton and not PointerUtil.isTouchOnly() then
		self.maid:GiveTask(upgradeButton.MouseEnter:Connect(function()
			self.previewHovered = true
			self:refreshPreview()
		end))
		self.maid:GiveTask(upgradeButton.MouseLeave:Connect(function()
			self.previewHovered = false
			self:refreshPreview()
		end))
	end

	local priorityButton = CardUpgrade:FindFirstChild("Priority")
	if self.priorityConnection then
		self.priorityConnection:Disconnect()
		self.priorityConnection = nil
	end

	if priorityButton and unitModel then
		--[[
			Um clique anda uma casa no ciclo do `TargetPriority`. O que vai para o
			servidor e o modo de destino, nao "o proximo": o botao le o estado do
			atributo, que e o que o servidor confirmou por ultimo, entao dois cliques
			seguidos nao se atropelam.

			O texto do botao nao muda aqui -- ele muda quando a confirmacao volta e
			mexe no atributo. Assim o card nunca mostra uma prioridade que o servidor
			recusou (unidade de outro jogador, por exemplo).
		]]
		self.priorityConnection = priorityButton.Activated:Connect(function()
			local unitId = unitModel:GetAttribute("UnitID")
			if not unitId then return end

			Framework:Fire("SetUnitPriority", unitId, TargetPriority.Next(unitModel:GetAttribute("TargetPriority")))
		end)
		self.maid:GiveTask(function()
			if self.priorityConnection then
				self.priorityConnection:Disconnect()
				self.priorityConnection = nil
			end
		end)
	end

	if unitModel then
		-- Upgrade muda dano/alcance/cooldown e o custo do proximo nivel; o dano total
		-- chega em lote do servidor algumas vezes por segundo.
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("Upgrades"):Connect(function()
			self:refresh()
		end))
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("TargetPriority"):Connect(function()
			self:refreshPriority()
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

	self:setJumpButtonHidden(true)
end

--[=[
	Tira o botao de pulo da tela enquanto o card estiver aberto, e devolve depois.

	No celular o card abre exatamente por cima do canto onde o Roblox desenha o
	botao de pulo: os dois disputam o mesmo dedo, e o jogador que ia apertar
	VENDER pula. So no toque -- num PC o botao nem existe.

	Nao e `controls:Disable()`: isso levaria junto o direcional, e o jogador
	continua podendo andar com o card aberto. O que sai e so o botao.

	A escondida fica vigiada porque o `TouchGui` nao e nosso: o modulo TouchJump do
	Roblox reescreve `Visible` sozinho (ao renascer, ao sentar, ao voltar a poder
	pular) e um respawn troca o botao por um novo. Enquanto o card estiver aberto,
	qualquer botao de pulo que aparecer volta a ficar escondido -- e o que o
	TouchJump quis nesse meio tempo e o que se devolve no fim, para nao acender um
	botao que o Roblox tinha apagado de proposito.
]=]
function module:setJumpButtonHidden(hidden : boolean)
	if self.jumpMaid then
		self.jumpMaid:Destroy()
		self.jumpMaid = nil
	end

	if not hidden or not PointerUtil.isTouchOnly() then return end

	local maid = Maid.new()
	self.jumpMaid = maid

	local active = true
	local wanted = true

	local function hide(button : GuiObject)
		wanted = button.Visible
		button.Visible = false

		maid:GiveTask(button:GetPropertyChangedSignal("Visible"):Connect(function()
			if not active or not button.Visible then return end
			wanted = true
			button.Visible = false
		end))
	end

	local button = findJumpButton()
	if button then
		hide(button)
	end

	maid:GiveTask(PlayerGui.DescendantAdded:Connect(function(descendant)
		if not active or descendant.Name ~= "JumpButton" then return end
		if descendant ~= findJumpButton() then return end

		hide(descendant)
	end))

	-- Primeiro desliga a vigia, depois devolve: assim a restauracao nao cai no
	-- proprio observador e apaga o botao de novo.
	maid:GiveTask(function()
		active = false

		local current = findJumpButton()
		if current then
			current.Visible = wanted
		end
	end)
end

--[=[
	O icone de classe do card: `Melee`, `Ranged`, `Magic`, `Fire`, `Ice` ou
	`Electric`, pela classe que a unidade declara em `UnitStats`.

	Unidade sem classe (ou classe que ainda nao tem arte) esconde o label em vez de
	mostrar um quadrado vazio -- e ele volta sozinho na proxima unidade que tiver.

	`FindFirstChild` porque o `ClassIcon` e recente no StarterGui: sem ele o card
	inteiro continua funcionando, so sem o icone.
]=]
local function applyClassIcon(unitName : string?)
	local icon = CardUpgrade:FindFirstChild("ClassIcon")
	if not icon or not icon:IsA("ImageLabel") then return end

	local image = ClassConfig.GetIcon(unitName)

	icon.Image = image or ""
	icon.Visible = image ~= nil
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
		applyClassIcon(nil)
		return
	end

	local unitName = unitModel.Name
	local level = unitModel:GetAttribute("Upgrades") or 0
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local weather = getWeather()

	CardUpgrade.Info.UnitName.Text = unitName
	CardUpgrade.Info.UnitLevel.Text = "LVL." .. level
	applyClassIcon(unitName)

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

	--[[
		O label `DamagePerSecond` mostra o dano por golpe, nao o DPS: o numero que
		interessa na hora de comprar um upgrade e o que entra no mob por batida — o
		cooldown ja esta logo abaixo, no proprio card, para quem quiser a conta por
		segundo.

		Farm nao ataca: no lugar do dano, a renda por wave.
	]]
	CardUpgrade.DamagePerSecond.Text = formatDamageOrIncome(unitName, level, weather)

	CardUpgrade.AttackSpeed.Text = formatNumber(upgradeConfig:GetCooldown(unitName, level, weather), 2) .. " COOLDOWN"
	CardUpgrade.Range.Text = formatStat(upgradeConfig:GetRange(unitName, level, weather)) .. " RANGE"

	self:refreshPreview()
	self:refreshPriority()
	self:refreshDamageDone()
end

--[=[
	Escreve nas previas o que a unidade vira depois do proximo upgrade -- os mesmos
	getters do card, so que com `level + 1`, entao dano, cooldown e alcance da
	previa saem da mesma conta que o servidor usa em combate (clima incluido).

	No nivel maximo as previas somem, mesmo no celular: nao ha proximo valor para
	mostrar, e o custo ao lado ja esta escrito "MAX".
]=]
function module:refreshPreview()
	local unitModel = self.currentUnit
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local level = unitModel and unitModel:GetAttribute("Upgrades") or 0

	local shouldShow = self.previewHovered or PointerUtil.isTouchOnly()
	if not unitModel or not unitModel.Parent or upgradeConfig:IsMaxed(level) then
		shouldShow = false
	end

	if not shouldShow then
		hidePreviewLabels()
		return
	end

	local unitName = unitModel.Name
	local weather = getWeather()
	local nextLevel = level + 1

	local texts = {
		DamagePerSecondUpgrade = formatDamageOrIncome(unitName, nextLevel, weather),
		CooldownUpgrade = formatNumber(upgradeConfig:GetCooldown(unitName, nextLevel, weather), 2) .. " COOLDOWN",
		RangeUpgrade = formatStat(upgradeConfig:GetRange(unitName, nextLevel, weather)) .. " RANGE",
	}

	for _, entry in PREVIEW_LABELS do
		local label = getPreviewLabel(entry)
		if label then
			label.Text = texts[entry.preview]
			label.Visible = true
		end
	end
end

--[=[
	Escreve no botao a prioridade de alvo que a unidade esta usando. Sai do
	atributo do modelo, que e o que o servidor mandou -- o botao nunca adivinha.
]=]
function module:refreshPriority()
	local button = CardUpgrade:FindFirstChild("Priority")
	local label = button and button:FindFirstChild("TextLabel")
	if not label then return end

	local unitModel = self.currentUnit
	if not unitModel or not unitModel.Parent then return end

	-- Farm nao mira em ninguem: o botao sai da tela em vez de mostrar uma
	-- prioridade que nao vai ser usada.
	local unitStats = SharedConfig.UnitStats[unitModel.Name]
	button.Visible = not (unitStats and unitStats.Farm)

	label.Text = TargetPriority.Label(unitModel:GetAttribute("TargetPriority"))
end

function module:refreshDamageDone()
	local unitModel = self.currentUnit
	if not unitModel or not unitModel.Parent then return end

	local total = math.floor((unitModel:GetAttribute("DamageDone") or 0) + 0.5)
	CardUpgrade.DmgDone.Text = UIUtil.formatAbbreviated(total) .. " DMG DONE"
end

function module:destroy()
	self.currentUnit = nil
	self.previewHovered = false
	hidePreviewLabels()
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
		self:setJumpButtonHidden(false)
		self.delayTask = nil
		table.remove(self.tasks, table.find(self.tasks, conn))
	end)
	table.insert(self.tasks, conn)
end

return module
