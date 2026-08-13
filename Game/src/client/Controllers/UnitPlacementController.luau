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
		MobController = {}
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

	game.SoundService.SelectSound:Play()
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

	game.SoundService.UnitPlace:Play()
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

	local gridHighlights = {}
	for _, part in ipairs(CollectionService:GetTagged("Grid")) do
		local h = Instance.new("Highlight")
		h.FillColor = INVALID_COLOR
		h.OutlineColor = INVALID_COLOR
		h.FillTransparency = 0.35
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Parent = part
		table.insert(gridHighlights, h)
	end

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

				for _, h in (gridHighlights) do
					h:Destroy()
				end

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
		for _, h in ipairs(gridHighlights) do
			h:Destroy()
		end
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

				game.SoundService.UnitUpgrade:Play()
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
