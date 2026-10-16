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
local NEAR_SPAWN_POINT = "@NearSpawn"

-- How often a held purchase step re-checks that the player can still afford a card.
local ENSURE_INTERVAL = 0.5

-- How often an open step re-checks whether the player already did what it asks.
local WATCH_INTERVAL = 0.2

--[[
	How `@NearSpawn` looks for its spot: along the first `NEAR_SPAWN_NODES` path nodes,
	at each fraction of a segment in `NEAR_SPAWN_ALONG`, stepping sideways off the path
	by each distance in `NEAR_SPAWN_OFFSETS` (both sides). The first spot that is on
	ground roughly level with the path (`NEAR_SPAWN_MAX_STEP` studs) and that the unit
	really fits on wins.
]]
local NEAR_SPAWN_NODES = 6
local NEAR_SPAWN_ALONG = { 0.5, 0.25, 0.75 }
local NEAR_SPAWN_OFFSETS = { 6, 7.5, 9, 11 }
local NEAR_SPAWN_MAX_STEP = 3

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

	**Nothing runs ahead of the lesson.** Steps hold their wave (`Hold`) or the next
	one (`HoldNext`) until done, Info steps wait for the client to report the dialog
	was read (`TutorialStepRead`), steps with `Ensure` keep cash topped up while they
	wait, and upgrading/selling stay refused until the `Match.TowerActionsUntil` step
	opens.

	**Time stops for the lesson.** A step's `TimeScale` holds the match clock through
	`SpeedService:SetHold` while it is on screen: `0` freezes the match while the
	player places a tower or picks a card, a value below 1 slows it while the speed
	button is taught. Completing the step lets go.

	**Steps can chain.** Two steps on the same wave run back to back: when the first
	is done the second opens straight away, still holding the wave (the card shop,
	then placing the rest of the hand).

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
TutorialMatchService.Opened = {}
TutorialMatchService.Granted = {}
TutorialMatchService.Tutorial = nil :: boolean?
TutorialMatchService.Won = false
TutorialMatchService.LastWave = nil :: number?

-- The wave whose steps are running: what chained steps open on.
TutorialMatchService.CurrentWave = nil :: number?

-- Goes up on every opened step: a delayed opening checks it before showing up.
TutorialMatchService.StepToken = 0

-- The spot `@NearSpawn` resolved to, worked out once per match.
TutorialMatchService.NearSpawn = nil :: Vector3?

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
	The preset this match imposes, or `nil` for a regular match: `Match.Difficulty`
	with `Match.PresetOverrides` written over it.

	**Written onto the live preset, not a copy.** `WaveService` uses what this
	returns, but `MobService` (base damage, spawns, starting cash), the card shop
	and the weather read the preset through `DifficultyService:GetSelected()`, which
	hands out `Config.Difficulty`'s own table. A copy only `WaveService` saw left
	them on the plain preset: escaped enemies hurt the base despite `MobDamage = 0`,
	and wave overrides never reached the spawner. A tutorial server is a tutorial
	server for its whole life (see `resolve`), so changing the preset here changes
	nothing anywhere else. Writing it again on a later call is harmless.
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

	for field, value in (Config.Match.PresetOverrides or {}) do
		preset[field] = value
	end

	return preset
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

--[[ TIME ]]

--[=[
	Holds the match clock for the lesson (`0` pauses, below `1` slows), or lets go
	with `nil`. See `SpeedService:SetHold`.
]=]
function TutorialMatchService:setHold(scale : number?)
	local speed = self.Services.SpeedService
	if not speed or not speed.SetHold then return end

	speed:SetHold(scale)
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

--[=[
	The first path nodes, in walking order, as positions. Up to `limit` of them.

	The nodes folder either holds the nodes directly or one folder per route; with
	routes, the first route is the one used, like `spawnPosition`.
]=]
function TutorialMatchService:pathPositions(limit : number) : { Vector3 }
	local path = workspace:FindFirstChild("PathScriptable")
	local nodes = path and path:FindFirstChild("Nodes")
	if not nodes then return {} end

	local sorted = PathUtil.GetSortedNodes(nodes)
	local first = sorted[1]
	if not first then return {} end

	local list = if first:IsA("BasePart") then sorted else PathUtil.GetSortedNodes(first)
	local positions = {}

	for _, node in list do
		if node:IsA("BasePart") then
			table.insert(positions, node.Position)

			if #positions >= limit then
				break
			end
		end
	end

	return positions
end

--- Where the enemies enter the map: the first node of the path.
function TutorialMatchService:spawnPosition() : Vector3?
	return self:pathPositions(1)[1]
end

--[=[
	A free spot beside the start of the path where `unitName` can be placed: the
	ground point the step's arrow points at and the player's tower snaps onto.

	The map is whatever the player picked, so the spot is worked out here instead of
	being authored: walking the first segments of the path, stepping sideways off it,
	dropping a ray to the ground and asking `UnitService:isSpotFree` (the same
	question a real placement asks) plus a clearance check for scenery the unit would
	stand inside. Found once and kept for the match. With nothing valid in reach, it
	falls back to the path's first node.
]=]
function TutorialMatchService:nearSpawnSpot(unitName : string?) : Vector3?
	if self.NearSpawn then
		return self.NearSpawn
	end

	local unitService = self.Services.UnitService
	local nodes = self:pathPositions(NEAR_SPAWN_NODES)

	if not unitService or #nodes < 2 or not unitName then
		return nodes[1]
	end

	local bounds = unitService.UnitBounds and unitService.UnitBounds[unitName]
	local size = if typeof(bounds) == "Vector3" then bounds else Vector3.new(2, 4, 2)

	local exclude = {}

	for _, part in (unitService.getGridParts and unitService:getGridParts() or {}) do
		table.insert(exclude, part)
	end

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end

	local pathFolder = workspace:FindFirstChild("PathScriptable")
	if pathFolder then
		table.insert(exclude, pathFolder)
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = exclude

	local function groundAt(point : Vector3) : RaycastResult?
		return workspace:Raycast(point + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), rayParams)
	end

	local function clear(cf : CFrame, ground : Instance) : boolean
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Exclude
		overlap.FilterDescendantsInstances = { ground, table.unpack(exclude) }

		local probe = cf * CFrame.new(0, 0.25, 0)

		return #workspace:GetPartBoundsInBox(probe, size * 0.8, overlap) == 0
	end

	for index = 1, #nodes - 1 do
		local a, b = nodes[index], nodes[index + 1]
		local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)

		if flat.Magnitude < 0.5 then
			continue
		end

		local direction = flat.Unit
		local side = Vector3.new(-direction.Z, 0, direction.X)

		for _, along in NEAR_SPAWN_ALONG do
			local base = a:Lerp(b, along)
			local pathGround = groundAt(base)
			local pathY = if pathGround then pathGround.Position.Y else base.Y

			for _, distance in NEAR_SPAWN_OFFSETS do
				for _, sign in { 1, -1 } do
					local hit = groundAt(base + side * distance * sign)
					if not hit or math.abs(hit.Position.Y - pathY) > NEAR_SPAWN_MAX_STEP then
						continue
					end

					local cf = CFrame.new(hit.Position + Vector3.new(0, size.Y / 2, 0))

					if unitService:isSpotFree(cf, unitName, "tutorial spot") and clear(cf, hit.Instance) then
						self.NearSpawn = hit.Position

						log:Debug(string.format("@NearSpawn resolved to (%.1f, %.1f, %.1f), %d stud(s) off segment %d.",
							hit.Position.X, hit.Position.Y, hit.Position.Z, distance, index))

						return hit.Position
					end
				end
			end
		end
	end

	log:StudioWarn("no free spot found beside the start of the path; pointing at the first node instead.")

	return nodes[1]
end

--- The spot a step points at, as a position.
function TutorialMatchService:positionFor(step : any) : Vector3?
	if not step or not step.Point then
		return nil
	end

	if step.Point == NEAR_SPAWN_POINT then
		return self:nearSpawnSpot(step.Unit)
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

	self.CurrentWave = wave
	self:openStep(self:StepFor(wave))
end

function TutorialMatchService:BeginFinal()
	if not self:IsTutorial() then return end

	self.CurrentWave = nil
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

--[=[
	Makes `step` the open step. What it holds (its wave, the next one) holds from
	this instant; what the player sees comes in `presentStep`, right away or after
	`OpenDelay` real seconds while the wave plays.
]=]
function TutorialMatchService:openStep(step : any)
	self.StepToken += 1
	local token = self.StepToken

	if not step then
		self.Step = nil
		self:setHold(nil)

		return
	end

	self.Step = step
	self.Done = false
	self.Opened[step.Id] = true
	self.LastWave = step.Wave or self.LastWave

	if step.UnlocksDeck then
		self.DeckUnlocked = true
	end

	local delay = tonumber(step.OpenDelay)
	if delay and delay > 0 then
		task.delay(delay, function()
			if self.StepToken ~= token or self.Step ~= step or self.Done then return end

			self:presentStep(step, token)
		end)

		return
	end

	self:presentStep(step, token)
end

--[=[
	Shows the open step: holds the clock, sets up the money and the weather it needs,
	tells the clients, and starts watching for it to be done.
]=]
function TutorialMatchService:presentStep(step : any, token : number)
	self:setHold(step.TimeScale)

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
			Panel = step.Panel,
			Position = position,
			Positions = positions,
			SnapRadius = step.SnapRadius,
			ArrowOnEquip = step.ArrowOnEquip,
			Lines = step.Lines,
			HideDeck = step.HideDeck,
			ReadDelay = step.ReadDelay,

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
				log:StudioWarn(`step "{step.Id}" closed on its AutoComplete fallback; the read never arrived.`)

				self:CompleteStep()
			end
		end)
	end

	self:watchStep(step, token)
end

--[=[
	Watches an open step for the things only the server can see: the speed the room
	picked, an upgrade bought, cash that ran short while the step waits.

	It runs whether or not the step holds a wave, on real time (`task.wait`): with the
	clock held at 0, match time would never advance.
]=]
function TutorialMatchService:watchStep(step : any, token : number)
	task.spawn(function()
		local baseline = if step.Kind == "Upgrade" then self:upgradeTotal() else 0
		local lastEnsure = os.clock()

		while self.StepToken == token and self.Step == step and not self.Done do
			if step.Kind == "Speed" then
				local speed = self.Services.SpeedService

				if speed and speed:GetIndex() >= (step.Index or 2) then
					self:CompleteStep()

					break
				end
			end

			if step.Kind == "Upgrade" and self:upgradeTotal() > baseline then
				self:CompleteStep()

				break
			end

			if step.Ensure and os.clock() - lastEnsure >= ENSURE_INTERVAL then
				lastEnsure = os.clock()
				self:ensureCash(step)
			end

			task.wait(WATCH_INTERVAL)
		end
	end)
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

--- What placing every card still in this player's hand costs, at the current weather.
function TutorialMatchService:handCost(player : Player) : number
	local unitService = self.Services.UnitService
	local cards = unitService and unitService.SessionCards and unitService.SessionCards[player.UserId]
	if not cards then return 0 end

	local weather = unitService.GetWeather and unitService:GetWeather() or nil
	local total = 0

	for unitName, count in cards do
		if count > 0 then
			total += SharedConfig.UnitUpgradeConfig:GetPlaceCost(unitName, weather) * count
		end
	end

	return total
end

--- The cheapest next upgrade among this player's placed units, or 0 with nothing to upgrade.
function TutorialMatchService:cheapestUpgrade(player : Player) : number
	local unitService = self.Services.UnitService
	local upgrades = SharedConfig.UnitUpgradeConfig
	local cheapest = nil

	for _, entry in (unitService and unitService.PlacedUnits or {}) do
		if entry.ownerUserId ~= player.UserId then continue end

		local level = entry.upgrades or 0
		if upgrades:IsMaxed(level) then continue end

		local cost = upgrades:GetCost(entry.unitName, level)
		if not cheapest or cost < cheapest then
			cheapest = cost
		end
	end

	return cheapest or 0
end

--- Every upgrade bought on the map so far, summed: what tells an `Upgrade` step it happened.
function TutorialMatchService:upgradeTotal() : number
	local unitService = self.Services.UnitService
	local total = 0

	for _, entry in (unitService and unitService.PlacedUnits or {}) do
		total += entry.upgrades or 0
	end

	return total
end

--- What a step with `Ensure` needs this player to be able to pay.
function TutorialMatchService:requiredCash(step : any, player : Player) : number
	if step.Kind == "PlaceRest" then
		return self:handCost(player)
	end

	if step.Kind == "Upgrade" then
		return self:cheapestUpgrade(player)
	end

	if step.Card then
		local card = RoundCardConfig.Get(step.Card)
		return card and RoundCardConfig.GetPrice(card) or 0
	end

	return maxCardPrice()
end

--[=[
	A step that waits on the player must never find them without money.
	Tops up only the difference: to the card's price (or, for "any card", the most
	expensive card), to the cost of the rest of the hand, or to the cheapest upgrade.

	Safe to call repeatedly: a player who already has enough gets nothing.
]=]
function TutorialMatchService:ensureCash(step : any)
	if not step.Ensure then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	for _, player in Players:GetPlayers() do
		local price = self:requiredCash(step, player)
		if price <= 0 then continue end

		local missing = price - (mobService:getCash(player) or 0)

		if missing > 0 then
			mobService:addCash(player, missing)

			log:Debug(`topped up {missing} so {player.Name} can finish step "{step.Id}".`)
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

--[=[
	Holds the wave while a step that holds it is open.

	It follows **whichever step is open**, not the one that was open when the wave
	started: a step that chains into another on the same wave (the card shop, then
	placing the rest of the hand) keeps the wave held across both.
]=]
function TutorialMatchService:AwaitStep(wave : number)
	while true do
		local step = self.Step

		if not step or self.Done or not step.Hold then
			return
		end

		if step.Wave ~= wave and not step.OnShop then
			return
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

--[=[
	Closes the open step: lets go of the clock, reports it, and opens the next step
	on the same wave when there is one (in the same call, so a held wave never slips
	through between the two).
]=]
function TutorialMatchService:CompleteStep()
	local step = self.Step
	if not step or self.Done then return end

	self.Done = true
	self.Completed[step.Id] = true

	self:setHold(nil)

	log:Debug(`step "{step.Id}" completed.`)

	local analytics = self.Services.AnalyticsService

	for _, player in Players:GetPlayers() do
		if analytics and step.Kind ~= "Lobby" then
			analytics:LogFunnelStep(player, step.Id)
		end

		Framework:Fire("TutorialStepDone", player, step.Id)
	end

	if step.Kind == "Lobby" or self.CurrentWave == nil then return end

	local nextStep = self:StepFor(self.CurrentWave)

	if nextStep and nextStep ~= step and nextStep.Wave == self.CurrentWave then
		self:openStep(nextStep)
	end
end

--[=[
	The client is done with an `Info` step's dialog, or with the weather popup of a
	`Weather` step. Only the open step, only once: action steps close on the action
	itself.
]=]
function TutorialMatchService:NoteRead(id : any)
	local step = self.Step
	if not step or self.Done then return end
	if step.Kind ~= "Info" and step.Kind ~= "Weather" then return end
	if typeof(id) ~= "string" or step.Id ~= id then return end

	self:CompleteStep()
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

--[=[
	Whether upgrading and selling are allowed yet. Locked for the whole match with
	`LockTowerActions`, otherwise until the `TowerActionsUntil` step has opened.
]=]
function TutorialMatchService:towerActionsAllowed() : boolean
	if not self:IsTutorial() then
		return true
	end

	if Config.Match.LockTowerActions == true then
		return false
	end

	local gate = Config.Match.TowerActionsUntil
	if not gate then
		return true
	end

	return self.Opened[gate] == true
end

function TutorialMatchService:CanUpgrade() : boolean
	return self:towerActionsAllowed()
end

function TutorialMatchService:CanSell() : boolean
	return self:towerActionsAllowed()
end

--[=[
	With a placement step open: only its unit (if it names one), and only within
	`Radius` of its spot. A `PlaceRest` step with `Points` only takes those spots;
	without them, anywhere. Outside a step, the deck lock still applies.
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
		if not step.Points or #step.Points == 0 then
			return true
		end

		for _, name in step.Points do
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

	Framework:Listen("TutorialStepRead", function(_player : Player, id : any)
		if not self:IsTutorial() then return end

		self:NoteRead(id)
	end)

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