local ContractConfig = require(script.Parent.ContractConfig)
local SkinConfig = require(script.Parent.SkinConfig)
local NametagConfig = require(script.Parent.NametagConfig)

--[[
	The Halloween event: the Spooky Merchant's shop (skins and titles for event
	currency) and the Halloween quests.

	Quests are the contracts again, paying event currency. Same periods, same rollover
	(`ContractConfig.KINDS`), same events and filters, so `ContractConfig.describe`
	and friends work on these definitions untouched. Ids are their own (`HQ_`) and
	live under their own profile key, so contracts and quests never share progress.

	**Balance.** Pumpkins drop per wave by difficulty (`PumpkinsPerWave`), so a full
	run pays:

		| Difficulty | Waves | Per wave | Full run |
		| Easy       |    15 |        5 |       75 |
		| Medium     |    20 |       10 |      200 |
		| Hard       |    25 |       15 |      375 |
		| Impossible |    30 |       25 |      750 |
		| Nightmare  |    35 |       20 |      700 |

	A quest pays about a quarter of what the runs it takes already drop, with Medium
	(200 a run) as the reference for "any difficulty" quests; dailies and weeklies get
	a little on top for the commitment. With `Difficulty = Random` and a
	`RewardDifficulty`, the amount is written for that difficulty and scales to the
	drawn one by full-run pumpkins (see `HalloweenQuestService`).

	`PumpkinsPerWave` here only drives that scaling; the drops themselves are the
	Game place's.
]]

local HalloweenConfig = {}

HalloweenConfig.PROFILE_KEY = "HalloweenQuests"

-- The pumpkin from `HUD.HUDMiddle.EventCurrency.ImageLabel`, not the plate behind it.
HalloweenConfig.CURRENCY_ICON = "rbxassetid://83080487979327"

HalloweenConfig.RANDOM = ContractConfig.RANDOM
HalloweenConfig.KINDS = ContractConfig.KINDS
HalloweenConfig.Events = ContractConfig.Events

-- The order the sections appear in on the Quest tab.
HalloweenConfig.KIND_ORDER = { "Daily", "Hourly", "Weekly" }

HalloweenConfig.PumpkinsPerWave = {
	Easy = 5,
	Medium = 10,
	Hard = 15,
	Nightmare = 20,
	Impossible = 25,
}

--[[
	`Workspace.<Model>` and, searched in depth, `<Target>`: the radius center that
	opens `StarterGui.HalloweenUI`. Distance is measured to the `HumanoidRootPart`.
]]
HalloweenConfig.Merchant = {
	Model = "SpookyMerchant",
	Target = "Base",
	OpenRadius = 8,
	ProximityInterval = 0.2,
	Animation = "OpenShop",
}

--[[
	What the merchant sells, in display order. `Id` is the `SkinConfig` /
	`NametagConfig` id; `Price` is event currency.
]]
HalloweenConfig.Shop = {
	Skins = {
		{ Id = "AwesomeSkin", Price = 1000 },
	},

	Titles = {
		{ Id = "PumpkinPatch", Price = 500 },
		{ Id = "GraveCandle", Price = 750 },
		{ Id = "Phantom", Price = 1000 },
		{ Id = "WitchsBrew", Price = 1500 },
		{ Id = "BloodMoon", Price = 2500 },
	},
}

local CATALOGS = {
	Skins = SkinConfig,
	Titles = NametagConfig,
}

local E = ContractConfig.Events
local RANDOM = ContractConfig.RANDOM
local HOUR = 3600

HalloweenConfig.Quests = {
	Hourly = {
		{ Id = "HQ_H_Win3", Text = "Win 3 games in any map", Event = E.Win, Goal = 3,
			Rewards = { EventCurrency = 150 } },

		{ Id = "HQ_H_Win2Map", Text = "Win 2 games in {Map}", Event = E.Win, Goal = 2, Map = RANDOM,
			Rewards = { EventCurrency = 100 } },

		{ Id = "HQ_H_Wave15Map", Text = "Reach Wave 15 on {Map}", Event = E.WaveReached, Goal = 15, Mode = "Max", Map = RANDOM,
			Rewards = { EventCurrency = 40 } },

		{ Id = "HQ_H_Win2Difficulty", Text = "Win {Difficulty} difficulty twice on any map", Event = E.Win, Goal = 2, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { EventCurrency = 100 } },

		{ Id = "HQ_H_Spend5000", Text = "Spend 5,000 coins during a match", Event = E.MatchCashSpent, Goal = 5000, Mode = "Max",
			Rewards = { EventCurrency = 40 } },

		{ Id = "HQ_H_BeatMapMedium", Text = "Beat {Map} in Medium difficulty or higher", Event = E.Win, Goal = 1, Map = RANDOM, MinDifficulty = "Medium",
			Rewards = { EventCurrency = 60 } },

		{ Id = "HQ_H_Kill100", Text = "Kill 100 enemies", Event = E.Kill, Goal = 100,
			Rewards = { EventCurrency = 30 } },

		{ Id = "HQ_H_WinFullHealth", Text = "Win with 100% base health", Event = E.Win, Goal = 1, FullHealth = true,
			Rewards = { EventCurrency = 75 } },

		{ Id = "HQ_H_Kill200Map", Text = "Kill 200 enemies on {Map}", Event = E.Kill, Goal = 200, Map = RANDOM,
			Rewards = { EventCurrency = 40 } },

		{ Id = "HQ_H_Damage30k", Text = "Deal 30,000 damage", Event = E.Damage, Goal = 30000,
			Rewards = { EventCurrency = 50 } },

		{ Id = "HQ_H_WinFriendsMap", Text = "Win a match in {Map} with 1 or more friends", Event = E.Win, Goal = 1, Map = RANDOM, WithFriends = true,
			Rewards = { EventCurrency = 60 } },
	},

	Daily = {
		{ Id = "HQ_D_Win6", Text = "Win 6 games in any map", Event = E.Win, Goal = 6,
			Rewards = { EventCurrency = 300 } },

		{ Id = "HQ_D_Win6MapDifficulty", Text = "Win 6 games in {Map} on {Difficulty} difficulty", Event = E.Win, Goal = 6, Map = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { EventCurrency = 350 } },

		{ Id = "HQ_D_Stun676", Text = "Stun enemies 676 times", Event = E.Stun, Goal = 676, NeedsUnitStat = { "Stun", "Frost", "Static" },
			Rewards = { EventCurrency = 300 } },

		{ Id = "HQ_D_Win3Nightmare", Text = "Win 3 games in {Difficulty} mode", Event = E.Win, Goal = 3, Difficulty = RANDOM, RewardDifficulty = "Nightmare",
			Rewards = { EventCurrency = 550 } },

		{ Id = "HQ_D_Earn20k", Text = "Earn 20,000 Cash in a single match", Event = E.MatchCashEarned, Goal = 20000, Mode = "Max",
			Rewards = { EventCurrency = 150 } },

		{ Id = "HQ_D_Win6Hard", Text = "Win 6 games in {Difficulty} mode", Event = E.Win, Goal = 6, Difficulty = RANDOM, RewardDifficulty = "Hard",
			Rewards = { EventCurrency = 550 } },

		{ Id = "HQ_D_Kill600", Text = "Kill 600 enemies", Event = E.Kill, Goal = 600,
			Rewards = { EventCurrency = 125 } },

		{ Id = "HQ_D_Win4MapDifficulty", Text = "Win 4 games in {Map} on {Difficulty}", Event = E.Win, Goal = 4, Map = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { EventCurrency = 225 } },

		{ Id = "HQ_D_Win5DifficultyFriends", Text = "Win 5 games on {Difficulty} with 1 or more friends", Event = E.Win, Goal = 5, Difficulty = RANDOM, RewardDifficulty = "Medium", WithFriends = true,
			Rewards = { EventCurrency = 275 } },
	},

	Weekly = {
		{ Id = "HQ_W_Win7MapClassDifficulty", Text = "Win 7 games in {Map} with only {Class} units in {Difficulty}", Event = E.Win, Goal = 7, Map = RANDOM, Class = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Nightmare",
			Rewards = { EventCurrency = 1500 } },

		{ Id = "HQ_W_Login7", Text = "Log in for 7 days straight", Event = E.Login, Goal = 7, Mode = "Distinct",
			Rewards = { EventCurrency = 750 } },

		{ Id = "HQ_W_Unbox2Legendary", Text = "Unbox 2 Legendary Cards", Event = E.Unbox, Goal = 2, Rarity = "Legendary",
			Rewards = { EventCurrency = 750 } },

		{ Id = "HQ_W_Damage1M", Text = "Deal 1,000,000 damage", Event = E.Damage, Goal = 1000000,
			Rewards = { EventCurrency = 1000 } },

		{ Id = "HQ_W_Weather60", Text = "Experience Weathers 60 times", Event = E.Weather, Goal = 60,
			Rewards = { EventCurrency = 1000 } },

		{ Id = "HQ_W_Boss70", Text = "Defeat 70 bosses", Event = E.BossKill, Goal = 70,
			Rewards = { EventCurrency = 1250 } },

		{ Id = "HQ_W_Play7Hours", Text = "Play 7 hours worth of matches", Event = E.MatchTime, Goal = 7 * HOUR, Format = "Hours",
			Rewards = { EventCurrency = 1500 } },

		{ Id = "HQ_W_Win20Map", Text = "Win 20 games in {Map} in any difficulty", Event = E.Win, Goal = 20, Map = RANDOM,
			Rewards = { EventCurrency = 1000 } },

		{ Id = "HQ_W_UnboxCosmic", Text = "Unbox a Cosmic Card", Event = E.Unbox, Goal = 1, Rarity = "Cosmic",
			Rewards = { EventCurrency = 1000 } },
	},
}

--[[ INDEX ]]

local byId = {}

for _, list in HalloweenConfig.Quests do
	for _, definition in list do
		assert(byId[definition.Id] == nil, `[HalloweenConfig]: duplicate quest Id '{definition.Id}'.`)
		byId[definition.Id] = definition
	end
end

for category, list in HalloweenConfig.Shop do
	for _, item in list do
		assert(CATALOGS[category], `[HalloweenConfig]: unknown shop category '{category}'.`)
		if not CATALOGS[category].Get(item.Id) then
			warn(`[HalloweenConfig]: '{item.Id}' is not in the {category} catalog; it will not be sold.`)
		end
	end
end

--[[ QUESTS ]]

function HalloweenConfig.get(id : string?) : any?
	return id and byId[id] or nil
end

function HalloweenConfig.isKind(kind : any) : boolean
	return ContractConfig.isKind(kind)
end

function HalloweenConfig.createEmpty()
	return ContractConfig.createEmpty()
end

--- What the slot pays: the drawn difficulty's amount when it scaled, the config's otherwise.
function HalloweenConfig.rewardOf(definition, slot) : number
	local scaled = slot and slot.Rewards and slot.Rewards.EventCurrency
	if typeof(scaled) == "number" then
		return scaled
	end

	return definition and definition.Rewards and definition.Rewards.EventCurrency or 0
end

HalloweenConfig.resolve = ContractConfig.resolve
HalloweenConfig.periodOf = ContractConfig.periodOf
HalloweenConfig.endsAt = ContractConfig.endsAt
HalloweenConfig.describe = ContractConfig.describe
HalloweenConfig.isComplete = ContractConfig.isComplete
HalloweenConfig.formatRemaining = ContractConfig.formatRemaining

--[[ SHOP ]]

--[=[
	The shop entry and its catalog definition, or nil when the item is not sold
	(unknown category, not listed, or missing from its catalog).
]=]
function HalloweenConfig.getShopItem(category : any, id : any) : (any?, any?)
	local list = typeof(category) == "string" and HalloweenConfig.Shop[category]
	if not list or typeof(id) ~= "string" then
		return nil, nil
	end

	for _, item in list do
		if item.Id == id then
			local definition = CATALOGS[category].Get(id)
			if definition then
				return item, definition
			end

			return nil, nil
		end
	end

	return nil, nil
end

return HalloweenConfig