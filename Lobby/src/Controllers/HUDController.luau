local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Util.UIUtil)

local LevelConfig = SharedConfig.LevelConfig

local Framework = Me.new()
local log = Log.new("HUDController")

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"
local MIDDLE_NAME = "HUDMiddle"

local LEVEL_NAME = "Level"
local EXP_NAME = "ExpAmount"
local BAR_CONTAINER_NAME = "ProgressBarContainer"
local BAR_IMAGE_NAME = "EXPImage"

local COIN_NAME = "CoinAmount"
local COIN_TEXT_NAME = "CoinAmountText"
local SHARD_NAME = "ShardAmount"
local SHARD_TEXT_NAME = "ShardAmountText"

local WAIT_TIMEOUT = 10

local LEVEL_FORMAT = "LEVEL %d"
local MAX_EXP_TEXT = "MAX"

-- A ScreenGui only to hold the bar's images in memory. It stays disabled and
-- with ResetOnSpawn off: the HUD is recreated on every respawn, the cache is not.
local CACHE_GUI_NAME = "HUDImageCache"

--[=[
	Writes the profile data into StarterGui.HUD.HUDMiddle: level, XP, coins, and shards.

	Level and progress come from accumulated XP (`SharedConfig.LevelConfig`): the profile
	stores no level. The bar is not a bar: it is a single ImageLabel that swaps art by
	progress band, and the five arts are downloaded and cached as soon as the player joins,
	so the first swap does not show blank.

	The HUD has `ResetOnSpawn` on, so the bind runs again for every new copy the engine
	puts in PlayerGui.

	See docs/lobby/hud.md.
]=]
local HUDController = {
	Controllers = {
		DataController = {},
	},
}

--[[ INTERNAL ]]

--[=[
	Downloads the bar's art and holds it in memory. `PreloadAsync` alone only guarantees
	the download; what prevents discarding it later is having a live ImageLabel pointing at
	each one, which is why the cache is made of instances, not a list of ids.

	`emptyImage` is the empty bar authored in the GUI, which is also used again when
	progress resets on a level up.
]=]
function HUDController:_cacheImages(emptyImage : string?)
	if self.CacheGui then
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local cacheGui = Instance.new("ScreenGui")
	cacheGui.Name = CACHE_GUI_NAME
	cacheGui.Enabled = false
	cacheGui.ResetOnSpawn = false
	cacheGui.Parent = playerGui

	self.CacheGui = cacheGui
	self.Maid:GiveTask(cacheGui)

	local images = LevelConfig:GetBarImages()
	if emptyImage and emptyImage ~= "" then
		table.insert(images, 1, emptyImage)
	end

	local holders = {}
	for index, image in images do
		local holder = Instance.new("ImageLabel")
		holder.Name = tostring(index)
		holder.Image = image
		holder.BackgroundTransparency = 1
		holder.ImageTransparency = 1
		holder.Size = UDim2.fromOffset(1, 1)
		holder.Visible = false
		holder.Parent = cacheGui

		table.insert(holders, holder)
	end

	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(holders)
		end)

		if not ok then
			log:StudioWarn(`XP bar preload failed: {err}`)
		end
	end)
end

--[=[
	The profile stats, or nil until the replica arrives.
]=]
function HUDController:_getStats()
	local replica = self.Replica
	return replica and replica.Data and replica.Data.Stats
end

function HUDController:_setBarImage(image : string)
	local bar = self.Bar
	if not bar or not image or bar.Image == image then
		return
	end

	bar.Image = image
end

--[=[
	Rewrites the four fields from the replica. Called on bind and on every write to
	`Stats`; with no replica yet, shows the zeroed state instead of the authored text.
]=]
function HUDController:_refresh()
	if not self.Middle or not self.Middle.Parent then
		return
	end

	local stats = self:_getStats()
	local state = LevelConfig:Resolve(stats and stats.XP or 0)

	self.State = state

	if self.LevelLabel then
		self.LevelLabel.Text = string.format(LEVEL_FORMAT, state.Level)
	end

	if self.ExpLabel then
		self.ExpLabel.Text = if state.IsMax
			then MAX_EXP_TEXT
			else `{UIUtil.formatCommas(state.XP)}/{UIUtil.formatCommas(state.Required)}`
	end

	self:_setBarImage(LevelConfig:GetBarImage(state.Progress) or self.EmptyBarImage)

	if self.CoinLabel then
		self.CoinLabel.Text = UIUtil.formatCommas(stats and stats.Cash or 0)
	end

	if self.ShardLabel then
		self.ShardLabel.Text = UIUtil.formatCommas(stats and stats.Shards or 0)
	end
end

--[=[
	Holds the player's replica and rewrites the HUD on every change. Same as the
	ShopController counter: DataService writes the whole `Stats` key, but the listener is
	`OnChange` so any deeper write (`Stats.XP`, ...) also counts.
]=]
function HUDController:_watchStats()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_refresh()

		local connection = replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
				return
			end

			self:_refresh()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	Binds to a copy of the HUD. Runs again on every respawn (`ResetOnSpawn`).
]=]
function HUDController:_bindUI(screenGui : ScreenGui)
	local middle = screenGui:WaitForChild(MIDDLE_NAME, WAIT_TIMEOUT)
	local barContainer = middle and middle:WaitForChild(BAR_CONTAINER_NAME, WAIT_TIMEOUT)
	local bar = barContainer and barContainer:WaitForChild(BAR_IMAGE_NAME, WAIT_TIMEOUT)

	if not middle or not bar or not bar:IsA("ImageLabel") then
		log:StudioWarn(`could not find {HUD_UI_NAME}.{MIDDLE_NAME}.{BAR_CONTAINER_NAME}.{BAR_IMAGE_NAME}.`)
		return
	end

	local coin = middle:FindFirstChild(COIN_NAME)
	local shard = middle:FindFirstChild(SHARD_NAME)

	self.ScreenGui = screenGui
	self.Middle = middle
	self.Bar = bar
	self.LevelLabel = middle:FindFirstChild(LEVEL_NAME)
	self.ExpLabel = middle:FindFirstChild(EXP_NAME)
	self.CoinLabel = coin and coin:FindFirstChild(COIN_TEXT_NAME)
	self.ShardLabel = shard and shard:FindFirstChild(SHARD_TEXT_NAME)

	-- The empty bar is the art authored in the GUI: its id does not live in the config,
	-- it is read from here. Only from the first copy, the only one guaranteed untouched,
	-- and it is also what triggers the cache, which holds for the whole session.
	if not self.EmptyBarImage then
		self.EmptyBarImage = bar.Image
		self:_cacheImages(self.EmptyBarImage)
	end

	self:_refresh()
end

function HUDController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindUI(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

--[=[
	The local player's level and progress, as the HUD is showing them.
]=]
function HUDController:GetLevelState()
	return self.State or LevelConfig:Resolve(0)
end

--[=[
	Rewrites the HUD by hand. Only needed for code that changes the profile without going
	through the replica; the replica already updates on its own.
]=]
function HUDController:Refresh()
	self:_refresh()
end

function HUDController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()
	self:_watchStats()
end

function HUDController:init()
	self.Maid = Maid.new()
	self.EmptyBarImage = nil
end

return HUDController
