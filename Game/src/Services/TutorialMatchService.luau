local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local PathUtil = require(Shared.Util.PathUtil)

local Framework = Me.new()
local log = Log.new("TutorialMatchService")

local Config = SharedConfig.TutorialConfig
local RoundCardConfig = SharedConfig.RoundCardConfig
local WeatherConfig = SharedConfig.WeatherConfig
local DifficultyConfig = ServerConfig.Difficulty
local AnalyticsConfig = ServerConfig.Analytics

local INTERMISSION_WAVE = 0
local SPAWN_POINT = "@Spawn"

--[[
	The tutorial match: what says this match is the tutorial, and what it imposes.

	**Two doors.** `TeleportData.Tutorial == true` (the Lobby's portal stamps it on
	a tutorial group), or, in Studio only, `ServerStorage.Maps` carrying
	`TutorialConfig.Match.StudioAttribute = true`.

	**What it imposes:** the `Match.Difficulty` preset with `PresetOverrides`
	applied (the vote is skipped), the step script in `Match.Steps`, and the round
	card shop's schedule (`ShopIsScripted` / `ShouldOpenShop`). The map is whatever
	the player picked; the deck is their own loadout unless `Match.Deck` says
	otherwise.

	The answer is decided once and cached: a server is a tutorial server or not for
	its whole life.

	See docs/game/tutorial-match.md.
]]

local TutorialMatchService = {
	Services = {
		UnitService = {},
		SpeedService = {},
		WeatherRoundService = {},
		MobService = {},
		MapService = {},
		AnalyticsService = {},
	}
}

TutorialMatchService.Step = nil :: any
TutorialMatchService.Done = false
TutorialMatchService.DeckUnlocked = false
TutorialMatchService.Completed = {}
TutorialMatchService.Granted = {}
TutorialMatchService.Tutorial = nil :: boolean?
TutorialMatchService.Won = false
TutorialMatchService.LastWave = nil :: number?

--[[ DETECTION ]]

function TutorialMatchService:teleportedFlag(player : Player) : boolean
	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	if not success or typeof(joinData) ~= "table" then
		return false
	end

	local teleportData = joinData.TeleportData
	if typeof(teleportData) ~= "table" then
		return false
	end

	return teleportData.Tutorial == true
end

function TutorialMatchService:studioFlag() : boolean
	local maps = ServerStorage:FindFirstChild("Maps")
	if not maps then
		return false
	end

	return maps:GetAttribute(Config.Match.StudioAttribute) == true
end

function TutorialMatchService:resolve() : boolean
	if self.Tutorial ~= nil then
		return self.Tutorial
	end

	if RunService:IsStudio() and self:studioFlag() then
		self.Tutorial = true

		log:Debug(`tutorial match via the {Config.Match.StudioAttribute} attribute.`)

		return true
	end

	local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()

	self.Tutorial = self:teleportedFlag(player)

	if self.Tutorial then
		log:Debug(`tutorial match via the TeleportData of {player.Name}.`)
	end

	return self.Tutorial
end

--[[ MATCH SETUP ]]

function TutorialMatchService:IsTutorial() : boolean
	return self:resolve()
end

--[=[
	The preset this match imposes, or `nil` for a regular match: a copy of
	`Match.Difficulty` with `Match.PresetOverrides` written over it.
]=]
function TutorialMatchService:GetForcedPreset() : any
	if not self:IsTutorial() then
		return nil
	end

	local name = Config.Match.Difficulty
	local preset = DifficultyConfig.Presets[name]

	if not preset then
		log:StudioWarn(`preset "{name}" does not exist in Config.Difficulty.Presets; the match will vote as usual.`)

		return nil
	end

	local resolved = table.clone(preset)
	for field, value in (Config.Match.PresetOverrides or {}) do
		resolved[field] = value
	end

	return resolved
end

function TutorialMatchService:GetDeck() : { [string] : number }?
	if not self:IsTutorial() or not Config.Match.Deck then
		return nil
	end

	local counts = {}

	for _, slot in Config.Match.Deck do
		counts[slot.Unit] = (counts[slot.Unit] or 0) + slot.Amount
	end

	return counts
end

function TutorialMatchService:GetDeckOrder() : { string }?
	if not self:IsTutorial() or not Config.Match.Deck then
		return nil
	end

	local order = {}

	for _, slot in Config.Match.Deck do
		table.insert(order, slot.Unit)
	end

	return order
end

--[[ THE SCRIPT ]]

--[=[
	This wave's step: the first not-yet-completed step with this `Wave`, or, on a
	calendar shop wave, the first not-yet-completed `OnShop` step.
]=]
function TutorialMatchService:StepFor(wave : number) : any
	for _, step in Config.Match.Steps do
		if step.Wave == wave and not self.Completed[step.Id] then
			return step
		end
	end

	if wave >= 1 and RoundCardConfig.IsShopWave(wave, Config.Match.Difficulty) then
		for _, step in Config.Match.Steps do
			if step.OnShop and not self.Completed[step.Id] then
				return step
			end
		end
	end

	return nil
end

function TutorialMatchService:pointNamed(name : string) : BasePart?
	local map = workspace:FindFirstChild("Map")
	local points = map and map:FindFirstChild("PlacementPoints")
	local part = points and points:FindFirstChild(name)

	return if part and part:IsA("BasePart") then part else nil
end

--- Where the enemies enter the map: the first node of the path.
function TutorialMatchService:spawnPosition() : Vector3?
	local path = workspace:FindFirstChild("PathScriptable")
	local nodes = path and path:FindFirstChild("Nodes")
	if not nodes then return nil end

	local first = PathUtil.GetSortedNodes(nodes)[1]
	if not first then return nil end

	if first:IsA("BasePart") then
		return first.Position
	end

	for _, node in PathUtil.GetSortedNodes(first) do
		if node:IsA("BasePart") then
			return node.Position
		end
	end

	return nil
end

--- The spot a step points at, as a position.
function TutorialMatchService:positionFor(step : any) : Vector3?
	if not step or not step.Point then
		return nil
	end

	if step.Point == SPAWN_POINT then
		local position = self:spawnPosition()
		if not position then
			log:StudioWarn(`step "{step.Id}" points at the spawn, but the map has no PathScriptable.Nodes.`)
		end
		return position
	end

	local part = self:pointNamed(step.Point)
	if not part then
		log:StudioWarn(`step "{step.Id}" asks for point "{step.Point}", which does not exist in Map.PlacementPoints.`)
	end

	return part and part.Position or nil
end

function TutorialMatchService:BeginStep(wave : number)
	if not self:IsTutorial() then return end

	self:awaitPending()

	self:openStep(self:StepFor(wave))
end

function TutorialMatchService:BeginFinal()
	if not self:IsTutorial() then return end

	self:openStep(self:finalStep())
end

function TutorialMatchService:finalStep() : any
	for _, step in Config.Match.Steps do
		if step.Kind == "Lobby" then
			return step
		end
	end

	return nil
end

function TutorialMatchService:openStep(step : any)
	if not step then
		self.Step = nil

		return
	end

	self.Step = step
	self.Done = false
	self.LastWave = step.Wave or self.LastWave

	if step.UnlocksDeck then
		self.DeckUnlocked = true
	end

	self:scheduleWeather(step)
	self:ensureCash(step)
	self:grantCash(step)

	local position = self:positionFor(step)

	local positions = nil
	if step.Points then
		positions = {}

		for _, name in step.Points do
			local part = self:pointNamed(name)

			if part then
				table.insert(positions, part.Position)
			end
		end
	end

	log:Debug(string.format("opening step '%s' (%s, %s)%s",
		step.Id,
		if step.Wave then `wave {step.Wave}` elseif step.OnShop then "shop wave" else "end of match",
		step.Kind,
		(step.Hold or step.HoldNext) and ", holding" or ""))

	local locked = {}
	for _, other in Config.Match.Steps do
		if other.Kind == "Use" and other.Card and not self.Completed[other.Id] then
			locked[other.Card] = true
		end
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("TutorialStep", player, {
			Id = step.Id,
			Kind = step.Kind,
			Unit = step.Unit,
			Card = step.Card,
			Index = step.Index,
			Highlight = step.Highlight,
			HighlightWait = step.HighlightWait,
			Position = position,
			Positions = positions,
			Lines = step.Lines,
			HideDeck = step.HideDeck,

			Locked = locked,
			AllowedUnits = self:allowedUnits(),

			Buttons = step.Buttons,
			BlockedButtons = step.BlockedButtons,
			ButtonRelease = step.ButtonRelease,
			UnlockOnDone = step.UnlockOnDone,

			FreeSpeed = Config.Match.FreeSpeed == true,
			LockTowerActions = Config.Match.LockTowerActions == true,
		})
	end

	if step.AutoComplete then
		task.delay(step.AutoComplete, function()
			if self.Step == step and not self.Done then
				self:CompleteStep()
			end
		end)
	end
end

function TutorialMatchService:BeginIntermission()
	self:BeginStep(INTERMISSION_WAVE)
end

function TutorialMatchService:NoteIntermissionEnd()
	local step = self.Step

	if step and step.Kind == "Ready" then
		self:CompleteStep()
	end
end

--[=[
	Waits for an earlier step that holds the **next** wave (`HoldNext`). It is how
	an intermission step keeps wave 1 from spawning until the player has done it.
]=]
function TutorialMatchService:awaitPending()
	local step = self.Step

	while step and step.HoldNext and not self.Done and self.Step == step do
		task.wait(0.2)
		step = self.Step
	end
end

--[=[
	Schedules a weather for the next wave through `WeatherRoundService`'s own
	fields, so the usual warning shows. The list is filtered by the map's pool;
	when nothing overlaps, the step's list is used as is.
]=]
function TutorialMatchService:scheduleWeather(step : any)
	if not step.ScheduleWeather or #step.ScheduleWeather == 0 then return end

	local weather = self.Services.WeatherRoundService
	if not weather then return end

	local mapService = self.Services.MapService
	local pool = WeatherConfig.GetPool(mapService and mapService.CurrentMapName or nil)

	local options = {}
	for _, name in step.ScheduleWeather do
		if table.find(pool, name) then
			table.insert(options, name)
		end
	end

	if #options == 0 then
		options = step.ScheduleWeather
	end

	local name = options[math.random(1, #options)]
	local wave = (step.Wave or 0) + 1

	weather.Scheduled = name
	weather.ScheduledWave = wave

	weather:broadcastWarning(name, 1)

	log:Debug(`"{name}" scheduled for wave {wave}.`)
end

--- The most expensive round card, for a "buy any card" step's safety net.
local function maxCardPrice() : number
	local highest = 0

	for _, card in (RoundCardConfig.Cards or {}) do
		if typeof(card) == "table" then
			highest = math.max(highest, RoundCardConfig.GetPrice(card))
		end
	end

	return highest
end

--[=[
	A purchase step that holds the wave must never find a player without money.
	Tops up only the difference: to the card's price, or, for "any card", to the
	most expensive card so whatever is on the table is affordable.
]=]
function TutorialMatchService:ensureCash(step : any)
	if not step.Ensure then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	local price
	if step.Card then
		local card = RoundCardConfig.Get(step.Card)
		price = card and RoundCardConfig.GetPrice(card) or 0
	else
		price = maxCardPrice()
	end

	if price <= 0 then return end

	for _, player in Players:GetPlayers() do
		local missing = price - (mobService:getCash(player) or 0)

		if missing > 0 then
			mobService:addCash(player, missing)

			log:Debug(`topped up {missing} so {player.Name} can afford a card.`)
		end
	end
end

function TutorialMatchService:grantCash(step : any)
	local amount = step.GrantCash
	if not amount or amount <= 0 then return end

	if self.Granted[step.Id] then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	self.Granted[step.Id] = true

	for _, player in Players:GetPlayers() do
		mobService:addCash(player, amount)
	end

	log:Debug(`gave {amount} cash on step "{step.Id}".`)
end

function TutorialMatchService:AwaitStep(wave : number)
	local step = self.Step
	if not step or not step.Hold then
		return
	end

	if step.Wave ~= wave and not step.OnShop then
		return
	end

	while self.Step == step and not self.Done do
		if step.Kind == "Speed" then
			local speed = self.Services.SpeedService

			if speed and speed:GetIndex() >= (step.Index or 2) then
				self:CompleteStep()

				break
			end
		end

		task.wait(0.2)
	end
end

function TutorialMatchService:handIsEmpty(player : Player) : boolean
	local unitService = self.Services.UnitService
	if not unitService then
		return true
	end

	local cards = unitService.SessionCards and unitService.SessionCards[player.UserId]
	if not cards then
		return true
	end

	for _, count in cards do
		if count > 0 then
			return false
		end
	end

	return true
end

function TutorialMatchService:CompleteStep()
	local step = self.Step
	if not step or self.Done then return end

	self.Done = true
	self.Completed[step.Id] = true

	log:Debug(`step "{step.Id}" completed.`)

	local analytics = self.Services.AnalyticsService

	for _, player in Players:GetPlayers() do
		if analytics and step.Kind ~= "Lobby" then
			analytics:LogFunnelStep(player, step.Id)
		end

		Framework:Fire("TutorialStepDone", player, step.Id)
	end
end

--[[ SHOP ]]

--[=[
	In the tutorial the shop's schedule always comes from here, so a step can force
	it open on a wave the difficulty's calendar would skip. `CardShopService` asks
	`ShopIsScripted` first and, when it is `true`, opens only where
	`ShouldOpenShop` says.
]=]
function TutorialMatchService:ShopIsScripted() : boolean
	return self:IsTutorial()
end

--[=[
	Whether the round card shop opens on this wave in the tutorial: on a step that
	asks for it (`OpenShop`), and, with `Match.KeepShopCalendar`, on the
	difficulty's normal shop waves too.
]=]
function TutorialMatchService:ShouldOpenShop(wave : number) : boolean
	if not self:IsTutorial() then
		return false
	end

	for _, step in Config.Match.Steps do
		if step.Wave == wave and step.OpenShop then
			return true
		end
	end

	if Config.Match.KeepShopCalendar then
		return RoundCardConfig.IsShopWave(wave, Config.Match.Difficulty)
	end

	return false
end

function TutorialMatchService:ForcedCard(wave : number) : string?
	if not self:IsTutorial() then
		return nil
	end

	local step = self:StepFor(wave)

	return step and step.Kind == "Buy" and step.Card or nil
end

--- With a purchase step open, only its card; a step with no `Card` takes any.
function TutorialMatchService:CanBuy(cardId : string) : boolean
	local step = self.Step

	if not step or step.Kind ~= "Buy" or self.Done or not step.Card then
		return true
	end

	return cardId == step.Card
end

function TutorialMatchService:allowedUnits() : { [string] : boolean }?
	if not self:IsTutorial() or self.DeckUnlocked then
		return nil
	end

	local list = Config.Match.AllowedUnits
	if not list or #list == 0 then
		return nil
	end

	local allowed = {}
	for _, unitName in list do
		allowed[unitName] = true
	end

	return allowed
end

function TutorialMatchService:useStepFor(cardId : string) : any
	for _, step in Config.Match.Steps do
		if step.Kind == "Use" and step.Card == cardId then
			return step
		end
	end

	return nil
end

function TutorialMatchService:CanUse(cardId : string) : boolean
	if not self:IsTutorial() then
		return true
	end

	local step = self:useStepFor(cardId)
	if not step then
		return true
	end

	if self.Step == step and not self.Done then
		return true
	end

	return self.Completed[step.Id] == true
end

function TutorialMatchService:NoteBuy(cardId : string)
	local step = self.Step

	if step and step.Kind == "Buy" and (not step.Card or step.Card == cardId) then
		self:CompleteStep()
	end
end

function TutorialMatchService:NoteUse(cardId : string)
	local step = self.Step

	if step and step.Kind == "Use" and step.Card == cardId then
		self:CompleteStep()
	end
end

function TutorialMatchService:NoteWon()
	self.Won = true
end

--[[ UNIT RULES ]]

function TutorialMatchService:CanUpgrade() : boolean
	return not (self:IsTutorial() and Config.Match.LockTowerActions == true)
end

function TutorialMatchService:CanSell() : boolean
	return not (self:IsTutorial() and Config.Match.LockTowerActions == true)
end

--[=[
	With a placement step open: only its unit (if it names one), and only within
	`Radius` of its spot. Outside a step, the deck lock still applies.
]=]
function TutorialMatchService:CanPlace(unitName : string, cf : CFrame) : boolean
	local allowed = self:allowedUnits()
	if allowed and not allowed[unitName] then
		return false
	end

	local step = self.Step
	if not step or self.Done then
		return true
	end

	if step.Kind == "PlaceRest" then
		for _, name in (step.Points or {}) do
			local part = self:pointNamed(name)

			if part and (cf.Position - part.Position).Magnitude <= (step.Radius or 10) then
				return true
			end
		end

		return false
	end

	if step.Kind ~= "Place" then
		return true
	end

	if step.Unit and unitName ~= step.Unit then
		return false
	end

	local position = self:positionFor(step)
	if not position then
		return true
	end

	local offset = cf.Position - position
	local flat = Vector3.new(offset.X, 0, offset.Z)

	return flat.Magnitude <= (step.Radius or 10)
end

--[[ TELEMETRY ]]

function TutorialMatchService:watchPlayers()
	local analytics = self.Services.AnalyticsService
	if not analytics then return end

	local function joined(player : Player)
		analytics:LogFunnelStep(player, "MatchJoined")
	end

	for _, player in Players:GetPlayers() do
		joined(player)
	end

	Players.PlayerAdded:Connect(joined)

	Players.PlayerRemoving:Connect(function(player : Player)
		if self.Won then return end

		local step = self.Step

		analytics:LogEvent(player, AnalyticsConfig.Events.Abandoned, self.LastWave or 0, {
			step and step.Id or "None",
		})
	end)
end

--[[ LIFECYCLE ]]

function TutorialMatchService:construct()
	Framework:Listen("TutorialStep", function() end)
	Framework:Listen("TutorialStepDone", function() end)
	Framework:Listen("TutorialDeck", function() end)

	task.spawn(function()
		if not self:resolve() then return end

		self:watchPlayers()
	end)

	local unitService = self.Services.UnitService
	if not unitService then return end

	unitService.Signals.UnitPlaced:Connect(function(player : Player, unitName : string)
		local step = self.Step
		if not step or self.Done then return end

		if step.Kind == "Place" and (not step.Unit or step.Unit == unitName) then
			self:CompleteStep()

			return
		end

		if step.Kind == "PlaceRest" and self:handIsEmpty(player) then
			self:CompleteStep()
		end
	end)
end

function TutorialMatchService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function TutorialMatchService:init()
end

return TutorialMatchService