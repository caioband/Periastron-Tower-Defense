local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("ChallengeService")

local Config = SharedConfig.ChallengeConfig
local UnlockConfig = SharedConfig.DifficultyUnlockConfig
local DifficultyConfig = ServerConfig.Difficulty

-- Studio only: a string attribute on `ServerStorage.Maps`, "Kind:Slot" (e.g.
-- "Weekly:1"), runs that slot of the current period without a teleport.
local STUDIO_ATTRIBUTE = "StudioChallenge"

--[[
	Daily and weekly challenges, server side. Both places run it.

	**Lobby:** `RequestPlayChallenge(kind, slot)` checks the player may play it
	(current period, profile loaded, not in a portal group, not mid-tutorial,
	difficulty unlocked, owns at least one unbanned unit) and teleports them alone
	to a reserved Game server. The teleport data is the usual portal shape
	(`Map`, `Players`, `MaxPlayers`) plus `Challenge = { Kind, Period, Slot }`.
	The answer goes back as `ChallengePlayResult(kind, slot, ok, reason)`.

	**Game:** the first player's teleport data resolves the active challenge
	(`ChallengeConfig.resolveRef`, which rebuilds it from the config, so nothing a
	client sends is trusted). It is published as Workspace attributes
	(`ChallengeConfig.ATTRIBUTES`) for clients. The match services ask:

	  - `WaveService` -> `GetForcedPreset()`: the difficulty preset with the
	    modifiers in, imposed through `DifficultyService:ForcePreset`.
	  - `UnitService` -> `IsBanned(unitName)`: banned towers start with 0 cards.
	  - `WeatherRoundService` -> `GetWeather(wave)` / `GetRotateWaves()`.
	  - `WaveService` on a win -> `Complete(players)`: pays `Rewards` once per
	    challenge per period, marking the profile first and paying right after,
	    with nothing yielding in between.

	The profile key (`ChallengeConfig.DATA_KEY`) is created on first write.
]]

local ChallengeService = {
	Services = {
		DataService = {},
		RewardService = {},
	},

	Signals = {
		-- (challenge) -- Game: the active challenge was resolved.
		Resolved = Signal.new(),

		-- (player, challenge) -- a challenge was completed and paid.
		Completed = Signal.new(),
	},
}

-- [Player] = { At, Kind, Slot } of the last accepted Play request.
ChallengeService.Busy = {}

-- Game: the challenge this server is running, or nil.
ChallengeService.Active = nil

--[[ INTERNAL ]]

function ChallengeService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

local function ownsPlayableUnit(profile : any, challenge) : boolean
	local units = typeof(profile) == "table" and profile.Units or nil
	if typeof(units) ~= "table" then
		return false
	end

	for unitName, amount in units do
		if (tonumber(amount) or 0) > 0 and not Config.isBanned(challenge, unitName) then
			return true
		end
	end

	return false
end

function ChallengeService:_readRef(player : Player) : any
	local ok, joinData = pcall(player.GetJoinData, player)
	local data = ok and typeof(joinData) == "table" and joinData.TeleportData or nil
	local ref = typeof(data) == "table" and data.Challenge or nil

	return typeof(ref) == "table" and ref or nil
end

function ChallengeService:_activate(challenge, source : string)
	self.Active = challenge

	workspace:SetAttribute(Config.ATTRIBUTES.Kind, challenge.Kind)
	workspace:SetAttribute(Config.ATTRIBUTES.Period, challenge.Period)
	workspace:SetAttribute(Config.ATTRIBUTES.Slot, challenge.Slot)

	log:Debug(`active challenge {challenge.Id} via {source}: {challenge.Map} on {challenge.Difficulty}.`)

	self.Signals.Resolved:Fire(challenge)
end

function ChallengeService:_tryResolve(player : Player)
	if self.Active or Environment.IsPlace("Lobby") then
		return
	end

	local ref = self:_readRef(player)
	if not ref then
		return
	end

	local challenge = Config.resolveRef(ref)
	if not challenge then
		log:Warn(`{player.Name} arrived with an expired or invalid challenge; running a normal match.`)
		return
	end

	self:_activate(challenge, `the TeleportData of {player.Name}`)
end

function ChallengeService:_tryStudio()
	if self.Active or not RunService:IsStudio() or Environment.IsPlace("Lobby") then
		return
	end

	local maps = ServerStorage:FindFirstChild("Maps")
	local value = maps and maps:GetAttribute(STUDIO_ATTRIBUTE)
	if typeof(value) ~= "string" or value == "" then
		return
	end

	local kind, slot = string.match(value, "^(%a+):(%d+)$")
	local challenge = kind and Config.isKind(kind)
		and Config.get(kind, Config.currentPeriod(kind), tonumber(slot))
		or nil

	if not challenge then
		log:StudioWarn(`{STUDIO_ATTRIBUTE} = "{value}" is not a valid "Kind:Slot".`)
		return
	end

	self:_activate(challenge, `the {STUDIO_ATTRIBUTE} attribute`)
end

function ChallengeService:_completeOne(player : Player, challenge)
	local dataService = self.Services.DataService
	if not dataService or not self:_profileOf(player) then
		return
	end

	local paid = false

	dataService:Update(player, Config.DATA_KEY, function(record)
		if typeof(record) ~= "table" then
			record = Config.createEmpty()
		end

		local entry = record[challenge.Kind]
		if typeof(entry) ~= "table" then
			entry = { Period = -1, Done = {} }
			record[challenge.Kind] = entry
		end

		if typeof(entry.Done) ~= "table" then
			entry.Done = {}
		end

		local stored = tonumber(entry.Period) or -1

		-- A newer period was already recorded: this one is over.
		if challenge.Period < stored then
			return record
		end

		if challenge.Period > stored then
			entry.Period = challenge.Period
			entry.Done = {}
		end

		local key = tostring(challenge.Slot)
		if entry.Done[key] then
			return record
		end

		entry.Done[key] = true
		paid = true

		return record
	end)

	if not paid then
		return
	end

	local rewardService = self.Services.RewardService
	if rewardService then
		rewardService:Grant(player, challenge.Rewards)
	end

	self.Signals.Completed:Fire(player, challenge)
end

--[[ LOBBY ]]

--[=[
	Validates and teleports. Returns `ok, reason`; reasons: `Invalid`, `Cooldown`,
	`NotLoaded`, `InGroup`, `Tutorial`, `DifficultyLocked`, `AllBanned`,
	`TeleportFailed`.
]=]
function ChallengeService:Play(player : Player, kind : any, slot : any) : (boolean, string?)
	if not Config.isKind(kind) then
		return false, "Invalid"
	end

	local challenge = Config.get(kind, Config.currentPeriod(kind), slot)
	if not challenge then
		return false, "Invalid"
	end

	local busy = self.Busy[player]
	if busy and os.clock() - busy.At < Config.PLAY_COOLDOWN then
		return false, "Cooldown"
	end

	local profile = self:_profileOf(player)
	if not profile then
		return false, "NotLoaded"
	end

	local portalService = Framework:Get("PortalService", false, false)
	if portalService and portalService.GetPortalOf and portalService:GetPortalOf(player) then
		return false, "InGroup"
	end

	local tutorialService = Framework:Get("TutorialService", false, false)
	if tutorialService and tutorialService.IsPending and tutorialService:IsPending(player) then
		return false, "Tutorial"
	end

	if not UnlockConfig.isUnlocked(challenge.Difficulty, profile.Stats) then
		return false, "DifficultyLocked"
	end

	if not ownsPlayableUnit(profile, challenge) then
		return false, "AllBanned"
	end

	self.Busy[player] = { At = os.clock(), Kind = kind, Slot = challenge.Slot }

	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true
	options:SetTeleportData({
		Map = challenge.Map,
		Players = { player.UserId },
		MaxPlayers = 1,
		Challenge = {
			Kind = challenge.Kind,
			Period = challenge.Period,
			Slot = challenge.Slot,
		},
	})

	local ok, err = pcall(function()
		return TeleportService:TeleportAsync(Environment.GetPlaceId("Game"), { player }, options)
	end)

	if not ok then
		self.Busy[player] = nil
		log:Warn(`challenge teleport for {player.Name} failed: {tostring(err)}`)

		return false, "TeleportFailed"
	end

	return true, nil
end

--[[ GAME ]]

--- The challenge this server is running, or nil.
function ChallengeService:GetActive()
	return self.Active
end

function ChallengeService:IsActive() : boolean
	return self.Active ~= nil
end

--[=[
	Waits up to `timeout` seconds (default 10) for the challenge to resolve, for
	match code that runs before the first player has joined. Returns it, or nil
	when this is a normal match.
]=]
function ChallengeService:AwaitActive(timeout : number?)
	local deadline = os.clock() + (timeout or 10)

	while not self.Active and os.clock() < deadline do
		task.wait(0.1)
	end

	return self.Active
end

--- The difficulty the challenge imposes, or nil.
function ChallengeService:GetDifficulty() : string?
	return self.Active and self.Active.Difficulty or nil
end

--[=[
	The preset this match imposes, or nil for a regular match: a copy of the
	challenge's difficulty preset with its modifiers applied.
]=]
function ChallengeService:GetForcedPreset() : any
	local challenge = self.Active
	if not challenge then
		return nil
	end

	local preset = DifficultyConfig.Presets[challenge.Difficulty]
	if not preset then
		log:StudioWarn(`preset "{challenge.Difficulty}" does not exist in Config.Difficulty.Presets; the match will vote as usual.`)
		return nil
	end

	return Config.applyModifiers(challenge, preset)
end

--- A copy of `preset` with the active challenge's modifiers applied.
function ChallengeService:ApplyPreset(preset : { [string] : any }) : { [string] : any }
	return Config.applyModifiers(self.Active, preset)
end

function ChallengeService:IsBanned(unitName : string?) : boolean
	return Config.isBanned(self.Active, unitName)
end

--- The weather that must be on for `wave`, or nil (no challenge, or no weathers).
function ChallengeService:GetWeather(wave : number) : string?
	return Config.weatherAt(self.Active, wave)
end

--- How many waves each challenge weather lasts.
function ChallengeService:GetRotateWaves() : number
	return self.Active and self.Active.RotateWaves or 1
end

--- Call on a won match. Pays each player once per challenge per period.
function ChallengeService:Complete(players : { Player })
	local challenge = self.Active
	if not challenge then
		return
	end

	for _, player in players do
		self:_completeOne(player, challenge)
	end
end

--[[ LIFECYCLE ]]

function ChallengeService:construct()
	if not Environment.IsPlace("Game") then
		Framework:Listen("RequestPlayChallenge", function(player : Player, kind : any, slot : any)
			local ok, reason = self:Play(player, kind, slot)
			Framework:Fire("ChallengePlayResult", player, kind, slot, ok, reason)
		end)

		TeleportService.TeleportInitFailed:Connect(function(player : Player, result : Enum.TeleportResult, message : string)
			local busy = self.Busy[player]
			if not busy then
				return
			end

			self.Busy[player] = nil
			log:Warn(`challenge teleport for {player.Name} failed: {result.Name}: {message}`)

			Framework:Fire("ChallengePlayResult", player, busy.Kind, busy.Slot, false, "TeleportFailed")
		end)
	end

	if not Environment.IsPlace("Lobby") then
		self:_tryStudio()

		Players.PlayerAdded:Connect(function(player : Player)
			self:_tryResolve(player)
		end)

		for _, player in Players:GetPlayers() do
			task.spawn(self._tryResolve, self, player)
		end
	end

	Players.PlayerRemoving:Connect(function(player : Player)
		self.Busy[player] = nil
	end)
end

function ChallengeService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function ChallengeService:init()
	-- Server-to-client event, declared up front like the other server-only events.
	Framework:Listen("ChallengePlayResult", function() end)
end

return ChallengeService