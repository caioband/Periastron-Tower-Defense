local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local RuneConfig = SharedConfig.RuneConfig

local Framework = Me.new()
local log = Log.new("RuneShopService")

--[=[
	The Lobby rune shop: charges the price and hands the rune to `RuneService`.

	The client sends "rune X, tier N" and decides nothing else. The price and its
	currency come from `RuneConfig`, and whether the tier can be bought (the same tier
	extends, a higher one replaces, a lower one is refused) is checked against the **live** rune before
	charging, and again inside `RuneService:Grant`'s write, which refunds when two
	clicks in the same frame race each other.

	See docs/lobby/rune-shop.md.
]=]
local RuneShopService = {
	Services = {
		DataService = {},
		RuneService = {},
	},

	Signals = {
		-- (Player, id : string, tier : number, action : string, price : number)
		RunePurchased = Signal.new(),
	},
}

--[[ INTERNAL ]]

function RuneShopService:_refund(player : Player, currency : string, amount : number)
	self.Services.DataService:Update(player, "Stats", function(stats)
		stats = stats or {}
		stats[currency] = (stats[currency] or 0) + amount

		return stats
	end)
end

--[[ API ]]

--[=[
	Buys a rune tier for the player. Returns true and the action (`"New"`, `"Extend"`,
	`"Upgrade"`), or false and the reason: `"UnknownRune"`, `"NotLoaded"`,
	`"LowerTier"`, `"NotEnoughCurrency"`.

	The balance check and the charge are one `Update`, which does not yield, so two
	quick clicks cannot spend the same shards.
]=]
function RuneShopService:Purchase(player : Player, id : any, tier : any) : (boolean, string?)
	local definition = RuneConfig.getTier(id, tier)
	if not definition then
		log:StudioWarn(string.format("%s asked for rune %q tier %s, which does not exist.",
			player.Name, tostring(id), tostring(tier)))
		return false, "UnknownRune"
	end

	local dataService = self.Services.DataService
	local runeService = self.Services.RuneService
	local profiles = dataService and dataService.Profiles

	if not runeService or not profiles or not profiles[player] then
		return false, "NotLoaded"
	end

	-- Checked before charging, so the common refusal never touches the balance.
	local action, reason = RuneConfig.purchaseAction(runeService:GetEntry(player, id), tier)
	if not action then
		return false, reason
	end

	local price = definition.Price
	local currency = RuneConfig.currencyOf(RuneConfig.Get(id))
	local charged = false

	dataService:Update(player, "Stats", function(stats)
		stats = stats or {}

		local owned = stats[currency] or 0
		if owned < price then
			return stats
		end

		stats[currency] = owned - price
		charged = true

		return stats
	end)

	if not charged then
		return false, "NotEnoughCurrency"
	end

	local granted, result = runeService:Grant(player, id, tier)

	if not granted then
		self:_refund(player, currency, price)
		return false, result
	end

	self.Signals.RunePurchased:Fire(player, id, tier, result, price)
	return true, result
end

--[[ LIFECYCLE ]]

function RuneShopService:construct()
	Framework:Listen("RequestBuyRune", function(player : Player, id : any, tier : any)
		local success, result = self:Purchase(player, id, tier)

		Framework:Fire("RunePurchaseResult", player, id, tier, success, result)
	end)
end

function RuneShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function RuneShopService:init()
	-- Declared here so the client's `Listen` does not wait for the first purchase to
	-- create the event (see docs/architecture/me-framework.md).
	Framework:Listen("RunePurchaseResult", function() end)
end

return RuneShopService
