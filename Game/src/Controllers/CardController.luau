local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local DeckConfig = SharedConfig.DeckConfig

local Me = require(Vendor.Me)

local Framework = Me.new()

-- The card-selected sound, in SoundService.SharedSounds.SFX.
local CARD_SOUND = "CardFlip"

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
	A click on a card.

	Clicking the card already in hand drops the unit; clicking another switches. With
	no units left on the card, nothing happens: the card is already dimmed on screen
	because of its own counter.
]=]
function CardController:_onCardActivated(unitName : string)
	if (self.CardCounts[unitName] or 0) <= 0 then
		return
	end

	-- The tutorial asks for a specific card on some steps. This is only interface
	-- courtesy: `TutorialMatchService` does the real refusing, on the server.
	local tutorial = self.Controllers.TutorialStepController
	if tutorial and not tutorial:AllowsCard(unitName) then
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

--[[ EXTERNAL ]]

--[=[
	Called by `UnitPlacementController` when the unit leaves the hand outside the
	hotbar: after placing, on cancel, on round change.
]=]
function CardController:setUnequipState()
	self:_setEquipped(nil)
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
