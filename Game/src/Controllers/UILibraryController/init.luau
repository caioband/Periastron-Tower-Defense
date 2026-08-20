local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Utils = Shared:WaitForChild("Util")

local Spring = require(Vendor.Spring)
local Observers = require(Vendor.Observers)
local PointerUtil = require(Utils.PointerUtil)

local Camera = workspace.CurrentCamera

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)

local Frames = Interface:WaitForChild("Frames")

local OpeningSequence = require(script:WaitForChild("Opening"))

local UILibraryController = {}

function UILibraryController:closeFrame(FrameName : string)
	local FrameData = self.Frames[FrameName]

	if not FrameData then
		warn("Frame not found", FrameName)
		return
	end

	task.spawn(function()
		for _, Child : GuiButton in FrameData.Frame:GetDescendants() do
			if Child:IsA("GuiButton") and Child:HasTag("AnimatedButton") then
				Child:RemoveTag("AnimatedButton")
			end
		end
	end)

	local closingDelay = FrameData.CloseAnimation(FrameData.Frame)
	if closingDelay ~= nil then
		UILibraryController.scheduledDestroyDelay = closingDelay
	end
	local mainCode = script.Frames:FindFirstChild(FrameName)
	if not mainCode then
		return
	end

	local Functionality = require(mainCode)
	if Functionality and Functionality.destroy then
		Functionality:destroy()
	end

	-- Revert HUD Animation
	local TweenService = game:GetService("TweenService")
	local ti = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local function RevertHud(inst)
		if inst and inst:GetAttribute("OgPos") then
			TweenService:Create(inst, ti, {Position = inst:GetAttribute("OgPos")}):Play()
		end
	end

	RevertHud(Interface.HUD:FindFirstChild("Shop"))
	RevertHud(Interface.HUD:FindFirstChild("Rebirth"))
	RevertHud(Interface.HUD:FindFirstChild("Daily"))
	RevertHud(Interface.HUD:FindFirstChild("CashDisplay"))

	local Top = Interface.HUD:FindFirstChild("Top")
	if Top then
		for _, child in Top:GetChildren() do
			if child:IsA("GuiObject") then
				RevertHud(child)
			end
		end
	end

	return
end

function UILibraryController:doComponent(name : string, func : string, ...)
	local component = script.Components:FindFirstChild(name)

	if not component then
		print("did not find any component with name", name)
		return
	end

	local requiredComponent = require(component)
	if requiredComponent[func] then
		task.spawn(requiredComponent[func], requiredComponent, ...)
	end

	return true
end

function UILibraryController:loadFrames()
	self.Frames = {}

	for _, Frame : Frame in Frames:GetChildren() do
		if not Frame:IsA("Frame") and not Frame:IsA("ImageLabel") then continue end
		local Name =  Frame.Name
		local Data = OpeningSequence[Name] or {}

		local Opening = Data.OpeningAnimation or function() end
		local Closing = Data.ClosingAnimation or function() end
		self.Frames[Name] = {
			Frame = Frame,
			OpenAnimation = Opening,
			CloseAnimation = Closing,
		}
		Frame.Visible = false

		-- Use existing logic: Find the Close button dynamically

		for _, Close : GuiButton in Frame:GetDescendants() do
			if Close:IsA("GuiButton") and Close.Name == "Close" then
				UILibraryController.addHoverAnimation(Close)
				UILibraryController.addClickAnimation(Close, function()
					if self.globalOpenFrame == Name then
						self:openFrame(Name) -- Natively toggles it closed, resetting camera and blur
					end
				end)

				-- Tag it so it doesn't get double animations from the global sweep in openFrame
				Close:AddTag("AnimatedButton")
			end
		end
	end
end

function UILibraryController.addHoverAnimation(Button : GuiButton)
	local conn = {}

	--[[
		Hover nao existe no toque: o dedo ou esta apertando ou nao esta na tela, nao
		ha um estado "pairando por cima". Pior, o Roblox as vezes dispara o MouseEnter
		no comeco do toque sem o MouseLeave correspondente, e o botao ficaria crescido
		para sempre. No celular o botao simplesmente nao reage a hover.
	]]
	if PointerUtil.isTouchOnly() then
		return conn
	end

	local UIScale = Button:FindFirstChildOfClass("UIScale")
	if not UIScale then
		UIScale = Instance.new("UIScale")
		UIScale.Parent = Button
	end

	local canRotate = Button:HasTag("Wiggly")

	local Vector = Button:FindFirstChild("Vector")
	local defaultPos
	local defaultRot = 0
	local newPos

	local frame = Button:FindFirstChild("Frame")
	if frame then
		defaultPos = frame.Position
		defaultRot = frame.Rotation
		newPos = UDim2.fromScale(defaultPos.X.Scale, defaultPos.Y.Scale - .1)
	end

	table.insert(conn, Button.MouseEnter:Connect(function()
		Spring.target(UIScale, .65, 4, {
			Scale = 1.08
		})
		if Vector then
			Spring.target(Vector, .65, 4, {
				Rotation = 12
			})
		end

		if canRotate and frame then

			Spring.target(frame, .65, 4, {
				Rotation = defaultRot + 2
			})

			Spring.target(frame, .65, 4, {
				Position = newPos
			})

		end

	--	require(Vendor.Me).new():Get("MusicController"):PlaySFX("UIHover")   -- falta o UIHover em SharedSounds.SFX
	end))
	table.insert(conn, Button.MouseLeave:Connect(function()
		Spring.target(UIScale, .65, 4, {
			Scale = 1
		})

		if canRotate and frame then
			Spring.target(frame, .65, 4, {
				Rotation = defaultRot
			})

			Spring.target(frame, .65, 4, {
				Position = defaultPos
			})
		end

		if Vector then
			Spring.target(Vector, .65, 4, {
				Rotation = 0
			})
		end
	end))

	return conn
end

function UILibraryController.addClickAnimation(Button : GuiButton, clickCallback : () -> ()?)
	local Vector = Button:FindFirstChild("Vector")
	local conn = {}
	local UIScale = Button:FindFirstChildOfClass("UIScale")
	if not UIScale then
		UIScale = Instance.new("UIScale")
		UIScale.Parent = Button
	end
	local function pressVisual()
		Spring.target(UIScale, .65, 4, {
			Scale = .95
		})

		if Vector then
			Spring.target(Vector, .65, 4, {
				Rotation = -8
			})
		end
	end

	local function releaseVisual()
		Spring.target(UIScale, .65, 4, {
			Scale = 1
		})

		if Vector then
			Spring.target(Vector, .65, 4, {
				Rotation = 0
			})
		end
	end

	--[[
		O botao afunda no aperto e volta no soltar, mas soltar nem sempre passa pelo
		botao: no toque, se o dedo escorrega para fora antes de sair, o
		`MouseButton1Up` nunca chega e o botao ficaria encolhido para sempre.

		Por isso a volta e vigiada pelo UserInputService, que ve o dedo sair de
		qualquer lugar da tela.
	]]
	local releaseWatcher : RBXScriptConnection? = nil

	local function stopWatchingRelease()
		if releaseWatcher then
			releaseWatcher:Disconnect()
			releaseWatcher = nil
		end
	end

	table.insert(conn, Button.MouseButton1Down:Connect(function()
		pressVisual()

		stopWatchingRelease()
		releaseWatcher = UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			stopWatchingRelease()
			releaseVisual()
		end)
	end))

	--[[
		A acao sai do `Activated`, que e o unico evento que o Roblox garante tanto no
		clique quanto no toque -- e so quando o dedo/cursor sai de fato em cima do
		botao, entao arrastar para fora continua sendo desistir.
	]]
	table.insert(conn, Button.Activated:Connect(function()
		stopWatchingRelease()
		releaseVisual()

		if clickCallback ~= nil then
			clickCallback()
		end

		--require(Vendor.Me).new():Get("MusicController"):PlaySFX("UIClick")   -- falta o UIClick em SharedSounds.SFX
	end))

	-- Quem recebe essa lista desliga tudo chamando `:Disconnect()` em cada item, e
	-- o vigia de soltura pode estar vivo na hora em que o botao morre.
	table.insert(conn, { Disconnect = stopWatchingRelease })

	return conn
end

function UILibraryController:connectHud()
	for _, Button : ImageButton in Interface.HUD:GetDescendants() do
		if Button:IsA("GuiButton") then
			UILibraryController.addHoverAnimation(Button)
			UILibraryController.addClickAnimation(Button, function()
				if Button:HasTag("Ignore") then return end
				local Name = Button.Name

				if self.Frames[Name] ~= nil then
					self:openFrame(Name)
				end
			end)
		end
	end

	local TweenService = game:GetService("TweenService")

	-- Pulsing size effect for Shop Alert
	local ShopBtn = Interface.HUD:FindFirstChild("Shop")
	if ShopBtn then
		local Alert = ShopBtn:FindFirstChild("Alert")
		if Alert then
			local UIScale = Alert:FindFirstChildOfClass("UIScale")
			if not UIScale then
				UIScale = Instance.new("UIScale")
				UIScale.Parent = Alert
			end
			local pulseInfo = TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			TweenService:Create(UIScale, pulseInfo, {Scale = 1.2}):Play()
		end
	end

	-- Floating/Spinning effect for HUD Vectors
	local function animateHudVector(parentBtn)
		if not parentBtn then return end
		local vector = parentBtn:FindFirstChild("Vector")
		if not vector then return end

		local originalPos = vector.Position
		local bobTween, rotTween

		local function startTweens()
			if bobTween then bobTween:Cancel() end
			if rotTween then rotTween:Cancel() end

			local bobInfo = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			bobTween = TweenService:Create(vector, bobInfo, {
				Position = originalPos - UDim2.new(0, 0, 0.1, 0)
			})
			bobTween:Play()

			local rotInfo = TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			-- Start from current rotation (which should be -3 at this point)
			rotTween = TweenService:Create(vector, rotInfo, {
				Rotation = 3
			})
			rotTween:Play()
		end

		vector.Rotation = -3
		startTweens()

		local isHovering = false
		parentBtn.MouseEnter:Connect(function()
			isHovering = true
			if bobTween then bobTween:Cancel() end
			if rotTween then rotTween:Cancel() end
		end)

		parentBtn.MouseLeave:Connect(function()
			isHovering = false
			-- Wait for Spring to settle back to 0
			task.delay(0.6, function()
				if not isHovering then
					-- Smoothly transition into the idle starting position (-3)
					local transitionTw = TweenService:Create(vector, TweenInfo.new(0.5, Enum.EasingStyle.Sine), {
						Rotation = -3,
						Position = originalPos
					})
					transitionTw:Play()
					transitionTw.Completed:Once(function()
						if not isHovering then
							startTweens()
						end
					end)
				end
			end)
		end)
	end

	animateHudVector(Interface.HUD:FindFirstChild("Shop"))
	animateHudVector(Interface.HUD:FindFirstChild("Daily"))
	animateHudVector(Interface.HUD:FindFirstChild("Rebirth"))
end

function UILibraryController:messWithBlur(size : number)
	local UIBlur = game.Lighting:FindFirstChild("UIBlur")
	if not UIBlur then
		UIBlur = Instance.new("BlurEffect")
		UIBlur.Name = "UIBlur"
		UIBlur.Size = 0
		UIBlur.Parent = game.Lighting
	end

	Spring.target(UIBlur, .65, 4, {
		Size = size
	})
	return true
end

function UILibraryController:openFrame(FrameName : string)
	local FrameData = self.Frames[FrameName]

	if not FrameData then
		warn("Frame not found", FrameName)
		return
	end

	if self.globalOpenFrame == FrameName then
		self:closeFrame(FrameName)
		self.globalOpenFrame = nil

		Spring.target(Camera, .65, 3, {
			FieldOfView = 70
		})

		self:messWithBlur(0)

		return
	end

	if self.globalOpenFrame ~= nil and self.globalOpenFrame ~= FrameName then
		self:closeFrame(self.globalOpenFrame)
	end

	self:messWithBlur(20)

	if self.scheduledDestroyDelay ~= nil then

		local success, err = pcall(function()
			task.cancel(self.scheduledDestroyDelay)
		end)
		self.scheduledDestroyDelay = nil
	end

	Spring.target(Camera, .65, 3, {
		FieldOfView = 50
	})

	self.globalOpenFrame = FrameName

	FrameData.OpenAnimation(FrameData.Frame)
	FrameData.Frame.Visible = true
	task.spawn(function()
		for _, Child : Frame in FrameData.Frame:GetDescendants() do
			if Child:IsA("GuiButton") and not Child:HasTag("AnimatedButton") then
				Child:AddTag("AnimatedButton")
			end
		end
	end)

	local mainCode = script.Frames:FindFirstChild(FrameName)
	if not mainCode then
		return
	end
	local Functionality = require(mainCode)
	if Functionality and Functionality.assign then
		Functionality:assign(FrameData.Frame)
	end

	-- HUD Off-screen Animation
	local TweenService = game:GetService("TweenService")
	local ti = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local function TweenOffscreen(inst, targetPos)
		if not inst then return end
		if not inst:GetAttribute("OgPos") then
			inst:SetAttribute("OgPos", inst.Position)
		end
		TweenService:Create(inst, ti, {Position = targetPos}):Play()
	end

	local Shop = Interface.HUD:FindFirstChild("Shop")
	if Shop then TweenOffscreen(Shop, UDim2.new(-0.5, 0, Shop.Position.Y.Scale, Shop.Position.Y.Offset)) end

	local Rebirth = Interface.HUD:FindFirstChild("Rebirth")
	if Rebirth then TweenOffscreen(Rebirth, UDim2.new(1.5, 0, Rebirth.Position.Y.Scale, Rebirth.Position.Y.Offset)) end

	local Daily = Interface.HUD:FindFirstChild("Daily")
	if Daily then TweenOffscreen(Daily, UDim2.new(1.5, 0, Daily.Position.Y.Scale, Daily.Position.Y.Offset)) end

	local CashDisplay = Interface.HUD:FindFirstChild("CashDisplay")
	if CashDisplay then TweenOffscreen(CashDisplay, UDim2.new(CashDisplay.Position.X.Scale, CashDisplay.Position.X.Offset, 1.5, 0)) end

	local Top = Interface.HUD:FindFirstChild("Top")
	if Top then
		for _, child in Top:GetChildren() do
			if child:IsA("GuiObject") then
				TweenOffscreen(child, UDim2.new(child.Position.X.Scale, child.Position.X.Offset, -0.5, 0))
			end
		end
	end

	return
end

function UILibraryController:connectZones()
	task.spawn(function()
		local Environment = workspace:WaitForChild("Environment", 10)
		if not Environment then return end

		local Middle = Environment:WaitForChild("Middle", 10)
		if not Middle then return end

		local function bindZone(child, mainPart)
			local frameName = child.Name

			local function isCharacterPart(part)
				local character = Player.Character
				return character and part:IsDescendantOf(character)
			end

			mainPart.Touched:Connect(function(hit)
				if not isCharacterPart(hit) then return end
				if self.globalOpenFrame ~= frameName and self.Frames[frameName] then
					self:openFrame(frameName)
				end
			end)
		end

		local function setupZone(child)
			local mainPart = child:FindFirstChild("Main", true)

			if mainPart and mainPart:IsA("BasePart") then
				bindZone(child, mainPart)
			else
				local conn
				conn = child.DescendantAdded:Connect(function(desc)
					if desc.Name == "Main" and desc:IsA("BasePart") then
						conn:Disconnect()
						bindZone(child, desc)
					end
				end)
			end
		end

		for _, child in Middle:GetChildren() do
			setupZone(child)
		end

		Middle.ChildAdded:Connect(setupZone)
	end)
end

function UILibraryController:start()
	self:connectZones()
end

function UILibraryController:init()
	self:loadFrames()
--	self:connectHud()
	Observers.observeTag("AnimatedButton", function(Inst)
		local hoverConnections = UILibraryController.addHoverAnimation(Inst)
		local clickConnections = UILibraryController.addClickAnimation(Inst)
		return function()
			for _, v in hoverConnections do
				v:Disconnect()
			end
			for _, v in clickConnections do
				v:Disconnect()
			end

			hoverConnections = nil
			clickConnections = nil
		end
	end)

	Observers.observeTag("GlowEffect", function(Inst)

		local function DoEffect()
			local Tween = game:GetService("TweenService"):Create(Inst, TweenInfo.new(1.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In), {
				Offset = Vector2.new(.4,0)
			})

			Tween:Play()

			Tween.Completed:Once(function()
				local TweenBack = game:GetService("TweenService"):Create(Inst, TweenInfo.new(1.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In), {
					Offset = Vector2.new(0,0)
				})

				TweenBack:Play()
				TweenBack.Completed:Once(function()
					return DoEffect()
				end)
			end)
		end

		DoEffect()

		return function()

		end
	end)

	local TweenService = game:GetService("TweenService")
	local RunService = game:GetService("RunService")
	local DISTANCE_THRESHOLD = 75
	local DISTANCE_CHECK_INTERVAL = 0.15
	local distanceTi = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		local cashCounter = Interface:FindFirstChild("CashCounter")
	local cashLabel = cashCounter and cashCounter:FindFirstChild("TextLabel")

	if cashLabel then
		local function abbreviate(n)
			if n >= 1e9 then
				return string.format("$%.1fB", n / 1e9)
			elseif n >= 1e6 then
				return string.format("$%.1fM", n / 1e6)
			elseif n >= 1e3 then
				return string.format("$%.1fK", n / 1e3)
			else
				return "$" .. math.floor(n)
			end
		end

		local Me2 = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Vendor"):WaitForChild("Me"))
		local Framework2 = Me2.new()
		Framework2:Listen("UpdateCash", function(amount)
			cashLabel.Text = abbreviate(amount)
		end)
		Framework2:Fire("RequestCash")
	end
end

return UILibraryController
