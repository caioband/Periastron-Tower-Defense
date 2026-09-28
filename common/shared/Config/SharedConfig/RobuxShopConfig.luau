--[[
	The Lobby's Robux shop: `StarterGui.ShopUI.RobuxShop`.

	It is only a storefront. The six game passes and three coin packs open the
	Roblox prompt, and crediting stays where it always was: a pass is a **state**
	that `MonetizationService` checks on join (`RecalibratePasses`), and a pack is
	an **event** that `ProcessReceipt` pays once, through `RobuxShopService`.

	So there is nothing here but names and numbers: what each UI row sells. Each
	pass's benefit stays in `GamepassConfig`; this table only says that `GP1` on
	screen is the `VIP` pass there, never what VIP does. Two sources for the same
	thing is how a pass gains a benefit in the shop that it lacks in the game.

	Nothing here is secret: ids are on each product page, Roblox draws the price in
	the prompt, and the client needs the numbers to open the purchase.

	See docs/common/gamepasses.md.
]]

local module = {}

--[=[
	The UI path. `Wrapper` is the frame that comes and goes, and `Panel` is the art
	`OPEN_ANIMATION` animates; `ShopUI` holds three shops, and each lights its own
	(see `ProximityPanel`).

	Rows live in two `ScrollingFrame`s with the **same name** inside the panel (one
	for passes, one for packs), so each row is found by its name in depth from the
	panel, never by the list path.
]=]
module.Gui = {
	ScreenGui = "ShopUI",
	Wrapper = "RobuxShop",
	Panel = "ImageLabel",

	-- A row's buy button, and the text inside it.
	Buy = "BUY",
}

module.OPEN_ANIMATION = "OpenShop"

--[=[
	The button text. `OWNED` is for a pass this player already has: the button dims
	and stops opening the prompt, like the CLAIM of a claimed contract.

	A coin pack has no state: it can be bought again any number of times.
]=]
module.BUY_TEXT = "BUY"
module.OWNED_TEXT = "OWNED"

--[=[
	The storefront game passes, one per UI row, in the order the designer drew them.

	`Frame` is the row name on screen; `Pass` is the `GamepassConfig.PASSES` key,
	which gives the id the prompt opens and where the profile says whether the
	player owns it.
]=]
module.PASSES = {
	{ Frame = "GP1", Pass = "VIP" },
	{ Frame = "GP2", Pass = "Shards" },
	{ Frame = "GP3", Pass = "Luck" },
	{ Frame = "GP4", Pass = "CardSlots" },
	{ Frame = "GP5", Pass = "Coins" },
	{ Frame = "GP6", Pass = "Speed" },
}

--[=[
	The coin packs, one row per developer product.

	`Coins` is what the server deposits into `Stats.Cash` when the receipt arrives.
	It does **not** count toward `Stats.CoinsEarned`: the MOST COINS board is what
	the player earned by playing, not what they bought (see `RobuxShopService`).
]=]
module.PACKS = {
	{ Frame = "DEVPROD1", ProductId = 3713311022, Coins = 200 },
	{ Frame = "DEVPROD2", ProductId = 3713311161, Coins = 1400 },
	{ Frame = "DEVPROD3", ProductId = 3713311237, Coins = 7000 },
}

--[=[
	The pack for a `ProductId`, or nil. That is how a receipt comes back: it only
	carries the product number.
]=]
function module.packOfProduct(productId : number?)
	for _, pack in module.PACKS do
		if pack.ProductId == productId then
			return pack
		end
	end

	return nil
end

return module
