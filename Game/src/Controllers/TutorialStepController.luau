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

	**Nothing runs ahead of the player.** With `Match.WaitForRead`, each line waits
	for a click, and the step's highlight, arrow, and hotbar only come in once the
	dialog is dismissed. An `Info` step tells the server it was read
	(`TutorialStepRead`) when its dialog closes, which is what releases its wave.

	**Placement steps follow the hand.** While the player has not picked the card
	up, the highlight points at it; the moment a ghost is out (`isPlacing`), the
	highlight gets out of the way of the map and, with `ArrowOnEquip`, the arrow
	appears over the spot. Putting the card back brings the highlight back. With a
	`SnapRadius`, `UnitPlacementController` asks `GetPlacementSnap` every frame and
	snaps the ghost onto the arrow's spot when the player aims close to it.

	**Purchase steps follow the shop.** The highlight sits on the round card shop's
	edge button until the player opens the shop, moves to the offer once the cards
	are on the table, and goes back to the button if the shop is closed unbought.

	**Weather steps follow the popup.** The hand points at the weather button, moves
	onto the weather popup once it opens, and the step counts as read after the popup
	has been looked at for `ReadDelay` seconds (or closed).

	**Upgrade steps follow the selection.** Every tower the player owns glows with an
	arrow over it until one is clicked; once the upgrade card is open, the hand
	points at its upgrade button.

	**Lesson locks.** `Match.LockedUntil` buttons stay unclickable until the step
	that teaches them opens, held through `Interactable`, which
	`ButtonGateController` (which owns `Active`) never touches. Upgrading and
	selling stay locked until `Match.TowerActionsUntil` opens (see `IsTutorial`).

	The step lock outlives the step unless the step says `UnlockOnDone`.

	`FreeSpeed` marks every speed step's game pass as owned for this session (the
	tutorial server), so 2x is unlocked here and nowhere else.

	See docs/game/tutorial-match.md.
]]

local UI_WAIT_FRAMES = 50
local SPEECH_TIMEOUT = 120
local LESSON_LOCK_INTERVAL = 0.5
local SHOP_WATCH_INTERVAL = 0.15
local PLACEMENT_WATCH_INTERVAL = 0.1
local VISUAL_WATCH_INTERVAL = 0.15

-- The glow on the player's towers during an `Upgrade` step.
local UNIT_HIGHLIGHT_NAME = "TutorialUnitHighlight"
local UNIT_HIGHLIGHT_FILL = Color3.fromRGB(255, 205, 60)
local UNIT_HIGHLIGHT_OUTLINE = Color3.fromRGB(255, 255, 255)
local UNIT_HIGHLIGHT_FILL_TRANSPARENCY = 0.6

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
TutorialStepController.InTutorial = false
TutorialStepController.LockTowerActions = false
TutorialStepController.SpeedGranted = false
TutorialStepController.CardComponent = nil :: any
TutorialStepController.LockedCards = {}
TutorialStepController.DeckHidden = false
TutorialStepController.AllowedUnits = nil :: { [string] : boolean }?
TutorialStepController.Arrows = {}
TutorialStepController.StepConnections = {}

-- The placement step whose visuals are up: what `GetPlacementSnap` answers for.
TutorialStepController.SnapStep = nil :: any

-- The `Upgrade` step's glow and arrows over the towers. See `markUnits`.
TutorialStepController.UnitHighlights = {} :: { [Model] : Highlight }
TutorialStepController.UnitArrows = {} :: { [Model] : any }

-- Step Ids that have opened: what releases `LockedUntil` buttons and tower actions.
TutorialStepController.Opened = {}

-- `[GuiButton] = { Was : boolean, Connection }` for buttons held by a lesson lock.
TutorialStepController.Held = {}
TutorialStepController.LessonLoopRunning = false

--[[ INTERNAL ]]

function TutorialStepController:cardComponent() : any
	return self.CardComponent
end

--[=[
	A controller this one only needs now and then, looked up at the time of use and
	without waiting: the placement and weather controllers live in this place only,
	and a waiting lookup during boot could hang.
]=]
function TutorialStepController:controller(name : string) : any
	return Framework:Get(name, false, false)
end

function TutorialStepController:placement() : any
	return self:controller("UnitPlacementController")
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

--[[ LESSON LOCKS ]]

--- The buttons still waiting for their lesson: each entry's target and every button inside it.
function TutorialStepController:lessonButtons() : { [GuiButton] : boolean }
	local out = {}
	local highlight = self.Controllers.HighlightController
	if not highlight then return out end

	for _, entry in (Config.Match.LockedUntil or {}) do
		if self.Opened[entry.Step] then continue end

		local target = highlight:Find(entry.Button)
		if not target then continue end

		if target:IsA("GuiButton") then
			out[target] = true
		end

		for _, descendant in target:GetDescendants() do
			if descendant:IsA("GuiButton") then
				out[descendant] = true
			end
		end
	end

	return out
end

function TutorialStepController:releaseHeld(button : GuiButton)
	local state = self.Held[button]
	if not state then return end

	self.Held[button] = nil
	state.Connection:Disconnect()

	if button.Parent then
		button.Interactable = state.Was
	end
end

--[=[
	Holds every lesson-locked button at `Interactable = false` and gives back the
	ones whose lesson has opened. Returns whether anything is still locked.
]=]
function TutorialStepController:refreshLessonLocks() : boolean
	local wanted = self:lessonButtons()

	for button in self.Held do
		if not wanted[button] or not button.Parent then
			self:releaseHeld(button)
		end
	end

	for button in wanted do
		if self.Held[button] then continue end

		local state = { Was = button.Interactable }

		state.Connection = button:GetPropertyChangedSignal("Interactable"):Connect(function()
			if self.Held[button] == state and button.Interactable then
				button.Interactable = false
			end
		end)

		self.Held[button] = state
		button.Interactable = false
	end

	local pending = false
	for _, entry in (Config.Match.LockedUntil or {}) do
		if not self.Opened[entry.Step] then
			pending = true
			break
		end
	end

	return pending
end

function TutorialStepController:startLessonLocks()
	if self.LessonLoopRunning then return end

	self.LessonLoopRunning = true

	task.spawn(function()
		while self:refreshLessonLocks() do
			task.wait(LESSON_LOCK_INTERVAL)
		end

		for button in self.Held do
			self:releaseHeld(button)
		end

		self.LessonLoopRunning = false
	end)
end

--[[ STEP DISPLAY ]]

--- Tells the server an `Info` step's dialog has been read.
function TutorialStepController:reportRead(step : any)
	if not step or step.Kind ~= "Info" then return end

	task.delay(step.ReadDelay or 0, function()
		if self.Step ~= step then return end

		Framework:Fire("TutorialStepRead", step.Id)
	end)
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
			self:reportRead(step)
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
			Auto = not Config.Match.WaitForRead,
		}))

		return
	end

	self:showVisuals(step)
	self:reportRead(step)
end

function TutorialStepController:showVisuals(step : any)
	self:setCardsHidden(false)
	self:setAllowedCards(self:allowedOf(step))

	local highlight = self.Controllers.HighlightController
	local followsPlacement = step.Kind == "Place" or step.Kind == "PlaceRest"

	if step.Kind == "Place" then
		self.SnapStep = step
	end

	if step.Kind == "Buy" then
		-- The shop step drives its own highlight: the edge button first, the offer
		-- only once the shop is open.
		self:watchShop(step)
	elseif followsPlacement then
		-- The placement steps drive their own highlight and arrow, following the card
		-- in the player's hand.
		self:watchPlacement(step)
	elseif step.Kind == "Weather" then
		self:watchWeather(step)
	elseif step.Kind == "Upgrade" then
		self:watchUpgrade(step)
	elseif highlight then
		local target = self:cardOf(step.Unit)

		if not target and step.Highlight then
			target = highlight:Find(step.Highlight)
		end

		if not (target and highlight:Show(target)) and step.Highlight then
			self:awaitHighlight(step)
		end

		self:refreshGate()
	end

	if step.Kind == "Use" then
		self:awaitCard(step)
	end

	if step.Kind == "Speed" then
		self:watchSpeedOptions(step)
	end

	local arrow = self.Controllers.ArrowController
	if arrow and not step.ArrowOnEquip then
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

--- What a placement step points at while the card is still in the hotbar.
function TutorialStepController:placementTarget(step : any) : GuiObject?
	local target = self:cardOf(step.Unit)

	if not target and step.Highlight then
		local highlight = self.Controllers.HighlightController
		target = highlight and highlight:Find(step.Highlight)
	end

	return target
end

--[=[
	A placement step's visuals, following the card in the player's hand.

	Card in the hotbar: the highlight and its finger point at it. Card picked up (a
	ghost is out): the highlight leaves, because the player needs to see the map, and
	the arrow over the spot comes in (`ArrowOnEquip`). Card put back: the arrow
	leaves and the highlight returns.
]=]
function TutorialStepController:watchPlacement(step : any)
	task.spawn(function()
		local highlight = self.Controllers.HighlightController
		local arrowController = self.Controllers.ArrowController

		local lastPlacing = nil
		local arrow = nil
		local current = nil

		while self.Step == step do
			local placement = self:placement()
			local placing = placement ~= nil and placement.isPlacing == true

			if placing ~= lastPlacing then
				lastPlacing = placing

				if placing then
					current = nil

					if highlight then
						highlight:Hide()
					end

					if step.ArrowOnEquip and typeof(step.Position) == "Vector3" and arrowController and not arrow then
						arrow = arrowController:Point(step.Position)

						if arrow then
							table.insert(self.Arrows, arrow)
						end
					end
				else
					if arrow then
						local index = table.find(self.Arrows, arrow)
						if index then
							table.remove(self.Arrows, index)
						end

						arrow:Destroy()
						arrow = nil
					end
				end
			end

			-- Not placing: keep pointing at the card. Retried every pass, because the card
			-- may not be on screen yet (the hotbar comes back after the dialog).
			if not placing and highlight then
				local target = self:placementTarget(step)

				if target and target ~= current and highlight:Show(target) then
					current = target
					self:refreshGate()
				end
			end

			task.wait(PLACEMENT_WATCH_INTERVAL)
		end
	end)
end

--[=[
	The weather step's visuals: the hand on the weather button until the popup
	opens, then on the popup. The step counts as read after the popup has been open
	for `ReadDelay` seconds, or when the player closes it after opening it.
]=]
function TutorialStepController:watchWeather(step : any)
	task.spawn(function()
		local highlight = self.Controllers.HighlightController
		if not highlight then return end

		local current = nil
		local openedAt = nil
		local reported = false

		while self.Step == step do
			local indicator = self:controller("WeatherIndicatorController")
			local isOpen = indicator ~= nil and indicator.IsOpen == true

			local target
			if isOpen then
				openedAt = openedAt or os.clock()
				target = (indicator and indicator.Panel) or (step.Panel and highlight:Find(step.Panel))
			else
				target = step.Highlight and highlight:Find(step.Highlight)
			end

			if target and target ~= current and highlight:Show(target) then
				current = target
				self:refreshGate()
			end

			if openedAt and not reported then
				local looked = os.clock() - openedAt >= (step.ReadDelay or 3)

				if looked or not isOpen then
					reported = true
					Framework:Fire("TutorialStepRead", step.Id)
				end
			end

			task.wait(VISUAL_WATCH_INTERVAL)
		end
	end)
end

--- The player's own placed towers.
function TutorialStepController:ownedUnits() : { Model }
	local placement = self:placement()
	local out = {}

	for model, class in (placement and placement.createdClasses or {}) do
		if typeof(model) == "Instance" and model.Parent and class and class.isOwner then
			table.insert(out, model)
		end
	end

	return out
end

--[=[
	The glow and the arrow over every tower the player owns: "click one of these".
	Towers placed after the step opened get theirs on the next pass.
]=]
function TutorialStepController:markUnits()
	local arrowController = self.Controllers.ArrowController

	for _, model in self:ownedUnits() do
		if not self.UnitHighlights[model] then
			local glow = Instance.new("Highlight")
			glow.Name = UNIT_HIGHLIGHT_NAME
			glow.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			glow.FillColor = UNIT_HIGHLIGHT_FILL
			glow.FillTransparency = UNIT_HIGHLIGHT_FILL_TRANSPARENCY
			glow.OutlineColor = UNIT_HIGHLIGHT_OUTLINE
			glow.OutlineTransparency = 0
			glow.Parent = model

			self.UnitHighlights[model] = glow
		end

		if arrowController and not self.UnitArrows[model] then
			local center, size = model:GetBoundingBox()
			local top = center.Position + Vector3.new(0, size.Y / 2, 0)

			self.UnitArrows[model] = arrowController:Point(top)
		end
	end
end

function TutorialStepController:clearUnitMarks()
	for model, glow in self.UnitHighlights do
		glow:Destroy()
		self.UnitHighlights[model] = nil
	end

	for model, arrow in self.UnitArrows do
		if arrow then
			arrow:Destroy()
		end

		self.UnitArrows[model] = nil
	end
end

--[=[
	The upgrade step's visuals. Upgrade card closed: the towers glow with an arrow
	over each. Upgrade card open: the marks leave and the hand points at its upgrade
	button. Closing the card brings the marks back.
]=]
function TutorialStepController:watchUpgrade(step : any)
	task.spawn(function()
		local highlight = self.Controllers.HighlightController
		local pointing = false

		while self.Step == step do
			local interface = PlayerGui:FindFirstChild("Interface")
			local card = interface and interface:FindFirstChild("CardUpgrade")
			local button = step.Highlight and highlight and highlight:Find(step.Highlight)
			local open = card ~= nil and card:IsA("GuiObject") and card.Visible

			if open and button then
				if not pointing then
					self:clearUnitMarks()

					if highlight and highlight:Show(button) then
						pointing = true
						self:refreshGate()
					end
				end
			else
				if pointing then
					pointing = false

					if highlight then
						highlight:Hide()
					end
				end

				self:markUnits()
			end

			task.wait(VISUAL_WATCH_INTERVAL)
		end

		self:clearUnitMarks()
	end)
end

--- The round card shop's row of offers, the container of every card on the table.
function TutorialStepController:offerRow() : GuiObject?
	local shop = self.Controllers.RoundCardShopController
	local row = shop and shop.Row

	return if row and row:IsA("GuiObject") and row.Parent then row else nil
end

--- Whether the shop has finished dealing its cards onto the table.
function TutorialStepController:offerReady(step : any) : GuiObject?
	if step.Card then
		return self:artOf(self:offerCardOf(step.Card))
	end

	local row = self:offerRow()
	if not row then return nil end

	for _, child in row:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			return row
		end
	end

	return nil
end

--[=[
	The purchase step's highlight, following the shop's own state.

	Closed: the edge button the shop opens from (the step's `Highlight`). Open, with
	the cards dealt: the card the step asks for, or the whole offer row when any
	card will do. Closed again without buying: back to the button.
]=]
function TutorialStepController:watchShop(step : any)
	local highlight = self.Controllers.HighlightController
	local shop = self.Controllers.RoundCardShopController
	if not highlight then return end

	task.spawn(function()
		local current = nil

		while self.Step == step do
			local target = nil

			if shop and shop.ShopOpen == true then
				target = self:offerReady(step)
			elseif step.Highlight then
				target = highlight:Find(step.Highlight)
			end

			if target and target ~= current then
				if highlight:Show(target) then
					current = target
					self:refreshGate()
				end
			elseif not target and current and shop and shop.ShopOpen == true then
				-- Opened, cards still dealing: nothing to point at for a moment.
				highlight:Hide()
				current = nil
			end

			task.wait(SHOP_WATCH_INTERVAL)
		end
	end)
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

--- Waits for a `Use` step's card to land in the hand and highlights it.
function TutorialStepController:awaitCard(step : any)
	local highlight = self.Controllers.HighlightController
	if not highlight or not step.Card then return end

	task.spawn(function()
		for _ = 1, UI_WAIT_FRAMES do
			if self.Step ~= step then return end

			local target = self:artOf(self:handCardOf(step.Card))

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
	self.SnapStep = nil

	local highlight = self.Controllers.HighlightController
	if highlight then
		highlight:Hide()
	end

	for _, arrow in self.Arrows do
		arrow:Destroy()
	end

	table.clear(self.Arrows)

	self:clearUnitMarks()

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
			self:reportRead(step)
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
	Where a ghost of `unitName` should snap to right now, and from how far: the spot
	under the placement step's arrow and its `SnapRadius`. `nil` when no placement
	step with a snap is on screen, or the ghost is another unit.

	`UnitPlacementController` asks every frame: aiming within the radius puts the
	ghost exactly on the spot, aiming further away paints it red.
]=]
function TutorialStepController:GetPlacementSnap(unitName : string) : (Vector3?, number?)
	local step = self.SnapStep
	if not step or self.Step ~= step then return nil, nil end

	if step.Kind ~= "Place" then return nil, nil end
	if typeof(step.Position) ~= "Vector3" or typeof(step.SnapRadius) ~= "number" then return nil, nil end
	if step.Unit and unitName ~= step.Unit then return nil, nil end

	return step.Position, step.SnapRadius
end

--- Whether upgrading and selling are still locked by the tutorial.
function TutorialStepController:LocksTowerActions() : boolean
	if not self.InTutorial then
		return false
	end

	if self.LockTowerActions then
		return true
	end

	local gate = Config.Match.TowerActionsUntil

	return gate ~= nil and not self.Opened[gate]
end

--[=[
	Whether this tutorial currently locks the match's tower actions and "PLAY AGAIN".

	`ToggleTower` (upgrade/sell) and `ResultController` (play again) ask this. It is
	`true` until the `Match.TowerActionsUntil` step opens (or all match with
	`LockTowerActions`), then `false`, and both behave normally. The closing step's
	button whitelist still keeps the results screen pointed at "BACK TO LOBBY".

	For "is this the tutorial match at all", use `IsTutorialMatch`.
]=]
function TutorialStepController:IsTutorial() : boolean
	return self:LocksTowerActions()
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

		if typeof(step.Id) == "string" then
			self.Opened[step.Id] = true
		end

		if step.FreeSpeed then
			self:grantFreeSpeed()
		end

		if type(step.Locked) == "table" then
			self.LockedCards = step.Locked
		end

		self:startLessonLocks()
		self:refreshLessonLocks()

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