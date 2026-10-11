local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local DeckConfig = SharedConfig.DeckConfig
local GamepadConfig = SharedConfig.GamepadConfig

local Me = require(Vendor.Me)

local Framework = Me.new()

-- The card-selected sound, in SoundService.SharedSounds.SFX.
local CARD_SOUND = "CardFlip"

--[[
	The bumpers walk the hotbar: RB to the next card, LB to the previous one, wrapping
	at both ends. Equipping through them is the same as clicking the card, so the ghost
	comes out and the controller places it with R2.

	`GAMEPAD_CONTEXT` puts both in the hint bar (see `GamepadController:SetContext`).
]]
local GAMEPAD_CONTEXT = "Hotbar"

--- `GamepadController`, borrowed without yielding: it is in Common, this is in Game.
local function getGamepad()
	return Framework:Get("GamepadController", false, false)
end

local function isGamepadInput(input : InputObject) : boolean
	return string.find(input.UserInputType.Name, "^Gamepad") ~= nil
end

--[=[
	The bridge between the profile's deck and the match hotbar.

	Nothing is drawn here: the `Card` component draws
	(`UILibraryController/Components/Card.luau`), cloning the `CardWrapper` authored in
	`TowerContainer` and fitting the cards into the arc. This controller decides
	**what** appears, **how many** of each card there are, and **which is selected**.

	- the card list is the deck built in the Lobby (`EquippedUnits`), in slot order and
	  without gaps; see `DeckConfig.resolve`/`unitList` and docs/game/hotbar.md;
	- each card's count comes from the server (`UpdateCardCounts`), which also derives
	  it from the deck;
	- the selected card grows and dims the others, so every `Equipped` change notifies
	  the component, and that is where `CardFlip` plays.
]=]
local CardController = {
	Controllers = {
		DataController = {},
		MusicController = {},
		UnitPlacementController = {},
		UILibraryController = {},
		TutorialStepController = {},
	},

	CardCounts = {},
	Cash = 0,
	Equipped = nil,

	-- The hotbar as last drawn, in on-screen order. What the bumpers walk through.
	Hotbar = {},

	-- The hotbar imposed by the tutorial, when there is one. Nil in a regular match.
	TutorialDeck = nil,
}

--[[ INTERNAL ]]

function CardController:_component(func : string, ...)
	self.Controllers.UILibraryController:doComponent("Card", func, ...)
end

--[=[
	Stores which unit is in hand and tells the hotbar, which grows that card and dims
	the others. It is the only way to change `Equipped`, so the screen never disagrees
	with what `UnitPlacementController` shows on the ground.

	The sound only plays when a card **enters** the hand: dropping the unit is the same
	path with `nil`, and then there is no card to flip.
]=]
function CardController:_setEquipped(unitName : string?)
	if self.Equipped == unitName then
		return
	end

	self.Equipped = unitName
	self:_component("setSelected", unitName)

	if unitName then
		self:_playCardSound()
	end
end

--[=[
	The card-flip sound, the same as the Lobby deck panel's
	(`SoundService.SharedSounds.SFX`).
]=]
function CardController:_playCardSound()
	local music = self.Controllers.MusicController

	if music then
		music:PlaySFX(CARD_SOUND)
	end
end

--[=[
	Whether this card can go into the hand now: it has units left and the tutorial
	allows it. The same two rules `_onCardActivated` applies to a click, in one place so
	the bumpers skip exactly the cards a click would refuse.
]=]
function CardController:_isPickable(unitName : string) : boolean
	if (self.CardCounts[unitName] or 0) <= 0 then
		return false
	end

	-- The tutorial asks for a specific card on some steps. This is only interface
	-- courtesy: `TutorialMatchService` does the real refusing, on the server.
	local tutorial = self.Controllers.TutorialStepController
	if tutorial and not tutorial:AllowsCard(unitName) then
		return false
	end

	return true
end

--[=[
	A click on a card.

	Clicking the card already in hand drops the unit; clicking another switches. With
	no units left on the card, nothing happens: the card is already dimmed on screen
	because of its own counter.
]=]
function CardController:_onCardActivated(unitName : string)
	if not self:_isPickable(unitName) then
		return
	end

	if self.Equipped == unitName then
		self:_setEquipped(nil)
		self.Controllers.UnitPlacementController:unequip()

		return
	end

	if self.Equipped then
		self.Controllers.UnitPlacementController:unequip()
	end

	self.Controllers.UnitPlacementController:visualize(unitName)
	self:_setEquipped(unitName)
end

--[=[
	Whether the hand is free for the bumpers to change.

	Two cases where it is not, and both belong to round cards, not the hotbar:

	- a round card is asking for a target (`pointerLocked`): it already emptied the hand,
	  and filling it again would put a ghost over what the card is aiming at;
	- a ghost is out with **no** hotbar card equipped: that is Zippers moving a tower
	  through `visualize` with options, and swapping it for a unit would drop the move.
]=]
function CardController:_canCycle() : boolean
	local placement = self.Controllers.UnitPlacementController
	if not placement then
		return false
	end

	if placement.pointerLocked then
		return false
	end

	if placement.isPlacing and not self.Equipped then
		return false
	end

	return true
end

--[=[
	Redraws the hotbar from the profile. Runs at boot and on every server write to
	`Units`, `EquippedUnits`, or `CardLimit`.

	A player who never built a deck gets an automatic one, the same `UnitService`
	builds on the other side: both ends read the same profile through the same
	functions, so the hotbar and the counts always talk about the same thing.
]=]
function CardController:_render()
	local replica = self.Controllers.DataController:GetReplica()
	local profile = replica and replica.Data

	if not profile then
		return
	end

	-- In the tutorial the cards do not come from the profile: they are the ones the server sent.
	local hotbar = self.TutorialDeck or DeckConfig.unitList(DeckConfig.resolve(profile))

	self.Hotbar = hotbar

	self:_component("set", hotbar, self.CardCounts, function(unitName : string)
		self:_onCardActivated(unitName)
	end)

	-- The deck changed under the unit in hand: if it is no longer in the deck, the
	-- hand empties; if it still is, the hotbar needs to know it is the apex.
	if self.Equipped and not table.find(hotbar, self.Equipped) then
		self.Equipped = nil
		self.Controllers.UnitPlacementController:unequip()
	end

	self:_component("setSelected", self.Equipped)
end

--[=[
	The bumpers. Controller buttons skip `gameProcessed`: Satchel binds LB/RB through
	`ContextActionService` for tool switching, which can mark them processed even in a
	match with no tools. What the filter guarded against is checked directly: typing,
	the Roblox menu, cutscenes, and a panel open over the map.
]=]
function CardController:_bindGamepad()
	UserInputService.InputBegan:Connect(function(input : InputObject)
		local key = input.KeyCode
		if key ~= GamepadConfig.CARD_NEXT_KEY and key ~= GamepadConfig.CARD_PREVIOUS_KEY then
			return
		end

		if not isGamepadInput(input) then return end
		if UserInputService:GetFocusedTextBox() then return end

		local gamepad = getGamepad()
		if gamepad and (gamepad:IsBlocked() or gamepad:HasOpenPanel()) then return end

		self:CycleEquipped(if key == GamepadConfig.CARD_NEXT_KEY then 1 else -1)
	end)
end

--[[ EXTERNAL ]]

--[=[
	Called by `UnitPlacementController` when the unit leaves the hand outside the
	hotbar: after placing, on cancel, on round change.
]=]
function CardController:setUnequipState()
	self:_setEquipped(nil)
end

--[=[
	Puts the next (`direction = 1`) or previous (`-1`) card in hand, wrapping at both
	ends of the hotbar.

	With an empty hand, next starts at the first card and previous at the last. Cards
	`_isPickable` refuses (none left, locked by the tutorial) are skipped, and if no
	other card qualifies the hand stays as it is. It goes through `_onCardActivated`,
	so it is exactly a click on that card: ghost out, card grown, `CardFlip` played.
]=]
function CardController:CycleEquipped(direction : number)
	local hotbar = self.Hotbar
	local count = hotbar and #hotbar or 0

	if count == 0 or not self:_canCycle() then
		return
	end

	local current = self.Equipped and table.find(hotbar, self.Equipped)
	local origin = current or (if direction > 0 then 0 else count + 1)

	for step = 1, count do
		local index = ((origin - 1 + direction * step) % count) + 1
		local unitName = hotbar[index]

		if unitName ~= self.Equipped and self:_isPickable(unitName) then
			self:_onCardActivated(unitName)
			return
		end
	end
end

function CardController:construct()
	-- `Gamepasses` is in the list because the +5 Total Cards pass changes the deck cap
	-- (`DeckConfig.limitFor`), and buying it mid-match must show.
	for _, key in { "Units", "EquippedUnits", "CardLimit", "Gamepasses" } do
		self.Controllers.DataController:OnConnectChange({ key }, function()
			self:_render()
		end)
	end

	--[[
		The tutorial deck arrives from the server, not the profile: it belongs to the
		match, not the player. When it arrives, the hotbar is redrawn with it; the usual
		`_render` uses it in place of the profile read.
	]]
	Framework:Listen("TutorialDeck", function(units : any)
		if type(units) ~= "table" then return end

		self.TutorialDeck = units
		self:_render()
	end)

	Framework:Listen("UpdateCardCounts", function(unitName : string, count : number)
		self.CardCounts[unitName] = count
		self:_component("setCount", unitName, count)
	end)
	Framework:Fire("RequestCardCounts")

	-- Session money decides whether the card shows in red (not enough cash).
	Framework:Listen("UpdateCash", function(amount : number)
		self.Cash = amount or 0
		self:_component("setCash", self.Cash)
	end)
	Framework:Fire("RequestCash")

	--[[
		Weather can change the placement price (rain discounts Ice by 25%), and the
		price is written on the card: without this the player would see the old value
		until the hotbar was redrawn for another reason.

		`task.defer` for the same reason as in `WeatherFeedbackController`:
		`WeatherController` keeps the current weather and listens to the same event,
		and the order between the two is not guaranteed. One deferred step is enough
		for `GetCurrent` to already answer the new weather.
	]]
	Framework:Listen("WeatherChanged", function()
		task.defer(function()
			self:_component("refreshWeather")
		end)
	end)

	self:_bindGamepad()

	local gamepad = getGamepad()
	if gamepad then
		gamepad:SetContext(GAMEPAD_CONTEXT, {
			{ Key = GamepadConfig.CARD_PREVIOUS_KEY, Label = "Prev Card" },
			{ Key = GamepadConfig.CARD_NEXT_KEY, Label = "Next Card" },
		})
	end

	task.spawn(function()
		self:_render()
	end)
end

function CardController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

function CardController:init()

end

return CardController