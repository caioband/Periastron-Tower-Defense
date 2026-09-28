local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Signal = require(Packages.Signal)

local PortalConfig = SharedConfig.PortalConfig

local Framework = Me.new()
local log = Log.new("PortalController")

--[[ CONSTANTS ]]
local MAP_FOLDER_NAME = "Map"
local EXIT_UI_NAME = "ExitGroupPortal"
local EXIT_BUTTON_NAME = "Exit"

--[[
	The name of the InterfaceController request: the player joined a group, the countdown
	started, and the screen keeps only the leave button until it reaches zero.

	The request is released when the player leaves the group, not when the countdown hits
	zero. At zero the cutscene takes over, hiding everything (Roblox's interface too);
	keeping this request up underneath it is what stops the whole Lobby from reappearing
	between the end of the scene and the teleport. If the teleport fails, the portal
	returns the group, and that return brings the interface back.

	See docs/common/interface-visibility.md.
]]
local HIDE_REASON = "PortalCountdown"

-- Walking is not a per-frame problem: the check runs on a fixed beat instead.
local CHECK_INTERVAL = 0.15

-- A join the server turned down (the group filled up in the meantime) is not worth
-- retrying every beat.
local JOIN_COOLDOWN = 1

-- The scene goes back to ReplicatedStorage this long after the cutscene ends, so the
-- rigs are not left standing in the middle of the lobby.
local SCENE_LINGER = 0.5

-- The rig inside EnterCutscene that stands in for the player. Anything else in the
-- scene keeps its own look.
local ACTOR_RIG_NAME = "playerportal"

-- The white-out at the end of the scene, and how it is taken back when the teleport
-- falls through and the player stays in the lobby.
local FLASH_UI_NAME = "PortalFlash"
local FLASH_INFO = TweenInfo.new(PortalConfig.FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_OUT_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[=[
	The player's side of the lobby portals.

	Walking up to a free portal opens the map panel; walking up to one that already
	holds a group joins it. The panel and the exit button only ask -- PortalService
	decides, and answers with PortalGroupChanged.

	When the countdown runs out the server says so, and the EnterCutscene asset itself
	(not a copy) is moved onto the portal and played from there.
]=]
local PortalController = {
	Controllers = {
		ChooseMapsController = {},
		CutsceneController = {},
		InterfaceController = {},
	},

	Signals = {
		-- (portalId : number, mapName : string) -- portalId is 0 when the player left
		GroupChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

function PortalController:_findPortal(portalId : number) : Model?
	for _, model in self.PortalsFolder:GetChildren() do
		if model:GetAttribute("PortalId") == portalId then
			return model
		end
	end

	return nil
end

function PortalController:_closePanel()
	self.PanelPortal = nil
	self.Controllers.ChooseMapsController:Close()
end

--[=[
	The portal the player is standing at, or nil when they are not close to any.
]=]
function PortalController:_findNearestPortal() : Model?
	local character = self.Player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local nearest, nearestDistance = nil, PortalConfig.PROXIMITY_RADIUS

	for _, model in self.PortalsFolder:GetChildren() do
		local enter = model:FindFirstChild(PortalConfig.ENTER_NAME)
		if not enter or not enter:IsA("BasePart") then
			continue
		end

		local distance = (enter.Position - root.Position).Magnitude
		if distance <= nearestDistance then
			nearest, nearestDistance = model, distance
		end
	end

	return nearest
end

function PortalController:_requestJoin(model : Model)
	local now = os.clock()
	if self.LastJoinPortal == model and now - self.LastJoinRequest < JOIN_COOLDOWN then
		return
	end

	self.LastJoinPortal = model
	self.LastJoinRequest = now

	Framework:Fire("RequestJoinGroup", model:GetAttribute("PortalId"))
end

function PortalController:_update()
	-- Already in a group: the portal has nothing left to offer.
	if self.GroupPortalId ~= 0 then
		self:_closePanel()
		return
	end

	local nearest = self:_findNearestPortal()
	if not nearest then
		self.IgnorePortal = nil
		self:_closePanel()
		return
	end

	-- The portal the player just walked out of: it stays quiet until they leave it
	-- behind, so the exit spot does not put them straight back in the group.
	if nearest == self.IgnorePortal then
		self:_closePanel()
		return
	end

	self.IgnorePortal = nil

	if nearest:GetAttribute("Occupied") == true then
		self:_closePanel()

		local memberCount = nearest:GetAttribute("MemberCount") or 0
		local maxPlayers = nearest:GetAttribute("MaxPlayers") or 0

		if nearest:GetAttribute("Launching") ~= true and memberCount < maxPlayers then
			self:_requestJoin(nearest)
		end

		return
	end

	-- The panel was closed while the player kept standing here: that was the Exit
	-- button, and reopening it every beat would make the button useless. It opens
	-- again once they walk off and come back.
	if self.PanelPortal == nearest then
		return
	end

	self.PanelPortal = nearest
	self.Controllers.ChooseMapsController:Open()
end

--[=[
	The white-out that closes the cutscene: a frame that goes from invisible to solid
	in a blink, and stays solid -- the teleport lands behind it.

	It is built here and not in StarterGui because it has to survive nothing: it exists
	between the end of the scene and the player leaving the server.
]=]
function PortalController:_flash()
	self.FlashMaid:DoCleaning()

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = FLASH_UI_NAME
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 1000
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- The cutscene hides the GUIs while it runs, and the flash is born inside it: without this
	-- mark it would be born disabled, and the teleport would happen in plain sight.
	screenGui:SetAttribute("IgnoreInterfaceHide", true)

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	screenGui.Parent = self.Player:WaitForChild("PlayerGui")

	self.Flash = frame
	self.FlashMaid:GiveTask(screenGui)
	self.FlashMaid:GiveTask(function()
		self.Flash = nil
	end)

	TweenService:Create(frame, FLASH_INFO, { BackgroundTransparency = 0 }):Play()
end

--[=[
	Takes the white-out back. Only ever runs when the player is still here -- that is,
	when the teleport did not happen and the portal gave the group back.
]=]
function PortalController:_clearFlash()
	local frame = self.Flash
	if not frame or not frame.Parent then
		self.FlashMaid:DoCleaning()
		return
	end

	self.Flash = nil

	local tween = TweenService:Create(frame, FLASH_OUT_INFO, { BackgroundTransparency = 1 })
	tween.Completed:Once(function()
		self.FlashMaid:DoCleaning()
	end)

	tween:Play()
end

--[=[
	Turns the leave-group button on and off.

	It goes through InterfaceController's `SetEnabled`, not `Enabled` by hand, because this
	button is exactly the GUI that changes **together** with a request: it lights up at the
	same instant the countdown hides the Lobby. Writing directly, the request would read the
	old `Enabled` (its notification only arrives at the end of the frame) and turn the
	button back off in the same frame: the button would vanish on entering the portal.

	With the call below, the order between this and `Hide`/`Show` no longer matters.
]=]
function PortalController:_setExitVisible(visible : boolean)
	local screenGui = self.ExitUI
	if not screenGui or not screenGui.Parent then
		return
	end

	local InterfaceController = self.Controllers.InterfaceController
	if InterfaceController then
		InterfaceController:SetEnabled(screenGui, visible)
		return
	end

	screenGui.Enabled = visible
end

function PortalController:_bindExitUI(screenGui : ScreenGui)
	self.UiMaid:DoCleaning()

	local button = screenGui:WaitForChild(EXIT_BUTTON_NAME, 10)
	if not button or not button:IsA("GuiButton") then
		log:StudioWarn(`could not find {EXIT_UI_NAME}.{EXIT_BUTTON_NAME}.`)
		return
	end

	self.ExitUI = screenGui
	self:_setExitVisible(self.GroupPortalId ~= 0)

	self.UiMaid:GiveTask(button.Activated:Connect(function()
		if self.GroupPortalId == 0 then
			return
		end

		Framework:Fire("RequestLeaveGroup")
	end))
end

function PortalController:_observeUI()
	local playerGui = self.Player:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child.Name ~= EXIT_UI_NAME or not child:IsA("ScreenGui") then
			return
		end

		self:_bindExitUI(child)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

function PortalController:_onGroupChanged(portalId : number, mapName : string)
	local previousId = self.GroupPortalId

	if (portalId or 0) == 0 and previousId ~= 0 then
		self.IgnorePortal = self:_findPortal(previousId)
	end

	self.GroupPortalId = portalId or 0
	self.MapName = mapName or ""

	self:_setExitVisible(self.GroupPortalId ~= 0)

	--[[
		The countdown is a decision already made: the player chose the map and is on the
		way. The shop, the deck, and the rest of the Lobby have nothing left to offer, and
		opening any of them now would only make the player lose the one button that still
		matters: the leave-group one, which is what `Except` keeps up.
	]]
	local InterfaceController = self.Controllers.InterfaceController

	if InterfaceController then
		if self.GroupPortalId ~= 0 then
			InterfaceController:Hide(HIDE_REASON, { Except = { EXIT_UI_NAME } })
		else
			InterfaceController:Show(HIDE_REASON)
		end
	end

	if self.GroupPortalId ~= 0 then
		self:_closePanel()
	else
		-- Left the group while still here: either they gave up, or the teleport did not go and
		-- the portal returned everyone. Either way the white screen must not stay, and the camera
		-- the scene left parked goes back to the player.
		self:_clearFlash()
		self.Controllers.CutsceneController:releaseCamera()
	end

	self.Signals.GroupChanged:Fire(self.GroupPortalId, self.MapName)
end

--[[ EXTERNAL ]]

function PortalController:GetGroupPortalId() : number
	return self.GroupPortalId
end

--[=[
	Moves the EnterCutscene asset onto a portal and plays it there.

	It is the asset itself that travels, not a clone: the rigs the scene animates are
	the ones inside it, and CutsceneController drives them where they stand. Once the
	scene is over it goes back to ReplicatedStorage, at the pivot it came from.
]=]
function PortalController:PlayPortalCutscene(model : Model)
	local reference = model:FindFirstChild(PortalConfig.CUTSCENE_REFERENCE_NAME)
	if not reference or not reference:IsA("BasePart") then
		log:StudioWarn(`portal has no {PortalConfig.CUTSCENE_REFERENCE_NAME} part.`)
		return
	end

	local scene = self.Scene
	if not scene then
		log:StudioWarn(`no cutscene named {PortalConfig.CUTSCENE_NAME} in Assets.Cutscenes.`)
		return
	end

	if scene.Parent == workspace then
		-- Still playing from the last group; do not yank it out from under it.
		return
	end

	self.SceneMaid:DoCleaning()

	-- Leaving is off the table once the countdown is over, and the button has no
	-- business sitting on top of the cutscene.
	self:_setExitVisible(false)

	local CutsceneController = self.Controllers.CutsceneController
	local origin = reference.CFrame

	local previousParent = scene.Parent
	scene.Parent = workspace

	local previousPivot = CutsceneController:placeScene(scene, origin)
	if not previousPivot then
		log:StudioWarn(`cutscene {PortalConfig.CUTSCENE_NAME} has no scene reference part.`)
		scene.Parent = previousParent
		return
	end

	-- The actor is the player walking into the portal, so it wears their look. Each
	-- client plays its own copy of the scene, so each one sees itself go through.
	local undress = CutsceneController:dressScene(scene, self.Player, ACTOR_RIG_NAME)

	local flashed = false
	local function flash()
		if flashed then
			return
		end

		flashed = true
		self:_flash()
	end

	-- The white comes in a few frames before the end, to cover the scene while it is still
	-- running instead of flashing after it.
	local connection = CutsceneController.Signals.FrameReached:Connect(function(frame : number, lastFrame : number)
		if frame >= lastFrame - PortalConfig.FLASH_LEAD_FRAMES then
			flash()
		end
	end)

	self.SceneMaid:GiveTask(function()
		connection:Disconnect()
	end)

	-- The camera stays where the scene ended; the teleport failure gives it back.
	local duration = CutsceneController:playCutscene(scene, origin, true)

	-- Safety net: a scene that did not play (or never reached the frame) must not
	-- leave the player staring at the portal until the teleport.
	task.delay(duration or 0, flash)

	task.delay((duration or 0) + SCENE_LINGER, function()
		undress()

		scene:PivotTo(previousPivot)
		scene.Parent = previousParent
	end)
end

function PortalController:construct()
	local map = workspace:WaitForChild(MAP_FOLDER_NAME)

	self.PortalsFolder = map:WaitForChild(PortalConfig.PORTALS_FOLDER)
	self.Scene = Shared:WaitForChild("Assets"):WaitForChild("Cutscenes"):FindFirstChild(PortalConfig.CUTSCENE_NAME)

	self:_observeUI()

	self.Maid:GiveTask(self.Controllers.ChooseMapsController.Signals.MapChosen:Connect(function(mapName : string, maxPlayers : number)
		local portal = self.PanelPortal
		if not portal or not portal.Parent then
			return
		end

		Framework:Fire("RequestCreateGroup", portal:GetAttribute("PortalId"), mapName, maxPlayers)
		self:_closePanel()
	end))

	Framework:Listen("PortalGroupChanged", function(portalId : number, mapName : string)
		self:_onGroupChanged(portalId, mapName)
	end)

	Framework:Listen("PlayPortalCutscene", function(portalId : number)
		local model = self:_findPortal(portalId)
		if model then
			self:PlayPortalCutscene(model)
		end
	end)

	local elapsed = 0
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		elapsed += deltaTime
		if elapsed < CHECK_INTERVAL then
			return
		end

		elapsed = 0
		self:_update()
	end))
end

function PortalController:start()

end

function PortalController:init()
	self.Maid = Maid.new()
	self.UiMaid = Maid.new()
	self.FlashMaid = Maid.new()
	self.SceneMaid = Maid.new()

	self.Maid:GiveTask(self.UiMaid)
	self.Maid:GiveTask(self.FlashMaid)
	self.Maid:GiveTask(self.SceneMaid)

	self.Player = Players.LocalPlayer

	self.GroupPortalId = 0
	self.MapName = ""
	self.PanelPortal = nil
	self.IgnorePortal = nil
	self.LastJoinPortal = nil
	self.LastJoinRequest = 0

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return PortalController
