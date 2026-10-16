local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)

local Framework = Me.new()
local log = Log.new("TutorialService")

local Config = SharedConfig.TutorialConfig
local AnalyticsConfig = ServerConfig.Analytics

--[[
	The tutorial's Lobby side.

	A player whose profile has `Tutorial = false` is dropped on the portal plaza
	and walked through picking a map (`BeginMapPick`). While that is pending,
	`PortalService` makes their portal group solo and stamps `Tutorial = true` on
	the teleport, which is what turns the match into the tutorial match.

	The key becomes `true` when the tutorial match is won (`Complete`, called from
	the Game place). Leaving midway leaves it `false`, so the next Lobby visit
	starts the map pick again.

	**The shop half waits for the client.** A player coming back from the won
	match carries the `TutorialDone` ticket. The ticket is read as soon as the
	profile loads, but the prompt is only sent once the client says its
	`TutorialShopController` is listening (`TutorialShopReady`): a network event
	fired at a client that has not hooked it yet is dropped, and the profile
	usually loads while the client is still on the loading screen. Without the
	handshake the returning player landed in the Lobby and nothing happened.

	**Lobby only** for the automatic start (`Environment.IsPlace("Lobby")`). In an
	unpublished place nothing starts on its own; Cmdr's `tutorial` still works.

	See docs/common/tutorial.md.
]]

local TutorialService = {
	Services = {
		DataService = {},
		AnalyticsService = {},
	}
}

local DATA_KEY = "Tutorial"

TutorialService.Returned = {}
TutorialService.Pending = {}

-- Players holding a `TutorialDone` ticket whose shop prompt has not gone out yet.
TutorialService.ShopTicket = {}

-- Players whose client said its shop flow is listening.
TutorialService.ShopReady = {}

--[[ INTERNAL ]]

local function isDone(data : any) : boolean
	local stored = data and data[DATA_KEY]

	if typeof(stored) == "table" then
		return stored.Match == true
	end

	return stored == true
end

function TutorialService:funnel(player : Player, stepName : string)
	local analytics = self.Services.AnalyticsService
	if not analytics then return end

	analytics:LogFunnelStep(player, stepName)
end

function TutorialService:isLobby() : boolean
	return Environment.IsPlace("Lobby")
end

--[=[
	Drops the player on the portal plaza marker. Waits for the character, since
	the profile usually loads before it.
]=]
function TutorialService:placeOnPlaza(player : Player)
	local character = player.Character or player.CharacterAdded:Wait()
	if not player.Parent or not character then return end

	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root then return end

	local map = workspace:FindFirstChild("Map")
	local marker = map and map:FindFirstChild(Config.MapPick.SpawnPart, true)

	if not marker or not marker:IsA("BasePart") then
		log:StudioWarn(`no {Config.MapPick.SpawnPart} under Workspace.Map; the player stays at the spawn.`)
		return
	end

	character:PivotTo(marker.CFrame * CFrame.new(0, marker.Size.Y / 2 + Config.MapPick.SpawnHeightOffset, 0))
	root.AssemblyLinearVelocity = Vector3.zero
end

function TutorialService:offer(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

	dataService:Get(player, function(data)
		if isDone(data) then return end
		if not player.Parent then return end

		-- Back from the won match with the ticket: the shop half runs, not the map pick.
		if self.Returned[player] then return end

		self:BeginMapPick(player)
	end)
end

--- The ticket the match server attached to the teleport back, if any.
local function hasTicket(player : Player) : boolean
	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	local teleportData = success and typeof(joinData) == "table" and joinData.TeleportData

	return typeof(teleportData) == "table" and teleportData.TutorialDone == true
end

function TutorialService:shopPrompt(player : Player)
	if not self:isLobby() then return end
	if self.Returned[player] then return end
	if not hasTicket(player) then return end

	self.Returned[player] = true
	self.ShopTicket[player] = true

	log:Debug(`{player.Name} is back from the tutorial match; the shop step waits for the client.`)

	self:funnel(player, "BackToLobby")
	self:tryShop(player)
end

--[=[
	Sends the shop prompt once both halves are there: the ticket, and a client
	that is listening. Called from either side, whichever comes last.
]=]
function TutorialService:tryShop(player : Player)
	if not self.ShopTicket[player] or not self.ShopReady[player] then return end
	if not player.Parent then return end

	self.ShopTicket[player] = nil

	log:Debug(`sending the shop step to {player.Name}.`)

	self:PromptShop({ player })
end

function TutorialService:watchShop()
	if not self:isLobby() then return end

	local shopService = Framework:Get("ShopService", false, false)
	if not shopService or not shopService.Signals or not shopService.Signals.ItemPurchased then
		log:Warn("no ItemPurchased signal; the shop step will not complete on its own.")

		return
	end

	shopService.Signals.ItemPurchased:Connect(function(player : Player, item : any)
		if not item or item.Id ~= Config.Lobby.Item then return end

		if self.Returned[player] then
			self:funnel(player, "CrateBought")
		end

		Framework:Fire("TutorialShopDone", player)
	end)
end

--[[ API ]]

--[=[
	Starts the map pick: the player lands on the portal plaza and the client walks
	them to a portal and through the map panel.
]=]
function TutorialService:BeginMapPick(player : Player)
	if not player.Parent then return end

	self.Pending[player] = true
	self:funnel(player, "PromptShown")

	task.spawn(function()
		self:placeOnPlaza(player)
	end)

	task.delay(Config.PromptDelay or 0, function()
		if not player.Parent or not self.Pending[player] then return end

		Framework:Fire("TutorialMapPick", player)
	end)
end

--[=[
	Whether this player's next portal group is the tutorial match.
	`PortalService` asks this when the group opens.
]=]
function TutorialService:IsPending(player : Player) : boolean
	return self.Pending[player] == true
end

--[=[
	The player opened their tutorial portal group: the funnel's "accepted".
]=]
function TutorialService:NoteGroupCreated(player : Player)
	if not self.Pending[player] then return end

	self:funnel(player, "Accepted")
end

function TutorialService:Prompt(players : { Player })
	for _, player in players do
		Framework:Fire("TutorialPrompt", player)
	end
end

--[=[
	The direct teleport, kept for Cmdr and as a fallback. A normal run goes
	through the portals instead.
]=]
function TutorialService:Start(player : Player)
	local match = Config.Match

	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true
	options:SetTeleportData({
		Map = match.Map,
		Tutorial = true,
	})

	local success, result = pcall(function()
		return TeleportService:TeleportAsync(Environment.GetPlaceId("Game"), { player }, options)
	end)

	if not success then
		log:Warn(`could not teleport {player.Name} to the tutorial: {result}`)

		return false
	end

	return true
end

function TutorialService:PromptShop(players : { Player })
	local crateService = Framework:Get("CrateService", false, false)
	local guarantee = Config.CrateGuarantee

	for _, player in players do
		if crateService and crateService.ForceRarity and guarantee then
			crateService:ForceRarity(player, guarantee.Rarity)
		end

		Framework:Fire("TutorialShopPrompt", player)
	end
end

function TutorialService:Reset(player : Player)
	local dataService = self.Services.DataService
	if not dataService then
		return false
	end

	dataService:Update(player, DATA_KEY, function()
		return false
	end)

	if self:isLobby() then
		self:BeginMapPick(player)
	end

	return true
end

function TutorialService:MarkDone(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

	self.Pending[player] = nil

	dataService:Update(player, DATA_KEY, function()
		return true
	end)
end

function TutorialService:Complete(player : Player)
	self:MarkDone(player)
end

--[[ LIFECYCLE ]]

function TutorialService:construct()
	Framework:Listen("TutorialPrompt", function() end)
	Framework:Listen("TutorialMapPick", function() end)
	Framework:Listen("TutorialShopPrompt", function() end)
	Framework:Listen("TutorialShopDone", function() end)

	-- The client's shop flow is hooked up and the loading screen is out of the way.
	Framework:Listen("TutorialShopReady", function(player : Player)
		if self.ShopReady[player] then return end

		self.ShopReady[player] = true
		self:tryShop(player)
	end)

	Framework:Listen("TutorialShopFinished", function(player : Player)
		if not self.Returned[player] then return end

		self.Returned[player] = nil

		self:funnel(player, "CrateOpened")
	end)

	Framework:Listen("TutorialAnswered", function(player : Player, accepted : any)
		if accepted ~= true then
			local analytics = self.Services.AnalyticsService
			if analytics then
				analytics:LogEvent(player, AnalyticsConfig.Events.Declined)
			end

			self:MarkDone(player)

			return
		end

		if self:isLobby() then
			self:BeginMapPick(player)
		else
			self:Start(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.Returned[player] = nil
		self.Pending[player] = nil
		self.ShopTicket[player] = nil
		self.ShopReady[player] = nil
	end)

	if not self:isLobby() then return end

	self:watchShop()

	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; the tutorial will not start.")

		return
	end

	-- The ticket is read before the map pick check: a player back from the won match
	-- whose profile write has not landed yet must not be sent to the map pick.
	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:shopPrompt(player)
		self:offer(player)
	end)

	for _, player in Players:GetPlayers() do
		self:shopPrompt(player)
		self:offer(player)
	end
end

function TutorialService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function TutorialService:init()
end

return TutorialService