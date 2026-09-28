local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

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

local ShopConfig = SharedConfig.ShopConfig

local Framework = Me.new()
local log = Log.new("ShopService")

--[=[
	Sells what ShopConfig lists.

	The client only sends an item id -- the price, **which currency it is priced in**,
	what the item grants and whether the player can afford it are all decided here,
	against the profile.
]=]
local ShopService = {
	Services = {
		DataService = {},
		CrateService = {},
	},

	Signals = {
		-- (Player, item : ShopConfig.ShopItem, remaining : number) -- remaining is the
		-- balance of item.Currency after the charge, and not always Shards.
		ItemPurchased = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	Hands the player what the item is worth. Returns false when the item describes a
	reward this service does not know how to grant, so the caller refunds instead of
	charging for nothing.
]=]
function ShopService:_grantItem(Player : Player, item) : boolean
	if item.Crate then
		return self.Services.CrateService:GiveCrates(Player, item.Crate, item.Amount) ~= nil
	end

	log:StudioWarn(string.format("item %q grants nothing -- give it a Crate in ShopConfig.", tostring(item.Id)))
	return false
end

--[=[
	Returns what was charged, in the currency it was charged in.

	`currency` is always a `ShopConfig.CURRENCIES` key: `resolveItem` already replaces an
	unknown currency with the default before the item gets here, so the refund cannot
	create a field the profile does not have.
]=]
function ShopService:_refund(Player : Player, currency : string, amount : number)
	self.Services.DataService:Update(Player, "Stats", function(stats)
		stats = stats or {}
		stats[currency] = (stats[currency] or 0) + amount

		return stats
	end)
end

--[[ EXTERNAL ]]

--[=[
	The chances the shop publishes, per crate: `{ [item Id] = { [rarity] = % } }`.

	It comes from here and not a shared config because the odds belong to the **server**
	(`ServerScriptService.Config.Crate`): the client receives the math's result, not the
	table that produces it. What it receives is already the real chance, with the crate's
	upgrade included; see `Crate.GetDisplayOdds`.

	An item that delivers no crate is left out of the map, not given an empty map: readers
	can tell "this crate has no chance of anything" (impossible) from "this item is not a
	crate".
]=]
function ShopService:GetCrateOdds() : { [string]: { [string]: number } }
	if self.CrateOdds then
		return self.CrateOdds
	end

	local odds = {}

	for _, item in ShopConfig.getItems() do
		if item.Crate then
			local itemOdds = ServerConfig.Crate.GetDisplayOdds(item.Crate)
			if itemOdds then
				odds[item.Id] = itemOdds
			end
		end
	end

	-- Nothing here changes at runtime: it is config times config, and the same answer
	-- holds for everyone for the rest of the server's life.
	self.CrateOdds = odds
	return odds
end

--[=[
	How much of a currency the player has, straight from the loaded profile. `currency` is
	a `ShopConfig.CURRENCIES` key; without it, the shop's default currency.

	Returns nil when the profile has not loaded yet, which is different from zero.
]=]
function ShopService:PeekBalance(Player : Player, currency : string?) : number?
	local profiles = self.Services.DataService.Profiles
	local profile = profiles and profiles[Player]
	if not profile then
		return nil
	end

	local stat = (currency and ShopConfig.CURRENCIES[currency]) or ShopConfig.DEFAULT_CURRENCY
	local stats = profile.Profile.Data.Stats

	return (stats and stats[stat]) or 0
end

--[=[
	Buys one shop item for the player: charges the item's currency and grants the
	reward.

	Returns true on success, or false plus a reason ("UnknownItem", "NotLoaded",
	"NotEnoughCurrency", "GrantFailed"). The check and the charge happen inside a
	single :Update callback, which does not yield -- two clicks landing back to back
	cannot both spend the same balance.
]=]
function ShopService:Purchase(Player : Player, itemId : string?) : (boolean, string?)
	local item = ShopConfig.getItem(itemId)
	if not item then
		log:StudioWarn(string.format("%s asked for %q, which the shop does not sell.", Player.Name, tostring(itemId)))
		return false, "UnknownItem"
	end

	local DataService = self.Services.DataService
	local profiles = DataService.Profiles

	if not DataService.Update or not profiles or not profiles[Player] then
		log:StudioWarn(string.format("%s has no profile loaded, ignoring the purchase.", Player.Name))
		return false, "NotLoaded"
	end

	-- It is already the `Data.Stats` key: a crate priced in Coins charges `Cash`, which is
	-- what the profile calls the currency the screen calls Coins.
	local currency = item.Currency

	--[[
		**This** player's price, with the VIP discount already applied (`ShopConfig.priceFor`).

		Read here and not inside `Update`: the price comes from `Data.Gamepasses`, which the
		`Stats` `Update` does not provide; it is the same math the client did to write the
		number on the button, so what it read is what it pays.
	]]
	local price = ShopConfig.priceFor(item, profiles[Player].Profile.Data)

	local charged = false
	local remaining = 0

	DataService:Update(Player, "Stats", function(stats)
		stats = stats or {}

		local owned = stats[currency] or 0
		if owned < price then
			return stats
		end

		remaining = owned - price
		stats[currency] = remaining
		charged = true

		return stats
	end)

	if not charged then
		return false, "NotEnoughCurrency"
	end

	if not self:_grantItem(Player, item) then
		-- The grant is what failed, so hand the money back instead of eating it.
		self:_refund(Player, currency, price)
		return false, "GrantFailed"
	end

	self.Signals.ItemPurchased:Fire(Player, item, remaining)

	return true
end

function ShopService:construct()
	Framework:Listen("RequestBuyShopItem", function(Player : Player, itemId : string)
		local success, reason = self:Purchase(Player, itemId)

		Framework:Fire("ShopPurchaseResult", Player, itemId, success, reason)
	end)

	--[[
		The client asks for the chances when it hooks up the shop, instead of the server
		sending them on join: `ShopUI` is `ResetOnSpawn`, so the panel is rebuilt on every
		respawn, and a single send on join would be lost at the first death. The request
		also covers a player who joined before the service started.
	]]
	Framework:Listen("RequestCrateOdds", function(Player : Player)
		Framework:Fire("CrateOdds", Player, self:GetCrateOdds())
	end)
end

function ShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function ShopService:init()
	-- The client connects to "ShopPurchaseResult" during its own init, but the server
	-- would only create the event when it first fires it -- and Warp complains that it
	-- "is taking too long to retrieve". Declared here like the other server-only events.
	Framework:Listen("ShopPurchaseResult", function() end)
	Framework:Listen("CrateOdds", function() end)
end

return ShopService
