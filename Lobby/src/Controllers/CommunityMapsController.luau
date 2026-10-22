local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local TeleportService = game:GetService("TeleportService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("CommunityMapsController")

local PortalConfig = SharedConfig.PortalConfig

--[[ CONSTANTS ]]
local REQUEST_EVENT = "CommunityMapsRequest"
local RESPONSE_EVENT = "CommunityMapsResponse"

local CHOOSE_MAPS_UI_NAME = "ChooseMaps"
local PANEL_NAME = "CommunityMaps"

local SELECTION_NAME = "MapSelection"
local SCROLL_NAME = "ScrollingFrame"
local TEMPLATE_NAME = "MapWrapper"
local BANNER_NAME = "MapBanner"
local SEARCH_NAME = "Search"

local ENTRY_NAME_PREFIX = "Map_"
local STATUS_NAME = "Status"

-- The tabs, in `MapSelection`. `Tab` is the name the server knows.
local TABS = {
	{ Tab = "Featured", Button = "FeaturedMapsButton" },
	{ Tab = "YourMaps", Button = "YourMapsButton" },
	{ Tab = "Favorites", Button = "FavoriteMapsButton" },
}

--[[
	What the list sorts by (`FilterTypes`) and in which direction (`FilterSortTypes`).
	The first wrapper of each frame is the template for its buttons; the copies the
	designer left are dropped. `Stat` must be one of `Config.CommunityMaps.STATS` on
	the server, which falls back to its default otherwise.
]]
local FILTER_TYPES_NAME = "FilterTypes"
local FILTER_WRAPPER_NAME = "FilterWrapper"
local SORT_TYPES_NAME = "FilterSortTypes"
local SORT_WRAPPER_NAME = "SortWrapper"

local STATS = {
	{ Stat = "Likes", Label = "Likes" },
	{ Stat = "Visits", Label = "Visits" },
	{ Stat = "Favorites", Label = "Favorites" },
	{ Stat = "Plays", Label = "Plays" },
}

local SORTS = {
	{ Ascending = false, Label = "Descending" },
	{ Ascending = true, Label = "Ascending" },
}

-- What a list opens with.
local DEFAULT_TAB = "Featured"
local DEFAULT_STAT = "Likes"
local DEFAULT_ASCENDING = false

-- The two looks of each toggle.
local LIKE_IMAGE = "rbxassetid://114169879395476"
local LIKED_IMAGE = "rbxassetid://122840204943561"
local FAVORITE_IMAGE = "rbxassetid://102349663952223"
local FAVORITED_IMAGE = "rbxassetid://131213085052883"
local FILTER_IMAGE = "rbxassetid://83927112071307"
local FILTER_SELECTED_IMAGE = "rbxassetid://72098468299979"

-- `MapDetails`, the right column.
local DETAILS_NAME = "MapDetails"
local DETAIL_IMAGE_NAME = "MapImage"
local DETAIL_OBJECTS_NAME = "ObjectCount"
local DETAIL_VISITS_NAME = "VisitCount"
local DETAIL_FAVORITES_NAME = "FavoriteCount"
local DETAIL_CREATOR_NAME = "Creator"
local DETAIL_DESCRIPTION_NAME = "Description"
local PLAY_NAME = "PlayButton"
local EDIT_NAME = "EditButton"

local NO_DESCRIPTION = "No description."

--[[
	The player-count stepper at the top of the panel: how many players the group PLAY
	opens will take. An authored `CommunityMaps.PlayerCount` frame is used when there is
	one (with `LowerPlrs`, `MaxPlrs`, `IncreasePlrs` inside, the names of the vanilla
	panel); otherwise one is built from the vanilla panel's own controls, so both look
	the same.
]]
local COUNT_FRAME_NAME = "PlayerCount"
local COUNT_LABEL_NAME = "MaxPlrs"
local COUNT_LOWER_NAME = "LowerPlrs"
local COUNT_INCREASE_NAME = "IncreasePlrs"
local COUNT_TITLE_NAME = "PlrText"
local VANILLA_PANEL_NAME = "Lobby"

-- Where the built stepper sits: centered on the top edge of `MapDetails`, like the
-- tabs sit on the top edge of `MapSelection`.
local COUNT_FRAME_SIZE = UDim2.fromScale(0.5, 0.075)
local COUNT_FRAME_POSITION = UDim2.fromScale(0.5, 0)

-- The Game could not build the map the group went to (`MapService:returnToLobby`).
local FAILED_TEXT = "THAT COMMUNITY MAP COULD NOT BE LOADED"
local FAILED_PRIORITY = 1
local FAILED_HOLD = 6

local STATUS_TEXT = {
	Loading = "Loading...",
	Empty = "No maps here yet.",
	Failed = "Could not load the maps. Try again.",
}

-- How close to the bottom of the list, in pixels, the next page starts loading.
local NEXT_PAGE_MARGIN = 120

-- An answer that never came is given up on after this long.
local REQUEST_TIMEOUT = 15

-- A request the server turned down for being one too many is sent again after this.
local BUSY_RETRY = 0.5

-- Same curves as the vanilla maps panel, so both read as the same UI.
local OPEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local TAB_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local OPEN_FROM_SCALE = 0.85
local CLOSE_TO_SCALE = 0.9

-- The chosen tab grows a little.
local TAB_SELECTED_SCALE = 1.1
local TAB_SCALE_NAME = "TabScale"

local HIDE_REASON = "CommunityMaps"

--[=[
	Owns `ChooseMaps.CommunityMaps`: the maps players published from the Map
	Editor, opened by walking up to a portal in `Workspace.Map.BuildPortals`
	(`PortalController` decides when).

	The left column lists one tab at a time (Featured, Your Maps, Favorites),
	sorted by the chosen counter and direction and filtered by the search box,
	twenty maps per page; scrolling to the bottom brings the next page. The arrow
	on a row fills the right column with that map's details, which stay while the
	player switches tabs. Like and Favorite on a row change at once and roll back
	if the server refuses.

	Everything comes from `CommunityMapService` through one request/response pair
	of events carrying a request id: Warp does not order events, so an answer is
	matched to its request, and a list answer for a tab or filter that is no longer
	on screen is dropped.

	PLAY fires `PlayRequested(key, playerCount)`; `PortalController` turns it into a
	group on the build portal the player stands at, and the Game builds the map. The
	edit button (own maps only) asks the server to send the player to the Map Editor
	with that map open.

	See docs/lobby/community-maps.md.
]=]
local CommunityMapsController = {
	Controllers = {
		InterfaceController = {},
		DataController = {},
		GamepadController = {},
		WarningController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),
		-- (mapKey : string, playerCount : number) -- PLAY on the selected map
		PlayRequested = Signal.new(),
		-- (mapKey : string) -- the edit button, only on the player's own maps
		EditRequested = Signal.new(),
	},
}

--[[ INTERNAL ]]

local function formatCount(value : number) : string
	value = math.max(0, math.floor(tonumber(value) or 0))
	if value < 1000 then
		return tostring(value)
	end

	for _, unit in { { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } } do
		if value >= unit[1] then
			local scaled = value / unit[1]
			local text = if scaled < 10 then string.format("%.1f", math.floor(scaled * 10) / 10) else tostring(math.floor(scaled))
			return (string.gsub(text, "%.0$", "")) .. unit[2]
		end
	end

	return tostring(value)
end

--[[
	Connects a click. `Activated` does not fire on a button with `Active = false`,
	and the authored buttons of this panel came that way, so the button is switched
	on here instead of trusting the template.
]]
local function onClick(maid, button : GuiButton, callback : () -> ())
	button.Active = true
	maid:GiveTask(button.Activated:Connect(callback))
end

local function setText(label : Instance?, text : string)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

function CommunityMapsController:_playTween(object : Instance, info : TweenInfo, goal : { [string] : any }, maid) : Tween
	local tween = TweenService:Create(object, info, goal)

	;(maid or self.TweenMaid):GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
	return tween
end

--[[ NETWORK ]]

--[=[
	Sends a request and calls `callback(ok, data, reason)` with its answer, or with
	`false, "Timeout"` when none came.
]=]
function CommunityMapsController:_request(action : string, payload : { [string] : any }, callback : ((boolean, any, string?) -> ())?)
	self.RequestId += 1
	local requestId = self.RequestId

	if callback then
		self.Callbacks[requestId] = callback

		task.delay(REQUEST_TIMEOUT, function()
			local pending = self.Callbacks[requestId]
			if pending then
				self.Callbacks[requestId] = nil
				pending(false, nil, "Timeout")
			end
		end)
	end

	Framework:Fire(REQUEST_EVENT, requestId, action, payload)
end

function CommunityMapsController:_onResponse(response : any)
	if typeof(response) ~= "table" then
		return
	end

	local callback = self.Callbacks[response.Id]
	if not callback then
		return
	end

	self.Callbacks[response.Id] = nil
	callback(response.Ok == true, response.Data, response.Reason)
end

--[[ PLAYER STATE ]]

--- The player's own `PlayerMaps` list (`Likes` or `Favorites`) from the replica.
function CommunityMapsController:_profileList(name : string) : { [string] : any }
	local replica = self.Replica
	local playerMaps = replica and replica.Data and replica.Data.PlayerMaps
	local list = typeof(playerMaps) == "table" and playerMaps[name]

	return if typeof(list) == "table" then list else {}
end

--[[
	Whether the player likes / favorited a map. A click the server has not
	answered yet (or answered) wins over the replica, which may still be on its way.
]]
function CommunityMapsController:_isLiked(key : string) : boolean
	local override = self.LikeOverrides[key]
	if override ~= nil then
		return override
	end

	return self:_profileList("Likes")[key] ~= nil
end

function CommunityMapsController:_isFavorite(key : string) : boolean
	local override = self.FavoriteOverrides[key]
	if override ~= nil then
		return override
	end

	return self:_profileList("Favorites")[key] ~= nil
end

--[[ LIST ]]

function CommunityMapsController:_setStatus(state : string?)
	local label = self.StatusLabel
	if not label then
		return
	end

	label.Visible = state ~= nil
	label.Text = state and STATUS_TEXT[state] or ""
end

function CommunityMapsController:_clearRows()
	self.RowMaid:DoCleaning()
	self.Rows = {}
	self.RowCount = 0
end

function CommunityMapsController:_renderRow(row)
	local view = row.View

	setText(row.Likes, formatCount(view.Likes))

	if row.LikeButton then
		row.LikeButton.Image = if self:_isLiked(view.Key) then LIKED_IMAGE else LIKE_IMAGE
	end

	if row.FavoriteButton then
		row.FavoriteButton.Image = if self:_isFavorite(view.Key) then FAVORITED_IMAGE else FAVORITE_IMAGE
	end
end

function CommunityMapsController:_addRow(view)
	local template = self.Template
	local scroll = self.Scroll
	if not template or not scroll then
		return
	end

	local entry = template:Clone()
	entry.Name = ENTRY_NAME_PREFIX .. view.Key
	self.RowCount += 1
	entry.LayoutOrder = self.RowCount
	entry.Visible = true

	local banner = entry:FindFirstChild(BANNER_NAME)
	local find = function(name : string) : Instance?
		return banner and banner:FindFirstChild(name)
	end

	setText(find("MapName"), view.Name)

	local row = {
		View = view,
		Entry = entry,
		Likes = find("Likes"),
		LikeButton = find("LikeButton"),
		FavoriteButton = find("FavoriteButton"),
	}

	if row.LikeButton and row.LikeButton:IsA("GuiButton") then
		onClick(self.RowMaid, row.LikeButton, function()
			self:ToggleLike(view.Key)
		end)
	end

	if row.FavoriteButton and row.FavoriteButton:IsA("GuiButton") then
		onClick(self.RowMaid, row.FavoriteButton, function()
			self:ToggleFavorite(view.Key)
		end)
	end

	local expand = find("ExpandDetailsButton")
	if expand and expand:IsA("GuiButton") then
		onClick(self.RowMaid, expand, function()
			self:SelectMap(view.Key)
		end)
	end

	self:_renderRow(row)

	entry.Parent = scroll
	self.RowMaid:GiveTask(entry)
	self.Rows[view.Key] = row
end

--[[
	Starts the list over for the current tab, filter, and search. Bumping
	`ListToken` is what makes any answer still in flight for the old list be
	dropped when it arrives.
]]
function CommunityMapsController:_reload()
	self.ListToken += 1
	self.Page = 0
	self.HasMore = true
	self.LoadingToken = nil

	self:_clearRows()
	self:_loadNextPage()
end

function CommunityMapsController:_loadNextPage()
	if not self.HasMore or self.LoadingToken == self.ListToken or not self.IsOpenState then
		return
	end

	local token = self.ListToken
	local page = self.Page + 1
	self.LoadingToken = token

	if page == 1 then
		self:_setStatus("Loading")
	end

	local function send()
		self:_request("List", {
			Tab = self.Tab,
			Stat = self.Stat,
			Ascending = self.Ascending,
			Search = self.Search,
			Page = page,
		}, function(ok, data, reason)
			if token ~= self.ListToken then
				return
			end

			if not ok and reason == "Busy" then
				task.delay(BUSY_RETRY, function()
					if token == self.ListToken then
						send()
					end
				end)
				return
			end

			self.LoadingToken = nil

			if not ok or typeof(data) ~= "table" or typeof(data.Maps) ~= "table" then
				if page == 1 then
					self:_setStatus("Failed")
				end
				self.HasMore = false
				return
			end

			self.Page = page
			self.HasMore = data.HasMore == true

			for _, view in data.Maps do
				if typeof(view) == "table" and typeof(view.Key) == "string" and not self.Rows[view.Key] then
					self:_addRow(view)
				end
			end

			self:_setStatus(if self.RowCount == 0 then "Empty" else nil)

			-- A short page may not fill the frame, so nothing would scroll to ask for more.
			task.defer(function()
				self:_checkScroll()
			end)
		end)
	end

	send()
end

function CommunityMapsController:_checkScroll()
	local scroll = self.Scroll
	if not scroll or not self.HasMore then
		return
	end

	local bottom = scroll.CanvasPosition.Y + scroll.AbsoluteWindowSize.Y
	if bottom >= scroll.AbsoluteCanvasSize.Y - NEXT_PAGE_MARGIN then
		self:_loadNextPage()
	end
end

--[[ DETAILS ]]

function CommunityMapsController:_renderDetails()
	local details = self.Details
	if not details then
		return
	end

	local view = self.SelectedView

	setText(details:FindFirstChild(DETAIL_OBJECTS_NAME), if view then formatCount(view.Count) else "")
	setText(details:FindFirstChild(DETAIL_VISITS_NAME), if view then formatCount(view.Visits) else "")
	setText(details:FindFirstChild(DETAIL_FAVORITES_NAME), if view then formatCount(view.Favorites) else "")
	setText(details:FindFirstChild(DETAIL_CREATOR_NAME), if view then view.Creator or "" else "")
	setText(details:FindFirstChild(DETAIL_DESCRIPTION_NAME), if view then (if view.Description ~= "" then view.Description else NO_DESCRIPTION) else "")

	local play = details:FindFirstChild(PLAY_NAME)
	if play and play:IsA("GuiObject") then
		play.Visible = view ~= nil
	end

	-- Only the owner can open their map in the editor.
	local edit = details:FindFirstChild(EDIT_NAME)
	if edit and edit:IsA("GuiObject") then
		edit.Visible = view ~= nil and view.Owner == Players.LocalPlayer.UserId
	end
end

--[[ FILTERS ]]

--[[
	Rebuilds one button per option from the frame's first wrapper, labelled from
	`options`. `onPick(option)` runs on click. Answers the buttons by option index.
]]
function CommunityMapsController:_buildOptions(frame : Instance?, wrapperName : string, options, onPick) : { ImageButton }
	local buttons = {}
	if not frame then
		return buttons
	end

	local template = frame:FindFirstChild(wrapperName)
	if not template then
		log:StudioWarn(`could not find {wrapperName} in {frame:GetFullName()}.`)
		return buttons
	end

	for _, child in frame:GetChildren() do
		if child.Name == wrapperName and child ~= template then
			child:Destroy()
		end
	end

	template.Parent = nil
	self.UiMaid:GiveTask(template)

	for index, option in options do
		local wrapper = template:Clone()
		wrapper.LayoutOrder = index

		local button = wrapper:FindFirstChildWhichIsA("ImageButton")
		if button then
			setText(button:FindFirstChildWhichIsA("TextLabel"), option.Label)
			onClick(self.UiMaid, button, function()
				onPick(option)
			end)
			buttons[index] = button
		end

		wrapper.Parent = frame
	end

	return buttons
end

function CommunityMapsController:_renderFilters()
	for index, button in self.StatButtons do
		button.Image = if STATS[index].Stat == self.Stat then FILTER_SELECTED_IMAGE else FILTER_IMAGE
	end

	for index, button in self.SortButtons do
		button.Image = if SORTS[index].Ascending == self.Ascending then FILTER_SELECTED_IMAGE else FILTER_IMAGE
	end
end

function CommunityMapsController:_renderTabs(immediate : boolean?)
	self.TabMaid:DoCleaning()

	for tab, scale in self.TabScales do
		local goal = if tab == self.Tab then TAB_SELECTED_SCALE else 1
		if immediate then
			scale.Scale = goal
		elseif scale.Scale ~= goal then
			self:_playTween(scale, TAB_INFO, { Scale = goal }, self.TabMaid)
		end
	end
end

--[[ PLAYER COUNT ]]

--[=[
	Builds the stepper from the vanilla panel's controls (`ChooseMaps.Lobby`) when the
	panel has none of its own. Each part keeps its place when an arrow hides at either
	end, so nothing jumps.
]=]
function CommunityMapsController:_buildPlayerCount(panel : GuiObject) : Frame
	local frame = Instance.new("Frame")
	frame.Name = COUNT_FRAME_NAME
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Size = COUNT_FRAME_SIZE
	frame.Position = COUNT_FRAME_POSITION
	frame.ZIndex = 5

	local vanilla = self.ScreenGui:FindFirstChild(VANILLA_PANEL_NAME)

	local function part(name : string, class : string, x : number, width : number, text : string?) : GuiObject
		local source = vanilla and vanilla:FindFirstChild(name)
		local object = if source and source:IsA(class) then source:Clone() else Instance.new(class)

		object.Name = name
		object.AnchorPoint = Vector2.new(0.5, 0.5)
		object.Position = UDim2.fromScale(x, 0.5)
		object.Size = UDim2.fromScale(width, 1)
		object.Visible = true
		object.ZIndex = 5

		if not source then
			object.BackgroundTransparency = 1
			object.TextScaled = true
			object.TextColor3 = Color3.new(1, 1, 1)
			object.Text = text or ""
		end

		object.Parent = frame
		return object
	end

	part(COUNT_TITLE_NAME, "TextLabel", 0.25, 0.48, "PLAYERS")
	part(COUNT_LOWER_NAME, "TextButton", 0.6, 0.14, "<")
	part(COUNT_LABEL_NAME, "TextLabel", 0.76, 0.16, "1")
	part(COUNT_INCREASE_NAME, "TextButton", 0.92, 0.14, ">")

	local details = panel:FindFirstChild(DETAILS_NAME)
	frame.Parent = details or panel

	return frame
end

function CommunityMapsController:_bindPlayerCount(panel : GuiObject)
	local frame = panel:FindFirstChild(COUNT_FRAME_NAME, true)
	if not frame then
		frame = self:_buildPlayerCount(panel)
	end

	self.CountLabel = frame:FindFirstChild(COUNT_LABEL_NAME)
	self.LowerButton = frame:FindFirstChild(COUNT_LOWER_NAME)
	self.IncreaseButton = frame:FindFirstChild(COUNT_INCREASE_NAME)

	if self.LowerButton and self.LowerButton:IsA("GuiButton") then
		onClick(self.UiMaid, self.LowerButton, function()
			self:_stepCount(-1)
		end)
	end

	if self.IncreaseButton and self.IncreaseButton:IsA("GuiButton") then
		onClick(self.UiMaid, self.IncreaseButton, function()
			self:_stepCount(1)
		end)
	end
end

function CommunityMapsController:_renderCount()
	local count = self.PlayerCount

	setText(self.CountLabel, tostring(count))

	-- At either end the step that cannot happen is gone, like the vanilla panel.
	if self.LowerButton then
		self.LowerButton.Visible = count > PortalConfig.MIN_PLAYERS
	end

	if self.IncreaseButton then
		self.IncreaseButton.Visible = count < PortalConfig.MAX_PLAYERS
	end
end

function CommunityMapsController:_stepCount(delta : number)
	self.PlayerCount = math.clamp(self.PlayerCount + delta, PortalConfig.MIN_PLAYERS, PortalConfig.MAX_PLAYERS)
	self:_renderCount()
end

--[[ OPEN / CLOSE ]]

--- Whether another panel of the same ScreenGui (the vanilla list) is on screen.
function CommunityMapsController:_otherPanelVisible() : boolean
	for _, child in self.ScreenGui:GetChildren() do
		if child ~= self.Panel and child:IsA("GuiObject") and child.Visible then
			return true
		end
	end

	return false
end

function CommunityMapsController:_setOpen(open : boolean)
	local panel = self.Panel
	if not panel or not panel.Parent or not self.PanelScale then
		return
	end

	if open == self.IsOpenState then
		return
	end

	self.IsOpenState = open
	self.TweenMaid:DoCleaning()

	local InterfaceController = self.Controllers.InterfaceController

	if open then
		-- Every opening starts over, like the vanilla panel.
		self.Tab = DEFAULT_TAB
		self.Stat = DEFAULT_STAT
		self.Ascending = DEFAULT_ASCENDING
		self.Search = ""
		self.Selected = nil
		self.SelectedView = nil
		self.PlayerCount = PortalConfig.MIN_PLAYERS

		if self.SearchBox then
			self.SearchBox.Text = ""
		end

		self:_renderCount()
		self:_renderTabs(true)
		self:_renderFilters()
		self:_renderDetails()

		InterfaceController:Hide(HIDE_REASON, { Except = { CHOOSE_MAPS_UI_NAME } })
		InterfaceController:SetEnabled(self.ScreenGui, true)

		self.PanelScale.Scale = OPEN_FROM_SCALE
		panel.Visible = true

		self:_playTween(self.PanelScale, OPEN_INFO, { Scale = 1 })

		self:_reload()
	else
		InterfaceController:Show(HIDE_REASON)

		-- No list loading behind a closed panel.
		self.ListToken += 1
		self.LoadingToken = nil

		local tween = self:_playTween(self.PanelScale, CLOSE_INFO, { Scale = CLOSE_TO_SCALE })
		tween.Completed:Once(function(state : Enum.PlaybackState)
			if state ~= Enum.PlaybackState.Completed or self.IsOpenState then
				return
			end

			panel.Visible = false
			self:_clearRows()

			-- The vanilla panel shares the ScreenGui: it may have opened meanwhile.
			if not self:_otherPanelVisible() then
				InterfaceController:SetEnabled(self.ScreenGui, false)
			end
		end)
	end

	self.Signals.OpenChanged:Fire(open)
end

--[[ BINDING ]]

--[=[
	Binds to a ChooseMaps instance. The ScreenGui has ResetOnSpawn enabled, so this
	runs again for every fresh copy the engine parents into PlayerGui.
]=]
function CommunityMapsController:_bindUI(screenGui : ScreenGui)
	self.UiMaid:DoCleaning()
	self.TweenMaid:DoCleaning()
	self.TabMaid:DoCleaning()
	self:_clearRows()

	local panel = screenGui:WaitForChild(PANEL_NAME, 10)
	local selection = panel and panel:WaitForChild(SELECTION_NAME, 10)
	local scroll = selection and selection:WaitForChild(SCROLL_NAME, 10)
	local template = scroll and scroll:WaitForChild(TEMPLATE_NAME, 10)

	if not panel or not selection or not scroll or not template then
		log:StudioWarn(`could not find {CHOOSE_MAPS_UI_NAME}.{PANEL_NAME}.{SELECTION_NAME}.{SCROLL_NAME}.{TEMPLATE_NAME}.`)
		return
	end

	local panelScale = panel:FindFirstChildWhichIsA("UIScale")
	if not panelScale then
		panelScale = Instance.new("UIScale")
		panelScale.Name = "PanelScale"
		panelScale.Parent = panel
	end

	self.ScreenGui = screenGui
	self.Panel = panel
	self.PanelScale = panelScale
	self.Scroll = scroll
	self.Details = panel:FindFirstChild(DETAILS_NAME)

	-- The template leaves the list; rows are clones of it.
	template.Parent = nil
	self.Template = template
	self.UiMaid:GiveTask(template)

	-- Loading / empty / error line, built here and styled after the template's name.
	local nameLabel = template:FindFirstChild("MapName", true)
	local status = Instance.new("TextLabel")
	status.Name = STATUS_NAME
	status.Size = template.Size
	status.BackgroundTransparency = 1
	status.TextScaled = true
	status.TextColor3 = Color3.new(1, 1, 1)
	status.LayoutOrder = 2 ^ 30
	status.Visible = false
	if nameLabel and nameLabel:IsA("TextLabel") then
		status.FontFace = nameLabel.FontFace
	end
	status.Parent = scroll
	self.StatusLabel = status
	self.UiMaid:GiveTask(status)

	self.UiMaid:GiveTask(scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		self:_checkScroll()
	end))

	-- Tabs
	self.TabScales = {}
	for _, info in TABS do
		local button = selection:FindFirstChild(info.Button)
		if not button or not button:IsA("GuiButton") then
			log:StudioWarn(`could not find the {info.Button} tab.`)
			continue
		end

		local scale = button:FindFirstChild(TAB_SCALE_NAME)
		if not scale then
			scale = Instance.new("UIScale")
			scale.Name = TAB_SCALE_NAME
			scale.Parent = button
		end
		self.TabScales[info.Tab] = scale

		onClick(self.UiMaid, button, function()
			self:SetTab(info.Tab)
		end)
	end

	-- Filters
	self.StatButtons = self:_buildOptions(selection:FindFirstChild(FILTER_TYPES_NAME), FILTER_WRAPPER_NAME, STATS, function(option)
		self:SetFilter(option.Stat, self.Ascending)
	end)
	self.SortButtons = self:_buildOptions(selection:FindFirstChild(SORT_TYPES_NAME), SORT_WRAPPER_NAME, SORTS, function(option)
		self:SetFilter(self.Stat, option.Ascending)
	end)

	-- Search: applied when the box loses focus (Enter on a keyboard, Done on a phone).
	local search = selection:FindFirstChild(SEARCH_NAME)
	local box = search and search:FindFirstChildWhichIsA("TextBox")
	self.SearchBox = box
	if box then
		self.UiMaid:GiveTask(box.FocusLost:Connect(function()
			self:SetSearch(box.Text)
		end))
	end

	-- Details
	local details = self.Details
	local play = details and details:FindFirstChild(PLAY_NAME)
	if play and play:IsA("GuiButton") then
		onClick(self.UiMaid, play, function()
			if self.Selected then
				self.Signals.PlayRequested:Fire(self.Selected, self.PlayerCount)
			end
		end)
	elseif details then
		log:StudioWarn(`{DETAILS_NAME}.{PLAY_NAME} is missing or is not a button.`)
	end

	local edit = details and details:FindFirstChild(EDIT_NAME)
	if edit and edit:IsA("GuiButton") then
		onClick(self.UiMaid, edit, function()
			if self.Selected then
				self:EditMap(self.Selected)
			end
		end)
	end

	self:_bindPlayerCount(panel)

	-- Starts closed; a respawn with the panel open hands the screen back too.
	self.IsOpenState = false
	self.PlayerCount = PortalConfig.MIN_PLAYERS
	self.ListToken += 1
	self.LoadingToken = nil
	self.Selected = nil
	self.SelectedView = nil
	self.Tab = DEFAULT_TAB
	self.Stat = DEFAULT_STAT
	self.Ascending = DEFAULT_ASCENDING

	self.Controllers.InterfaceController:Show(HIDE_REASON)

	self:_renderTabs(true)
	self:_renderFilters()
	self:_renderDetails()
	self:_renderCount()

	panel.Visible = false
end

function CommunityMapsController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child.Name ~= CHOOSE_MAPS_UI_NAME or not child:IsA("ScreenGui") then
			return
		end

		self:_bindUI(child)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[=[
	Holds the replica and repaints the rows when the player's likes or favorites
	change, which also covers a change made from another panel or server.
]=]
function CommunityMapsController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		local connection = replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "PlayerMaps" then
				return
			end

			for _, row in self.Rows do
				self:_renderRow(row)
			end
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

function CommunityMapsController:IsOpen() : boolean
	return self.IsOpenState == true
end

function CommunityMapsController:Open()
	self:_setOpen(true)
end

function CommunityMapsController:Close()
	self:_setOpen(false)
end

function CommunityMapsController:Toggle()
	self:_setOpen(not self.IsOpenState)
end

--- The key of the map in the details column, or nil.
function CommunityMapsController:GetSelected() : string?
	return self.Selected
end

--- Switches tab and reloads the list. The filters and search carry over.
function CommunityMapsController:SetTab(tab : string)
	if tab == self.Tab then
		return
	end

	self.Tab = tab
	self:_renderTabs()
	self:_reload()
end

function CommunityMapsController:SetFilter(stat : string, ascending : boolean)
	if stat == self.Stat and ascending == self.Ascending then
		return
	end

	self.Stat = stat
	self.Ascending = ascending
	self:_renderFilters()
	self:_reload()
end

function CommunityMapsController:SetSearch(text : string)
	local search = string.gsub(text, "^%s*(.-)%s*$", "%1")
	if search == self.Search then
		return
	end

	self.Search = search
	self:_reload()
end

--- Shows a listed map in the details column and counts the visit.
function CommunityMapsController:SelectMap(key : string)
	local row = self.Rows[key]
	if not row then
		return
	end

	self.Selected = key
	self.SelectedView = row.View
	self:_renderDetails()

	if not self.Visited[key] then
		self.Visited[key] = true
		row.View.Visits = (row.View.Visits or 0) + 1
		self:_renderDetails()

		self:_request("Visit", { Key = key })
	end
end

--[=[
	Flips the like on a map: the row changes now, and goes back if the server says no.
]=]
function CommunityMapsController:ToggleLike(key : string)
	local row = self.Rows[key]
	local liked = not self:_isLiked(key)

	self.LikeOverrides[key] = liked
	if row then
		row.View.Likes = math.max(0, (row.View.Likes or 0) + (if liked then 1 else -1))
		self:_renderRow(row)
	end

	self:_request("Like", { Key = key, Value = liked }, function(ok, state)
		if self.LikeOverrides[key] ~= liked then
			-- Clicked again meanwhile: that request has the final say.
			return
		end

		if ok then
			self.LikeOverrides[key] = state == true
			return
		end

		self.LikeOverrides[key] = not liked
		local current = self.Rows[key]
		if current then
			current.View.Likes = math.max(0, (current.View.Likes or 0) + (if liked then -1 else 1))
			self:_renderRow(current)
		end
	end)
end

--- Flips the favorite on a map, the same way as `ToggleLike`.
function CommunityMapsController:ToggleFavorite(key : string)
	local row = self.Rows[key]
	local favorite = not self:_isFavorite(key)

	self.FavoriteOverrides[key] = favorite
	if row then
		row.View.Favorites = math.max(0, (row.View.Favorites or 0) + (if favorite then 1 else -1))
		self:_renderRow(row)
		self:_renderDetails()
	end

	self:_request("Favorite", { Key = key, Value = favorite }, function(ok, state)
		if self.FavoriteOverrides[key] ~= favorite then
			return
		end

		if ok then
			self.FavoriteOverrides[key] = state == true
			return
		end

		self.FavoriteOverrides[key] = not favorite
		local current = self.Rows[key]
		if current then
			current.View.Favorites = math.max(0, (current.View.Favorites or 0) + (if favorite then -1 else 1))
			self:_renderRow(current)
			self:_renderDetails()
		end
	end)
end

--[=[
	Sends the player to the Map Editor with their map open. The server checks the map
	is theirs and that this universe has the editor.
]=]
function CommunityMapsController:EditMap(key : string)
	self.Signals.EditRequested:Fire(key)
	self:_request("Edit", { Key = key })
end

--[=[
	Tells a player sent back from the Game why: the community map their group went to
	could not be built there.
]=]
function CommunityMapsController:_checkFailedReturn()
	local ok, data = pcall(function()
		return TeleportService:GetLocalPlayerTeleportData()
	end)

	if not ok or typeof(data) ~= "table" or data.CommunityMapFailed ~= true then
		return
	end

	local WarningController = self.Controllers.WarningController
	if WarningController then
		WarningController:Show(FAILED_TEXT, { Priority = FAILED_PRIORITY, Hold = FAILED_HOLD })
	end
end

function CommunityMapsController:construct()
	Framework:Listen(RESPONSE_EVENT, function(response : any)
		self:_onResponse(response)
	end)

	self:_observeUI()
	self:_watchProfile()

	task.spawn(function()
		self:_checkFailedReturn()
	end)

	local GamepadController = self.Controllers.GamepadController
	if GamepadController then
		GamepadController:RegisterPanel("CommunityMaps", self)
	end
end

function CommunityMapsController:start()

end

function CommunityMapsController:init()
	self.Maid = Maid.new()
	self.UiMaid = Maid.new()
	self.TweenMaid = Maid.new()
	self.TabMaid = Maid.new()
	self.RowMaid = Maid.new()

	self.Maid:GiveTask(self.UiMaid)
	self.Maid:GiveTask(self.TweenMaid)
	self.Maid:GiveTask(self.TabMaid)
	self.Maid:GiveTask(self.RowMaid)

	self.IsOpenState = false
	self.RequestId = 0
	self.Callbacks = {}
	self.PlayerCount = PortalConfig.MIN_PLAYERS

	self.Tab = DEFAULT_TAB
	self.Stat = DEFAULT_STAT
	self.Ascending = DEFAULT_ASCENDING
	self.Search = ""

	self.ListToken = 0
	self.LoadingToken = nil
	self.Page = 0
	self.HasMore = true

	self.Rows = {}
	self.RowCount = 0
	self.Selected = nil
	self.SelectedView = nil
	self.TabScales = {}
	self.StatButtons = {}
	self.SortButtons = {}

	self.LikeOverrides = {}
	self.FavoriteOverrides = {}

	-- Maps whose visit this player already sent; the server counts one per server anyway.
	self.Visited = {}

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CommunityMapsController
