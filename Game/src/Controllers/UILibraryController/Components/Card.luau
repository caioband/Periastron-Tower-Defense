local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)
local TowerContainer = Interface:WaitForChild("TowerContainer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("Card")

--[[ CONSTANTS ]]
local WRAPPER_NAME = "CardWrapper"
local CARD_NAME = "Card"
local BUTTON_NAME = "Button"

-- The card inside the wrapper the round shop hands over. It is the button itself,
-- unlike a unit card, which has a `Button` inside.
local ROUND_CARD_NAME = "CardTemplate"
local COUNT_NAME = "Count"
local COST_NAME = "Cost"
local UNIT_NAME_NAME = "UnitName"

local COUNT_LAYER_NAME = "CountLayer"

--[[
	The arc.

	A card drops by the **square** of its distance to the apex, and the drop is measured
	in card heights: that is why changing the card size in Studio opens or closes the
	whole arc on its own, with no number to adjust here.

	The curve is normalized by the farthest card's distance: the one at the end always
	drops `ARC_SPREAD` and always tilts `ARC_TILT`, whatever the deck size and wherever
	the apex is. Without that, choosing the first card of a six-card deck would push the
	last one almost a full height down (the square of 5), out of the container.

	The tilt follows the arc's side: cards left of the apex lean left, cards right of it
	lean right, and the apex stands upright. The eight degrees at the end match the fan
	the authored layout had.
]]
local ARC_SPREAD = 0.23
local ARC_TILT = 8

--[[
	The whole re-layout lasts `ARC_TOTAL_TIME`, from the first move to the last.

	The cards do not all leave together: a slice of the time (`ARC_STAGGER_SHARE`) is
	spent staggering the starts, and what remains is each one's duration. Since the total
	interval is always the same slice, a two-card deck and a six-card deck finish at the
	same instant; only how tight the gap between one and the next gets changes.

	The delay lives in the `TweenInfo` itself, not a `task.delay`: until it expires, the
	tween writes nothing, and canceling the tween cancels the wait too.
]]
local ARC_TOTAL_TIME = 0.3
local ARC_STAGGER_SHARE = 0.4
local ARC_EASING = Enum.EasingStyle.Quad
local ARC_DIRECTION = Enum.EasingDirection.Out

--[[
	Each card's scale comes from two things that **multiply**: where it rests (1, or
	`SELECTED_SCALE` if it is the selected one) times `HOVER_SCALE` while the mouse is over
	it.

	As alternatives, with the larger one winning, they would break: since `HOVER_SCALE` is
	the larger of the two, selecting a card **with the mouse over it** (which is how every
	mouse click happens) would go from 1.2 to 1.2: the card would be selected without
	moving a pixel, and the selection would only show when the mouse moved away. On
	mobile, with no hover, the same selection would animate normally.

	Multiplied, the selected card under the mouse goes to 1.32 and the click responds
	right away; hovering an unselected card stays exactly at 1.2, and a selected card
	without the mouse over it stays at 1.1. Every change is the same tween, so none of
	them jumps.

	The cards overlap a lot, so the one that grows also comes to the front, or it would
	grow underneath its neighbor.
]]
local HOVER_SCALE = 1.2
local SELECTED_SCALE = 1.1
local SCALE_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[[
	How much of the width a card gains when growing is given back as space to its
	neighbors. At 1, the growing card pushes the neighbor exactly as much as it intruded;
	below that, part of the growth is absorbed by the overlap the fan already has.

	The push is symmetric (half to each side), so the hand stays centered however much a
	card in the middle of it grows.
]]
local PUSH_SHARE = 1

local BASE_ZINDEX = 1
local SELECTED_ZINDEX = 5
local HOVER_ZINDEX = 10

--[[
	With no units left, the card does not stay in the hand: it drops out of the deck, and
	the hand only closes its slot when it finishes leaving. When the unit exists again,
	the path is the same in reverse: the slot reopens and the card rises back into the
	arc.

	The drop is measured in card heights, like the rest of the arc, so it still leaves the
	screen entirely if the card size changes.
]]
local EXIT_DROP = 1.2
local EXIT_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local RESTORE_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[[
	With a card selected, **the others** dim a little: them and everything inside, plus
	their counter, which lives outside the card but is part of it.

	The value is a fraction of the way left to full transparency, not a fixed value: that
	way it composes with what the piece already had (a card with no stock is already at
	0.25) without ever passing 1, and each piece's normal state is still what the designer
	left.
]]
local DIM_AMOUNT = 0.35

--[[
	How much a **locked** card dims. Stronger than `DIM_AMOUNT` on purpose: dimming for not
	being selected says "this is not the one now"; dimming for being locked says "this one
	cannot be used now", and the two must not look alike.
]]
local LOCKED_AMOUNT = 0.6

-- Not enough money for the cost: the card goes red, but does not dim.
local NO_CASH_COLOR = Color3.fromRGB(255, 70, 70)

-- One key per hotbar card.
local KEYBINDS = {
	One = 1,
	Two = 2,
	Three = 3,
	Four = 4,
	Five = 5,
	Six = 6,
}

--[=[
	The match hotbar: one card per deck unit, cloned from the `CardWrapper` the designer
	authored in `TowerContainer`.

	The container's `UIListLayout` spreads the **wrappers** horizontally; what this module
	draws is the **card's Y position inside the wrapper** and its tilt, and that is where
	the arc comes from. Keeping the two separate is what lets the arc exist without
	fighting the layout.

	`CardController` feeds this module, through `doComponent`.

	**Not every card in the hand comes from the deck.** Cards bought in the round shop
	(`RoundCardShopController`) come in through `addRound` and sit in `self.entries` just
	like the others: they fall into the arc, grow on hover, get pushed by neighbors, and
	dim when another card is selected. Only the origin differs: their wrapper comes ready
	from another template, and whoever handed them over knows what the click does.

	The difference lives in two `entry` fields:

	| Field | Unit card | Round card |
	| --- | --- | --- |
	| `Kind` | `"Unit"` | `"Round"` |
	| `Unit` | the unit name | `nil` |

	An empty `Unit` is what takes a round card out of everything deck related: price,
	weather, counter, stock, and the notion of "selected card". Everything else (the arc,
	the scale, the dimming, the exit) is the same code.

	See docs/game/hotbar.md.
]=]
local module = {}

module.entries = {}
module.byUnit = {}

-- The round cards in hand now, by purchase `uid`.
module.byRound = {}

module.counts = {}
module.cash = 0
module.selected = nil

--[[
	The selected **round** card, by purchase `uid`.

	It is a state separate from `selected` because the two are not identified the same
	way (a unit card is a unit name, and a round card is a purchase), but both are the
	same idea: what is in the player's hand now. That is why only one of the two can be in
	effect (see `setSelected`), and both go through the same growing and the same dimming
	of neighbors.
]]
module.selectedRound = nil

--[[
	The whole hand hidden without anyone losing their place. `RoundCardShopController`
	turns it on and off while the shop tab is open: the player's cards leave the screen and
	come back exactly as they were.

	It is a component state, not a `Visible` written from outside, precisely because each
	wrapper's `Visible` already has an owner here (`_setPresence`): a card with no units
	left stays off screen on its own, and restoring "everything on" on the way back would
	put it back in the hand.
]]
module.hidden = false

--[[ INTERNAL ]]

--[=[
	The template, taken off the screen the first time someone needs it.

	The authored `CardWrapper` is not a card: it is the drawing of one. It leaves the
	container too, so the hotbar on screen is always 100% deck.

	Each piece's "normal" colors are read from the template, not written here: if the
	designer changes the outline's purple, the normal state follows. The same goes for
	where the counter lives inside the card, which is what `_followCounts` reproduces
	after taking the counter out of it.
]=]
local template : Frame? = nil
local defaults = {}

local function getTemplate() : Frame?
	if template then
		return template
	end

	local authored = TowerContainer:FindFirstChild(WRAPPER_NAME)
	if not authored then
		log:StudioWarn(`could not find the authored {WRAPPER_NAME} in TowerContainer.`)
		return nil
	end

	template = authored:Clone()
	authored:Destroy()

	local card = (template :: Frame):FindFirstChild(CARD_NAME)
	local cost = card and card:FindFirstChild(COST_NAME)
	local countHolder = card and card:FindFirstChild(COUNT_NAME)
	local countLabel = countHolder and countHolder:FindFirstChild(COUNT_NAME)

	defaults = {
		CostStroke = cost and cost:FindFirstChildOfClass("UIStroke") and cost:FindFirstChildOfClass("UIStroke").Color,
		CountImage = countHolder and countHolder.ImageColor3,
		CountStroke = countLabel and countLabel:FindFirstChildOfClass("UIStroke") and countLabel:FindFirstChildOfClass("UIStroke").Color,

		-- Where the counter sits inside the card, in its scale. It is what remains of the
		-- link after it leaves the card.
		CountCenter = countHolder and Vector2.new(
			countHolder.Position.X.Scale + countHolder.Size.X.Scale * (0.5 - countHolder.AnchorPoint.X),
			countHolder.Position.Y.Scale + countHolder.Size.Y.Scale * (0.5 - countHolder.AnchorPoint.Y)
		) or Vector2.new(0.5, 0.5),

		CountSize = countHolder and Vector2.new(countHolder.Size.X.Scale, countHolder.Size.Y.Scale)
			or Vector2.new(0.4, 0.4),
	}

	return template
end

--[=[
	The layer where the counters live.

	They must sit on a single plane, in front of **all** the cards: since the cards
	overlap, a counter that stayed inside its own card would vanish behind the neighboring
	card: `Interface` is `ZIndexBehavior.Sibling`, so a descendant never draws above a
	sibling of its parent.

	The layer is the last child of `TowerContainer` and draws over the wrappers. It also
	enters the `UIListLayout`, so its width is chosen to **cancel its own slot**: with the
	layout's negative spacing, a +12px cell followed by -12px of padding adds up to zero,
	and the cards stay centered exactly where they were.
]=]
local function ensureCountLayer() : Frame?
	local existing = TowerContainer:FindFirstChild(COUNT_LAYER_NAME)
	if existing then
		return existing
	end

	local layout = TowerContainer:FindFirstChildOfClass("UIListLayout")
	local padding = layout and layout.Padding or UDim.new()
	local width = -(padding.Scale * TowerContainer.AbsoluteSize.X + padding.Offset)

	local layer = Instance.new("Frame")
	layer.Name = COUNT_LAYER_NAME
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.Size = UDim2.fromOffset(math.max(width, 0), 0)
	layer.ZIndex = HOVER_ZINDEX + 1

	-- Last in line: that way it draws after every wrapper. (`LayoutOrder` is an
	-- integer, so "infinity" here is just a large number.)
	layer.LayoutOrder = 1e6
	layer.Parent = TowerContainer

	return layer
end

--[=[
	Where the card rests when it is the apex, and how much the arc drops the others. The
	height comes from the card's own size, in wrapper scale.
]=]
local function cardHeightScale(card : GuiObject) : number
	local height = card.Size.Y.Scale

	return if height > 0 then height else 1
end

--[=[
	Which transparency properties each piece type has.
]=]
local function fadeProperties(object : Instance) : { string }?
	if object:IsA("UIStroke") then
		return { "Transparency" }
	elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
		return { "BackgroundTransparency", "ImageTransparency" }
	elseif object:IsA("TextLabel") or object:IsA("TextButton") then
		return { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" }
	elseif object:IsA("GuiObject") then
		return { "BackgroundTransparency" }
	end

	return nil
end

--[=[
	The transparencies the card has **before** anything touches it, one entry per piece:
	the card, the texts, the outlines, and the counter.

	They are read from the freshly made clone, so "back to the original state" is literal:
	the fade's target is always what the designer left on the template, not a value
	written here.
]=]
local function captureFades(roots : { Instance? })
	local fades = {}

	local function add(object : Instance)
		local properties = fadeProperties(object)
		if not properties then
			return
		end

		local values = {}
		for _, property in properties do
			values[property] = (object :: any)[property]
		end

		table.insert(fades, { Object = object, Values = values })
	end

	for _, root in roots do
		if not root then
			continue
		end

		add(root)
		for _, descendant in root:GetDescendants() do
			add(descendant)
		end
	end

	return fades
end

--[=[
	The card's authored width in pixels, **without** the scale.

	It is read from `Size` against the wrapper, not from `AbsoluteSize`: during the hover
	tween the absolute value is halfway there, and the push would chase its own effect.
	Read at the moment, it also follows the window changing size.
]=]
function module:_cardWidth(entry) : number
	local size = entry.Card.Size

	return size.X.Scale * entry.Wrapper.AbsoluteSize.X + size.X.Offset
end

--[=[
	The cards in hand now. A card with no units left has left the deck, so it counts for
	neither the arc nor the shortcuts: the hand closes its slot.
]=]
function module:_liveEntries()
	local live = {}

	for _, entry in self.entries do
		if entry.Available ~= false then
			table.insert(live, entry)
		end
	end

	return live
end

--[=[
	Where the card rests when it is out of the hand: straight below its place, far enough
	to leave the screen entirely.
]=]
function module:_exitGoal(entry) : UDim2
	local base = entry.BasePosition

	return UDim2.new(
		base.X.Scale, base.X.Offset,
		base.Y.Scale + EXIT_DROP * entry.Height, base.Y.Offset
	)
end

--[=[
	Removes (or restores) the card from the screen.

	There are two halves: the wrapper, which occupies the slot in the row, and the counter,
	which lives on the upper layer and therefore does **not** disappear with it.
	Forgetting the second would leave the number of a card that already left floating in
	the hotbar.

	`present` is stored in the entry itself because it is the **intent** ("should this card
	be in the hand?"), and the whole hand may be hidden on top of that (`setHidden`).
	Without separating the two, leaving the shop tab would also light back up the cards
	that were off screen for having no units left.
]=]
function module:_setPresence(entry, present : boolean)
	entry.Present = present

	local visible = present and not self.hidden

	entry.Wrapper.Visible = visible

	if entry.Badge then
		entry.Badge.Visible = visible
	end
end

--[=[
	Puts the card in or takes it out of the hand.

	**Taking it out** is a half-second drop, and its slot only closes when it finishes
	falling, which is why `_layout` comes from `Completed`, not from here. **Putting it
	back** is the reverse: the slot reopens right away and the card rises from where it
	stopped.

	`instant` is for building the hand, where a card born with no units has nowhere to
	fall from; callers doing that also take care of `_layout`.
]=]
function module:_setAvailable(entry, available : boolean, instant : boolean?) : boolean
	if entry.Available == available then
		return false
	end

	entry.Available = available

	-- While the card enters or leaves, this tween owns its position.
	entry.ExitMaid:DoCleaning()
	entry.ArcMaid:DoCleaning()

	if not available then
		if instant then
			entry.Card.Position = self:_exitGoal(entry)
			self:_setPresence(entry, false)

			return true
		end

		local tween = TweenService:Create(entry.Card, EXIT_INFO, { Position = self:_exitGoal(entry) })

		entry.ExitMaid:GiveTask(function()
			tween:Cancel()
		end)

		tween.Completed:Connect(function(state : Enum.PlaybackState)
			-- Canceled is the path of a card that came back mid-drop.
			if state ~= Enum.PlaybackState.Completed or entry.Available then
				return
			end

			self:_setPresence(entry, false)
			self:_layout()
		end)

		tween:Play()

		return true
	end

	self:_setPresence(entry, true)

	if instant then
		return true
	end

	-- `_layout` takes the card from where it stopped to its slot, at the return timing.
	entry.Returning = true
	self:_layout()

	return true
end

--[=[
	The index of the arc's apex: the middle of the deck.

	The middle card when the count is odd, and the **two** middle ones when it is even:
	both are the same distance from `(n+1)/2`, so both rise together.

	The selected card does not move the apex: its scale (`SELECTED_SCALE`) shows it is
	selected, not its position.
]=]
function module:_vertex(count : number) : number
	return (count + 1) / 2
end

--[=[
	Repositions and tilts **all** the cards. Runs when the deck changes size and when the
	apex moves.

	The card (or the two) at the apex stays exactly where the designer left it on the
	template and upright; the one farthest from it drops `ARC_SPREAD` and tilts `ARC_TILT`,
	and the rest spread between those two extremes: the drop by the square of the
	distance, the tilt by the signed distance.

	Measuring against the list's smallest and largest square is what solves both cases at
	once: with an even count and no selection, the **two** middle ones tie at the smallest
	distance and rise together; with the apex at one end, the card at the other end stops
	in the usual place instead of leaving through the bottom of the container.

	The cards leave staggered, left to right, and the last one ends at `ARC_TOTAL_TIME`
	counted from the very start.
]=]
function module:_layout(instant : boolean?)
	local live = self:_liveEntries()
	local count = #live

	if count == 0 then
		return
	end

	local vertex = self:_vertex(count)

	local closest, farthest = math.huge, 0
	for index = 1, count do
		local square = (index - vertex) ^ 2

		closest = math.min(closest, square)
		farthest = math.max(farthest, square)
	end

	-- A one-card deck (or two, with no selection): all tie, and the arc is a straight
	-- line at the template's height.
	local span = farthest - closest
	local reach = math.sqrt(farthest)

	-- The stagger: the last card starts at `spread` and ends with the total,
	-- because `spread + duration` is exactly `ARC_TOTAL_TIME`.
	-- A single card has no one to stagger against, so all the time becomes duration.
	local spread = if count > 1 then ARC_TOTAL_TIME * ARC_STAGGER_SHARE else 0
	local duration = ARC_TOTAL_TIME - spread
	local step = if count > 1 then spread / (count - 1) else 0

	--[[
		How much extra space each card asks for for being grown.

		The width comes from the card's authored size at the moment (`_cardWidth`), not a
		stored number: that way changing the card's `Size` also re-lays out the deck, not
		only changing its scale.
	]]
	local extra = {}
	for index, entry in live do
		extra[index] = ((entry.ScaleTarget or 1) - 1) * self:_cardWidth(entry) * PUSH_SHARE
	end

	for index, entry in live do
		local distance = index - vertex
		local square = distance * distance

		local ratio = if span > 0 then (square - closest) / span else 0
		local drop = ARC_SPREAD * entry.Height * ratio
		local tilt = if reach > 0 then ARC_TILT * (distance / reach) else 0

		-- Cards to the left of a grown card move left, cards to the right move
		-- right, and the card itself does not move.
		local shift = 0
		for other = 1, count do
			if other < index then
				shift += extra[other] / 2
			elseif other > index then
				shift -= extra[other] / 2
			end
		end

		local base = entry.BasePosition
		local goal = {
			Position = UDim2.new(base.X.Scale, base.X.Offset + shift, base.Y.Scale + drop, base.Y.Offset),
			Rotation = entry.BaseRotation + tilt,
		}

		entry.ArcMaid:DoCleaning()

		if instant then
			entry.Card.Position = goal.Position
			entry.Card.Rotation = goal.Rotation
			continue
		end

		-- A card returning to the hand makes the whole trip at the return timing; the rest
		-- of the deck settles with the usual stagger.
		local info = if entry.Returning
			then RESTORE_INFO
			else TweenInfo.new(duration, ARC_EASING, ARC_DIRECTION, 0, false, (index - 1) * step)

		entry.Returning = false

		local tween = TweenService:Create(entry.Card, info, goal)
		entry.ArcMaid:GiveTask(function()
			tween:Cancel()
		end)

		tween:Play()
	end
end

--[=[
	Sticks each counter to its card.

	The counter left the card so it can draw in front of all of them, so the link that was
	parenting became this computation, redone every frame: the center comes from the
	position it had inside the card, rotated by the card's tilt and measured on the card's
	**absolute** size, which already includes the hover's `UIScale`. Hovering grows the
	card and the counter together.
]=]
function module:_followCounts()
	local layerPosition = self.CountLayer and self.CountLayer.AbsolutePosition
	if not layerPosition then
		return
	end

	for _, entry in self.entries do
		local badge = entry.Badge
		if not badge or not badge.Visible then
			continue
		end

		local card = entry.Card
		local size = card.AbsoluteSize
		local center = card.AbsolutePosition + size / 2

		local offset = Vector2.new(
			(defaults.CountCenter.X - 0.5) * size.X,
			(defaults.CountCenter.Y - 0.5) * size.Y
		)

		local radians = math.rad(card.Rotation)
		local sin, cos = math.sin(radians), math.cos(radians)

		local rotated = Vector2.new(
			offset.X * cos - offset.Y * sin,
			offset.X * sin + offset.Y * cos
		)

		local badgeCenter = center + rotated - layerPosition

		badge.Position = UDim2.fromOffset(badgeCenter.X, badgeCenter.Y)
		badge.Size = UDim2.fromOffset(size.X * defaults.CountSize.X, size.Y * defaults.CountSize.Y)
		badge.Rotation = card.Rotation
	end
end

local function getParts(card : GuiObject, badge : GuiObject?)
	local countLabel = badge and badge:FindFirstChild(COUNT_NAME)
	local costLabel = card:FindFirstChild(COST_NAME)

	return {
		Card = card,
		Cost = costLabel,
		CostStroke = costLabel and costLabel:FindFirstChildOfClass("UIStroke"),
		CountHolder = badge,
		CountLabel = countLabel,
		CountStroke = countLabel and countLabel:FindFirstChildOfClass("UIStroke"),
		UnitName = card:FindFirstChild(UNIT_NAME_NAME),
	}
end

--[=[
	The weather in the sky, the way `ToggleTower` also asks.

	Asked at the moment instead of cached: the card price is rewritten at only two moments
	(when the card is born and when the weather changes), and at both the right answer is
	the current one.
]=]
local function getWeather()
	local weatherController = Framework:Get("WeatherController", false, false)
	return weatherController and weatherController:GetCurrent() or nil
end

--[=[
	What placing the unit costs now, with the weather discount if any (rain takes 25% off
	Ice).

	The same function the server charges in `PlaceUnit`, on purpose: it keeps the card
	from showing one price while placement charges another.
]=]
local function placeCost(unitName : string?) : number
	if not unitName then return 0 end

	return SharedConfig.UnitUpgradeConfig:GetPlaceCost(unitName, getWeather())
end

-- The card's visual state: out of stock takes priority over lack of money, since
-- without units the card cannot be used at all.
function module:_resolveState(unitName : string?) : string
	if unitName and SharedConfig.UnitStats[unitName] and self.cash < placeCost(unitName) then
		return "NoCash"
	end

	return "Available"
end

--[=[
	Writes the price on the card. It is its own function because the price is not fixed:
	a weather that changes `Cost` entering or leaving rewrites all of them.
]=]
function module:_writeCost(entry)
	if not entry.Parts.Cost then return end

	entry.Parts.Cost.Text = "$" .. placeCost(entry.Unit)
end

--[=[
	Writes each card piece's transparency.

	Today there is only one reason for a piece to dim: `Dimmed`, meaning "another card is
	selected". The math always starts from the authored value, so undoing it restores
	exactly the original.
]=]
function module:_applyTransparency(entry)
	entry.FadeMaid:DoCleaning()

	-- Locked outranks dimmed: both are the same channel, and the stronger is the one
	-- the player needs to understand first.
	local dim = if entry.Locked then LOCKED_AMOUNT elseif entry.Dimmed then DIM_AMOUNT else 0

	for _, fade in entry.Fades do
		local goal = {}

		for property, authored in fade.Values do
			goal[property] = authored + (1 - authored) * dim
		end

		local tween = TweenService:Create(fade.Object, SCALE_INFO, goal)
		entry.FadeMaid:GiveTask(function()
			tween:Cancel()
		end)

		tween:Play()
	end
end

function module:_applyState(entry)
	local state = self:_resolveState(entry.Unit)
	if entry.State == state then
		return
	end

	entry.State = state

	local parts = entry.Parts

	self:_applyTransparency(entry)

	local costStroke = defaults.CostStroke
	local countImage = defaults.CountImage
	local countStroke = defaults.CountStroke

	if state == "NoCash" then
		costStroke = NO_CASH_COLOR
		countImage = NO_CASH_COLOR
		countStroke = NO_CASH_COLOR
	end

	if parts.CostStroke and costStroke then
		parts.CostStroke.Color = costStroke
	end

	if parts.CountHolder and countImage then
		parts.CountHolder.ImageColor3 = countImage
	end

	if parts.CountStroke and countStroke then
		parts.CountStroke.Color = countStroke
	end
end

--[=[
	Writes the counter and decides whether the card stays in the hand: at zero, it drops
	out; with units again, it rises back.
]=]
function module:_writeCount(entry, instant : boolean?)
	if entry.Parts.CountLabel then
		entry.Parts.CountLabel.Text = tostring(self.counts[entry.Unit] or 0) .. "x"
	end

	self:_setAvailable(entry, (self.counts[entry.Unit] or 0) > 0, instant)
	self:_applyState(entry)
end

--[=[
	With a card selected, all the others dim a little. With no selection (or on the
	selected card itself), nothing dims.
]=]
function module:_setDimmed(entry)
	local hasSelection = self.selected ~= nil or self.selectedRound ~= nil
	local dimmed = hasSelection and not self:_isSelected(entry)

	if entry.Dimmed == dimmed then
		return
	end

	entry.Dimmed = dimmed
	self:_applyTransparency(entry)
end

--[=[
	Whether this is the card in the player's hand now.

	A round card is identified by the purchase `uid` and a unit card by the unit name, so
	the question is one but the key differs. The `~= nil` on both sides is not a detail:
	without it, `nil == nil` would make **every** round card "selected" whenever no unit
	was equipped.
]=]
function module:_isSelected(entry) : boolean
	if entry.Uid ~= nil then
		return entry.Uid == self.selectedRound
	end

	return entry.Unit ~= nil and entry.Unit == self.selected
end

--[=[
	Where the card's scale rests when the mouse is not over it: 1.1 if it is the selected
	one, 1 otherwise.
]=]
function module:_restScale(entry) : number
	return if self:_isSelected(entry) then SELECTED_SCALE else 1
end

--[=[
	Takes the card's scale to the state it should be in. A single tween for every change
	(mouse entering and leaving, being selected, stopping being selected), so none of them
	jumps.

	It bails out when the target did not change: without that, a `setSelected` that does
	not touch this card would restart its animation mid-way. Returns whether it changed,
	because a card that changes size re-lays out the deck, and the caller knows whether
	that is one card or several at once.
]=]
function module:_applyScale(entry) : boolean
	local target = self:_restScale(entry)
	if entry.Hovered then
		target *= HOVER_SCALE
	end

	if entry.ScaleTarget == target then
		return false
	end

	entry.ScaleTarget = target
	entry.ScaleMaid:DoCleaning()

	local tween = TweenService:Create(entry.Scale, SCALE_INFO, { Scale = target })
	entry.ScaleMaid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()

	return true
end

function module:_setHovered(entry, hovered : boolean)
	entry.Hovered = hovered

	self:_refreshDepth(entry)

	if self:_applyScale(entry) then
		self:_layout()
	end
end

--[=[
	Who is in front of whom. The card under the mouse beats all; the selected one stays
	in front of its neighbors, because it is bigger than them and must not grow underneath.
]=]
function module:_refreshDepth(entry)
	if entry.Hovered then
		entry.Wrapper.ZIndex = HOVER_ZINDEX
		return
	end

	entry.Wrapper.ZIndex = if self:_isSelected(entry) then SELECTED_ZINDEX else BASE_ZINDEX
end

--[=[
	Builds the `entry` of an already drawn card and puts it in the hand.

	Everything about the arc lives here, and none of it knows where the card came from:
	the scale, the resting position and rotation, the transparency list for dimming, the
	maids, and the button's three events. It is what makes a card bought in the shop
	behave exactly like a unit card: it falls into the arc, grows on hover, pushes its
	neighbors, and dims when another is selected, through the same code.

	The caller says what is specific to the origin:

	| Field | What it is |
	| --- | --- |
	| `Wrapper` / `Card` | the two pieces: the wrapper takes the slot in the row, the card is what animates |
	| `Button` | what receives the click; a unit card has a `Button` inside, a round card is the button itself |
	| `Badge` | the counter, already moved to the upper layer (only unit cards have one) |
	| `Activate` | what the click (and the keyboard shortcut) does |
]=]
function module:_buildEntry(config)
	local wrapper = config.Wrapper
	local card = config.Card
	local badge = config.Badge

	local scale = card:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = card
	end

	wrapper.LayoutOrder = config.Index
	wrapper.ZIndex = BASE_ZINDEX

	local entry = {
		Kind = config.Kind,
		Unit = config.Unit,

		-- Only round cards have it: it is the purchase `uid`, and it is how the card is
		-- the selected one (see `_isSelected`).
		Uid = config.Uid,

		Activate = config.Activate,

		Index = config.Index,
		Wrapper = wrapper,
		Card = card,
		Badge = badge,
		Scale = scale,
		Parts = getParts(card, badge),
		Height = cardHeightScale(card),

		-- The template's position and rotation are the apex's: the arc drops and tilts
		-- from them.
		BasePosition = card.Position,
		BaseRotation = card.Rotation,

		Hovered = false,
		Dimmed = false,
		ScaleTarget = 1,
		Present = true,

		-- Read from the untouched clone: any dimming returns here.
		Fades = captureFades({ card, badge }),

		Maid = Maid.new(),
		ArcMaid = Maid.new(),
		ScaleMaid = Maid.new(),
		FadeMaid = Maid.new(),
		ExitMaid = Maid.new(),
	}

	entry.Maid:GiveTask(wrapper)
	entry.Maid:GiveTask(entry.ArcMaid)
	entry.Maid:GiveTask(entry.ScaleMaid)
	entry.Maid:GiveTask(entry.FadeMaid)
	entry.Maid:GiveTask(entry.ExitMaid)

	-- The counter no longer lives in the wrapper, so it does not die with it.
	if badge then
		entry.Maid:GiveTask(badge)
	end

	-- Changing the card size (in Studio, or at runtime) re-lays out the
	-- deck through the same path as the scale.
	entry.Maid:GiveTask(card:GetPropertyChangedSignal("Size"):Connect(function()
		self:_layout()
	end))

	local button = config.Button
	if button and button:IsA("GuiButton") then
		entry.Maid:GiveTask(button.Activated:Connect(function()
			entry.Activate()
		end))

		entry.Maid:GiveTask(button.MouseEnter:Connect(function()
			self:_setHovered(entry, true)
		end))

		entry.Maid:GiveTask(button.MouseLeave:Connect(function()
			self:_setHovered(entry, false)
		end))
	end

	wrapper.Parent = TowerContainer

	return entry
end

--[=[
	The row order is what decides the arc: `_vertex` counts from it, and `UIListLayout`
	spreads the wrappers by it.

	It walks all of `self.entries` instead of keeping a counter because the list changes
	from both sides: the deck is rebuilt from scratch on every change, and round cards come
	and go in the middle of all that.
]=]
function module:_reindex()
	for index, entry in self.entries do
		entry.Index = index
		entry.Wrapper.LayoutOrder = index
	end
end

function module:_createEntry(unitName : string, index : number, callbackDo : (string) -> ())
	local wrapper = (getTemplate() :: Frame):Clone()
	local card = wrapper:FindFirstChild(CARD_NAME)

	if not card or not card:IsA("GuiObject") then
		wrapper:Destroy()
		return nil
	end

	wrapper.Name = unitName

	-- The counter leaves the card for the upper layer, where it does not vanish behind
	-- the neighboring card. `_followCounts` keeps it stuck to the card.
	local badge = card:FindFirstChild(COUNT_NAME)
	if badge and self.CountLayer then
		badge.AnchorPoint = Vector2.new(0.5, 0.5)
		badge.Parent = self.CountLayer
	end

	local entry = self:_buildEntry({
		Kind = "Unit",
		Unit = unitName,
		Index = index,
		Wrapper = wrapper,
		Card = card,
		Badge = badge,
		Button = card:FindFirstChild(BUTTON_NAME),
		Activate = function()
			callbackDo(unitName)
		end,
	})

	if entry.Parts.UnitName then
		entry.Parts.UnitName.Text = unitName
	end

	self:_writeCost(entry)

	--[[
		The card art is per unit, and it is the whole card: `Card` is an ImageLabel, not a
		frame with the illustration inside.

		A unit with no id in `CardConfig` keeps the art the `CardWrapper` came authored
		with: a card with the wrong art beats an invisible card in the hotbar.
	]]
	local cardImage = SharedConfig.CardConfig.GetImage(unitName)
	if cardImage and (card:IsA("ImageLabel") or card:IsA("ImageButton")) then
		card.Image = cardImage
	end

	return entry
end

--[[ EXTERNAL ]]

--[=[
	Removes the unit cards. Round cards **stay**.

	`clean` is the first thing `set` does, and `set` means "redraw the hotbar from the
	deck". A card bought in the shop did not come from the deck and cannot be rebuilt from
	it: destroying it here would make switching units mid-match evaporate a card the
	player paid for.

	To empty the whole hand, call `destroy`.
]=]
function module:clean()
	local kept = {}

	for _, entry in self.entries do
		if entry.Kind == "Round" then
			table.insert(kept, entry)
		else
			entry.Maid:DoCleaning()
		end
	end

	self.entries = kept
	self.byUnit = {}

	if self.maid then
		self.maid:DoCleaning()
		self.maid = nil
	end

	return true
end

--- Removes the round cards. Only `destroy` goes through here.
function module:_cleanRound()
	for _, entry in self.entries do
		if entry.Kind == "Round" then
			entry.Maid:DoCleaning()
		end
	end

	self.entries = {}
	self.byRound = {}

	-- The selected card left the hand along with all the others.
	self.selectedRound = nil
	self.roundCleared = nil
end

--[=[
	Draws the hotbar from the deck.

	`Cards` is the list of units in slot order (see `DeckConfig.unitList`). Each becomes a
	clone of the template, and at the end all are laid into the arc at once: that is why
	removing or adding a card repositions the whole deck.

	The round cards the player had already bought survive this and return to the row
	**after** the unit cards: they do not come from the deck, and slot order is the deck's.
]=]
--[=[
	Locks the hotbar to some cards.

	`allowed` is `{ [unit] = true }`; `nil` unlocks everything. A locked card gets
	`Active = false` (the click is not accepted even by the button) and dims more than a
	merely unselected card.

	The list is **stored in the component**, not applied once: the hotbar is rebuilt on
	every deck change and every round restart, and the lock must survive that, or winning
	the match and playing again would bring back every card on the tutorial's first step.
]=]
function module:setAllowed(allowed : { [string] : boolean }?)
	self.allowed = allowed

	for _, entry in self.entries do
		self:_applyAllowed(entry)
	end
end

--[=[
	Applies the lock to a card. A round card (no `Unit`) is never locked here:
	`TutorialStepController` handles it, on the use request.
]=]
function module:_applyAllowed(entry)
	local allowed = self.allowed == nil
		or entry.Unit == nil
		or self.allowed[entry.Unit] == true

	if entry.Locked == (not allowed) then
		return
	end

	entry.Locked = not allowed

	--[[
		The lock falls on the card **and** its button.

		A unit card is only the art: the `Button` inside it receives the click (see
		`_buildEntry`). Turning off only the art would leave the card dimmed and clickable:
		the tutorial's locked unit would equip normally, and the player would only discover
		the lock when the server refused the placement (`CanPlace`), with the ghost already
		in hand.

		On a round card the two are the same object, and then the loop writes twice to the
		same place, which costs nothing and avoids a special case.

		`Interactable` goes along with `Active` because the hotbar buttons have `InputSink`
		on `Activate`, and writing `Active` does not write `InputSink`: `Interactable` is
		what guarantees the locked card responds to no click at all. `CardController` still
		asks `AllowsCard` before equipping: locking the screen is courtesy, and the rule
		must not depend on it alone.
	]]
	for _, object in { entry.Card, entry.Button } do
		if not object:IsA("GuiObject") then
			continue
		end

		object.Active = allowed

		if object:IsA("GuiButton") then
			object.AutoButtonColor = allowed
			object.Selectable = allowed
			object.Interactable = allowed
		end
	end

	--[[
		A card locked with the pointer over it no longer receives `MouseLeave` (it dies with
		the interaction) and would stay grown in the arc forever. The exit is applied here,
		at lock time.
	]]
	if not allowed and entry.Hovered then
		self:_setHovered(entry, false)
	end

	self:_applyTransparency(entry)
end

--[=[
	This unit's card in the hotbar, or `nil` if it is not there now.

	It returns the **card**, not the wrapper around it: the wrapper is the slot in the
	`UIListLayout` (it has the arc's slack, the counter's space, and whatever else the
	layout needs), and a highlight drawn over it hugs that empty space instead of the art.
	Pointers want the card.

	It exists for code that needs to point at a card without drawing it: today
	`TutorialStepController`. It is read-only: the caller does not modify what it gets.
]=]
function module:getCard(unitName : string) : GuiObject?
	local entry = self.byUnit[unitName]

	return entry and (entry.Card or entry.Wrapper)
end

function module:set(Cards : { string }, Counts : {}, callbackDo : (string) -> ())
	-- The first build is born ready; a deck change with the hotbar already on screen
	-- animates, which is the only moment a card is actually added or removed.
	local hadCards = #self.entries > 0

	self:clean()

	if not getTemplate() then
		return false
	end

	self.CountLayer = ensureCountLayer()
	self.counts = Counts or {}
	self.maid = Maid.new()

	-- What `clean` left standing are the round cards; the unit cards go in
	-- front of them.
	local rounds = self.entries
	self.entries = {}

	for index, unitName in Cards do
		local entry = self:_createEntry(unitName, index, callbackDo)

		if entry then
			table.insert(self.entries, entry)
			self.byUnit[unitName] = entry

			self:_writeCount(entry, true)
			self:_refreshDepth(entry)
			self:_applyAllowed(entry)

			-- The selected card may have survived the deck change: the clones are
			-- new, so scale and dimming must be reapplied here; `setSelected`
			-- would bail out, because the selected name did not change.
			self:_applyScale(entry)
			self:_setDimmed(entry)
		end
	end

	for _, entry in rounds do
		table.insert(self.entries, entry)
		self:_setDimmed(entry)
	end

	self:_reindex()
	self:_layout(not hadCards)
	self:_followCounts()

	-- The counters follow the card every frame: that is how they track the
	-- arc tween and the hover growth without a frame of lag.
	self.maid:GiveTask(RunService.RenderStepped:Connect(function()
		self:_followCounts()
	end))

	self.maid:GiveTask(UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end

		-- A hotbar off screen is a hotbar that does not respond: whatever hides
		-- TowerContainer (DifficultyController, before the match starts) and whatever
		-- hides the whole hand (the round shop tab) need not remember to also
		-- turn off the shortcuts.
		if not TowerContainer.Visible or self.hidden then return end

		-- The number follows what is on screen: a card that dropped out takes no
		-- key, just as it takes no slot. And each one's `Activate` knows
		-- what to do: equip the unit, or spend the round card.
		local index = KEYBINDS[input.KeyCode.Name]
		local entry = index and self:_liveEntries()[index]

		--[[
			A locked card does not respond to the key, just as it does not respond to the
			click: `_applyAllowed`'s `Active = false` stops the finger, but not the keyboard:
			the shortcut talks straight to `Activate`, and in the tutorial it would be the
			open path to equipping exactly the unit the step locks.
		]]
		if entry and not entry.Locked then
			entry.Activate()
		end
	end))

	return true
end

function module:setCount(unitName : string, count : number)
	self.counts[unitName] = count

	local entry = self.byUnit[unitName]
	if entry then
		self:_writeCount(entry)
	end
end

--[[ ROUND CARDS ]]

--[=[
	Puts a card bought in the round shop into the hand.

	The `wrapper` arrives **ready**: `RoundCardShopController` cloned its template, wrote
	the title, description, and art, and removed the price plate. On this side it becomes a
	hotbar card like any other: it enters the row, falls into the arc, grows on hover, and
	dims when another is selected.

	Two normalizations happen here, both because the **source template** is different. The
	shop card is anchored at the corner (`0, 0`) and the hotbar's at the center: without
	changing that, the arc's tilt would rotate the card around its top-left corner, and the
	hover growth would push it sideways instead of growing in place.

	The entrance is the same as a card that gets stock back: it is born out of the hand and
	**rises** into the slot, pushing its neighbors along the way.

	`uid` is per purchase, not per card: the same card bought twice is two cards in hand,
	and using one must not touch the other.
]=]
function module:addRound(uid : string, wrapper : Frame, activate : () -> ()) : boolean
	if not uid or not wrapper or self.byRound[uid] then
		return false
	end

	local card = wrapper:FindFirstChild(ROUND_CARD_NAME)
	if not card or not card:IsA("GuiObject") then
		log:StudioWarn(`round card '{uid}' arrived without its {ROUND_CARD_NAME}.`)
		wrapper:Destroy()
		return false
	end

	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)

	local entry = self:_buildEntry({
		Kind = "Round",
		Unit = nil,
		Uid = uid,
		Index = #self.entries + 1,
		Wrapper = wrapper,
		Card = card,

		-- The shop card is the button itself; a unit card has a `Button` inside.
		Button = if card:IsA("GuiButton") then card else card:FindFirstChild(BUTTON_NAME),
		Activate = activate,
	})

	table.insert(self.entries, entry)
	self.byRound[uid] = entry

	-- Out of the hand so it can enter: `_setAvailable` just below is what makes the
	-- card rise into its slot and the rest of the deck make room.
	entry.Available = false
	entry.Card.Position = self:_exitGoal(entry)
	self:_setPresence(entry, false)

	self:_reindex()
	self:_setDimmed(entry)
	self:_refreshDepth(entry)
	self:_setAvailable(entry, true)

	return true
end

--[=[
	Removes the used round card from the hand.

	It leaves like any other card leaving the deck: it drops off screen, and the slot only
	closes when it finishes falling (`EXIT_INFO`). The `entry` leaves the list at the end
	of the drop, not the start, because while it is falling it still occupies its slot:
	closing earlier would re-lay out the deck under a card still on screen.
]=]
function module:removeRound(uid : string) : boolean
	local entry = self.byRound[uid]
	if not entry then
		return false
	end

	self.byRound[uid] = nil

	--[[
		The selected card is leaving the hand (it was used, or the server returned it):
		without dropping the selection here, the neighbors would stay dimmed forever around
		a card that no longer exists.
	]]
	if self.selectedRound == uid then
		self.selectedRound = nil
		self.roundCleared = nil

		for _, other in self.entries do
			if other ~= entry then
				self:_applyScale(other)
				self:_refreshDepth(other)
				self:_setDimmed(other)
			end
		end
	end

	self:_setAvailable(entry, false)

	task.delay(EXIT_INFO.Time, function()
		local index = table.find(self.entries, entry)
		if index then
			table.remove(self.entries, index)
		end

		entry.Maid:DoCleaning()

		self:_reindex()
		self:_layout()
	end)

	return true
end

--[=[
	Hides (or restores) the whole hand, without anyone losing their place.

	`RoundCardShopController` turns it on while the shop tab is open. Restoring returns each
	card to the state it had (`entry.Present`), not "everything on": a card with no units
	left stays off screen.
]=]
function module:setHidden(hidden : boolean)
	hidden = hidden == true

	if self.hidden == hidden then
		return
	end

	self.hidden = hidden

	for _, entry in self.entries do
		self:_setPresence(entry, entry.Present ~= false)
	end
end

function module:setCash(cash : number)
	self.cash = cash or 0

	for _, entry in self.entries do
		self:_applyState(entry)
	end
end

--[=[
	The weather came or went: rewrites each card's price and re-evaluates what the player
	can afford.

	Both together, and in this order, because they are the same change seen from two
	places: a card that became 25% cheaper may have stopped being red at the same instant.
]=]
function module:refreshWeather()
	for _, entry in self.entries do
		self:_writeCost(entry)
		self:_applyState(entry)
	end
end

--[=[
	Which card is selected. It rests at `SELECTED_SCALE` and stays in front of its
	neighbors; the arc does not move. `nil` returns all to normal size.
]=]
function module:setSelected(unitName : string?)
	if self.selected == unitName then
		return
	end

	self.selected = unitName

	--[[
		One thing at a time in the hand. Putting a unit in hand with a round card waiting
		for a target would leave both up: the unit's ghost and the card's aim competing for
		the same click on the map. Whoever selected the card is notified by
		`setSelectedRound`'s `onCleared`, and gives up aiming on their side.
	]]
	if unitName and self.selectedRound then
		local cleared = self.roundCleared

		self.selectedRound = nil
		self.roundCleared = nil

		if cleared then
			task.spawn(cleared)
		end
	end

	local changed = false
	for _, entry in self.entries do
		changed = self:_applyScale(entry) or changed
		self:_refreshDepth(entry)
		self:_setDimmed(entry)
	end

	-- Switching the selected card touches two, but the deck re-lays out only once.
	if changed then
		self:_layout()
	end
end

--[=[
	Which **round** card is selected, by purchase `uid`.

	It is `setSelected`'s twin and does exactly the same thing: the card grows, comes to
	the front, and dims its neighbors. It is what makes a round card that asks for a target
	behave like an equipped unit card: it stays "in hand" while the player chooses where to
	use it.

	`onCleared` is called when **something else** takes the hand (the player equipped a
	unit). Whoever selected the card needs to know, to give up aiming, and has no way to
	find out alone: the click that switched hands was on the hotbar, not the map. It is not
	called when the owner undoes the selection itself: then it already knows.

	> Callers must **drop the unit first** (`UnitPlacementController:clearInteraction`).
	> `selected` here is only the drawing; the ghost following the mouse and the notion of
	> an equipped unit belong to two other owners, and clearing it from here would leave
	> them disagreeing with the screen.
]=]
function module:setSelectedRound(uid : string?, onCleared : (() -> ())?)
	if self.selectedRound == uid then
		return
	end

	self.selectedRound = uid
	self.roundCleared = if uid then onCleared else nil

	local changed = false
	for _, entry in self.entries do
		changed = self:_applyScale(entry) or changed
		self:_refreshDepth(entry)
		self:_setDimmed(entry)
	end

	if changed then
		self:_layout()
	end
end

function module:destroy()
	self:clean()

	-- `clean` spares round cards on purpose (it is the deck rebuild); here the whole
	-- hand goes.
	self:_cleanRound()

	self.selected = nil
	self.hidden = false
end

return module
