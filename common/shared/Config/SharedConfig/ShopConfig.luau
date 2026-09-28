--[[
	Single source of truth for the lobby shop.

	`ShopController` reads this to fill `ShopUI`. **It creates no containers**: each
	crate has its container authored in the `ScrollingFrame`, with its own art, and
	the code only finds the container by name and writes what changes (name, price,
	and rarity list). An item without an authored container does not appear (and
	warns once), and a container without an item in the table stays hidden.

	Crate rows carry only the crate name: the name, the icon, and the **container
	name** come from `CrateConfig`, so the shop never repeats what the crate knows.

	Nothing here is secret. Granting the item is server side -- the client only
	asks, and ServerScriptService validates the price against the profile. Each
	crate's **odds** are also server side: they arrive through the `CrateOdds`
	event, not this table.

	See docs/lobby/shop.md.
]]

local Log = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Log"))
local CrateConfig = require(script.Parent.CrateConfig)
local GamepassConfig = require(script.Parent.GamepassConfig)

local log = Log.new("ShopConfig")

local module = {}

--[[ ANIMATION ]]

--[=[
	Module name inside ReplicatedStorage.CascadeAnimations. `OpenShop` animates two
	tracks: a child `UIScale`'s `Scale` and the panel's `ImageTransparency`.

	The controller creates the `UIScale` when the panel has none authored; without
	it the track has nowhere to write and the shop would only fade in.
]=]
module.OPEN_ANIMATION = "OpenShop"

--[[ PROXIMITY ]]

-- The shop opens when the player walks up to this part and closes when they leave.
-- It lives somewhere under Workspace.<REFERENCE_PARENT_NAME>, at any depth: both
-- markers are grouped in the shop's model, and the controller walks the tree by
-- name instead of requiring them loose at the map root.
module.REFERENCE_PARENT_NAME = "Map"
module.REFERENCE_PART_NAME = "ShopPartReference"

--[[
	Studs from the part, measured against the HumanoidRootPart.

	Five studs is the counter: the shop opens when the player reaches **the**
	shopkeeper, not when they walk past. A wider radius caught half the plaza, and
	players just crossing it opened and closed the shop without asking.

	The wide radius now belongs to the shopkeeper (`KEEPER_APPROACH_RADIUS`), who gets
	up on seeing the player approach. Two moments on purpose: they see you from afar,
	the shop opens at the counter.

	**`ShopPartTeleport` is 14.85 studs from here, outside this radius.** The HUD
	button does not rely on proximity to open: it opens the shop by hand and marks
	the entry, so walking away closes it the same way. See
	`ShopController:TeleportToShop`.
]]
module.OPEN_RADIUS = 5

-- How often the distance is checked. The radius is wide enough that a fifth of a
-- second is imperceptible and cheaper than measuring every frame.
module.PROXIMITY_INTERVAL = 0.2

--[[ TELEPORT ]]

-- Where the HUD shop button drops the player: a marker part next to the shop,
-- searched under Workspace.<REFERENCE_PARENT_NAME> like the one above. It sits
-- outside the open radius, so `TeleportToShop` opens the shop by hand.
module.TELEPORT_PART_NAME = "ShopPartTeleport"

-- Studs above the top of the marker, so the character lands standing on it instead
-- of half sunk into it.
module.TELEPORT_HEIGHT_OFFSET = 3

--[[ SHOPKEEPER ]]

--[=[
	The shopkeeper, found by name under Workspace.<REFERENCE_PARENT_NAME>, like the
	markers.

	It has no `Humanoid`: animations play through its `AnimationController`'s
	`Animator`. The **client** plays them, not the server, so the shopkeeper reacts
	to whoever arrived, not to "someone arrived". Two players in the Lobby each see
	the shopkeeper serving them.
]=]
module.KEEPER_MODEL_NAME = "Entrepreneur"

--[=[
	Studs from `REFERENCE_PART_NAME` (the same center the shop uses, not the
	shopkeeper's body) at which it leaves its rest and gets up to serve.

	It must be **larger** than `OPEN_RADIUS`, with enough margin to see the
	animation: the player crosses these 20 studs walking, `GetUp` plays on the way,
	and by the time they reach the counter the shopkeeper is standing. Equal radii
	would make it stand up as the shop opens, too late to be a gesture.
]=]
module.KEEPER_APPROACH_RADIUS = 20

--[=[
	The shopkeeper's animations, by the name of the model's `Animation` child.

	Each is a moment of the visit, not a code step: `IDLE` is what it does alone all
	day, `GET_UP` is standing up, `ATTEND` is waiting at the counter, and the two
	goodbyes depend on whether the player bought something.

	**The sour goodbye is not a bug.** Leaving without buying plays `FAREWELL_EMPTY`
	(`ByeByeEvil`); leaving after a purchase plays `FAREWELL_SOLD`. It is the only
	thing the shop remembers about the visit, reset when the player enters the radius.
]=]
module.KEEPER_IDLE_ANIMATION = "Idle"
module.KEEPER_GET_UP_ANIMATION = "GetUp"
module.KEEPER_ATTEND_ANIMATION = "IdleBench"
module.KEEPER_FAREWELL_SOLD_ANIMATION = "ByeBye"
module.KEEPER_FAREWELL_EMPTY_ANIMATION = "ByeByeEvil"

-- Crossfade between one animation and the next. Short because its transitions are
-- gestures (standing up, waving), not poses: half a second of blending would smear
-- the start of the wave with the end of the idle.
module.KEEPER_FADE_TIME = 0.2

--[=[
	The longest a gesture may take before the shopkeeper falls into the next pose
	anyway.

	A safety net, not pacing: the track's own `Stopped` ends `GetUp` and the wave.
	But an `Animation` whose asset does not load **never plays**, so `Stopped` never
	arrives; without this cap the shopkeeper would freeze mid-gesture forever, since
	automatic recovery only covers the two resting poses.

	Ten seconds is generous on purpose: it must not cut a real gesture, and a
	shopkeeper stuck for ten seconds still recovers on its own.
]=]
module.KEEPER_GESTURE_TIMEOUT = 10

--[[ ITEMS ]]

--[[
	The price on the `Buy` button label: `50`, `1,800`.

	Just the number. The currency is not written: the button carries its icon (see
	`CURRENCIES`), and repeating the word only stole width from the number, the only
	part that changes between crates.

	The number goes through `UIUtil.formatCommas`, so the legendary reads `1,800`.
]]
module.PRICE_FORMAT = "%s"

module.DEFAULT_BUTTON_TEXT = "BUY"

--[[ CURRENCIES ]]

--[=[
	The currencies the shop accepts, by their key in `Data.Stats`.

	**The key is the profile name, not the screen name**: players read "Coins" and
	the profile has always stored `Cash` (see `LeaderstatsService`). Writing the
	screen word here would create a ghost `Stats.Coins` the day the server charged it.

	`ShopController` paints each currency's color and icon on the button; this is
	only what the server needs to charge.
]=]
module.CURRENCIES = {
	Shards = "Shards",
	Cash = "Cash",
}

-- An item without `Currency` charges Shards, the shop's only currency before the
-- common and nature crates started costing Coins.
module.DEFAULT_CURRENCY = "Shards"

--[=[
	Fields per item:
		Id            unique, what the client sends to the server on purchase
		Order         top to bottom inside the scrolling frame
		Price         how much of Currency the purchase costs
		Currency      optional: a key of CURRENCIES, defaults to DEFAULT_CURRENCY
		Crate         optional: fills DisplayName/Image/Container from CrateConfig
		              and marks the item as granting that crate
		Amount        how many the purchase grants (defaults to 1)
		DisplayName   optional override of the name shown on the row
		Image         optional override of the icon shown on the row
		ButtonText    optional override of the confirm button label
]=]

--[[
	**The shop charges in two currencies.**

	The first two crates cost Coins (`Stats.Cash`), what the player earns by playing,
	and the other two stay in Shards. With everything in shards, the common crate
	competed with the legendary for the same wallet.

	Prices are set against what a **complete** run pays today (see `WinCash` and
	`WinShards` in `Config.Difficulty`): 100 coins and 1 shard on Easy, 900 coins and
	5 shards on Nightmare. At that scale, a Crate of Beginnings every half run on Easy
	and a Fragmented Crate every run on Nightmare.

	**The legendary is out of scale.** Its 1,800 shards date from when a run paid 60
	shards on Medium; at 5 on Nightmare, that is 360 matches. It does not appear in
	the shop today (no `LegendaryCrate` container is authored), so no player sees the
	number, but it must be repriced before it returns.
]]
module.ITEMS = {
	{
		Id = "CrateOfBeginnings",
		Order = 1,
		Crate = "Common",
		Price = 50,
		Currency = "Cash",
	},

	{
		Id = "CrateOfNature",
		Order = 2,
		Crate = "Rare",
		Price = 200,
		Currency = "Cash",
	},

	{
		Id = "FragmentedCrate",
		Order = 3,
		Crate = "Epic",
		Price = 4,
		Currency = "Shards",
	},

	--[[
		The legendary is still for sale in the table and **stays off screen**: the
		`ScrollingFrame` only has containers for the top three, and the controller only
		draws crates with a container.

		It was not removed on purpose: it exists in the inventory, drops, and unboxing,
		and the day a `LegendaryCrate` container is authored it returns with no code
		change.
	]]
	{
		Id = "LegendaryCrate",
		Order = 4,
		Crate = "Legendary",
		Price = 1800,
		Currency = "Shards",
	},
}

export type ShopItem = {
	Id: string,
	Order: number,
	Price: number,
	Currency: string,
	Amount: number,
	DisplayName: string,
	Image: string,
	ButtonText: string,
	Crate: string?,
	Container: string,
}

--[=[
	What this profile pays for an item, with game pass discounts included.

	**Rounds to the nearest value, with a floor of 1.** Not up: the Fragmented Crate
	costs 4 shards, 20% of that is 0.8, and rounding up would charge VIP players the
	same 4. The floor exists because a discount that zeroes the price gives the crate
	away.

	Both sides call this function: `ShopService` to charge and `ShopController` to
	write the button. The price on screen is the price charged because it is the same
	math.
]=]
function module.priceFor(item, profile) : number
	local price = typeof(item) == "table" and item.Price or 0
	local multiplier = GamepassConfig.cratePriceMultiplier(profile)

	if multiplier >= 1 then
		return price
	end

	return math.max(math.floor(price * multiplier + 0.5), 1)
end

--[=[
	The currency the item charges, as a `Data.Stats` key.

	An unknown currency falls back to the default with a warning instead of becoming
	`stats[nil]` on the server: a typo here would charge a field the profile lacks,
	and the crate would be free.
]=]
local function resolveCurrency(item): string
	local currency = item.Currency
	if currency == nil then
		return module.DEFAULT_CURRENCY
	end

	if not module.CURRENCIES[currency] then
		log:StudioWarn(`item '{item.Id}' prices in unknown currency '{currency}', falling back to {module.DEFAULT_CURRENCY}.`)
		return module.DEFAULT_CURRENCY
	end

	return module.CURRENCIES[currency]
end

--[=[
	Resolves one raw entry into the row the UI renders. Returns nil (and warns)
	when the entry points at a crate that does not exist, so a typo drops a single
	row instead of breaking the whole shop.
]=]
local function resolveItem(item): ShopItem?
	local displayName = item.DisplayName
	local image = item.Image
	local crate = nil
	local container = item.Container

	if item.Crate then
		crate = CrateConfig.resolveRarity(item.Crate)
		if not crate then
			log:StudioWarn(`item '{item.Id}' points at unknown crate '{item.Crate}'.`)
			return nil
		end

		local crateInfo = CrateConfig.CRATES[crate]
		displayName = displayName or crateInfo.DisplayName
		image = image or crateInfo.Image

		-- The container is the crate's `Key`: one name for the model, the container, and
		-- the `Id` here. See `CRATES` in `CrateConfig`.
		container = container or crateInfo.Key
	end

	return {
		Id = item.Id,
		Order = item.Order or 0,
		Price = item.Price or 0,
		Currency = resolveCurrency(item),
		Amount = item.Amount or 1,
		DisplayName = displayName or item.Id,
		Image = image or "",
		ButtonText = item.ButtonText or module.DEFAULT_BUTTON_TEXT,
		Crate = crate,
		Container = container or item.Id,
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
