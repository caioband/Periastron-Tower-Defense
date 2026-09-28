--[[
	The game passes: each one's id and what it changes in the game.

	A single source for both sides. The server asks Roblox who owns what and saves
	it in the profile (`MonetizationService:RecalibratePasses`); from then on
	**nobody asks Roblox again**, and both sides read the profile's `Gamepasses`
	key through the functions below.

	Nothing here is secret (the numbers are on each pass page, and the client needs
	them to draw discounted prices and the deck cap). Crate odds stay in
	`ServerScriptService.Config.Crate`, and luck multiplies **those** tables on the
	server, not here.

	## How the profile stores it

	`Data.Gamepasses` is `{ [key] = true }`, keyed by this table's **key**, not the
	numeric id. The id belongs to Roblox and changes if a pass is recreated; the key
	belongs to the game. A changed id is one line here, not a profile migration.

	A pass is **not** stored forever: `RecalibratePasses` rewrites the whole table on
	every join, so a refund removes the benefit on the next login. That is why
	nothing here is a credit: passes are multipliers read on demand, never currency
	deposited.

	## How numbers combine

	Each benefit is a **multiplier**, and passes touching the same number multiply.
	Today there is one pass per benefit, but a second coins pass tomorrow works
	without touching any reader, unlike an `if` per pass spread across services.

	See docs/common/gamepasses.md.
]]

local RarityConfig = require(script.Parent.RarityConfig)

local module = {}

--[=[
	One pass per line. `Id` is the Roblox `GamePassId`; the rest is what it does.

	| Field | What it is |
	| --- | --- |
	| `Id` | the `GamePassId` that `MarketplaceService` checks |
	| `DisplayName` | what the player reads |
	| `CardBonus` | how many extra cards fit in the deck |
	| `CoinMultiplier` | multiplies end-of-match reward coins |
	| `ShardMultiplier` | same, for shards |
	| `XpMultiplier` | same, for XP |
	| `CratePriceMultiplier` | multiplies crate prices in the shop (0.8 is 20% off) |
	| `LuckMultiplier` | multiplies the weight of good rarities in the crate draw |
	| `ChatTag` | the tag shown before the name in chat |

	`Speed` has no benefit field: it unlocks a `SpeedConfig` step, and the step
	points at it (`Gamepass = "Speed"`). A pass that only unlocks content works this
	way: id and name here, the rule where the content lives.

	A missing field means "this pass does not touch that"; the functions below
	treat it as neutral (1 for multipliers, 0 for bonuses).
]=]
module.PASSES = {
	CardSlots = {
		Id = 1966789042,
		DisplayName = "+5 Total Cards",
		CardBonus = 5,
	},

	Luck = {
		Id = 1969136561,
		DisplayName = "+30% Luck",
		LuckMultiplier = 1.3,
	},

	Coins = {
		Id = 1969568499,
		DisplayName = "2x Coins",
		CoinMultiplier = 2,
	},

	Shards = {
		Id = 1970648287,
		DisplayName = "1.5x Shards",
		ShardMultiplier = 1.5,
	},

	Speed = {
		Id = 1970667486,
		DisplayName = "2x Speed",
	},

	VIP = {
		Id = 1953119816,
		DisplayName = "VIP",
		CratePriceMultiplier = 0.8,
		XpMultiplier = 1.25,
		ChatTag = "VIP",
	},
}

--[=[
	The lowest rarity luck lifts.

	"Better units" means this and above: `Luck` multiplies the weight of Epic,
	Legendary, and Cosmic in the crate pool and leaves Common and Rare alone. Since
	the draw normalizes by the sum of weights, lifting the top already pushes the
	bottom down; there is no second number to keep in sync.
]=]
module.LUCK_MIN_RARITY = "Epic"

--[=[
	The attribute the server writes on the `Player` for each pass with a `ChatTag`.

	The profile only replicates to its owner, so it cannot drive chat: the VIP tag
	must appear on **other players'** screens. `Player` attributes replicate to the
	whole room, and the server still does the writing.
]=]
module.TAG_ATTRIBUTE_PREFIX = "Pass_"

--[=[
	A pass's attribute name. `VIP` becomes `Pass_VIP`.
]=]
function module.attributeName(key : string) : string
	return module.TAG_ATTRIBUTE_PREFIX .. key
end

--[=[
	The pass for an id, or nil. That is how `MonetizationService` comes back from
	`PromptGamePassPurchaseFinished`, which only gives the number.
]=]
function module.keyOfId(gamePassId : number?) : string?
	for key, pass in module.PASSES do
		if pass.Id == gamePassId then
			return key
		end
	end

	return nil
end

--[=[
	The passes the profile declares: `{ [key] = true }`.

	A profile not loaded yet (or older than the key) counts as "none", not an error:
	without passes the player plays the base game, which is right until the data
	arrives.
]=]
function module.ownedOf(profile : any) : { [string]: boolean }
	local owned = typeof(profile) == "table" and profile.Gamepasses

	return typeof(owned) == "table" and owned or {}
end

--[=[
	Whether this profile has the pass.
]=]
function module.owns(profile : any, key : string) : boolean
	return module.ownedOf(profile)[key] == true
end

--[=[
	The product of a multiplier field across the profile's passes.

	The engine behind every multiplier below: a missing field counts as 1, so a pass
	that does not touch the number stays out, and two that do multiply.
]=]
local function product(profile : any, field : string) : number
	local owned = module.ownedOf(profile)
	local total = 1

	for key, pass in module.PASSES do
		local factor = owned[key] == true and pass[field]

		if typeof(factor) == "number" and factor > 0 then
			total *= factor
		end
	end

	return total
end

--[=[
	The sum of a bonus field across the profile's passes. A missing field counts as
	zero: bonuses add, multipliers multiply.
]=]
local function sum(profile : any, field : string) : number
	local owned = module.ownedOf(profile)
	local total = 0

	for key, pass in module.PASSES do
		local bonus = owned[key] == true and pass[field]

		if typeof(bonus) == "number" then
			total += bonus
		end
	end

	return total
end

--[=[
	How many extra cards this profile may equip. See `DeckConfig.limitFor`.
]=]
function module.cardBonus(profile : any) : number
	return math.floor(sum(profile, "CardBonus"))
end

--- Multiplies end-of-match reward coins.
function module.coinMultiplier(profile : any) : number
	return product(profile, "CoinMultiplier")
end

--- Multiplies end-of-match reward shards.
function module.shardMultiplier(profile : any) : number
	return product(profile, "ShardMultiplier")
end

--- Multiplies end-of-match reward XP.
function module.xpMultiplier(profile : any) : number
	return product(profile, "XpMultiplier")
end

--- Multiplies crate prices in the shop. 0.8 is "20% off".
function module.cratePriceMultiplier(profile : any) : number
	return product(profile, "CratePriceMultiplier")
end

--[=[
	Multiplies the weight of rarities from `LUCK_MIN_RARITY` up in the crate draw.
	Without the pass, 1, and the draw comes out exactly as if this file did not exist.
]=]
function module.luckMultiplier(profile : any) : number
	return product(profile, "LuckMultiplier")
end

--[=[
	Whether luck lifts this rarity.

	A rarity `RarityConfig` does not know is not lifted: paying the normal weight is
	safer than multiplying a tier nobody understands.
]=]
function module.isLuckyRarity(rarity : string?) : boolean
	local order = RarityConfig.getOrder(rarity)
	local minimum = RarityConfig.getOrder(module.LUCK_MIN_RARITY)

	return order ~= nil and minimum ~= nil and order >= minimum
end

--[=[
	This profile's chat tag, or nil when it has no pass with a tag.

	With more than one, the **first by key in alphabetical order** wins, only so the
	choice is stable; today only VIP has a tag.
]=]
function module.chatTagOf(owned : { [string]: boolean }?) : string?
	local passes = typeof(owned) == "table" and owned or {}

	local keys = {}
	for key in module.PASSES do
		table.insert(keys, key)
	end
	table.sort(keys)

	for _, key in keys do
		local pass = module.PASSES[key]

		if passes[key] == true and typeof(pass.ChatTag) == "string" then
			return pass.ChatTag
		end
	end

	return nil
end

return module
