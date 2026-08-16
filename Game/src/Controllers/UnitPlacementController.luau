local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Classes = Shared:WaitForChild("Classes")

local UIAssets = Assets:WaitForChild("UI")

local Units = Assets:WaitForChild("Units")

local UnitClass = require(Classes.Unit)

local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()
local Player = Players.LocalPlayer

local LERP_SPEED = 14
local VALID_COLOR = Color3.fromRGB(0, 255, 0)
local INVALID_COLOR = Color3.fromRGB(255, 0, 0)
local COLOR_LERP_SPEED = 10

local TILT_MAX = math.rad(16)
local TILT_PER_STUD = 0.08
local TILT_LERP_SPEED = 10

local RING_SPIN_SPEED = 40
local DOTTED_LINE_SPIN_SPEED = 25
local SELECT_SCALE = 1.3

-- Como o caminho fica marcado enquanto o jogador posiciona uma unidade.
local GRID_PREVIEW_COLOR = Color3.fromRGB(255, 0, 0)
local GRID_PREVIEW_MATERIAL = Enum.Material.Neon

--[[
	A entrada e em cascata, e o que se configura e o TEMPO TOTAL dela — nao o
	intervalo entre parts. O intervalo sai da divisao pela quantidade de parts do
	mapa carregado, entao a animacao dura o mesmo no Default (5 parts) e no
	Mountain (206), em vez de esticar de 0.25s para 10s conforme o mapa.

	GRID_PAINT_TOTAL_TIME conta do inicio ate a ultima part terminar de ficar
	vermelha, ou seja, ja inclui o tween final.
]]
local GRID_PAINT_TOTAL_TIME = 0.75
local GRID_PAINT_TIME = 0.25

local function getPaintStagger(count : number)
	if count <= 1 then
		return 0
	end
	return math.max(0, GRID_PAINT_TOTAL_TIME - GRID_PAINT_TIME) / (count - 1)
end

--[[
	Aparencia original das parts do caminho, guardada na primeira vez que cada uma
	e pintada e devolvida quando o posicionamento acaba.

	Chaves fracas: o mapa pode ser trocado entre rounds, e as parts do mapa antigo
	nao devem ficar presas aqui.
]]
local gridOriginals = setmetatable({}, { __mode = "k" })

local cachedGridParts = nil

local function invalidateGridParts()
	cachedGridParts = nil
end

--[[
	Parts do caminho do mapa que esta carregado, e so dele.

	O escopo e o clone que o MapService coloca em `workspace.Map`. `GetTagged("Grid")`
	sozinho devolve tambem as parts dos outros mapas, que seguem em
	ReplicatedStorage — hoje sao mais de 500 no total, de cinco mapas.

	O resultado e calculado uma vez por mapa e reaproveitado em todo
	posicionamento; o cache cai no RoundRestarted, quando o mapa pode ter mudado.
]]
local function getWorldGridParts()
	if cachedGridParts then
		return cachedGridParts
	end

	local mapRoot = workspace:FindFirstChild("Map")

	local parts = {}
	for _, part in CollectionService:GetTagged("Grid") do
		if part:IsA("BasePart") and part:IsDescendantOf(mapRoot or workspace) then
			table.insert(parts, part)
		end
	end

	-- Sem o mapa em workspace a lista pode estar incompleta (replicacao a caminho),
	-- entao ela nao e guardada — senao um vazio ficaria congelado para sempre.
	if mapRoot then
		cachedGridParts = parts
	end

	return parts
end

-- Cascata em andamento e os tweens de cor vivos, para poder cortar os dois na
-- hora em que o jogador larga a unidade.
local gridPaintThread = nil
local gridTweens = {}

local function stopGridPaint()
	if gridPaintThread then
		pcall(task.cancel, gridPaintThread)
		gridPaintThread = nil
	end

	for part, tween in gridTweens do
		tween:Cancel()
		gridTweens[part] = nil
	end
end

-- Acende uma part: Material de uma vez, cor por tween.
local function paintOneGridPart(part)
	if not part.Parent then
		return
	end

	-- Capturado no momento em que a part entra: quem a cascata ainda nao
	-- alcancou continua intocado e sem snapshot.
	if not gridOriginals[part] then
		gridOriginals[part] = { material = part.Material, color = part.Color }
	end

	part.Material = GRID_PREVIEW_MATERIAL

	local tween = TweenService:Create(
		part,
		TweenInfo.new(GRID_PAINT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Color = GRID_PREVIEW_COLOR }
	)

	gridTweens[part] = tween
	tween.Completed:Once(function()
		if gridTweens[part] == tween then
			gridTweens[part] = nil
		end
	end)
	tween:Play()
end

--[[
	Acende o caminho em cascata: cada part troca para Neon e puxa a cor ate o
	vermelho por tween, escalonadas para caber em GRID_PAINT_TOTAL_TIME.

	O avanco e por tempo decorrido, e nao um `task.wait(intervalo)` por part. Com
	107 parts em 0.75s o intervalo da ~0.005s, bem abaixo de um frame — e
	`task.wait` sempre gasta um frame inteiro, o que faria a cascata levar 107
	frames (~1.8s) em vez dos 0.75s pedidos. Aqui cada frame pinta todas as parts
	cujo horario ja chegou, o que tambem e o que produz a sensacao de batch.

	O Material nao da para interpolar (e enum), entao ele troca de uma vez no
	instante em que a part entra — e isso que a faz "acender". So a cor anda.
]]
local function paintGridParts(parts)
	stopGridPaint()

	local total = #parts
	if total == 0 then
		return
	end

	local stagger = getPaintStagger(total)

	gridPaintThread = task.spawn(function()
		local startedAt = os.clock()
		local nextIndex = 1

		while nextIndex <= total do
			local elapsed = os.clock() - startedAt

			while nextIndex <= total and (nextIndex - 1) * stagger <= elapsed do
				paintOneGridPart(parts[nextIndex])
				nextIndex += 1
			end

			if nextIndex <= total then
				RunService.Heartbeat:Wait()
			end
		end

		gridPaintThread = nil
	end)
end

--[[
	Volta tudo de uma vez, sem tween.

	A cascata e os tweens de cor sao cortados primeiro: um tween sobrevivente
	continuaria escrevendo Color depois da restauracao e deixaria a part vermelha.
]]
local function restoreGridParts(parts)
	stopGridPaint()

	for _, part in parts do
		local original = gridOriginals[part]
		if original then
			if part.Parent then
				part.Material = original.material
				part.Color = original.color
			end
			gridOriginals[part] = nil
		end
	end
end

local TILT_MAX = math.rad(16)
local TILT_PER_STUD = 0.08
local TILT_LERP_SPEED = 10

local function setDottedLineVisible(dottedLine, visible)
	if not dottedLine then return end
	for _, child in dottedLine:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "BlueCircle" then
			child.Transparency = visible and 0 or 1
		end
		if child.Name == "BlueCircle" then
			local gui = child:FindFirstChild("SurfaceGUI")
			if gui then
				local star = gui:FindFirstChild("Star")
				if star then star.Visible = visible end
			end
		end
	end
end

local function tweenRingOut(ring)
	if not ring or not ring.Parent then return end
	local currentScale = ring:GetScale()
	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = currentScale
	scaleVal.Changed:Connect(function(v)
		if ring and ring.Parent then ring:ScaleTo(v) end
	end)
	local tween = TweenService:Create(
		scaleVal,
		TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Value = 0.001 }
	)
	tween:Play()
	tween.Completed:Connect(function()
		scaleVal:Destroy()
		if ring and ring.Parent then ring:Destroy() end
	end)
end

local function raycastGroundY(position : Vector3, excludeInstances : {Instance}?)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList = table.clone(CollectionService:GetTagged("Grid"))
	if excludeInstances then
		for _, inst in excludeInstances do
			table.insert(excludeList, inst)
		end
	end
	raycastParams.FilterDescendantsInstances = excludeList

	local origin = Vector3.new(position.X, position.Y + 300, position.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -1000, 0), raycastParams)
	if result then
		return result.Position.Y
	end

	return nil
end

local UnitPlacementController = {
	Controllers = {
		TargetingController = {},
		UILibraryController = {},
		CardController = {},
		VFXController = {},
		MobController = {},
		MusicController = {}
	},
	selectedUnit = nil,
	selectionHighlight = nil,
	selectionData = nil
}
UnitPlacementController.createdClasses = {}
UnitPlacementController.classesById = {}
UnitPlacementController.unitDottedLines = {}
UnitPlacementController.dottedLineData = {}
UnitPlacementController.scaleTweens = {}
UnitPlacementController.isPlacing = false

function UnitPlacementController:getGroundExcludeList(extra)
	local list = {}
	for unitModel, _ in pairs(self.createdClasses) do
		table.insert(list, unitModel)
	end
	if extra then
		for _, inst in extra do
			table.insert(list, inst)
		end
	end
	return list
end

function UnitPlacementController:tweenUnitScale(unitModel, targetScale, easingDirection)
	local existing = self.scaleTweens[unitModel]
	if existing then
		existing.tween:Cancel()
		existing.value:Destroy()
		self.scaleTweens[unitModel] = nil
	end

	if not unitModel or not unitModel.Parent then return end

	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = unitModel:GetScale()
	scaleVal.Changed:Connect(function(v)
		if unitModel and unitModel.Parent then unitModel:ScaleTo(v) end
	end)

	local tween = TweenService:Create(scaleVal, TweenInfo.new(0.18, Enum.EasingStyle.Back, easingDirection), { Value = targetScale })
	self.scaleTweens[unitModel] = { tween = tween, value = scaleVal }
	tween.Completed:Connect(function()
		local current = self.scaleTweens[unitModel]
		if current and current.tween == tween then
			self.scaleTweens[unitModel] = nil
		end
		scaleVal:Destroy()
	end)
	tween:Play()
end

function UnitPlacementController:deselectCurrent()
	if self.selectedUnit and self.selectedOriginalScale and self.selectedUnit.Parent then
		self:tweenUnitScale(self.selectedUnit, self.selectedOriginalScale, Enum.EasingDirection.In)
	end
	self.selectedOriginalScale = nil

	if self.selectionHighlight then
		self.selectionHighlight:Destroy()
		self.selectionHighlight = nil
	end

	if self.selectionRingTween then
		self.selectionRingTween.tween:Cancel()
		self.selectionRingTween.value:Destroy()
		self.selectionRingTween = nil
	end
	self.selectionRing = nil
	self.selectionRingBase = nil

	if self.ringSpinConn then
		self.ringSpinConn:Disconnect()
		self.ringSpinConn = nil
	end

	if self.dottedLineSpinConn then
		self.dottedLineSpinConn:Disconnect()
		self.dottedLineSpinConn = nil
	end

	if self.AOE then
		for _, inst in self.AOE do
			tweenRingOut(inst)
		end
		table.clear(self.AOE)
	end

	if self.selectedUnit then
		local dottedLine = self.unitDottedLines[self.selectedUnit]
		setDottedLineVisible(dottedLine, false)
	end

	self.selectedUnit = nil

	self.Controllers.UILibraryController:doComponent("ToggleTower", "destroy")
end

function UnitPlacementController:tweenSelectionRing(targetScale)
	local ring = self.selectionRing
	if not ring or not ring.Parent then return end

	if self.selectionRingTween then
		self.selectionRingTween.tween:Cancel()
		self.selectionRingTween.value:Destroy()
		self.selectionRingTween = nil
	end

	local scaleVal = Instance.new("NumberValue")
	scaleVal.Value = ring:GetScale()
	scaleVal.Changed:Connect(function(v)
		if ring and ring.Parent then ring:ScaleTo(v) end
	end)

	local tween = TweenService:Create(scaleVal, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = targetScale })
	self.selectionRingTween = { tween = tween, value = scaleVal }
	tween.Completed:Connect(function()
		local current = self.selectionRingTween
		if current and current.tween == tween then
			self.selectionRingTween = nil
		end
		scaleVal:Destroy()
	end)
	tween:Play()
end

function UnitPlacementController:selectUnit(unitModel)
	if self.selectedUnit == unitModel then
		self:deselectCurrent()
		return
	end

	self:deselectCurrent()

	self.selectedUnit = unitModel

	local baseScale = unitModel:GetAttribute("BaseScale")
	if not baseScale then
		baseScale = unitModel:GetScale()
		unitModel:SetAttribute("BaseScale", baseScale)
	end
	self.selectedOriginalScale = baseScale
	self:tweenUnitScale(unitModel, baseScale * SELECT_SCALE, Enum.EasingDirection.Out)

	local dottedLine = self.unitDottedLines[unitModel]
	setDottedLineVisible(dottedLine, true)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(0, 255, 0)
	highlight.OutlineColor = Color3.fromRGB(0, 255, 0)
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.6
	highlight.Parent = unitModel
	self.selectionHighlight = highlight

	self.Controllers.UILibraryController:doComponent("ToggleTower", "create", unitModel)

	self.AOE = {}

	local unitPos = unitModel:GetPivot().Position
	local groundSurfaceY = raycastGroundY(unitPos, self:getGroundExcludeList({unitModel})) or unitPos.Y

	local Ring = UIAssets.AOE.Ring:Clone()
	local ringPartSel = Ring:FindFirstChild("Renge")
	local targetScale = Ring:GetScale()

	if ringPartSel then
		local upgrades = unitModel:GetAttribute("Upgrades") or 0
		local unitRange = SharedConfig.UnitUpgradeConfig:GetRange(unitModel.Name, upgrades)
		local currentDiameter = ringPartSel.Size.X
		local scaleFactor = (unitRange * 2) / currentDiameter
		targetScale = Ring:GetScale() * scaleFactor
		self.selectionRingBase = { scale = Ring:GetScale(), diameter = currentDiameter }
	end

	Ring:ScaleTo(0.001)
	Ring:PivotTo(CFrame.new(unitPos.X, groundSurfaceY + Ring:GetExtentsSize().Y / 2, unitPos.Z))
	Ring.Parent = workspace.CurrentCamera
	self.selectionRing = Ring

	self:tweenSelectionRing(targetScale)

	local ringYAngle = 0
	self.ringSpinConn = RunService.Heartbeat:Connect(function(dt)
		if not Ring or not Ring.Parent then return end
		ringYAngle = ringYAngle + RING_SPIN_SPEED * dt
		Ring:PivotTo(CFrame.new(unitPos.X, groundSurfaceY + Ring:GetExtentsSize().Y / 2, unitPos.Z) * CFrame.Angles(0, math.rad(ringYAngle), 0))
	end)

	local data = self.dottedLineData[unitModel]
	if dottedLine and data then
		self.dottedLineSpinConn = RunService.Heartbeat:Connect(function(dt)
			if not dottedLine or not dottedLine.Parent then return end
			data.angle += DOTTED_LINE_SPIN_SPEED * dt
			local rot = CFrame.Angles(0, math.rad(data.angle), 0)
			for _, entry in data.dotParts do
				local rotatedOffset = rot * entry.offset
				entry.part.CFrame = CFrame.new(data.centerPos + rotatedOffset) * entry.baseCF * rot
			end
			if data.blueCircle and data.blueCircleCF then
				data.blueCircle.CFrame = data.blueCircleCF
			end
		end)
	end

	table.insert(self.AOE, Ring)

	self.Controllers.MusicController:PlaySFX("SelectSound")
end

function UnitPlacementController:replicatePlacedUnit(unitName : string, CF : CFrame, ownerUserId : number, unitId : string, upgrades : number)
	local unitModel = Units:FindFirstChild(unitName)
	if not unitModel then return end

	local unit = unitModel:Clone()

	for _, descendant in unit:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end

	local humanoid = unit:FindFirstChild("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end

	unit:PivotTo(CF or CFrame.new())
	unit.Parent = workspace

	local boundsCF, boundsSize = unit:GetBoundingBox()
	local bottomY = boundsCF.Position.Y - boundsSize.Y / 2
	local groundSurfaceY = raycastGroundY(boundsCF.Position, self:getGroundExcludeList({unit}))
	if groundSurfaceY then
		local lift = groundSurfaceY - bottomY
		if math.abs(lift) > 0.001 then
			unit:PivotTo((CF or CFrame.new()) + Vector3.new(0, lift, 0))
		end
	else
		groundSurfaceY = bottomY
	end

	local unitPos = unit:GetPivot().Position

	local DottedLine = UIAssets.AOE.DottedLine:Clone()
	local dottedPivot = DottedLine:GetPivot()
	DottedLine:PivotTo(CFrame.new(unitPos.X, groundSurfaceY, unitPos.Z) * dottedPivot.Rotation)
	local blueCircle = DottedLine:FindFirstChild("BlueCircle")
	if blueCircle then
		blueCircle.CFrame = CFrame.new(unitPos.X, groundSurfaceY + blueCircle.Size.X / 2, unitPos.Z) * CFrame.Angles(0, 0, math.pi / 2)
	end
	DottedLine.Parent = workspace.CurrentCamera
	setDottedLineVisible(DottedLine, false)
	self.unitDottedLines[unit] = DottedLine

	local centerPos = Vector3.new(unitPos.X, groundSurfaceY, unitPos.Z)
	local dotParts = {}
	for _, child in DottedLine:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "BlueCircle" then
			local offset = child.CFrame.Position - centerPos
			table.insert(dotParts, { part = child, offset = offset, baseCF = child.CFrame - child.CFrame.Position })
		end
	end
	self.dottedLineData[unit] = {
		angle = 0,
		blueCircleCF = blueCircle and blueCircle.CFrame or nil,
		blueCircle = blueCircle,
		centerPos = centerPos,
		dotParts = dotParts,
	}

	local class = UnitClass.new(unitName, unit)
	class.unitId = unitId
	class.isOwner = ownerUserId == Player.UserId
	class.upgrades = upgrades or 0
	unit:SetAttribute("UnitID", unitId)
	unit:SetAttribute("Upgrades", upgrades or 0)
	unit:SetAttribute("Owned", class.isOwner)
	self.createdClasses[unit] = class
	self.classesById[unitId] = class

	local unitStats = SharedConfig.UnitStats[unitName]
	local skipTargeting = unitStats and (unitStats.Farm ~= nil or unitStats.Tripmine ~= nil)
	if not skipTargeting and self.Controllers.TargetingController and self.Controllers.TargetingController.RegisterUnit then
		self.Controllers.TargetingController:RegisterUnit(class)
	end

	if self.Controllers.VFXController then
		self.Controllers.VFXController:Trigger(unitName, "OnPlace", { unitModel = unit })
	end

	self.Controllers.MusicController:PlaySFX("UnitPlace")
end

function UnitPlacementController:visualize(unitName : string)
	if self.isPlacing then return end
	local unitModel = Units:FindFirstChild(unitName)
	if not unitModel then return end
	self.isPlacing = true

	local maid = Maid.new()
	self._maid = maid
	local ghost = unitModel:Clone()
	local currentRotation = 0
	local currentColor = VALID_COLOR
	local canPlace = false

	local scale = ghost:GetScale()
	ghost:ScaleTo(scale * 0.8)

	for _, descendant in pairs(ghost:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Transparency = 0.5
		end
	end

	local ghostHumanoid = ghost:FindFirstChildOfClass("Humanoid")
	if ghostHumanoid then
		local animator = Instance.new("Animator")
		animator.Parent = ghostHumanoid
		local idleAnim = ghost:FindFirstChild("Idle")
		if idleAnim then
			local track = animator:LoadAnimation(idleAnim)
			track:Play()
		end
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.3
	highlight.FillColor = VALID_COLOR
	highlight.OutlineColor = VALID_COLOR
	highlight.Parent = ghost
	ghost.Parent = workspace

	local unitStats = SharedConfig.UnitStats[unitName]
	local unitRange = unitStats and unitStats.Range or 10
	local ghostBoundsCF, ghostBoundsSize = unitModel:GetBoundingBox()
	local unitSizeX = ghostBoundsSize.X
	local groundSurfaceY = workspace.GroundPart.CFrame.Y + workspace.GroundPart.Size.Y / 2
	local currentGroundY = groundSurfaceY

	local placementRing = UIAssets.AOE.Ring:Clone()
	local ringPart = placementRing:FindFirstChild("Renge")
	if ringPart then
		local currentDiameter = ringPart.Size.X
		local scaleFactor = (unitRange * 2) / currentDiameter
		placementRing:ScaleTo(placementRing:GetScale() * scaleFactor)
	end

	local targetRingScale = placementRing:GetScale()
	placementRing:ScaleTo(0.001)
	placementRing:PivotTo(CFrame.new(0, groundSurfaceY + placementRing:GetExtentsSize().Y / 2, 0))
	placementRing.Parent = workspace.CurrentCamera

	local ringScaleValue = Instance.new("NumberValue")
	ringScaleValue.Value = 0.001
	local ringTween = TweenService:Create(
		ringScaleValue,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Value = targetRingScale }
	)
	ringScaleValue.Changed:Connect(function(v)
		if placementRing and placementRing.Parent then
			placementRing:ScaleTo(v)
		end
	end)
	ringTween:Play()
	ringTween.Completed:Connect(function()
		ringScaleValue:Destroy()
	end)

	-- Nome distinto de proposito: o loop de validacao la embaixo tem o proprio
	-- `gridParts`, que e o resultado de um GetPartsInPart e nao tem relacao.
	local paintedGridParts = getWorldGridParts()
	paintGridParts(paintedGridParts)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local ghostExtentsSize = ghost:GetExtentsSize()
	local halfHeight = ghostExtentsSize.Y / 2

	local gridProbe = Instance.new("Part")
	gridProbe.Size = ghostBoundsSize
	gridProbe.Anchored = true
	gridProbe.CanCollide = false
	gridProbe.CanQuery = false
	gridProbe.CanTouch = false
	gridProbe.Transparency = 1
	gridProbe.Parent = workspace
	maid:GiveTask(gridProbe)

	local ghostCF = ghost:GetPivot()
	local targetCF = ghostCF
	local smoothLean = Vector3.zero


	local overlapCheckElapsed = 0
	local OVERLAP_CHECK_INTERVAL = 0.05

	maid:GiveTask(RunService.RenderStepped:Connect(function(dt)
		local character = Player.Character
		local filterList = {ghost}
		if character then
			table.insert(filterList, character)
		end
		raycastParams.FilterDescendantsInstances = filterList

		local mousePos = UserInputService:GetMouseLocation()
		local mouseRay = workspace.CurrentCamera:ViewportPointToRay(mousePos.X, mousePos.Y)
		local raycastResult = workspace:Raycast(mouseRay.Origin, mouseRay.Direction * 1000, raycastParams)

		if raycastResult then
			local position = raycastResult.Position
			currentGroundY = position.Y
			local placedPosition = Vector3.new(position.X, position.Y + halfHeight, position.Z)

			targetCF = CFrame.new(placedPosition) * CFrame.Angles(0, math.rad(currentRotation), 0)

			overlapCheckElapsed += dt
			if overlapCheckElapsed >= OVERLAP_CHECK_INTERVAL then
				overlapCheckElapsed = 0

				local ghostCFrameNow = CFrame.new(placedPosition) * CFrame.Angles(0, math.rad(currentRotation), 0)
				gridProbe.CFrame = ghostCFrameNow

				local gridOverlapParams = OverlapParams.new()
				gridOverlapParams.FilterType = Enum.RaycastFilterType.Include
				gridOverlapParams.FilterDescendantsInstances = CollectionService:GetTagged("Grid")
				local gridParts = workspace:GetPartsInPart(gridProbe, gridOverlapParams)
				local onGrid = #gridParts > 0

				local isObstructed = false

				if not onGrid then
					local overlapParams = OverlapParams.new()
					overlapParams.FilterType = Enum.RaycastFilterType.Exclude
					overlapParams.FilterDescendantsInstances = filterList
					local parts = workspace:GetPartsInPart(ghost.PrimaryPart or ghost:FindFirstChildWhichIsA("BasePart"), overlapParams)
					for _, part in ipairs(parts) do
						if part ~= raycastResult.Instance then
							isObstructed = true
							break
						end
					end
				end

				if not onGrid and not isObstructed then
					for placedUnit, _ in pairs(self.createdClasses) do
						local placedPos = placedUnit:GetPivot().Position
						local otherTemplate = Units:FindFirstChild(placedUnit.Name)
						local otherSizeX = otherTemplate and select(2, otherTemplate:GetBoundingBox()).X or unitSizeX
						local minDist = (unitSizeX + otherSizeX) / 2
						if (Vector3.new(placedPosition.X, 0, placedPosition.Z) - Vector3.new(placedPos.X, 0, placedPos.Z)).Magnitude < minDist then
							isObstructed = true
							break
						end
					end
				end

				canPlace = not onGrid and not isObstructed
			end
		end

		local targetColor = canPlace and VALID_COLOR or INVALID_COLOR
		currentColor = currentColor:Lerp(targetColor, math.min(1, dt * COLOR_LERP_SPEED))
		highlight.FillColor = currentColor
		highlight.OutlineColor = currentColor

		local alpha = math.min(1, dt * LERP_SPEED)
		ghostCF = ghostCF:Lerp(targetCF, alpha)

		local remaining = targetCF.Position - ghostCF.Position
		local desiredLean = Vector3.new(remaining.X, 0, remaining.Z)
		smoothLean = smoothLean:Lerp(desiredLean, math.min(1, dt * TILT_LERP_SPEED))

		local displayCF = ghostCF
		local leanMagnitude = smoothLean.Magnitude
		if leanMagnitude > 0.001 then
			local tiltAxis = Vector3.yAxis:Cross(smoothLean.Unit)
			if tiltAxis.Magnitude > 0.001 then
				local tiltAngle = math.min(leanMagnitude * TILT_PER_STUD, TILT_MAX)
				displayCF = CFrame.new(ghostCF.Position) * CFrame.fromAxisAngle(tiltAxis.Unit, tiltAngle) * (ghostCF - ghostCF.Position)
			end
		end
		ghost:PivotTo(displayCF)

		local ghostPos = ghostCF.Position
		placementRing:PivotTo(CFrame.new(ghostPos.X, currentGroundY + placementRing:GetExtentsSize().Y / 2, ghostPos.Z))
	end))

	maid:GiveTask(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.KeyCode == Enum.KeyCode.R then
			currentRotation = (currentRotation + 90) % 360
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if canPlace then
				Framework:Fire("PlaceUnit", unitName, ghostCF)

				-- A devolucao da aparencia do caminho fica a cargo do maid, logo
				-- abaixo: um dono so para os dois caminhos de saida.
				placementRing:Destroy()
				ringScaleValue:Destroy()
				self.isPlacing = false
				maid:Destroy()
				ghost:Destroy()

				self.Controllers.CardController:setUnequipState()
			end
		end
	end))

	maid:GiveTask(function()
		restoreGridParts(paintedGridParts)
		if placementRing and placementRing.Parent then
			placementRing:Destroy()
		end
		if ghost and ghost.Parent then
			ghost:Destroy()
		end
		self.isPlacing = false
		self._maid = nil
	end)
end

function UnitPlacementController:unequip()
	if not self.isPlacing then return end
	if self._maid then
		self._maid:Destroy()
		self._maid = nil
	end
end

--[=[
	Larga tudo que o jogador tinha em mao: o fantasma que segue o mouse, a unidade
	selecionada (com anel, linha pontilhada e painel de upgrade) e a carta equipada
	na hotbar.

	O fantasma e um Model no workspace, nao GUI — desligar a Interface no fim do
	round nao o faz sumir, ele continuaria seguindo o mouse por cima da tela de
	resultado. Por isso a limpeza e explicita.
]=]
function UnitPlacementController:clearInteraction()
	self:unequip()
	self:deselectCurrent()

	local cardController = self.Controllers.CardController
	if cardController and cardController.setUnequipState then
		cardController:setUnequipState()
	end
end

function UnitPlacementController:flashUpgrade(unitModel)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(120, 255, 140)
	highlight.OutlineColor = Color3.fromRGB(180, 255, 200)
	highlight.FillTransparency = 0.5
	highlight.OutlineTransparency = 0
	highlight.Parent = unitModel
	TweenService:Create(highlight, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()
	task.delay(0.45, function()
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end)
end

function UnitPlacementController:construct()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if self.isPlacing then return end
			local mouseRay = workspace.CurrentCamera:ViewportPointToRay(UserInputService:GetMouseLocation().X, UserInputService:GetMouseLocation().Y)

			local raycastParams = RaycastParams.new()
			raycastParams.FilterType = Enum.RaycastFilterType.Exclude
			if Player.Character then
				raycastParams.FilterDescendantsInstances = {Player.Character}
			end

			local raycastResult = workspace:Raycast(mouseRay.Origin, mouseRay.Direction * 1000, raycastParams)

			if raycastResult then
				local hitInstance = raycastResult.Instance
				local foundUnit = nil

				for unitModel, _ in pairs(self.createdClasses) do
					if hitInstance == unitModel or hitInstance:IsDescendantOf(unitModel) then
						foundUnit = unitModel
						break
					end
				end

				if foundUnit then
					self:selectUnit(foundUnit)
				else
					self:deselectCurrent()
				end
			else
				self:deselectCurrent()
			end
		end
	end)

	-- Rede de seguranca: se o round reiniciar sem passar pela tela de resultado,
	-- o jogador nao fica com fantasma nem carta equipada de uma partida que acabou.
	Framework:Listen("RoundRestarted", function()
		self:clearInteraction()
		-- O mapa pode ter mudado; a lista de parts do caminho e remontada no
		-- proximo posicionamento.
		invalidateGridParts()
	end)

	Framework:Listen("RemoveUnit", function(unitId)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				if self.selectedUnit == unitModel then
					self:deselectCurrent()
				end
				local dottedLine = self.unitDottedLines[unitModel]
				if dottedLine then
					dottedLine:Destroy()
					self.unitDottedLines[unitModel] = nil
					self.dottedLineData[unitModel] = nil
				end
				if self.Controllers.TargetingController and self.Controllers.TargetingController.UnregisterUnit then
					self.Controllers.TargetingController:UnregisterUnit(class)
				end
				if class.Destroy then
					class:Destroy()
				end
				self.createdClasses[unitModel] = nil
				self.classesById[unitId] = nil
				unitModel:Destroy()
				break
				end
			end
	end)

	Framework:Listen("UnitUpgraded", function(unitId, newLevel)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				class.upgrades = newLevel
				unitModel:SetAttribute("Upgrades", newLevel)
				self:flashUpgrade(unitModel)

				if self.selectedUnit == unitModel and self.selectionRing and self.selectionRing.Parent and self.selectionRingBase then
					local newRange = SharedConfig.UnitUpgradeConfig:GetRange(unitModel.Name, newLevel)
					local newScale = self.selectionRingBase.scale * (newRange * 2) / self.selectionRingBase.diameter
					self:tweenSelectionRing(newScale)
				end

				self.Controllers.MusicController:PlaySFX("UnitUpgrade")
				break
			end
		end
	end)

	Framework:Listen("ReplicateUnit", function(...)
		return self:replicatePlacedUnit(...)
	end)

	Framework:Listen("UnitSwing", function(unitId, unitName, targetMobId, stepIndex)
		local class = self.classesById[unitId]
		if not class then return end
		local mobController = self.Controllers.MobController
		local target = mobController and mobController.SpawnedMobs and mobController.SpawnedMobs[targetMobId] or nil
		class:playAttackVisual(target, stepIndex)
	end)

	Framework:Listen("FarmPayout", function(unitId, amount)
		local class = self.classesById[unitId]
		if not class or not class.playFarmVisual then return end
		class:playFarmVisual()
	end)

	Framework:Listen("UnitStunned", function(unitId, duration)
		for unitModel, class in pairs(self.createdClasses) do
			if class and class.unitId == unitId then
				local highlight = Instance.new("Highlight")
				highlight.FillColor = Color3.fromRGB(255, 200, 60)
				highlight.OutlineColor = Color3.fromRGB(255, 200, 60)
				highlight.FillTransparency = 0.6
				highlight.OutlineTransparency = 0.2
				highlight.Parent = unitModel

				task.delay(duration, function()
					if highlight and highlight.Parent then
						highlight:Destroy()
					end
				end)
				break
			end
		end
	end)
end



function UnitPlacementController:start()
end

function UnitPlacementController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return UnitPlacementController
