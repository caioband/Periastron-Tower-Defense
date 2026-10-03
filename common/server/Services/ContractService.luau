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
local log = Log.new("ContractService")

local ContractConfig = SharedConfig.ContractConfig
local MapConfig = SharedConfig.MapConfig
local UnitStats = SharedConfig.UnitStats
local WeatherConfig = SharedConfig.WeatherConfig
local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local DIFFICULTY_ORDER = ServerConfig.Difficulty.Order
local RANDOM = ContractConfig.RANDOM

--[[
	The player's contracts: draw, progress, claim, and payout.

	It lives in `common` because both places touch them. **Game** is where almost
	everything counts (win, kill, damage, weather...), through
	`ContractTrackerService`; the **Lobby** counts crates (`CrateService`) and is where
	the board is, and therefore the claim. Login counts in both. And both must draw:
	the hour can roll over with the player mid-match.

	**The draw is per player, and only happens on rollover.** On every tick, and when
	the profile loads, each period is compared with the current one; if it changed,
	that period's slots are drawn again (see `_draw`). Unclaimed contracts are lost
	with it, so there is nothing to clean up.

	**Progress is batched.** `Record` only notes into a per-player queue; `Flush`
	writes everything in one pass (`Update` of `Contracts`), every `FLUSH_INTERVAL`,
	on claim, and on leave. One write per event would replicate the whole
	`Contracts` on every enemy killed. Each queue entry remembers the slot's period
	and `Id`, so progress for a contract that expired mid-batch does not land on the
	one that replaced it.

	**The claim belongs to the server.** The client sends only "slot N of period X";
	this service checks it is complete and not yet paid. Marking as paid and paying
	happen in sequence, with nothing yielding in between, so two clicks do not pay
	twice.

	See docs/common/contracts.md.
]]

-- How often the queue is written, rollovers are checked, and login is
-- marked.
local FLUSH_INTERVAL = 2

-- After those that still write progress on leave (`ContractTrackerService`, with
-- the match's last reading). See `DataService:OnBeforeRelease`.
local RELEASE_ORDER = 1

local ContractService = {
	Services = {
		DataService = {},
		MonetizationService = {},
		RewardService = {},
	},

	-- [Player] = { ["Kind|Index"] = { Kind, Index, Period, Id, Mode, Value, Seen } }
	Pending = {},
}

--[[ INTERNAL ]]

local function now() : number
	return workspace:GetServerTimeNow()
end

local function dayIndex() : number
	return math.floor(now() / 86400)
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

function ContractService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[[ DRAW ]]

--- The maps the player can already choose.
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

--- The difficulties the player can already vote for.
local function unlockedDifficulties(profile) : { string }
	local difficulties = {}

	for _, name in DIFFICULTY_ORDER do
		if UnlockConfig.isUnlocked(name, profile.Stats) then
			table.insert(difficulties, name)
		end
	end

	return difficulties
end

--[=[
	The classes of the units the player owns. "Win with only Fire" could not be done
	by a player with no Fire unit; with no units at all, any class.
]=]
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

--[=[
	Whether the player has any unit with the requested field in `UnitStats`. `stat`
	accepts a single name or a list, and one is enough: "stuns", today, is `Stun`
	(the Electro's jolt) or `Frost` (the Frostione's freeze).
]=]
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

--[=[
	Whether the contract can be drawn for this player: a fixed map and difficulty
	must be unlocked, and `NeedsUnitStat` requires a unit that has it.
]=]
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

-- The fields that accept `Random` (see `rollParams`).
local RANDOM_FIELDS = { "Map", "Difficulty", "Class" }

--- What each field's `Random` draws from, among what this player has unlocked.
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

--[[ REWARD BY DIFFICULTY ]]

-- The larger it is, the rounder: 213 coins become 215.
local CASH_ROUNDING = 5

--[=[
	Whether the contract's reward follows the drawn difficulty: only when the
	difficulty is `Random` and the contract says which difficulty its `Rewards` were
	written for (`RewardDifficulty`).
]=]
local function scalesWithDifficulty(definition) : boolean
	return definition ~= nil
		and definition.Difficulty == RANDOM
		and ServerConfig.Difficulty.Exists(definition.RewardDifficulty)
end

--[=[
	The contract's `Rewards` carried from `RewardDifficulty` to the drawn difficulty.

	The ratio is that of a full run's reward in `Config.Difficulty`: coins by
	`WinCash`, shards and crates by `WinShards`. If a Nightmare run pays 4x Medium,
	the Nightmare contract also pays 4x. Changing the presets rebalances the next
	draws' contracts without touching this.

	Coins round to `CASH_ROUNDING`; shards and crates to the nearest integer, never
	below 1 when the base pays something. Returns nil when the contract does not
	scale; then the config's `Rewards` apply.
]=]
local function scaledRewards(definition, params) : { [string] : any }?
	if not scalesWithDifficulty(definition) then return nil end

	local difficulty = params and params.Difficulty
	if not ServerConfig.Difficulty.Exists(difficulty) then return nil end

	local base = ServerConfig.Difficulty.Get(definition.RewardDifficulty)
	local rolled = ServerConfig.Difficulty.Get(difficulty)

	local cashRatio = (rolled.WinCash or 0) / math.max(1, base.WinCash or 0)
	local shardRatio = (rolled.WinShards or 0) / math.max(1, base.WinShards or 0)

	local function scaleCount(amount : number?) : number?
		if not amount or amount <= 0 then return amount end
		return math.max(1, math.floor(amount * shardRatio + 0.5))
	end

	local rewards = definition.Rewards or {}
	local result = {}

	if rewards.Cash and rewards.Cash > 0 then
		result.Cash = math.max(CASH_ROUNDING, math.floor(rewards.Cash * cashRatio / CASH_ROUNDING + 0.5) * CASH_ROUNDING)
	end

	result.Shards = scaleCount(rewards.Shards)

	if rewards.Crates then
		result.Crates = {}
		for tier, amount in rewards.Crates do
			result.Crates[tier] = scaleCount(amount)
		end
	end

	return result
end

--[=[
	The slots for a new period.

	The urn is the period's list filtered by what the player can do. Contracts from
	the previous period (`previous`) go to the end: the draw takes new ones first,
	and only fills in with repeats when there are not enough new ones. If even that
	does not add up (a player with almost everything locked), it fills in with what
	the filter had removed, so the section never shows a gap.
]=]
function ContractService:_draw(kind : string, previous : { any }, profile, rng : Random) : { any }
	local count = ContractConfig.KINDS[kind].Count
	local list = ContractConfig.Contracts[kind]

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
				-- Nil when the contract does not scale: the config's `Rewards` apply.
				Rewards = scaledRewards(definition, params),
				Progress = 0,
				Claimed = false,
			})
		end
	end

	return slots
end

--[=[
	Whether an already-drawn slot needs repair: a `Random` field with no value in
	`Params`, or a difficulty reward that has not been computed yet.

	It happens when the config changes mid-period. Without the value, `matches`
	would never match (the contract would be impossible until rollover, a week on
	the weekly), and without `Rewards` the slot would pay the config's reward on any
	difficulty.
]=]
local function needsRepair(slot) : boolean
	local definition = typeof(slot) == "table" and ContractConfig.get(slot.Id)
	if not definition then return false end

	for _, field in RANDOM_FIELDS do
		if definition[field] == RANDOM and not (slot.Params and slot.Params[field]) then
			return true
		end
	end

	return scalesWithDifficulty(definition) and slot.Rewards == nil
end

--[=[
	Redraws every period that rolled over. A single write for all three, and none
	when nothing rolled over, which is the case on almost every tick.

	In the same write, it repairs slots that need it (`needsRepair`): only the
	missing field is drawn, the reward comes from the slot's difficulty, and progress
	stays.
]=]
function ContractService:_ensurePeriods(player : Player)
	local profile = self:_profileOf(player)
	if not profile then return end

	local contracts = profile.Contracts
	local time = now()

	local stale = {}
	local repair = false
	for _, kind in ContractConfig.KIND_ORDER do
		local bucket = contracts and contracts[kind]
		local period = ContractConfig.periodOf(kind, time)

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

	self.Services.DataService:Update(player, "Contracts", function(current)
		current = typeof(current) == "table" and current or ContractConfig.createEmpty()

		for _, bucket in current do
			if typeof(bucket) ~= "table" or typeof(bucket.Slots) ~= "table" then continue end

			for _, slot in bucket.Slots do
				if not needsRepair(slot) then continue end

				local definition = ContractConfig.get(slot.Id)

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

--[=[
	Whether the event applies to this slot. Each contract field is a condition on the
	context; a field the contract does not have filters nothing.
]=]
local function matches(definition, slot, context) : boolean
	if definition.Map then
		if context.Map ~= ContractConfig.resolve(definition, slot, "Map") then
			return false
		end
	end

	if definition.Difficulty then
		if context.Difficulty ~= ContractConfig.resolve(definition, slot, "Difficulty") then
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

	-- "Only X units": `CommonClasses` is what **every** placed unit has in common.
	if definition.Class then
		local class = ContractConfig.resolve(definition, slot, "Class")
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
	Notes an event for the player's contracts it applies to. It writes nothing:
	writing is `Flush`'s job.

	`value` is how much to add (`Sum`), the value to compare (`Max`), or the value to
	mark (`Distinct`). `context` carries what the filters look at: `Map`,
	`Difficulty`, `FullHealth`, `WithFriends`, `CommonClasses`, `Rarity`.
]=]
function ContractService:Record(player : Player, event : string, value : number, context : { [string] : any }?)
	local profile = self:_profileOf(player)
	local contracts = profile and profile.Contracts
	if typeof(contracts) ~= "table" then return end

	context = context or {}

	for _, kind in ContractConfig.KIND_ORDER do
		local bucket = contracts[kind]
		if typeof(bucket) ~= "table" then continue end

		for index, slot in bucket.Slots or {} do
			local definition = ContractConfig.get(slot.Id)
			if not definition or definition.Event ~= event then continue end
			if slot.Claimed or (slot.Progress or 0) >= definition.Goal then continue end

			local mode = definition.Mode or "Sum"

			-- Today's day, already marked, does not need to go through the queue again every tick.
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

--- Writes the player's queue to the profile, in a single pass.
function ContractService:Flush(player : Player)
	local pending = self.Pending[player]
	if not pending or next(pending) == nil then return end

	self.Pending[player] = nil

	if not self:_profileOf(player) then return end

	self.Services.DataService:Update(player, "Contracts", function(contracts)
		for _, entry in pending do
			local bucket = contracts[entry.Kind]
			local slot = bucket and bucket.Period == entry.Period and bucket.Slots[entry.Index]

			if not slot or slot.Id ~= entry.Id or slot.Claimed then continue end

			local definition = ContractConfig.get(slot.Id)
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

		return contracts
	end)
end

--[[ REROLL ]]

--[=[
	Redraws the whole `kind` tab and adds one to its reroll count. Only the developer
	product receipt calls this (see `construct`): there is no client event for it,
	because the only proof of payment is the receipt.

	Everything goes: claimed or not, with progress or not. The new contracts avoid
	the ones that were there whenever enough remain (`_draw`'s `previous`).

	The progress queue is written **first**: it points at the slot by index, period,
	and `Id`, and a reroll that drew the same contract in the same place would
	receive the previous one's progress.

	Returns false when the reroll could not happen (profile closed); then the receipt
	comes back as `NotProcessedYet` and Roblox retries.
]=]
function ContractService:Reroll(player : Player, kind : string) : boolean
	if not ContractConfig.isKind(kind) or not self:_profileOf(player) then
		return false
	end

	-- Rollover first: paid in the period's last second, the reroll applies to the new one.
	self:_ensurePeriods(player)
	self:Flush(player)

	local profile = self:_profileOf(player)
	local rng = Random.new()
	local rerolled = false

	self.Services.DataService:Update(player, "Contracts", function(current)
		local bucket = current and current[kind]
		if typeof(bucket) ~= "table" then return current end

		local previous = typeof(bucket.Slots) == "table" and bucket.Slots or {}

		bucket.Slots = self:_draw(kind, previous, profile, rng)
		bucket.Rerolls = (tonumber(bucket.Rerolls) or 0) + 1
		rerolled = true

		return current
	end)

	return rerolled
end

--[[ CLAIM ]]

--[=[
	Claims a slot. Returns whether it paid and, when not, the reason: `NotLoaded`,
	`NoContract`, `NotComplete`, or `AlreadyClaimed`.

	The queue is written before the check: the event that completed the contract may
	be in it, and a player who saw "CLAIM" light up must not hear "incomplete".
]=]
function ContractService:Claim(player : Player, kind : any, index : any) : (boolean, string?)
	if not ContractConfig.isKind(kind) or typeof(index) ~= "number" then
		return false, "NoContract"
	end

	if not self:_profileOf(player) then
		return false, "NotLoaded"
	end

	self:_ensurePeriods(player)
	self:Flush(player)

	local contracts = self:_profileOf(player).Contracts
	local bucket = contracts and contracts[kind]
	local slot = bucket and bucket.Slots[index]
	local definition = slot and ContractConfig.get(slot.Id)

	if not definition then
		return false, "NoContract"
	end

	if slot.Claimed then
		return false, "AlreadyClaimed"
	end

	if not ContractConfig.isComplete(definition, slot) then
		return false, "NotComplete"
	end

	self.Services.DataService:Update(player, "Contracts", function(current)
		current[kind].Slots[index].Claimed = true
		return current
	end)

	-- The slot's own, when the drawn difficulty changed it (`scaledRewards`).
	self.Services.RewardService:Grant(player, slot.Rewards or definition.Rewards or {})

	return true, nil
end

--[[ LIFECYCLE ]]

function ContractService:_tick(player : Player)
	self:_ensurePeriods(player)

	-- Login counts by the day the player is online, not just on join: someone who
	-- plays through midnight also marks the new day.
	self:Record(player, ContractConfig.Events.Login, dayIndex())
	self:Flush(player)
end

function ContractService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; contracts will not work.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_tick(player)
	end)

	for _, player in Players:GetPlayers() do
		if self:_profileOf(player) then
			self:_tick(player)
		end
	end

	-- Whatever is left in the queue goes in with the profile still open, after the
	-- leave-time writers.
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

	Framework:Listen("ClaimContract", function(player : Player, kind : any, index : any)
		local ok, reason = self:Claim(player, kind, index)
		Framework:Fire("ContractClaimResult", player, kind, index, ok, reason)
	end)

	--[[
		Paid rerolls: each product of each tab credits one reroll for it. Registered in
		both places, because an unprocessed receipt comes back wherever the player is,
		and they may have gone to a match before then.
	]]
	local monetization = self.Services.MonetizationService
	if monetization then
		for kind, products in ContractConfig.Reroll.Products do
			for _, productId in products do
				monetization:RegisterProduct(productId, function(player : Player)
					return self:Reroll(player, kind)
				end)
			end
		end
	else
		log:Warn("no MonetizationService; contract rerolls will not be credited.")
	end

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

function ContractService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function ContractService:init()
	-- Only the server fires this one; without the empty Listen the client would wait
	-- ten seconds for the identifier (see docs/architecture/me-framework.md).
	Framework:Listen("ContractClaimResult", function() end)
end

return ContractService
