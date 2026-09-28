local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local DeckConfig = SharedConfig.DeckConfig
local GamepassConfig = SharedConfig.GamepassConfig

local Framework = Me.new()
local log = Log.new("DeckService")

--[=[
	Writes the player's deck (`EquippedUnits` on the profile).

	The deck is an array of slots (see `SharedConfig.DeckConfig`): each unit's slot is
	fixed, and removing a unit's last card empties its slot without touching the others.

	The client only sends a unit name and says "equip one" or "remove one"; whether the
	card can go in (whether the unit exists, whether a copy is left in the inventory,
	whether there is a free **unlocked** slot, whether `CardLimit` allows it) is decided
	here, against the profile. `DeckController` draws from the replica, so what it shows
	is always what this service wrote.

	The top three slots belong to everyone; the fourth, fifth, and sixth open by level
	(`DeckConfig.SLOT_UNLOCK_LEVELS`). The level comes from the profile's own `Stats.XP`,
	so there is nothing to receive from the client: it computes the same number with the
	same config only to draw before the answer.

	Reading, deciding, and writing happen inside a single `:Update`, which does not yield:
	two back-to-back clicks do not pass the limit.

	See docs/lobby/deck.md.
]=]
local DeckService = {
	Services = {
		DataService = {},
	},

	Signals = {
		-- (Player, deck : DeckConfig.Deck)
		DeckChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	The player's loaded profile, or `nil` while it has not arrived.
]=]
function DeckService:_getData(Player : Player)
	local profiles = self.Services.DataService.Profiles
	local profile = profiles and profiles[Player]

	return profile and profile.Profile.Data or nil
end

--[=[
	The shared path for equipping and unequipping: validates what can be validated outside
	the write, runs `decide` inside `:Update`, and notifies listeners.

	`decide(deck, data)` receives the already cleaned deck and returns `nil` when the card
	went in (or out), or the refusal reason. Touching the slots is its job.
]=]
function DeckService:_write(Player : Player, unitName : string?, decide) : (boolean, string?)
	if not DeckConfig.exists(unitName) then
		log:StudioWarn(string.format("%s asked for %q, which is not a unit.", Player.Name, tostring(unitName)))
		return false, "UnknownUnit"
	end

	local DataService = self.Services.DataService
	local data = self:_getData(Player)

	if not data or not DataService.Update then
		log:StudioWarn(string.format("%s has no profile loaded yet.", Player.Name))
		return false, "NotLoaded"
	end

	local reason : string? = nil

	DataService:Update(Player, "EquippedUnits", function(current)
		local deck = DeckConfig.sanitize(current, data.Units, DeckConfig.limitFor(data), DeckConfig.unlockedFor(data))

		-- Even when refusing, what the cleanup removed is worth writing: it is the chance for
		-- an old profile to catch up with today's UnitStats (and to become slots, if it is
		-- still in the old format).
		reason = decide(deck, data)

		return deck
	end)

	if reason then
		return false, reason
	end

	self.Signals.DeckChanged:Fire(Player, self:GetEquipped(Player))

	return true
end

--[[ EXTERNAL ]]

--[=[
	How many cards fit in this player's deck, gamepass included (`limitFor`).
]=]
function DeckService:GetLimit(Player : Player) : number
	local data = self:_getData(Player)

	return DeckConfig.limitFor(data)
end

--[=[
	The player's deck, already cleaned. `nil` while the profile has not loaded.
]=]
function DeckService:GetEquipped(Player : Player) : DeckConfig.Deck?
	local data = self:_getData(Player)
	if not data then
		return nil
	end

	return DeckConfig.sanitize(data.EquippedUnits, data.Units, DeckConfig.limitFor(data), DeckConfig.unlockedFor(data))
end

--[=[
	How many slots the player has today, out of `DeckConfig.MAX_SLOTS`. Zero when the
	profile has not loaded yet, which is different from the starting three.
]=]
function DeckService:GetUnlockedSlots(Player : Player) : number
	local data = self:_getData(Player)

	return if data then DeckConfig.unlockedFor(data) else 0
end

--[=[
	Puts **one** card of the unit in the deck.

	Refuses with "NoCopies" (every copy they own is already equipped), "LimitReached"
	(`CardLimit` exceeded), or "NoSlot" (no unlocked slot left, either because the player
	already has a different unit in each one or because the remaining ones still require
	a level).
]=]
function DeckService:Equip(Player : Player, unitName : string?) : (boolean, string?)
	return self:_write(Player, unitName, function(deck, data)
		local owned = data.Units and data.Units[unitName] or 0
		if owned <= 0 then
			return "NotOwned"
		end

		if DeckConfig.countOf(deck, unitName) >= owned then
			return "NoCopies"
		end

		if DeckConfig.total(deck) >= DeckConfig.limitFor(data) then
			return "LimitReached"
		end

		-- It only fails when the unit is new to the deck and there is no free unlocked slot:
		-- a copy of a unit already there goes to its slot, locked or not, and its slot
		-- is never locked, because the `sanitize` above already removed it from there.
		if not DeckConfig.addCard(deck, unitName, DeckConfig.unlockedFor(data)) then
			return "NoSlot"
		end

		return nil
	end)
end

--[=[
	Removes **one** card of the unit from the deck. Refuses with "NotEquipped".
]=]
function DeckService:Unequip(Player : Player, unitName : string?) : (boolean, string?)
	return self:_write(Player, unitName, function(deck)
		-- The slot is only freed when the last card leaves, and the others do not move.
		if not DeckConfig.removeCard(deck, unitName) then
			return "NotEquipped"
		end

		return nil
	end)
end

--[=[
	Changes how many cards fit in the deck. This is how a reward or a command raises the
	cap; the deck is cleaned right after, so a lower cap does not leave extra cards.
]=]
function DeckService:SetLimit(Player : Player, limit : number) : boolean
	local DataService = self.Services.DataService
	local data = self:_getData(Player)

	if not data or not DataService.Update then
		return false
	end

	--[[
		What is saved is the **game's** cap, without the gamepass: the pass adds on read
		(`limitFor`), and writing it here would turn it into a credit: a refund would leave
		the +5 on the profile forever.

		The cleanup just below does use the real cap: cutting the deck by the number
		without the pass would remove cards the player is entitled to keep.
	]]
	local resolved = DeckConfig.resolveLimit(limit)

	DataService:Update(Player, "CardLimit", function()
		return resolved
	end)

	DataService:Update(Player, "EquippedUnits", function(current)
		local limitWithPasses = resolved + GamepassConfig.cardBonus(data)

		return DeckConfig.sanitize(current, data.Units, limitWithPasses, DeckConfig.unlockedFor(data))
	end)

	self.Signals.DeckChanged:Fire(Player, self:GetEquipped(Player))

	return true
end

function DeckService:construct()
	Framework:Listen("RequestEquipCard", function(Player : Player, unitName : string)
		local success, reason = self:Equip(Player, unitName)

		Framework:Fire("DeckCardResult", Player, unitName, "Equip", success, reason)
	end)

	Framework:Listen("RequestUnequipCard", function(Player : Player, unitName : string)
		local success, reason = self:Unequip(Player, unitName)

		Framework:Fire("DeckCardResult", Player, unitName, "Unequip", success, reason)
	end)
end

function DeckService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function DeckService:init()
	-- The client listens to this event in its own init, and the Warp identifier
	-- is created on the server: without this empty Listen it waits ten seconds and the rest
	-- of the controller stops with it (see docs/architecture/me-framework.md).
	Framework:Listen("DeckCardResult", function() end)
end

return DeckService
