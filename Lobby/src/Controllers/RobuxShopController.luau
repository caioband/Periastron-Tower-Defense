local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local ProximityPanel = require(Util.ProximityPanel)

local RobuxShopConfig = SharedConfig.RobuxShopConfig
local GamepassConfig = SharedConfig.GamepassConfig

local Framework = Me.new()
local log = Log.new("RobuxShopController")

local GUI = RobuxShopConfig.Gui

--[[ CONSTANTS ]]

--[=[
	The name of the `InterfaceController` request: while the shop is open, the screen is
	its alone.

	Its own, not the other shops' `"Shop"`: a GUI only comes back when the **last**
	request leaves, and sharing the name would let one give back the screen the other
	asked for.
]=]
local HIDE_REASON = "RobuxShop"

--[=[
	The HUD button that opens the shop: `HUD.HUDLeft.Wrapper.RobuxShop`, next to
	`Contracts` in the left column.

	**This shop has no place on the map.** The other two open by proximity and the HUD
	button only takes the player there; here the button *is* the door; see
	`ProximityPanel` without `GetReference`.

	The button's grow and sink still belong to `HUDButtonController`, which animates both
	columns. Only the click comes from here.
]=]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDLeft"
local HUD_BUTTON_NAME = "RobuxShop"

local WAIT_TIMEOUT = 10

-- The `UIScale` `ButtonUtil` needs to give the button weight. The rows were
-- authored without it, and creating one here does not get in the way of those that have one.
local SCALE_NAME = "BuyScale"

-- The button of a pass the player already owns is dimmed, not hidden: the row's art
-- was drawn with it in place. The same number as an already claimed CLAIM.
local DISABLED_TRANSPARENCY = 0.55

--[=[
	The Lobby Robux shop: `StarterGui.ShopUI.RobuxShop`.

	Six gamepasses and three coin packs, each on a `BUY`. **This controller credits
	nothing**: it opens Roblox's prompt and stops there. The pass becomes a benefit when
	`MonetizationService` rechecks the profile (`RecalibratePasses`), and the pack becomes
	coins when the receipt reaches `RobuxShopService`: both on the server, both coming back
	here through the replica.

	`OWNED` is a reading of the same profile: `Data.Gamepasses` says what this player
	already owns, and the matching row dims its button. Canceling the prompt changes
	nothing, which is right: nothing here is written on the click.

	**`ShopUI` is shared with the other two shops.** The three are siblings inside it and
	none controls `Enabled` alone: each one's wrapper `Visible` says which panel is on
	screen (see `CanDisable` in `construct`).

	See docs/common/gamepasses.md.
]=]
local RobuxShopController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},

		-- The other two shops in the same `ScreenGui`. Only to know whether any is
		-- open before disabling the ScreenGui of all three; see `CanDisable`.
		ShopController = {},
		RoundCardShopController = {},
		RuneShopController = {},

		-- The HUD button's `New` badge, which comes back five minutes after each
		-- opening. See `BeforeOpen` in `construct`.
		HUDBadgeController = {},
	},
}

--[[ INTERNAL ]]

--- The replica's `Data`, or nil until it arrives.
function RobuxShopController:_profile()
	local replica = self.Replica

	return replica and replica.Data or nil
end

--- Whether this player owns the pass. With no profile it counts as "does not", not an error.
function RobuxShopController:_owns(key : string) : boolean
	local profile = self:_profile()

	return profile ~= nil and GamepassConfig.owns(profile, key)
end

--[=[
	Hooks up a storefront row by its name.

	The lookup is by depth from the panel: the rows live in two `ScrollingFrame`s with
	**the same name** (passes in one, packs in the other), so the path to the list does not
	tell them apart, but `GP1` and `DEVPROD1` are unique on the whole screen.
]=]
function RobuxShopController:_bindRow(panel : GuiObject, frameName : string, maid, onClick : () -> ())
	local row = panel:FindFirstChild(frameName, true)
	local button = row and row:FindFirstChild(GUI.Buy, true)

	if not button or not button:IsA("GuiButton") then
		log:StudioWarn(`could not find {frameName}.{GUI.Buy} in {GUI.ScreenGui}.{GUI.Wrapper}; that row buys nothing.`)
		return nil
	end

	if not button:FindFirstChildWhichIsA("UIScale") then
		local scale = Instance.new("UIScale")
		scale.Name = SCALE_NAME
		scale.Parent = button
	end

	local label = button:FindFirstChildWhichIsA("TextLabel")

	maid:GiveTask(button.Activated:Connect(onClick))
	ButtonUtil.bindFeedback(button, maid)

	return {
		Button = button,
		Label = label,

		-- The authored transparency, read once: it is what the button returns to when
		-- the row is for sale.
		Image = button:IsA("ImageButton") and button.ImageTransparency or 0,
		Text = label and label.TextTransparency or 0,
	}
end

--[=[
	The content on a new copy of `ShopUI`: the six passes and the three packs.

	The panel itself (frame, animation, blur, screen) belongs to `ProximityPanel`, and the
	`maid` here is its maid: a new copy disconnects the previous one's clicks.
]=]
function RobuxShopController:_onBind(panel : GuiObject, maid)
	self.Rows = {}

	for _, entry in RobuxShopConfig.PASSES do
		self.Rows[entry.Frame] = self:_bindRow(panel, entry.Frame, maid, function()
			self:_promptPass(entry.Pass)
		end)
	end

	for _, pack in RobuxShopConfig.PACKS do
		self.Rows[pack.Frame] = self:_bindRow(panel, pack.Frame, maid, function()
			self:_promptPack(pack)
		end)
	end

	self:_render()
end

--[=[
	The button according to the profile: dimmed and unclickable for a pass the player
	already owns.

	A coin pack never goes through here: it can be bought again as many times as wanted,
	and its button always stays as authored.
]=]
function RobuxShopController:_writeOwned(entry, owned : boolean)
	local button = entry.Button

	button.Active = not owned
	button.AutoButtonColor = not owned

	if button:IsA("ImageButton") then
		button.ImageTransparency = if owned then DISABLED_TRANSPARENCY else entry.Image
	end

	local label = entry.Label
	if label then
		label.Text = if owned then RobuxShopConfig.OWNED_TEXT else RobuxShopConfig.BUY_TEXT
		label.TextTransparency = if owned then DISABLED_TRANSPARENCY else entry.Text
	end
end

function RobuxShopController:_render()
	for _, pass in RobuxShopConfig.PASSES do
		local entry = self.Rows[pass.Frame]

		if entry then
			self:_writeOwned(entry, self:_owns(pass.Pass))
		end
	end
end

--[=[
	Opens a gamepass prompt.

	It only opens what can still be bought: the button is already dimmed, and this is the
	same check on the other side of the click: a prompt for a pass the player owns would
	only tell them what the row already said.
]=]
function RobuxShopController:_promptPass(key : string)
	local pass = GamepassConfig.PASSES[key]

	if not pass then
		log:StudioWarn(`pass '{key}' is not in GamepassConfig.`)
		return
	end

	if self:_owns(key) then
		return
	end

	MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, pass.Id)
end

--[=[
	Opens a coin pack prompt.

	No debounce, like the reroll: `PromptProductPurchase` does not stack windows. And no
	credit at all here: the receipt pays, in `RobuxShopService`.
]=]
function RobuxShopController:_promptPack(pack)
	MarketplaceService:PromptProductPurchase(Players.LocalPlayer, pack.ProductId)
end

--[=[
	Hooks up the HUD button that opens the shop.

	Its own maid: `HUD` and `ShopUI` are different `ScreenGui`s and the engine rebuilds
	them at different times, so one's bind must not disconnect the other's.
]=]
function RobuxShopController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)
	local button = hudFrame and hudFrame:FindFirstChild(HUD_BUTTON_NAME, true)

	if not button or not button:IsA("GuiButton") then
		if not self.WarnedButton then
			self.WarnedButton = true
			log:StudioWarn(`could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		end

		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:Toggle()
	end))
end

--- The HUD, through the button that opens the shop. `ProximityPanel` follows `ShopUI`.
function RobuxShopController:_observeUI()
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

--[=[
	Follows the profile: a pass bought mid-session arrives here through the replica,
	because `MonetizationService` rechecks and rewrites `Data.Gamepasses` as soon as the
	prompt closes. That is why the row turns `OWNED` on its own, with the shop open.
]=]
function RobuxShopController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= "Gamepasses" then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

function RobuxShopController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function RobuxShopController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function RobuxShopController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function RobuxShopController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function RobuxShopController:construct()
	--[[
		The panel: the frame, `OpenShop`, the blur, and the screen request. **No
		`GetReference`**: this shop has no point on the map, so nothing measures distance
		and it lives on the HUD button and the X.
	]]
	self.Proximity = ProximityPanel.new({
		Name = "RobuxShopController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = RobuxShopConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		InterfaceController = self.Controllers.InterfaceController,

		-- `ShopUI` is shared with the crate, card, and rune shops: closing this one with
		-- one of them open must not disable the ScreenGui under it.
		CanDisable = function()
			local crateShop = self.Controllers.ShopController
			local cardShop = self.Controllers.RoundCardShopController
			local runeShop = self.Controllers.RuneShopController

			return not ((crateShop and crateShop:IsOpen()) or (cardShop and cardShop:IsOpen())
				or (runeShop and runeShop:IsOpen()))
		end,

		OnBind = function(_screenGui, _wrapper, panel, maid)
			self:_onBind(panel, maid)
		end,

		-- The profile may have changed with the shop closed (a pass bought on the game's
		-- page, for example): the storefront opens already showing what applies now.
		BeforeOpen = function()
			self:_render()

			-- The shop was opened: the badge goes off and its clock restarts.
			local badges = self.Controllers.HUDBadgeController
			if badges then
				badges:NoteSeen(HUD_BUTTON_NAME)
			end
		end,
	})

	self.Maid:GiveTask(function()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_observeUI()
	self:_watchProfile()
end

function RobuxShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function RobuxShopController:init()
	self.Maid = Maid.new()

	-- The HUD button's click, which the engine rebuilds on every respawn.
	self.HudMaid = Maid.new()
	self.Maid:GiveTask(self.HudMaid)

	-- [row name] = { Button, Label, Image, Text }
	self.Rows = {}

	self.Replica = nil
	self.Proximity = nil
	self.WarnedButton = false
end

return RobuxShopController
