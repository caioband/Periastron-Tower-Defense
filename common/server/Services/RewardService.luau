local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("RewardService")

local CrateConfig = SharedConfig.CrateConfig

export type Rewards = {
	Cash : number?,
	Shards : number?,
	Crates : { [string] : number }?,
}

--[[
	Pays a reward bundle to a player on this server: `{ Cash, Shards, Crates }`.

	Shared by every system that hands out a fixed bundle (contracts, codes), so
	they all pay the same way:

	  - Coins also go into `CoinsEarned` (MOST COINS is the total earned, and a
	    contract or a code is earnings).
	  - Crates go through `CrateService` when it exists (the Lobby: it notifies the
	    backpack screen), and straight into the inventory when it does not (the
	    Game and the AFK place).

	`Grant` does not yield. Callers that must not pay twice (a double click) mark
	the claim first and call this right after, with nothing that yields in between.

	See docs/common/codes.md and docs/common/contracts.md.
]]
local RewardService = {
	Services = {
		DataService = {},
	},
}

--[[ EXTERNAL ]]

function RewardService:Grant(player : Player, rewards : Rewards)
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn(`no DataService; reward for {player.Name} not paid.`)
		return
	end

	local cash = math.max(0, math.floor(rewards.Cash or 0))
	local shards = math.max(0, math.floor(rewards.Shards or 0))

	if cash > 0 or shards > 0 then
		dataService:Update(player, "Stats", function(stats)
			stats.Cash = (stats.Cash or 0) + cash
			stats.CoinsEarned = (tonumber(stats.CoinsEarned) or 0) + cash
			stats.Shards = (stats.Shards or 0) + shards
			return stats
		end)
	end

	if not rewards.Crates then return end

	local crateService = Framework:Get("CrateService")

	for rarity, amount in rewards.Crates do
		amount = math.max(0, math.floor(amount))
		if amount <= 0 then continue end

		if crateService and crateService.GiveCrates then
			crateService:GiveCrates(player, rarity, amount)
			continue
		end

		local resolved = CrateConfig.resolveRarity(rarity)
		if not resolved then
			log:StudioWarn(string.format("%q is not a crate tier; reward skipped.", tostring(rarity)))
			continue
		end

		dataService:Update(player, "Inventory", function(inventory)
			inventory = inventory or {}
			inventory.Crates = inventory.Crates or CrateConfig.createEmptyCrates()
			inventory.Crates[resolved] = math.min(
				CrateConfig.MAX_CRATES_PER_RARITY,
				(inventory.Crates[resolved] or 0) + amount
			)
			return inventory
		end)
	end
end

function RewardService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end
end

function RewardService:init()
end

return RewardService
