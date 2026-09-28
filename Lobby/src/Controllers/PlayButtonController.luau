local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)

local ButtonUtil = require(Util.ButtonUtil)
local MarkerUtil = require(Util.MarkerUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local PortalConfig = SharedConfig.PortalConfig

local Framework = Me.new()
local log = Log.new("PlayButtonController")

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"
local MIDDLE_NAME = "HUDMiddle"
local BUTTON_NAME = "PlayButton"

local MAP_FOLDER_NAME = "Map"

local WAIT_TIMEOUT = 10

--[=[
	The play button in `StarterGui.HUD.HUDMiddle`: it takes the player to the portals,
	which is where the match really starts.

	The grow and sink come from `ButtonUtil`, the same gesture as both shops' buy buttons,
	not `HUDButtonController`'s, which belongs to the `HUDFrame` column icons and slides
	out of the column. This button is in the middle of the screen and has no column to
	slide out of, so what is left for it is the scale, on the `UIScale` authored inside
	the button.

	The landing spot is the map's `PortalsTpPart`, found by depth under `Workspace.Map`
	like any other marker. Getting there is all the button does: `PortalController`
	opens the maps panel, by proximity, just as it would if the player had walked there.

	The HUD has `ResetOnSpawn` on, so the bind runs again for every new copy the engine
	puts in PlayerGui.

	See docs/lobby/hud.md.
]=]
local PlayButtonController = {
	Controllers = {},
}

--[[ INTERNAL ]]

function PlayButtonController:_bindHud(screenGui : ScreenGui)
	local middle = screenGui:WaitForChild(MIDDLE_NAME, WAIT_TIMEOUT)
	local button = middle and middle:WaitForChild(BUTTON_NAME, WAIT_TIMEOUT)

	if not button or not button:IsA("GuiButton") then
		log:StudioWarn(`could not find {HUD_UI_NAME}.{MIDDLE_NAME}.{BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()

	ButtonUtil.bindFeedback(button, self.HudMaid)

	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:TeleportToPortals()
	end))
end

function PlayButtonController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

--[=[
	Drops the player on the marker at the portals' entrance.

	The client owns its own character, so moving it here is enough: the server sees the
	new position through the usual replication, like `ShopController:TeleportToShop`.

	Returns `false` when it could not: the character has not loaded yet, or the map lacks
	the marker. In both cases the button simply does nothing; the missing-marker warning
	goes out once per name, through `MarkerUtil`.
]=]
function PlayButtonController:TeleportToPortals() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not root then
		return false
	end

	local part = MarkerUtil.find(
		MAP_FOLDER_NAME,
		PortalConfig.PLAY_TELEPORT_PART_NAME,
		self.MapParts,
		self.WarnedParts,
		"PlayButtonController"
	)

	local pivot = MarkerUtil.pivotOf(part)
	if not pivot then
		return false
	end

	local halfHeight = MarkerUtil.halfHeightOf(part)

	character:PivotTo(pivot * CFrame.new(0, halfHeight + PortalConfig.PLAY_TELEPORT_HEIGHT_OFFSET, 0))

	-- Without this the player carries the velocity they had and slides off the marker.
	root.AssemblyLinearVelocity = Vector3.zero

	return true
end

function PlayButtonController:start()
	self:_observeUI()
end

function PlayButtonController:init()
	self.Maid = Maid.new()
	self.HudMaid = Maid.new()

	self.Maid:GiveTask(self.HudMaid)

	self.MapParts = {}
	self.WarnedParts = {}

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
end

return PlayButtonController
