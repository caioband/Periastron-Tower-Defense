local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local CrateConfig = SharedConfig.CrateConfig
local RarityConfig = SharedConfig.RarityConfig
local GamepassConfig = SharedConfig.GamepassConfig

local RANDOM = Random.new()

local TutorialConfig = SharedConfig.TutorialConfig
local UnitStats = SharedConfig.UnitStats

local Framework = Me.new()
local log = Log.new("CrateService")

-- The `RuneConfig` id whose bonus multiplies crate luck.
local LUCK_RUNE = "Luck"

-- The most crates one bulk request may open. The backpack's biggest button is 30.
local MAX_BULK_OPEN = 30

local CrateService = {
	Services = {
		DataService = {},
		IndexService = {},
		ContractService = {},
		RuneService = {},
	},

	Signals = {
		-- (Player, rarity : string, amount : number, delta : number)
		CrateAmountChanged = Signal.new(),
	},
}

local function clampAmount(amount : number?) : number
	if typeof(amount) ~= "number" or amount ~= amount then
		return 0
	end

	return math.clamp(math.floor(amount), 0, CrateConfig.MAX_CRATES_PER_RARITY)
end

local function rarityRank(rarity : string?) : number
	return (rarity and table.find(RarityConfig.ORDER, rarity)) or 0
end

--[=[
	Reads the crates of a player straight from the loaded profile.
	Returns nil when the profile is not loaded yet -- use :GetCrates for the async version.
]=]
function CrateService:PeekCrates(Player : Player) : { [string]: number }?
	local profiles = self.Services.DataService.Profiles
	local profile = profiles and profiles[Player]
	if not profile then
		return nil
	end

	local inventory = profile.Profile.Data.Inventory
	return inventory and inventory.Crates or nil
end

--[=[
	Async read that waits for the profile to be loaded.
]=]
function CrateService:GetCrates(Player : Player, callbackFunc : ({ [string]: number }) -> ())
	self.Services.DataService:Get(Player, function(data)
		data.Inventory = data.Inventory or {}
		data.Inventory.Crates = data.Inventory.Crates or CrateConfig.createEmptyCrates()

		callbackFunc(data.Inventory.Crates)
	end)
end

--[=[
	Sets the crate amount of a single rarity to an absolute value.
	Returns the applied amount, or nil when it failed (bad rarity / profile not loaded).
]=]
function CrateService:SetCrates(Player : Player, rarity : string, amount : number) : number?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		log:StudioWarn(string.format("%q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local DataService = self.Services.DataService
	if not DataService.Update then
		log:Warn("DataService is not ready yet; ignoring the crate change.")
		return nil
	end

	local targetAmount = clampAmount(amount)
	local previousAmount

	local inventory = DataService:Update(Player, "Inventory", function(currentInventory)
		currentInventory = currentInventory or {}
		currentInventory.Crates = currentInventory.Crates or CrateConfig.createEmptyCrates()

		previousAmount = currentInventory.Crates[resolvedRarity] or 0
		currentInventory.Crates[resolvedRarity] = targetAmount

		return currentInventory
	end)

	if not inventory then
		return nil
	end

	self.Signals.CrateAmountChanged:Fire(Player, resolvedRarity, targetAmount, targetAmount - previousAmount)
	return targetAmount
end

--[=[
	Adds (or removes, with a negative amount) crates of a rarity.
	Returns the resulting amount, or nil when it failed.
]=]
function CrateService:GiveCrates(Player : Player, rarity : string, amount : number?) : number?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		log:StudioWarn(string.format("%q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local delta = typeof(amount) == "number" and math.floor(amount) or 1
	local crates = self:PeekCrates(Player)
	local currentAmount = crates and crates[resolvedRarity] or 0

	return self:SetCrates(Player, resolvedRarity, currentAmount + delta)
end

--[=[
	Rolls the upgrade chain of a crate and returns the crate whose pool applies, plus
	every step it went through (empty when it did not evolve).

	The client replays that list one spin per step, so the order matters.
	Bounded by the number of tiers so a config with a loop in it cannot hang us.
]=]
function CrateService:_rollCrateUpgrade(crateRarity : string) : (string, { string })
	local CrateOdds = ServerConfig.Crate

	local current = crateRarity
	local upgrades = {}

	for _ = 1, #RarityConfig.ORDER do
		local upgrade = CrateOdds.UPGRADES[current]
		if not upgrade or RANDOM:NextNumber(0, 100) >= upgrade.Chance then
			break
		end

		current = upgrade.To
		table.insert(upgrades, current)

		if not CrateOdds.CHAIN_UPGRADES then
			break
		end
	end

	return current, upgrades
end

--[=[
	Marks this player's next crate with a rarity.

	It is single use and does not stack: marking twice still applies to one crate only. It
	lasts while they are on the server; it is not saved on the profile, because it belongs
	to a tutorial step, not a game promise.
]=]
function CrateService:ForceRarity(Player : Player, rarity : string)
	local resolved = RarityConfig.resolveRarity and RarityConfig.resolveRarity(rarity) or rarity
	if not resolved then return end

	self.ForcedRarity = self.ForcedRarity or {}
	self.ForcedRarity[Player.UserId] = resolved

	log:Debug(`next crate for {Player.Name} will be {resolved} (tutorial).`)
end

--[=[
	Reads and clears the next-crate mark, if any.
]=]
function CrateService:ConsumeForcedRarity(Player : Player) : string?
	local forced = self.ForcedRarity and self.ForcedRarity[Player.UserId]

	if forced and self.ForcedRarity then
		self.ForcedRarity[Player.UserId] = nil
	end

	return forced
end

--[=[
	The newcomer's guarantee: within the profile's first crates ever, one comes out Epic or
	better.

	The count is `Stats.BoxesOpened`, which already exists and already counts real
	openings: no new key. The guarantee only applies on the **last** of the first crates
	(the third, today) and only if no Epic came out before: someone lucky on the first
	does not spend the guarantee, and someone unlucky leaves the three with one.
]=]
function CrateService:_guaranteedRarity(profile : any) : string?
	local guarantee = TutorialConfig.CrateGuarantee
	if not guarantee then
		return nil
	end

	local stats = typeof(profile) == "table" and profile.Stats or nil
	local opened = (typeof(stats) == "table" and tonumber(stats.BoxesOpened)) or 0

	-- This opening is number `opened + 1`.
	if opened + 1 ~= guarantee.Crates then
		return nil
	end

	local units = typeof(profile) == "table" and profile.Units or nil
	if typeof(units) == "table" then
		local floor = table.find(RarityConfig.ORDER, guarantee.Rarity)

		for unitName in units do
			local rarity = UnitStats[unitName] and UnitStats[unitName].Rarity
			local index = rarity and table.find(RarityConfig.ORDER, rarity)

			if index and floor and index >= floor then
				return nil
			end
		end
	end

	return guarantee.Rarity
end

--[=[
	Rolls a unit rarity out of a crate's pool. Returns nil when the crate has no pool.

	`profile` is the opener's profile, and it serves the `+30% Luck` gamepass, which
	multiplies the weight of rarities from Epic up (see `GamepassConfig.LUCK_MIN_RARITY`).
	`luckMultiplier` is the opener's Luck rune (`RuneService:GetMultiplier`), applied on
	top of the pass. Without either the multiplier is 1 and the math comes out exactly as
	without them.

	**Luck raises the top ones and leaves the bottom ones alone**, and that is enough: the
	draw normalizes by the sum of weights, so raising Epic+ pushes Common and Rare down on
	its own. Touching both sides would be two numbers to keep in sync.

	It also does not make the published chance false: the shop's `GetDisplayOdds` stays
	the raw pool, which is what a player **without** luck gets.
]=]
function CrateService:_rollRarity(crateRarity : string, profile : any, luckMultiplier : number?) : string?
	local guaranteed = self:_guaranteedRarity(profile)
	if guaranteed then
		log:Debug(`starter guarantee: {guaranteed} on this opening.`)

		return guaranteed
	end

	local pool = ServerConfig.Crate.POOLS[crateRarity]
	if not pool then
		log:StudioWarn(string.format("crate %q has no pool in ServerConfig.Crate.", tostring(crateRarity)))
		return nil
	end

	local luck = GamepassConfig.luckMultiplier(profile) * (luckMultiplier or 1)

	local function weightOf(rarity : string) : number
		local weight = pool[rarity] or 0

		if GamepassConfig.isLuckyRarity(rarity) then
			return weight * luck
		end

		return weight
	end

	local total = 0
	for _, rarity in RarityConfig.ORDER do
		total += weightOf(rarity)
	end

	if total <= 0 then
		return nil
	end

	local roll = RANDOM:NextNumber(0, total)
	local cumulative = 0

	for _, rarity in RarityConfig.ORDER do
		cumulative += weightOf(rarity)
		if roll < cumulative then
			return rarity
		end
	end

	return RarityConfig.ORDER[1]
end

--[=[
	The units of a tier a crate can actually deliver.

	`RarityConfig.getUnitsOfRarity` stays the tier's honest list: the card, the deck, and
	balance read it. The drop is what is smaller: `EXCLUDED_UNITS` removes from here units
	that exist in the game but no longer drop from crates (see ServerConfig.Crate).
]=]
local function unboxableUnitsOfRarity(rarity : string) : { string }
	local excluded = ServerConfig.Crate.EXCLUDED_UNITS or {}
	local units = {}

	for _, unitName in RarityConfig.getUnitsOfRarity(rarity) do
		if not excluded[unitName] then
			table.insert(units, unitName)
		end
	end

	return units
end

--[=[
	Picks the unit the player actually gets, among the units of that rarity a crate
	can still give.

	A tier with nothing left to give (because no unit was assigned to it (Cosmic, as it
	stands) or because the ones it had are out of the drop) walks down to the closest tier
	that has one, so a roll never comes back empty-handed.
]=]
function CrateService:_rollUnit(rarity : string) : (string?, string?)
	local currentRarity : string? = rarity

	while currentRarity do
		local units = unboxableUnitsOfRarity(currentRarity)
		if #units > 0 then
			if currentRarity ~= rarity then
				log:StudioWarn(string.format(
					"no unit of rarity %q can drop from a crate, dropping a %s one instead.",
					rarity,
					currentRarity
				))
			end

			return units[RANDOM:NextInteger(1, #units)], currentRarity
		end

		currentRarity = RarityConfig.getLowerRarity(currentRarity)
	end

	log:Warn("no unit is left in the crate pool at any rarity.")
	return nil, nil
end

--[=[
	The rarity guaranteed on this opening, or nil. The count is shared by every crate,
	so any crate that takes part in that rarity's guarantee delivers it; one left out
	(`CrateConfig.PITY_EXCLUDED_CRATES`) skips it, and the guarantee waits.

	It reads the profile's `Pity` counts against each rarity's limit
	(`CrateConfig.getPityThreshold`), in `CrateConfig.PITY_RARITIES` order: if Cosmic and
	Legendary come due together, Cosmic comes out now and Legendary stays due for the
	next opening.
]=]
function CrateService:_dueRarity(crateRarity : string, profile : any) : string?
	local counts = CrateConfig.readPity(profile and profile.Pity)

	for _, rarity in CrateConfig.PITY_RARITIES do
		local threshold = CrateConfig.getPityThreshold(rarity)
		if threshold and CrateConfig.countsForPity(crateRarity, rarity) and (counts[rarity] or 0) >= threshold then
			return rarity
		end
	end

	return nil
end

--[=[
	Updates the guarantee counts after an opening of any crate: resets the one for the
	rarity that came out and adds one to the others.

	`gotRarity` is the rarity of the unit the player actually received (the same as the
	result), not the rolled one: a tier with no unit steps down in `_rollUnit`, and that
	opening did not deliver the upper tier.

	`crateRarity` is the crate bought, before any upgrade: a rarity's count stays as it
	is when that crate is left out of its guarantee (`CrateConfig.countsForPity`),
	whatever came out.

	It always writes the current shape (`{ [rarity] = count }`): a profile still holding
	the old per-crate tables is converted here, by `CrateConfig.readPity`.
]=]
function CrateService:_recordPity(Player : Player, crateRarity : string, gotRarity : string?)
	self.Services.DataService:Update(Player, "Pity", function(pity)
		local counts = CrateConfig.readPity(pity)

		for _, rarity in CrateConfig.PITY_RARITIES do
			if not CrateConfig.countsForPity(crateRarity, rarity) then
				counts[rarity] = counts[rarity] or 0
			elseif gotRarity == rarity then
				counts[rarity] = 0
			else
				counts[rarity] = (counts[rarity] or 0) + 1
			end
		end

		return counts
	end)
end

export type UnboxingResult = {
	-- The crate the player opened.
	Crate : string,
	-- Every crate it evolved into, in order. Empty when it did not.
	Upgrades : { string },
	Rarity : string,
	Unit : string?,
}

export type BulkSummary = {
	-- How many crates were actually opened.
	Opened : number,
	-- [rarity] = how many units of that rarity came out.
	Rarities : { [string] : number },
	-- [unitName] = how many copies came out.
	Units : { [string] : number },
}

--[=[
	Runs a crate opening end to end: upgrade chain, rarity out of the resulting pool,
	then a unit of that rarity. Pure roll -- nothing is written or sent.

	`profile` belongs to the opener, and only the gamepass luck reads it (see
	`_rollRarity`). `luckMultiplier` is the opener's Luck rune. Without either the draw is
	that of a player with no luck at all: that is what makes Cmdr's `unbox` roll the crate
	"stock" when nobody passes a profile.

	`forcedRarity` is the guarantee (see `_dueRarity`): when present, it overrides the
	rarity draw. The upgrade still rolls (the reel shows the crate upgrading the same
	way); only the delivered rarity was already decided.
]=]
function CrateService:RollCrate(rarity : string, profile : any, forcedRarity : string?, luckMultiplier : number?) : UnboxingResult?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		log:StudioWarn(string.format("%q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local poolCrate, upgrades = self:_rollCrateUpgrade(resolvedRarity)

	local rolledRarity = forcedRarity or self:_rollRarity(poolCrate, profile, luckMultiplier)
	if not rolledRarity then
		return nil
	end

	-- The unit may come from a lower tier when the rolled one has no unit yet, and the
	-- result reports the tier the player actually got.
	local unit, unitRarity = self:_rollUnit(rolledRarity)

	return {
		Crate = resolvedRarity,
		Upgrades = upgrades,
		Rarity = unitRarity or rolledRarity,
		Unit = unit,
	}
end

--[=[
	The player's open profile, or nil while it has not loaded.

	The draw's luck reads it: without a profile the crate rolls without a gamepass, which
	is the worst case for the player and the only safe one for the game: inventing a pass
	they may not have would give the benefit away for free.
]=]
function CrateService:_profileOf(Player : Player) : any
	local DataService = self.Services.DataService
	local profiles = DataService and DataService.Profiles
	local entry = profiles and profiles[Player]

	return entry and entry.Profile.Data or nil
end

--- The player's Luck rune multiplier (1 without one).
function CrateService:_runeLuckOf(Player : Player) : number
	local RuneService = self.Services.RuneService
	if not RuneService or not RuneService.GetMultiplier then
		return 1
	end

	return RuneService:GetMultiplier(Player, LUCK_RUNE)
end

--[=[
	Sends the opening to the whole Lobby, not only the opener.

	`Owner` travels along because it is their character the crate appears in front of, on
	every screen, and it is what separates the opener from those just watching: only the
	owner's screen shows the reel and the unit's name; the rest see the crate and the prize.

	One `Fire` per player is how the rest of the project broadcasts (`MobService`): `Me`
	only exposes sending to one client at a time.
]=]
function CrateService:_broadcastUnboxing(Owner : Player, result : UnboxingResult)
	for _, player in Players:GetPlayers() do
		Framework:Fire("PlayUnboxing", player, result, Owner)
	end
end

--[=[
	Rolls a crate and plays the unboxing on every client (crate model in front of
	`Player` + the reel above it landing on the rolled rarity).

	It does NOT spend the crate and does NOT give the unit -- it is the "show me" entry
	point, used by the cmdr command. :OpenCrate is the one the player drives.
]=]
function CrateService:PlayUnboxing(Player : Player, rarity : string) : UnboxingResult?
	local result = self:RollCrate(rarity, self:_profileOf(Player), nil, self:_runeLuckOf(Player))
	if not result then
		return nil
	end

	self:_broadcastUnboxing(Player, result)
	return result
end

--[=[
	Spends up to `count` crates of a rarity in a single `:Update`, which does not yield:
	two requests landing back to back cannot both spend the same crates. Returns how
	many were actually spent (0 when the player owns none).
]=]
function CrateService:_spendCrates(Player : Player, resolvedRarity : string, count : number) : number
	local spent = 0
	local remaining = 0

	self.Services.DataService:Update(Player, "Inventory", function(currentInventory)
		currentInventory = currentInventory or {}
		currentInventory.Crates = currentInventory.Crates or CrateConfig.createEmptyCrates()

		local owned = currentInventory.Crates[resolvedRarity] or 0
		if owned <= 0 then
			return currentInventory
		end

		spent = math.min(owned, count)
		remaining = owned - spent
		currentInventory.Crates[resolvedRarity] = remaining

		return currentInventory
	end)

	if spent > 0 then
		self.Signals.CrateAmountChanged:Fire(Player, resolvedRarity, remaining, -spent)
	end

	return spent
end

--[=[
	Resolves one crate that was already spent: rolls it, moves the guarantee counts,
	counts the opening, gives the unit, and records the Index and contracts. Sends
	nothing to the clients. A failed roll hands the crate back and returns nil.
]=]
function CrateService:_resolveOpening(Player : Player, resolvedRarity : string) : UnboxingResult?
	local DataService = self.Services.DataService

	--[[
		The guarantee: if some rarity came due on the shared count, it is already decided
		before the draw (`_dueRarity`). The counts only move after the roll succeeds: a
		failed opening returns the crate and does not count.

		Nothing between reading the counts and writing them yields the thread, so two
		openings in a row do not read the same count before it moves.
	]]
	local profile = self:_profileOf(Player)

	--[[
		The rarity the tutorial left marked for this player's next crate takes precedence
		over the normal guarantee, and is **consumed** here: one mark, one crate.
		`TutorialService` sets it, on the server, when it opens the Lobby step: the client
		asks for no rarity, so there is nothing to forge.
	]]
	local dueRarity = self:ConsumeForcedRarity(Player) or self:_dueRarity(resolvedRarity, profile)

	local result = self:RollCrate(resolvedRarity, profile, dueRarity, self:_runeLuckOf(Player))
	if not result then
		-- The roll is what failed, so hand the crate back instead of eating it.
		self:GiveCrates(Player, resolvedRarity, 1)
		return nil
	end

	self:_recordPity(Player, resolvedRarity, result.Rarity)

	-- MOST BOXES OPENED counts from here: only a crate actually spent and rolled. The
	-- `PlayUnboxing` (Cmdr's `unbox`) does not go through here and does not count.
	DataService:Update(Player, "Stats", function(stats)
		stats.BoxesOpened = (tonumber(stats.BoxesOpened) or 0) + 1
		return stats
	end)

	if result.Unit then
		DataService:Update(Player, "Units", function(units)
			units = units or {}
			units[result.Unit] = (units[result.Unit] or 0) + 1
			return units
		end)

		-- Obtaining is the Index trigger: the unit enters the catalog on the first copy, and
		-- stays there even if they sell all of them later.
		local IndexService = self.Services.IndexService
		if IndexService then
			IndexService:UnlockUnit(Player, result.Unit)
		end

		-- "Unbox 2 Legendary Cards": the rarity is that of the unit that came out, from any
		-- crate. Summons do not go through here and do not count.
		local ContractService = self.Services.ContractService
		if ContractService then
			ContractService:Record(Player, SharedConfig.ContractConfig.Events.Unbox, 1, { Rarity = result.Rarity })
		end
	end

	return result
end

--[=[
	Opens one crate the player owns: spends it, rolls it, gives the unit and plays the
	unboxing. Returns nil when the player owns none of that rarity.
]=]
function CrateService:OpenCrate(Player : Player, rarity : string) : UnboxingResult?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		log:StudioWarn(string.format("%q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	if not self.Services.DataService.Update then
		log:Warn("DataService is not ready yet; ignoring the crate opening.")
		return nil
	end

	if self:_spendCrates(Player, resolvedRarity, 1) <= 0 then
		return nil
	end

	local result = self:_resolveOpening(Player, resolvedRarity)
	if not result then
		return nil
	end

	self:_broadcastUnboxing(Player, result)
	return result
end

--[=[
	Opens up to `count` crates of a rarity at once (capped at `MAX_BULK_OPEN` and at what
	the player owns).

	Every crate is spent in one write and then resolved one by one, so the guarantee,
	the tutorial mark, BoxesOpened, the Index and contracts all count each crate. Only
	the best result (highest rarity, first one on a tie) plays the unboxing for the
	Lobby; thirty crates at once would bury the plaza. The opener gets the whole batch
	through `BulkUnboxResult`.
]=]
function CrateService:OpenCrates(Player : Player, rarity : string, count : number) : { UnboxingResult }?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		log:StudioWarn(string.format("%q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	if typeof(count) ~= "number" or count ~= count or count == math.huge then
		return nil
	end

	count = math.clamp(math.floor(count), 1, MAX_BULK_OPEN)

	if count == 1 then
		local single = self:OpenCrate(Player, resolvedRarity)
		return single and { single } or nil
	end

	if not self.Services.DataService.Update then
		log:Warn("DataService is not ready yet; ignoring the crate opening.")
		return nil
	end

	local spent = self:_spendCrates(Player, resolvedRarity, count)
	if spent <= 0 then
		return nil
	end

	local results = {}
	local summary : BulkSummary = {
		Opened = 0,
		Rarities = {},
		Units = {},
	}

	local best : UnboxingResult? = nil

	for _ = 1, spent do
		local result = self:_resolveOpening(Player, resolvedRarity)
		if not result then
			continue
		end

		table.insert(results, result)

		summary.Opened += 1
		summary.Rarities[result.Rarity] = (summary.Rarities[result.Rarity] or 0) + 1

		if result.Unit then
			summary.Units[result.Unit] = (summary.Units[result.Unit] or 0) + 1
		end

		if not best or rarityRank(result.Rarity) > rarityRank(best.Rarity) then
			best = result
		end
	end

	if not best then
		return nil
	end

	self:_broadcastUnboxing(Player, best)
	Framework:Fire("BulkUnboxResult", Player, resolvedRarity, summary, best)

	return results
end

function CrateService:construct()
	Framework:Listen("RequestOpenCrate", function(Player : Player, rarity : string)
		self:OpenCrate(Player, rarity)
	end)

	Framework:Listen("RequestOpenCrates", function(Player : Player, rarity : string, count : number)
		self:OpenCrates(Player, rarity, count)
	end)
end

function CrateService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function CrateService:init()
	-- The client connects to "PlayUnboxing" and "BulkUnboxResult" during its own init,
	-- but the server would only create the events when it first fires them -- and Warp
	-- complains that they are "taking too long to retrieve". Declared here like the other
	-- server-only events.
	Framework:Listen("PlayUnboxing", function() end)
	Framework:Listen("BulkUnboxResult", function() end)
end

return CrateService