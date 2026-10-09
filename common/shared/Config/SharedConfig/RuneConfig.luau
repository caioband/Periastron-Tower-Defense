--[[
	Runes: temporary buffs bought with shards in the Lobby rune shop
	(`StarterGui.ShopUI.RuneShop`).

	Each rune has three tiers. A tier only changes the bonus and the price; the
	duration is the same for every tier (`DURATION`).

	## The time only runs while the player is in the game

	The profile keeps the seconds **left**, not an expiry date
	(`Runes = { [Id] = { Tier, Remaining } }`). `RuneService` counts down while the
	profile is open on a server (Lobby, Game, or AFK), so time offline and time spent
	teleporting between places are free.

	## Buying again

	Only one tier of each rune is active at a time (`purchaseAction`):

	  - The same tier adds another `DURATION` on top of what is left.
	  - A higher tier replaces the active one and starts a fresh `DURATION`.
	  - A lower tier is refused while a higher one is active.

	## Where the bonus applies

	The Shards rune multiplies the shards from the end-of-match reward, on top of
	the game passes (`WaveService:rewardsFor`). A rune that is active at any point
	of a match covers the whole match, even if it runs out before the last wave
	(`RuneService:Lock`).

	This module is shared because both sides read it: the client to draw the shop
	and the countdown, the server to charge and to apply the bonus.

	See docs/common/runes.md and docs/lobby/rune-shop.md.
]]

local RuneConfig = {}

--[[ CATALOG ]]

-- The `Data.Stats` key that pays for a rune without its own `Currency`.
RuneConfig.CURRENCY = "Shards"

--[=[
	How each currency reads on the buy button: the word after the price and the
	color of the label's `UIStroke`. The colors are the crate shop's
	(`ShopController`'s `CURRENCY_STYLE`), so a price reads the same in every shop.

	Keyed by the `Data.Stats` key, not the screen word: the profile stores coins as
	`Cash`.
]=]
RuneConfig.CURRENCIES = {
	Shards = { Name = "Shards", Color = Color3.fromRGB(69, 92, 241) },
	Cash = { Name = "Coins", Color = Color3.fromRGB(211, 170, 88) },
}

-- How long one purchase lasts, in seconds of play. The same for every tier.
RuneConfig.DURATION = 25 * 60

export type Tier = {
	-- Added to the multiplier: 0.10 is +10%.
	Bonus : number,
	Price : number,
}

export type Rune = {
	-- The profile key, and the name of the rune's frame in `RuneShop.Runes`.
	Id : string,
	DisplayName : string,

	-- What the bonus multiplies, written after the percentage in the shop.
	Effect : string,

	-- The `Data.Stats` key that pays for it (a key of `CURRENCIES`). Default `CURRENCY`.
	Currency : string?,

	-- Tier 1 first.
	Tiers : { Tier },
}

--[=[
	Every rune the shop sells. To add one, add an entry and author a frame with the
	same `Id` in `RuneShop.Runes`; then make the reward it boosts read
	`RuneService:GetMultiplier(player, Id)`.

	Prices are steep on purpose: a full Nightmare run pays 5 shards.
]=]
RuneConfig.Runes = {
	{
		Id = "Shards",
		DisplayName = "SHARD",
		Effect = "SHARDS GAIN",
		Tiers = {
			{ Bonus = 0.10, Price = 10 },
			{ Bonus = 0.20, Price = 20 },
			{ Bonus = 0.35, Price = 40 },
		},
	},
} :: { Rune }

--[[ WHERE THE SHOP LIVES IN THE GUI ]]

--[=[
	The authored names. `ShopUI` holds every Lobby shop as siblings, so this one only
	shows and hides its own wrapper (see `ProximityPanel`'s `CanDisable`).
]=]
RuneConfig.Gui = {
	ScreenGui = "ShopUI",

	-- The wrapper (it owns the `UIAspectRatioConstraint` and the X) and the art
	-- inside it, which `OPEN_ANIMATION` animates.
	Wrapper = "RuneShop",
	Panel = "Runes",

	-- Inside each rune's frame (named after its `Id`, a child of `Panel`).
	Display = "RuneDisplay",
	Previous = "Previous",
	Next = "Next",
	Name = "RuneType",
	Tier = "CurrentTier",
	Buy = "Buy",
	BuyLabel = "TextLabel",

	-- The bonus line ("+10% SHARDS GAIN (25m)"), a direct child of the rune's frame.
	Description = "TextLabel",

	-- The list of active runes, a child of the wrapper: one clone of `ActiveRow` per
	-- active rune, with the text on `ActiveText`.
	ActiveList = "ActiveRunes",
	ActiveRow = "RuneActiveWrapper",
	ActiveText = "Rune",
}

RuneConfig.OPEN_ANIMATION = "OpenShop"

--[[ TEXT ]]

RuneConfig.TIER_NAMES = { "I", "II", "III" }

-- `TIER II`
RuneConfig.TIER_FORMAT = "TIER %s"

-- `20 Shards`: the price, with commas, and the currency's `Name`.
RuneConfig.PRICE_FORMAT = "%s %s"

-- On the button while a higher tier of the same rune is active.
RuneConfig.BLOCKED_TEXT = "HIGHER ACTIVE"

-- `+20% SHARDS GAIN (25m)`: the bonus in whole percent, the effect, the duration.
RuneConfig.DESCRIPTION_FORMAT = "+%d%% %s (%s)"

-- `SHARD II · 24:13`: an active rune, its tier, and the time left.
RuneConfig.ACTIVE_FORMAT = "%s %s · %s"

-- The single row shown when no rune is active.
RuneConfig.EMPTY_TEXT = "NONE"

--[[ PROXIMITY ]]

--[=[
	The shop's markers, searched in depth under `Workspace.Map`. The landing marker is
	about 21 studs from the reference, outside `OPEN_RADIUS`, so the teleport opens the
	panel by hand (see `RuneShopController:TeleportToShop`).
]=]
RuneConfig.REFERENCE_PARENT_NAME = "Map"
RuneConfig.REFERENCE_PART_NAME = "RunesShopPartReference"
RuneConfig.TELEPORT_PART_NAME = "RunesShopPartTeleport"

RuneConfig.OPEN_RADIUS = 5
RuneConfig.PROXIMITY_INTERVAL = 0.2
RuneConfig.TELEPORT_HEIGHT_OFFSET = 3

--[[ API ]]

local byId : { [string] : Rune } = {}
for _, rune in RuneConfig.Runes do
	byId[rune.Id] = rune
end

function RuneConfig.Get(id : any) : Rune?
	return if typeof(id) == "string" then byId[id] else nil
end

--- The `Data.Stats` key that pays for a rune: its own `Currency`, or `CURRENCY`.
function RuneConfig.currencyOf(rune : Rune) : string
	local currency = rune.Currency
	return if currency and RuneConfig.CURRENCIES[currency] then currency else RuneConfig.CURRENCY
end

function RuneConfig.getTier(id : any, tier : any) : Tier?
	local rune = RuneConfig.Get(id)
	if not rune or typeof(tier) ~= "number" then
		return nil
	end

	return rune.Tiers[tier]
end

--[=[
	A rune's saved record, cleaned up: `{ Tier, Remaining }`, or nil when the rune is
	not active. Anything malformed (a tier that left the config, a negative time)
	counts as not active.
]=]
function RuneConfig.entryOf(runes : any, id : string) : { Tier : number, Remaining : number }?
	local entry = typeof(runes) == "table" and runes[id] or nil
	if typeof(entry) ~= "table" then
		return nil
	end

	local tier = tonumber(entry.Tier)
	local remaining = tonumber(entry.Remaining) or 0

	if not tier or not RuneConfig.getTier(id, tier) or remaining <= 0 then
		return nil
	end

	return { Tier = tier, Remaining = remaining }
end

--[=[
	What buying `tier` does with `active` (the record from `entryOf`, or nil):
	`"New"`, `"Extend"`, `"Upgrade"`, or nil plus `"LowerTier"` when it is refused.

	The client uses it to dim the button and the server to decide, so both sides
	always agree.
]=]
function RuneConfig.purchaseAction(active : { Tier : number, Remaining : number }?, tier : number) : (string?, string?)
	if not active then
		return "New"
	end

	if tier == active.Tier then
		return "Extend"
	end

	if tier > active.Tier then
		return "Upgrade"
	end

	return nil, "LowerTier"
end

function RuneConfig.tierName(tier : number) : string
	return RuneConfig.TIER_NAMES[tier] or tostring(tier)
end

--- `25m`, `1h`, `1h 30m`: a duration for the bonus line.
function RuneConfig.formatDuration(seconds : number) : string
	local minutes = math.floor(seconds / 60 + 0.5)
	local hours = minutes // 60
	minutes %= 60

	if hours > 0 and minutes > 0 then
		return string.format("%dh %dm", hours, minutes)
	elseif hours > 0 then
		return string.format("%dh", hours)
	end

	return string.format("%dm", minutes)
end

--- `24:13`, or `1:02:05` past an hour: the time left on an active rune.
function RuneConfig.formatCountdown(seconds : number) : string
	local total = math.max(math.ceil(seconds), 0)
	local hours = total // 3600
	local minutes = (total % 3600) // 60

	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, total % 60)
	end

	return string.format("%d:%02d", minutes, total % 60)
end

return RuneConfig
