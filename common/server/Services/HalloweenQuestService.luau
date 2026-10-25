-- HALLOWEEN EVENT OFF: the whole module is commented out below.
-- To bring it back, delete this header, the opening `--[==[` and the closing
-- `]==]` + `return {}` at the end of the file.

--[==[
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("HalloweenQuestService")

local HalloweenConfig = SharedConfig.HalloweenConfig
local EventCurrencyConfig = SharedConfig.EventCurrencyConfig
local MapConfig = SharedConfig.MapConfig
local UnitStats = SharedConfig.UnitStats
local WeatherConfig = SharedConfig.WeatherConfig
local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local KEY = HalloweenConfig.PROFILE_KEY
local DIFFICULTY_ORDER = ServerConfig.Difficulty.Order
local RANDOM = HalloweenConfig.RANDOM
local RANDOM_FIELDS = { "Map", "Difficulty", "Class" }

--[[
	The Halloween quests: the contracts again, paying event currency.

	Draw, progress, rollover and claim follow `ContractService` rule for rule, on
	their own profile key (`HalloweenQuests`) so the two never share progress.

	**Progress comes from the contracts' events.** On start this wraps
	`ContractService:Record`: every event a match, a crate, or a login records for the
	contracts is recorded here too, with the same value and context. No tracker had to
	change, and both places (Lobby and Game) count, since this lives in `common`.

	**Rewards follow the pumpkins.** A `Random`-difficulty quest's amount is written
	for its `RewardDifficulty` and scales to the drawn difficulty by the pumpkins a
	full run drops (`PumpkinsPerWave` times the preset's `MaxWaves`).

	**Nothing runs while the event is off** (`EventCurrencyConfig.Enabled = false`):
	no draw, no progress, no claim.

	The claim marks the slot first and pays right after through
	`EventCurrencyService:Add`, with nothing yielding in between, so two clicks do not
	pay twice.
]]

local FLUSH_INTERVAL = 2
local RELEASE_ORDER = 1
local REWARD_ROUNDING = 5

local HalloweenQuestService = {
	Services = {
		DataService = {},
		EventCurrencyService = {},
	},

	-- [Player] = { ["Kind|Index"] = { Kind, Index, Period, Id, Mode, Value, Seen } }
	Pending = {},
}

--[[ INTERNAL ]]

local function now() : number
	return workspace:GetServerTimeNow()
end

local function difficultyRank(name : string?) : number
	return name and table.find(DIFFICULTY_ORDER, name) or 0
end

local function shuffle(list : { any }, rng : Random)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

function HalloweenQuestService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[[ DRAW ]]

local function unlockedMaps(profile) : { string }
	local wins = profile.Stats and profile.Stats.Wins or 0
	local maps = {}

	for _, map in MapConfig.getOrderedMaps() do
		if MapConfig.isUnlocked(map, wins) then
			table.insert(maps, map)
		end
	end

	return maps
end

local function unlockedDifficulties(profile) : { string }
	local difficulties = {}

	for _, name in DIFFICULTY_ORDER do
		if ServerConfig.Difficulty.Get(name).Endless then continue end

		if UnlockConfig.isUnlocked(name, profile.Stats) then
			table.insert(difficulties, name)
		end
	end

	return difficulties
end

local function ownedClasses(profile) : { string }
	local seen = {}
	local classes = {}

	for unitName, amount in (profile.Units or {}) do
		if (tonumber(amount) or 0) <= 0 then continue end

		for _, class in WeatherConfig.GetClasses(unitName) do
			if not seen[class] then
				seen[class] = true
				table.insert(classes, class)
			end
		end
	end

	if #classes == 0 then
		return table.clone(WeatherConfig.ClassList)
	end

	return classes
end

local function ownsUnitWith(profile, stat : string | { string }) : boolean
	local wanted = if typeof(stat) == "table" then stat else { stat }

	for unitName, amount in (profile.Units or {}) do
		local stats = UnitStats[unitName]
		if (tonumber(amount) or 0) > 0 and typeof(stats) == "table" then
			for _, name in wanted do
				if stats[name] ~= nil then
					return true
				end
			end
		end
	end

	return false
end

local function isAvailable(definition, profile) : boolean
	local map = definition.Map
	if map and map ~= RANDOM and not MapConfig.isUnlocked(map, profile.Stats and profile.Stats.Wins or 0) then
		return false
	end

	local difficulty = definition.Difficulty
	if difficulty and difficulty ~= RANDOM and not UnlockConfig.isUnlocked(difficulty, profile.Stats) then
		return false
	end

	if definition.NeedsUnitStat and not ownsUnitWith(profile, definition.NeedsUnitStat) then
		return false
	end

	return true
end

local function rollParams(definition, profile, rng : Random) : { [string] : string }
	local params = {}

	local function pick(list : { string }) : string?
		if #list == 0 then return nil end
		return list[rng:NextInteger(1, #list)]
	end

	if definition.Map == RANDOM then
		params.Map = pick(unlockedMaps(profile)) or "Farm"
	end

	if definition.Difficulty == RANDOM then
		params.Difficulty = pick(unlockedDifficulties(profile)) or DIFFICULTY_ORDER[1]
	end

	if definition.Class == RANDOM then
		params.Class = pick(ownedClasses(profile))
	end

	return params
end

--- Pumpkins a full run of `name` drops, or nil when the difficulty has no fixed length or no rate.
local function runPumpkins(name : string?) : number?
	local perWave = name and HalloweenConfig.PumpkinsPerWave[name]
	if not perWave or not ServerConfig.Difficulty.Exists(name) then
		return nil
	end

	local waves = ServerConfig.Difficulty.Get(name).MaxWaves
	if typeof(waves) ~= "number" or waves == math.huge or waves <= 0 then
		return nil
	end

	return perWave * waves
end

local function scalesWithDifficulty(definition) : boolean
	return definition ~= nil
		and definition.Difficulty == RANDOM
		and runPumpkins(definition.RewardDifficulty) ~= nil
end

--[=[
	The quest's event currency carried from `RewardDifficulty` to the drawn
	difficulty, by the ratio of their full-run pumpkins. Nil when it does not scale.
]=]
local function scaledRewards(definition, params) : { EventCurrency : number }?
	if not scalesWithDifficulty(definition) then return nil end

	local rolled = runPumpkins(params and params.Difficulty)
	if not rolled then return nil end

	local amount = definition.Rewards and definition.Rewards.EventCurrency or 0
	if amount <= 0 then return nil end

	local ratio = rolled / runPumpkins(definition.RewardDifficulty)

	return {
		EventCurrency = math.max(REWARD_ROUNDING, math.floor(amount * ratio / REWARD_ROUNDING + 0.5) * REWARD_ROUNDING),
	}
end

function HalloweenQuestService:_draw(kind : string, previous : { any }, profile, rng : Random) : { any }
	local count = HalloweenConfig.KINDS[kind].Count
	local list = HalloweenConfig.Quests[kind]

	local wasThere = {}
	for _, slot in previous do
		if slot.Id then
			wasThere[slot.Id] = true
		end
	end

	local fresh, repeated, locked = {}, {}, {}
	for _, definition in list do
		if not isAvailable(definition, profile) then
			table.insert(locked, definition)
		elseif wasThere[definition.Id] then
			table.insert(repeated, definition)
		else
			table.insert(fresh, definition)
		end
	end

	shuffle(fresh, rng)
	shuffle(repeated, rng)
	shuffle(locked, rng)

	local slots = {}
	for _, group in { fresh, repeated, locked } do
		for _, definition in group do
			if #slots >= count then break end

			local params = rollParams(definition, profile, rng)

			table.insert(slots, {
				Id = definition.Id,
				Params = params,
				Rewards = scaledRewards(definition, params),
				Progress = 0,
				Claimed = false,
			})
		end
	end

	return slots
end

local function needsRepair(slot) : boolean
	local definition = typeof(slot) == "table" and HalloweenConfig.get(slot.Id)
	if not definition then return false end

	for _, field in RANDOM_FIELDS do
		if definition[field] == RANDOM and not (slot.Params and slot.Params[field]) then
			return true
		end
	end

	return scalesWithDifficulty(definition) and slot.Rewards == nil
end

function HalloweenQuestService:_ensurePeriods(player : Player)
	local profile = self:_profileOf(player)
	if not profile then return end

	local quests = profile[KEY]
	local time = now()

	local stale = {}
	local repair = false
	for _, kind in HalloweenConfig.KIND_ORDER do
		local bucket = typeof(quests) == "table" and quests[kind]
		local period = HalloweenConfig.periodOf(kind, time)

		if not bucket or bucket.Period ~= period then
			stale[kind] = period
		elseif typeof(bucket.Slots) == "table" then
			for _, slot in bucket.Slots do
				if needsRepair(slot) then
					repair = true
				end
			end
		end
	end

	if next(stale) == nil and not repair then return end

	local rng = Random.new()

	self.Services.DataService:Update(player, KEY, function(current)
		current = typeof(current) == "table" and current or HalloweenConfig.createEmpty()

		for _, bucket in current do
			if typeof(bucket) ~= "table" or typeof(bucket.Slots) ~= "table" then continue end

			for _, slot in bucket.Slots do
				if not needsRepair(slot) then continue end

				local definition = HalloweenConfig.get(slot.Id)

				slot.Params = typeof(slot.Params) == "table" and slot.Params or {}
				for field, value in rollParams(definition, profile, rng) do
					if slot.Params[field] == nil then
						slot.Params[field] = value
					end
				end

				if slot.Rewards == nil then
					slot.Rewards = scaledRewards(definition, slot.Params)
				end
			end
		end

		for kind, period in stale do
			local bucket = current[kind]
			local previous = typeof(bucket) == "table" and bucket.Slots or {}

			current[kind] = {
				Period = period,
				Slots = self:_draw(kind, previous, profile, rng),
			}
		end

		return current
	end)
end

--[[ PROGRESS ]]

local function matches(definition, slot, context) : boolean
	if definition.Map then
		if context.Map ~= HalloweenConfig.resolve(definition, slot, "Map") then
			return false
		end
	end

	if definition.Difficulty then
		if context.Difficulty ~= HalloweenConfig.resolve(definition, slot, "Difficulty") then
			return false
		end
	end

	if definition.MinDifficulty then
		if difficultyRank(context.Difficulty) < difficultyRank(definition.MinDifficulty) then
			return false
		end
	end

	if definition.FullHealth and not context.FullHealth then
		return false
	end

	if definition.WithFriends and not context.WithFriends then
		return false
	end

	if definition.Class then
		local class = HalloweenConfig.resolve(definition, slot, "Class")
		if not (class and context.CommonClasses and context.CommonClasses[class]) then
			return false
		end
	end

	if definition.Rarity and context.Rarity ~= definition.Rarity then
		return false
	end

	return true
end

--[=[
	Notes an event for the player's quests it applies to. Same contract as
	`ContractService:Record`; it is called by the wrapper on it (`_hookContracts`).
]=]
function HalloweenQuestService:Record(player : Player, event : string, value : number, context : { [string] : any }?)
	if not EventCurrencyConfig.Enabled then return end

	local profile = self:_profileOf(player)
	local quests = profile and profile[KEY]
	if typeof(quests) ~= "table" then return end

	context = context or {}

	for _, kind in HalloweenConfig.KIND_ORDER do
		local bucket = quests[kind]
		if typeof(bucket) ~= "table" then continue end

		for index, slot in bucket.Slots or {} do
			local definition = HalloweenConfig.get(slot.Id)
			if not definition or definition.Event ~= event then continue end
			if slot.Claimed or (slot.Progress or 0) >= definition.Goal then continue end

			local mode = definition.Mode or "Sum"

			if mode == "Distinct" and slot.Seen and slot.Seen[tostring(value)] then continue end

			if not matches(definition, slot, context) then continue end

			local pending = self.Pending[player]
			if not pending then
				pending = {}
				self.Pending[player] = pending
			end

			local key = kind .. "|" .. index
			local entry = pending[key]

			if not entry or entry.Period ~= bucket.Period or entry.Id ~= slot.Id then
				entry = {
					Kind = kind,
					Index = index,
					Period = bucket.Period,
					Id = slot.Id,
					Mode = mode,
					Value = 0,
				}
				pending[key] = entry
			end

			if mode == "Max" then
				entry.Value = math.max(entry.Value, value)
			elseif mode == "Distinct" then
				entry.Seen = entry.Seen or {}
				entry.Seen[tostring(value)] = true
			else
				entry.Value += value
			end
		end
	end
end

function HalloweenQuestService:Flush(player : Player)
	local pending = self.Pending[player]
	if not pending or next(pending) == nil then return end

	self.Pending[player] = nil

	local profile = self:_profileOf(player)
	if not profile or typeof(profile[KEY]) ~= "table" then return end

	self.Services.DataService:Update(player, KEY, function(quests)
		for _, entry in pending do
			local bucket = quests[entry.Kind]
			local slot = bucket and bucket.Period == entry.Period and bucket.Slots[entry.Index]

			if not slot or slot.Id ~= entry.Id or slot.Claimed then continue end

			local definition = HalloweenConfig.get(slot.Id)
			if not definition then continue end

			local progress = slot.Progress or 0

			if entry.Mode == "Max" then
				progress = math.max(progress, entry.Value)
			elseif entry.Mode == "Distinct" then
				slot.Seen = slot.Seen or {}

				for key in entry.Seen or {} do
					slot.Seen[key] = true
				end

				progress = 0
				for _ in slot.Seen do
					progress += 1
				end
			else
				progress += entry.Value
			end

			slot.Progress = math.min(definition.Goal, math.max(0, math.floor(progress)))
		end

		return quests
	end)
end

--[[ CLAIM ]]

--[=[
	Claims a slot. Returns whether it paid and, when not, the reason: `EventOff`,
	`NotLoaded`, `NoQuest`, `NotComplete`, or `AlreadyClaimed`.
]=]
function HalloweenQuestService:Claim(player : Player, kind : any, index : any) : (boolean, string?)
	if not EventCurrencyConfig.Enabled then
		return false, "EventOff"
	end

	if not HalloweenConfig.isKind(kind) or typeof(index) ~= "number" then
		return false, "NoQuest"
	end

	if not self:_profileOf(player) then
		return false, "NotLoaded"
	end

	self:_ensurePeriods(player)
	self:Flush(player)

	local quests = self:_profileOf(player)[KEY]
	local bucket = quests and quests[kind]
	local slot = bucket and bucket.Slots[index]
	local definition = slot and HalloweenConfig.get(slot.Id)

	if not definition then
		return false, "NoQuest"
	end

	if slot.Claimed then
		return false, "AlreadyClaimed"
	end

	if not HalloweenConfig.isComplete(definition, slot) then
		return false, "NotComplete"
	end

	self.Services.DataService:Update(player, KEY, function(current)
		current[kind].Slots[index].Claimed = true
		return current
	end)

	self.Services.EventCurrencyService:Add(player, HalloweenConfig.rewardOf(definition, slot), "HalloweenQuest")

	return true, nil
end

--[[ LIFECYCLE ]]

--[=[
	Wraps `ContractService:Record` so every contract event is also a quest event.
	Callers reach `Record` through the service table, so the wrapper is what they call.
]=]
function HalloweenQuestService:_hookContracts()
	local contracts = Framework:Get("ContractService", false, true)
	if not contracts or typeof(contracts.Record) ~= "function" then
		log:Warn("no ContractService; Halloween quests will not progress.")
		return
	end

	if contracts.HalloweenQuestsHooked then return end
	contracts.HalloweenQuestsHooked = true

	local original = contracts.Record

	contracts.Record = function(service, player : Player, event : string, value : number, context)
		original(service, player, event, value, context)
		self:Record(player, event, value, context)
	end
end

function HalloweenQuestService:_tick(player : Player)
	if not EventCurrencyConfig.Enabled then return end

	self:_ensurePeriods(player)
	self:Flush(player)
end

function HalloweenQuestService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; Halloween quests will not work.")
		return
	end

	self:_hookContracts()

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_tick(player)
	end)

	for _, player in Players:GetPlayers() do
		if self:_profileOf(player) then
			self:_tick(player)
		end
	end

	if dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:Flush(player)
			self.Pending[player] = nil
		end, RELEASE_ORDER)
	end

	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.Pending[player] = nil
		end)
	end)

	Framework:Listen("ClaimHalloweenQuest", function(player : Player, kind : any, index : any)
		local ok, reason = self:Claim(player, kind, index)
		Framework:Fire("HalloweenQuestClaimResult", player, kind, index, ok, reason)
	end)

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)

			for _, player in Players:GetPlayers() do
				if self:_profileOf(player) then
					self:_tick(player)
				end
			end
		end
	end)
end

function HalloweenQuestService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function HalloweenQuestService:init()
	Framework:Listen("HalloweenQuestClaimResult", function() end)
end

return HalloweenQuestService
]==]

return {}
