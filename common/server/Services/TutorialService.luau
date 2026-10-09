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
	Players who have not done the tutorial are sent straight into it on arriving
	in the Lobby. There is no offer: `Tutorial = false` means "teleport them".

	The profile keeps a boolean: `Tutorial`. The key becomes `true` when they win
	the 5 waves, over in the other place (`:Complete`).

	**Abandoning the match midway leaves the key at `false`**: a player who left
	before the end is sent back in on their next Lobby arrival and restarts from
	wave 1.

	If the teleport fails, the old Yes/No offer is shown as a fallback, so the
	player is never left with nothing. Declining it still settles the matter.

	**Lobby only.** The gate is `PlaceId` against the Lobby id of the current
	environment (`Environment.IsPlace("Lobby")`), so the QA Lobby does it too.

	> In an unpublished place (a loose `.rbxl` in Studio) `PlaceId` is 0 and
	> nothing happens on its own. Cmdr's `tutorial` still shows the offer dialog.

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
	Sends players who have not done the tutorial straight into it.

	The delay gives the Lobby a moment to load before the teleport starts. Both
	funnel steps are still logged so the onboarding dashboard keeps its shape.
	If the teleport fails, the offer dialog is shown instead.
]=]
function TutorialService:offer(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

	dataService:Get(player, function(data)
		if isDone(data) then return end
		if not player.Parent then return end

		self:funnel(player, "PromptShown")

		task.delay(Config.PromptDelay or 0, function()
			if not player.Parent then return end

			self:funnel(player, "Accepted")

			if not self:Start(player) then
				self:Prompt({ player })
			end
		end)
	end)
end

function TutorialService:shopPrompt(player : Player)
	if not self:isLobby() then return end

	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	local teleportData = success and typeof(joinData) == "table" and joinData.TeleportData
	if typeof(teleportData) ~= "table" or teleportData.TutorialDone ~= true then
		return
	end

	self.Returned[player] = true

	self:funnel(player, "BackToLobby")

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

function TutorialService:Prompt(players : { Player })
	for _, player in players do
		Framework:Fire("TutorialPrompt", player)
	end
end

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
		self:Prompt({ player })
	end

	return true
end

function TutorialService:MarkDone(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

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
	Framework:Listen("TutorialShopPrompt", function() end)
	Framework:Listen("TutorialShopDone", function() end)

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

		self:funnel(player, "Accepted")

		self:Start(player)
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.Returned[player] = nil
	end)

	if not self:isLobby() then return end

	self:watchShop()

	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; the tutorial will not start.")

		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:offer(player)
		self:shopPrompt(player)
	end)

	for _, player in Players:GetPlayers() do
		self:offer(player)
		self:shopPrompt(player)
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