local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("TutorialStepController")

local Config = SharedConfig.TutorialConfig
local SpeedConfig = SharedConfig.SpeedConfig

--[[
	The tutorial script on the player's screen: the dialog, the highlight, the
	arrows, and the button lock, per step the server sends (`TutorialStep`,
	`TutorialStepDone`).

	The lock a step sets outlives the step unless the step says `UnlockOnDone`: the
	reworked script releases the screen after each lesson so the rest of the match
	plays like a normal game.

	`FreeSpeed` marks every speed step's game pass as owned **for this session**,
	which is the tutorial server: the speed menu shows 2x unlocked here and nowhere
	else.

	See docs/game/tutorial-match.md.
]]

local UI_WAIT_FRAMES = 50
local SPEECH_TIMEOUT = 20

local TutorialStepController = {
	Controllers = {
		DialogController = {},
		HighlightController = {},
		ArrowController = {},
		RoundCardShopController = {},
		SpeedController = {},
		ButtonGateController = {},
		DifficultyController = {},
	}
}

TutorialStepController.Step = nil :: any

-- Becomes `true` on the first step and never goes back.
TutorialStepController.InTutorial = false

-- Whether this tutorial locks upgrading/selling and "PLAY AGAIN" (see `IsTutorial`).
TutorialStepController.LockTowerActions = false

TutorialStepController.SpeedGranted = false
TutorialStepController.CardComponent = nil :: any
TutorialStepController.LockedCards = {}
TutorialStepController.DeckHidden = false
TutorialStepController.AllowedUnits = nil :: { [string] : boolean }?
TutorialStepController.Arrows = {}
TutorialStepController.StepConnections = {}

--[[ INTERNAL ]]

function TutorialStepController:cardComponent() : any
	return self.CardComponent
end

function TutorialStepController:resolveCardComponent()
	local library = script.Parent:FindFirstChild("UILibraryController")
	local components = library and library:FindFirstChild("Components")
	local card = components and components:FindFirstChild("Card")
	if not card then
		log:StudioWarn("could not find the Card component; the hotbar does not follow the script.")

		return
	end

	local success, component = pcall(require, card)
	if not success or type(component) ~= "table" then
		log:StudioWarn(`the Card component did not load: {component}`)

		return
	end

	self.CardComponent = component

	if component.setHidden then
		component.setHidden(component, self.DeckHidden)
	end

	if component.setAllowed then
		component.setAllowed(component, self.AllowedUnits)
	end
end

function TutorialStepController:cardOf(unitName : string?) : GuiObject?
	if not unitName then
		return nil
	end

	local component = self:cardComponent()
	local getter = component and component.getCard

	return getter and getter(component, unitName)
end

function TutorialStepController:setCardsHidden(hidden : boolean)
	self.DeckHidden = hidden == true

	local component = self:cardComponent()
	local setter = component and component.setHidden

	if setter then
		setter(component, self.DeckHidden)
	end
end

function TutorialStepController:setAllowedCards(allowed : { [string] : boolean }?)
	self.AllowedUnits = allowed

	local component = self:cardComponent()
	local setter = component and component.setAllowed

	if setter then
		setter(component, allowed)
	end
end

function TutorialStepController:allowedOf(step : any) : { [string] : boolean }?
	local allowed = step and step.AllowedUnits

	if step and step.Kind == "Place" and step.Unit then
		return { [step.Unit] = true }
	end

	return allowed
end

--[=[
	Every speed step that needs a game pass counts as bought, for this session
	only. `SpeedController.purchased` is its "bought this session" table; the
	server does not check speed passes, so nothing else is needed.
]=]
function TutorialStepController:grantFreeSpeed()
	if self.SpeedGranted then return end

	local speed = self.Controllers.SpeedController
	if not speed or type(speed.purchased) ~= "table" then return end

	self.SpeedGranted = true

	for index in SpeedConfig.Steps do
		local key = SpeedConfig.GetGamepass(index)
		if key then
			speed.purchased[key] = true
		end
	end
end

function TutorialStepController:show(step : any)
	self.Step = step

	self:setDeckHeld(step.HideDeck == true)
	self:gateFor(step)

	local dialog = self.Controllers.DialogController

	if dialog and step.Lines then
		self:setCardsHidden(true)

		local shown = false

		local function reveal()
			if shown or self.Step ~= step then return end

			shown = true
			self:showVisuals(step)
		end

		local disconnect
		disconnect = dialog:OnClosed(function()
			if disconnect then
				disconnect()
			end

			reveal()
		end)

		task.delay(SPEECH_TIMEOUT, function()
			if shown or self.Step ~= step then return end

			log:StudioWarn(`the dialog of step "{step.Id}" did not close within {SPEECH_TIMEOUT}s; continuing without it.`)

			if disconnect then
				disconnect()
			end

			reveal()
		end)

		dialog:Play(step.Lines, Config.Speech({
			HideUI = false,
			Blur = false,
			Duck = false,
			Auto = true,
		}))

		return
	end

	self:showVisuals(step)
end

function TutorialStepController:showVisuals(step : any)
	self:setCardsHidden(false)
	self:setAllowedCards(self:allowedOf(step))

	local highlight = self.Controllers.HighlightController
	if highlight then
		local target = self:cardOf(step.Unit)

		if not target and step.Highlight then
			target = highlight:Find(step.Highlight)
		end

		if not (target and highlight:Show(target)) and step.Highlight then
			self:awaitHighlight(step)
		end

		self:refreshGate()
	end

	if step.Kind == "Buy" or step.Kind == "Use" then
		self:awaitCard(step)
	end

	if step.Kind == "Speed" then
		self:watchSpeedOptions(step)
	end

	local arrow = self.Controllers.ArrowController
	if arrow then
		if typeof(step.Position) == "Vector3" then
			table.insert(self.Arrows, arrow:Point(step.Position))
		end

		for _, position in (step.Positions or {}) do
			if typeof(position) == "Vector3" then
				table.insert(self.Arrows, arrow:Point(position))
			end
		end
	end
end

--- The round card shop's row of offers, the container of every card on the table.
function TutorialStepController:offerRow() : GuiObject?
	local shop = self.Controllers.RoundCardShopController
	local row = shop and shop.Row

	return if row and row:IsA("GuiObject") and row.Parent then row else nil
end

function TutorialStepController:gateTargets(step : any, list : { any }?) : { any }
	local out = {}

	local aliases = {
		["@Highlight"] = function()
			local highlight = self.Controllers.HighlightController

			return highlight and highlight:GetTarget() or nil
		end,

		["@Deck"] = function()
			local interface = PlayerGui:FindFirstChild("Interface")

			return interface and interface:FindFirstChild("TowerContainer") or nil
		end,

		["@Card"] = function()
			return self:cardOf(step.Unit)
		end,

		["@Hand"] = function()
			return if step.Card then self:handCardOf(step.Card) else nil
		end,

		["@Offer"] = function()
			return if step.Card then self:offerCardOf(step.Card) else nil
		end,

		-- Every card on the shop table, for a step that lets the player pick any.
		["@Offers"] = function()
			return self:offerRow()
		end,

		["@SpeedOptions"] = function()
			local speed = self.Controllers.SpeedController

			return speed and speed:GetOptions() or nil
		end,
	}

	for _, entry in (list or {}) do
		if type(entry) ~= "string" then
			continue
		end

		if string.sub(entry, 1, 1) ~= "@" then
			table.insert(out, entry)

			continue
		end

		local alias = aliases[entry]

		if alias then
			table.insert(out, alias)
		else
			log:StudioWarn(`step "{step.Id}" asks for alias "{entry}", which does not exist.`)
		end
	end

	return out
end

function TutorialStepController:gateFor(step : any)
	local gate = self.Controllers.ButtonGateController
	if not gate or not step or not step.Buttons then return end

	local allow = self:gateTargets(step, step.Buttons)

	for _, entry in (Config.ButtonGate.Always or {}) do
		table.insert(allow, entry)
	end

	gate:Lock({
		Allow = allow,
		Block = self:gateTargets(step, step.BlockedButtons),
		Ignore = Config.ButtonGate.Ignore,
		Release = step.ButtonRelease or Config.ButtonGate.Release,
	})
end

function TutorialStepController:watchSpeedOptions(step : any)
	local speed = self.Controllers.SpeedController
	local button = speed and speed:GetButton()
	local parent = button and button.Parent
	if not parent then return end

	local function update()
		if self.Step ~= step then return end

		local highlight = self.Controllers.HighlightController
		local target = speed:GetOption(step.Index) or button

		if highlight and target then
			highlight:Show(target)
		end

		self:refreshGate()
	end

	table.insert(self.StepConnections, parent.ChildAdded:Connect(function()
		task.defer(update)
	end))

	table.insert(self.StepConnections, parent.ChildRemoved:Connect(function()
		task.defer(update)
	end))
end

function TutorialStepController:refreshGate()
	local gate = self.Controllers.ButtonGateController

	if gate then
		gate:Refresh()
	end
end

--[=[
	Waits for the step's card and highlights it: the shop card for a purchase
	(or the whole row when any card will do), the hand card for a use.
]=]
function TutorialStepController:awaitCard(step : any)
	local highlight = self.Controllers.HighlightController
	if not highlight then return end

	if step.Kind == "Use" and not step.Card then return end

	task.spawn(function()
		for _ = 1, UI_WAIT_FRAMES do
			if self.Step ~= step then return end

			local target
			if step.Kind == "Buy" then
				target = if step.Card then self:artOf(self:offerCardOf(step.Card)) else self:offerRow()
			else
				target = self:artOf(self:handCardOf(step.Card))
			end

			if target and target.Visible and highlight:Show(target) then
				self:refreshGate()

				return
			end

			task.wait(0.1)
		end
	end)
end

function TutorialStepController:awaitHighlight(step : any)
	local highlight = self.Controllers.HighlightController
	if not highlight or not step.Highlight then return end

	local frames = if typeof(step.HighlightWait) == "number"
		then math.max(1, math.round(step.HighlightWait * 10))
		else UI_WAIT_FRAMES

	task.spawn(function()
		for _ = 1, frames do
			if self.Step ~= step then return end

			local target = highlight:Find(step.Highlight)

			if target and highlight:Show(target) then
				self:refreshGate()

				return
			end

			task.wait(0.1)
		end

		log:StudioWarn(`step "{step.Id}" asks to highlight "{step.Highlight}", which did not show up on screen.`)
	end)
end

function TutorialStepController:offerCardOf(cardId : string) : GuiObject?
	local shop = self.Controllers.RoundCardShopController

	return shop and shop:GetOfferCard(cardId) or nil
end

function TutorialStepController:artOf(wrapper : GuiObject?) : GuiObject?
	if not wrapper then
		return nil
	end

	for _, child in wrapper:GetChildren() do
		if child:IsA("GuiButton") or child:IsA("ImageLabel") then
			return child
		end
	end

	return wrapper
end

function TutorialStepController:handCardOf(cardId : string) : GuiObject?
	local interface = PlayerGui:FindFirstChild("Interface")
	local container = interface and interface:FindFirstChild("TowerContainer")

	return container and container:FindFirstChild(`RoundCard_{cardId}`) or nil
end

function TutorialStepController:clear()
	self.Step = nil

	self:setDeckHeld(false)
	self:clearVisuals()
end

function TutorialStepController:setDeckHeld(held : boolean)
	local difficulty = self.Controllers.DifficultyController
	if difficulty and difficulty.HoldHotbar then
		difficulty:HoldHotbar("Tutorial", held)
	end
end

function TutorialStepController:clearVisuals()
	local highlight = self.Controllers.HighlightController
	if highlight then
		highlight:Hide()
	end

	for _, arrow in self.Arrows do
		arrow:Destroy()
	end

	table.clear(self.Arrows)

	for _, connection in self.StepConnections do
		connection:Disconnect()
	end

	table.clear(self.StepConnections)
end

function TutorialStepController:reassert()
	local step = self.Step
	if not step then return end

	self:gateFor(step)

	local dialog = self.Controllers.DialogController
	if dialog and (dialog:IsOpen() or dialog:IsResuming()) then
		local disconnect
		disconnect = dialog:OnClosed(function()
			if disconnect then
				disconnect()
			end

			if self.Step ~= step then return end

			self:clearVisuals()
			self:showVisuals(step)
		end)

		return
	end

	self:clearVisuals()
	self:showVisuals(step)
end

--[[ API ]]

function TutorialStepController:AllowsCard(unitName : string) : boolean
	local allowed = self.AllowedUnits
	if allowed and not allowed[unitName] then
		return false
	end

	local step = self.Step

	if not step or step.Kind ~= "Place" or not step.Unit then
		return true
	end

	return unitName == step.Unit
end

function TutorialStepController:AllowsCardUse(cardId : string) : boolean
	local step = self.Step

	if not step or step.Kind ~= "Use" or not step.Card then
		return not self.LockedCards or not self.LockedCards[cardId]
	end

	return cardId == step.Card
end

--[=[
	Whether this tutorial locks the match's tower actions and "PLAY AGAIN".

	`ToggleTower` (upgrade/sell) and `ResultController` (play again) ask this. The
	reworked tutorial is a full match, so with `LockTowerActions = false` this
	answers `false` and both behave normally; the closing step's button whitelist
	still keeps the results screen pointed at "BACK TO LOBBY".

	For "is this the tutorial match at all", use `IsTutorialMatch`.
]=]
function TutorialStepController:IsTutorial() : boolean
	return self.InTutorial == true and self.LockTowerActions == true
end

function TutorialStepController:IsTutorialMatch() : boolean
	return self.InTutorial == true
end

--- The shop only refuses an outside-click dismiss while a purchase step is open.
function TutorialStepController:AllowsShopDismiss() : boolean
	local step = self.Step

	return not (step and step.Kind == "Buy")
end

function TutorialStepController:GetStep() : any
	return self.Step
end

--[[ LIFECYCLE ]]

function TutorialStepController:construct()
	Player.CharacterAdded:Connect(function()
		task.defer(function()
			self:reassert()
		end)
	end)

	Framework:Listen("TutorialStep", function(step : any)
		if type(step) ~= "table" then return end

		self.InTutorial = true
		self.LockTowerActions = step.LockTowerActions == true

		if step.FreeSpeed then
			self:grantFreeSpeed()
		end

		if type(step.Locked) == "table" then
			self.LockedCards = step.Locked
		end

		self:clear()
		self:show(step)
	end)

	Framework:Listen("TutorialStepDone", function(id : any)
		local step = self.Step

		if step and id ~= nil and step.Id ~= id then
			return
		end

		local gate = self.Controllers.ButtonGateController
		if gate then
			if step and step.UnlockOnDone then
				gate:Unlock()
			else
				gate:HoldRelease()
			end
		end

		if step and step.Kind == "Use" and step.Card then
			self.LockedCards[step.Card] = nil
		end

		self:clear()
	end)
end

function TutorialStepController:start()
end

function TutorialStepController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	task.spawn(function()
		self:resolveCardComponent()
	end)

	self:construct()
end

return TutorialStepController