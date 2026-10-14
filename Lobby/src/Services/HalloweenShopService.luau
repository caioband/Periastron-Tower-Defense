local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("HalloweenShopService")

local HalloweenConfig = SharedConfig.HalloweenConfig
local EventCurrencyConfig = SharedConfig.EventCurrencyConfig

local REQUEST_COOLDOWN = 0.5

--[[
	The Spooky Merchant's shop: skins and titles for event currency.

	The client sends "category, id" and nothing else. The price comes from
	`HalloweenConfig.Shop`, the charge from `EventCurrencyService:Spend` (check and
	charge in one write), and the item from `SkinService` / `NametagService`. If the
	grant fails after the charge, the price goes back.

	Result reasons: `EventOff`, `UnknownItem`, `AlreadyOwned`, `NotEnoughCurrency`,
	or the grant's own reason.
]]

local HalloweenShopService = {
	Services = {
		EventCurrencyService = {},
		SkinService = {},
		NametagService = {},
	},
}

--[[ INTERNAL ]]

function HalloweenShopService:_owns(player : Player, category : string, id : string) : boolean
	if category == "Skins" then
		return self.Services.SkinService:Owns(player, id)
	end

	return self.Services.NametagService:Owns(player, id)
end

function HalloweenShopService:_grant(player : Player, category : string, id : string) : (boolean, string?)
	if category == "Skins" then
		return self.Services.SkinService:Grant(player, id)
	end

	return self.Services.NametagService:Grant(player, id)
end

--[[ API ]]

function HalloweenShopService:Buy(player : Player, category : any, id : any) : (boolean, string?)
	if not EventCurrencyConfig.Enabled then
		return false, "EventOff"
	end

	local item = HalloweenConfig.getShopItem(category, id)
	if not item then
		return false, "UnknownItem"
	end

	if self:_owns(player, category, id) then
		return false, "AlreadyOwned"
	end

	local currency = self.Services.EventCurrencyService
	local paid = currency:Spend(player, item.Price, `HalloweenShop:{id}`)
	if not paid then
		return false, "NotEnoughCurrency"
	end

	local granted, reason = self:_grant(player, category, id)
	if not granted then
		currency:Apply(player, "add", item.Price, `HalloweenShopRefund:{id}`)
		log:Warn(`granting {category}.{id} to {player.Name} failed ({tostring(reason)}); refunded {item.Price}.`)
		return false, reason or "GrantFailed"
	end

	return true, nil
end

--[[ LIFECYCLE ]]

function HalloweenShopService:construct()
	Framework:Listen("RequestBuyHalloweenItem", function(player : Player, category : any, id : any)
		local now = os.clock()
		if now - (self.LastRequest[player] or 0) < REQUEST_COOLDOWN then
			return
		end
		self.LastRequest[player] = now

		local ok, reason = self:Buy(player, category, id)
		Framework:Fire("HalloweenPurchaseResult", player, category, id, ok, reason)
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.LastRequest[player] = nil
	end)
end

function HalloweenShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function HalloweenShopService:init()
	self.LastRequest = {}

	Framework:Listen("HalloweenPurchaseResult", function() end)
end

return HalloweenShopService