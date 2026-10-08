local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Util.Log)

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local UIUtil = require(Util.UIUtil)

local GiftConfig = SharedConfig.GiftConfig
local RobuxShopConfig = SharedConfig.RobuxShopConfig

local Framework = Me.new()
local log = Log.new("GiftController")

local EVENTS = {
	Request = "RequestGift",
	RequestResult = "GiftRequestResult",
	Lookup = "LookupGiftRecipient",
	LookupResult = "GiftLookupResult",
}

local GUI = {
	ScreenGui = "ShopUI",
	Shop = "RobuxShop",
	ShopPanel = "ImageLabel",
	ShopGiftButton = "ImageButton",
	PlayersUI = "GiftUI",
	SelectUI = "GiftSelectUI",
	List = "ScrollingFrame",
	PlayerRow = "Players",
	ItemRow = "GiftItems",
	PassIcon = "GPImg",
	Close = "Close",
	Back = "Back",
}

-- Names of shop elements that stay on screen while gifting is open, besides the
-- GIFT button. Example: { CloseWrapper = true } keeps the shop's X.
local KEEP_VISIBLE = {}

local WAIT_TIMEOUT = 10
local LOOKUP_TIMEOUT = 12
local LOOKUP_SPACING = 3.1
local LOOKUP_MAX_RETRIES = 3
local REQUEST_TIMEOUT = 15
local FLASH_TIME = 1.5
local BUY_SCALE_NAME = "BuyScale"
local PRICE_FALLBACK = "-- ROBUX"

local REASON_TEXT = {
	Cooldown = "WAIT",
	Busy = "WAIT",
	UnknownItem = "UNAVAILABLE",
	InvalidRecipient = "INVALID",
	SelfGift = "NOT YOU",
	NotLoaded = "TRY AGAIN",
	PurchasePending = "PENDING",
	NotFriends = "FRIENDS ONLY",
	RecipientNotFound = "NOT FOUND",
	RecipientNoProfile = "NEW PLAYER",
	AlreadyOwns = "OWNED",
	AlreadyPending = "SENT",
	InboxFull = "INBOX FULL",
	Left = "LEFT",
	ServiceUnavailable = "TRY AGAIN",
	ServerError = "ERROR",
	Timeout = "TIMEOUT",
	Unknown = "ERROR",
}

--[[
	Front end of the gifting system. The GIFT button in the Robux shop opens
	`ShopUI.GiftUI` (every other player in the server) and hides the rest of the
	shop, leaving only the GIFT button on screen. Pressing it again closes gifting
	and brings the shop back. GIFT on a player opens `ShopUI.GiftSelectUI` with
	every gift item that player does not already own.

	The recipient's ownership comes from the server (`LookupGiftRecipient`): the
	client cannot see another player's profile. Owned and already-pending items are
	dropped from the list. The purchase itself is `RequestGift`, which opens
	Roblox's prompt on success.
]]
local GiftController = {
	Controllers = {
		RobuxShopController = {},
	},
}

--[[ HELPERS ]]

local function ensureScale(button : GuiButton)
	if not button:FindFirstChildWhichIsA("UIScale") then
		local scale = Instance.new("UIScale")
		scale.Name = BUY_SCALE_NAME
		scale.Parent = button
	end
end

local function fitList(list : ScrollingFrame, rows : { GuiObject }, rowHeight : number)
	local canvas = math.max(1, #rows * rowHeight)
	list.CanvasSize = UDim2.new(0, 0, canvas, 0)

	for _, row in rows do
		row.Size = UDim2.new(row.Size.X.Scale, row.Size.X.Offset, rowHeight / canvas, 0)
	end
end

local function flash(label : TextLabel?, original : string, text : string)
	if not label or not label.Parent then
		return
	end

	label.Text = text

	task.delay(FLASH_TIME, function()
		if label.Parent and label.Text == text then
			label.Text = original
		end
	end)
end

local function destroyAll(rows : { Instance })
	for _, row in rows do
		row:Destroy()
	end
end

--[[ INTERNAL ]]

--[=[
	Hides the shop around the GIFT button, or puts it back. The panel art fades out
	through `ImageTransparency`, and every other element of the panel and the
	wrapper (the lists, the X) goes `Visible = false`, except `KEEP_VISIBLE`.
	What was visible before is remembered and restored exactly.
]=]
function GiftController:_setShopHidden(hidden : boolean)
	local ui = self.UI
	if not ui or hidden == (self.ShopState ~= nil) then
		return
	end

	local panel = ui.ShopPanel

	if hidden then
		local state = { Panel = panel.ImageTransparency, Visible = {} }

		local function hide(inst : Instance)
			if inst:IsA("GuiObject") and inst ~= ui.GiftButton and not KEEP_VISIBLE[inst.Name] then
				state.Visible[inst] = inst.Visible
				inst.Visible = false
			end
		end

		for _, child in panel:GetChildren() do
			hide(child)
		end

		for _, child in ui.Shop:GetChildren() do
			if child ~= panel then
				hide(child)
			end
		end

		panel.ImageTransparency = 1
		self.ShopState = state
	else
		local state = self.ShopState
		self.ShopState = nil

		for inst, visible in state.Visible do
			if inst.Parent then
				inst.Visible = visible
			end
		end

		if panel.Parent then
			panel.ImageTransparency = state.Panel
		end
	end
end

function GiftController:_giftableKeys(status : any) : { string }
	local owned = typeof(status.Owned) == "table" and status.Owned or {}
	local pending = typeof(status.Pending) == "table" and status.Pending or {}

	local keys = {}
	local seen = {}

	local function consider(itemKey : string, item : any)
		if seen[itemKey] then
			return
		end
		seen[itemKey] = true

		if not GiftConfig.isEnabled(item) then
			return
		end
		if owned[itemKey] or pending[itemKey] then
			return
		end

		table.insert(keys, itemKey)
	end

	for _, entry in RobuxShopConfig.PASSES do
		for itemKey, item in GiftConfig.ITEMS do
			if item.Kind == "Pass" and item.Pass == entry.Pass then
				consider(itemKey, item)
			end
		end
	end

	for _, pack in RobuxShopConfig.PACKS do
		for itemKey, item in GiftConfig.ITEMS do
			if item.Kind == "Pack" and item.Pack == pack.ProductId then
				consider(itemKey, item)
			end
		end
	end

	local rest = {}
	for itemKey in GiftConfig.ITEMS do
		if not seen[itemKey] then
			table.insert(rest, itemKey)
		end
	end
	table.sort(rest)

	for _, itemKey in rest do
		consider(itemKey, GiftConfig.ITEMS[itemKey])
	end

	return keys
end

function GiftController:_iconOf(itemKey : string) : string?
	local ui = self.UI
	local item = GiftConfig.ITEMS[itemKey]
	if not ui or not item then
		return nil
	end

	local frameName = nil

	if item.Kind == "Pass" then
		for _, entry in RobuxShopConfig.PASSES do
			if entry.Pass == item.Pass then
				frameName = entry.Frame
			end
		end
	else
		local pack = RobuxShopConfig.packOfProduct(item.Pack)
		frameName = pack and pack.Frame
	end

	local row = frameName and ui.ShopPanel:FindFirstChild(frameName, true)
	if not row then
		return nil
	end

	local icon = if item.Kind == "Pass" then row:FindFirstChild(GUI.PassIcon) else row:FindFirstChildWhichIsA("ImageLabel")

	if icon and icon:IsA("ImageLabel") then
		return icon.Image
	end

	return nil
end

function GiftController:_priceOf(productId : number, callback : (number) -> ())
	local cached = self.Prices[productId]
	if cached then
		callback(cached)
		return
	end

	task.spawn(function()
		local ok, info = pcall(MarketplaceService.GetProductInfoAsync, MarketplaceService, productId, Enum.InfoType.Product)
		local price = ok and typeof(info) == "table" and info.PriceInRobux or nil

		if typeof(price) == "number" then
			self.Prices[productId] = price
			callback(price)
		end
	end)
end

--[[ PLAYERS LIST ]]

function GiftController:_clearPlayers()
	local ui = self.UI
	if not ui then
		return
	end

	self.PlayerRowMaid:DoCleaning()
	destroyAll(self.PlayerRows)
	self.PlayerRows = {}
	self.PlayerLabels = {}

	fitList(ui.PlayersList, {}, ui.PlayerRowHeight)
end

function GiftController:_renderPlayers()
	local ui = self.UI
	if not ui or self.Mode ~= "Players" then
		return
	end

	self:_clearPlayers()

	local others = {}
	for _, player in Players:GetPlayers() do
		if player ~= Players.LocalPlayer and player.Parent == Players then
			table.insert(others, player)
		end
	end
	table.sort(others, function(a, b)
		return string.lower(a.Name) < string.lower(b.Name)
	end)

	local rows = {}

	for index, player in others do
		local row = ui.PlayerTemplate:Clone()
		row.Name = tostring(player.UserId)
		row.LayoutOrder = index
		row.Visible = true

		local avatar = row:FindFirstChildWhichIsA("ImageLabel")
		local nameLabel = avatar and avatar:FindFirstChildWhichIsA("TextLabel")
		local button = row:FindFirstChildWhichIsA("ImageButton")
		local buttonLabel = button and button:FindFirstChildWhichIsA("TextLabel")

		if nameLabel then
			nameLabel.Text = "@" .. string.upper(player.Name)
		end

		if avatar then
			task.spawn(function()
				local ok, content = pcall(Players.GetUserThumbnailAsync, Players, player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
				if ok and typeof(content) == "string" and avatar.Parent then
					avatar.Image = content
				end
			end)
		end

		if button then
			ensureScale(button)
			ButtonUtil.bindFeedback(button, self.PlayerRowMaid)

			self.PlayerRowMaid:GiveTask(button.Activated:Connect(function()
				self:_selectRecipient(player)
			end))

			self.PlayerLabels[player.UserId] = buttonLabel
		end

		row.Parent = ui.PlayersList
		table.insert(rows, row)
	end

	self.PlayerRows = rows
	fitList(ui.PlayersList, rows, ui.PlayerRowHeight)
	ui.PlayersList.CanvasPosition = Vector2.zero
end

--[[ ITEMS LIST ]]

function GiftController:_clearItems()
	local ui = self.UI
	if not ui then
		return
	end

	self.ItemRowMaid:DoCleaning()
	destroyAll(self.ItemRows)
	self.ItemRows = {}

	fitList(ui.SelectList, {}, ui.ItemRowHeight)
end

function GiftController:_removeItemRow(row : GuiObject)
	local ui = self.UI
	local index = table.find(self.ItemRows, row)
	if not ui or not index then
		return
	end

	table.remove(self.ItemRows, index)
	row:Destroy()

	fitList(ui.SelectList, self.ItemRows, ui.ItemRowHeight)
end

function GiftController:_renderItems(status : any)
	local ui = self.UI
	if not ui or self.Mode ~= "Select" then
		return
	end

	self:_clearItems()

	local rows = {}

	for index, itemKey in self:_giftableKeys(status) do
		local item = GiftConfig.ITEMS[itemKey]

		local row = ui.ItemTemplate:Clone()
		row.Name = itemKey
		row.LayoutOrder = index
		row.Visible = true

		local icon = row:FindFirstChildWhichIsA("ImageLabel")
		local nameLabel = icon and icon:FindFirstChildWhichIsA("TextLabel")
		local button = row:FindFirstChildWhichIsA("ImageButton")
		local priceLabel = button and button:FindFirstChildWhichIsA("TextLabel")

		local image = self:_iconOf(itemKey)
		if icon and image then
			icon.Image = image
		end

		if nameLabel then
			nameLabel.Text = string.upper(GiftConfig.displayName(itemKey) or itemKey)
		end

		if priceLabel then
			priceLabel.Text = PRICE_FALLBACK

			self:_priceOf(item.ProductId, function(price : number)
				if priceLabel.Parent then
					priceLabel.Text = `{UIUtil.formatCommas(price)} ROBUX`
				end
			end)
		end

		if button then
			ensureScale(button)
			ButtonUtil.bindFeedback(button, self.ItemRowMaid)

			self.ItemRowMaid:GiveTask(button.Activated:Connect(function()
				self:_requestGift(itemKey, row, priceLabel)
			end))
		end

		row.Parent = ui.SelectList
		table.insert(rows, row)
	end

	self.ItemRows = rows
	fitList(ui.SelectList, rows, ui.ItemRowHeight)
	ui.SelectList.CanvasPosition = Vector2.zero
end

--[[ REQUESTS ]]

function GiftController:_lookup(player : Player)
	self.RequestId += 1
	local requestId = self.RequestId

	self.LookupPending = { Id = requestId, UserId = player.UserId }

	local wait = math.max(0, LOOKUP_SPACING - (os.clock() - self.LastLookup))

	task.delay(wait, function()
		local pending = self.LookupPending
		if not pending or pending.Id ~= requestId then
			return
		end

		self.LastLookup = os.clock()
		Framework:Fire(EVENTS.Lookup, requestId, player.UserId)
	end)

	task.delay(wait + LOOKUP_TIMEOUT, function()
		local pending = self.LookupPending
		if pending and pending.Id == requestId then
			self.LookupPending = nil
			self:_lookupFailed(player.UserId, "Timeout")
		end
	end)
end

function GiftController:_lookupFailed(userId : number, reason : string?)
	log:StudioWarn(`recipient lookup failed for {userId}: {tostring(reason)}`)

	self:_showPlayers()

	local label = self.PlayerLabels[userId]
	if label then
		flash(label, label.Text, REASON_TEXT[reason or "Unknown"] or REASON_TEXT.Unknown)
	end
end

function GiftController:_onLookupResult(payload : any)
	local pending = self.LookupPending
	if typeof(payload) ~= "table" or not pending or payload.Id ~= pending.Id then
		return
	end

	self.LookupPending = nil

	if not payload.Success then
		local recipient = self.Recipient

		if payload.Reason == "Cooldown" and recipient and self.LookupRetries < LOOKUP_MAX_RETRIES then
			self.LookupRetries += 1
			self.LastLookup = os.clock()
			self:_lookup(recipient)
			return
		end

		self:_lookupFailed(pending.UserId, payload.Reason)
		return
	end

	if not self.Recipient or self.Recipient.UserId ~= pending.UserId then
		return
	end

	self:_renderItems(payload)
end

function GiftController:_requestGift(itemKey : string, row : GuiObject, label : TextLabel?)
	local recipient = self.Recipient
	if not recipient or self.GiftPending or self.Mode ~= "Select" then
		return
	end

	self.RequestId += 1
	local requestId = self.RequestId

	self.GiftPending = {
		Id = requestId,
		Row = row,
		Label = label,
		Original = label and label.Text or "",
	}

	task.delay(REQUEST_TIMEOUT, function()
		local pending = self.GiftPending
		if pending and pending.Id == requestId then
			self.GiftPending = nil
			flash(pending.Label, pending.Original, REASON_TEXT.Timeout)
		end
	end)

	Framework:Fire(EVENTS.Request, requestId, recipient.UserId, itemKey)
end

function GiftController:_onGiftResult(payload : any)
	local pending = self.GiftPending
	if typeof(payload) ~= "table" or not pending or payload.Id ~= pending.Id then
		return
	end

	self.GiftPending = nil

	if payload.Success then
		self:CloseAll()
		return
	end

	local reason = payload.Reason
	flash(pending.Label, pending.Original, REASON_TEXT[reason or "Unknown"] or REASON_TEXT.Unknown)

	if reason == "AlreadyOwns" or reason == "AlreadyPending" then
		task.delay(FLASH_TIME, function()
			self:_removeItemRow(pending.Row)
		end)
	end
end

--[[ NAVIGATION ]]

function GiftController:_showPlayers()
	local ui = self.UI
	if not ui then
		return
	end

	self.Mode = "Players"
	self.Recipient = nil
	self.LookupPending = nil
	self.GiftPending = nil

	self:_setShopHidden(true)
	self:_clearItems()

	ui.Select.Visible = false
	ui.Players.Visible = true

	self:_renderPlayers()
end

function GiftController:_selectRecipient(player : Player)
	local ui = self.UI
	if not ui or not player.Parent then
		return
	end

	self.Mode = "Select"
	self.Recipient = player
	self.GiftPending = nil
	self.LookupRetries = 0

	self:_clearPlayers()
	self:_clearItems()

	ui.Players.Visible = false
	ui.Select.Visible = true

	self:_lookup(player)
end

function GiftController:_onRosterChanged(removed : Player?)
	if self.Mode == "Players" then
		task.delay(0.1, function()
			self:_renderPlayers()
		end)
	elseif self.Mode == "Select" and removed and removed == self.Recipient then
		self:_showPlayers()
	end
end

function GiftController:_watchShopClosing(token : any)
	task.spawn(function()
		local waited = 0
		local robuxShop = self.Controllers.RobuxShopController

		while self.BindToken == token and not (robuxShop and robuxShop.Proximity) and waited < WAIT_TIMEOUT do
			task.wait(0.25)
			waited += 0.25
			robuxShop = self.Controllers.RobuxShopController
		end

		local proximity = robuxShop and robuxShop.Proximity
		if self.BindToken ~= token or not proximity then
			return
		end

		local connection = proximity.Signals.OpenChanged:Connect(function(isOpen : boolean)
			if not isOpen then
				self:CloseAll()
			end
		end)

		self.BindMaid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

function GiftController:_bind(screenGui : ScreenGui)
	local playersUI = screenGui:WaitForChild(GUI.PlayersUI, WAIT_TIMEOUT)
	local selectUI = screenGui:WaitForChild(GUI.SelectUI, WAIT_TIMEOUT)
	local shop = screenGui:WaitForChild(GUI.Shop, WAIT_TIMEOUT)
	local shopPanel = shop and shop:WaitForChild(GUI.ShopPanel, WAIT_TIMEOUT)

	if not playersUI or not selectUI or not shop or not shopPanel then
		log:StudioWarn(`could not find {GUI.PlayersUI}, {GUI.SelectUI} or {GUI.Shop}.{GUI.ShopPanel} in {GUI.ScreenGui}.`)
		return
	end

	local playersList = playersUI:FindFirstChild(GUI.List)
	local playerTemplate = playersList and playersList:FindFirstChild(GUI.PlayerRow)
	local selectList = selectUI:FindFirstChild(GUI.List)
	local itemTemplate = selectList and selectList:FindFirstChild(GUI.ItemRow)
	local giftButton = shopPanel:FindFirstChild(GUI.ShopGiftButton)

	if not playersList or not playerTemplate or not selectList or not itemTemplate then
		log:StudioWarn(`{GUI.PlayersUI} or {GUI.SelectUI} is missing its {GUI.List} or row template.`)
		return
	end

	if not giftButton or not giftButton:IsA("GuiButton") then
		log:StudioWarn(`could not find {GUI.Shop}.{GUI.ShopPanel}.{GUI.ShopGiftButton}; the shop cannot open gifting.`)
		return
	end

	self.BindMaid:DoCleaning()
	self.PlayerRowMaid = Maid.new()
	self.ItemRowMaid = Maid.new()
	self.BindMaid:GiveTask(self.PlayerRowMaid)
	self.BindMaid:GiveTask(self.ItemRowMaid)

	local token = {}
	self.BindToken = token

	self.ShopState = nil
	self.Mode = nil
	self.Recipient = nil
	self.LookupPending = nil
	self.GiftPending = nil
	self.PlayerRows = {}
	self.PlayerLabels = {}
	self.ItemRows = {}

	playerTemplate.Visible = false
	itemTemplate.Visible = false
	playersUI.Visible = false
	selectUI.Visible = false

	for _, list in { playersList, selectList } do
		list.ScrollingDirection = Enum.ScrollingDirection.Y
		list.AutomaticCanvasSize = Enum.AutomaticSize.None

		local layout = list:FindFirstChildWhichIsA("UIListLayout")
		if layout then
			layout.SortOrder = Enum.SortOrder.LayoutOrder
		end
	end

	local function rowHeightOf(list : ScrollingFrame, template : GuiObject) : number
		local canvasScale = list.CanvasSize.Y.Scale
		if canvasScale <= 0 then
			canvasScale = 1
		end

		return template.Size.Y.Scale * canvasScale
	end

	self.UI = {
		Players = playersUI,
		Select = selectUI,
		Shop = shop,
		ShopPanel = shopPanel,
		GiftButton = giftButton,
		PlayersList = playersList,
		SelectList = selectList,
		PlayerTemplate = playerTemplate,
		ItemTemplate = itemTemplate,
		PlayerRowHeight = rowHeightOf(playersList, playerTemplate),
		ItemRowHeight = rowHeightOf(selectList, itemTemplate),
	}

	ensureScale(giftButton)
	ButtonUtil.bindFeedback(giftButton, self.BindMaid)

	self.BindMaid:GiveTask(giftButton.Activated:Connect(function()
		self:Toggle()
	end))

	self.BindMaid:GiveTask(shop:GetPropertyChangedSignal("Visible"):Connect(function()
		if not shop.Visible then
			self:CloseAll()
		end
	end))

	local back = selectUI:FindFirstChild(GUI.Back, true)
	if back and back:IsA("GuiButton") then
		self.BindMaid:GiveTask(back.Activated:Connect(function()
			self:_showPlayers()
		end))
	end

	for _, root in { playersUI, selectUI } do
		local close = root:FindFirstChild(GUI.Close, true)
		if close and close:IsA("GuiButton") then
			self.BindMaid:GiveTask(close.Activated:Connect(function()
				self:CloseAll()
			end))
		end
	end

	self:_clearPlayers()
	self:_clearItems()
	self:_watchShopClosing(token)
end

function GiftController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == GUI.ScreenGui then
			task.spawn(self._bind, self, child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
end

--[[ EXTERNAL ]]

function GiftController:IsOpen() : boolean
	return self.Mode ~= nil
end

function GiftController:Open()
	if self.UI then
		self:_showPlayers()
	end
end

function GiftController:CloseAll()
	local ui = self.UI

	self.Mode = nil
	self.Recipient = nil
	self.LookupPending = nil
	self.GiftPending = nil

	self:_setShopHidden(false)

	if ui then
		ui.Players.Visible = false
		ui.Select.Visible = false
	end
end

function GiftController:Toggle()
	if self:IsOpen() then
		self:CloseAll()
	else
		self:Open()
	end
end

function GiftController:construct()
	Framework:Listen(EVENTS.LookupResult, function(payload : any)
		self:_onLookupResult(payload)
	end)

	Framework:Listen(EVENTS.RequestResult, function(payload : any)
		self:_onGiftResult(payload)
	end)

	self.Maid:GiveTask(Players.PlayerAdded:Connect(function()
		self:_onRosterChanged(nil)
	end))

	self.Maid:GiveTask(Players.PlayerRemoving:Connect(function(player : Player)
		self:_onRosterChanged(player)
	end))

	self:_observeUI()
end

function GiftController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function GiftController:init()
	self.Maid = Maid.new()
	self.BindMaid = Maid.new()
	self.Maid:GiveTask(self.BindMaid)

	self.PlayerRowMaid = Maid.new()
	self.ItemRowMaid = Maid.new()

	self.UI = nil
	self.Mode = nil
	self.Recipient = nil
	self.ShopState = nil
	self.BindToken = nil

	self.PlayerRows = {}
	self.PlayerLabels = {}
	self.ItemRows = {}
	self.Prices = {}

	self.RequestId = 0
	self.LastLookup = -math.huge
	self.LookupRetries = 0
	self.LookupPending = nil
	self.GiftPending = nil
end

return GiftController