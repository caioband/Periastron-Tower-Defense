--[[
	The Lobby board's contracts (missions): which exist, what they pay, when they
	roll over, and how the description reads.

	**Three periods, rolling over at fixed times (UTC).** Hourly on the hour, daily
	at midnight UTC, weekly on Monday 00:00 UTC. The rollover is the same for
	everyone; the **draw** is per player (`ContractService`) and only happens when
	the profile sees a new period, on join or at a rollover while online.

	  | Period | Contracts at a time |
	  | Hourly | 2                   |
	  | Daily  | 3                   |
	  | Weekly | 4                   |

	A contract not claimed by the rollover is lost with the period.

	**Variety.** The draw removes the previous period's contracts from the urn
	whenever enough remain without them, and only repeats when it has to.

	**Each contract is a line of data.** `Event` is what it counts, and the rest are
	filters on the event context (map, difficulty...). No game rule runs here:
	`ContractService` matches events to contracts, and the match services
	(`ContractTrackerService` in the Game) and `CrateService` (Lobby) fire the events.

	  | Field | What it is |
	  | --- | --- |
	  | `Id` | the profile key. **Do not change** an existing contract's. |
	  | `Text` | the description. `{Map}`, `{Difficulty}`, and `{Class}` become the drawn value. |
	  | `Event` | what counts (see `Events`) |
	  | `Goal` | how far it counts |
	  | `Mode` | `Sum` (default) adds; `Max` keeps the highest value; `Distinct` counts different values |
	  | `Map` / `Difficulty` / `Class` | the event must be this one; `Random` draws one per player |
	  | `MinDifficulty` | the event's difficulty must be this or higher |
	  | `FullHealth` / `WithFriends` | the win must be with a full base / a friend in the room |
	  | `Rarity` | the rarity of the unit that came out of the crate |
	  | `NeedsUnitStat` | only drawn for players with a unit that has this `UnitStats` field; accepts a list, one is enough |
	  | `Format` | `Hours` shows progress in hours (`Goal` is in seconds) |
	  | `Rewards` | `Cash`, `Shards`, and `Crates` (`{ [crate tier] = count }`, see `CrateConfig.CRATES`) |
	  | `RewardDifficulty` | with `Difficulty = Random`: the difficulty `Rewards` was written for. The reward scales to the drawn one in proportion to a run's prize (`WinCash` for coins, `WinShards` for shards and crates, in `ServerScriptService.Config.Difficulty`) |

	**A scaling reward is computed at draw time** and stored in the slot
	(`Slot.Rewards`), because `Config.Difficulty` is not replicated. The screen and
	the claim read the slot's before the config's.

	**A contract tied to a locked map or difficulty is not drawn** (Nightmare for a
	player who has not unlocked it, Volcano for one with two wins), and `Random`
	draws only among unlocked options. A `Random` difficulty never draws Endless.

	See docs/common/contracts.md.
]]

local MapConfig = require(script.Parent.MapConfig)

local ContractConfig = {}

ContractConfig.RANDOM = "Random"

-- The order sections appear in and the server checks them in.
ContractConfig.KIND_ORDER = { "Hourly", "Daily", "Weekly" }

local HOUR = 3600
local DAY = 24 * HOUR
local WEEK = 7 * DAY

--[[
	`Offset` is where the first period starts, counted from the Unix epoch. January
	1, 1970 was a Thursday, so the first Monday is four days later, and the
	contracts week rolls over on Monday.
]]
ContractConfig.KINDS = {
	Hourly = { Count = 2, Length = HOUR, Offset = 0 },
	Daily = { Count = 3, Length = DAY, Offset = 0 },
	Weekly = { Count = 4, Length = WEEK, Offset = 4 * DAY },
}

--[[
	The board on the Lobby map: `Workspace.<Model>.<Target>` is the center of the
	radius that opens `StarterGui.Contracts`, the same way the counter opens the
	shops (see `ProximityPanel`). One stud more than the shops: `TargetPart` sits on
	the floor, and the distance is measured to the `HumanoidRootPart`, about three
	studs above it.
]]
ContractConfig.Board = {
	Model = "ContractsBoard",
	Target = "TargetPart",
	OpenRadius = 6,
	ProximityInterval = 0.2,
	Animation = "OpenShop",

	-- The HUD button drops the player **on top of** the `TargetPart` itself, the radius
	-- center, not a separate landing marker as with the shops. The height is the same
	-- the shops use, counted from the part's top.
	TeleportHeightOffset = 3,
}

--[[
	Each section's reroll: one developer product per reroll, in order. The period's
	first reroll opens product 1, the second product 2, and from the 7th on it stays
	on the last one.

	The count lives in the profile (`Contracts[kind].Rerolls`) and resets on
	rollover, since the new period starts without it. The reroll redraws the
	**whole** section (claimed slots included), with progress reset and avoiding the
	contracts that were there (see `ContractService:Reroll`).

	The receipt on the server does the crediting: any of these products rerolls its
	section, whatever the count. The number only decides which product the button
	opens.
]]
ContractConfig.Reroll = {
	Button = "RerollDice",

	Products = {
		Hourly = { 3713210488, 3713210581, 3713210596, 3713210618, 3713210662, 3713210676, 3713210698 },
		Daily = { 3713210718, 3713210736, 3713210747, 3713210794, 3713210802, 3713210822, 3713210833 },
		Weekly = { 3713210846, 3713210863, 3713210871, 3713210887, 3713210898, 3713210909, 3713210923 },
	},
}

ContractConfig.Events = {
	Win = "Win",
	WaveReached = "WaveReached",
	Kill = "Kill",
	BossKill = "BossKill",
	Damage = "Damage",
	Stun = "Stun",
	Weather = "Weather",
	MatchCashSpent = "MatchCashSpent",
	MatchCashEarned = "MatchCashEarned",
	MatchTime = "MatchTime",
	Unbox = "Unbox",
	Login = "Login",
}

local E = ContractConfig.Events
local RANDOM = ContractConfig.RANDOM

ContractConfig.Contracts = {
	Hourly = {
		{ Id = "H_Win3", Text = "Win 3 games in any map", Event = E.Win, Goal = 3,
			Rewards = { Cash = 200 } },

		--[[
			Ids that mention a map or difficulty (`H_Win2Castle`, `D_Win3Nightmare`...)
			date from when the field was fixed. They stay on purpose: the Id is the
			profile key, and changing it would reset the progress of players who have
			the contract.
		]]
		{ Id = "H_Win2Castle", Text = "Win 2 games in {Map}", Event = E.Win, Goal = 2, Map = RANDOM,
			Rewards = { Cash = 150 } },

		{ Id = "H_Wave15Desert", Text = "Reach Wave 15 on {Map}", Event = E.WaveReached, Goal = 15, Mode = "Max", Map = RANDOM,
			Rewards = { Cash = 100 } },

		{ Id = "H_Win2Medium", Text = "Win {Difficulty} difficulty twice on any map", Event = E.Win, Goal = 2, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { Cash = 200 } },

		-- "During one match": `Max` keeps the best match, not the sum.
		{ Id = "H_Spend5000", Text = "Spend 5,000 coins during a match", Event = E.MatchCashSpent, Goal = 5000, Mode = "Max",
			Rewards = { Cash = 150 } },

		{ Id = "H_BeatFarmMedium", Text = "Beat {Map} in Medium difficulty or higher", Event = E.Win, Goal = 1, Map = RANDOM, MinDifficulty = "Medium",
			Rewards = { Cash = 200 } },

		{ Id = "H_Kill100", Text = "Kill 100 enemies", Event = E.Kill, Goal = 100,
			Rewards = { Cash = 100 } },

		{ Id = "H_WinFullHealth", Text = "Win with 100% base health", Event = E.Win, Goal = 1, FullHealth = true,
			Rewards = { Cash = 100 } },

		{ Id = "H_Kill200Volcano", Text = "Kill 200 enemies on {Map}", Event = E.Kill, Goal = 200, Map = RANDOM,
			Rewards = { Cash = 150 } },

		{ Id = "H_Damage30k", Text = "Deal 30,000 damage", Event = E.Damage, Goal = 30000,
			Rewards = { Cash = 250 } },

		{ Id = "H_WinFriendsMap", Text = "Win a match in {Map} with 1 or more friends", Event = E.Win, Goal = 1, Map = RANDOM, WithFriends = true,
			Rewards = { Cash = 150 } },
	},

	Daily = {
		{ Id = "D_Win6", Text = "Win 6 games in any map", Event = E.Win, Goal = 6,
			Rewards = { Cash = 500, Shards = 3 } },

		{ Id = "D_Win6VolcanoMedium", Text = "Win 6 games in {Map} on {Difficulty} difficulty", Event = E.Win, Goal = 6, Map = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { Cash = 700, Shards = 3 } },

		-- Only players with a unit that stuns get this: the Electro's jolt (`Stun`),
		-- the Frostione's freeze (`Frost`), or the Volt's charge (`Static`).
		{ Id = "D_Stun676", Text = "Stun enemies 676 times", Event = E.Stun, Goal = 676, NeedsUnitStat = { "Stun", "Frost", "Static" },
			Rewards = { Cash = 800, Shards = 4 } },

		{ Id = "D_Win3Nightmare", Text = "Win 3 games in {Difficulty} mode", Event = E.Win, Goal = 3, Difficulty = RANDOM, RewardDifficulty = "Nightmare",
			Rewards = { Cash = 900, Shards = 8 } },

		-- Round cash in a single match (the `Max`), not profile coins.
		{ Id = "D_Earn20k", Text = "Earn 20,000 Cash in a single match", Event = E.MatchCashEarned, Goal = 20000, Mode = "Max",
			Rewards = { Cash = 500, Shards = 2 } },

		{ Id = "D_Win6Hard", Text = "Win 6 games in {Difficulty} mode", Event = E.Win, Goal = 6, Difficulty = RANDOM, RewardDifficulty = "Hard",
			Rewards = { Cash = 700, Shards = 4 } },

		{ Id = "D_Kill600", Text = "Kill 600 enemies", Event = E.Kill, Goal = 600,
			Rewards = { Cash = 500, Shards = 2 } },

		{ Id = "D_Win4MapDifficulty", Text = "Win 4 games in {Map} on {Difficulty}", Event = E.Win, Goal = 4, Map = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { Cash = 500, Shards = 4 } },

		{ Id = "D_Win5DifficultyFriends", Text = "Win 5 games on {Difficulty} with 1 or more friends", Event = E.Win, Goal = 5, Difficulty = RANDOM, RewardDifficulty = "Medium", WithFriends = true,
			Rewards = { Cash = 400, Shards = 3 } },
	},

	Weekly = {
		{ Id = "W_Win7MapClassNightmare", Text = "Win 7 games in {Map} with only {Class} units in {Difficulty}", Event = E.Win, Goal = 7, Map = RANDOM, Class = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Nightmare",
			Rewards = { Cash = 2000, Shards = 10, Crates = { Epic = 6 } } },

		-- One UTC day at a time, only within the week: all seven are needed.
		{ Id = "W_Login7", Text = "Log in for 7 days straight", Event = E.Login, Goal = 7, Mode = "Distinct",
			Rewards = { Cash = 777, Shards = 7, Crates = { Common = 7, Rare = 7 } } },

		{ Id = "W_Unbox2Legendary", Text = "Unbox 2 Legendary Cards", Event = E.Unbox, Goal = 2, Rarity = "Legendary",
			Rewards = { Crates = { Epic = 4 } } },

		{ Id = "W_Damage1M", Text = "Deal 1,000,000 damage", Event = E.Damage, Goal = 1000000,
			Rewards = { Cash = 8000, Shards = 10 } },

		{ Id = "W_Weather60", Text = "Experience Weathers 60 times", Event = E.Weather, Goal = 60,
			Rewards = { Crates = { Epic = 8 } } },

		{ Id = "W_Boss70", Text = "Defeat 70 bosses", Event = E.BossKill, Goal = 70,
			Rewards = { Shards = 40 } },

		{ Id = "W_Play7Hours", Text = "Play 7 hours worth of matches", Event = E.MatchTime, Goal = 7 * HOUR, Format = "Hours",
			Rewards = { Cash = 2000, Crates = { Epic = 8 } } },

		{ Id = "W_Win20Map", Text = "Win 20 games in {Map} in any difficulty", Event = E.Win, Goal = 20, Map = RANDOM,
			Rewards = { Crates = { Epic = 8 } } },

		{ Id = "W_UnboxCosmic", Text = "Unbox a Cosmic Card", Event = E.Unbox, Goal = 1, Rarity = "Cosmic",
			Rewards = { Crates = { Epic = 10 } } },
	},
}

--[[ INDEX ]]

local byId = {}
local kindOf = {}

for kind, list in ContractConfig.Contracts do
	for _, definition in list do
		assert(byId[definition.Id] == nil, `[ContractConfig]: Id repetido '{definition.Id}'.`)
		byId[definition.Id] = definition
		kindOf[definition.Id] = kind
	end
end

--[[ API ]]

function ContractConfig.get(id : string?) : any?
	return id and byId[id] or nil
end

function ContractConfig.kindOf(id : string?) : string?
	return id and kindOf[id] or nil
end

function ContractConfig.isKind(kind : any) : boolean
	return typeof(kind) == "string" and ContractConfig.KINDS[kind] ~= nil
end

--- The period `now` (Unix seconds) falls in.
function ContractConfig.periodOf(kind : string, now : number) : number
	local info = ContractConfig.KINDS[kind]

	return math.floor((now - info.Offset) / info.Length)
end

--- When the period ends, in Unix seconds.
function ContractConfig.endsAt(kind : string, period : number) : number
	local info = ContractConfig.KINDS[kind]

	return (period + 1) * info.Length + info.Offset
end

--[=[
	A new profile's `Contracts`. `Period = -1` is no period, so the first load draws
	all three.
]=]
function ContractConfig.createEmpty()
	local contracts = {}

	for _, kind in ContractConfig.KIND_ORDER do
		contracts[kind] = { Period = -1, Slots = {} }
	end

	return contracts
end

--- The value of a field that may be `Random`: the slot's drawn value, or the fixed one.
function ContractConfig.resolve(definition, slot, field : string) : any?
	local value = definition[field]

	if value == RANDOM then
		return slot and slot.Params and slot.Params[field] or nil
	end

	return value
end

local function commas(value : number) : string
	local formatted = tostring(math.floor(value))
	local count

	repeat
		formatted, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
	until count == 0

	return formatted
end

local function formatAmount(definition, value : number) : string
	if definition.Format == "Hours" then
		-- One decimal place, rounded down: 6.99 hours must not show as "7/7".
		local hours = math.floor(value / HOUR * 10) / 10
		local text = string.format("%.1f", hours)

		return (string.gsub(text, "%.0$", ""))
	end

	return commas(value)
end

--[=[
	The description with the drawn value in place and progress at the end:
	`Win 4 games in Volcano on Hard (1/4)`.
]=]
function ContractConfig.describe(definition, slot) : string
	local text = definition.Text

	text = string.gsub(text, "{Map}", function()
		local map = ContractConfig.resolve(definition, slot, "Map")
		local resolved = MapConfig.resolveMap(map)
		local entry = resolved and MapConfig.MAPS[resolved]

		return entry and entry.DisplayName or tostring(map or "?")
	end)

	text = string.gsub(text, "{Difficulty}", function()
		return tostring(ContractConfig.resolve(definition, slot, "Difficulty") or "?")
	end)

	text = string.gsub(text, "{Class}", function()
		return tostring(ContractConfig.resolve(definition, slot, "Class") or "?")
	end)

	local progress = math.min(definition.Goal, (slot and slot.Progress) or 0)

	return string.format("%s (%s/%s)", text, formatAmount(definition, progress), formatAmount(definition, definition.Goal))
end

--[=[
	The developer product for the section's next reroll, given how many the player
	has done this period. Past the end of the list, it stays on the last.
]=]
function ContractConfig.rerollProduct(kind : string, rerolls : number?) : number?
	local products = ContractConfig.Reroll.Products[kind]
	if not products or #products == 0 then return nil end

	local index = math.clamp(math.floor(tonumber(rerolls) or 0) + 1, 1, #products)

	return products[index]
end

--- Whether the slot's progress has reached the goal.
function ContractConfig.isComplete(definition, slot) : boolean
	return definition ~= nil and slot ~= nil and (slot.Progress or 0) >= definition.Goal
end

--- Time as `HH:MM:SS`, with hours past 24 (the week shows `167:59:59`).
function ContractConfig.formatRemaining(seconds : number) : string
	seconds = math.max(0, math.floor(seconds))

	return string.format("%02d:%02d:%02d", seconds // HOUR, (seconds // 60) % 60, seconds % 60)
end

return ContractConfig
