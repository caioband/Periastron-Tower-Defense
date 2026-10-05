local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Signal = require(Packages.Signal)

local SharedConfig = require(Configs.SharedConfig)
local LightingUtil = require(Util.LightingUtil)
local UIUtil = require(Util.UIUtil)

local CardConfig = SharedConfig.CardConfig
local ClassConfig = SharedConfig.ClassConfig
local DeckConfig = SharedConfig.DeckConfig
local RarityConfig = SharedConfig.RarityConfig
local UnitStats = SharedConfig.UnitStats
local UpgradeConfig = SharedConfig.UnitUpgradeConfig

local Framework = Me.new()
local log = Log.new("DeckController")

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDFrame"
local HUD_BUTTON_NAME = "Deck"

local CARD_UI_NAME = "CardUI"
local INVENTORY_NAME = "Inventory"
local LIST_NAME = "ScrollingFrame"
local EQUIPPED_NAME = "EquippedCards"
local SELECTION_NAME = "SelectionPanel"
local CONTAINER_NAME = "Container"
local CLOSE_NAME = "Close"
local ERROR_NAME = "ErrorLabel"
local LIMIT_NAME = "CardsLimit"

local WRAPPER_NAME = "CardWrapper"
local CARD_NAME = "Card"
local EMPTY_CARD_NAME = "EmptyCard"
local LOCKED_FRAME_NAME = "LockedFrame"
local LOCK_TEXT_NAME = "LockText"
local UNIT_NAME_NAME = "UnitName"
local COUNT_NAME = "Count"
local BUTTON_NAME = "Button"

local EQUIP_TOGGLE_NAME = "EquipToggle"
local CLASS_ICON_NAME = "ClassIcon"
local DAMAGE_NAME = "DamagePerSecond"
local COOLDOWN_NAME = "AttackSpeed"
local RANGE_NAME = "Range"

local WAIT_TIMEOUT = 10

--[[
	The name of the `InterfaceController` request: with the loadout open, the screen is its
	alone, the same as the shops and contracts (`ProximityPanel`).
]]
local HIDE_REASON = "Deck"

-- The background blur, the same `UIBlur` and the same size as `ProximityPanel`.
local BLUR_SIZE = 24

--[[
	The locked slot text. `%d` is the level it asks for (`DeckConfig.SLOT_UNLOCK_LEVELS`);
	the sentence is the one the designer authored in `LockText`, with `X` in place of the
	number.
]]
local LOCK_TEXT_FORMAT = "Unlocked at Level %d"

local OPEN_INFO = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- The cards' entrance: position overshoots (Back) and opacity just follows, shorter,
-- because transparency with overshoot would pass 0 and flicker.
local INTRO_MOVE_TIME = 0.42
local INTRO_FADE_TIME = 0.28
local INTRO_STAGGER = 0.035

-- Cap on the accumulated delay: with a large inventory, the last card must not
-- take half a minute to come in.
local INTRO_MAX_DELAY = 0.9

-- Where every card comes from on opening. It is the position inside its own wrapper: the
-- wrapper is what the UIGridLayout puts in place, so animating the card does not fight
-- the grid.
local INTRO_FROM_POSITION = UDim2.fromScale(0, 0)

-- The card that travels between the inventory and the deck. The clone flies over
-- everything, so its ZIndex is well above the panels (which are at 1); the HUD is
-- `ZIndexBehavior.Sibling`, so that is enough.
local FLIGHT_INFO = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local FLIGHT_ZINDEX = 50
local FLIGHT_NAME = "FlyingCard"

-- When the list rearranges (a unit ran out and its row left), the wrapper
-- jumps straight to the new cell and the card inside makes the trip.
local SLIDE_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- EquipToggle is only the "can equip" state, and its color comes authored in the GUI.
-- When there is nothing to equip the button hides, instead of becoming an "unequip".
local EQUIP_TEXT = "Equip"

-- The sound for every clicked card, in SoundService.SharedSounds.SFX.
local CARD_SOUND = "CardFlip"

local LIMIT_FORMAT = "%d/%d"
local LIMIT_ERROR = "Your deck is full — %d/%d cards."
local COPIES_ERROR = "You have no spare %s cards."
local ERROR_DURATION = 3

--[[ HELPERS ]]

--[=[
	A number with at most `decimals` places and no trailing zeros: 12.00 -> "12".
	The same format as Game's upgrade card (`ToggleTower`).
]=]
local function formatNumber(value : number, decimals : number?) : string
	local text = string.format("%." .. (decimals or 0) .. "f", value)

	if text:find("%.") then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end

	return text
end

local function formatStat(value : number) : string
	if value >= 1000 then
		return UIUtil.formatAbbreviated(math.floor(value + 0.5))
	end

	return formatNumber(value, 1)
end

--[=[
	The unit's damage per hit with no upgrade at all, or its income per wave when it is a
	Farm, which does not attack. It is the same text the upgrade card shows in a match,
	just at level 0 and without weather: in the Lobby neither exists.
]=]
local function formatDamageOrIncome(unitName : string) : string
	local stats = UnitStats[unitName]
	local farm = stats and stats.Farm

	if farm then
		return "$" .. UIUtil.formatAbbreviated(farm.Income or 0) .. " INCOME"
	end

	-- A slow aura deals no damage: its level 0 slow, as the others show level 0 damage.
	if stats and stats.SlowAura then
		return formatNumber(UpgradeConfig:GetAuraSlow(unitName, 0) * 100, 1) .. "% SLOW"
	end

	return formatStat(UpgradeConfig:GetDamage(unitName, 0)) .. " DMG"
end

--[=[
	Where the unit sits in the inventory list: highest rarity to lowest, alphabetical
	within a band. It is an order that only depends on the name, so you can know where a
	card will land before it exists.
]=]
local function sortByRarity(a : string, b : string) : boolean
	local orderA = RarityConfig.getOrder(UnitStats[a].Rarity) or 0
	local orderB = RarityConfig.getOrder(UnitStats[b].Rarity) or 0

	if orderA ~= orderB then
		return orderA > orderB
	end

	return a < b
end

--[=[
	The transparencies the card has **before** any animation touches it, one entry per
	object: the card, the texts, the outlines.

	It is read from the object itself, not a table of fixed values, because the fade's
	target is "what the designer left": an outline that came half faded returns half
	faded.

	It only holds if called before the first animation. An inventory card is cloned and read
	on the spot; a slot card is read once, on bind.
]=]
local function captureFades(card : GuiObject)
	local fades = {}

	local function add(object : Instance)
		local goal = nil

		if object:IsA("UIStroke") then
			goal = { Transparency = object.Transparency }
		elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
			goal = {
				BackgroundTransparency = object.BackgroundTransparency,
				ImageTransparency = object.ImageTransparency,
			}
		elseif object:IsA("TextLabel") or object:IsA("TextButton") then
			goal = {
				BackgroundTransparency = object.BackgroundTransparency,
				TextTransparency = object.TextTransparency,
				TextStrokeTransparency = object.TextStrokeTransparency,
			}
		elseif object:IsA("GuiObject") then
			goal = { BackgroundTransparency = object.BackgroundTransparency }
		end

		if goal then
			table.insert(fades, { Object = object, Goal = goal })
		end
	end

	add(card)
	for _, descendant in card:GetDescendants() do
		add(descendant)
	end

	return fades
end

--[=[
	Everything the entrance animation needs to know about a card: where it rests and how
	opaque it is when still.
]=]
local function captureIntro(card : GuiObject)
	return {
		Card = card,
		Position = card.Position,
		Fades = captureFades(card),
	}
end

--[=[
	Puts the card in its starting state: at the wrapper's corner and invisible.
]=]
local function applyIntroStart(entry)
	entry.Card.Position = INTRO_FROM_POSITION

	for _, fade in entry.Fades do
		for property, _ in fade.Goal do
			fade.Object[property] = 1
		end
	end
end

--[=[
	Puts the card in its final state right away, without animating. That is what applies
	when the list is redrawn with the panel already open: equipping a card must not make
	the whole screen come in again.
]=]
local function applyIntroEnd(entry)
	entry.Card.Position = entry.Position

	for _, fade in entry.Fades do
		for property, value in fade.Goal do
			fade.Object[property] = value
		end
	end
end

--[=[
	Owner of `StarterGui.HUD.CardUI`: the unit inventory, the equipped deck, and the detail
	panel.

	The `HUDFrame.Deck` button opens and closes it (the same button with the panel open
	closes it), and opening is a tween of the `UIScale` from 0 to the authored scale. Open,
	it is alone on screen with the background blurred, like the shops and contracts (see
	`_claimScreen`).

	**One card per click.** `EquipToggle` puts cards in the deck, with the selected unit:
	an inventory card only **shows**, it does not equip. The button hides when no copy is
	left in the inventory, and removing a card is only by clicking the card in the deck
	itself. Every swap is a cloned card flying to its destination.

	**On PC there is a shortcut:** right-clicking an inventory card selects and equips at
	once, without going to `EquipToggle`. It is the same equip path, with the same checks;
	only the click count changes.

	**The side the card left changes right away; the side it will land on waits for the
	landing.** The two are drawn separately (`_renderInventory` and `_renderSlots`), and
	each stays still while a card is flying toward it: that is what keeps the `EmptyCard`
	visible, or the card out of the list, until it arrives.

	Clicking in bursts is meant to work: each click releases one more card, and what
	decides whether it counts is `Projected`: the deck counting what is still in the air,
	which is what the server already saved, not what the screen is showing.

	Nothing here decides what the player owns: the inventory, the deck, and the limit come
	from the profile replica (`Units`, `EquippedUnits`, `CardLimit`), and the click only
	asks `DeckService` for the swap.

	The HUD has `ResetOnSpawn` on, so the bind runs again on every respawn.

	See docs/lobby/deck.md.
]=]
local DeckController = {
	Controllers = {
		DataController = {},
		MusicController = {},
		HUDBadgeController = {},
		InterfaceController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),

		-- (unitName : string?) — the card the detail panel is showing.
		SelectionChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

function DeckController:_playTween(object : Instance, info : TweenInfo, goal : { [string]: any }, maid) : Tween
	local tween = TweenService:Create(object, info, goal)
	local owner = maid or self.TweenMaid

	owner:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()

	return tween
end

--[=[
	The profile inventory (`{[name] = count}`), or an empty table until the replica arrives.
]=]
function DeckController:_getUnits() : { [string]: number }
	local replica = self.Replica

	return replica and replica.Data and replica.Data.Units or {}
end

--[=[
	How many cards fit in the deck. It comes from the same `limitFor` `DeckService` uses,
	so the +5 gamepass counts here without the client asking anything, and both sides
	reach the same number from the same replica.
]=]
function DeckController:_getLimit() : number
	local replica = self.Replica
	local data = replica and replica.Data

	return DeckConfig.limitFor(data)
end

--[=[
	How many slots the player has today.

	It comes from the replica's `Stats.XP` through the same `DeckConfig` the server uses,
	so both reach the same number without exchanging anything: the client counts along
	only to draw the lock and refuse the click before the answer. `DeckService` still
	decides.

	Three until the replica arrives, which is what every player has.
]=]
function DeckController:_getUnlocked() : number
	local replica = self.Replica
	local data = replica and replica.Data

	if not data then
		return DeckConfig.unlockedSlots(1)
	end

	return DeckConfig.unlockedFor(data)
end

function DeckController:_getEquipped() : DeckConfig.Deck
	local replica = self.Replica
	local raw = replica and replica.Data and replica.Data.EquippedUnits

	return DeckConfig.sanitize(raw, self:_getUnits(), self:_getLimit(), self:_getUnlocked())
end

--[=[
	The units that have a row in the inventory list, in the order they appear.

	A unit with every copy equipped leaves here (that is what removes the inventory card
	when the player equips the last one), **unless** it has a card coming back from the
	deck: then the row stays, hidden, holding the spot where the card will land. A unit
	that left `UnitStats` (renamed, cut) is left out either way: the card would have no
	number to show.
]=]
function DeckController:_sortedUnits(
	units : { [string]: number },
	tally : { [string]: number },
	incoming : { [string]: number }?
) : { string }
	local names = {}

	for unitName, count in units do
		if not DeckConfig.exists(unitName) then
			if not self.WarnedMissing[unitName] then
				self.WarnedMissing[unitName] = true
				log:StudioWarn(`the profile has "{unitName}", which is not in UnitStats.`)
			end

			continue
		end

		local remaining = (count or 0) - (tally[unitName] or 0)
		if remaining <= 0 and not (incoming and incoming[unitName]) then
			continue
		end

		table.insert(names, unitName)
	end

	table.sort(names, sortByRarity)

	return names
end

--[=[
	The unit's card art.

	`Card` is an ImageLabel and its art is the **whole card** (frame, illustration, and
	background in a single image), so switching units is switching the image. The ids live
	in `SharedConfig.CardConfig`, the same ones Game's hotbar uses.

	A unit without an id keeps the art the GUI came authored with: a card with the wrong
	art beats a blank card in the middle of the inventory. A free slot's `EmptyCard` has
	its own art and does not go through here.
]=]
local function writeCardImage(card : GuiObject, unitName : string)
	if not card:IsA("ImageLabel") and not card:IsA("ImageButton") then
		return
	end

	local image = CardConfig.GetImage(unitName)
	if not image then
		return
	end

	card.Image = image
end

--[=[
	The card's identity: which unit it belongs to.

	The art, the name, and the outline in the rarity's color: the name is the only place
	on the card where rarity fits, and without it the whole inventory is purple.

	None of this changes while the card belongs to that unit, so an inventory row only
	writes it when it is born. A slot card goes through here on every redraw, because it
	is fixed and switches units as the deck changes.
]=]
local function writeCardName(card : GuiObject, unitName : string)
	card:SetAttribute("Unit", unitName)
	writeCardImage(card, unitName)

	local nameLabel = card:FindFirstChild(UNIT_NAME_NAME)
	if not nameLabel or not nameLabel:IsA("TextLabel") then
		return
	end

	nameLabel.Text = unitName
	nameLabel.Visible = true

	local stroke = nameLabel:FindFirstChildOfClass("UIStroke")
	local stats = UnitStats[unitName]
	local color = stats and RarityConfig.getColor(stats.Rarity)

	if stroke and color then
		stroke.Color = color
	end
end

--[=[
	The card's counter. It is what actually changes from one redraw to the next.
]=]
local function writeCardCount(card : GuiObject, count : number?)
	local countHolder = card:FindFirstChild(COUNT_NAME)
	local countLabel = countHolder and countHolder:FindFirstChild(COUNT_NAME)

	if countLabel and countLabel:IsA("TextLabel") then
		countLabel.Text = `{count or 0}x`
	end
end

--[=[
	Writes a whole card and hooks up its click. It is the path for slot cards, which are
	fixed instances that switch units as the deck changes.
]=]
function DeckController:_fillCard(card : GuiObject, unitName : string, count : number, onClick : (() -> ())?, maid)
	writeCardName(card, unitName)
	writeCardCount(card, count)

	local button = card:FindFirstChild(BUTTON_NAME)
	if button and button:IsA("GuiButton") and onClick and maid then
		maid:GiveTask(button.Activated:Connect(onClick))
	end
end


--[=[
	Where the card leaving the deck will land: that unit's row in the inventory.

	It is a normal output of `_renderInventory`: a unit with a card on its way always gets
	a row, hidden if it had no copy left.

	It only waits a frame when the row was just born: `UIGridLayout` positions the new
	wrapper at the end of the frame, and without that wait the card would fly to where it
	*was*. A row that already existed does not move, so the trip starts right away.
]=]
function DeckController:_inventoryTarget(unitName : string, isNew : boolean) : GuiObject?
	if isNew then
		task.wait()
	end

	local entry = self.InventoryByUnit[unitName]

	return entry and entry.Card or nil
end

--[=[
	A card's position (center) and size in `CardUI` scale, which is where the traveling
	clone lives. Leaving absolute space is what allows flying between the scrolling list
	and the deck frame, which share nothing but the panel.
]=]
function DeckController:_rectToScale(card : GuiObject) : (UDim2, UDim2)
	local cardUI = self.CardUI
	local size = cardUI.AbsoluteSize

	if size.X <= 0 or size.Y <= 0 then
		return UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.2, 0.2)
	end

	local center = card.AbsolutePosition + card.AbsoluteSize / 2
	local offset = center - cardUI.AbsolutePosition

	return UDim2.fromScale(offset.X / size.X, offset.Y / size.Y),
		UDim2.fromScale(card.AbsoluteSize.X / size.X, card.AbsoluteSize.Y / size.Y)
end

--[=[
	Cuts the opening animation and puts every card in place at once.

	Someone clicking before the entrance ends must not see the card fly to where the
	destination *was still arriving*, nor leave a card at half opacity.
]=]
function DeckController:_finishIntro()
	self.AnimMaid:DoCleaning()

	for _, entry in self.InventoryEntries do
		if entry.Intro then
			applyIntroEnd(entry.Intro)
		end
	end

	for _, slot in self.Slots do
		applyIntroEnd(slot.CardIntro)
		applyIntroEnd(slot.EmptyIntro)
	end
end

--[=[
	Makes the clone look like a traveling card.

	The counter goes: how many cards exist on each side is the business of the cards
	standing still, and the source's number is already stale the instant the clone leaves,
	all the more with several trips in the air at once.

	The name **and the art** are rewritten because the source may be hidden and still
	showing another unit: that is the case of a slot that will only be filled when the
	previous card lands. Without it, the flying card leaves with the wrong unit's face.
]=]
function DeckController:_dressClone(clone : GuiObject, unitName : string)
	clone.Name = FLIGHT_NAME
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.ZIndex = FLIGHT_ZINDEX
	clone.Visible = true

	local countHolder = clone:FindFirstChild(COUNT_NAME)
	if countHolder then
		countHolder:Destroy()
	end

	writeCardImage(clone, unitName)

	local nameLabel = clone:FindFirstChild(UNIT_NAME_NAME)
	local stats = UnitStats[unitName]

	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = unitName
		nameLabel.Visible = true

		local stroke = nameLabel:FindFirstChildOfClass("UIStroke")
		local color = stats and RarityConfig.getColor(stats.Rarity)

		if stroke and color then
			stroke.Color = color
		end
	end

	-- The clone is decoration: its button must not equip anything.
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("GuiButton") then
			descendant.Interactable = false
			descendant.Active = false
			descendant.Selectable = false
		end
	end
end

--[=[
	Releases the clone traveling from `sourceCard` to `targetCard`. The request already
	registered the trip; here only the clone and its tween are filled in.
]=]
function DeckController:_launchFlight(flight, sourceCard : GuiObject?, targetCard : GuiObject?)
	-- Between registering the trip and getting here there is a frame (the one
	-- `_inventoryTarget` yields), and in it the panel may have closed or the player
	-- respawned: both end everything in the air. Without this guard, the
	-- clone would be born for a trip nobody follows anymore.
	if not table.find(self.Flights, flight) then
		return
	end

	local cardUI = self.CardUI

	if not cardUI or not cardUI.Parent or not sourceCard or not targetCard then
		self:_endFlight(flight)
		return
	end

	self:_finishIntro()
	self:_playCardSound()

	local clone = sourceCard:Clone()
	self:_dressClone(clone, flight.Unit)

	local fromPosition, fromSize = self:_rectToScale(sourceCard)
	local toPosition, toSize = self:_rectToScale(targetCard)

	clone.Position = fromPosition
	clone.Size = fromSize
	clone.Rotation = sourceCard.Rotation
	clone.Parent = cardUI

	flight.Clone = clone

	local tween = TweenService:Create(clone, FLIGHT_INFO, {
		Position = toPosition,
		Size = toSize,
		Rotation = targetCard.Rotation,
	})

	flight.Tween = tween

	tween.Completed:Connect(function(state : Enum.PlaybackState)
		-- Canceled is the path of whoever already ended the trip (closing the panel, a
		-- respawn, a server refusal): only a tween that reached the end makes the landing
		-- count.
		if state ~= Enum.PlaybackState.Completed then
			return
		end

		self:_endFlight(flight)
	end)

	tween:Play()
end

--[=[
	Registers a trip. While **any** is in the air, the screen is not redrawn: that is what
	holds each slot in its old state until its card lands, even with other cards leaving
	along the way.
]=]
function DeckController:_addFlight(flight)
	table.insert(self.Flights, flight)
end

--[=[
	End of a trip: the clone disappears and the screen is redrawn. The side waiting for
	this card is only released if it was the last one on its way there: that is when the
	slot swaps `EmptyCard` for `Card`, or the card reappears in the inventory.

	`silent` only ends, without redrawing: it is for callers that will redraw on their own
	after ending all of them.
]=]
function DeckController:_endFlight(flight, silent : boolean?)
	local index = table.find(self.Flights, flight)
	if not index then
		return
	end

	table.remove(self.Flights, index)

	if flight.Tween then
		flight.Tween:Cancel()
		flight.Tween = nil
	end

	if flight.Clone then
		flight.Clone:Destroy()
		flight.Clone = nil
	end

	if not silent then
		self:_render()
	end
end

function DeckController:_endAllFlights()
	while #self.Flights > 0 do
		self:_endFlight(self.Flights[#self.Flights], true)
	end
end

--[=[
	Changes the deck the client believes is the real one (`Projected`): what the replica
	says plus what was already requested and is still in the air.

	Clicks are validated against it and the destination slot comes from it: the screen may
	be two clicks behind, but what the server already saved is not. The last landing's
	`_render` resyncs everything with the profile.
]=]
function DeckController:_project(action : string, unitName : string)
	if action == "Equip" then
		DeckConfig.addCard(self.Projected, unitName, self:_getUnlocked())
	else
		DeckConfig.removeCard(self.Projected, unitName)
	end
end

--[=[
	Undoes what `_project` did. It is the server refusal path.
]=]
function DeckController:_unproject(action : string, unitName : string)
	self:_project(if action == "Equip" then "Unequip" else "Equip", unitName)
end

--[=[
	How many cards of each unit are flying in this action's direction: `"Equip"` for those
	going to the deck, `"Unequip"` for those returning to the inventory.

	What waits for the landing is the card, not the panel: with one card going to the deck
	and another returning to the inventory at once, each holds only its own slot (or its own
	list row), and everything else on both sides keeps responding right away.
]=]
function DeckController:_incomingUnits(action : string) : { [string]: number }
	local counts = {}

	for _, flight in self.Flights do
		if flight.Action == action then
			counts[flight.Unit] = (counts[flight.Unit] or 0) + 1
		end
	end

	return counts
end

--[=[
	The deck as the **slots** are entitled to show it: `Projected` without the cards still
	flying there, so a slot only changes when its card arrives. With no card in the air,
	it is `Projected`.
]=]
function DeckController:_landedDeck() : DeckConfig.Deck
	local deck = DeckConfig.copy(self.Projected)

	for _, flight in self.Flights do
		if flight.Action == "Equip" then
			DeckConfig.removeCard(deck, flight.Unit)
		end
	end

	return deck
end

--[=[
	How many cards of each unit the **inventory** is entitled to consider equipped:
	`Projected`'s plus those still returning, which only leave the count when they land.
]=]
function DeckController:_landedTally() : { [string]: number }
	local tally = DeckConfig.tally(self.Projected)

	for _, flight in self.Flights do
		if flight.Action == "Unequip" then
			tally[flight.Unit] = (tally[flight.Unit] or 0) + 1
		end
	end

	return tally
end

--[=[
	Requests equipping **one** card of the unit and releases the one traveling to its slot.

	The checks here are the same as `DeckService`'s, just so the warning shows right away,
	without a round trip. The server still really decides: if it refuses, the trip is
	undone in `DeckCardResult`.
]=]
function DeckController:_requestEquip(unitName : string)
	if not self.CardUI then
		return
	end

	local units = self:_getUnits()
	local projected = self.Projected
	local owned = units[unitName] or 0

	if DeckConfig.countOf(projected, unitName) >= owned then
		self:_showError(string.format(COPIES_ERROR, unitName))
		return
	end

	local total = DeckConfig.total(projected)
	if total >= self.Limit then
		self:_showError(string.format(LIMIT_ERROR, total, self.Limit))
		return
	end

	-- A copy of a unit already in the deck goes to its slot; a new unit, to the
	-- first free one, which is not necessarily the next in line, since a slot
	-- in the middle may have emptied, and never one the level has not opened yet.
	local slotIndex = DeckConfig.slotIndexOf(projected, unitName)
		or DeckConfig.firstFreeSlot(projected, self:_getUnlocked())

	local slot = slotIndex and self.Slots[slotIndex]
	if not slot then
		-- No unlocked slot left: either the deck already has a different unit in each
		-- one, or the remaining ones still require a level.
		self:_showError()
		return
	end

	local source = self.InventoryByUnit[unitName]
	if not source then
		return
	end

	Framework:Fire("RequestEquipCard", unitName)

	local flight = { Action = "Equip", Unit = unitName }
	self:_addFlight(flight)
	self:_project("Equip", unitName)

	-- The clone goes out before the redraw: the source card may be exactly the one
	-- that will leave the list (it was the last copy), and afterward there would be nothing
	-- to clone nor to measure the starting position from.
	self:_launchFlight(flight, source.Card, slot.Card)

	-- The source side (the inventory) changes right away. The slots stay still: that is
	-- where the card is going.
	self:_render()
end

--[=[
	Requests removing **one** card of the unit and releases the one traveling back to the
	inventory. If the unit had every copy in the deck, the destination card is created
	hidden before the trip.
]=]
function DeckController:_requestUnequip(unitName : string)
	if not self.CardUI then
		return
	end

	local slotIndex = DeckConfig.slotIndexOf(self.Projected, unitName)
	local slot = slotIndex and self.Slots[slotIndex]

	if not slot then
		return
	end

	Framework:Fire("RequestUnequipCard", unitName)

	-- The trip is registered before `_render`: it tells the inventory there is a card
	-- arriving, and therefore that the destination row must exist.
	local flight = { Action = "Unequip", Unit = unitName }
	self:_addFlight(flight)
	self:_project("Unequip", unitName)

	-- If the unit had every copy in the deck, its row will be born now
	-- and the layout needs a frame; if it was already in the list, it does not.
	local isNew = self.InventoryByUnit[unitName] == nil

	-- The source side (the slots) changes right away. The inventory stays still: that is
	-- where the card is going.
	self:_render()

	-- Cloning after the redraw is not a problem: `_dressClone` rewrites the name and
	-- restores visibility, and the slot's position does not change with its content.
	local destination = self:_inventoryTarget(unitName, isNew)
	self:_launchFlight(flight, slot.Card, destination)
end

--[=[
	Redraws the inventory, the six slots, and the counter from the replica.

	It runs on every server write to `Units`, `EquippedUnits`, or `CardLimit`, on bind, on
	every click, and on every landing. The two sides decide what is actually redrawn: each
	refuses to change while a card is flying toward it. With the panel open cards are born
	ready (`applyIntroEnd`); the entrance animation is only for opening.
]=]
function DeckController:_render()
	if not self.CardUI or not self.CardUI.Parent or not self.Template then
		return
	end

	local units = self:_getUnits()

	-- With nothing in the air, what the client thinks and what the profile says are the
	-- same thing again. With cards flying, `Projected` rules: it already has what
	-- the replica may not have received yet.
	if #self.Flights == 0 then
		self.Projected = DeckConfig.copy(self:_getEquipped())
	end

	self.Limit = self:_getLimit()

	self:_renderInventory(units)
	self:_renderSlots()

	-- The selected unit may have left the profile along the way.
	if self.SelectedUnit and (units[self.SelectedUnit] or 0) <= 0 then
		self.SelectedUnit = nil
		self.Signals.SelectionChanged:Fire(nil)
	end

	self:_renderSelection()
end

--[=[
	Rebuilds the inventory list.

	A unit with a card flying **here** keeps its previous number, and comes in hidden if it
	had no card in the list: that is what holds the landing. Everything else in the list is
	as it is now: a card that left here disappears right away, because this is its source
	side.
]=]
--[=[
	Creates a unit's row in the list.

	What does not change while the row exists is written here, only once: the name, the
	rarity color, and the click. A hidden card receives no input, so the connection can
	stay on even when the row is only holding a landing spot.
]=]
function DeckController:_createInventoryEntry(unitName : string)
	local wrapper = self.Template:Clone()
	local card = wrapper:FindFirstChild(CARD_NAME)

	if not card or not card:IsA("GuiObject") then
		wrapper:Destroy()
		return nil
	end

	wrapper.Name = unitName

	local entry = {
		Unit = unitName,
		Wrapper = wrapper,
		Card = card,

		-- Read from the untouched clone: it is the "pre-runtime" value the fade must restore
		-- at the end.
		Intro = captureIntro(card),
		Maid = Maid.new(),
	}

	entry.Maid:GiveTask(wrapper)
	entry.Maid:GiveTask(function()
		self:_cancelSlide(entry)
	end)

	writeCardName(card, unitName)

	local button = card:FindFirstChild(BUTTON_NAME)
	if button and button:IsA("GuiButton") then
		-- An inventory card only shows: `EquipToggle` equips, with the selected
		-- card.
		entry.Maid:GiveTask(button.Activated:Connect(function()
			self:Select(unitName)
		end))

		-- The mouse users' shortcut: right-click selects **and** equips, without
		-- going through `EquipToggle`. `MouseButton2Click` only exists for the real right
		-- button, so touch and gamepad stay on the normal click, which is
		-- selection only. Equipping is the toggle's same `_requestEquip`: the same
		-- caps, the same warning when it cannot, the same card flying to the free slot.
		entry.Maid:GiveTask(button.MouseButton2Click:Connect(function()
			self:Select(unitName)
			self:_requestEquip(unitName)
		end))
	end

	-- A row born with the panel already open comes in ready: the entrance animation is
	-- only for opening.
	if self.IsOpenState then
		applyIntroEnd(entry.Intro)
	end

	wrapper.Parent = self.List

	return entry
end

--[=[
	Clears every row. Only on bind and at the end of the controller's life: the normal
	redraw removes them one by one.
]=]
function DeckController:_clearInventory()
	for _, entry in self.InventoryByUnit do
		entry.Maid:DoCleaning()
	end

	self.InventoryEntries = {}
	self.InventoryByUnit = {}
end

--[=[
	Where the cell at `index` sits inside the list, in pixels.

	The math is `UIGridLayout`'s own (cell + spacing, filling horizontally), and it serves
	to know how far a row moved **without** waiting for the layout to recompute: reading
	`AbsolutePosition` right after changing `LayoutOrder` still returns the old value, and
	waiting a frame would make the card flash at the new position before going back to
	animate.

	It only holds for the grid as built (aligned top-left). If the alignment changes, the
	last incomplete row comes out slightly off; the rest still works.
]=]
function DeckController:_cellOffset(index : number) : Vector2
	local grid = self.Grid
	local list = self.List

	if not grid or not list then
		return Vector2.zero
	end

	local cell = grid.AbsoluteCellSize
	local size = list.AbsoluteSize
	local padding = grid.CellPadding

	local padX = padding.X.Scale * size.X + padding.X.Offset
	local padY = padding.Y.Scale * size.Y + padding.Y.Offset

	local columns = grid.FillDirectionMaxCells

	-- Zero means "as many as fit": the math is the same the layout does.
	if columns <= 0 then
		columns = math.max(1, math.floor((size.X + padX) / math.max(cell.X + padX, 1)))
	end

	local slot = index - 1

	return Vector2.new(
		(slot % columns) * (cell.X + padX),
		math.floor(slot / columns) * (cell.Y + padY)
	)
end

function DeckController:_cancelSlide(entry)
	if entry.SlideTween then
		entry.SlideTween:Cancel()
		entry.SlideTween = nil
	end
end

--[=[
	Takes the card from the old cell to the new one.

	The wrapper is already in the new cell (`UIGridLayout` puts it there, instantly). What
	is done here is offsetting the card inside by the difference between the two cells, so
	it stays **exactly where it was** on screen, and from there bringing it back to rest
	with an animation.

	The offset is in pixels added to the card's authored scale position, so the tween's
	target is always its resting position.
]=]
function DeckController:_slideCard(entry, fromIndex : number, toIndex : number)
	if not self.IsOpenState or not entry.Card.Visible then
		return
	end

	local offset = self:_cellOffset(fromIndex) - self:_cellOffset(toIndex)

	if offset.Magnitude < 0.5 then
		return
	end

	self:_cancelSlide(entry)

	local resting = entry.Intro.Position

	entry.Card.Position = resting + UDim2.fromOffset(offset.X, offset.Y)

	local tween = TweenService:Create(entry.Card, SLIDE_INFO, { Position = resting })
	entry.SlideTween = tween

	tween.Completed:Connect(function()
		if entry.SlideTween == tween then
			entry.SlideTween = nil
		end
	end)

	tween:Play()
end

function DeckController:_renderInventory(units : { [string]: number }?)
	units = units or self:_getUnits()

	-- The "landed" count: a card flying here still counts as
	-- equipped, so its row keeps the old number (or stays out of the list) until
	-- it lands. Units with no card in the air use the current number.
	local landed = self:_landedTally()
	local incoming = self:_incomingUnits("Unequip")
	local names = self:_sortedUnits(units, landed, incoming)

	local wanted = {}
	for _, unitName in names do
		wanted[unitName] = true
	end

	--[[
		The list is updated in place, not rebuilt.

		Recreating every wrapper on every redraw would make the inventory flash on every
		landing: cards would be destroyed and cloned again, and the scroller's
		`AutomaticCanvasSize` would recompute along. Instead only rows with nothing left to
		show leave, only rows not there yet come in, and the ones that stay only get the new
		counter.
	]]
	for unitName, entry in self.InventoryByUnit do
		if not wanted[unitName] then
			entry.Maid:DoCleaning()
			self.InventoryByUnit[unitName] = nil
		end
	end

	self.InventoryEntries = {}

	for index, unitName in names do
		local entry = self.InventoryByUnit[unitName]

		if not entry then
			entry = self:_createInventoryEntry(unitName)

			if not entry then
				continue
			end

			self.InventoryByUnit[unitName] = entry
		end

		local remaining = (units[unitName] or 0) - (landed[unitName] or 0)

		-- A unit with no copy left but a card on its way: the row stays,
		-- hidden, only so the grid keeps the space where it will land.
		entry.Card.Visible = remaining > 0
		writeCardCount(entry.Card, remaining)

		-- LayoutOrder is the list order: it is what makes a row born in the middle of
		-- an unequip open the gap in the right place, not at the end of the grid.
		local previousIndex = entry.Index

		entry.Index = index
		entry.Wrapper.LayoutOrder = index

		-- A row that changed cell because another left the list: the wrapper goes straight,
		-- the card makes the trip. A freshly created row has nowhere to come from.
		if previousIndex and previousIndex ~= index then
			self:_slideCard(entry, previousIndex, index)
		end

		table.insert(self.InventoryEntries, entry)
	end
end

--[=[
	Rewrites the six slots and the card counter.

	A slot with a card flying **here** keeps its previous number, and keeps showing
	`EmptyCard` if it was empty: that is what holds the landing. The other five change
	right away.

	Each slot shows **one** of three things: the card, the dimmed card (free), or the
	locked cover, with the level it asks for. The deck arriving here was already cleaned by
	`sanitize`, so a locked slot never has an occupant: the level check is about what to
	draw, not about what exists.
]=]
function DeckController:_renderSlots()
	self.SlotMaid:DoCleaning()

	local deck = self:_landedDeck()
	local unlocked = self:_getUnlocked()

	for index, slot in self.Slots do
		-- The slot is fixed: what rules is the position in the deck, not the order of arrival.
		local occupant = deck[index]

		if typeof(occupant) ~= "table" then
			occupant = nil
		end

		local locked = index > unlocked

		if slot.Locked then
			slot.Locked.Visible = locked
		end

		if locked then
			-- The level comes from the config, not the authored text: changing the unlock
			-- ladder is one line in `DeckConfig` and nothing here.
			if slot.LockText then
				slot.LockText.Text = string.format(LOCK_TEXT_FORMAT, DeckConfig.slotUnlockLevel(index))
			end

			--[[
				The dimmed card goes **under** the cover: a locked slot is an empty slot not open
				yet, and without it the padlock would sit in a hole in the middle of the row
				instead of over a slot's frame.

				Screen order is tree order (`ZIndexBehavior.Sibling`), and `LockedFrame` comes
				after `EmptyCard` and also with a higher `ZIndex`: the cover covers the dimmed
				card, not the reverse.
			]]
			slot.Card.Visible = false
			slot.Empty.Visible = true
			slot.Card:SetAttribute("Unit", nil)

			continue
		end

		-- An occupied slot shows the card, a free slot shows the dimmed card. The two
		-- never show together.
		slot.Card.Visible = occupant ~= nil
		slot.Empty.Visible = occupant == nil

		if occupant then
			local unitName = occupant.Unit

			self:_fillCard(slot.Card, unitName, occupant.Amount, function()
				self:Select(unitName)
				self:_requestUnequip(unitName)
			end, self.SlotMaid)
		else
			slot.Card:SetAttribute("Unit", nil)
		end
	end

	-- The counter belongs to the deck, so it moves with the slots: drops right away when
	-- a card leaves, goes up when the flying one arrives.
	if self.LimitLabel then
		self.LimitLabel.Text = string.format(LIMIT_FORMAT, DeckConfig.total(deck), self.Limit)
	end
end

--[=[
	The card-flip sound. It plays when a card **changes sides** (leaves the inventory for
	the deck, or returns), not on the click: selecting a card moves nothing.

	It goes out with the clone, not on landing: the sound is the response to the click.
]=]
function DeckController:_playCardSound()
	local music = self.Controllers.MusicController

	if music then
		music:PlaySFX(CARD_SOUND)
	end
end

--[=[
	Whether there is still a copy of the unit in the inventory to put in the deck.

	It reads `Projected`, not what is drawn: the card still in the air is already saved on
	the profile, and counting by the screen would let the player equip the same copy twice.
]=]
function DeckController:_hasSpare(unitName : string) : boolean
	local owned = self:_getUnits()[unitName] or 0

	return owned - DeckConfig.countOf(self.Projected, unitName) > 0
end

--[=[
	The equip button: one card of the selected unit per click, and the **only** way to put
	a card in the deck: an inventory card only selects.

	It **hides** when no copy is left in the inventory, that is, when the unit is entirely
	in the deck and there is nothing left to equip. There is no unequip state here: to
	remove a card, click the card in the deck itself.

	Color and text are rewritten along with visibility so the button never depends on how
	the GUI copy arrived.
]=]
function DeckController:_renderEquipToggle(unitName : string)
	local toggle = self.EquipToggle
	if not toggle then
		return
	end

	toggle.Visible = self:_hasSpare(unitName)

	if not toggle.Visible then
		return
	end

	if self.EquipColor then
		toggle.ImageColor3 = self.EquipColor
	end

	if self.EquipLabel then
		self.EquipLabel.Text = EQUIP_TEXT
	end

	if self.EquipStrokeObject and self.EquipStroke then
		self.EquipStrokeObject.Color = self.EquipStroke
	end
end

--[=[
	Writes the selected card's detail panel. With no selection it hides: that is the state
	the panel opens in.
]=]
function DeckController:_renderSelection()
	local container = self.Container
	if not container then
		return
	end

	local unitName = self.SelectedUnit
	local stats = unitName and UnitStats[unitName]

	if not stats then
		container.Visible = false
		return
	end

	local card = container:FindFirstChild(CARD_NAME)

	if card then
		writeCardImage(card, unitName)
	end

	local nameLabel = card and card:FindFirstChild(UNIT_NAME_NAME)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = unitName
		nameLabel.Visible = true

		local stroke = nameLabel:FindFirstChildOfClass("UIStroke")
		local color = RarityConfig.getColor(stats.Rarity)

		if stroke and color then
			stroke.Color = color
		end
	end

	local damage = container:FindFirstChild(DAMAGE_NAME)
	if damage and damage:IsA("TextLabel") then
		damage.Text = formatDamageOrIncome(unitName)
	end

	local cooldown = container:FindFirstChild(COOLDOWN_NAME)
	if cooldown and cooldown:IsA("TextLabel") then
		cooldown.Text = formatNumber(UpgradeConfig:GetCooldown(unitName, 0), 2) .. " COOLDOWN"
	end

	local range = container:FindFirstChild(RANGE_NAME)
	if range and range:IsA("TextLabel") then
		range.Text = formatStat(UpgradeConfig:GetRange(unitName, 0)) .. " RANGE"
	end

	-- A unit with no class (or a class with no art yet) hides the icon instead of
	-- showing an empty square: the same rule as Game's upgrade card.
	local classIcon = container:FindFirstChild(CLASS_ICON_NAME)
	if classIcon and classIcon:IsA("ImageLabel") then
		local image = ClassConfig.GetIcon(unitName)

		classIcon.Image = image or ""
		classIcon.Visible = image ~= nil
	end

	self:_renderEquipToggle(unitName)

	container.Visible = true
end

--[=[
	The cards' entrance: all leave from the wrapper's corner, transparent, and fall into
	place one after another.

	A slot's two sides (the card and the empty card) come in together, with the same delay:
	only one of the two is visible, and giving each its own delay would open a gap in the
	order.

	The delay lives in the `TweenInfo` itself, not a `task.delay`: until it expires, the
	tween writes nothing and the card stays where `applyIntroStart` left it.
]=]
function DeckController:_playIntro()
	self.AnimMaid:DoCleaning()

	-- The entrance repositions every card: a list slide still running
	-- would fight it over the same property.
	for _, entry in self.InventoryEntries do
		self:_cancelSlide(entry)
	end

	local groups = {}

	for _, entry in self.InventoryEntries do
		if entry.Intro then
			table.insert(groups, { entry.Intro })
		end
	end

	for _, slot in self.Slots do
		table.insert(groups, { slot.CardIntro, slot.EmptyIntro })
	end

	for _, group in groups do
		for _, entry in group do
			applyIntroStart(entry)
		end
	end

	for index, group in groups do
		local delay = math.min((index - 1) * INTRO_STAGGER, INTRO_MAX_DELAY)
		local moveInfo = TweenInfo.new(INTRO_MOVE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, delay)
		local fadeInfo = TweenInfo.new(INTRO_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay)

		for _, entry in group do
			self:_playTween(entry.Card, moveInfo, { Position = entry.Position }, self.AnimMaid)

			for _, fade in entry.Fades do
				self:_playTween(fade.Object, fadeInfo, fade.Goal, self.AnimMaid)
			end
		end
	end
end

function DeckController:_hideError()
	self.ErrorToken += 1

	if self.ErrorLabel then
		self.ErrorLabel.Visible = false
	end
end

--[=[
	Lights the red warning for a few seconds. With no text, the text authored in the GUI
	comes back, which is the no-free-slot case.
]=]
function DeckController:_showError(message : string?)
	local label = self.ErrorLabel
	if not label then
		return
	end

	label.Text = message or self.DefaultError

	self.ErrorToken += 1
	local token = self.ErrorToken

	label.Visible = true

	task.delay(ERROR_DURATION, function()
		if self.ErrorToken ~= token or not label.Parent then
			return
		end

		label.Visible = false
	end)
end

--[=[
	The message for each server refusal. Only what the client's check let through gets
	here: a lagging replica, or two tabs of the same player.
]=]
function DeckController:_errorMessage(reason : string?, unitName : string) : string?
	if reason == "LimitReached" then
		return string.format(LIMIT_ERROR, self.Limit, self.Limit)
	end

	if reason == "NoCopies" or reason == "NotOwned" then
		return string.format(COPIES_ERROR, unitName)
	end

	-- "NoSlot" falls to the authored text; the rest is not something the player causes.
	if reason ~= "NoSlot" then
		log:StudioWarn(`the server refused "{unitName}": {tostring(reason)}.`)
	end

	return nil
end

function DeckController:_playBlur(open : boolean)
	self.BlurMaid:DoCleaning()

	local info = if open then OPEN_INFO else CLOSE_INFO
	local tween = LightingUtil.TweenUIBlur(if open then BLUR_SIZE else 0, info)
	if not tween then
		return
	end

	self.BlurMaid:GiveTask(function()
		tween:Cancel()
	end)
end

--[=[
	The loadout is the only thing on screen while it is open, like the shops and contracts.

	The `InterfaceController` request can only hide whole ScreenGuis, and `CardUI` lives
	**inside** `HUD`: the request leaves `HUD` out, and `CardUI`'s neighbors (`HUDFrame`,
	`HUDMiddle`, `HUDLeft`) are dimmed here. Only those that were lit leave, and only those
	come back: a frame another owner had already hidden stays hidden.
]=]
function DeckController:_claimScreen()
	self.ScreenClaimed = true

	local interface = self.Controllers.InterfaceController
	if interface then
		interface:Hide(HIDE_REASON, { Except = { HUD_UI_NAME } })
	end

	local cardUI = self.CardUI
	local hud = cardUI and cardUI.Parent

	if hud then
		for _, sibling in hud:GetChildren() do
			if sibling ~= cardUI and sibling:IsA("GuiObject") and sibling.Visible then
				sibling.Visible = false
				table.insert(self.HiddenSiblings, sibling)
			end
		end
	end

	self:_playBlur(true)
end

--[=[
	Gives the screen back: the rest of the UI returns and the blur leaves. It only acts if
	the loadout asked for the screen: bind always calls this, and lowering the blur there
	would clear that of a shop that was open.
]=]
function DeckController:_releaseScreen()
	if not self.ScreenClaimed then
		return
	end

	self.ScreenClaimed = false

	local interface = self.Controllers.InterfaceController
	if interface then
		interface:Show(HIDE_REASON)
	end

	for _, sibling in self.HiddenSiblings do
		if sibling.Parent then
			sibling.Visible = true
		end
	end

	table.clear(self.HiddenSiblings)

	self:_playBlur(false)
end

function DeckController:_setOpen(open : boolean)
	local cardUI = self.CardUI
	if not cardUI or not cardUI.Parent or not self.Scale then
		return
	end

	if open == self.IsOpenState then
		return
	end

	self.IsOpenState = open
	self.TweenMaid:DoCleaning()

	if open then
		--[[
			The loadout was opened: the button's `New` badge ends here. The player saw the
			cards, and a unit arriving after that lights the badge again on its own.

			Inside `_setOpen`, not the button click, because the panel also opens through
			`Open()`, and opening is opening, wherever it comes from.
		]]
		local badges = self.Controllers.HUDBadgeController
		if badges then
			badges:NoteSeen(HUD_BUTTON_NAME)
		end

		-- The panel opens with no card selected, so the detail starts closed.
		self.SelectedUnit = nil
		self:_render()
		self.Signals.SelectionChanged:Fire(nil)

		self:_claimScreen()

		cardUI.Visible = true
		self.Scale.Scale = 0

		self:_playTween(self.Scale, OPEN_INFO, { Scale = self.ShownScale })
		self:_playIntro()
	else
		self.AnimMaid:DoCleaning()
		self:_hideError()

		-- Given back at the start of the close, as in `ProximityPanel`: the rest of the UI
		-- comes back behind the panel, instead of appearing at once after it leaves.
		self:_releaseScreen()

		-- Closing with a card in the air loses nothing: the swap is already saved on the profile,
		-- and the landing becomes the redraw that happens now.
		if #self.Flights > 0 then
			self:_endAllFlights()
			self:_render()
		end

		local tween = self:_playTween(self.Scale, CLOSE_INFO, { Scale = 0 })
		tween.Completed:Once(function(state : Enum.PlaybackState)
			-- Reopened mid-close: the other tween owns the panel now.
			if state == Enum.PlaybackState.Completed and not self.IsOpenState then
				cardUI.Visible = false
			end
		end)
	end

	self.Signals.OpenChanged:Fire(open)
end

--[=[
	Binds to a copy of CardUI. Runs again on every respawn (`ResetOnSpawn`).
]=]
function DeckController:_bindUI(screenGui : ScreenGui)
	local cardUI = screenGui:WaitForChild(CARD_UI_NAME, WAIT_TIMEOUT)
	local inventory = cardUI and cardUI:WaitForChild(INVENTORY_NAME, WAIT_TIMEOUT)
	local list = inventory and inventory:WaitForChild(LIST_NAME, WAIT_TIMEOUT)
	local equippedFrame = cardUI and cardUI:WaitForChild(EQUIPPED_NAME, WAIT_TIMEOUT)
	local selection = cardUI and cardUI:WaitForChild(SELECTION_NAME, WAIT_TIMEOUT)
	local container = selection and selection:WaitForChild(CONTAINER_NAME, WAIT_TIMEOUT)
	local template = list and list:FindFirstChild(WRAPPER_NAME)

	if not cardUI or not list or not equippedFrame or not container or not template then
		log:StudioWarn(`could not find the {HUD_UI_NAME}.{CARD_UI_NAME} structure.`)
		return
	end

	self:_endAllFlights()

	self.UIMaid:DoCleaning()
	self:_clearInventory()
	self.SlotMaid:DoCleaning()
	self.TweenMaid:DoCleaning()
	self.AnimMaid:DoCleaning()

	self.CardUI = cardUI
	self.List = list

	-- The list's grid: it provides the math for how far a row moved when the
	-- list rearranges (see `_cellOffset`).
	self.Grid = list:FindFirstChildOfClass("UIGridLayout")
	self.Container = container
	local limitLabel = cardUI:FindFirstChild(LIMIT_NAME)
	self.LimitLabel = if limitLabel and limitLabel:IsA("TextLabel") then limitLabel else nil

	local scale = cardUI:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = cardUI
	end

	self.Scale = scale

	-- The "open" scale is the one the designer left in Studio, read before
	-- any animation touches the value.
	self.ShownScale = if scale.Scale > 0 then scale.Scale else 1

	-- The authored wrapper is the template, not a card: the whole list comes from the
	-- profile inventory. The template lives outside the DataModel and dies with the bind,
	-- or each respawn would leave a copy behind.
	self.Template = template:Clone()
	self.UIMaid:GiveTask(self.Template)

	for _, child in list:GetChildren() do
		if child.Name == WRAPPER_NAME then
			child:Destroy()
		end
	end

	self.InventoryEntries = {}
	self.InventoryByUnit = {}

	self.Slots = {}
	for _, wrapper in equippedFrame:GetChildren() do
		if not wrapper:IsA("GuiObject") or wrapper.Name ~= WRAPPER_NAME then
			continue
		end

		local card = wrapper:FindFirstChild(CARD_NAME)
		local emptyCard = wrapper:FindFirstChild(EMPTY_CARD_NAME)

		if not card or not emptyCard then
			log:StudioWarn(`{WRAPPER_NAME} has no {CARD_NAME} or {EMPTY_CARD_NAME}.`)
			continue
		end

		-- The locked slot's cover. Optional on purpose: without it a locked slot only
		-- stops accepting cards, instead of the whole panel failing to draw.
		local lockedFrame = wrapper:FindFirstChild(LOCKED_FRAME_NAME)
		local lockText = lockedFrame and lockedFrame:FindFirstChild(LOCK_TEXT_NAME, true)

		if not lockedFrame then
			log:StudioWarn(`{WRAPPER_NAME} has no {LOCKED_FRAME_NAME}; the locked slot shows no padlock.`)
		end

		-- The empty card is the same card, dimmed: it follows the tilt the
		-- designer gave the slot's full card (-4 or 4), or the free slot leans
		-- the wrong way.
		emptyCard.Rotation = card.Rotation

		-- The six wrappers all come with LayoutOrder 0, and then the on-screen order is the
		-- Explorer order. Stamping the index keeps the first slot always in
		-- first place, without changing anything the designer built.
		wrapper.LayoutOrder = #self.Slots + 1

		table.insert(self.Slots, {
			Wrapper = wrapper,
			Card = card,
			Empty = emptyCard,
			Locked = lockedFrame,
			LockText = if lockText and lockText:IsA("TextLabel") then lockText else nil,
			CardIntro = captureIntro(card),
			EmptyIntro = captureIntro(emptyCard),
		})
	end

	if #self.Slots ~= DeckConfig.MAX_SLOTS then
		log:StudioWarn(`{EQUIPPED_NAME} has {#self.Slots} slots and DeckConfig expects {DeckConfig.MAX_SLOTS}.`)
	end

	local toggle = container:FindFirstChild(EQUIP_TOGGLE_NAME)
	local toggleLabel = toggle and toggle:FindFirstChildWhichIsA("TextLabel")

	self.EquipToggle = toggle
	self.EquipLabel = toggleLabel
	self.EquipStrokeObject = toggleLabel and toggleLabel:FindFirstChildOfClass("UIStroke")

	-- The authored state is "can equip": stored from the first copy, the
	-- only one guaranteed untouched.
	if not self.EquipColor and toggle then
		self.EquipColor = toggle.ImageColor3
		self.EquipStroke = self.EquipStrokeObject and self.EquipStrokeObject.Color
	end

	if toggle and toggle:IsA("GuiButton") then
		self.UIMaid:GiveTask(toggle.Activated:Connect(function()
			self:EquipSelected()
		end))
	end

	self.ErrorLabel = cardUI:FindFirstChild(ERROR_NAME)

	if self.ErrorLabel and not self.DefaultError then
		self.DefaultError = self.ErrorLabel.Text
	end

	local errorButton = self.ErrorLabel and self.ErrorLabel:FindFirstChild(BUTTON_NAME)
	if errorButton and errorButton:IsA("GuiButton") then
		self.UIMaid:GiveTask(errorButton.Activated:Connect(function()
			self:_hideError()
		end))
	end

	-- `Close` may be a TextLabel with a `Button` inside or the button itself:
	-- both shapes work.
	local close = cardUI:FindFirstChild(CLOSE_NAME)
	local closeButton = if close and close:IsA("GuiButton")
		then close
		else close and close:FindFirstChild(BUTTON_NAME)

	if closeButton and closeButton:IsA("GuiButton") then
		self.UIMaid:GiveTask(closeButton.Activated:Connect(function()
			self:Close()
		end))
	end

	-- A new copy means a respawn: the panel comes back closed and with no selection. Dying
	-- with it open would leave the screen request up: the player would respawn without the
	-- rest of the UI and with the background blurred.
	self:_releaseScreen()
	self.IsOpenState = false
	self.SelectedUnit = nil
	self:_hideError()

	cardUI.Visible = false
	scale.Scale = 0
	container.Visible = false

	self:_render()
end

--[=[
	Hooks up the HUD button. It lives inside a wrapper, so it is looked up by name at any
	depth of the frame, and `HUDButtonController`, which handles every button up there,
	animates its hover and click.
]=]
function DeckController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, HUD_BUTTON_NAME, WAIT_TIMEOUT)

	if not button or not button:IsA("GuiButton") then
		log:StudioWarn(`could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		-- The same button closes what it opened.
		self:Toggle()
	end))
end

function DeckController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if not child:IsA("ScreenGui") or child.Name ~= HUD_UI_NAME then
			return
		end

		self:_bindUI(child)
		self:_bindHud(child)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[=[
	Holds the profile replica and redraws on every write to `Units`, `EquippedUnits`, or
	`CardLimit`. It is how the result of an equip arrives: the click does not touch the
	screen on its own.
]=]
function DeckController:_watchData()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]

			-- `Stats` is in the list because of XP: slots 4, 5, and 6 open by
			-- level, and without this a level-up would only show on the panel the next time
			-- the player touched the deck. `Gamepasses` is in for the same reason: the
			-- +5 Total Cards pass changes the cap, and buying it mid-session must show.
			if key ~= nil
				and key ~= "Units"
				and key ~= "EquippedUnits"
				and key ~= "CardLimit"
				and key ~= "Stats"
				and key ~= "Gamepasses"
			then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

function DeckController:IsOpen() : boolean
	return self.IsOpenState == true
end

function DeckController:Open()
	self:_setOpen(true)
end

function DeckController:Close()
	self:_setOpen(false)
end

function DeckController:Toggle()
	self:_setOpen(not self.IsOpenState)
end

--[=[
	The card the detail panel shows. `nil` closes the panel.
]=]
function DeckController:Select(unitName : string?)
	if unitName ~= nil and not DeckConfig.exists(unitName) then
		return
	end

	if self.SelectedUnit == unitName then
		return
	end

	self.SelectedUnit = unitName
	self:_renderSelection()
	self.Signals.SelectionChanged:Fire(unitName)
end

--[=[
	What `EquipToggle` does: puts one card of the selected unit in the deck.

	It does nothing without a copy left: in that state the button is invisible, so this
	only applies to callers invoking the method by hand.
]=]
function DeckController:EquipSelected()
	local unitName = self.SelectedUnit
	if not unitName or not self:_hasSpare(unitName) then
		return
	end

	self:_requestEquip(unitName)
end

function DeckController:construct()
	self:_observeUI()
	self:_watchData()

	Framework:Listen("DeckCardResult", function(unitName : string, action : string, success : boolean, reason : string?)
		if success then
			return
		end

		-- The newest trip of that card is the one that did not happen: it vanishes midway
		-- and the screen returns to what the profile says.
		for index = #self.Flights, 1, -1 do
			local flight = self.Flights[index]

			if flight.Unit == unitName and flight.Action == action then
				self:_unproject(action, unitName)
				self:_endFlight(flight)
				break
			end
		end

		self:_showError(self:_errorMessage(reason, unitName))
	end)
end

function DeckController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function DeckController:init()
	self.Maid = Maid.new()
	self.UIMaid = Maid.new()

	-- Each inventory row has its own maid (it enters and leaves the list on its own; see
	-- `_renderInventory`); the slots are fixed instances and fit in a single maid.
	-- Separate because the two sides are redrawn at different times, and
	-- clearing one must not disconnect the other's buttons.
	self.SlotMaid = Maid.new()

	self.TweenMaid = Maid.new()
	self.AnimMaid = Maid.new()
	self.HudMaid = Maid.new()

	-- The blur tween lives outside the bind: it belongs to Lighting, not the HUD.
	self.BlurMaid = Maid.new()

	-- The `CardUI` neighbors the opening dimmed, for the close to restore.
	self.HiddenSiblings = {}
	self.ScreenClaimed = false

	self.Maid:GiveTask(self.UIMaid)
	self.Maid:GiveTask(function()
		self:_clearInventory()
	end)
	self.Maid:GiveTask(self.SlotMaid)
	self.Maid:GiveTask(self.TweenMaid)
	self.Maid:GiveTask(self.AnimMaid)
	self.Maid:GiveTask(self.HudMaid)
	self.Maid:GiveTask(self.BlurMaid)

	self.IsOpenState = false
	self.SelectedUnit = nil

	self.Slots = {}
	self.InventoryEntries = {}
	self.InventoryByUnit = {}
	self.Limit = DeckConfig.DEFAULT_CARD_LIMIT

	-- The cards in the air now. While there is any, the screen is not
	-- redrawn, but clicking still counts, and each click releases one more.
	self.Flights = {}

	-- The deck counting what is still in the air. See `_project`.
	self.Projected = DeckConfig.empty()

	-- Profile unit names that no longer exist, so the warning goes out only once.
	self.WarnedMissing = {}

	self.ErrorToken = 0
end

return DeckController
