--[[
	Single source of truth for the lobby shop.

	ShopController reads this to build the rows inside ShopUI: one wrapper per
	entry in ITEMS, in Order. Adding an item to the shop means editing ITEMS --
	nothing in the GUI has to change, and no wrapper is authored by hand.

	Crate rows carry only the crate name: the display name and the icon come from
	CrateConfig, so the shop never restates what the crate already knows.

	Nothing here is secret. Granting the item is server side -- the client only
	asks, and ServerScriptService validates the price against the profile.
]]

local CrateConfig = require(script.Parent.CrateConfig)

local module = {}

--[[ ANIMATION ]]

-- Module names inside ReplicatedStorage.CascadeAnimations.
module.OPEN_ANIMATION = "OpenShop"
module.ITEM_ANIMATION = "ShopItemContainerShow"

-- Gap between one wrapper and the next when the rows animate in as a batch.
module.ITEM_STAGGER = 0.1

-- How long the rows wait before sliding in, so the panel finishes opening first.
module.ITEM_ANIMATION_DELAY = 0.25

--[[ PROXIMITY ]]

-- The shop opens when the player walks up to this part and closes when they leave.
-- It lives at Workspace.<REFERENCE_PARENT_NAME>.<REFERENCE_PART_NAME>.
module.REFERENCE_PARENT_NAME = "Map"
module.REFERENCE_PART_NAME = "ShopPartReference"

-- Studs from the part, measured against the HumanoidRootPart.
module.OPEN_RADIUS = 40

-- How often the distance is checked. The radius is wide enough that a fifth of a
-- second is imperceptible and cheaper than measuring every frame.
module.PROXIMITY_INTERVAL = 0.2

--[[ TELEPORT ]]

-- Where the HUD shop button drops the player: a marker part next to the shop, at
-- Workspace.<REFERENCE_PARENT_NAME>.<TELEPORT_PART_NAME>. It sits inside the open
-- radius above, so landing there opens the shop on its own.
module.TELEPORT_PART_NAME = "ShopPartTeleport"

-- Studs above the top of the marker, so the character lands standing on it instead
-- of half sunk into it.
module.TELEPORT_HEIGHT_OFFSET = 3

--[[ ITEMS ]]

module.DEFAULT_BUTTON_TEXT = "BUY"

--[=[
	Fields per item:
		Id            unique, what the client sends to the server on purchase
		Order         top to bottom inside the scrolling frame
		Price         in Shards (the premium currency, Data.Template.Stats.Shards)
		Crate         optional: fills DisplayName/Image from CrateConfig and marks
		              the item as granting that crate
		Amount        how many the purchase grants (defaults to 1)
		DisplayName   optional override of the name shown on the row
		Image         optional override of the icon shown on the row
		ButtonText    optional override of the confirm button label
]=]
module.ITEMS = {
	{
		Id = "CommonCrate",
		Order = 1,
		Crate = "Common",
		Price = 100,
	},

	{
		Id = "RareCrate",
		Order = 2,
		Crate = "Rare",
		Price = 250,
	},

	{
		Id = "EpicCrate",
		Order = 3,
		Crate = "Epic",
		Price = 600,
	},

	{
		Id = "LegendaryCrate",
		Order = 4,
		Crate = "Legendary",
		Price = 1500,
	},
}

export type ShopItem = {
	Id: string,
	Order: number,
	Price: number,
	Amount: number,
	DisplayName: string,
	Image: string,
	ButtonText: string,
	Crate: string?,
}

--[=[
	Resolves one raw entry into the row the UI renders. Returns nil (and warns)
	when the entry points at a crate that does not exist, so a typo drops a single
	row instead of breaking the whole shop.
]=]
local function resolveItem(item): ShopItem?
	local displayName = item.DisplayName
	local image = item.Image
	local crate = nil

	if item.Crate then
		crate = CrateConfig.resolveRarity(item.Crate)
		if not crate then
			warn(`[ShopConfig]: item '{item.Id}' points at unknown crate '{item.Crate}'.`)
			return nil
		end

		local crateInfo = CrateConfig.CRATES[crate]
		displayName = displayName or crateInfo.DisplayName
		image = image or crateInfo.Image
	end

	return {
		Id = item.Id,
		Order = item.Order or 0,
		Price = item.Price or 0,
		Amount = item.Amount or 1,
		DisplayName = displayName or item.Id,
		Image = image or "",
		ButtonText = item.ButtonText or module.DEFAULT_BUTTON_TEXT,
		Crate = crate,
	}
end

--[=[
	Every item the shop shows, already resolved and sorted by Order.
]=]
function module.getItems(): { ShopItem }
	local items = {}

	for _, item in module.ITEMS do
		local resolved = resolveItem(item)
		if resolved then
			table.insert(items, resolved)
		end
	end

	table.sort(items, function(a, b)
		return a.Order < b.Order
	end)

	return items
end

--[=[
	Returns the resolved item with that Id, or nil when the shop has no such item.
	The server uses this to price a purchase request.
]=]
function module.getItem(id: string?): ShopItem?
	if typeof(id) ~= "string" then
		return nil
	end

	for _, item in module.ITEMS do
		if item.Id == id then
			return resolveItem(item)
		end
	end

	return nil
end

return module
