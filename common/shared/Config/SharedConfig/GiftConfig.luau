--[[
	What can be gifted, and how each item is paid out. Registered by `SharedConfig`
	on its own (it loads every child by name).

	A gift is bought with its **own developer product**, never with the pass or the
	pack the player buys for themselves: the receipt only carries the buyer and the
	product, and the two must be told apart. Price each gift product the same as
	what it gifts.

	| Field | What it is |
	| --- | --- |
	| `Kind` | `"Pass"` or `"Pack"` |
	| `Pass` | (Pass) the `GamepassConfig.PASSES` key the recipient gets |
	| `Pack` | (Pack) the `ProductId` of the coin pack in `RobuxShopConfig.PACKS` |
	| `ProductId` | the **gift** developer product. `0` = not created yet, item disabled |

	The item key (`VIP`, `Pack1`, ...) is stored in profiles: never rename one.
	A pass gift stores the pass key, so ids that Roblox changes stay a one-line edit
	in `GamepassConfig`.
]]

local GamepassConfig = require(script.Parent.GamepassConfig)
local RobuxShopConfig = require(script.Parent.RobuxShopConfig)

local module = {}

module.MAX_MESSAGE_LENGTH = 100

module.ITEMS = {
	VIP = { Kind = "Pass", Pass = "VIP", ProductId = 0 },
	Shards = { Kind = "Pass", Pass = "Shards", ProductId = 0 },
	Luck = { Kind = "Pass", Pass = "Luck", ProductId = 0 },
	CardSlots = { Kind = "Pass", Pass = "CardSlots", ProductId = 0 },
	Coins = { Kind = "Pass", Pass = "Coins", ProductId = 0 },
	Speed = { Kind = "Pass", Pass = "Speed", ProductId = 0 },

	Pack1 = { Kind = "Pack", Pack = 3713311022, ProductId = 0 },
	Pack2 = { Kind = "Pack", Pack = 3713311161, ProductId = 0 },
	Pack3 = { Kind = "Pack", Pack = 3713311237, ProductId = 0 },
}

--[=[
	Why an item cannot be gifted right now, or nil when it can.
]=]
function module.problem(item : any) : string?
	if typeof(item) ~= "table" then
		return "not a table"
	end

	if item.Kind == "Pass" then
		if not GamepassConfig.PASSES[item.Pass] then
			return `unknown pass '{tostring(item.Pass)}'`
		end
	elseif item.Kind == "Pack" then
		if not RobuxShopConfig.packOfProduct(item.Pack) then
			return `no coin pack with ProductId {tostring(item.Pack)}`
		end
	else
		return `unknown Kind '{tostring(item.Kind)}'`
	end

	if typeof(item.ProductId) ~= "number" or item.ProductId <= 0 then
		return "no gift ProductId yet"
	end

	return nil
end

function module.isEnabled(item : any) : boolean
	return module.problem(item) == nil
end

--- What the player reads: the pass name, or "1400 Coins".
function module.displayName(itemKey : string) : string?
	local item = module.ITEMS[itemKey]
	if not item then
		return nil
	end

	if item.Kind == "Pass" then
		local pass = GamepassConfig.PASSES[item.Pass]
		return pass and pass.DisplayName
	end

	local pack = RobuxShopConfig.packOfProduct(item.Pack)
	return pack and `{pack.Coins} Coins`
end

return module