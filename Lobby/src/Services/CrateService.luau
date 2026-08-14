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
local Signal = require(Packages.Signal)

local CrateConfig = SharedConfig.CrateConfig
local RarityConfig = SharedConfig.RarityConfig

local RANDOM = Random.new()

local Framework = Me.new()

local CrateService = {
	Services = {
		DataService = {},
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
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local DataService = self.Services.DataService
	if not DataService.Update then
		warn("[CrateService]: DataService is not ready yet, ignoring crate change.")
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
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
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
	Rolls a unit rarity out of a crate's pool. Returns nil when the crate has no pool.
]=]
function CrateService:_rollRarity(crateRarity : string) : string?
	local pool = ServerConfig.Crate.POOLS[crateRarity]
	if not pool then
		warn(string.format("[CrateService]: crate %q has no pool in ServerConfig.Crate.", tostring(crateRarity)))
		return nil
	end

	local total = 0
	for _, rarity in RarityConfig.ORDER do
		total += pool[rarity] or 0
	end

	if total <= 0 then
		return nil
	end

	local roll = RANDOM:NextNumber(0, total)
	local cumulative = 0

	for _, rarity in RarityConfig.ORDER do
		cumulative += pool[rarity] or 0
		if roll < cumulative then
			return rarity
		end
	end

	return RarityConfig.ORDER[1]
end

--[=[
	Picks the unit the player actually gets, among the units of that rarity.

	A tier with no unit tagged yet (Cosmic, as it stands) walks down to the closest
	tier that has one, so a roll never comes back empty-handed.
]=]
function CrateService:_rollUnit(rarity : string) : (string?, string?)
	local currentRarity : string? = rarity

	while currentRarity do
		local units = RarityConfig.getUnitsOfRarity(currentRarity)
		if #units > 0 then
			if currentRarity ~= rarity then
				warn(string.format(
					"[CrateService]: no unit is tagged %q in UnitStats, dropping a %s one instead.",
					rarity,
					currentRarity
				))
			end

			return units[RANDOM:NextInteger(1, #units)], currentRarity
		end

		currentRarity = RarityConfig.getLowerRarity(currentRarity)
	end

	warn("[CrateService]: no unit in UnitStats carries a valid Rarity.")
	return nil, nil
end

export type UnboxingResult = {
	-- The crate the player opened.
	Crate : string,
	-- Every crate it evolved into, in order. Empty when it did not.
	Upgrades : { string },
	Rarity : string,
	Unit : string?,
}

--[=[
	Runs a crate opening end to end: upgrade chain, rarity out of the resulting pool,
	then a unit of that rarity. Pure roll -- nothing is written or sent.
]=]
function CrateService:RollCrate(rarity : string) : UnboxingResult?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local poolCrate, upgrades = self:_rollCrateUpgrade(resolvedRarity)

	local rolledRarity = self:_rollRarity(poolCrate)
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
	Rolls a crate and plays the unboxing on the player's client (crate model in front
	of them + the reel above it landing on the rolled rarity).

	It does NOT spend the crate and does NOT give the unit -- it is the "show me" entry
	point, used by the cmdr command. :OpenCrate is the one the player drives.
]=]
function CrateService:PlayUnboxing(Player : Player, rarity : string) : UnboxingResult?
	local result = self:RollCrate(rarity)
	if not result then
		return nil
	end

	Framework:Fire("PlayUnboxing", Player, result)
	return result
end

--[=[
	Opens one crate the player owns: spends it, rolls it, gives the unit and plays the
	unboxing. Returns nil when the player owns none of that rarity.

	The check and the decrement happen inside a single :Update callback, which does not
	yield -- two clicks landing back to back cannot both spend the same last crate.
]=]
function CrateService:OpenCrate(Player : Player, rarity : string) : UnboxingResult?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local DataService = self.Services.DataService
	if not DataService.Update then
		warn("[CrateService]: DataService is not ready yet, ignoring crate opening.")
		return nil
	end

	local spent = false
	local remaining = 0

	DataService:Update(Player, "Inventory", function(currentInventory)
		currentInventory = currentInventory or {}
		currentInventory.Crates = currentInventory.Crates or CrateConfig.createEmptyCrates()

		local owned = currentInventory.Crates[resolvedRarity] or 0
		if owned <= 0 then
			return currentInventory
		end

		remaining = owned - 1
		currentInventory.Crates[resolvedRarity] = remaining
		spent = true

		return currentInventory
	end)

	if not spent then
		return nil
	end

	self.Signals.CrateAmountChanged:Fire(Player, resolvedRarity, remaining, -1)

	local result = self:RollCrate(resolvedRarity)
	if not result then
		-- The roll is what failed, so hand the crate back instead of eating it.
		self:GiveCrates(Player, resolvedRarity, 1)
		return nil
	end

	if result.Unit then
		DataService:Update(Player, "Units", function(units)
			units = units or {}
			units[result.Unit] = (units[result.Unit] or 0) + 1
			return units
		end)
	end

	Framework:Fire("PlayUnboxing", Player, result)
	return result
end

function CrateService:construct()
	Framework:Listen("RequestOpenCrate", function(Player : Player, rarity : string)
		self:OpenCrate(Player, rarity)
	end)
end

function CrateService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function CrateService:init()
	-- The client connects to "PlayUnboxing" during its own init, but the server would
	-- only create the event when it first fires it -- and Warp complains that it "is
	-- taking too long to retrieve". Declared here like the other server-only events.
	Framework:Listen("PlayUnboxing", function() end)
end

return CrateService
