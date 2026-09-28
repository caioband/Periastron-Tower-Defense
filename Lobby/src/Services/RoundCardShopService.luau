local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local RoundCardConfig = SharedConfig.RoundCardConfig
local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

local Framework = Me.new()
local log = Log.new("RoundCardShopService")

--[=[
	The Lobby card shop: it draws the storefront and charges for it.

	It sells **access** to round cards: a purchase writes the `Id` into the profile's
	`RoundCards`, and that table is what the match's round offer draws from (see
	`CardShopService`'s `_pool`). Rules and prices are in
	`SharedConfig.RoundCardShopConfig`; only the draw and the charge come from here.

	**The storefront belongs to each player, and comes from the time.** The three cards are
	recomputed from the current four-hour block plus the `UserId`
	(`RoundCardShopConfig.stockFor`), so a restart mid-block does not change anyone's offer
	and two players in the same Lobby see different cards. None of it is stored in a
	DataStore: the time and the owner already answer.

	The client decides nothing here. It asks for the storefront, draws it, and sends "I
	want card X", and this service checks that X is in the storefront **of the current
	time**, that the player does not have it yet, and that the shards are enough.

	**The reroll replaces that player's three cards.** The storefront is already
	per-player, so buying the developer product (`REROLL_PRODUCT_ID`) only changes where
	they come from: instead of the block draw, they come from the profile, until the block
	turns over. The three drawn cards are **saved** in the profile's `RoundCardRoll`, which
	is why they do not change when the player buys one of them; see the
	`createEmptyRoll` comment.

	See docs/lobby/round-card-shop.md.
]=]
local RoundCardShopService = {
	Services = {
		DataService = {},

		-- To register the reroll developer product. The `ProcessReceipt` over there calls
		-- the callback.
		MonetizationService = {},
	},

	Signals = {
		-- (Player, cardId : string, price : number, remaining : number) -- `remaining`
		-- is the shards balance after the charge.
		CardUnlocked = Signal.new(),

		-- (Player, rolls : number) -- the reroll was credited; `rolls` is its number
		-- within this four-hour block.
		Rerolled = Signal.new(),
	},
}

--[[ INTERNAL ]]

--- The player's open profile, or nil while it has not loaded.
function RoundCardShopService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[=[
	The cards the shop can sell: the catalog's, in the order it declares them.

	Order matters because the storefront draw is seeded: changing the order of entries in
	`RoundCardConfig` changes which three cards each four-hour block offers. That is not a
	problem (it is just what happens when the catalog changes), but it is why the pool is
	built once and cached instead of filtered per player: the base is the same for
	everyone.

	**No effect filter.** The Lobby does not have the `Effects` table (it belongs to
	`CardShopService`, in Game), so a card whose effect does not exist there could be sold
	here and never come up in the round draw. That is the same config error Game already
	warns about on startup, and that is where it must be fixed: silencing it here would
	only hide half the symptom.
]=]
function RoundCardShopService:_pool() : { any }
	if self.Pool then
		return self.Pool
	end

	local pool = {}
	for _, card in RoundCardConfig.Cards do
		table.insert(pool, card)
	end

	self.Pool = pool
	return pool
end

--[=[
	Refunds the shards charged for a purchase that could not be delivered.

	Its own write, not an `Update` of `Stats` back by hand in each call, because the charge
	and the refund must read the balance at the same instant they write: `Update` does not
	yield midway, and that is what keeps two simultaneous purchases from spending the same
	balance.
]=]
function RoundCardShopService:_refund(player : Player, amount : number)
	self.Services.DataService:Update(player, "Stats", function(stats)
		stats = stats or {}

		local currency = RoundCardShopConfig.CURRENCY
		stats[currency] = (stats[currency] or 0) + amount

		return stats
	end)
end

--[=[
	Sends the player **their** storefront (the global one, or the one they rerolled).

	It sends nothing while the profile has not loaded: `PlayerDataLoaded` pushes the
	storefront as soon as it arrives, and it is better for the shop to open empty for a
	second than to open with the wrong shelf and stay on it.
]=]
function RoundCardShopService:_sendStock(player : Player)
	local stock = self:GetStockFor(player)
	if not stock then
		return false
	end

	Framework:Fire("RoundCardStock", player, stock)
	return true
end

--[=[
	The two reroll pools for this profile: what is left to unlock, and what they already
	have.

	The draw fills the slots from the first and only tops up from the second: that is what
	separates the paid reroll from the block draw, which shows already unlocked cards with
	the `SOLD` veil without distinguishing anything. See `REROLL_EXCLUDES_UNLOCKED` and
	`drawReroll`.
]=]
function RoundCardShopService:_rerollPools(profile : any) : ({ any }, { any })
	return RoundCardShopConfig.splitByUnlocked(profile, self:_pool())
end

--[=[
	Turns the storefront over when the four-hour block ends.

	The loop sleeps until the next reset instead of checking every second: the switch
	instant is a computation (`secondsUntilReset`), not something to discover. The `+ 1`
	is slack so `os.time()` has already passed the limit when it wakes: waking on the exact
	second would leave `rotationIndex` still on the old block and the wait would repeat
	with zero wait.

	Players already in the Lobby receive the new storefront without asking: the shop may
	be open in front of them at switch time, and a panel still showing the old cards would
	sell what the shop no longer sells (the server would refuse, and the player would read
	that as a bug).
]=]
function RoundCardShopService:_watchRotation()
	task.spawn(function()
		while true do
			task.wait(RoundCardShopConfig.secondsUntilReset() + 1)

			local index = RoundCardShopConfig.rotationIndex()
			if self.Block and self.Block.Index == index then
				continue
			end

			self.Block = nil

			-- Players not loaded yet lose nothing: `PlayerDataLoaded` sends them the new
			-- storefront as soon as the profile arrives.
			for _, player in Players:GetPlayers() do
				self:_sendStock(player)
			end
		end
	end)
end

--[[ API ]]

--[=[
	The four-hour block the clock is in: `{ Index, ResetsAt }`.

	It is the only part of the shop that belongs to everyone. The cards are per player
	(see `GetStockFor`); what they share is the instant they all turn over.

	Cached per block, not per call: it is two divisions of `os.time()`, and the cache dies
	on its own when the index changes.
]=]
function RoundCardShopService:GetBlock()
	local index = RoundCardShopConfig.rotationIndex()

	if self.Block and self.Block.Index == index then
		return self.Block
	end

	self.Block = {
		Index = index,
		ResetsAt = RoundCardShopConfig.resetsAt(),
	}

	return self.Block
end

--[=[
	**This** player's storefront: the global one, or the one they rerolled this block.

	Both answers are built on the spot, and neither is cached. Building is cheap (a seeded
	draw of three cards, or reading three `Id`s' prices) and there is nothing to
	invalidate: what could change between two calls (what the player unlocked) is on
	purpose **not** part of either computation.
]=]
function RoundCardShopService:GetStockFor(player : Player)
	local block = self:GetBlock()

	local profile = self:_profileOf(player)

	--[[
		**No profile, no answer.** A profile still loading is not "this player did not
		reroll": it is "cannot tell yet". The storefront depends on the `UserId` **and** the
		saved reroll, so answering without a profile guesses both.

		The client asks for the storefront when `ShopUI` builds, which happens before
		`StartSessionAsync` returns. Answering with the global one there would stick: the
		client would store it, nothing would correct it, and the paid shelf would only come
		back on the next reroll. Callers handle nil by waiting for the profile; see
		`RequestRoundCardStock` and `PlayerDataLoaded` in `construct`.
	]]
	if not profile then
		return nil
	end

	local rolls = RoundCardShopConfig.rollsOf(profile, block.Index)

	--[[
		Without a reroll, the storefront is the block draw for **this** player: recomputed,
		not stored. It is stable because the pool is the whole catalog: buying a card does
		not remove it from the draw, it only gets the `SOLD` veil.
	]]
	if rolls <= 0 then
		return {
			Index = block.Index,
			ResetsAt = block.ResetsAt,
			Rolls = 0,
			Cards = RoundCardShopConfig.stockFor(block.Index, player.UserId, self:_pool()),
		}
	end

	--[[
		The cards come from the profile, not from a draw redone now.

		That is what keeps the paid shelf still while the player buys from it: the draw only
		sweeps what is left to unlock, so redoing it after a purchase would fill the sold slot
		with a new card instead of leaving it `SOLD`.
	]]
	local cards = RoundCardShopConfig.entriesFor(
		RoundCardShopConfig.rolledCardsOf(profile, block.Index)
	)

	-- An empty saved shelf (a profile from before it was saved, or cards that
	-- left the catalog) counts as not having rerolled: the block draw is the state
	-- the screen always knows how to draw.
	if #cards == 0 then
		return {
			Index = block.Index,
			ResetsAt = block.ResetsAt,
			Rolls = 0,
			Cards = RoundCardShopConfig.stockFor(block.Index, player.UserId, self:_pool()),
		}
	end

	return {
		Index = block.Index,
		ResetsAt = block.ResetsAt,
		Rolls = rolls,
		Cards = cards,
	}
end

--[=[
	Unlocks a storefront card for the player: charges the shards and writes the `Id` into
	the profile's `RoundCards`.

	Returns true, or false plus the reason ("NotLoaded", "NotInStock", "AlreadyOwned",
	"NotEnoughCurrency", "GrantFailed"). None is a program error: they are the ways the
	request can be stale or repeated: the double click, the storefront that turned over
	between drawing and clicking, the event sent by hand.

	The check and the charge happen inside a single `:Update`, which does not yield: two
	clicks in a row cannot spend the same balance. And **ownership** is checked again inside
	the `RoundCards` write, not only before the charge: without that, two clicks on the same
	frame would charge twice for the same card.
]=]
function RoundCardShopService:Purchase(player : Player, cardId : any) : (boolean, string?)
	local DataService = self.Services.DataService
	local profile = self:_profileOf(player)

	if not DataService or not DataService.Update or not profile then
		log:StudioWarn(string.format("%s has no profile loaded; purchase ignored.", player.Name))
		return false, "NotLoaded"
	end

	--[[
		The price comes from **this player's storefront**, not `priceOf` directly: it says
		what is for sale to them now, and charging for any `Id` would sell the whole catalog
		to whoever sent the event by hand.

		`GetStockFor`, not `GetStock`: a player who rerolled is looking at another shelf,
		and checking against the global one would refuse exactly the cards they paid to see.
	]]
	local stock = self:GetStockFor(player)

	-- The `profile` above already guarantees it is not nil; the guard is because `GetStockFor`
	-- can return nil, and a deref here would take down the whole purchase.
	if not stock then
		return false, "NotLoaded"
	end

	local price = nil

	for _, entry in stock.Cards do
		if entry.Id == cardId then
			price = entry.Price
			break
		end
	end

	if not price then
		log:StudioWarn(string.format("%s asked for %q, which is not in their stock right now.",
			player.Name, tostring(cardId)))
		return false, "NotInStock"
	end

	if RoundCardShopConfig.isUnlocked(profile, cardId) then
		return false, "AlreadyOwned"
	end

	local charged = false
	local remaining = 0

	DataService:Update(player, "Stats", function(stats)
		stats = stats or {}

		local currency = RoundCardShopConfig.CURRENCY
		local owned = stats[currency] or 0

		if owned < price then
			return stats
		end

		remaining = owned - price
		stats[currency] = remaining
		charged = true

		return stats
	end)

	if not charged then
		return false, "NotEnoughCurrency"
	end

	local granted = false

	DataService:Update(player, "RoundCards", function(unlocked)
		unlocked = typeof(unlocked) == "table" and unlocked or {}

		if unlocked[cardId] then
			return unlocked
		end

		unlocked[cardId] = true
		granted = true

		return unlocked
	end)

	if not granted then
		-- The card was already unlocked when the write arrived: two clicks on the same
		-- frame. The second refunds what it charged.
		self:_refund(player, price)
		return false, "GrantFailed"
	end

	self.Signals.CardUnlocked:Fire(player, cardId, price, remaining)
	return true
end

--[=[
	Credits a reroll: increments the current block's counter and sends the new shelf.

	Returns `false` when it could not write to the profile, and that is why the return
	matters: `ProcessReceipt` calls it, and `false` makes the receipt come back as
	`NotProcessedYet`. Roblox then retries later, instead of counting the purchase as
	delivered without it having happened. The player was already charged; what must not
	happen is the money vanishing without a shelf.

	**It charges nothing and checks no price**: Roblox charged. This is only the delivery.

	The record resets on its own when the block turns over, through `Index`: `Update`
	rewrites the fields when what was there belongs to an earlier block, so today's paid
	shelf does not survive tomorrow's rotation.
]=]
function RoundCardShopService:Reroll(player : Player) : boolean
	local DataService = self.Services.DataService

	if not DataService or not DataService.Update or not self:_profileOf(player) then
		log:Warn(string.format("%s has no profile loaded; the reroll was not credited.", player.Name))
		return false
	end

	local index = RoundCardShopConfig.rotationIndex()

	--[[
		The draw happens **before** `Update`, not inside it: the `Update` callback must not
		yield, and drawing inside it would only hide the work in a place where it cannot
		grow.

		The pool is read from the current profile: the cards they do not have yet. From then
		on the result is saved and no longer recomputed.
	]]
	local locked, owned = self:_rerollPools(self:_profileOf(player))
	local cards = RoundCardShopConfig.drawReroll(locked, owned)

	if #cards == 0 then
		log:Warn(string.format("%s rerolled with no card left to draw.", player.Name))
		return false
	end

	local rolls = 0

	DataService:Update(player, "RoundCardRoll", function(roll)
		roll = typeof(roll) == "table" and roll or RoundCardShopConfig.createEmptyRoll()

		if roll.Index ~= index then
			roll.Index = index
			roll.Rolls = 0
		end

		rolls = math.max(math.floor(tonumber(roll.Rolls) or 0), 0) + 1

		roll.Rolls = rolls
		roll.Cards = cards

		return roll
	end)

	if rolls <= 0 then
		return false
	end

	self:_sendStock(player)
	self.Signals.Rerolled:Fire(player, rolls)

	return true
end

--[[ LIFECYCLE ]]

function RoundCardShopService:construct()
	--[[
		The client asks for the storefront when it hooks up the shop, instead of the server
		sending it on join: `ShopUI` is `ResetOnSpawn`, so the panel is rebuilt on every
		respawn, and a single send on join would be lost at the first death. The request also
		covers a player who joined before this service started.
	]]
	--[[
		The request **waits for the profile**. `DataService:Get` answers when it is loaded
		(and does not block this handler: it schedules), so a request that arrived too early
		is answered late instead of answered wrong.
	]]
	Framework:Listen("RequestRoundCardStock", function(player : Player)
		local dataService = self.Services.DataService

		if not dataService then
			return
		end

		dataService:Get(player, function()
			self:_sendStock(player)
		end)
	end)

	--[[
		And the storefront also goes out on its own when the profile arrives, without anyone
		asking.

		They are two sides of the same race: the `Get` above covers the request that arrived
		before the profile, and this covers a request lost entirely (the client may have
		hooked up the shop before this service registered its `Listen`, and its retry has a
		cap).
	]]
	local dataService = self.Services.DataService

	if dataService and dataService.Signals and dataService.Signals.PlayerDataLoaded then
		dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
			self:_sendStock(player)
		end)

		-- Players already in when this service started: their signal already fired.
		for _, player in Players:GetPlayers() do
			self:_sendStock(player)
		end
	else
		log:Warn("no PlayerDataLoaded; the stock is only sent when the client asks for it.")
	end

	Framework:Listen("RequestBuyRoundCard", function(player : Player, cardId : any)
		local success, reason = self:Purchase(player, cardId)

		Framework:Fire("RoundCardPurchaseResult", player, cardId, success, reason)
	end)

	--[[
		The reroll is sold by Roblox, not by this service: the client opens the developer
		product prompt and what arrives here is the **receipt**, through
		`MonetizationService`'s `ProcessReceipt`.

		There is no "I want to reroll" event on purpose. A client request could only open the
		prompt (which the client already opens on its own) or credit without payment, and the
		only proof there was a payment is the receipt.

		`MonetizationService` handles the rest of the contract: it does not credit the same
		`PurchaseId` twice (`PurchaseHistory`) and only confirms the purchase after the
		profile is saved to disk.
	]]
	local monetization = self.Services.MonetizationService

	if monetization then
		monetization:RegisterProduct(RoundCardShopConfig.REROLL_PRODUCT_ID, function(player : Player)
			return self:Reroll(player)
		end)
	else
		log:Warn("no MonetizationService; card shop rerolls will not be credited.")
	end

	self:_watchRotation()
end

function RoundCardShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function RoundCardShopService:init()
	-- The client connects to both during its `init`, but the server would only create the
	-- event the first time it fired it, and Warp complains that it "is taking
	-- too long to retrieve". Declared here like the other server events.
	Framework:Listen("RoundCardStock", function() end)
	Framework:Listen("RoundCardPurchaseResult", function() end)

	-- The current four-hour block, `{ Index, ResetsAt }`. The cards do not live here:
	-- they belong to each player (see `GetStockFor`).
	self.Block = nil

	-- The catalog for sale, built once. See `_pool`.
	self.Pool = nil
end

return RoundCardShopService
