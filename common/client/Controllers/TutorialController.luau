local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.TutorialConfig
local PortalConfig = SharedConfig.PortalConfig
local PICK = Config.MapPick

--[[
	The tutorial's Lobby voice.

	**The map pick** (`TutorialMapPick`, sent by `TutorialService` to a first-time
	player): a welcome, then an arrow at the nearest free portal. Once the map panel
	opens, the highlight lands on the suggested map, then on Confirm once a map is
	picked. The player's portal group opening ends it with one short line.

	**The old offer** (`TutorialPrompt`) is still here for Cmdr's `tutorial`;
	accepting starts the map pick.

	The controller decides nothing: the server makes the group solo and stamps the
	tutorial flag on the teleport.

	See docs/common/tutorial.md.
]]

local TutorialController = {
	Controllers = {
		DialogController = {},
		RichTextController = {},
		HighlightController = {},
		ArrowController = {},
	}
}

TutorialController.Listeners = {}
TutorialController.Session = 0

-- The map pick's state: which session runs it and what it is pointing at now.
TutorialController.PickSession = 0
TutorialController.PickMode = nil :: string?
TutorialController.PickArrow = nil :: any
TutorialController.PickArrowTarget = nil :: BasePart?

--[[ INTERNAL ]]

function TutorialController:escapedName() : string
	return self.Controllers.RichTextController:Escape(Player.DisplayName)
end

function TutorialController:lines() : { string }
	local name = self:escapedName()

	local lines = {}
	for index, line in Config.Lines do
		lines[index] = string.format(line, name)
	end

	return lines
end

function TutorialController:answer(accepted : boolean)
	self.Session += 1

	Framework:Fire("TutorialAnswered", accepted)

	for _, listener in self.Listeners do
		task.spawn(listener, accepted)
	end

	self.Controllers.DialogController:Close()
end

--[[ MAP PICK ]]

function TutorialController:chooseMaps() : any
	return Framework:Get("ChooseMapsController", false, false)
end

--- The nearest portal nobody is using, by its enter part.
function TutorialController:nearestFreePortal() : BasePart?
	local character = Player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local map = workspace:FindFirstChild("Map")
	local portals = map and map:FindFirstChild(PortalConfig.PORTALS_FOLDER)
	if not root or not portals then return nil end

	local best, bestDistance = nil, math.huge

	for _, model in portals:GetChildren() do
		if not model:IsA("Model") or model:GetAttribute("Occupied") == true then
			continue
		end

		local enter = model:FindFirstChild(PortalConfig.ENTER_NAME)
		if enter and enter:IsA("BasePart") then
			local distance = (enter.Position - root.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = enter, distance
			end
		end
	end

	return best
end

function TutorialController:clearArrow()
	if self.PickArrow then
		self.PickArrow:Destroy()
	end

	self.PickArrow = nil
	self.PickArrowTarget = nil
end

function TutorialController:pointAtPortal()
	local target = self:nearestFreePortal()
	if target == self.PickArrowTarget then return end

	self:clearArrow()

	local arrow = self.Controllers.ArrowController
	if arrow and target then
		self.PickArrow = arrow:Point(target.Position)
		self.PickArrowTarget = target
	end
end

function TutorialController:highlightPath(path : string)
	local highlight = self.Controllers.HighlightController
	if not highlight then return end

	local target = highlight:Find(path)
	if target then
		highlight:Show(target)
	end
end

function TutorialController:clearPick()
	self.PickMode = nil
	self:clearArrow()

	local highlight = self.Controllers.HighlightController
	if highlight then
		highlight:Hide()
	end
end

--- One pass of the map pick: what should be pointed at right now.
function TutorialController:updatePick()
	local chooseMaps = self:chooseMaps()

	if chooseMaps and chooseMaps:IsOpen() then
		self:clearArrow()

		local mode = if chooseMaps:GetSelected() then "Confirm" else "Map"
		if mode == self.PickMode then return end

		self.PickMode = mode

		if mode == "Map" then
			self:highlightPath(string.format(PICK.Gui.MapEntry, PICK.SuggestedMap))
		else
			self:highlightPath(PICK.Gui.Confirm)
		end

		return
	end

	if self.PickMode ~= "Portal" then
		self.PickMode = "Portal"

		local highlight = self.Controllers.HighlightController
		if highlight then
			highlight:Hide()
		end
	end

	self:pointAtPortal()
end

function TutorialController:finishPick(session : number)
	if self.PickSession ~= session then return end

	self.PickSession += 1
	self:clearPick()

	local dialog = self.Controllers.DialogController
	if dialog and PICK.ChosenLines then
		dialog:Play(PICK.ChosenLines, Config.Speech({
			HideUI = false,
			Blur = false,
			Auto = true,
		}))
	end
end

--[=[
	Runs the map pick. The welcome plays first and alone; pointing starts when it
	closes, and stops when the player's portal group opens.
]=]
function TutorialController:RunMapPick()
	self.PickSession += 1
	local session = self.PickSession

	self:clearPick()

	local dialog = self.Controllers.DialogController

	local function startPointing()
		if self.PickSession ~= session then return end

		task.spawn(function()
			while self.PickSession == session do
				self:updatePick()
				task.wait(PICK.PollInterval)
			end
		end)
	end

	local name = self:escapedName()
	local lines = {}
	for index, line in PICK.Lines do
		lines[index] = string.format(line, name)
	end

	if not dialog then
		startPointing()
		return
	end

	local disconnect
	disconnect = dialog:OnClosed(function()
		if disconnect then
			disconnect()
		end

		startPointing()
	end)

	if not dialog:Play(lines, Config.Speech()) then
		if disconnect then
			disconnect()
		end

		startPointing()
	end
end

--[[ API ]]

function TutorialController:Prompt() : boolean
	local dialog = self.Controllers.DialogController

	self.Session += 1
	local session = self.Session

	local buttons = {}
	buttons[Config.Buttons.AcceptIndex] = {
		Text = Config.Buttons.AcceptText,
		Font = Config.Font,
		OnClick = function()
			if self.Session ~= session then return end

			self:answer(true)
		end,
	}
	buttons[Config.Buttons.DeclineIndex] = {
		Text = Config.Buttons.DeclineText,
		Font = Config.Font,
		OnClick = function()
			if self.Session ~= session then return end

			self:answer(false)
		end,
	}

	return dialog:Play(self:lines(), Config.Speech({
		Buttons = buttons,
		ButtonsAtEnd = true,
	}))
end

function TutorialController:OnAnswer(callback : (accepted : boolean) -> ()) : () -> ()
	table.insert(self.Listeners, callback)

	return function()
		local index = table.find(self.Listeners, callback)
		if index then
			table.remove(self.Listeners, index)
		end
	end
end

function TutorialController:IsPickingMap() : boolean
	return self.PickMode ~= nil
end

--[[ LIFECYCLE ]]

function TutorialController:construct()
	Framework:Listen("TutorialPrompt", function()
		local session = self.Session

		task.delay(Config.PromptDelay, function()
			if self.Session ~= session then return end

			self:Prompt()
		end)
	end)

	Framework:Listen("TutorialMapPick", function()
		self:RunMapPick()
	end)

	Framework:Listen("PortalGroupChanged", function(portalId : any)
		if typeof(portalId) == "number" and portalId > 0 then
			self:finishPick(self.PickSession)
		end
	end)
end

function TutorialController:start()
end

function TutorialController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return TutorialController