local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local ShopConfig = SharedConfig.ShopConfig
local RarityConfig = SharedConfig.RarityConfig

local Framework = Me.new()
local log = Log.new("ShopController")

--[[ CONSTANTS ]]
local SHOP_UI_NAME = "ShopUI"

--[=[
	The panel path: `ShopUI.Frame.ImageLabel`.

	The outer `Frame` carries the `UIAspectRatioConstraint`, and the inner `ImageLabel` is
	the drawn frame: it is what `OpenShop` writes to.

	**`ShopUI` carries three shops.** `Frame` is this one, the crate shop; `RCSS` next to it
	is the card shop (`RoundCardShopController`), and `RobuxShop` is the Robux shop
	(`RobuxShopController`). `ProximityPanel` opens and closes the frame, and its
	`CanDisable` is what keeps this shop from disabling the ScreenGui with a neighbor open.
]=]
local WRAPPER_NAME = "Frame"
local PANEL_NAME = "ImageLabel"
local LIST_NAME = "ScrollingFrame"

-- Inside each crate's container. `BoxArt` carries the illustration and, inside it,
-- the name; `Frame` carries the rarity list; `Buy` is the button with the price.
local BOX_ART_NAME = "BoxArt"
local ODDS_FRAME_NAME = "Frame"
local RARITY_TEMPLATE_NAME = "Rarity"
local RARITY_TEXT_NAME = "RarityTextPercentage"
local BUY_BUTTON_NAME = "Buy"

local RARITY_ROW_PREFIX = "Rarity_"

-- The shards counter does not exist in the new panel yet; the shop does not depend
-- on it to work. The X (`Close`, on the outer `Frame`) is hooked up by `ProximityPanel`.
local SHARDS_LABEL_NAME = "CurrentShards"

local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDFrame"
local HUD_BUTTON_NAME = "Shop"

-- How many times the chances are requested from the server before giving up, and how
-- often. See `_requestOdds`.
local ODDS_REQUEST_ATTEMPTS = 5
local ODDS_REQUEST_INTERVAL = 2

--[=[
	The name of the `InterfaceController` request: while the shop is open, the screen is
	its alone.

	A named request, not a global switch: the cutscene and the maps panel ask for the same
	thing, and a GUI only comes back when the **last** request leaves. Whoever hides never
	writes to the others' `Enabled`: the controller keeps what each GUI's owner wanted and
	restores exactly that.
]=]
local HIDE_REASON = "Shop"

--[=[
	The purchase sound, one per currency. It plays on the server's **result**, not on the
	click: price and wallet are checked there, and a click without balance bought nothing.

	Both live in `SoundService.BuySFX`, a loose folder next to the `SharedSounds` Package:
	it is a Lobby-only effect, and not worth a package change in both places.
	`MusicController` finds loose sounds and sounds in loose folders by name; see its
	`_findLoose`.

	The key is the profile currency (`ShopConfig.CURRENCIES`) and the value is the
	`Sound`'s name, which is the screen's name: the folder has `Coins`, not `Cash`.

	**Every purchase plays from the start.** Both share a `Key`, and `PlaySFX` stops and
	destroys whatever is playing on it before releasing the new clone: buying again
	mid-sound cuts and restarts, instead of adding a second copy on top of the first.
	Without `Key` the clones would stack, and the third purchase in a row would come out as
	a smear instead of three confirmations.

	This **is not a debounce**: nothing is swallowed, and every server response has its
	sound. The cut favors the player: the sound they hear is always the purchase they just
	made.

	No fade, so the clone plays on the same frame the response arrives. What could still
	delay it was downloading the audio on the first play, which is why both are preloaded
	in `construct`.
]=]
local BUY_SOUND_KEY = "ShopBuy"

local BUY_SOUNDS = {
	Shards = "Shards",
	Cash = "Coins",
}

--[[
	Each rarity row's outline.

	The color is the tier's from `RarityConfig` (the same that paints the unboxing reel and
	the card name in the deck), and the gradient is a shine on top of it: the `UIStroke`'s
	`Color` carries the color and the gradient carries only the light, in gray, so changing
	a rarity color is one line in `RarityConfig` and not four here.

	Vertical (`Rotation = 90`) because the row is a wide, short rectangle: a horizontal
	gradient would light one end of the text and darken the other.
]]
local STROKE_GRADIENT_ROTATION = 90
local STROKE_SHEEN_TOP = 1
local STROKE_SHEEN_BOTTOM = 0.45

--[=[
	The `Buy` button's look per currency: the price outline's color, the icon next to it,
	and that icon's size.

	It lives here and not in `ShopConfig` because it is drawing: the config says which
	`Data.Stats` key the crate charges (and the server charges from there), and the screen
	translates that into color and image. Containers are authored one per crate, so
	without this the Crate Of Beginnings would keep the Shard icon next to a price in
	Coins: the art was drawn when the shop had a single currency.

	`IconScale` goes on the `UIScale` authored inside the `ImageLabel`. The two arts do not
	weigh the same in the same box: the Coins coin is fuller than the Shard, and comes out
	too large at the size the Shard needs. It is written on **both** currencies, not only
	the one that shrinks, because the `UIScale` belongs to the container, not the
	currency: a price that went back to Shards would keep the previous owner's shrunk
	icon.

	The key is the same as `ShopConfig.CURRENCIES`. A currency with no entry here leaves
	the button as the designer authored it, which beats hiding its icon.
]=]
local CURRENCY_STYLE = {
	Shards = {
		StrokeColor = Color3.fromRGB(69, 92, 241),
		Icon = "rbxassetid://84637851192567",
		IconScale = 1,
	},

	Cash = {
		StrokeColor = Color3.fromRGB(211, 170, 88),
		Icon = "rbxassetid://94514377432201",
		IconScale = 0.8,
	},
}

--[=[
	Owner of `StarterGui.ShopUI`: finds each crate's container, writes what changes into
	it, and plays `OpenShop` on the panel.

	**It creates no container.** Each crate has its own container authored in the
	`ScrollingFrame`, with its own illustration, frame, and color, and the code only finds
	it by name (the crate's `Key`; see `CrateConfig`) and fills in three things: the name
	on `BoxArt`, the price on `Buy` (with its currency's color and icon), and the rarity
	list on `Frame`. Cloning a single template per item would give three crates that look
	like the first.

	Inside each container, the rarity row **is a per-crate template**: the authored
	`Rarity` is that crate's art, and it is cloned once per rarity the crate can drop,
	from most common (top) to rarest (bottom).

	The **chances** are not in a shared config: they belong to the server, and arrive
	through `CrateOdds` after a `RequestCrateOdds`. Until they arrive the container has no
	rows at all, not the authored number: a designer placeholder on the player's screen is
	worse than half a second of empty space.

	Walking within `ShopConfig.OPEN_RADIUS` of the shop part opens it, and leaving closes
	it. `Open`/`Close`/`Toggle` are public, so anything else (the HUD button, a Cmdr
	command) moves the same panel.

	`ShopKeeperController` reacts to the player **arriving**, in a larger radius around the
	same point. It listens to `PurchaseResult` here to know whether to say goodbye nicely
	or not, and this controller does not know it exists.

	See docs/lobby/shop.md.
]=]
local ShopController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},

		-- The other shops in the same `ScreenGui`. Only to know whether any is open
		-- before disabling the ScreenGui of all three; see `CanDisable` in `construct`.
		RoundCardShopController = {},
		RobuxShopController = {},
		RuneShopController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),

		-- (item : ShopConfig.ShopItem) -- fired alongside the RequestBuyShopItem
		-- event, for anything client side that wants to react to the click.
		PurchaseRequested = Signal.new(),

		-- (itemId : string, success : boolean, reason : string?) -- what ShopService
		-- decided. reason is one of UnknownItem, NotLoaded, NotEnoughCurrency,
		-- GrantFailed.
		PurchaseResult = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	A percentage the way the art writes it: `40%`, `85.99%`, `0.14%`.

	Two decimals are enough for the table's smallest chance (Cosmic in the Crate Of
	Nature, 0.14%) not to become "0%", and the trailing zero drops so the round case does
	not become "40.00%" next to an "85.99%".
]=]
local function formatPercent(chance : number) : string
	local rounded = math.floor(chance * 100 + 0.5) / 100

	-- A chance that exists but does not fit in two decimals becomes `<0.01%`, not `0%`: the
	-- row is there because the rarity can drop, and writing zero would be a lie.
	-- No pool today comes close (the smallest is 0.14%), but whoever changes the
	-- numbers will not discover this rule through a bug.
	if rounded <= 0 then
		return "<0.01%"
	end

	local text = string.format("%.2f", rounded)

	text = string.gsub(text, "%.?0+$", "")

	return text .. "%"
end

--[=[
	Dresses the `Buy` button with the currency that crate charges: the price outline and
	the icon next to it.

	The three crates were authored when the shop only charged in Shards, so all three are
	born with the Shard's icon and blue. Writing both here is what makes a Coins crate read
	as Coins without the designer touching any container when a price changes currency.
]=]
local function styleBuyButton(buy : Instance, currency : string)
	local style = CURRENCY_STYLE[currency]
	if not style then
		return
	end

	local priceLabel = buy:FindFirstChildWhichIsA("TextLabel")
	local stroke = priceLabel and priceLabel:FindFirstChildWhichIsA("UIStroke")

	if stroke then
		stroke.Color = style.StrokeColor
	end

	local icon = buy:FindFirstChildWhichIsA("ImageLabel")
	if not icon then
		return
	end

	icon.Image = style.Icon

	-- The `UIScale` is authored inside the icon. Without it only the designer's size
	-- applies.
	local scale = icon:FindFirstChildWhichIsA("UIScale")
	if scale and style.IconScale then
		scale.Scale = style.IconScale
	end
end

--[=[
	Paints a row's outline with its rarity's color, with a top-to-bottom shine.

	The authored `UIStroke` is the crate's (black on the Crate Of Nature, green on the
	Fragmented Crate), and it says nothing about the row's rarity: a crate's four rows
	would come out identical. Here it becomes the tier's color, and the row reads on its
	own before the player reaches the text.

	The gradient is reused when an authored one exists (the Crate Of Beginnings template
	has one) instead of creating a second one beside it: two `UIGradient`s on the same
	`UIStroke` means Roblox picking one by tree order.
]=]
local function styleRarityStroke(label : TextLabel, rarity : string)
	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	local color = RarityConfig.getColor(rarity)

	if not stroke or not color then
		return
	end

	stroke.Color = color

	local gradient = stroke:FindFirstChildWhichIsA("UIGradient")
	if not gradient then
		gradient = Instance.new("UIGradient")
		gradient.Parent = stroke
	end

	gradient.Rotation = STROKE_GRADIENT_ROTATION
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(STROKE_SHEEN_TOP, STROKE_SHEEN_TOP, STROKE_SHEEN_TOP)),
		ColorSequenceKeypoint.new(1, Color3.new(STROKE_SHEEN_BOTTOM, STROKE_SHEEN_BOTTOM, STROKE_SHEEN_BOTTOM)),
	})
end

--[=[
	Writes a container's rarity rows, from most common to rarest.

	The `Rarity` authored inside the container is that crate's template: it leaves the
	screen on bind and comes back cloned, once per rarity with a chance above zero. The
	order is `RarityConfig`'s, not by chance: in the legendary crate Epic and Legendary tie
	at 40%, and sorting by number would put both before Rare.

	With no odds (they have not arrived from the server yet) the container stays empty on
	purpose. See the class comment.
]=]
function ShopController:_renderOdds(entry)
	local template = entry.RarityTemplate
	local frame = entry.OddsFrame
	if not template or not frame or not frame.Parent then
		return
	end

	for _, row in entry.Rows do
		row:Destroy()
	end

	entry.Rows = {}

	local odds = self.CrateOdds and self.CrateOdds[entry.Item.Id]
	if not odds then
		return
	end

	for _, rarity in RarityConfig.ORDER do
		local chance = odds[rarity]
		if not chance or chance <= 0 then
			continue
		end

		local row = template:Clone()
		row.Name = RARITY_ROW_PREFIX .. rarity
		row.LayoutOrder = RarityConfig.getOrder(rarity) or 0

		local label = row:FindFirstChild(RARITY_TEXT_NAME, true)
		if label and label:IsA("TextLabel") then
			local tier = RarityConfig.TIERS[rarity]
			local name = (tier and tier.DisplayName) or rarity

			label.Text = string.format("%s: %s", string.upper(name), formatPercent(chance))
			styleRarityStroke(label, rarity)
		end

		row.Visible = true
		row.Parent = frame

		table.insert(entry.Rows, row)
	end
end

--[=[
	Binds an authored container to the shop item it represents.

	Returns nil when the container lacks the structure the art promises: a broken
	container disappears from the shop instead of showing without a price.
]=]
function ShopController:_bindContainer(container : Instance, item)
	local boxArt = container:FindFirstChild(BOX_ART_NAME)
	local oddsFrame = container:FindFirstChild(ODDS_FRAME_NAME)
	local buy = container:FindFirstChild(BUY_BUTTON_NAME)

	if not oddsFrame or not buy then
		log:StudioWarn(`container '{container.Name}' has no {ODDS_FRAME_NAME}/{BUY_BUTTON_NAME}.`)
		return nil
	end

	container.LayoutOrder = item.Order
	container:SetAttribute("ShopItemId", item.Id)
	container.Visible = true

	-- The name lives inside the illustration, not next to it.
	local nameLabel = boxArt and boxArt:FindFirstChildWhichIsA("TextLabel")
	if nameLabel then
		nameLabel.Text = string.upper(item.DisplayName)
	end

	--[[
		The price with the VIP discount, through the same `ShopConfig.priceFor` the server
		uses to charge: the number on the button is the number that leaves the wallet because
		it is the same math, not because someone remembered to change both.
	]]
	local priceLabel = buy:FindFirstChildWhichIsA("TextLabel")
	if priceLabel then
		priceLabel.Text = string.format(ShopConfig.PRICE_FORMAT, UIUtil.formatCommas(self:_priceOf(item)))
	end

	styleBuyButton(buy, item.Currency)

	if buy:IsA("GuiButton") then
		self.ItemMaid:GiveTask(buy.Activated:Connect(function()
			self:_requestPurchase(item)
		end))

		--[[
			The button's weight (grow on hover, sink on press) comes from `ButtonUtil`: the card
			shop uses the same, and both must respond to touch the same way. It goes in
			`ItemMaid`, along with the rest of the container's bind: a new `_render`
			disconnects everything and cancels any tween midway.
		]]
		ButtonUtil.bindFeedback(buy, self.ItemMaid)
	end

	--[[
		The authored row becomes a template and leaves the screen.

		It is cloned before being destroyed because its art is **that crate's**: there is no
		single row template anywhere, and what separates the Crate Of Nature's row from the
		Fragmented Crate's is exactly what the designer authored in here.
	]]
	local authored = oddsFrame:FindFirstChild(RARITY_TEMPLATE_NAME)
	local template = nil

	if authored then
		template = authored:Clone()
		authored:Destroy()
	else
		log:StudioWarn(`container '{container.Name}' has no {RARITY_TEMPLATE_NAME} to clone.`)
	end

	local entry = {
		Item = item,
		Container = container,
		OddsFrame = oddsFrame,
		RarityTemplate = template,
		Rows = {},
	}

	self:_renderOdds(entry)

	return entry
end

--[=[
	Fills the whole shop from the config.

	A container with no item in the table stays hidden, and an item with no authored
	container leaves the shop with a warning: that is the legendary one's case today (see
	`ShopConfig.ITEMS`). Both warn only once per name: a missing container is an authoring
	error, and repeating it per respawn only fills the output.
]=]
function ShopController:_render()
	if not self.List then
		return
	end

	self.ItemMaid:DoCleaning()
	self.Entries = {}

	local claimed = {}

	for _, item in ShopConfig.getItems() do
		local container = self.List:FindFirstChild(item.Container)

		if not container or not container:IsA("GuiObject") then
			if not self.WarnedMissing[item.Container] then
				self.WarnedMissing[item.Container] = true
				log:StudioWarn(`no container '{item.Container}' in {SHOP_UI_NAME}.{WRAPPER_NAME}.{PANEL_NAME}.{LIST_NAME}, skipping '{item.Id}'.`)
			end

			continue
		end

		claimed[container] = true

		local entry = self:_bindContainer(container, item)
		if entry then
			table.insert(self.Entries, entry)
		end
	end

	-- A container that belongs to no item in the table: hidden, not destroyed. It
	-- is designer work, and the shop does not own it.
	for _, child in self.List:GetChildren() do
		if child:IsA("GuiObject") and not claimed[child] then
			child.Visible = false
		end
	end
end

--[=[
	Asks the server for the chances, and insists until they arrive.

	The insisting exists because **the event identifier is created on the server** (see
	docs/architecture/me-framework.md): the client may hook up the shop before
	`ShopService` registered its `RequestCrateOdds` `Listen`, and a request made in that
	window is lost. Without retrying, the shop would have no rarity rows for the rest of
	the session because of half a second of boot order.

	The loop stops at the first `CrateOdds` that arrives and has an attempt cap: if the
	server does not answer after that, it will not, and asking forever would only hide the
	problem.
]=]
function ShopController:_requestOdds()
	if self.CrateOdds or self.OddsRequested then
		return
	end

	self.OddsRequested = true

	task.spawn(function()
		for _ = 1, ODDS_REQUEST_ATTEMPTS do
			if self.CrateOdds then
				return
			end

			Framework:Fire("RequestCrateOdds")
			task.wait(ODDS_REQUEST_INTERVAL)
		end

		if not self.CrateOdds then
			log:StudioWarn("no CrateOdds from the server -- the crates show no rarity rows.")
		end
	end)
end

function ShopController:_requestPurchase(item)
	self.Signals.PurchaseRequested:Fire(item)

	-- The server prices it against the profile and grants it -- the client only asks.
	Framework:Fire("RequestBuyShopItem", item.Id)
end

function ShopController:_updateShards()
	local label = self.ShardsLabel
	if not label or not label.Parent then
		return
	end

	local replica = self.Replica
	local stats = replica and replica.Data and replica.Data.Stats
	local shards = (stats and stats.Shards) or 0

	label.Text = UIUtil.formatCommas(shards)
end

--[=[
	An item's price for this player. The VIP gamepass takes 20%, and the math is the same
	as the server's: `ShopConfig.priceFor` reads the replica's own `Gamepasses` key.
]=]
function ShopController:_priceOf(item) : number
	local replica = self.Replica

	return ShopConfig.priceFor(item, replica and replica.Data or nil)
end

function ShopController:_watchShards()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_updateShards()

		-- DataService writes the whole Stats key, but listen through OnChange so any
		-- deeper write (Stats.Shards, ...) refreshes the counter too.
		local connection = replica:OnChange(function(_action, path)
			local key = path[1]

			-- `Gamepasses` is included because VIP changes the price written on the button: buying
			-- the pass with the shop open must reprice the screen, not wait for the next
			-- opening.
			if key == "Gamepasses" then
				self:_render()
				return
			end

			if key ~= nil and key ~= "Stats" then
				return
			end

			self:_updateShards()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	One of the shop's marker parts in the map, cached until it is taken out of the
	world (a map swap reparents it, so the reference is re-resolved instead of held
	forever). Warns once per marker so a missing one is visible without spamming.

	**The lookup is recursive inside the map, not only its direct children.** Both markers
	are grouped in the shop model (`Map.Shop`), not loose in `Map`: looking one level down
	would find nothing, the HUD button would not teleport, and proximity would never open
	the panel. Each marker's name is unique on the map, so walking down the tree finds the
	same part wherever the artist groups it.
]=]
function ShopController:_getMapPart(partName : string) : Instance?
	return MarkerUtil.find(
		ShopConfig.REFERENCE_PARENT_NAME,
		partName,
		self.MapParts,
		self.WarnedMissing,
		"ShopController"
	)
end

--[=[
	Where the shop is, for anyone who needs to measure against the same center proximity
	measures. Public because of `ShopKeeperController`: the shopkeeper stands up in a
	larger radius around **this** point, not their body, so the two radii are concentric:
	reaching the counter can never happen without them having stood up first.
]=]
function ShopController:GetReferencePosition() : Vector3?
	local pivot = MarkerUtil.pivotOf(self:_getMapPart(ShopConfig.REFERENCE_PART_NAME))
	return pivot and pivot.Position or nil
end

--[=[
	The shop's content on a new copy of `ShopUI`. The panel itself (the frame, `OpenShop`,
	the X, the blur, and the screen request) belongs to `ProximityPanel`, which calls this at
	the end of its bind. `ShopUI` is `ResetOnSpawn`, so this runs again on every respawn.
]=]
function ShopController:_onBind(screenGui : ScreenGui, panel : GuiObject)
	local list = panel:WaitForChild(LIST_NAME, 10)

	if not list then
		log:StudioWarn(`could not find {SHOP_UI_NAME}.{WRAPPER_NAME}.{PANEL_NAME}.{LIST_NAME}.`)
		return
	end

	self.ItemMaid:DoCleaning()

	self.List = list

	--[[
		The shards counter is optional: the new panel does not have one yet, and the shop
		opens and closes by proximity without needing it.

		The lookup starts **inside the panel** and only then falls back to the whole
		ScreenGui. Order matters because the old panel (`ShopUI.ImageLabel`, hidden) still
		has a `CurrentShards`, and it comes first in the tree: searching the ScreenGui
		directly, a new counter authored on today's panel would lose to the old one and never
		be written.
	]]
	self.ShardsLabel = panel:FindFirstChild(SHARDS_LABEL_NAME, true)
		or screenGui:FindFirstChild(SHARDS_LABEL_NAME, true)

	self.Entries = {}

	self:_render()
	self:_updateShards()
	self:_requestOdds()
end

--[=[
	Binds the shop button on the HUD, which walks the player over to the shop. The
	icon lives inside a wrapper frame, so the button is looked up by name anywhere
	under the HUD frame -- and the hover and click animations are the
	HUDButtonController's, shared by every button up there.
]=]
function ShopController:_bindHud(screenGui : ScreenGui)
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

--- The HUD, through the button that goes to the shop. `ProximityPanel` follows `ShopUI`.
function ShopController:_observeUI()
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

function ShopController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function ShopController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function ShopController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

--[=[
	Drops the player on the teleport marker next to the shop.

	The client owns its own character, so moving it here is enough; the server sees
	the new position through the usual replication.

	The landing is **outside** `OPEN_RADIUS`, which is the counter (5 studs), not the
	whole yard. So the button opens the shop by hand, through `EnterRange`, which marks the
	entry too, or the exit crossing would never happen and the shop opened by the button
	would stay stuck on screen however far they walked.
]=]
function ShopController:TeleportToShop() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not root then
		return false
	end

	local pivot = MarkerUtil.pivotOf(self:_getMapPart(ShopConfig.TELEPORT_PART_NAME))
	if not pivot then
		return false
	end

	local halfHeight = MarkerUtil.halfHeightOf(self.MapParts[ShopConfig.TELEPORT_PART_NAME])

	character:PivotTo(pivot * CFrame.new(0, halfHeight + ShopConfig.TELEPORT_HEIGHT_OFFSET, 0))

	-- Without this the player keeps whatever momentum they had and slides off.
	root.AssemblyLinearVelocity = Vector3.zero

	if self.Proximity then
		self.Proximity:EnterRange()
	end

	return true
end

function ShopController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

--[=[
	Rewrites the containers from the config. Only needed when the config changes at
	runtime.

	It does not ask for the odds again: they are config times config on the server and do
	not change during the session.
]=]
function ShopController:Refresh()
	self:_render()
end

function ShopController:construct()
	--[[
		The odds are listened to before the UI is observed on purpose: the answer may arrive
		before the first bind finishes, and each entry's `_renderOdds` draws from scratch:
		arriving too early only means the shop opens with the rows already there.
	]]
	Framework:Listen("CrateOdds", function(odds)
		if typeof(odds) ~= "table" then
			return
		end

		self.CrateOdds = odds

		for _, entry in self.Entries do
			self:_renderOdds(entry)
		end
	end)

	Framework:Listen("ShopPurchaseResult", function(itemId : string, success : boolean, reason : string?)
		if success then
			--[[
				Which of the two sounds plays comes from the config, not the server: the result
				carries the item id, and that id's price is public. Sending the currency over the
				network would only give the client a second version of something it already
				knows.

				It is the first thing that happens with the response: `PurchaseResult` goes out
				afterward, because listeners to the signal may do anything, and none of it may
				get ahead of the sound.
			]]
			local item = ShopConfig.getItem(itemId)
			local sound = item and BUY_SOUNDS[item.Currency]

			local music = self.Controllers.MusicController
			if music and sound then
				music:PlaySFX(sound, { Key = BUY_SOUND_KEY })
			end
		end

		self.Signals.PurchaseResult:Fire(itemId, success, reason)
	end)

	--[[
		Both purchase sounds download now, not on the first click.

		`Sound:Play()` on an asset that has not arrived waits for the download, and for a
		sound confirming an action that wait is the whole response. The preload runs on its
		own thread inside `PreloadSFX`, so it does not hold up the controller's boot.
	]]
	local music = self.Controllers.MusicController
	if music then
		local names = {}
		for _, name in BUY_SOUNDS do
			table.insert(names, name)
		end

		music:PreloadSFX(names)
	end

	--[[
		The panel: the frame, `OpenShop`, the blur, the screen request, and counter
		proximity. What is specific to this shop comes in through `OnBind`.
	]]
	self.Proximity = ProximityPanel.new({
		Name = "ShopController",
		ScreenGui = SHOP_UI_NAME,
		Wrapper = WRAPPER_NAME,
		Panel = PANEL_NAME,
		Animation = ShopConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		GetReference = function()
			return self:GetReferencePosition()
		end,
		Radius = ShopConfig.OPEN_RADIUS,
		Interval = ShopConfig.PROXIMITY_INTERVAL,
		InterfaceController = self.Controllers.InterfaceController,

		-- `ShopUI` is shared with the card, Robux, and rune shops: closing this one with
		-- one of them open must not disable the ScreenGui under it.
		CanDisable = function()
			local cardShop = self.Controllers.RoundCardShopController
			local robuxShop = self.Controllers.RobuxShopController
			local runeShop = self.Controllers.RuneShopController

			return not ((cardShop and cardShop:IsOpen()) or (robuxShop and robuxShop:IsOpen())
				or (runeShop and runeShop:IsOpen()))
		end,

		OnBind = function(screenGui, _wrapper, panel)
			self:_onBind(screenGui, panel)
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
	self:_watchShards()
end

function ShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function ShopController:init()
	self.Maid = Maid.new()
	self.ItemMaid = Maid.new()
	self.HudMaid = Maid.new()

	self.Maid:GiveTask(self.ItemMaid)
	self.Maid:GiveTask(self.HudMaid)

	-- This shop's `ProximityPanel`, created in `construct`.
	self.Proximity = nil

	-- One entry per drawn crate: the item, its container, and the rarity rows
	-- on screen now.
	self.Entries = {}

	-- The chances per item, from the server: nil until the answer arrives.
	self.CrateOdds = nil
	self.OddsRequested = false

	-- Marker parts in the map, by name, and the names already warned about. The same
	-- map keeps the missing container, for the same reason: warn once.
	self.MapParts = {}
	self.WarnedMissing = {}
end

return ShopController
