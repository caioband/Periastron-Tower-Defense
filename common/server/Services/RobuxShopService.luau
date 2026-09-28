local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local RobuxShopConfig = SharedConfig.RobuxShopConfig

local Framework = Me.new()
local log = Log.new("RobuxShopService")

--[[
	Pays out the coin packs of the Robux shop (`StarterGui.ShopUI.RobuxShop`).

	The storefront belongs to `RobuxShopController`, and it credits nothing: the
	click only opens the prompt. What arrives here is the **receipt**, through
	`MonetizationService`, which already handled what a receipt needs: the open
	profile, `PurchaseHistory` so the same `PurchaseId` does not pay twice, and the
	save before answering `PurchaseGranted`. Returning `false` from here means "could
	not credit right now": the receipt comes back as `NotProcessedYet` and Roblox
	retries.

	It lives in `common/` because a pending receipt comes back **wherever the player
	is**, and they may have gone to a match before it was processed; the same reason
	as contract rerolls. The same shop's gamepasses do not go through here: a pass is
	state, and `MonetizationService:RecalibratePasses` checks it.

	The deposit goes only to `Stats.Cash`. `Stats.CoinsEarned` (the MOST COINS board)
	is left out on purpose: it is what the player earned by playing, not what they
	bought.

	See docs/common/gamepasses.md.
]]
local RobuxShopService = {
	Services = {
		CurrencyService = {},
		MonetizationService = {},
	},
}

--[[ EXTERNAL ]]

--[=[
	Deposits a pack into the balance. `false` when it could not (a profile that has
	not opened yet, a player who left midway), and then the receipt comes back later.
]=]
function RobuxShopService:Grant(player : Player, pack) : boolean
	local currency = self.Services.CurrencyService

	if not currency then
		log:Warn("no CurrencyService; the pack cannot be credited right now.")
		return false
	end

	local _, updated, reason = currency:Apply(player, "Cash", "add", pack.Coins)

	if not updated then
		log:Warn(string.format(
			"could not credit %d coins to %s (%s); the receipt is retried.",
			pack.Coins, player.Name, tostring(reason)))
		return false
	end

	return true
end

function RobuxShopService:construct()
	local monetization = self.Services.MonetizationService

	if not monetization then
		log:Warn("no MonetizationService; coin packs will not be credited.")
		return
	end

	for _, pack in RobuxShopConfig.PACKS do
		monetization:RegisterProduct(pack.ProductId, function(player : Player)
			return self:Grant(player, pack)
		end)
	end
end

function RobuxShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function RobuxShopService:init()

end

return RobuxShopService
