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
	Players who have not done the tutorial get the offer on arriving in the Lobby.

	The profile keeps a boolean: `Tutorial`. `false` is the only thing that makes the
	offer appear: this service reads the key when the profile loads and, if it is
	`false`, sends `TutorialPrompt` to the client; `TutorialController` puts the
	dialog on screen.

	**Both answers settle the matter**, along different paths:

	  - **accepting** teleports the player alone to the tutorial map (`:Start`), and
	    the key becomes `true` when they win the 5 waves, over in the other place
	    (`:Complete`);
	  - **declining** writes `true` right away. Declining is an answer, not a
	    postponement: someone who said "no" is not asked again on every Lobby visit.

	**Abandoning the match midway leaves the key at `false`**: a player who accepted
	and left before the end is asked again and restarts from wave 1. A half-played
	match state exists nowhere, and returning to wave 3 with an empty map would be
	worse than restarting.

	**Lobby only.** The service is in `common/` because the game is a single
	universe, but offering the tutorial to someone who just landed mid-match would
	be worse than not offering it. The gate is `PlaceId` against
	the Lobby id of the current environment (`Environment.IsPlace("Lobby")`), so
	the QA Lobby offers it too.

	> In an unpublished place (a loose `.rbxl` in Studio) `PlaceId` is 0 and the
	> offer does not appear on its own. To see the dialog in that case there is
	> Cmdr's `tutorial`, which goes through the same `:Prompt`.

	See docs/common/tutorial.md.
]]

local TutorialService = {
	Services = {
		DataService = {},
		AnalyticsService = {},
	}
}

-- The profile key. A constant because it appears in both the read and the write,
-- and both must be the same word.
local DATA_KEY = "Tutorial"

--[[
	[Player] = true for players who arrived with the `TutorialDone` ticket on teleport.

	It is what separates a real return from Cmdr's `tutorialshop`: both run the same
	flow on screen, and only one is a player finishing the tutorial. Without this,
	testing the shop step would send funnel step 13 to the dashboard.
]]
TutorialService.Returned = {}

--[[ INTERNAL ]]

--[=[
	Has the "tutorial" matter been settled for this profile?

	Two shapes come through here. Today's is the boolean. The other is the
	`{ Match, Shop, Crates }` table this key briefly was, which `DataService`'s
	reconcile does **not** undo on its own, because it only fills in what is
	missing. It reads as settled when the match had been won.

	Without this, a profile from that window would read as "done" just because the
	table is a truthy value, and would never get the offer again.
]=]
local function isDone(data : any) : boolean
	local stored = data and data[DATA_KEY]

	if typeof(stored) == "table" then
		return stored.Match == true
	end

	return stored == true
end

--[=[
	A step of the onboarding funnel, if `AnalyticsService` is up.

	It should never be missing (it is `common/` and loads in both places), but the
	measuring service must not be what stops the tutorial from happening.
]=]
function TutorialService:funnel(player : Player, stepName : string)
	local analytics = self.Services.AnalyticsService
	if not analytics then return end

	analytics:LogFunnelStep(player, stepName)
end

--[=[
	Is this place the Lobby?
]=]
function TutorialService:isLobby() : boolean
	return Environment.IsPlace("Lobby")
end

--[=[
	Offers it to players who have not done it.

	The read goes through `DataService:Get`, which only calls back with the profile
	open and the `Loaded` tag set, that is, never before the client has what it needs
	to draw the dialog.
]=]
function TutorialService:offer(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

	dataService:Get(player, function(data)
		if isDone(data) then return end
		if not player.Parent then return end

		-- The funnel's first step is here, not in `:Prompt`: that is the entry for Cmdr's
		-- `tutorial` command, and the funnel measures players, not tests.
		self:funnel(player, "PromptShown")

		self:Prompt({ player })
	end)
end

--[=[
	A player who just won the tutorial gets the nudge toward the shop.

	The signal is the `TutorialDone` the match server attached to the teleport back,
	not the profile. It applies to **this** Lobby arrival and nothing else: leaving
	and returning does not bring the pointer back, which is right for a nudge.
]=]
function TutorialService:shopPrompt(player : Player)
	if not self:isLobby() then return end

	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	local teleportData = success and typeof(joinData) == "table" and joinData.TeleportData
	if typeof(teleportData) ~= "table" or teleportData.TutorialDone ~= true then
		return
	end

	-- The ticket is proof they came from a won match: from here on, the funnel's
	-- last two steps count for this player.
	self.Returned[player] = true

	self:funnel(player, "BackToLobby")

	self:PromptShop({ player })
end

--[=[
	The crate was bought: removes the shop pointer.

	Connected to `ShopService`'s `ItemPurchased` signal. Listening instead of
	grafting keeps the purchase free of tutorial lines, the same way the placement
	step listens to `UnitPlaced` instead of living inside `PlaceUnit`.
]=]
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
	Sends the offer without looking at the profile. This is how Cmdr's `tutorial`
	gets in, and it lets you see the dialog without resetting your own data.
]=]
function TutorialService:Prompt(players : { Player })
	for _, player in players do
		Framework:Fire("TutorialPrompt", player)
	end
end

--[=[
	The tutorial started: sends the player to the tutorial map.

	The teleport carries **two** things: the map, which the other side's `MapService`
	already knows how to read, and the `Tutorial` flag, which is what makes
	`TutorialMatchService` impose the preset and the script. Both are needed and say
	different things: loading the Tutorial map without the flag is a regular match on
	it, which is how the map gets tested.

	It goes **alone**, not through the portal: the tutorial is a guided single-player
	match, and adding someone to it would get in the way of both.
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

--[=[
	Opens the **second part**, the one that happens in the Lobby after the match: the
	dialog and the shop button highlight, which close when the crate is bought.

	Normally the `TutorialDone` ticket from the teleport back triggers it (see
	`shopPrompt`). Through here it opens without any ticket, which is what the
	`tutorialshop` command needs: testing this step without winning the five waves
	first.
]=]
function TutorialService:PromptShop(players : { Player })
	local crateService = Framework:Get("CrateService", false, false)
	local guarantee = Config.CrateGuarantee

	for _, player in players do
		--[[
			The crate the flow asks the player to buy comes with a guaranteed epic unit.
			The mark is set **here**, on the server, when the step opens: the client
			never asks for a rarity, so there is no way to forge one by opening another
			crate.
		]]
		if crateService and crateService.ForceRarity and guarantee then
			crateService:ForceRarity(player, guarantee.Rarity)
		end

		Framework:Fire("TutorialShopPrompt", player)
	end
end

--[=[
	Returns the player to the state of someone who never saw the tutorial.

	It is a test tool: the matter is settled on the first answer (winning **or**
	declining), and without this, checking the offer a second time would require
	deleting the profile.

	It reopens the dialog right away when they are in the Lobby, which is what the
	tester wants to see and what `PlayerDataLoaded` would do on the next join. It
	touches nothing else: units, coins, and crates stay where they were.
]=]
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

--[=[
	Settles the matter: the offer no longer returns for this player.

	The two paths that call this say different things to the player and the same
	thing to the profile: won the 5 waves, or answered that they do not want it. The
	key does not store **which** one, on purpose: nothing in the game asks that, and
	a key that answers more than it is asked is a key that will end up wrong.
]=]
function TutorialService:MarkDone(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

	dataService:Update(player, DATA_KEY, function()
		return true
	end)
end

--[=[
	The tutorial match was won. Called from the other place, at the end of the 5 waves.
]=]
function TutorialService:Complete(player : Player)
	self:MarkDone(player)
end

--[[ LIFECYCLE ]]

function TutorialService:construct()
	-- The event identifier is created on the server: without this empty `Listen`,
	-- the client's `Listen` would wait ten seconds for an event nobody registered,
	-- and take the rest of its `construct` down with it. It applies in both places,
	-- including the one that offers no tutorial, because the controller is common.
	Framework:Listen("TutorialPrompt", function() end)
	Framework:Listen("TutorialShopPrompt", function() end)
	Framework:Listen("TutorialShopDone", function() end)

	--[[
		The end of the unboxing, which is the tutorial's last step and the only one
		only the client sees happen: the server knows about the purchase
		(`ItemPurchased`), not the animation that came after.

		The teleport ticket authorizes it: without `Returned`, Cmdr's `tutorialshop`
		would send step 13 to the dashboard on every test.
	]]
	Framework:Listen("TutorialShopFinished", function(player : Player)
		if not self.Returned[player] then return end

		self.Returned[player] = nil

		self:funnel(player, "CrateOpened")
	end)

	Framework:Listen("TutorialAnswered", function(player : Player, accepted : any)
		if accepted ~= true then
			-- Declining is an answer, and an answer settles it: someone who said "no" is not
			-- asked again every time they enter the Lobby.
			--
			-- The funnel alone cannot tell this "no" from an ignored dialog box: both stop at
			-- step 1. That is why declining is an event.
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
		log:Warn("no DataService; the tutorial offer will not be sent.")

		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:offer(player)
		self:shopPrompt(player)
	end)

	-- Players who loaded before this service started: their signal already fired.
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
