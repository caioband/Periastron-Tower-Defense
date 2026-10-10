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
	The Lobby rune shop and the backpack's runes.

	**Buying** charges the price and puts one unused rune in the backpack
	(`RuneService:GiveItem`); nothing starts. **Activating** (a click on the backpack
	entry) hands it to `RuneService:Activate`, which checks the tier against the live
	active rune, spends it and grants it.

	The client sends "rune X, tier N" and decides nothing else. The price and its
	currency come from `RuneConfig`.

	See docs/lobby/rune-shop.md.
]=]
local RuneShopService = {
	Services = {
		DataService = {},
		RuneService = {},
	},

	Signals = {
		-- (Player, id : string, tier : number, result : string, price : number)
		RunePurchased = Signal.new(),

		-- (Player, id : string, tier : number, action : string)
		RuneActivated = Signal.new(),
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
	Buys a rune tier into the player's backpack. Returns true and `"Stored"`, or false
	and the reason: `"UnknownRune"`, `"NotLoaded"`, `"BackpackFull"`,
	`"NotEnoughCurrency"`.

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

	-- Checked before charging, so a full backpack never touches the balance.
	if runeService:GetItemCount(player, id, tier) >= RuneConfig.MAX_ITEMS then
		return false, "BackpackFull"
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

	local stored, reason = runeService:GiveItem(player, id, tier, 1)

	if not stored then
		self:_refund(player, currency, price)
		return false, reason
	end

	self.Signals.RunePurchased:Fire(player, id, tier, "Stored", price)
	return true, "Stored"
end

--[=[
	Activates one of the player's unused runes. Returns true and the action (`"New"`,
	`"Extend"`, `"Upgrade"`), or false and the reason: `"UnknownRune"`, `"NotLoaded"`,
	`"LowerTier"`, `"NotOwned"`.
]=]
function RuneShopService:Activate(player : Player, id : any, tier : any) : (boolean, string?)
	local runeService = self.Services.RuneService
	if not runeService then
		return false, "NotLoaded"
	end

	local success, result = runeService:Activate(player, id, tier)

	if success then
		self.Signals.RuneActivated:Fire(player, id, tier, result)
	end

	return success, result
end

--[[ LIFECYCLE ]]

function RuneShopService:construct()
	Framework:Listen("RequestBuyRune", function(player : Player, id : any, tier : any)
		local success, result = self:Purchase(player, id, tier)

		Framework:Fire("RunePurchaseResult", player, id, tier, success, result)
	end)

	Framework:Listen("RequestActivateRune", function(player : Player, id : any, tier : any)
		local success, result = self:Activate(player, id, tier)

		Framework:Fire("RuneActivateResult", player, id, tier, success, result)
	end)
end

function RuneShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function RuneShopService:init()
	-- Declared here so the client's `Listen` does not wait for the first purchase or
	-- activation to create the event (see docs/architecture/me-framework.md).
	Framework:Listen("RunePurchaseResult", function() end)
	Framework:Listen("RuneActivateResult", function() end)
end

return RuneShopService