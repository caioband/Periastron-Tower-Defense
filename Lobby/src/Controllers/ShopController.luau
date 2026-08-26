local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Util.UIUtil)

local ShopConfig = SharedConfig.ShopConfig

-- Cascade lives only in the place (see Lobby/README.md), so it is reached by name
-- instead of through the Rojo tree.
local CascadeRuntime = ReplicatedStorage:WaitForChild("CascadeRuntimeEngine")
local AnimationService = require(CascadeRuntime:WaitForChild("AnimationService"))

local Framework = Me.new()

--[[ CONSTANTS ]]
local SHOP_UI_NAME = "ShopUI"

local PANEL_NAME = "ImageLabel"
local LIST_NAME = "ScrollingFrame"
local TEMPLATE_NAME = "ShopItemWrapper"
local CONTAINER_NAME = "ShopItemContainer"
local SHARDS_LABEL_NAME = "CurrentShards"
local CLOSE_BUTTON_NAME = "Close"

local ITEM_IMAGE_NAME = "ItemImg"
local ITEM_NAME_NAME = "ItemName"
local PRICE_NAME = "Price"
local CONFIRM_NAME = "Confirm"

local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDFrame"
local HUD_BUTTON_NAME = "Shop"

--[=[
	Owns StarterGui.ShopUI: renders one row per ShopConfig item and plays the two
	Cascade animations -- OpenShop on the panel, ShopItemContainerShow across every
	rendered wrapper as a single staggered batch.

	The GUI ships with one ShopItemWrapper authored by hand. That one is taken as
	the template and removed, so every row on screen comes from the config.

	Walking within ShopConfig.OPEN_RADIUS of the shop part opens it, and walking
	away closes it. Open/Close/Toggle are public, so anything else (a HUD button,
	a Cmdr command) can drive the same panel.
]=]
local ShopController = {
	Controllers = {
		DataController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),

		-- (item : ShopConfig.ShopItem) -- fired alongside the RequestBuyShopItem
		-- event, for anything client side that wants to react to the click.
		PurchaseRequested = Signal.new(),

		-- (itemId : string, success : boolean, reason : string?) -- what ShopService
		-- decided. reason is one of UnknownItem, NotLoaded, NotEnoughShards,
		-- GrantFailed.
		PurchaseResult = Signal.new(),
	},
}

--[[ INTERNAL ]]

function ShopController:_fillWrapper(wrapper : Frame, item)
	local container = wrapper:FindFirstChild(CONTAINER_NAME)
	if not container then
		warn(`[ShopController]: template is missing {CONTAINER_NAME}.`)
		return
	end

	wrapper.Name = item.Id
	wrapper.LayoutOrder = item.Order
	wrapper:SetAttribute("ShopItemId", item.Id)

	local itemImage = container:FindFirstChild(ITEM_IMAGE_NAME)
	if itemImage and itemImage:IsA("ImageLabel") and item.Image ~= "" then
		itemImage.Image = item.Image
	end

	local itemName = itemImage and itemImage:FindFirstChild(ITEM_NAME_NAME)
	if itemName and itemName:IsA("TextLabel") then
		itemName.Text = item.DisplayName
	end

	local price = container:FindFirstChild(PRICE_NAME)
	if price and price:IsA("TextLabel") then
		price.Text = UIUtil.formatCommas(item.Price)
	end

	local confirm = container:FindFirstChild(CONFIRM_NAME)
	if confirm and confirm:IsA("GuiButton") then
		local label = confirm:FindFirstChildWhichIsA("TextLabel")
		if label then
			label.Text = item.ButtonText
		end

		self.ItemMaid:GiveTask(confirm.Activated:Connect(function()
			self:_requestPurchase(item)
		end))
	end
end

--[=[
	Rebuilds every row from the config. Safe to call again: the old wrappers are
	pulled out of Cascade before being destroyed, so no track keeps writing to a
	frame that is already gone.
]=]
function ShopController:_render()
	if not self.Template or not self.List then
		return
	end

	self.ItemMaid:DoCleaning()

	if #self.Wrappers > 0 then
		AnimationService.ClearInstanceBatch(self.Wrappers)

		for _, wrapper in self.Wrappers do
			wrapper:Destroy()
		end
	end

	self.Wrappers = {}

	for _, item in ShopConfig.getItems() do
		local wrapper = self.Template:Clone()

		-- Hidden until the batch starts: the first frame Cascade writes is what puts
		-- the container off screen, and until then it would sit where it was authored.
		wrapper.Visible = false
		self:_fillWrapper(wrapper, item)
		wrapper.Parent = self.List

		table.insert(self.Wrappers, wrapper)
	end
end

--[=[
	Plays ShopItemContainerShow on every rendered wrapper as one batched track,
	ITEM_STAGGER apart. Cascade clamps a wrapper that has not reached its turn to the
	first keyframe, so the whole list starts off screen and slides in one by one.
]=]
function ShopController:_playItemAnimations()
	if #self.Wrappers == 0 then
		return
	end

	for _, wrapper in self.Wrappers do
		wrapper.Visible = true
	end

	AnimationService.PlayBatch(self.Wrappers, ShopConfig.ITEM_ANIMATION, {
		Stagger = ShopConfig.ITEM_STAGGER,
	})
end

--[=[
	Drives the panel through OpenShop. The track is created once per ShopUI and kept,
	so opening and closing is a direction change on the same animation -- closing
	mid-open picks up from wherever the panel got to instead of snapping.
]=]
function ShopController:_playPanel(reverse : boolean)
	local track = self.PanelTrack
	if not track then
		return
	end

	if track.State ~= "Playing" then
		track:Scrub(reverse and track.Duration or 0)
	end

	track:SetSpeed(reverse and -1 or 1)
	track:Play()
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

function ShopController:_watchShards()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_updateShards()

		-- DataService writes the whole Stats key, but listen through OnChange so any
		-- deeper write (Stats.Shards, ...) refreshes the counter too.
		local connection = replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
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
]=]
function ShopController:_getMapPart(partName : string) : Instance?
	local cached = self.MapParts[partName]
	if cached and cached.Parent then
		return cached
	end

	local parent = workspace:FindFirstChild(ShopConfig.REFERENCE_PARENT_NAME)
	local part = parent and parent:FindFirstChild(partName)

	if not part and not self.WarnedMissing[partName] then
		self.WarnedMissing[partName] = true
		warn(`[ShopController]: no Workspace.{ShopConfig.REFERENCE_PARENT_NAME}.{partName}.`)
	end

	self.MapParts[partName] = part
	return part
end

--[=[
	Where a marker part sits, whether it is a bare part or a model.
]=]
local function getPivot(part : Instance?) : CFrame?
	if not part then
		return nil
	end

	if part:IsA("BasePart") then
		return part.CFrame
	elseif part:IsA("Model") then
		return part:GetPivot()
	end

	return nil
end

function ShopController:_getReferencePosition() : Vector3?
	local pivot = getPivot(self:_getMapPart(ShopConfig.REFERENCE_PART_NAME))
	return pivot and pivot.Position or nil
end

--[=[
	Opens the shop when the player walks up to the part and closes it when they walk
	away. Only the crossing acts, so closing the panel by hand while still standing
	there does not fight the player by reopening it every check.
]=]
function ShopController:_updateProximity()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = root and self:_getReferencePosition()

	local inRange = false
	if position and root then
		inRange = (root.Position - position).Magnitude <= ShopConfig.OPEN_RADIUS
	end

	if inRange == self.InRange then
		return
	end

	self.InRange = inRange

	if inRange then
		self:Open()
	else
		self:Close()
	end
end

function ShopController:_watchProximity()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.ProximityClock += deltaTime

		if self.ProximityClock < ShopConfig.PROXIMITY_INTERVAL then
			return
		end

		self.ProximityClock = 0
		self:_updateProximity()
	end))
end

--[=[
	Binds to a ShopUI instance. ShopUI has ResetOnSpawn enabled, so this runs again
	for every fresh copy the engine parents into PlayerGui.
]=]
function ShopController:_bindUI(screenGui : ScreenGui)
	local panel = screenGui:WaitForChild(PANEL_NAME, 10)
	local list = panel and panel:WaitForChild(LIST_NAME, 10)
	local template = list and list:WaitForChild(TEMPLATE_NAME, 10)

	if not panel or not list or not template then
		warn(`[ShopController]: could not find {SHOP_UI_NAME}.{PANEL_NAME}.{LIST_NAME}.{TEMPLATE_NAME}.`)
		return
	end

	self.UIMaid:DoCleaning()
	self.ItemMaid:DoCleaning()

	self.ScreenGui = screenGui
	self.Panel = panel
	self.List = list
	self.ShardsLabel = panel:FindFirstChild(SHARDS_LABEL_NAME)

	--[[
		O X do painel.

		Fechar na mão não desliga a proximidade: o `_updateProximity` só age na
		**travessia**, então o painel não é reaberto no tick seguinte só porque o
		jogador continua parado ali. Ele volta quando o jogador sair do raio e
		voltar — que é o que "fechei porque não quero agora" quer dizer.

		Vai no `UIMaid`, junto com o resto do bind: a `ShopUI` é `ResetOnSpawn`, e a
		cópia nova traz um botão novo.
	]]
	local closeButton = panel:FindFirstChild(CLOSE_BUTTON_NAME)

	if closeButton and closeButton:IsA("GuiButton") then
		self.UIMaid:GiveTask(closeButton.Activated:Connect(function()
			self:Close()
		end))
	else
		warn(`[ShopController]: could not find {SHOP_UI_NAME}.{PANEL_NAME}.{CLOSE_BUTTON_NAME}.`)
	end

	-- The authored row is the template, not a row: it never shows up on screen.
	self.Template = template:Clone()
	template:Destroy()

	self.PanelTrack = AnimationService.CreateTrack(panel, ShopConfig.OPEN_ANIMATION)

	if self.PanelTrack then
		local connection = self.PanelTrack.Completed:Connect(function()
			-- Only the closing pass ends with the panel hidden.
			if not self.IsOpenState and screenGui.Parent then
				screenGui.Enabled = false
			end
		end)

		self.UIMaid:GiveTask(function()
			connection.Disconnect()
		end)
	end

	self.Wrappers = {}
	self.IsOpenState = false
	self.OpenToken += 1
	screenGui.Enabled = false

	-- A fresh copy means a respawn: the player may well still be standing next to
	-- the part, and the next check has to open the new panel.
	self.InRange = false

	self:_render()
	self:_updateShards()
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
		warn(`[ShopController]: could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:TeleportToShop()
	end))
end

function ShopController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if not child:IsA("ScreenGui") then
			return
		end

		if child.Name == SHOP_UI_NAME then
			self:_bindUI(child)
		elseif child.Name == HUD_UI_NAME then
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
	return self.IsOpenState == true
end

function ShopController:Open()
	if not self.ScreenGui or not self.ScreenGui.Parent or self.IsOpenState then
		return
	end

	self.IsOpenState = true
	self.OpenToken += 1
	local token = self.OpenToken

	-- Reopening: the rows are still parked where the last batch left them.
	for _, wrapper in self.Wrappers do
		wrapper.Visible = false
	end

	self.ScreenGui.Enabled = true
	self:_playPanel(false)

	task.delay(ShopConfig.ITEM_ANIMATION_DELAY, function()
		if self.OpenToken ~= token then
			return
		end

		self:_playItemAnimations()
	end)

	self.Signals.OpenChanged:Fire(true)
end

function ShopController:Close()
	if not self.ScreenGui or not self.IsOpenState then
		return
	end

	self.IsOpenState = false
	self.OpenToken += 1

	if self.PanelTrack then
		-- The panel hides when the reversed animation completes, in _bindUI.
		self:_playPanel(true)
	else
		self.ScreenGui.Enabled = false
	end

	self.Signals.OpenChanged:Fire(false)
end

--[=[
	Drops the player on the teleport marker next to the shop. The marker sits inside
	OPEN_RADIUS, so the proximity check opens the panel right after the landing --
	the button does not open it by hand.

	The client owns its own character, so moving it here is enough; the server sees
	the new position through the usual replication.
]=]
function ShopController:TeleportToShop() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not root then
		return false
	end

	local pivot = getPivot(self:_getMapPart(ShopConfig.TELEPORT_PART_NAME))
	if not pivot then
		return false
	end

	local part = self.MapParts[ShopConfig.TELEPORT_PART_NAME]
	local halfHeight = (part and part:IsA("BasePart")) and (part.Size.Y / 2) or 0

	character:PivotTo(pivot * CFrame.new(0, halfHeight + ShopConfig.TELEPORT_HEIGHT_OFFSET, 0))

	-- Without this the player keeps whatever momentum they had and slides off.
	root.AssemblyLinearVelocity = Vector3.zero

	-- The landing is inside OPEN_RADIUS, so proximity would open the panel on its
	-- own -- except for a player who was already in range and had closed it by hand.
	-- Opening here makes the button behave the same either way.
	self:Open()

	return true
end

function ShopController:Toggle()
	if self.IsOpenState then
		self:Close()
	else
		self:Open()
	end
end

--[=[
	Rebuilds the rows from the config. Only needed when the config changes at runtime.
]=]
function ShopController:Refresh()
	self:_render()
end

function ShopController:construct()
	self:_observeUI()
	self:_watchShards()
	self:_watchProximity()

	Framework:Listen("ShopPurchaseResult", function(itemId : string, success : boolean, reason : string?)
		self.Signals.PurchaseResult:Fire(itemId, success, reason)
	end)
end

function ShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function ShopController:init()
	self.Maid = Maid.new()
	self.UIMaid = Maid.new()
	self.ItemMaid = Maid.new()
	self.HudMaid = Maid.new()

	self.Maid:GiveTask(self.UIMaid)
	self.Maid:GiveTask(self.ItemMaid)
	self.Maid:GiveTask(self.HudMaid)

	self.Wrappers = {}
	self.IsOpenState = false

	-- Marker parts in the map, by name, and the names already warned about.
	self.MapParts = {}
	self.WarnedMissing = {}

	-- Bumped on every open, close and rebind, so a delayed batch that belongs to a
	-- previous open does not fire over the current one.
	self.OpenToken = 0

	self.InRange = false
	self.ProximityClock = 0
end

return ShopController
