local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("RoundCardStarterService")

local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

--[=[
	The starter kit of round cards, guaranteed on every open profile.

	`Data.Template` hands `STARTER_CARDS` to newcomers, and only to newcomers:
	`DataService`'s reconcile creates the `RoundCards` key where it is missing, but
	never touches one that exists. Without this service, every card added to the kit
	would apply only to accounts created after it: two players in the same room
	would build the round offer from different catalogs, with nothing on screen
	saying why.

	It writes **only what is missing**, and only when something is: a profile that
	is up to date is not touched. A card the player bought with shards is already in
	their `RoundCards`, so it does not show in the list: nobody is refunded and no
	purchase is undone.

	It lives in `common/` because both places open profiles: the player can enter
	through the Lobby or land directly in a match, and the round offer is built in
	Game from what is written here.
]=]
local RoundCardStarterService = {
	Services = {
		DataService = {},
	},
}

--[[ INTERNAL ]]

--[=[
	Writes the kit cards this player is still missing to their profile.

	It runs once per loaded profile. The list is checked again **inside** `Update`,
	not only before it: a purchase in the Lobby card shop fits between the read and
	the write, and the `RoundCards` that counts is the one in the callback's hands.
]=]
function RoundCardStarterService:_seed(player : Player)
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	local data = entry and entry.Profile and entry.Profile.Data

	if typeof(data) ~= "table" then return end

	local missing = RoundCardShopConfig.missingStarters(data.RoundCards)
	if #missing == 0 then return end

	dataService:Update(player, "RoundCards", function(unlocked)
		if typeof(unlocked) ~= "table" then
			unlocked = {}
		end

		for _, cardId in RoundCardShopConfig.missingStarters(unlocked) do
			unlocked[cardId] = true
		end

		return unlocked
	end)

	log:Debug(string.format("%s received the missing starter kit (%s).",
		player.Name, table.concat(missing, ", ")))
end

--[[ LIFECYCLE ]]

function RoundCardStarterService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; the starter kit will not be backfilled on old profiles.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_seed(player)
	end)

	-- Players who loaded before this service started: their signal already fired.
	for _, player in Players:GetPlayers() do
		self:_seed(player)
	end
end

function RoundCardStarterService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function RoundCardStarterService:init()
end

return RoundCardStarterService
