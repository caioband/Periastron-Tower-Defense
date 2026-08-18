local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local ShopConfig = SharedConfig.ShopConfig

local Framework = Me.new()

--[=[
	Sells what ShopConfig lists, for Shards.

	The client only sends an item id -- the price, what the item grants and whether
	the player can afford it are all decided here, against the profile.
]=]
local ShopService = {
	Services = {
		DataService = {},
		CrateService = {},
	},

	Signals = {
		-- (Player, item : ShopConfig.ShopItem, remainingShards : number)
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

	warn(string.format("[ShopService]: item %q grants nothing -- give it a Crate in ShopConfig.", tostring(item.Id)))
	return false
end

function ShopService:_addShards(Player : Player, amount : number)
	self.Services.DataService:Update(Player, "Stats", function(stats)
		stats = stats or {}
		stats.Shards = (stats.Shards or 0) + amount

		return stats
	end)
end

--[[ EXTERNAL ]]

--[=[
	Shards the player holds, straight from the loaded profile.
	Returns nil when the profile is not loaded yet.
]=]
function ShopService:PeekShards(Player : Player) : number?
	local profiles = self.Services.DataService.Profiles
	local profile = profiles and profiles[Player]
	if not profile then
		return nil
	end

	local stats = profile.Profile.Data.Stats
	return stats and stats.Shards or 0
end

--[=[
	Buys one shop item for the player: charges the Shards and grants the reward.

	Returns true on success, or false plus a reason ("UnknownItem", "NotLoaded",
	"NotEnoughShards", "GrantFailed"). The check and the charge happen inside a single
	:Update callback, which does not yield -- two clicks landing back to back cannot
	both spend the same Shards.
]=]
function ShopService:Purchase(Player : Player, itemId : string?) : (boolean, string?)
	local item = ShopConfig.getItem(itemId)
	if not item then
		warn(string.format("[ShopService]: %s asked for %q, which the shop does not sell.", Player.Name, tostring(itemId)))
		return false, "UnknownItem"
	end

	local DataService = self.Services.DataService
	local profiles = DataService.Profiles

	if not DataService.Update or not profiles or not profiles[Player] then
		warn(string.format("[ShopService]: %s has no profile loaded, ignoring the purchase.", Player.Name))
		return false, "NotLoaded"
	end

	local charged = false
	local remaining = 0

	DataService:Update(Player, "Stats", function(stats)
		stats = stats or {}

		local owned = stats.Shards or 0
		if owned < item.Price then
			return stats
		end

		remaining = owned - item.Price
		stats.Shards = remaining
		charged = true

		return stats
	end)

	if not charged then
		return false, "NotEnoughShards"
	end

	if not self:_grantItem(Player, item) then
		-- The grant is what failed, so hand the Shards back instead of eating them.
		self:_addShards(Player, item.Price)
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
end

return ShopService
