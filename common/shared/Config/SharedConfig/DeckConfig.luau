--[[
	The player's deck: how equipped cards are stored and what counts as a valid list.

	`EquippedUnits` is an array of **slots**, one per `CardWrapper` in
	`EquippedCards`; each entry is `{ Unit = name, Amount = count }` or `false`
	when the slot is empty. The array is always dense (`MAX_SLOTS` entries), so it
	survives the DataStore round trip without becoming a dictionary.

	A slot is **fixed**: removing a unit's last card empties its slot and moves
	nothing else; whoever is in slot 4 stays in slot 4. The old format (an array of
	names with repeats) derived slots from first appearance, so a unit running out
	pulled every later one back a slot.

	The old format is still read (`sanitize` converts it, grouping in order of
	appearance), so old profiles need no migration.

	The screen's three numbers come from here with no other field: the card total
	is `total`, a slot's count is its `Amount`, and `CardLimit` caps the total.

	See docs/lobby/deck.md.
]]

local UnitStats = require(script.Parent.UnitStats)
local RarityConfig = require(script.Parent.RarityConfig)
local LevelConfig = require(script.Parent.LevelConfig)
local GamepassConfig = require(script.Parent.GamepassConfig)

local DeckConfig = {}

export type Slot = { Unit : string, Amount : number }
export type Deck = { Slot | false }

-- How many `CardWrapper`s `StarterGui.HUD.CardUI.EquippedCards` has. It caps
-- **different** units in the deck, not cards.
DeckConfig.MAX_SLOTS = 6

--[=[
	The level each slot requires, from the first to the sixth.

	The player starts with three and earns the others by leveling up: the fourth at
	5, the fifth at 15, and the sixth at 25. A locked slot holds no card and does not
	show as free; each `CardWrapper`'s `LockedFrame` draws it.

	**The list must be ascending.** Slots unlock in order, and `unlockedSlots` counts
	the unlocked prefix instead of scanning the whole list, which lets the rest of the
	file work with "how many slots this player has".

	Nothing here is secret: the server decides the same with the same config (see
	`DeckService`), so the client computing it only makes the drawing arrive first.
]=]
DeckConfig.SLOT_UNLOCK_LEVELS = { 1, 1, 1, 5, 15, 25 }

-- How many cards in total a player can equip at first. It lives in the profile
-- (`CardLimit`), so raising a player's cap means writing there; this number only
-- applies to players who never had the key.
DeckConfig.DEFAULT_CARD_LIMIT = 15

--[=[
	An empty deck: `MAX_SLOTS` entries, all free.
]=]
function DeckConfig.empty() : Deck
	return table.create(DeckConfig.MAX_SLOTS, false)
end

--[=[
	The level the slot requires. A slot outside the list counts as always unlocked:
	`MAX_SLOTS` and `SLOT_UNLOCK_LEVELS` can drift apart in an edit, and an extra
	unlocked slot is better than one nobody can reach.
]=]
function DeckConfig.slotUnlockLevel(index : number?) : number
	local level = typeof(index) == "number" and DeckConfig.SLOT_UNLOCK_LEVELS[index]

	return typeof(level) == "number" and level or 1
end

--[=[
	Whether this slot is open for a player at this level.
]=]
function DeckConfig.isSlotUnlocked(index : number?, level : number?) : boolean
	local resolved = typeof(level) == "number" and level or 1

	return resolved >= DeckConfig.slotUnlockLevel(index)
end

--[=[
	How many slots the player has at this level: always the first three, and the
	others as they level up.
]=]
function DeckConfig.unlockedSlots(level : number?) : number
	local count = 0

	for index = 1, DeckConfig.MAX_SLOTS do
		if not DeckConfig.isSlotUnlocked(index, level) then
			break
		end

		count += 1
	end

	return count
end

--[=[
	A profile's level, derived from `Stats.XP` as everywhere: the level is not stored
	(see `LevelConfig`), so level and XP are never out of sync.
]=]
function DeckConfig.levelOf(profile : any) : number
	local stats = typeof(profile) == "table" and profile.Stats
	local xp = typeof(stats) == "table" and stats.XP or 0

	return LevelConfig:Resolve(xp).Level
end

--[=[
	How many slots this profile has. The shortcut server and client both use: they
	start from the same `Stats.XP` and reach the same number without coordinating.
]=]
function DeckConfig.unlockedFor(profile : any) : number
	return DeckConfig.unlockedSlots(DeckConfig.levelOf(profile))
end

--[=[
	Whether the name is a unit that exists in `UnitStats` today.
]=]
function DeckConfig.exists(unitName : string?) : boolean
	return typeof(unitName) == "string" and UnitStats[unitName] ~= nil
end

--[=[
	The card limit stored in a profile, with the default for players without the key
	yet. It is the **profile's** number, without game passes; see `limitFor`.
]=]
function DeckConfig.resolveLimit(limit : number?) : number
	if typeof(limit) ~= "number" or limit < 0 then
		return DeckConfig.DEFAULT_CARD_LIMIT
	end

	return math.floor(limit)
end

--[=[
	How many cards this profile can actually equip: its `CardLimit` plus what game
	passes give.

	The shortcut server and client both use, like `unlockedFor` for slots.

	**The pass adds here, not to `CardLimit`.** Writing +5 to the profile would be a
	credit, and credits do not go back: a refunded player would keep the higher cap
	forever, and a second login would add five more. Added on read, the cap drops
	with the pass, and `SetLimit` (the cap the game grants) remains the only thing
	saved.
]=]
function DeckConfig.limitFor(profile : any) : number
	local stored = typeof(profile) == "table" and profile.CardLimit or nil

	return DeckConfig.resolveLimit(stored) + GamepassConfig.cardBonus(profile)
end

--[=[
	Which slot the unit is in, or `nil` if it is not in the deck.
]=]
function DeckConfig.slotIndexOf(deck : Deck?, unitName : string?) : number?
	if typeof(deck) ~= "table" or unitName == nil then
		return nil
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" and slot.Unit == unitName then
			return index
		end
	end

	return nil
end

--[=[
	The first free slot **among the unlocked ones**, or `nil` if there is none.

	`unlocked` is how many slots the player has (see `unlockedFor`); without it, all
	of them, which keeps callers honest when they only ask about the deck.
]=]
function DeckConfig.firstFreeSlot(deck : Deck?, unlocked : number?) : number?
	if typeof(deck) ~= "table" then
		return nil
	end

	local last = math.clamp(unlocked or DeckConfig.MAX_SLOTS, 0, DeckConfig.MAX_SLOTS)

	for index = 1, last do
		if typeof(deck[index]) ~= "table" then
			return index
		end
	end

	return nil
end

--[=[
	How many cards of this unit are equipped.
]=]
function DeckConfig.countOf(deck : Deck?, unitName : string?) : number
	local index = DeckConfig.slotIndexOf(deck, unitName)

	return if index then (deck :: Deck)[index].Amount else 0
end

--[=[
	How many cards the deck holds in total. The number `CardLimit` caps.
]=]
function DeckConfig.total(deck : Deck?) : number
	if typeof(deck) ~= "table" then
		return 0
	end

	local total = 0
	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" then
			total += slot.Amount
		end
	end

	return total
end

--[=[
	How many cards of each unit the deck holds: `{[name] = count}`.
]=]
function DeckConfig.tally(deck : Deck?) : { [string]: number }
	local counts = {}

	if typeof(deck) ~= "table" then
		return counts
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" then
			counts[slot.Unit] = (counts[slot.Unit] or 0) + slot.Amount
		end
	end

	return counts
end

--[=[
	A copy that can be changed without touching the original; slots are copied too,
	or `addCard` would change both `Amount`s.
]=]
function DeckConfig.copy(deck : Deck?) : Deck
	local copy = DeckConfig.empty()

	if typeof(deck) ~= "table" then
		return copy
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" then
			copy[index] = { Unit = slot.Unit, Amount = slot.Amount }
		end
	end

	return copy
end

--[=[
	Adds **one** card of the unit: to its slot if it already has one, otherwise to
	the first free one. Returns `false` when there is no free slot.

	It checks neither ownership nor `CardLimit`; the caller knows those. `unlocked`
	is passed on to `firstFreeSlot`, so a new unit never enters a slot the player
	does not have yet.
]=]
function DeckConfig.addCard(deck : Deck, unitName : string, unlocked : number?) : boolean
	local index = DeckConfig.slotIndexOf(deck, unitName)

	if index then
		local slot = deck[index] :: Slot
		slot.Amount += 1

		return true
	end

	local free = DeckConfig.firstFreeSlot(deck, unlocked)
	if not free then
		return false
	end

	deck[free] = { Unit = unitName, Amount = 1 }

	return true
end

--[=[
	Removes **one** card of the unit. The slot is only freed when the last one
	leaves, and the others never move. Returns `false` if the unit was not in the deck.
]=]
function DeckConfig.removeCard(deck : Deck, unitName : string) : boolean
	local index = DeckConfig.slotIndexOf(deck, unitName)
	if not index then
		return false
	end

	local slot = deck[index] :: Slot
	slot.Amount -= 1

	if slot.Amount <= 0 then
		deck[index] = false
	end

	return true
end

--[=[
	Converts the old format (an array of names with repeats) into slots, grouping in
	order of appearance, the only thing that format said about slots.
]=]
local function fromLegacy(equipped : { string }) : { Slot }
	local order, counts = {}, {}

	for index = 1, #equipped do
		local unitName = equipped[index]
		if typeof(unitName) ~= "string" then
			continue
		end

		if not counts[unitName] then
			table.insert(order, unitName)
		end

		counts[unitName] = (counts[unitName] or 0) + 1
	end

	local slots = {}
	for _, unitName in order do
		table.insert(slots, { Unit = unitName, Amount = counts[unitName] })
	end

	return slots
end

--[=[
	The cleaned deck: only units that exist, at most what the player owns of each,
	one unit per slot, and at most `limit` cards in total.

	`owned` is the profile's `Units` (`{[name] = count}`); `nil` does not filter by
	ownership. `limit` falls back to the default.

	`unlocked` is how many slots the player has today (see `unlockedFor`): anything in
	a locked slot **leaves the deck** instead of moving. This matters mostly for
	profiles from when all six slots were free: the cards return to the inventory
	(`Units` is untouched here) and the player re-equips them when the slot opens.
	Moving them would be worse: slots are fixed, and repacking would move cards the
	player placed on purpose.

	**Each slot is cleaned in place**: a slot that loses everything becomes `false`
	and the others stay put.
]=]
function DeckConfig.sanitize(equipped : any, owned : { [string]: number }?, limit : number?, unlocked : number?) : Deck
	local deck = DeckConfig.empty()

	if typeof(equipped) ~= "table" then
		return deck
	end

	-- A profile in the old format: one name per card, no slots.
	if typeof(equipped[1]) == "string" then
		equipped = fromLegacy(equipped)
	end

	local maxCards = DeckConfig.resolveLimit(limit)
	local lastSlot = math.clamp(unlocked or DeckConfig.MAX_SLOTS, 0, DeckConfig.MAX_SLOTS)
	local seen = {}
	local total = 0

	for index = 1, lastSlot do
		local slot = equipped[index]
		if typeof(slot) ~= "table" then
			continue
		end

		local unitName = slot.Unit
		if not DeckConfig.exists(unitName) or seen[unitName] then
			continue
		end

		local amount = math.floor(tonumber(slot.Amount) or 0)

		if owned then
			amount = math.min(amount, owned[unitName] or 0)
		end

		-- Anything over the limit is cut, but the slot only disappears when no card is
		-- left in it.
		amount = math.min(amount, maxCards - total)

		if amount <= 0 then
			continue
		end

		seen[unitName] = true
		total += amount
		deck[index] = { Unit = unitName, Amount = amount }
	end

	return deck
end

--[=[
	A deck built on the spot from the inventory, for players who never built one.

	Without it, a player who never opened the deck panel would enter a match with no
	cards and be stuck, since the deck decides what they can place.

	It takes the rarest units first (up to the **unlocked** slots) and deals cards
	in turns among them, respecting what they own and `limit`, so the automatic deck
	is not three copies of one unit when the player has variety.

	It is **deterministic**: client and server reach the same deck from the same
	profile without coordinating.
]=]
function DeckConfig.autoDeck(owned : { [string]: number }?, limit : number?, unlocked : number?) : Deck
	local deck = DeckConfig.empty()

	if typeof(owned) ~= "table" then
		return deck
	end

	local names = {}
	for unitName, amount in owned do
		if DeckConfig.exists(unitName) and (amount or 0) > 0 then
			table.insert(names, unitName)
		end
	end

	-- From the highest rarity to the lowest, alphabetical within a rarity: the same
	-- order as the inventory list.
	table.sort(names, function(a : string, b : string)
		local orderA = RarityConfig.getOrder(UnitStats[a].Rarity) or 0
		local orderB = RarityConfig.getOrder(UnitStats[b].Rarity) or 0

		if orderA ~= orderB then
			return orderA > orderB
		end

		return a < b
	end)

	local maxCards = DeckConfig.resolveLimit(limit)
	local slots = math.clamp(unlocked or DeckConfig.MAX_SLOTS, 0, DeckConfig.MAX_SLOTS)
	local chosen = {}

	for index = 1, math.min(#names, slots) do
		table.insert(chosen, { Unit = names[index], Amount = 0 })
	end

	local total = 0
	local added = true

	while added and total < maxCards do
		added = false

		for _, slot in chosen do
			if total >= maxCards then
				break
			end

			if slot.Amount < (owned[slot.Unit] or 0) then
				slot.Amount += 1
				total += 1
				added = true
			end
		end
	end

	local index = 0
	for _, slot in chosen do
		if slot.Amount > 0 then
			index += 1
			deck[index] = slot
		end
	end

	return deck
end

--[=[
	The deck that applies to a match: the one the player built, or an automatic one
	when they never built any. The Game uses it to know what they can place, and it
	is called on both sides so both reach the same hotbar.
]=]
function DeckConfig.resolve(profile : { EquippedUnits : any, Units : any, CardLimit : number?, Stats : any, Gamepasses : any }?) : Deck
	if typeof(profile) ~= "table" then
		return DeckConfig.empty()
	end

	local owned = profile.Units

	-- The profile's slot count comes from the profile itself, not the caller: that is
	-- what makes the match hotbar, the Lobby deck, and the server check agree without
	-- anyone passing the level around.
	local unlocked = DeckConfig.unlockedFor(profile)
	local limit = DeckConfig.limitFor(profile)
	local deck = DeckConfig.sanitize(profile.EquippedUnits, owned, limit, unlocked)

	if DeckConfig.total(deck) > 0 then
		return deck
	end

	return DeckConfig.autoDeck(owned, limit, unlocked)
end

--[=[
	The deck's unit names, in slot order and without gaps. It is the match hotbar:
	an empty slot does not become a blank card in the middle of the hand.
]=]
function DeckConfig.unitList(deck : Deck?) : { string }
	local names = {}

	if typeof(deck) ~= "table" then
		return names
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" then
			table.insert(names, slot.Unit)
		end
	end

	return names
end

return DeckConfig
