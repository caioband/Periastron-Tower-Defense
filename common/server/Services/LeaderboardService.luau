local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)
local UIUtil = require(Shared.Util.UIUtil)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("LeaderboardService")

local LeaderboardConfig = ServerConfig.Leaderboard
local LevelConfig = SharedConfig.LevelConfig

--[[
	The global leaderboards: one OrderedDataStore per board (`Config.Leaderboard`).

	It lives in `common` because both places **write**: Game changes XP, coins, wins,
	matches, and time in match; the Lobby changes coins (purchases), crates opened,
	and playtime. Only the Lobby **draws**, and not by configuration: it is the only
	place with `Workspace.Leaderboards`, and without the folder the reading half
	never starts.

	**Writing.** The profile is still the source; the store is a sorted copy of it.
	Each server sends its own players' numbers when the profile loads, every
	`WRITE_INTERVAL`, and on leave, and only those that changed since the last write
	(`Written`). Everything goes through a queue (`Pending`) with one entry per
	store+player: if the number changes again before the write goes out, the entry
	is replaced, not duplicated. The queue respects Roblox's write budget and, if the
	store fails, waits for the next cycle instead of insisting.

	**Reading.** Every `READ_INTERVAL` the Lobby requests each board's top (one page
	of `TOP`, which costs the same with a hundred or a hundred million players in the
	store) and resolves names in a single batch (`GetUserInfosByUserIdsAsync`), with
	a cache.

	**Drawing.** The `Frame` inside the `ScrollingFrame` is the template: it leaves
	the screen and becomes one row per position. Rows are reused between reads (only
	the text changes), and extra rows stay hidden. The SurfaceGui is in the
	Workspace, so what the server writes replicates to everyone.

	**The store name includes `PROFILE_KEY`.** Changing the key resets profiles, and a
	leaderboard that kept showing numbers from profiles nobody reads anymore would be
	lying.

	Players with a negative UserId (Studio test clients) do not write: the store is
	the same as the live game's, and they would pollute the real top.

	See docs/common/leaderboards.md.
]]

local WRITE_BUDGET = Enum.DataStoreRequestType.SetIncrementSortedAsync
local READ_BUDGET = Enum.DataStoreRequestType.GetSortedAsync

-- After everything else that writes to the profile on leave: the early-leaver
-- reward, the final time (see `DataService:OnBeforeRelease`).
local RELEASE_ORDER = 1

-- How long shutdown waits for the queue to drain. Roblox gives `BindToClose` 30s.
local SHUTDOWN_TIMEOUT = 25

-- One warning per store every so often: with Studio API access off, every call
-- fails, and eight boards every cycle would bury the rest of the output.
local WARN_COOLDOWN = 600

local UNKNOWN_NAME = "???"

local LeaderboardService = {
	Services = {
		DataService = {},
	},

	-- [Store] = OrderedDataStore
	Stores = {},

	-- [UserId] = { [Store] = number already in the store }. Only for players here.
	Written = {},

	-- ["Store|UserId"] = { Store, UserId, Value }
	Pending = {},
	Draining = false,

	-- [UserId] = Username
	Names = {},

	-- The map's boards (Lobby only): { Config, List, Template, Rows }
	Boards = {},

	-- [key] = `os.clock()` of the last warning
	Warned = {},
}

--[[ FORMAT ]]

--- The number on the profile, as a non-negative integer. Anything not a number counts as zero.
local function readPath(data : any, path : { string }) : number
	local node = data
	for _, key in path do
		if typeof(node) ~= "table" then
			return 0
		end

		node = node[key]
	end

	local value = tonumber(node) or 0
	if value ~= value or value == math.huge then
		return 0
	end

	return math.max(0, math.floor(value))
end

--- Seconds as `DD:HH:MM`. Days do not stop at 99: 120 days is `120:00:00`.
local function formatTime(seconds : number) : string
	local minutes = seconds // 60

	return string.format("%02d:%02d:%02d", minutes // 1440, (minutes // 60) % 24, minutes % 60)
end

local function formatValue(format : string, value : number) : string
	if format == "Level" then
		return tostring(LevelConfig:Resolve(value).Level)
	elseif format == "Time" then
		return formatTime(value)
	end

	return (UIUtil.formatAbbreviated(value))
end

local function setText(row : Instance, name : string, text : string)
	local label = row:FindFirstChild(name)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

--[[ INTERNAL ]]

function LeaderboardService:_warn(key : string, message : string)
	local last = self.Warned[key]
	if last and os.clock() - last < WARN_COOLDOWN then
		return
	end

	self.Warned[key] = os.clock()
	log:Warn(message)
end

function LeaderboardService:_storeOf(storeKey : string) : OrderedDataStore?
	local store = self.Stores[storeKey]
	if store then
		return store
	end

	local name = string.format("%s_LB_%s", ServerConfig.Data.PROFILE_KEY, storeKey)
	local ok, result = pcall(DataStoreService.GetOrderedDataStore, DataStoreService, name)
	if not ok then
		self:_warn("store:" .. storeKey, string.format("could not open store %q (%s).", name, tostring(result)))
		return nil
	end

	self.Stores[storeKey] = result
	return result
end

function LeaderboardService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[[ WRITING ]]

--[=[
	Queues the player's numbers that changed since the last write.

	On the session's first time there is no `Written` to compare, so everything
	goes, except zeros, which is what the store already says about players who
	never scored.
]=]
function LeaderboardService:_collect(player : Player)
	local userId = player.UserId
	if userId <= 0 then return end

	local data = self:_profileOf(player)
	if not data then return end

	local written = self.Written[userId]
	if not written then
		written = {}
		self.Written[userId] = written
	end

	local queued = false
	for _, board in LeaderboardConfig.Boards do
		local value = readPath(data, board.Path)
		local last = written[board.Store]

		if value ~= last and not (last == nil and value == 0) then
			self.Pending[board.Store .. "|" .. userId] = {
				Store = board.Store,
				UserId = userId,
				Value = value,
			}
			queued = true
		end
	end

	if queued then
		self:_drain()
	end
end

--[=[
	Drains the queue on a single thread. Calling again while it runs does nothing:
	whatever entered the queue midway goes out on the same pass.

	A failed write goes back into the queue (unless a newer number has already
	taken its place) and the pass stops: a store that is down does not recover in
	a second, and insisting would only spend the budget. The next cycle retries.
]=]
function LeaderboardService:_drain()
	if self.Draining then return end
	self.Draining = true

	task.spawn(function()
		while true do
			local key, job = next(self.Pending)
			if not key then
				break
			end

			if DataStoreService:GetRequestBudgetForRequestType(WRITE_BUDGET) < 1 then
				task.wait(1)
				continue
			end

			self.Pending[key] = nil

			local store = self:_storeOf(job.Store)
			local ok, err = false, "store unavailable"
			if store then
				ok, err = pcall(store.SetAsync, store, tostring(job.UserId), job.Value)
			end

			if ok then
				local written = self.Written[job.UserId]
				if written then
					written[job.Store] = job.Value
				end
			else
				if self.Pending[key] == nil then
					self.Pending[key] = job
				end

				self:_warn("write:" .. job.Store, string.format("write to %s failed (%s).", job.Store, tostring(err)))
				break
			end
		end

		self.Draining = false
	end)
end

--[[ READING AND DRAWING ]]

--- Links each board in the config to its model on the map. Returns whether there are any.
function LeaderboardService:_bindBoards() : boolean
	local folder = workspace:FindFirstChild(LeaderboardConfig.FOLDER_NAME)
	if not folder then
		return false
	end

	for _, config in LeaderboardConfig.Boards do
		local model = folder:FindFirstChild(config.Model)
		local main = model and model:FindFirstChild("Main")
		local surface = main and main:FindFirstChildWhichIsA("SurfaceGui")
		local list = surface and surface:FindFirstChildWhichIsA("ScrollingFrame")
		local template = list and list:FindFirstChildWhichIsA("Frame")

		if not template then
			log:StudioWarn(string.format(
				"%s.%s has no Main > SurfaceGui > ScrollingFrame > Frame; board skipped.",
				LeaderboardConfig.FOLDER_NAME, config.Model))
			continue
		end

		-- The template leaves the screen: it stays only as the source for rows.
		template.Parent = nil

		table.insert(self.Boards, {
			Config = config,
			List = list,
			Template = template,
			Rows = {},
		})
	end

	return #self.Boards > 0
end

--- A board's top, highest to lowest, without zeros.
function LeaderboardService:_fetch(config) : { { UserId : number, Value : number } }?
	local store = self:_storeOf(config.Store)
	if not store then return nil end

	while DataStoreService:GetRequestBudgetForRequestType(READ_BUDGET) < 1 do
		task.wait(1)
	end

	local ok, result = pcall(function()
		return store:GetSortedAsync(false, LeaderboardConfig.TOP, 1):GetCurrentPage()
	end)

	if not ok then
		self:_warn("read:" .. config.Store, string.format("read from %s failed (%s).", config.Store, tostring(result)))
		return nil
	end

	local entries = {}
	for _, item in result do
		local userId = tonumber(item.key)
		if userId then
			table.insert(entries, { UserId = userId, Value = tonumber(item.value) or 0 })
		end
	end

	return entries
end

--[=[
	The names of those on the top. Players on the server come from `Player`; the rest
	go in a single batch to `UserService` and are cached: the top changes little
	between reads.

	If the whole batch fails, it falls back to one request per player. An id that
	still does not resolve (a deleted account) shows as `???` and is retried on the
	next pass.
]=]
function LeaderboardService:_resolveNames(entries)
	local missing = {}

	for _, entry in entries do
		local userId = entry.UserId
		if not self.Names[userId] then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				self.Names[userId] = player.Name
			else
				table.insert(missing, userId)
			end
		end
	end

	if #missing == 0 then return end

	local ok, infos = pcall(UserService.GetUserInfosByUserIdsAsync, UserService, missing)
	if ok then
		for _, info in infos do
			self.Names[info.Id] = info.Username
		end

		return
	end

	for _, userId in missing do
		local found, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
		if found then
			self.Names[userId] = name
		end
	end
end

function LeaderboardService:_render(board, entries)
	self:_resolveNames(entries)

	for rank, entry in entries do
		local row = board.Rows[rank]
		if not row then
			row = board.Template:Clone()
			row.Name = string.format("Rank%02d", rank)
			row.LayoutOrder = rank
			row.Parent = board.List
			board.Rows[rank] = row
		end

		setText(row, "Position", string.format("%dº", rank))
		setText(row, "Username", self.Names[entry.UserId] or UNKNOWN_NAME)
		setText(row, "Value", formatValue(board.Config.Format, entry.Value))
		row.Visible = true
	end

	for rank = #entries + 1, #board.Rows do
		board.Rows[rank].Visible = false
	end
end

function LeaderboardService:_refreshBoards()
	for _, board in self.Boards do
		local entries = self:_fetch(board.Config)
		if entries then
			self:_render(board, entries)
		end
	end
end

--[[ LIFECYCLE ]]

function LeaderboardService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; nothing will reach the leaderboards.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_collect(player)
	end)

	-- The final snapshot, with the profile still open and after the leave-time writers.
	if dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:_collect(player)
			self.Written[player.UserId] = nil
		end, RELEASE_ORDER)
	end

	-- Players who loaded before this service started: their signal already fired.
	for _, player in Players:GetPlayers() do
		self:_collect(player)
	end

	task.spawn(function()
		while true do
			task.wait(LeaderboardConfig.WRITE_INTERVAL)

			for _, player in Players:GetPlayers() do
				self:_collect(player)
			end
		end
	end)

	--[[
		Shutdown: DataService's `Destroy` calls queue each player's final snapshot
		(the hook above), and this holds the server until the queue drains. The
		`_collect` here covers players not yet released when this callback ran.
	]]
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			self:_collect(player)
		end

		local deadline = os.clock() + SHUTDOWN_TIMEOUT
		repeat
			self:_drain()
			task.wait(0.5)
		until os.clock() >= deadline or (next(self.Pending) == nil and not self.Draining)
	end)

	if self:_bindBoards() then
		task.spawn(function()
			while true do
				self:_refreshBoards()
				task.wait(LeaderboardConfig.READ_INTERVAL)
			end
		end)
	end
end

function LeaderboardService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function LeaderboardService:init()
end

return LeaderboardService
