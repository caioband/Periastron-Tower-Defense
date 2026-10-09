local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Signal = require(Packages.Signal)

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local MarkerUtil = require(Util.MarkerUtil)
local ProximityPanel = require(Util.ProximityPanel)
local UIUtil = require(Util.UIUtil)

local RoundCardConfig = SharedConfig.RoundCardConfig
local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

local Framework = Me.new()
local log = Log.new("RoundCardShopController")

local GUI = RoundCardShopConfig.Gui
local ANIM = RoundCardConfig.Animation

--[[ CONSTANTS ]]

local CHARACTER_ROOT = "HumanoidRootPart"

-- How many times the storefront is requested from the server before giving up, and how
-- often. See `_requestStock`.
local STOCK_REQUEST_ATTEMPTS = 5
local STOCK_REQUEST_INTERVAL = 2

--[=[
	The name of the `InterfaceController` request: while the shop is open, the screen is
	its alone.

	A named request, not a global switch: the crate shop, the cutscene, and the maps panel
	ask for the same thing, and a GUI only comes back when the **last** request leaves.
	Its own name, not the crate shop's `"Shop"`: the two are never open together, but
	sharing the name would let one give back the screen the other asked for.
]=]
local HIDE_REASON = "CardShop"

--[=[
	The purchase sound: the same `Shards` as the crate shop, in `SoundService.BuySFX`.

	It plays on the server's **result**, not the click: price and wallet are checked there,
	and a click without balance bought nothing.

	The `Key` is its own, not the crate shop's: the two never play at the same time, and a
	shared `Key` would let one cut the other's sound for no reason.
]=]
local BUY_SOUND = "Shards"
local BUY_SOUND_KEY = "RoundCardShopBuy"

-- How often `ResetText` is rewritten. One second because the countdown is in
-- seconds: rewriting faster would write the same text.
local COUNTDOWN_INTERVAL = 1

--[=[
	The HUD button that takes the player to the storefront.

	It lives in its own `Wrapper` inside `HUDFrame`, next to `Shop` (which does the same for
	the crate shop), which is why it is looked up **by depth**: the HUD changes shape over
	time, and a button inside a wrapper today may be loose in the frame tomorrow.

	The name does not collide with the neighbor's `Shop`: `FindFirstChild` matches the
	whole name, not part of it. And `RoundCardConfig.Gui`'s `CardShop` (the edge-of-screen
	button, in Game) is another `ScreenGui` in another place: the lookup here starts at the
	Lobby's `HUDFrame` and never reaches it.

	**Its grow and sink are not handled here.** `HUDButtonController` handles them, hooking
	up every `GuiButton` under `HUDFrame`: the new button joins the others' animation
	without a line of code. Only the click comes from here.
]=]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDFrame"
local HUD_BUTTON_NAME = "CardShop"

--[=[
	The Lobby card shop: `StarterGui.ShopUI.RCSS`.

	It sells **access** to round cards. A card bought here goes into no hand: it enters
	the profile's `RoundCards` and becomes eligible for the round offer draw inside the
	match. That is why a card this player already unlocked shows the `SOLD` veil instead of
	leaving the storefront: each player's storefront is three cards per four-hour block,
	and what the veil tracks is what they already own.

	**This controller draws nothing.** The three cards arrive from `RoundCardShopService`
	already drawn and priced, it draws them, and the click sends "I want card X". The
	server checks that X is in the current storefront, that the player does not own it,
	and that the shards are enough.

	**The reroll is not credited here either.** The die (`RerollDice`) opens the developer
	product prompt and stops there: the server's `ProcessReceipt` credits it, and what
	comes back is the new shelf through `RoundCardStock`, which this controller draws as
	it would draw a rotation. Canceling the prompt produces nothing, which is right.

	Each card is a clone of the authored `CardWrapper`, and the card inside the wrapper is
	what animates: it drops from above with its image appearing and, when that ends, the
	content (title, description, price, outlines) goes from transparent to the authored
	value. The wrapper exists precisely for that: it occupies the slot in the
	`UIListLayout`, so the card moves freely without the layout dragging it back every
	frame. The timings are the round shop's (`RoundCardConfig.Animation`), because it is
	the same card entering the screen with the same gesture.

	Walking within `RoundCardShopConfig.OPEN_RADIUS` of the marker opens it, and leaving
	closes it. The HUD's `CardShop` button takes the player there (`TeleportToShop`), the
	same way the `Shop` next to it goes to the crate shop. `Open`/`Close`/`Toggle` are
	public, so anything else (a Cmdr command, for example) moves the same panel.

	**`ShopUI` is shared with the crate shop and the Robux shop.** The three are siblings
	inside it, and none controls `Enabled` alone: each one's wrapper `Visible` says which
	panel is on screen. The panel (frame, animation, blur, proximity) belongs to
	`ProximityPanel`; see `CanDisable` in `construct`.

	See docs/lobby/round-card-shop.md.
]=]
local RoundCardShopController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},

		-- The other shops in the same `ScreenGui`. Only to know whether any is open
		-- before disabling the ScreenGui of all three; see `CanDisable` in `construct`.
		ShopController = {},
		RobuxShopController = {},
		RuneShopController = {},

		-- The HUD button's `New` badge: the storefront opening clears it. See
		-- `BeforeOpen` in `construct`.
		HUDBadgeController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),

		-- (cardId : string) -- fired along with `RequestBuyRoundCard`, so anything
		-- client side can react to the click.
		PurchaseRequested = Signal.new(),

		-- () -- the reroll prompt was opened. It does not mean it was paid: the new shelf
		-- arriving through `RoundCardStock` confirms that.
		RerollRequested = Signal.new(),

		-- (cardId : string, success : boolean, reason : string?) -- what
		-- `RoundCardShopService` decided. `reason` is one of NotLoaded, NotInStock,
		-- AlreadyOwned, NotEnoughCurrency, GrantFailed.
		PurchaseResult = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	The cards this player already unlocked, read from their own replica.

	It comes from the replica and not the server on purpose: the profile's `RoundCards` is
	already replicated to its owner, and sending the list with the storefront would give
	the client a second version of something it already has, which would go stale at the
	first purchase.
]=]
function RoundCardShopController:_unlocked() : { [string] : boolean }
	local replica = self.Replica

	return RoundCardShopConfig.unlockedOf(replica and replica.Data or nil)
end

--[=[
	A card's template: the authored `CardWrapper` leaves the row and comes back cloned, one
	per storefront card.

	It is cloned **and** destroyed because the authored one is the `UIListLayout`'s first
	slot: leaving it there would give a fourth idle card, with the sample text the designer
	wrote.
]=]
function RoundCardShopController:_template() : Frame?
	if self.Template then
		return self.Template
	end

	local authored = self.Row and self.Row:FindFirstChild(GUI.Wrapper_Card)
	if not authored then
		log:StudioWarn(`could not find the authored {GUI.Wrapper_Card} in {GUI.Row}.`)
		return nil
	end

	self.Template = authored:Clone()
	authored:Destroy()

	return self.Template
end

--[=[
	Writes what changes on a card: title, description, art, and price.

	A card without its own art keeps the template's authored art: a card with the wrong art
	beats an invisible card. The shard icon and the price outline color are already
	authored on the button, because this shop charges in a single currency.
]=]
function RoundCardShopController:_writeCard(card : GuiObject, definition, price : number)
	local title = card:FindFirstChild(GUI.Title)
	if title and title:IsA("TextLabel") then
		title.Text = definition.Title or definition.Id
	end

	local description = card:FindFirstChild(GUI.Description)
	if description and description:IsA("TextLabel") then
		description.Text = definition.Description or ""
	end

	local buy = card:FindFirstChild(GUI.Buy)
	local label = buy and buy:FindFirstChild(GUI.BuyLabel)

	if label and label:IsA("TextLabel") then
		label.Text = string.format(RoundCardShopConfig.PRICE_FORMAT, UIUtil.formatCommas(price))
	end

	if definition.Image and (card:IsA("ImageLabel") or card:IsA("ImageButton")) then
		card.Image = definition.Image
	end
end

--[=[
	Turns a card's `SOLD` veil on or off, and enables or disables its button.

	Called on draw and on every `RoundCards` change in the replica. **It does not redraw the
	card**: buying with the shop open only lights the veil, and rebuilding the row would
	make all three cards drop again in front of someone who just clicked one.
]=]
function RoundCardShopController:_applySold(entry)
	local sold = self:_unlocked()[entry.Id] == true

	entry.Sold = sold

	if entry.Veil and entry.Veil:IsA("GuiObject") then
		entry.Veil.Visible = sold
	end

	--[[
		Title and description disappear under the veil.

		The veil is a darkening with `SOLD` written on top, and the card text would cross
		both: the description would overlap `SOLD` and the panel would become a smear of
		letters. An already unlocked card does not need to explain itself: the player
		already knows what it is, and what matters there is that it is not for sale.

		It is `Visible`, not transparency: the card reveal (`UIUtil.applyFades`) writes to
		these same labels' transparencies, and the two would fight over the same property.
		`Visible` hides from outside and lets the animation run underneath without knowing.

		Written **both** ways because the clone is born with the texts on: without
		`not sold`, a card that stopped being sold (a new `_render` reusing the template)
		would stay mute.
	]]
	if entry.Title and entry.Title:IsA("GuiObject") then
		entry.Title.Visible = not sold
	end

	if entry.Description and entry.Description:IsA("GuiObject") then
		entry.Description.Visible = not sold
	end

	--[[
		The button dimmed, not hidden: an unlocked card still shows the price it cost. The
		click does nothing anyway (the server refuses with `AlreadyOwned`), and `Active` is
		what keeps the player from finding that out by clicking.
	]]
	local button = entry.Button
	if button and button:IsA("GuiButton") then
		button.Active = not sold
		button.AutoButtonColor = not sold
	end
end

--- Runs the `SOLD` veil over every card on screen.
function RoundCardShopController:_refreshSold()
	for _, entry in self.CardEntries do
		self:_applySold(entry)
	end

	self:_refreshReroll()
end

--[=[
	Enables or disables the reroll die.

	It only makes sense while there are cards left to unlock: the paid reroll draws from
	what is **missing** (see `REROLL_EXCLUDES_UNLOCKED`), so for someone who owns the whole
	catalog it would have nothing to offer. Leaving it clickable there would sell Robux for
	nothing, and Roblox has already charged when the receipt arrives, so the time to stop
	it is before the prompt.

	It runs along with the `SOLD` veil because both answer the same question: what this
	player already unlocked. The catalog's last purchase dims the button the same instant
	it lights the last `SOLD`.
]=]
function RoundCardShopController:_refreshReroll()
	local button = self.RerollButton
	if not button or not button.Parent then
		return
	end

	local unlocked = self:_unlocked()
	local remaining = 0

	for _, card in RoundCardConfig.Cards do
		if not unlocked[card.Id] then
			remaining += 1
		end
	end

	local available = remaining > 0

	button.Active = available
	button.AutoButtonColor = available
end

--[=[
	Opens the reroll developer product prompt.

	The client **opens** the purchase, and does not credit it: the server's
	`ProcessReceipt` credits it, and what comes back is the new shelf through
	`RoundCardStock`. There is no answer to wait for here: if the player cancels, nothing
	happens, which is exactly right.

	No debounce: `PromptProductPurchase` does not stack windows, and clicking again with
	the window open does nothing. A debounce would only create a state to unlock when the
	player closed the prompt from outside.
]=]
function RoundCardShopController:_promptReroll()
	local button = self.RerollButton

	-- Disabled means there is no card to draw (see `_refreshReroll`). `Active = false`
	-- already swallows the click; this is the safety net for callers invoking it by hand.
	if button and not button.Active then
		return
	end

	self.Signals.RerollRequested:Fire()

	MarketplaceService:PromptProductPurchase(
		Players.LocalPlayer,
		RoundCardShopConfig.REROLL_PRODUCT_ID
	)
end

--[=[
	Draws the storefront's three cards.

	Each card has two halves, in this order: it **drops** from `DropOffset` heights above
	its place while its image fades in (`CardDrop`), and only when that ends does the
	content (title, description, price, outlines, shadow) go from 1 to the authored value
	(`CardReveal`). Revealing everything together would make the text float before the
	card exists behind it.

	The three do not go out together: the second starts `CardStagger` after the first. The
	delay is a `task.delay` kept in the row's maid, so closing the shop midway cancels
	whatever has not started.
]=]
function RoundCardShopController:_render()
	local row = self.Row
	local stock = self.Stock

	if not row or not stock then
		return
	end

	local template = self:_template()
	if not template then
		return
	end

	self.CardEntries = {}
	self.RowMaid:DoCleaning()

	for index, offer in stock.Cards do
		local definition = RoundCardConfig.Get(offer.Id)
		if not definition then
			log:StudioWarn(`the stock brought card '{tostring(offer.Id)}', which is not in the config.`)
			continue
		end

		local wrapper = template:Clone()
		wrapper.Name = offer.Id
		wrapper.LayoutOrder = index

		local card = wrapper:FindFirstChild(GUI.Card)
		if not card or not card:IsA("GuiObject") then
			log:StudioWarn(`the template has no {GUI.Card} inside {GUI.Wrapper_Card}.`)
			wrapper:Destroy()
			continue
		end

		self:_writeCard(card, definition, offer.Price)

		local entry = {
			Id = offer.Id,
			Price = offer.Price,
			Wrapper = wrapper,
			Card = card,
			Veil = card:FindFirstChild(GUI.Sold),
			Button = card:FindFirstChild(GUI.Buy),

			-- Both texts hide under the `SOLD` veil. Kept in the entry because
			-- `_applySold` runs again on every purchase, and looking them up every time would be
			-- a lookup by name per card per replica write.
			Title = card:FindFirstChild(GUI.Title),
			Description = card:FindFirstChild(GUI.Description),

			Ready = false,
		}

		--[[
			The veil goes on **before** `captureFades`: it is the only piece whose state
			depends on the player, and capturing with it off would store `SOLD` as something
			the reveal has to light.
		]]
		self:_applySold(entry)

		-- Read from the untouched clone: this is where the reveal takes everything back. It must
		-- come before any transparency write.
		local fades = UIUtil.captureFades(card)
		local basePosition = card.Position

		entry.Fades = fades
		entry.BasePosition = basePosition

		table.insert(self.CardEntries, entry)

		-- Starting state: the card above its place, the image and content
		-- transparent.
		card.Position = UDim2.new(
			basePosition.X.Scale, basePosition.X.Offset,
			basePosition.Y.Scale - ANIM.DropOffset, basePosition.Y.Offset
		)

		if card:IsA("ImageLabel") or card:IsA("ImageButton") then
			card.ImageTransparency = 1
		end

		UIUtil.applyFades(fades, 0)

		wrapper.Parent = row
		self.RowMaid:GiveTask(wrapper)

		local button = entry.Button

		if button and button:IsA("GuiButton") then
			self.RowMaid:GiveTask(button.Activated:Connect(function()
				--[[
					The card only accepts clicks after it starts falling. It exists on screen
					from `Parent` on, transparent and out of place, and without this the third
					card (which only comes in a second later) could be bought while there is
					nothing for the player to see.
				]]
				if not entry.Ready or entry.Sold then
					return
				end

				self:_requestPurchase(offer.Id)
			end))

			ButtonUtil.bindFeedback(button, self.RowMaid)
		end

		local delayed = task.delay((index - 1) * ANIM.CardStagger, function()
			if not wrapper.Parent then
				return
			end

			entry.Ready = true

			local dropInfo = TweenInfo.new(ANIM.CardDrop, ANIM.CardEasing, ANIM.CardDirection)
			local goal : { [string] : any } = { Position = basePosition }

			if card:IsA("ImageLabel") or card:IsA("ImageButton") then
				goal.ImageTransparency = 0
			end

			local drop = TweenService:Create(card, dropInfo, goal)

			drop.Completed:Connect(function(state : Enum.PlaybackState)
				if state ~= Enum.PlaybackState.Completed or not wrapper.Parent then
					return
				end

				UIUtil.applyFades(fades, 1, TweenInfo.new(ANIM.CardReveal, ANIM.CardEasing, ANIM.CardDirection))
			end)

			drop:Play()

			self.RowMaid:GiveTask(function()
				drop:Cancel()
			end)
		end)

		self.RowMaid:GiveTask(function()
			pcall(task.cancel, delayed)
		end)
	end
end

--[=[
	Writes how long until the storefront changes.

	The math is against the `ResetsAt` the **server** sent, not the local clock: both are
	UTC seconds, but only the server's agrees with the block the storefront was drawn in.

	Reaching zero asks for the new storefront. The server also pushes it on its own at the
	switch (see its `_watchRotation`), and having both is on purpose: the push covers
	players with the shop open, and this request covers the clock difference between the
	two ends: without it, a client half a minute ahead would sit at `0:00:00` waiting for
	an event that, for it, should already have arrived.
]=]
function RoundCardShopController:_updateCountdown()
	local label = self.ResetLabel
	if not label or not label.Parent then
		return
	end

	local stock = self.Stock
	if not stock then
		return
	end

	local remaining = math.max((stock.ResetsAt or 0) - os.time(), 0)

	label.Text = string.format(
		RoundCardShopConfig.RESET_FORMAT,
		RoundCardShopConfig.formatCountdown(remaining)
	)

	if remaining <= 0 then
		self:_requestStock(true)
	end
end

--[=[
	Asks the server for the storefront, and insists until it arrives.

	The insisting exists because **the event identifier is created on the server** (see
	docs/architecture/me-framework.md): the client may hook up the shop before
	`RoundCardShopService` registered its `RequestRoundCardStock` `Listen`, and a request
	made in that window is lost. Without retrying, the shop would have no cards for the
	rest of the session because of half a second of boot order.

	`renew` is the request from a countdown that reached zero, not the boot one: it goes
	through even with a storefront in hand, because what it wants is the **next** one. It
	exists for the client clock running ahead of the server's: the server pushes the new
	storefront on its own at the switch (see its `_watchRotation`), and without this
	request a client half a minute ahead would sit at `0:00:00` waiting for an event that,
	for it, should already have arrived.

	The loop gives up after `STOCK_REQUEST_ATTEMPTS` and **releases the mark**: this
	attempt gave up, not the shop. A storefront still expired tries again the next second,
	and the warning only goes out in the boot case: on renewal it would come every ten
	seconds and bury the output.
]=]
function RoundCardShopController:_requestStock(renew : boolean?)
	if self.StockRequested then
		return
	end

	if self.Stock and not renew then
		return
	end

	self.StockRequested = true

	task.spawn(function()
		-- The storefront already in hand. One arriving with another index is what ends the
		-- loop: at boot it is nil, and any answer will do.
		local before = self.Stock and self.Stock.Index or nil

		for _ = 1, STOCK_REQUEST_ATTEMPTS do
			if (self.Stock and self.Stock.Index or nil) ~= before then
				return
			end

			Framework:Fire("RequestRoundCardStock")
			task.wait(STOCK_REQUEST_INTERVAL)
		end

		self.StockRequested = false

		if not self.Stock then
			log:StudioWarn("no stock came from the server; the card shop stays empty.")
		end
	end)
end

function RoundCardShopController:_requestPurchase(cardId : string)
	self.Signals.PurchaseRequested:Fire(cardId)

	-- The server checks the storefront and the wallet and writes to the profile: the client
	-- only asks.
	Framework:Fire("RequestBuyRoundCard", cardId)
end

--[=[
	Follows the replica: the `SOLD` veil tracks the profile's `RoundCards`.

	Listened to through the whole `OnChange`, not only the key: the purchase writes
	`RoundCards`, and any deeper write in there must also relight the veil.
]=]
function RoundCardShopController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_refreshSold()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]

			if key ~= nil and key ~= "RoundCards" then
				return
			end

			self:_refreshSold()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	One of the shop's markers in the map, kept until it leaves the world. See `MarkerUtil`:
	the lookup is recursive inside the map, because both markers live inside the house
	model, not loose at its root.
]=]
function RoundCardShopController:_getMapPart(partName : string) : Instance?
	return MarkerUtil.find(
		RoundCardShopConfig.REFERENCE_PARENT_NAME,
		partName,
		self.MapParts,
		self.WarnedMissing,
		"RoundCardShopController"
	)
end

--- Where the shop is, for anyone who needs to measure against the same center as proximity.
function RoundCardShopController:GetReferencePosition() : Vector3?
	local pivot = MarkerUtil.pivotOf(self:_getMapPart(RoundCardShopConfig.REFERENCE_PART_NAME))

	return pivot and pivot.Position or nil
end

--- The `ResetText` countdown, rewritten every second while the client lives.
function RoundCardShopController:_watchCountdown()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.CountdownClock += deltaTime

		if self.CountdownClock < COUNTDOWN_INTERVAL then
			return
		end

		self.CountdownClock = 0
		self:_updateCountdown()
	end))
end

--[=[
	The shop's content on a new copy of `ShopUI`. The panel itself (the frame, `OpenShop`,
	the X, the blur, and the screen request) belongs to `ProximityPanel`, which calls this at
	the end of its bind. `ShopUI` is `ResetOnSpawn`, so this runs again on every respawn.
	`maid` is the bind's: cleared on the next copy.
]=]
function RoundCardShopController:_onBind(panel : GuiObject, maid : any)
	local row = panel:WaitForChild(GUI.Row, 10)

	if not row then
		log:StudioWarn(`could not find {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.Row}.`)
		return
	end

	self.RowMaid:DoCleaning()

	self.Row = row

	--[[
		The template is per `ShopUI` copy: the previous one was destroyed with its ScreenGui,
		and keeping the old clone would put orphaned cards in the new row.
	]]
	self.Template = nil
	self.CardEntries = {}

	--[[
		A **direct** child of the panel, not by depth: the countdown has a fixed spot in the
		art, and the reroll button carries its own caption inside it. A recursive lookup
		would choose between labels by tree order, and the countdown could end up written
		over another piece's caption. See the `Gui.ResetText` comment.
	]]
	self.ResetLabel = panel:FindFirstChild(GUI.ResetText)

	if not self.ResetLabel or not self.ResetLabel:IsA("TextLabel") then
		self.ResetLabel = nil
		log:StudioWarn(`could not find {GUI.ResetText} as a child of {GUI.Panel}; the shop opens without the countdown.`)
	end

	--[[
		The reroll die. Its `UIScale` was authored for this, and `ButtonUtil` animates it:
		the same weight as the cards' `Buy` button and the crate shop's.

		It goes in the bind's maid because it is part of the panel: `ShopUI` is
		`ResetOnSpawn`, and the new copy brings a new button.
	]]
	local reroll = panel:FindFirstChild(GUI.Reroll)

	if reroll and reroll:IsA("GuiButton") then
		self.RerollButton = reroll

		maid:GiveTask(reroll.Activated:Connect(function()
			self:_promptReroll()
		end))

		ButtonUtil.bindFeedback(reroll, maid)
	else
		self.RerollButton = nil
		log:StudioWarn(`could not find {GUI.Reroll} in {GUI.Panel}; the shop opens without the reroll.`)
	end

	self:_render()
	self:_refreshReroll()
	self:_updateCountdown()
	self:_requestStock()
end

--[=[
	Hooks up the HUD button that takes the player to the storefront.

	Its own maid: `HUD` and `ShopUI` are different `ScreenGui`s and the engine rebuilds
	them at different times, so one's bind must not disconnect the other's.
]=]
function RoundCardShopController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, 10)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, HUD_BUTTON_NAME, 10)

	if not button or not button:IsA("GuiButton") then
		log:StudioWarn(`could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:TeleportToShop()
	end))
end

--- The HUD, through the button that goes to the storefront. `ProximityPanel` follows `ShopUI`.
function RoundCardShopController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

function RoundCardShopController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

--- The current storefront as the client knows it, or nil until it arrives.
function RoundCardShopController:GetStock()
	return self.Stock
end

function RoundCardShopController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function RoundCardShopController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

--[=[
	Drops the player on the landing marker next to the shop.

	The landing is 18.8 studs from the reference, that is, **outside** `OPEN_RADIUS` (which
	is 5, the counter). So the teleport opens the shop by hand, through `EnterRange`, which
	marks the entry too, or the exit crossing would never happen and the shop opened by the
	teleport would stay stuck on screen however far they walked.

	The HUD's `CardShop` button calls it (see `_bindHud`), the same way the `Shop` next to
	it calls the crate shop's teleport.
]=]
function RoundCardShopController:TeleportToShop() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)

	if not root then
		return false
	end

	local part = self:_getMapPart(RoundCardShopConfig.TELEPORT_PART_NAME)
	local pivot = MarkerUtil.pivotOf(part)

	if not pivot then
		return false
	end

	local halfHeight = MarkerUtil.halfHeightOf(part)

	character:PivotTo(pivot * CFrame.new(0, halfHeight + RoundCardShopConfig.TELEPORT_HEIGHT_OFFSET, 0))

	-- Without this the player keeps the velocity they had and slides off the
	-- marker.
	root.AssemblyLinearVelocity = Vector3.zero

	if self.Proximity then
		self.Proximity:EnterRange()
	end

	return true
end

function RoundCardShopController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function RoundCardShopController:construct()
	--[[
		The storefront is listened to before the UI is observed on purpose: the answer may
		arrive before the first bind finishes, and `_render` draws from scratch: arriving
		too early only means the shop opens with the cards ready.
	]]
	Framework:Listen("RoundCardStock", function(stock)
		if typeof(stock) ~= "table" or typeof(stock.Cards) ~= "table" then
			return
		end

		--[[
			`Index` **and** `Rolls`: rotation changes the block, and the reroll changes the
			shelf within the same block. Comparing only the index, the paid cards would arrive
			and not be drawn, which is exactly what the player just bought.
		]]
		local rotated = self.Stock == nil
			or self.Stock.Index ~= stock.Index
			or (self.Stock.Rolls or 0) ~= (stock.Rolls or 0)

		self.Stock = stock

		-- Released for the next request: `_updateCountdown` can insist again
		-- when **this** storefront expires.
		self.StockRequested = false

		--[[
			The new storefront only redraws the row if it is a different one. The block switch
			may happen with the shop open in front of the player, and then the new cards drop
			over the old ones, which is what the switch means. A repeated storefront (the
			request the boot repeated) must not make the three cards drop again.
		]]
		if rotated then
			self:_render()
		end

		self:_updateCountdown()
	end)

	Framework:Listen("RoundCardPurchaseResult", function(cardId : string, success : boolean, reason : string?)
		if success then
			--[[
				The sound is the first thing that happens with the response: `PurchaseResult`
				goes out afterward, because listeners to the signal may do anything, and none of
				it may get ahead of the sound.

				The `SOLD` veil is not lit here: it tracks the replica's `RoundCards` (see
				`_watchProfile`), which is the same write the server just made. Lighting it in
				both places would give two sources for the same state.
			]]
			local music = self.Controllers.MusicController
			if music then
				music:PlaySFX(BUY_SOUND, { Key = BUY_SOUND_KEY })
			end
		end

		self.Signals.PurchaseResult:Fire(cardId, success, reason)
	end)

	--[[
		The purchase sound downloads now, not on the first click: `Sound:Play()` on an asset
		that has not arrived waits for the download, and for a sound confirming an action that
		wait is the whole response.
	]]
	local music = self.Controllers.MusicController
	if music then
		music:PreloadSFX({ BUY_SOUND })
	end

	--[[
		The panel: the frame, `OpenShop`, the blur, the screen request, and marker
		proximity. What is specific to this shop comes in through `OnBind` and `BeforeOpen`.
	]]
	self.Proximity = ProximityPanel.new({
		Name = "RoundCardShopController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = RoundCardShopConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		GetReference = function()
			return self:GetReferencePosition()
		end,
		Radius = RoundCardShopConfig.OPEN_RADIUS,
		Interval = RoundCardShopConfig.PROXIMITY_INTERVAL,
		InterfaceController = self.Controllers.InterfaceController,

		-- `ShopUI` is shared with the crate, Robux, and rune shops: closing this one with
		-- one of them open must not disable the ScreenGui under it.
		CanDisable = function()
			local crateShop = self.Controllers.ShopController
			local robuxShop = self.Controllers.RobuxShopController
			local runeShop = self.Controllers.RuneShopController

			return not ((crateShop and crateShop:IsOpen()) or (robuxShop and robuxShop:IsOpen())
				or (runeShop and runeShop:IsOpen()))
		end,

		OnBind = function(_screenGui, _wrapper, panel, maid)
			self:_onBind(panel, maid)
		end,

		--[[
			The cards drop on every opening, not once per storefront: the drop is the offer's
			presentation, and a panel opening with the three cards already still would look
			like a screen that was open all along.
		]]
		BeforeOpen = function()
			self:_render()
			self:_updateCountdown()

			-- The storefront was seen: the "the shop reset" badge ends, and comes back when the
			-- four-hour block turns over again.
			local badges = self.Controllers.HUDBadgeController
			if badges then
				badges:NoteSeen(HUD_BUTTON_NAME)
			end
		end,
	})

	local openChanged = self.Proximity.Signals.OpenChanged:Connect(function(isOpen : boolean)
		self.Signals.OpenChanged:Fire(isOpen)
	end)

	self.Maid:GiveTask(function()
		openChanged:Disconnect()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_observeUI()
	self:_watchProfile()
	self:_watchCountdown()
end

function RoundCardShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function RoundCardShopController:init()
	self.Maid = Maid.new()

	-- The HUD button, which lives in its own `ScreenGui` and is rebuilt at a different time
	-- from the panel.
	self.HudMaid = Maid.new()

	-- The card row: the clones, their clicks, and the entrance delays.
	self.RowMaid = Maid.new()

	self.Maid:GiveTask(self.HudMaid)
	self.Maid:GiveTask(self.RowMaid)

	-- This shop's `ProximityPanel`, created in `construct`.
	self.Proximity = nil

	-- The storefront from the server: nil until the answer arrives.
	self.Stock = nil
	self.StockRequested = false

	-- One entry per drawn card: the `Id`, its clone, and what the reveal needs to
	-- know to take the transparencies back.
	self.CardEntries = {}

	-- The template cloned from the authored `CardWrapper`, per `ShopUI` copy.
	self.Template = nil

	-- The reroll die, per `ShopUI` copy. Disabled when there is no card left to
	-- unlock (see `_refreshReroll`).
	self.RerollButton = nil

	-- The map markers, by name, and the names already warned about as missing.
	self.MapParts = {}
	self.WarnedMissing = {}

	self.CountdownClock = 0
end

return RoundCardShopController
