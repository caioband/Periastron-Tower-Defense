--[[
	The Lobby card shop: `StarterGui.ShopUI.RCSS`.

	It sells **access** to `RoundCardConfig` cards, not the cards themselves. A card
	bought here goes to no hotbar: it enters the profile's `RoundCards` and from then
	on can be drawn in the in-match round offer (see `CardShopService`'s `_pool`).
	Buying unlocks; using it still means buying it again in the match, with round cash.

	The in-match offer draws only from what the player unlocked, which is what gives
	the Lobby a shop with progression instead of a decorative storefront.

	## Each player's stock, on a rotation

	Three cards per four-hour block, **drawn per player**: two friends in the same
	Lobby see different offers.

	The **clock** is shared: the four-hour block comes from `os.time()`
	(`rotationIndex`) and always turns at 00:00, 04:00, 08:00... UTC, so `ResetText`
	("RESETS IN: 3:12:04") still means something: stocks are personal, but they all
	turn at the same instant.

	It is **stored** nowhere: the three cards are recomputed from the block plus the
	`UserId` (`stockFor`). A server that starts mid-block reaches the same stock for
	each player, and no DataStore is needed for something time and owner answer.

	**This holds because the pool does not change.** The stock draw scans the whole
	catalog, including cards the player already unlocked (they show the `SOLD`
	veil). A pool that shrank with each purchase would rebuild the stock by itself,
	which is why the reroll, whose pool does shrink, **is** saved. See
	`createEmptyRoll`.

	## Who decides what

	Drawing the stock and charging are **server-side** (`RoundCardShopService`, in the
	Lobby). The client receives the three drawn cards with their prices, draws them,
	and sends "I want card X"; the server checks that X is in **the current** stock,
	that the player does not own it yet, and that the shards cover it.

	This module is shared because both sides read the same rules: the client to write
	prices and the countdown, the server to charge and to know the current stock.

	See docs/lobby/round-card-shop.md.
]]

local Log = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Log"))
local RoundCardConfig = require(script.Parent.RoundCardConfig)

local log = Log.new("RoundCardShopConfig")

local RoundCardShopConfig = {}

--[[ WHERE THE SHOP LIVES IN THE GUI ]]

--[=[
	The authored names, in one place.

	**The shop shares its `ScreenGui` with other shops.** `ShopUI` holds the panels as
	siblings (`Frame` is the crate shop, `RCSS` is this one), so none of them may own
	the ScreenGui's `Enabled` alone: each wrapper's `Visible` says which panel is on
	screen. See each controller's `_setShopEnabled`.
]=]
RoundCardShopConfig.Gui = {
	ScreenGui = "ShopUI",

	-- The wrapper (it owns the `UIAspectRatioConstraint`) and the panel drawn inside
	-- it, which `OPEN_ANIMATION` animates.
	Wrapper = "RCSS",
	Panel = "ImageLabel",

	-- The row of three cards, under a horizontal `UIListLayout`.
	Row = "CardsContainer",

	--[[
		A card's template. The wrapper is what enters the `UIListLayout`, which is why
		it exists: the card inside it animates position and scale freely without the
		layout dragging it back to its slot every frame.

		The `CardWrapper` authored in `CardsContainer` is the template, not the first
		card: the controller clones it three times and destroys the original (see
		`_template`).
	]]
	Wrapper_Card = "CardWrapper",
	Card = "Card",

	Title = "CardTitle",
	Description = "CardDescription",

	-- The buy button and the price number inside it. The shard icon and the outline
	-- color are authored on the button: this shop charges in one currency.
	Buy = "Buy",
	BuyLabel = "TextLabel",

	-- The "SOLD" veil, lit on cards this player has already unlocked.
	Sold = "SoldFrame",

	--[=[
		How long until the stock changes.

		**Looked up as a direct child of the panel, not in depth.** The name is unique
		in `RCSS` today, and the shallow search keeps that cheap to guarantee: the label
		inside `RerollDice` is called `Text`, and if someone names another label
		`ResetText` anywhere in the panel, the countdown still goes here, not wherever
		tree order returns first.
	]=]
	ResetText = "ResetText",

	-- The die that rerolls this player's stock, for Robux.
	Reroll = "RerollDice",
}

--[[
	The panel's animation, in `ReplicatedStorage.CascadeAnimations`.

	The **same** `OpenShop` as the crate shop, on purpose: both are the same counter
	gesture in the same Lobby, and sibling panels in the same `ScreenGui`. It animates
	a child `UIScale`'s `Scale` and the panel's `ImageTransparency`; the controller
	creates the `UIScale` when the panel has none authored.
]]
RoundCardShopConfig.OPEN_ANIMATION = "OpenShop"

--[[ PROXIMITY ]]

--[=[
	The shop markers, searched **in depth** under `Workspace.<REFERENCE_PARENT_NAME>`:
	both are inside the house model (`Map.Deco.Houses.CardShop`), not loose at the map
	root.

	The same pair of parts as the crate shop (reference + landing) with another name,
	and the same agreement in everything, including distance: the landing is **18.8
	studs** from the reference, outside `OPEN_RADIUS`. The teleport opens the panel by
	hand and marks the entry; see `RoundCardShopController:TeleportToShop`.
]=]
RoundCardShopConfig.REFERENCE_PARENT_NAME = "Map"
RoundCardShopConfig.REFERENCE_PART_NAME = "ShopCardPartReference"
RoundCardShopConfig.TELEPORT_PART_NAME = "ShopCardPartTeleport"

--[[
	Studs from the reference marker, measured against the `HumanoidRootPart`.

	The same 5 as the crate shop: the counter. The shop opens when the player
	**reaches** it, not when they cross the plaza in front of it.

	**`ShopCardPartTeleport` is 18.8 studs from here, outside this radius.** The
	teleport does not rely on proximity to open: it opens the shop by hand and marks
	the entry, so walking away closes it the same way.
]]
RoundCardShopConfig.OPEN_RADIUS = 5

-- How often distance is measured. The radius is wide enough that a fifth of a
-- second is imperceptible, and it is cheaper than measuring every frame.
RoundCardShopConfig.PROXIMITY_INTERVAL = 0.2

-- Studs above the landing marker's top, so the character lands standing on it
-- instead of half buried.
RoundCardShopConfig.TELEPORT_HEIGHT_OFFSET = 3

--[[ ROTATION ]]

--[=[
	How long a stock lasts, in seconds.

	Four hours counted from the epoch, not from server start: blocks always turn at
	00:00, 04:00, 08:00... UTC, which is how every server agrees on the current stock
	without talking.
]=]
RoundCardShopConfig.ROTATION_SECONDS = 4 * 60 * 60

--- How many cards the stock shows.
RoundCardShopConfig.STOCK_COUNT = 3

--[=[
	The stock draw's seed, multiplied by the block number.

	A large prime, so neighboring blocks do not fall into neighboring sequences: with
	the index itself as the seed, consecutive blocks' `Random` starts too close and
	the first card would barely change every four hours.
]=]
RoundCardShopConfig.ROTATION_SEED = 2654435761

--[=[
	The player's share of the stock seed. It is what makes two people in the same
	block get different cards.

	**It must be a different multiplier from `ROTATION_SEED`.** With the same
	constant on both, block and player become interchangeable in the sum: someone's
	stock today would be someone else's tomorrow, and the rotation would stop looking
	random to players with friends.

	Small on purpose: it multiplies a `UserId`, which is already large. A large prime
	on both sides would only push the sum toward the limit of floating-point
	exactness without separating anything better.
]=]
RoundCardShopConfig.PLAYER_SEED = 40503

--[[ REROLL ]]

--[=[
	The developer product that rerolls the stock: "Reroll Card Shop", 14 Robux.

	Stocks are already per player (see the top of this file), so the reroll invents
	nothing: it only replaces **that** player's three cards. It changes their origin:
	instead of the block's draw, they come from what was saved in the profile, until
	the block turns.

	The `ResetText` countdown does **not** change with a reroll: it is the global
	rotation clock, exactly when the rerolled shelf expires and the player returns to
	the block's draw. A reroll buys cards, not time.
]=]
RoundCardShopConfig.REROLL_PRODUCT_ID = 3712166271

--[=[
	Whether the reroll should avoid cards the player already unlocked.

	`true`, and that is the product's point: the normal stock shows unlocked cards
	with the `SOLD` veil, but a **paid** reroll returning three cards the player
	already owns would be money for nothing.

	**Best effort, not a prohibition.** The draw fills the three slots with what is
	still locked; if fewer remain, it completes with unlocked cards instead of
	returning a shelf of two. Three slots with one `SOLD` is a stock; two cards in a
	three-card panel is a broken one. See `drawReroll`.

	When **nothing** is missing, the button is disabled before the prompt (see the
	controller's `_refreshReroll`): the time to prevent a useless purchase is before
	Roblox charges.
]=]
RoundCardShopConfig.REROLL_EXCLUDES_UNLOCKED = true

--[[ PRICES ]]

--[=[
	The shop's price range, in shards. No price leaves it.

	It decides no price (the `PRICES` table below does); it **clamps** what is
	written there: a mistyped `12` becomes 8, and a `0` becomes 4. The shop never
	reaches the player with a price outside the agreed scale.

	4 to 8 against what a run pays today (see `WinShards` in `Config.Difficulty`: 1 on
	Easy, 5 on Nightmare): the cheapest card is one Nightmare run and the most
	expensive almost two. The scale is deliberate: unlocking a card is permanent, and
	there are two dozen to collect.
]=]
RoundCardShopConfig.MIN_PRICE = 4
RoundCardShopConfig.MAX_PRICE = 8

--[=[
	**Each card's price, in shards. This table rules.**

	One line per `RoundCardConfig` card, grouped by price. Changing a card's price is
	changing its number here and nothing else; no other code computes prices.

	Groups are ordered by cost, not catalog order, because the question asked here is
	usually "what costs 7?" rather than "how much is Trumpet?". Finding one card's
	price is still a Ctrl+F by `Id`.

	## The scale

	Today's numbers follow the card's cost **in the match** (its `RoundCardConfig`
	`Price`, from 150 to 500): what is expensive in a round is expensive to unlock.
	That is not a rule the code enforces, only where the first version of this table
	came from; any number here can change on its own.

	The distribution is a bell: one card at each end and the middle between 5 and 7.

	## New cards

	A card in `RoundCardConfig` that is **not** here does not break the shop: it falls
	into `priceOf`, which maps its match cost onto `MIN_PRICE..MAX_PRICE` and returns a
	plausible number. That is a safety net, not the path: a new card deserves a line
	here, decided by whoever is balancing.

	Every price, written or computed, goes through the range above before reaching
	the screen.
]=]
RoundCardShopConfig.PRICES = {
	-- The cheapest in the catalog. It changes no stat: it only moves a tower.
	--
	Zippers = 4,

	TimeAcceleration = 5,
	Iceolated = 5,
	ChillOut = 5,
	FireHazard = 5,
	NoPainNoGain = 5,
	BloxyCola = 5,
	Bloxiade = 5,

	TimeStop = 6,
	WeatherReport = 6,
	Overcharge = 6,
	PunchLine = 6,
	Axecellent = 6,
	Abrakadabra = 6,
	IceToMeetYou = 6,
	StaffOfHealing = 6,

	MoneyBag = 7,
	Trumpet = 7,
	WattsUp = 7,
	CleaveItToMe = 7,
	AzureEverIce = 7,
	RobuxRoyaltyStaff = 7,
	WindsStaff = 7,

	-- The top, alone: the most expensive card in the match (500 cash), well above the
	-- second.
	CelestialStaff = 8,
}

-- The currency, as a `Data.Stats` key. The crate shop charges in two (see
-- `ShopConfig.CURRENCIES`); this one charges in one, and its icon is authored
-- inside the `Buy` button.
RoundCardShopConfig.CURRENCY = "Shards"

--[[ TEXT ]]

-- The price number in `Buy.TextLabel`. Just the number: the currency icon sits next
-- to it, and repeating the word would steal width from the only part that changes
-- between cards. The same agreement as `ShopConfig.PRICE_FORMAT`.
RoundCardShopConfig.PRICE_FORMAT = "%s"

-- `ResetText`, with the countdown already formatted as `h:mm:ss`.
RoundCardShopConfig.RESET_FORMAT = "RESETS IN: %s"

--[[ WHAT A NEW PLAYER ALREADY HAS ]]

--[=[
	The cards a new profile starts with unlocked.

	Six, for two reasons. First, with no cards the round offer **never opens**: a new
	player would never see the round shop and could not connect that to a Lobby shop
	they have not visited. Second, precedent: the template's `Units` already gives
	Slasher, Sword, and Slingshot for the same reason: the game introduces a little of
	everything and saves the rest to be earned.

	The first three are the classic instant cards that need no target: the player
	learns the flow with cards they can use without learning to aim.

	The next three round out the vocabulary: Trumpet is a timed buff for the whole
	room, and Bloxy Cola and Bloxiade are the two drinks, the first aiming the player
	learns and the cheapest to get wrong. Without a targeted card in the kit,
	`Use.Unit` would only be discovered after a blind shard purchase.

	Emptying this list closes the round offer for anyone who never bought anything:
	one line, and a design decision, not a side effect.
]=]
RoundCardShopConfig.STARTER_CARDS = {
	"TimeStop",
	"TimeAcceleration",
	"WeatherReport",
	"Trumpet",
	"BloxyCola",
	"Bloxiade",
}

--[[ API ]]

--[=[
	A new profile's `RoundCards`: `{ [card Id] = true }`.

	This is what `Data.Template` stores, and only that: `DataService`'s reconcile
	creates the key where it is missing but does not touch an existing `RoundCards`.
	Existing players get cards added later through `missingStarters` below.
]=]
function RoundCardShopConfig.createEmpty() : { [string]: boolean }
	local unlocked = {}

	for _, cardId in RoundCardShopConfig.STARTER_CARDS do
		if RoundCardConfig.Get(cardId) then
			unlocked[cardId] = true
		else
			log:StudioWarn(`STARTER_CARDS lists '{cardId}', which is not in RoundCardConfig.`)
		end
	end

	return unlocked
end

--[=[
	The starter cards this `RoundCards` still lacks: `{ Id }`.

	The kit is **retroactive**, as a decision: `STARTER_CARDS` is not the welcome gift
	of whoever started that month, it is everyone's floor. When it grows, existing
	players get the same floor, or two players side by side would see offers built
	from different catalogs with nothing on screen explaining why.

	It does **not** refund shards to players who already bought one in the Lobby
	shop: the card is already in their `RoundCards`, so it does not appear here and
	nothing is rewritten.

	Returns an empty list when nothing is missing (almost every call), which lets the
	caller skip the profile write.
]=]
function RoundCardShopConfig.missingStarters(unlocked : any) : { string }
	local owned = typeof(unlocked) == "table" and unlocked or {}
	local missing = {}

	for _, cardId in RoundCardShopConfig.STARTER_CARDS do
		if owned[cardId] ~= true and RoundCardConfig.Get(cardId) then
			table.insert(missing, cardId)
		end
	end

	return missing
end

--[=[
	A new profile's `RoundCardRoll`: no reroll, in no block.

	`Cards` is the rerolled shelf, **saved**: the drawn `Id`s, in the order the shop
	shows them. `Index` says which four-hour block it belongs to and `Rolls` counts
	the rerolls bought in it.

	## Why the shelf is saved, not recomputed

	The reroll draw scans only what the player does not own yet
	(`REROLL_EXCLUDES_UNLOCKED`), and that pool shrinks when they buy, including when
	they buy a card from the rerolled shelf itself. Recomputed from a seed of (block,
	player, number of rerolls), buying one of the three removed it from the pool, the
	draw ran again, and the slot **refilled with a new card** instead of staying
	`SOLD`: one reroll gave access to the whole catalog, one purchase at a time.

	The normal stock does **not** have this problem even though it is computed: it
	draws from the whole catalog, which does not change when the player buys.

	A shelf is a result, not a formula: the formula had an ingredient the player
	controls. Three strings in the profile solve it and are simpler than any seed.

	`Index = -1` rather than `0` because `0` is a real block (January 1, 1970): a new
	profile must start with no reroll, not a reroll of a block the math could reach.
]=]
function RoundCardShopConfig.createEmptyRoll() : { Index : number, Rolls : number, Cards : { string } }
	return { Index = -1, Rolls = 0, Cards = {} }
end

--[=[
	How many rerolls this profile bought **in block `index`**.

	Zero when `RoundCardRoll` is from an earlier block: the reroll lasts until the
	rotation turns. Nothing needs to erase the old record; it stops applying when the
	block number changes.
]=]
function RoundCardShopConfig.rollsOf(profile : any, index : number) : number
	local roll = typeof(profile) == "table" and profile.RoundCardRoll
	if typeof(roll) ~= "table" or roll.Index ~= index then
		return 0
	end

	return math.max(math.floor(tonumber(roll.Rolls) or 0), 0)
end

--[=[
	The shelf this profile rerolled **in block `index`**: the saved `Id`s, in order.

	Empty when `RoundCardRoll` is from an earlier block: the reroll lasts until the
	rotation turns, which returns the player to the new block's draw. Nothing needs
	to erase the old record.

	Returns a new list, not the profile's: callers build the stock on top of it and
	must not end up writing to what is saved.
]=]
function RoundCardShopConfig.rolledCardsOf(profile : any, index : number) : { string }
	local roll = typeof(profile) == "table" and profile.RoundCardRoll
	if typeof(roll) ~= "table" or roll.Index ~= index or typeof(roll.Cards) ~= "table" then
		return {}
	end

	local cards = {}
	for _, cardId in roll.Cards do
		if typeof(cardId) == "string" then
			table.insert(cards, cardId)
		end
	end

	return cards
end

--[=[
	A list of `Id`s turned into stock entries: `{ { Id, Price } }`.

	An `Id` that is no card is dropped with a warning instead of becoming a slot the
	screen cannot draw. It happens when a card leaves `RoundCardConfig` after being
	drawn for someone: their shelf shrinks until the rotation turns, better than a
	ghost card for sale.
]=]
function RoundCardShopConfig.entriesFor(cardIds : { string }) : { { Id : string, Price : number } }
	local entries = {}

	for _, cardId in cardIds do
		if RoundCardConfig.Get(cardId) then
			table.insert(entries, {
				Id = cardId,
				Price = RoundCardShopConfig.priceOf(cardId),
			})
		else
			log:StudioWarn(`the shelf holds '{cardId}', which is no longer in the catalog.`)
		end
	end

	return entries
end

--[=[
	The cards this profile unlocked: `{ [Id] = true }`.

	A profile not loaded yet counts as empty, not an error, the same agreement as
	`IndexConfig.entriesOf`: until the data arrives, the player counts as owning
	nothing, which the screen can draw.
]=]
function RoundCardShopConfig.unlockedOf(profile : any) : { [string]: boolean }
	local unlocked = typeof(profile) == "table" and profile.RoundCards

	return typeof(unlocked) == "table" and unlocked or {}
end

--- Whether the profile has already unlocked this card.
function RoundCardShopConfig.isUnlocked(profile : any, cardId : any) : boolean
	if typeof(cardId) ~= "string" then
		return false
	end

	return RoundCardShopConfig.unlockedOf(profile)[cardId] == true
end

--[=[
	What the shop charges for this card, in shards.

	**`PRICES` first.** It decides; the rest of this function only exists for a card
	that has no line there yet.

	The fallback maps the card's match cost onto `MIN_PRICE..MAX_PRICE` against the
	**catalog's** extremes, not numbers written here: a new 600 card pushes the top,
	and the others stay spread between 4 and 8 instead of all sticking to the ceiling.
	A single-price (or single-card) catalog falls to the floor: with no range to
	stretch there is nothing to distinguish, and charging everyone the ceiling would
	make the most expensive shop possible by accident.

	An `Id` that is no card (it comes from the network) costs the floor. Both sides
	call this function (the client for the button, the server to charge), so the price
	on screen is the price charged because it is the same math.
]=]
function RoundCardShopConfig.priceOf(cardId : any) : number
	local min = RoundCardShopConfig.MIN_PRICE
	local max = RoundCardShopConfig.MAX_PRICE

	local override = typeof(cardId) == "string" and RoundCardShopConfig.PRICES[cardId]
	if typeof(override) == "number" then
		return math.clamp(math.floor(override + 0.5), min, max)
	end

	local card = RoundCardConfig.Get(cardId)
	if not card then
		return min
	end

	local lowest, highest = math.huge, -math.huge
	for _, entry in RoundCardConfig.Cards do
		local price = tonumber(entry.Price) or 0

		lowest = math.min(lowest, price)
		highest = math.max(highest, price)
	end

	local price = tonumber(card.Price) or 0
	local span = highest - lowest

	if span <= 0 then
		return min
	end

	local scaled = min + ((price - lowest) / span) * (max - min)

	return math.clamp(math.floor(scaled + 0.5), min, max)
end

--[=[
	The number of the four-hour block `now` falls in.

	`now` is `os.time()` (UTC seconds), so the number is the same on every server at
	the same instant. It alone decides which stock is up.
]=]
function RoundCardShopConfig.rotationIndex(now : number?) : number
	local seconds = tonumber(now) or os.time()

	return math.floor(seconds / RoundCardShopConfig.ROTATION_SECONDS)
end

--- When the current block ends, in UTC seconds.
function RoundCardShopConfig.resetsAt(now : number?) : number
	local index = RoundCardShopConfig.rotationIndex(now)

	return (index + 1) * RoundCardShopConfig.ROTATION_SECONDS
end

--- How many seconds until the stock changes. Never negative.
function RoundCardShopConfig.secondsUntilReset(now : number?) : number
	local seconds = tonumber(now) or os.time()

	return math.max(RoundCardShopConfig.resetsAt(seconds) - seconds, 0)
end

--[=[
	The countdown as it goes into `ResetText`: `3:07:41`.

	Hours without a leading zero, minutes and seconds with two digits: what was
	authored in Studio (`RESETS IN: 4:00:00`), so the text width stays the same
	through the block.

	No days, because the rotation is four hours: the countdown never passes `3:59:59`.
]=]
function RoundCardShopConfig.formatCountdown(seconds : number?) : string
	local total = math.max(math.floor(tonumber(seconds) or 0), 0)

	local hours = total // 3600
	local minutes = (total % 3600) // 60

	return string.format("%d:%02d:%02d", hours, minutes, total % 60)
end

--[=[
	Draws a stock from a seed. The engine behind both: the global stock and the
	reroll's.

	The draw is `RoundCardConfig.Draw` (no repeats, weighted, the same as the round
	offer), only with a seeded `Random`. Hence reproducibility: same seed, same three
	cards, on any server at any time.

	The seed is folded into 2^31 because `Random.new` accepts any integer, but the
	products feeding it pass 2^53 at high indices, where floating point stops being
	exact and two servers could round the same math differently and draw different
	stocks.
]=]
local function drawStock(seed : number, pool : { any }?) : { { Id : string, Price : number } }
	local rng = Random.new(seed % 2147483647)

	local drawn = RoundCardConfig.Draw(RoundCardShopConfig.STOCK_COUNT, pool, rng)

	local stock = {}
	for _, card in drawn do
		table.insert(stock, {
			Id = card.Id,
			Price = RoundCardShopConfig.priceOf(card.Id),
		})
	end

	return stock
end

--[=[
	`userId`'s stock in block `index`: `STOCK_COUNT` cards, always the same for the
	same pair, and different from any other player's in the same block.

	Reproducible on purpose: it is what lets nothing be stored. Any server, at any
	point in the block, reaches the same three cards for that person, so leaving and
	returning (or landing in another Lobby) does not swap the offer under them.

	`pool` is the list of cards the shop may sell; without it, the whole catalog.
	**It must be the same between calls**: the catalog, not what the player still has
	to unlock. See the note on the pool at the top of the file.

	Returns `{ { Id, Price } }`, in the order the stock shows them.
]=]
function RoundCardShopConfig.stockFor(
	index : number,
	userId : number,
	pool : { any }?
) : { { Id : string, Price : number } }
	local seed = (tonumber(index) or 0) * RoundCardShopConfig.ROTATION_SEED
		+ (tonumber(userId) or 0) * RoundCardShopConfig.PLAYER_SEED

	return drawStock(seed, pool)
end

--[=[
	Draws a reroll's shelf: `locked` first, `unlocked` only to complete it.

	The three slots are filled with what the player **does not own yet**. If slots
	remain (fewer than three cards were missing), the rest come from cards they own,
	which arrive with the `SOLD` veil. That is `REROLL_EXCLUDES_UNLOCKED`'s best
	effort.

	The two pools are disjoint (`splitByUnlocked` guarantees it), so the two draws
	cannot repeat a card between them.

	No seed: the result is **saved** in the profile (see `createEmptyRoll`), so it
	need not be reproducible, only unpredictable.
]=]
function RoundCardShopConfig.drawReroll(locked : { any }, unlocked : { any }?) : { string }
	local ids = {}

	for _, card in RoundCardConfig.Draw(RoundCardShopConfig.STOCK_COUNT, locked) do
		table.insert(ids, card.Id)
	end

	local missing = RoundCardShopConfig.STOCK_COUNT - #ids
	if missing <= 0 or typeof(unlocked) ~= "table" then
		return ids
	end

	for _, card in RoundCardConfig.Draw(missing, unlocked) do
		table.insert(ids, card.Id)
	end

	return ids
end

--[=[
	Splits a pool in two by what this profile unlocked: `locked, unlocked`.

	The reroll uses it: it fills slots from `locked` and only completes from
	`unlocked` (see `drawReroll`). The two are disjoint and together make up the
	input pool, so nothing is lost or appears twice.

	With `REROLL_EXCLUDES_UNLOCKED` off, everything goes to `locked` and the reroll
	draws from the whole catalog without distinction.
]=]
function RoundCardShopConfig.splitByUnlocked(profile : any, pool : { any }) : ({ any }, { any })
	if not RoundCardShopConfig.REROLL_EXCLUDES_UNLOCKED then
		return pool, {}
	end

	local unlocked = RoundCardShopConfig.unlockedOf(profile)
	local locked, owned = {}, {}

	for _, card in pool do
		if unlocked[card.Id] then
			table.insert(owned, card)
		else
			table.insert(locked, card)
		end
	end

	return locked, owned
end

export type StockEntry = {
	Id : string,
	Price : number,
}

export type Stock = {
	-- The four-hour block this stock belongs to. The server checks it on purchase: a
	-- click from a stock that already turned buys nothing.
	Index : number,

	-- When it changes, in UTC seconds.
	ResetsAt : number,

	-- How many rerolls this player bought in this block. Zero is the block's drawn
	-- stock. The client compares `Index` **and** `Rolls` to know whether the shelf
	-- changed: a reroll does not change the block, and without this number the new
	-- cards would arrive without being drawn.
	--
	-- A stock can have fewer than `STOCK_COUNT` cards only when the catalog itself
	-- has fewer.
	Rolls : number,

	Cards : { StockEntry },
}

return RoundCardShopConfig
