--[[
	Playtest setup and HUD for the map editor.

	Drives the frames authored in StarterGui.MapEditorUI:
	  PlaytestSetup  - difficulty board, start wave picker and tower loadout
	  PlaytestHUD    - cash, wave, base health, next wave button, the hotbar and
	                   CardUpgrade (the match's upgrade card)
	  Templates.TowerCard - the card cloned into the loadout grid and the hotbar

	The server opens every test in the "Setup" phase (PlaytestService.start); this
	script answers with PlaytestConfigure, places towers with PlaytestTower, and
	drives the upgrade card with PlaytestUpgrade, PlaytestPriority and PlaytestSell.
	The card reads the tower model's `Upgrades`, `TargetPriority` and `DamageDone`
	attributes and formats them with the same UnitUpgradeConfig getters the match's
	card uses. Waves are started with PlaytestWave, the same request the TestBar's
	NEXT WAVE button sends.
]]
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared:WaitForChild("Config"))
local TowerFootprint = require(Shared:WaitForChild("TowerFootprint"))
local Remotes = Shared:WaitForChild("Remotes")
local Request = Remotes:WaitForChild("Request")
local Push = Remotes:WaitForChild("Push")

local PeriShared = ReplicatedStorage:WaitForChild("Shared")
local SharedConfigModule = PeriShared:WaitForChild("Config"):WaitForChild("SharedConfig")
local SharedConfig = require(SharedConfigModule)
local UnitStats = SharedConfig.UnitStats
local CardConfig = SharedConfig.CardConfig
local ClassConfig = SharedConfig.ClassConfig
local UnitUpgradeConfig = SharedConfig.UnitUpgradeConfig
local TargetPriority = SharedConfig.TargetPriority
local UnitAssets = PeriShared:WaitForChild("Assets"):WaitForChild("Units")

local UIUtil = nil
do
	local util = PeriShared:FindFirstChild("Util")
	local module = util and util:FindFirstChild("UIUtil")
	if module then
		local ok, result = pcall(require, module)
		if ok then
			UIUtil = result
		end
	end
end

local PERI = Config.PERI

local gui = player:WaitForChild("PlayerGui"):WaitForChild("MapEditorUI")
local templates = gui:WaitForChild("Templates")
local cardTemplate = templates:WaitForChild("TowerCard")

local setup = gui:WaitForChild("PlaytestSetup")
local board = setup:WaitForChild("Board")
local difficultyHolder = board:WaitForChild("Difficulties")
local wavesFrame = board:WaitForChild("Waves")
local waveRow = wavesFrame:WaitForChild("Row")
local minusButton = waveRow:WaitForChild("Minus")
local plusButton = waveRow:WaitForChild("Plus")
local waveInput = waveRow:WaitForChild("ValueBox"):WaitForChild("Input")
local waveMax = waveRow:WaitForChild("Max")
local footer = board:WaitForChild("Footer")
local startButton = footer:WaitForChild("Start")
local cancelButton = footer:WaitForChild("Cancel")
local statusLabel = board:WaitForChild("Status")
local towerPanel = setup:WaitForChild("Towers")
local pickedLabel = towerPanel:WaitForChild("Picked")
local towerList = towerPanel:WaitForChild("List")

local hud = gui:WaitForChild("PlaytestHUD")
local waveNumber = hud:WaitForChild("WaveCounter"):WaitForChild("Number")
local cashLabel = hud:WaitForChild("CashCounter"):WaitForChild("TextLabel")
local baseLabel = hud:WaitForChild("BaseCounter"):WaitForChild("TextLabel")
local nextWaveButton = hud:WaitForChild("NextWave")
local nextWaveLabel = nextWaveButton:WaitForChild("Label")
local nextWaveCountdown = nextWaveButton:WaitForChild("Countdown")
local hotbar = hud:WaitForChild("TowerContainer")

local upgradeCard = hud:WaitForChild("CardUpgrade")
local cardInfo = upgradeCard:WaitForChild("Info")
local cardName = cardInfo:WaitForChild("UnitName")
local cardLevel = cardInfo:WaitForChild("UnitLevel")
local cardDamage = upgradeCard:WaitForChild("DamagePerSecond")
local cardCooldown = upgradeCard:WaitForChild("AttackSpeed")
local cardRange = upgradeCard:WaitForChild("Range")
local cardDamageDone = upgradeCard:WaitForChild("DmgDone")
local cardUpgrade = upgradeCard:WaitForChild("UpgradeCost")
local cardUpgradeLabel = cardUpgrade:WaitForChild("TextLabel")
local cardPriority = upgradeCard:WaitForChild("Priority")
local cardPriorityLabel = cardPriority:WaitForChild("TextLabel")
local cardSell = upgradeCard:WaitForChild("Sell")
local cardSellLabel = cardSell:WaitForChild("TextLabel")
local cardClassIcon = upgradeCard:FindFirstChild("ClassIcon")
local previewLabels = {
	cardDamage:FindFirstChild("DamagePerSecondUpgrade"),
	cardCooldown:FindFirstChild("CooldownUpgrade"),
	cardRange:FindFirstChild("RangeUpgrade"),
}
local INFO_DEFAULT_ICON = cardInfo.Image

local COLOR_OK = Color3.fromHex("55ff7f")
local COLOR_BAD = Color3.fromHex("ff5a5a")
local COLOR_IDLE = Color3.fromHex("9a9a9a")
local COLOR_RANGE = Color3.fromHex("6E99CA")
local NEXT_WAVE_COLOR = nextWaveButton.ImageColor3

local options = nil
local chosenDifficulty = nil
local startWave = 1
local loadout = {}
local pickerCards = {}
local hotbarCards = {}
local lastStats = nil
local busy = false

local selectedUnit = nil
local ghost = nil
local ghostRing = nil
local ghostHighlight = nil
local ghostLift = 0
local lastTouch = nil

local selectedTower = nil
local towerHighlight = nil
local towerRing = nil
local previewHovered = false

-- Helpers -------------------------------------------------------------------------

local function request(action, payload)
	local success, result = pcall(Request.InvokeServer, Request, action, payload)
	if not success then
		return { ok = false, err = "Connection problem. Try again." }
	end
	if typeof(result) ~= "table" then
		return { ok = false, err = "Unexpected server response." }
	end
	return result
end

local function abbreviate(n)
	if UIUtil and UIUtil.formatAbbreviated then
		local ok, text = pcall(UIUtil.formatAbbreviated, n)
		if ok and text then
			return tostring(text)
		end
	end
	return tostring(math.floor(n + 0.5))
end

local function formatNumber(n, decimals)
	local text = string.format("%." .. decimals .. "f", n)
	text = text:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
	return text
end

local function formatStat(n)
	if math.abs(n - math.floor(n)) < 1e-3 then
		return tostring(math.floor(n))
	end
	return formatNumber(n, 1)
end

local function setStatus(text, isError)
	statusLabel.Text = text or ""
	statusLabel.TextColor3 = if isError then Color3.fromHex("ff6139") else Color3.fromHex("ffffff")
end

local function difficultyInfo(name)
	if not options then
		return nil
	end
	for _, info in options.difficulties do
		if info.name == name then
			return info
		end
	end
	return nil
end

local function waveCap()
	local info = difficultyInfo(chosenDifficulty)
	if not info then
		return 1
	end
	if info.maxWaves > 0 then
		return info.maxWaves
	end
	return options.endlessCap or 1000
end

local function unitCost(name)
	return UnitUpgradeConfig:GetPlaceCost(name)
end

local function sortedUnits()
	local list = {}
	for name, s in UnitStats do
		if typeof(s) == "table" and UnitAssets:FindFirstChild(name) then
			table.insert(list, name)
		end
	end
	table.sort(list, function(a, b)
		local ca, cb = unitCost(a), unitCost(b)
		if ca ~= cb then
			return ca < cb
		end
		return a < b
	end)
	return list
end

local function hover(card)
	local face = card:FindFirstChild("Card")
	local scale = face and face:FindFirstChildOfClass("UIScale")
	local button = face and face:FindFirstChild("Button")
	if scale and button then
		button.MouseEnter:Connect(function()
			scale.Scale = 1.06
		end)
		button.MouseLeave:Connect(function()
			scale.Scale = 1
		end)
	end
end

local function makeCard(name, parent, order)
	local card = cardTemplate:Clone()
	card.Name = name
	card.Visible = true
	card.LayoutOrder = order
	local face = card:WaitForChild("Card")
	face.Image = CardConfig.GetImage(name) or face.Image
	face:WaitForChild("UnitName").Text = name
	face:WaitForChild("Cost").Text = "$" .. unitCost(name)
	face:WaitForChild("Count").Visible = false
	face:WaitForChild("Highlight").Visible = false
	card.Parent = parent
	hover(card)
	return card, face:WaitForChild("Button")
end

local function setCardHighlight(card, on)
	local face = card and card:FindFirstChild("Card")
	local highlight = face and face:FindFirstChild("Highlight")
	if highlight then
		highlight.Visible = on
	end
end

local function makeRing(name)
	local ring = Instance.new("Part")
	ring.Name = name
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.8
	return ring
end

local function placeRing(ring, ground: Vector3, range: number)
	ring.Size = Vector3.new(0.05, range * 2, range * 2)
	ring.CFrame = CFrame.new(ground + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, 0, math.rad(90))
end

-- Setup -------------------------------------------------------------------------------

local function refreshSetup()
	for _, button in difficultyHolder:GetChildren() do
		if button:IsA("GuiButton") then
			local highlight = button:FindFirstChild("Highlight")
			if highlight then
				highlight.Visible = button.Name == chosenDifficulty
			end
			button.Visible = difficultyInfo(button.Name) ~= nil
		end
	end
	local cap = waveCap()
	startWave = math.clamp(startWave, 1, cap)
	waveInput.Text = tostring(startWave)
	local info = difficultyInfo(chosenDifficulty)
	waveMax.Text = if info and info.maxWaves == 0 then "/ ENDLESS" else "/ " .. cap
	local size = options and options.loadoutSize or 6
	pickedLabel.Text = string.format("%d/%d", #loadout, size)
	for name, card in pickerCards do
		setCardHighlight(card, table.find(loadout, name) ~= nil)
	end
	startButton.ImageColor3 = if #loadout > 0 and chosenDifficulty then COLOR_OK else COLOR_IDLE
end

local function buildPicker()
	if next(pickerCards) then
		return
	end
	for index, name in sortedUnits() do
		local card, button = makeCard(name, towerList, index)
		pickerCards[name] = card
		button.Activated:Connect(function()
			local at = table.find(loadout, name)
			if at then
				table.remove(loadout, at)
			else
				local size = options and options.loadoutSize or 6
				if #loadout >= size then
					setStatus(string.format("Loadout is full (%d). Remove a tower first.", size), true)
					return
				end
				table.insert(loadout, name)
			end
			setStatus("")
			refreshSetup()
		end)
	end
end

local function openSetup()
	if not options then
		local response = request("PlaytestOptions")
		if not response.ok then
			return
		end
		options = response.data
	end
	if not chosenDifficulty or not difficultyInfo(chosenDifficulty) then
		chosenDifficulty = options.default
	end
	buildPicker()
	setStatus("")
	refreshSetup()
	hud.Visible = false
	setup.Visible = true
end

for _, button in difficultyHolder:GetChildren() do
	if button:IsA("GuiButton") then
		button.Activated:Connect(function()
			chosenDifficulty = button.Name
			setStatus("")
			refreshSetup()
		end)
	end
end

minusButton.Activated:Connect(function()
	startWave -= 1
	refreshSetup()
end)

plusButton.Activated:Connect(function()
	startWave += 1
	refreshSetup()
end)

waveInput.FocusLost:Connect(function()
	local value = tonumber(waveInput.Text)
	if value then
		startWave = math.floor(value)
	end
	refreshSetup()
end)

cancelButton.Activated:Connect(function()
	if busy then
		return
	end
	busy = true
	request("PlaytestStop")
	busy = false
end)

startButton.Activated:Connect(function()
	if busy then
		return
	end
	if not chosenDifficulty then
		setStatus("Pick a difficulty.", true)
		return
	end
	if #loadout == 0 then
		setStatus("Pick at least one tower.", true)
		return
	end
	busy = true
	setStatus("Starting...")
	local response = request("PlaytestConfigure", {
		difficulty = chosenDifficulty,
		startWave = startWave,
		towers = loadout,
	})
	busy = false
	if not response.ok then
		setStatus(response.err, true)
		return
	end
	setStatus("")
	setup.Visible = false
end)

-- Upgrade card ------------------------------------------------------------------------

local function supportMode(support)
	return support.Default or (support.Order and support.Order[1]) or "Damage"
end

local function formatDamageOrIncome(unitName, level)
	local unitStats = UnitStats[unitName]
	if unitStats and unitStats.Farm then
		local income = math.floor(UnitUpgradeConfig:GetIncome(unitName, level) + 0.5)
		return "$" .. abbreviate(income) .. " PER WAVE"
	end
	if unitStats and unitStats.SlowAura then
		return formatNumber(UnitUpgradeConfig:GetAuraSlow(unitName, level) * 100, 2) .. "% SLOW"
	end
	if unitStats and unitStats.Support then
		local support = unitStats.Support
		local mode = supportMode(support)
		local modeConfig = support.Modes and support.Modes[mode]
		local boost = UnitUpgradeConfig:GetSupportBoost(unitName, level, mode)
		local label = (modeConfig and modeConfig.Label) or string.upper(mode)
		return "+" .. formatNumber(boost * 100, 1) .. "% " .. label .. " BOOST"
	end
	return formatStat(UnitUpgradeConfig:GetDamage(unitName, level)) .. " DMG"
end

local function formatCooldownOrBonus(unitName, level)
	local bonus = UnitUpgradeConfig:GetAuraBonus(unitName, level)
	if bonus > 0 then
		return formatNumber(bonus * 100, 1) .. "% PER UNIT BONUS"
	end
	local unitStats = UnitStats[unitName]
	if unitStats and unitStats.SlowAura then
		return "SLOWS IN RANGE"
	end
	if unitStats and unitStats.Support then
		return formatNumber(unitStats.Support.SwapCooldown or 10, 1) .. "s SWAP COOLDOWN"
	end
	return formatNumber(UnitUpgradeConfig:GetCooldown(unitName, level), 2) .. " COOLDOWN"
end

local function formatRange(unitName, level)
	return formatStat(UnitUpgradeConfig:GetRange(unitName, level)) .. " RANGE"
end

local function clearTowerSelection()
	selectedTower = nil
	upgradeCard.Visible = false
	if towerHighlight then
		towerHighlight:Destroy()
		towerHighlight = nil
	end
	if towerRing then
		towerRing:Destroy()
		towerRing = nil
	end
end

local function refreshPreview()
	local model = selectedTower
	local level = model and model:GetAttribute("Upgrades") or 0
	local show = (previewHovered or (UserInputService.TouchEnabled and not UserInputService.MouseEnabled))
		and model ~= nil and model.Parent ~= nil and not UnitUpgradeConfig:IsMaxed(level)
	if not show then
		for _, label in previewLabels do
			if label then
				label.Visible = false
			end
		end
		return
	end
	local name = model.Name
	local texts = {
		formatDamageOrIncome(name, level + 1),
		formatCooldownOrBonus(name, level + 1),
		formatRange(name, level + 1),
	}
	for index, label in previewLabels do
		if label then
			label.Text = texts[index]
			label.Visible = true
		end
	end
end

local function refreshCard()
	local model = selectedTower
	if not model or not model.Parent then
		clearTowerSelection()
		return
	end
	local name = model.Name
	local level = model:GetAttribute("Upgrades") or 0
	local unitStats = UnitStats[name]

	cardName.Text = name
	cardLevel.Text = "LVL." .. level
	cardInfo.Image = CardConfig.GetIcon(name) or INFO_DEFAULT_ICON or ""
	if cardClassIcon and cardClassIcon:IsA("ImageLabel") then
		local icon = ClassConfig and ClassConfig.GetIcon and ClassConfig.GetIcon(name)
		cardClassIcon.Image = icon or ""
		cardClassIcon.Visible = icon ~= nil
	end

	if UnitUpgradeConfig:IsMaxed(level) then
		cardUpgradeLabel.Text = "MAX"
		cardUpgrade.ImageColor3 = COLOR_IDLE
	else
		local cost = UnitUpgradeConfig:GetCost(name, level)
		cardUpgradeLabel.Text = "$" .. abbreviate(cost)
		cardUpgrade.ImageColor3 = if lastStats and (lastStats.cash or 0) >= cost then Color3.fromHex("5eff63") else COLOR_BAD
	end

	local refund = math.floor(UnitUpgradeConfig:GetInvested(name, level) * (SharedConfig.SellRefundRatio or 0.5))
	cardSellLabel.Text = "SELL $" .. abbreviate(refund)

	cardDamage.Text = formatDamageOrIncome(name, level)
	cardCooldown.Text = formatCooldownOrBonus(name, level)
	cardRange.Text = formatRange(name, level)
	cardDamageDone.Text = abbreviate(model:GetAttribute("DamageDone") or 0) .. " DMG DONE"

	local support = unitStats and unitStats.Support
	cardPriority.Visible = not (unitStats and (unitStats.Farm or unitStats.SlowAura))
	if support then
		local mode = support.Modes[model:GetAttribute("BardMode") or support.Default]
		cardPriorityLabel.Text = mode and mode.Label or ""
	else
		cardPriorityLabel.Text = TargetPriority.Label(model:GetAttribute("TargetPriority"))
	end

	if towerRing then
		local range = model:GetAttribute("Range") or UnitUpgradeConfig:GetRange(name, level)
		local pivot = model:GetPivot().Position
		local groundY = model:GetAttribute("GroundY") or pivot.Y
		placeRing(towerRing, Vector3.new(pivot.X, groundY, pivot.Z), range)
	end

	refreshPreview()
end

local function selectTower(model)
	clearTowerSelection()
	if not model then
		return
	end
	selectedTower = model
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromHex("ffd23f")
	highlight.Adornee = model
	highlight.Parent = workspace.CurrentCamera
	towerHighlight = highlight
	local ring = makeRing("PlaytestTowerRange")
	ring.Color = COLOR_RANGE
	ring.Parent = workspace.CurrentCamera
	towerRing = ring
	upgradeCard.Visible = true
	refreshCard()
end

local function towerId()
	return selectedTower and selectedTower:GetAttribute("PlaytestTowerId")
end

cardUpgrade.Activated:Connect(function()
	local id = towerId()
	if busy or not id then
		return
	end
	busy = true
	request("PlaytestUpgrade", { id = id })
	busy = false
	refreshCard()
end)

cardUpgrade.MouseEnter:Connect(function()
	previewHovered = true
	refreshPreview()
end)

cardUpgrade.MouseLeave:Connect(function()
	previewHovered = false
	refreshPreview()
end)

cardPriority.Activated:Connect(function()
	local id = towerId()
	if busy or not id then
		return
	end
	busy = true
	request("PlaytestPriority", { id = id })
	busy = false
	refreshCard()
end)

cardSell.Activated:Connect(function()
	local id = towerId()
	if busy or not id then
		return
	end
	busy = true
	local response = request("PlaytestSell", { id = id })
	busy = false
	if response.ok then
		clearTowerSelection()
	end
end)

-- Placement ---------------------------------------------------------------------------

local function destroyGhost()
	if ghost then
		ghost:Destroy()
		ghost = nil
	end
	if ghostRing then
		ghostRing:Destroy()
		ghostRing = nil
	end
	ghostHighlight = nil
end

local function selectUnit(name)
	destroyGhost()
	if selectedUnit == name then
		name = nil
	end
	selectedUnit = name
	for unit, card in hotbarCards do
		setCardHighlight(card, unit == selectedUnit)
	end
	if not name then
		return
	end
	clearTowerSelection()
	local template = UnitAssets:FindFirstChild(name)
	if not template then
		return
	end
	local model = template:Clone()
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	local cf, size = template:GetBoundingBox()
	ghostLift = if root then root.Position.Y - (cf.Position.Y - size.Y / 2) else size.Y / 2
	if root then
		model.PrimaryPart = root
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("Animation") or d:IsA("AnimationController") then
			d:Destroy()
		end
	end
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 0.55
	highlight.OutlineTransparency = 0.2
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model
	ghostHighlight = highlight
	model.Name = "PlaytestGhost"
	model.Parent = workspace.CurrentCamera
	ghost = model

	ghostRing = makeRing("PlaytestGhostRange")
	ghostRing.Parent = workspace.CurrentCamera
end

local function screenRay(position, includesInset)
	local camera = workspace.CurrentCamera
	if includesInset then
		return camera:ViewportPointToRay(position.X, position.Y)
	end
	return camera:ScreenPointToRay(position.X, position.Y)
end

local function groundHit(ray)
	local mapRoot = workspace:FindFirstChild("Map")
	if not mapRoot then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { mapRoot }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
	return hit and hit.Position
end

local function towersFolder()
	local root = workspace:FindFirstChild("MapEditorPlaytest")
	return root and root:FindFirstChild("Towers")
end

local function placementReason(position)
	local mapRoot = workspace:FindFirstChild("Map")
	if not mapRoot then
		return "Point at the map."
	end
	-- The same downward ray PlaytestService.placeTower casts, so both sides test the
	-- same ground part.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { mapRoot }
	local hit = workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -20, 0), params)
	if not hit then
		return "Towers need ground under them."
	end
	local grid = {}
	for _, part in CollectionService:GetTagged(PERI.GridTag) do
		if part:IsA("BasePart") and part:IsDescendantOf(mapRoot) then
			table.insert(grid, part)
		end
	end
	local others = {}
	local folder = towersFolder()
	if folder then
		for _, tower in folder:GetChildren() do
			if tower:IsA("Model") then
				table.insert(others, { name = tower.Name, position = tower:GetPivot().Position })
			end
		end
	end
	local ok, reason = TowerFootprint.check(UnitAssets, selectedUnit, hit.Position, others, grid, mapRoot, hit.Instance)
	if not ok then
		return reason
	end
	if lastStats and lastStats.cash and selectedUnit and lastStats.cash < unitCost(selectedUnit) then
		return "Not enough cash."
	end
	return nil
end

local function placeAt(position)
	if not selectedUnit or not position then
		return
	end
	local response = request("PlaytestTower", {
		position = { position.X, position.Y, position.Z },
		unit = selectedUnit,
	})
	if not response.ok then
		return
	end
	if not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and not UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
		selectUnit(nil)
	end
end

local function towerAt(ray)
	local folder = towersFolder()
	if not folder then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
	if not hit then
		return nil
	end
	local model = hit.Instance:FindFirstAncestorOfClass("Model")
	while model and model.Parent ~= folder do
		model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
	end
	return model
end

local function inTest()
	return hud.Visible and lastStats ~= nil and lastStats.phase ~= "Setup"
end

local function clickWorld(ray)
	if selectedUnit then
		placeAt(groundHit(ray))
		return
	end
	local model = towerAt(ray)
	if model and model:GetAttribute("PlaytestTowerId") then
		if model == selectedTower then
			clearTowerSelection()
		else
			selectTower(model)
		end
	else
		clearTowerSelection()
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not inTest() then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.Escape or input.UserInputType == Enum.UserInputType.MouseButton2 then
		if selectedUnit then
			selectUnit(nil)
		end
		clearTowerSelection()
		return
	end
	if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	clickWorld(screenRay(UserInputService:GetMouseLocation(), true))
end)

UserInputService.TouchTapInWorld:Connect(function(position, processed)
	if processed or not inTest() then
		return
	end
	lastTouch = position
	clickWorld(screenRay(position, false))
end)

RunService.RenderStepped:Connect(function()
	if selectedTower and not selectedTower.Parent then
		clearTowerSelection()
	end
	if not ghost then
		return
	end
	if not inTest() then
		selectUnit(nil)
		return
	end
	local ray
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled and lastTouch then
		ray = screenRay(lastTouch, false)
	else
		ray = screenRay(UserInputService:GetMouseLocation(), true)
	end
	local position = groundHit(ray)
	if not position then
		ghost.Parent = nil
		if ghostRing then
			ghostRing.Parent = nil
		end
		return
	end
	ghost.Parent = workspace.CurrentCamera
	ghost:PivotTo(CFrame.new(position + Vector3.new(0, ghostLift, 0)))
	local reason = placementReason(position)
	local color = if reason then COLOR_BAD else COLOR_OK
	if ghostHighlight then
		ghostHighlight.FillColor = color
		ghostHighlight.OutlineColor = color
	end
	if ghostRing then
		ghostRing.Parent = workspace.CurrentCamera
		ghostRing.Color = color
		placeRing(ghostRing, position, UnitUpgradeConfig:GetRange(selectedUnit, 0))
	end
end)

-- HUD -------------------------------------------------------------------------------------

local function buildHotbar(list)
	for _, child in hotbar:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	table.clear(hotbarCards)
	for index, name in list or {} do
		local card, button = makeCard(name, hotbar, index)
		hotbarCards[name] = card
		local face = card:FindFirstChild("Card")
		local count = face and face:FindFirstChild("Count")
		if count then
			count.Visible = true
		end
		button.Activated:Connect(function()
			selectUnit(name)
		end)
	end
end

local function sameList(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local currentHotbar = {}

local function updateHud(stats)
	cashLabel.Text = "$" .. tostring(stats.cash or 0)
	baseLabel.Text = "HP " .. tostring(stats.baseHealth or 0)
	if (stats.maxWaves or 0) > 0 then
		waveNumber.Text = string.format("%d/%d", stats.wave or 0, stats.maxWaves)
	else
		waveNumber.Text = tostring(stats.wave or 0)
	end

	local phase = stats.phase
	local finalReached = (stats.maxWaves or 0) > 0 and (stats.wave or 0) >= stats.maxWaves
	local label, countdown, enabled = "NEXT WAVE", "", true
	if phase == "Ready" then
		label = "START WAVE"
	elseif phase == "Intermission" then
		countdown = if (stats.nextIn or 0) > 0 then string.format("IN %ds", stats.nextIn) else ""
	elseif phase == "Wave" and finalReached then
		label, enabled = "LAST WAVE", false
	elseif phase == "Won" then
		label, enabled = "VICTORY", false
	elseif phase == "Lost" then
		label, enabled = "DEFEAT", false
	end
	nextWaveLabel.Text = label
	nextWaveCountdown.Text = countdown
	nextWaveButton.ImageColor3 = if enabled then NEXT_WAVE_COLOR else COLOR_IDLE
	nextWaveButton.Active = enabled

	local list = stats.loadout or {}
	if not sameList(list, currentHotbar) then
		currentHotbar = table.clone(list)
		buildHotbar(list)
	end
	local placed = stats.placed or {}
	for name, card in hotbarCards do
		local face = card:FindFirstChild("Card")
		if face then
			local cost = face:FindFirstChild("Cost")
			if cost then
				cost.TextColor3 = if (stats.cash or 0) >= unitCost(name) then Color3.new(1, 1, 1) else COLOR_BAD
			end
			local count = face:FindFirstChild("Count")
			local countLabel = count and count:FindFirstChild("Count")
			if countLabel then
				countLabel.Text = tostring(placed[name] or 0) .. "x"
			end
		end
	end

	if selectedTower then
		refreshCard()
	end
end

nextWaveButton.Activated:Connect(function()
	if busy or not nextWaveButton.Active then
		return
	end
	busy = true
	request("PlaytestWave")
	busy = false
end)

local function closeAll()
	selectUnit(nil)
	clearTowerSelection()
	setup.Visible = false
	hud.Visible = false
	lastStats = nil
	currentHotbar = {}
	buildHotbar({})
end

Push.OnClientEvent:Connect(function(kind, data)
	if kind ~= "Playtest" or typeof(data) ~= "table" then
		return
	end
	if data.state == "Stopped" then
		closeAll()
		return
	end
	lastStats = data
	if data.phase == "Setup" then
		if not setup.Visible then
			openSetup()
		end
		return
	end
	setup.Visible = false
	hud.Visible = true
	updateHud(data)
end)