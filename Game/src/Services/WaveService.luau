local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared.Util.PathUtil)
local GameClock = require(Shared.Util.GameClock)

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)
local Signal = require(Packages.Signal)

local WaveConfig = ServerConfig.Wave
local GamepassConfig = SharedConfig.GamepassConfig
local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local TutorialConfig = SharedConfig.TutorialConfig

local Framework = Me.new()
local log = Log.new("WaveService")

local DataConfig = ServerConfig.Data

local INTERMISSION_TIME = 60
local WAVE_INTERVAL = 1.25
local SELECTION_TIME = 15

-- A breather between the last play-again vote and the round actually restarting, so
-- the full counter shows on screen before it leaves.
local PLAY_AGAIN_DELAY = 1.5
local MAX_WAVES = DataConfig.MAX_WAVES
local BASE_WINNING_XP = DataConfig.BASE_WINNING_XP

-- End-of-match coins and shards are each preset's full number
-- (`WinCash`/`WinShards`), not a multiplied base; only XP still works that way.
local DifficultyConfig = ServerConfig.Difficulty

--[[
	Round states. `Finished` is the only one where the play-again vote accepts votes;
	before that the button is not even on screen.
]]
local ROUND_STATE = {
	Idle = "Idle",
	Running = "Running",
	Finished = "Finished",
}

-- Services that keep match state and know how to clean themselves. Each one
-- exposes `ResetRound()`; anything added to this list gets reset along with it.
local ROUND_SCOPED_SERVICES = { "MobService", "UnitService", "DifficultyService", "WeatherRoundService", "SpeedService", "CardShopService" }


local ENDLESS_BADGES = {
	[50] = "Endless50",
	[100] = "Endless100",
	[500] = "Endless500",
}

local WaveService = {
	Services = {
		MobService = {},
		UnitService = {},
		DifficultyService = {},
		DataService = {},
		WeatherRoundService = {},
		SpeedService = {},
		CardShopService = {},
		TutorialMatchService = {},
		BadgeService = {},
	},
	Signals = {
		Ended = Signal.new(),

		--[[
			Fired at the start of each wave, with its number and the preset in use.

			`WeatherRoundService` listens today, rolling the weather die and turning on
			what was scheduled. It is a signal and not a direct call because the round
			does not need to know weather exists: if the service goes away, `setWave`
			stays the same.
		]]
		WaveStarted = Signal.new(),

		--[[
			The round entered `Running` (`RoundStarted`) and left it (`RoundClosed`),
			whether by the end of the match or by a `StopRound`/`ResetRound` midway.

			`MatchStatsService` listens, counting each player's time in the match.
			`RoundClosed` only fires for a round that was running: the results screen's
			reset (`Finished`) closes nothing.
		]]
		RoundStarted = Signal.new(),
		RoundClosed = Signal.new(),

		--[[
			(won : boolean, preset): the match actually ended: last wave won or base
			down. Fires after rewards, with the players who were in the room. Resets and
			leaves do not fire this (only `RoundClosed`).

			`ContractTrackerService` listens: this is the contracts' win, with the map,
			the difficulty, and the current base health.
		]]
		MatchFinished = Signal.new(),
	},
	ReadyPlayers = {},
	PlayAgainVotes = {},

	-- How much each player already received this round, by UserId. Reset every round.
	PaidRewards = {},
	GameOver = false,
	State = ROUND_STATE.Idle,

	-- Incremented on every Start/Stop. Every wait point in the round checks whether the
	-- generation is still its own; if not, that round was discarded and the coroutine
	-- ends on its own. That is what makes a reset safe at any point, even if canceling
	-- the thread fails.
	Generation = 0
}

function WaveService:setWave(waveCount : number)
	self.WaveCount = waveCount

	-- The wave composition is a server secret; the client only needs "is there a
	-- boss?" to switch the music at the start of the wave.
	local preset = self.Difficulty or self.Services.DifficultyService:GetSelected()
	local hasBoss = WaveConfig.HasBoss(waveCount, preset and preset.Name)

	for _, Player in Players:GetPlayers() do
		Framework:Fire("SetWave", Player, self.WaveCount, hasBoss)
	end

	self.Signals.WaveStarted:Fire(self.WaveCount, preset, self:getMaxWaves(preset))
end

function WaveService:waitForAllPlayers()
	while true do
		local allReady = true
		for _, player in Players:GetPlayers() do
			if not player:HasTag("ClientReady") then
				allReady = false
			end
		end

		if allReady and #Players:GetPlayers() > 0 then
			break
		end
		task.wait(0.5)
	end
end

function WaveService:timeLeft()
	if not self.IntermissionEndsAt then return 0 end
	return math.max(0, math.ceil(self.IntermissionEndsAt - os.clock()))
end

function WaveService:allReady()
	local players = Players:GetPlayers()
	if #players == 0 then return false end
	for _, player in players do
		if not self.ReadyPlayers[player.UserId] then
			return false
		end
	end
	return true
end

function WaveService:broadcastReadyState(timeLeft)
	local readyCount = 0
	local total = 0
	for _, player in Players:GetPlayers() do
		total += 1
		if self.ReadyPlayers[player.UserId] then
			readyCount += 1
		end
	end
	for _, player in Players:GetPlayers() do
		Framework:Fire("WaveIntermission", player, {
			active = self.IntermissionActive == true,
			ready = readyCount,
			total = total,
			timeLeft = timeLeft,
			isReady = self.ReadyPlayers[player.UserId] == true,
		})
	end
end

function WaveService:runIntermission(duration)
	self.ReadyPlayers = {}
	self.IntermissionActive = true
	self.IntermissionEndsAt = os.clock() + duration

	self:broadcastReadyState(self:timeLeft())

	local lastShown = nil
	while os.clock() < self.IntermissionEndsAt do
		if self:allReady() then break end
		local remaining = self:timeLeft()
		if remaining ~= lastShown then
			lastShown = remaining
			self:broadcastReadyState(remaining)
		end
		task.wait(0.2)
	end

	self.IntermissionActive = false
	self.ReadyPlayers = {}
	self:broadcastReadyState(0)
end

--[=[
	End-of-match reward: coins, shards, and XP at once.

	Coins and XP are linear in the fraction of waves survived. Shards are not: they only
	start after `SHARD_WAVE_THRESHOLD` and then follow a curve, so the expensive currency
	concentrates on those who get close to the end.
]=]
--[=[
	How many waves the match has. Each difficulty has its own (`MaxWaves`, the size
	of its table in `Config.Waves`); `DataConfig.MAX_WAVES` is only a fallback for
	when no preset is selected.
]=]
--[=[
	Pays the wave-completion reward to every player in the match.

	It is the only money in the game that does not depend on what the player did: not
	for damage, kills, or farms, but for the wave having ended. So it goes out equally
	to everyone, including players who joined mid-match.

	`runRound` calls it, after the game-over check: a wave that ended because the base
	fell does not pay.

	See docs/game/rewards.md.
]=]
function WaveService:payWaveCash()
	local amount = WaveConfig.GetWaveCash(self.WaveCount)
	if amount <= 0 then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	for _, player in Players:GetPlayers() do
		mobService:addCash(player, amount)
	end
end

function WaveService:awardEndlessMilestones(clearedWave : number)
	local badgeName = ENDLESS_BADGES[clearedWave]
	if not badgeName then return end

	local badgeService = self.Services.BadgeService
	if not badgeService then return end

	for _, player in Players:GetPlayers() do
		task.spawn(badgeService.Award, badgeService, player, badgeName)
	end
end


function WaveService:getMaxWaves(preset)
	preset = preset or self.Difficulty
	return (preset and preset.MaxWaves) or MAX_WAVES
end

--[=[
	NEW: Endless reward curve.

	Returns how many "wave-equivalents" a run of `waves` cleared waves is worth.
	Every wave adds a weight, and the total is what coins/XP/shards scale from:

	* waves 1..EarlyUntil          -> EarlyWeight each (stingy)
	* waves EarlyUntil+1..RampUntil -> ramp from EarlyWeight up to 1.0
	* waves past RampUntil          -> 1 + LateGrowth * (wave - RampUntil), uncapped

	Every weight is positive, so the total only ever goes up with the wave count.
]=]
function WaveService:endlessProgressUnits(curve, waves : number) : number
	local total = 0

	for w = 1, waves do
		local weight

		if w <= curve.EarlyUntil then
			weight = curve.EarlyWeight
		elseif w <= curve.RampUntil then
			local t = (w - curve.EarlyUntil) / (curve.RampUntil - curve.EarlyUntil)
			weight = curve.EarlyWeight + (1 - curve.EarlyWeight) * t
		else
			weight = 1 + curve.LateGrowth * (w - curve.RampUntil)
		end

		total += weight
	end

	return total
end

--[=[
	A match's reward, by the fraction of waves survived.

	`lost` separates the base falling from the player reaching the end:

	* **Defeat** (`true`): no shards, and coins are multiplied by
	  `LOSS_CASH_MULTIPLIER`. Losing on the last wave must not pay almost as much as
	  winning: the whole run is the product, not the time standing.
	* **Victory or leaving** (`false`/`nil`): the full math. `GrantLeaveReward` calls
	  without the argument on purpose: someone leaving a round that is still running did
	  not lose, their match just did not end.
]=]
function WaveService:computeReward(preset, lost : boolean?)
	-- Without a preset (a leave before the vote ended) the reward is the default's,
	-- the same the `or 1` multipliers gave when the base was Medium's.
	preset = preset or DifficultyConfig.Get(nil)

	-- CHANGED: Endless with a RewardCurve is uncapped and weighted per wave;
	-- every other preset keeps the old clamped, linear progress.
	local maxWaves = preset.RewardWaves or self:getMaxWaves(preset)
	local progress

	if preset.Endless and preset.RewardCurve then
		local wavesCleared = math.max(0, math.floor(self.WaveCount or 0))
		progress = maxWaves > 0 and (self:endlessProgressUnits(preset.RewardCurve, wavesCleared) / maxWaves) or 0
	else
		local wavesSurvived = math.clamp(self.WaveCount or 0, 0, maxWaves)
		progress = maxWaves > 0 and (wavesSurvived / maxWaves) or 0
	end

	-- The full-run reward is the preset's; someone leaving early gets the fraction of waves.
	local coins = (preset.WinCash or 0) * progress
	local xp = BASE_WINNING_XP * progress * (preset.WinXpMultiplier or 1)

	local shards = 0
	local threshold = DataConfig.SHARD_WAVE_THRESHOLD or 0
	if threshold < 1 and progress > threshold then
		local normalized = (progress - threshold) / (1 - threshold)
		shards = (preset.WinShards or 0) * (normalized ^ (DataConfig.SHARD_CURVE or 1))
	end

	if lost then
		coins *= (DataConfig.LOSS_CASH_MULTIPLIER or 1)

		-- Zeroed after the curve, not by skipping the math: defeat does not change **when**
		-- shards would start dropping, it removes all of them.
		shards = 0
	end

	return {
		coins = math.max(0, math.floor(coins + 0.5)),
		shards = math.max(0, math.floor(shards + 0.5)),
		xp = math.max(0, math.floor(xp + 0.5)),
	}
end

--[=[
	**This** player's reward: the match base, already multiplied by the gamepasses their
	profile declares (2x Coins, 1.5x Shards, the VIP's XP).

	The base is a single one for the whole room: it comes from the waves survived and the
	difficulty, which belong to the match and not to anyone. What belongs to each player
	is the multiplier, which is why it comes in here and not in `computeReward`: two
	people in the same run end with different numbers without the run having two
	computations.

	A profile that has not loaded multiplies by 1: the base game's full reward, never
	zero. It is rounded at the end, not before: multiplying an already rounded number
	loses the half point twice.
]=]
function WaveService:rewardsFor(player : Player, rewards)
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	local profile = entry and entry.Profile.Data or nil

	return {
		coins = math.floor(rewards.coins * GamepassConfig.coinMultiplier(profile) + 0.5),
		shards = math.floor(rewards.shards * GamepassConfig.shardMultiplier(profile) + 0.5),
		xp = math.floor(rewards.xp * GamepassConfig.xpMultiplier(profile) + 0.5),
	}
end

--[=[
	Credits the match reward to the player's profile, minus what they already received
	this round.

	The discount is what lets the leave reward coexist with the round-end reward.
	Without it, two cases break: someone leaving at the exact instant of the end would
	be paid by `onRoundEnded` and again on leave, and someone leaving on wave 19 and
	returning to the same round would get both rewards in full.

	Since the math grows with the wave and what was already paid is subtracted, the
	total of someone joining and leaving mid-match never exceeds what someone who stayed
	the whole round received. Returns `false` when there is nothing to pay.
]=]
function WaveService:grantReward(player : Player, rewards) : boolean
	local paid = self.PaidRewards[player.UserId]

	local coins = math.max(0, rewards.coins - (paid and paid.coins or 0))
	local shards = math.max(0, rewards.shards - (paid and paid.shards or 0))
	local xp = math.max(0, rewards.xp - (paid and paid.xp or 0))

	if coins <= 0 and shards <= 0 and xp <= 0 then return false end

	local dataService = self.Services.DataService
	if not dataService then return false end

	self.PaidRewards[player.UserId] = {
		coins = (paid and paid.coins or 0) + coins,
		shards = (paid and paid.shards or 0) + shards,
		xp = (paid and paid.xp or 0) + xp,
	}

	dataService:Update(player, "Stats", function(stats)
		stats.Cash = (stats.Cash or 0) + coins

		-- The total earned, which never goes down (MOST COINS). The game's coin gains are
		-- this and contract claims (`ContractService`); the other `+=` on `Cash`
		-- are purchase refunds and Cmdr.
		stats.CoinsEarned = (tonumber(stats.CoinsEarned) or 0) + coins

		stats.Shards = (stats.Shards or 0) + shards
		stats.XP = (stats.XP or 0) + xp
		return stats
	end)

	return true
end

--[=[
	Raises the player's Endless best (`Stats.EndlessBestWave`, the Highest Endless
	leaderboard). It only goes up: a worse run never lowers it.
]=]
function WaveService:recordEndlessBest(player : Player, waveNumber : number)
	local dataService = self.Services.DataService
	if not dataService then return end

	dataService:Update(player, "Stats", function(stats)
		if waveNumber > (tonumber(stats.EndlessBestWave) or 0) then
			stats.EndlessBestWave = math.floor(waveNumber)
		end
		return stats
	end)
end


--[=[
	The reward for someone leaving before the end, by choice or because the server is
	shutting down.

	It is the same math as the round end (`computeReward`), already proportional to the
	waves survived: someone leaving on wave 18 of 20 gets almost everything, someone
	leaving on 2 gets almost nothing. Nothing is sent to the client: there is no results
	screen for someone who is leaving.

	Only while the round is running. In `Finished`, `onRoundEnded` already paid everyone
	in the room, and in `Idle` there is no match to pay: leaving during the difficulty
	vote or the intermission earns no reward, and the math would return zero anyway
	(wave 0).

	`DataService` calls it, with the profile still open (see `OnBeforeRelease`), not the
	`PlayerRemoving` here: that guarantees the credit goes in before the session closes
	on both exit paths.
]=]
function WaveService:GrantLeaveReward(player : Player)
	if self.State ~= ROUND_STATE.Running then return end

	local preset = self.Difficulty or self.Services.DifficultyService:GetSelected()
	local rewards = self:rewardsFor(player, self:computeReward(preset))

	if self:grantReward(player, rewards) then
		log:Debug(string.format(
			"%s left at wave %d/%d; prorated reward paid (%d coins, %d shards, %d XP).",
			player.Name, self.WaveCount or 0, self:getMaxWaves(preset), rewards.coins, rewards.shards, rewards.xp))
	end
end

function WaveService:onRoundEnded(won : boolean)
	local preset = self.Difficulty or self.Services.DifficultyService:GetSelected()
	local maxWaves = if preset.Endless then math.max(1, self.WaveCount or 0) else self:getMaxWaves(preset)

	-- Here the match is over, so "did not win" means defeat, not "still
	-- running", which is `GrantLeaveReward`'s case.
	local rewards = self:computeReward(preset, not won and not preset.Endless)
	local dataService = self.Services.DataService

	local mobService = self.Services.MobService
	local mvp = mobService and mobService:GetMVP() or nil

	for _, player in Players:GetPlayers() do
		-- One computation per player: the base belongs to the match, the gamepasses to each player.
		-- This number (what they actually received) is what goes to their screen.
		local playerRewards = self:rewardsFor(player, rewards)

		self:grantReward(player, playerRewards)

		if won then
			-- A won tutorial settles the matter on the profile. `TutorialService` is
			-- common to both places, so what writes here is the same that reads in the Lobby.
			local tutorialMatch = self.Services.TutorialMatchService
			if tutorialMatch and tutorialMatch:IsTutorial() then
				local tutorialService = Framework:Get("TutorialService", false, false)

				if tutorialService then
					tutorialService:Complete(player)
				end

				-- The win is also onboarding funnel step 10, and it tells
				-- `TutorialMatchService` this player's leave is not abandonment.
				tutorialMatch:NoteWon()

				local analytics = Framework:Get("AnalyticsService", false, false)

				if analytics then
					analytics:LogFunnelStep(player, "MatchWon")
				end
			end

			--[[
				The win on the profile. It is the only place that writes `Stats.Wins`: the
				Lobby leaderstats' "Wins" column reads exactly this key, and without this it
				would stay at the template's zero forever.

				Separate from `grantReward` on purpose: that is proportional to the waves and
				also pays those who leave midway; this is binary and only applies to those in
				the room when the last wave fell.
			]]
			if dataService then
				dataService:Update(player, "Stats", function(stats)
					stats.Wins = (stats.Wins or 0) + 1

					--[[
						The same win counted again, now with the difficulty it happened on:
						that is what unlocks the higher difficulties
						(`SharedConfig.DifficultyUnlockConfig`). The total above does not work
						for that: it cannot say whether the wins are Easy's or Impossible's.

						The key is created here, on the first win at that difficulty, instead of
						coming ready from the template: the preset list belongs to the server
						config, and copying it into the profile would be the same list in two
						places. Readers treat a missing key as zero.
					]]
					local difficultyWins = stats[UnlockConfig.WINS_KEY]
					if typeof(difficultyWins) ~= "table" then
						difficultyWins = {}
						stats[UnlockConfig.WINS_KEY] = difficultyWins
					end

					difficultyWins[preset.Name] = (difficultyWins[preset.Name] or 0) + 1

					return stats
				end)
			end

			Framework:Fire("Win", player)
		end

		Framework:Fire("RoundReward", player, {
			won = won,
			rewards = playerRewards,
			wavesSurvived = math.clamp(self.WaveCount or 0, 0, maxWaves),
			maxWaves = maxWaves,
			mvp = mvp,
		})
	end

	--[[
		The tutorial script's wrap-up: the results screen is the last thing it points at,
		and the step opens with it. The client waits for the screen to finish revealing
		before lighting the spotlight: from here there is no way to know where the
		animation is.

		Outside the tutorial it does nothing.
	]]
	local tutorial = self.Services.TutorialMatchService
	if tutorial then
		tutorial:BeginFinal()
	end

	self.Signals.MatchFinished:Fire(won, preset)
end

function WaveService:getArrowLeadTime()
	local cfg = SharedConfig.ArrowConfig

	-- The longest route rules: the arrows on the longer side must reach the end
	-- before the first enemy spawns.
	local longest = 0
	for _, route in self.Services.MobService:getRoutes() do
		longest = math.max(longest, route.smooth.length)
	end

	local traversal = longest / cfg.Speed
	local lastArrowFinish = (cfg.Count - 1) * cfg.Stagger + traversal
	return lastArrowFinish + cfg.Buffer
end

--[[ round lifecycle ]]

function WaveService:isCurrent(generation : number)
	return self.Generation == generation
end

--[=[
	Waits for the wave to end in a way that can be aborted.

	`Signal:Wait()` does not work here: if the round's thread is canceled while waiting,
	the signal's internal connection is left hanging and the next `Fire` tries to wake a
	dead thread. Here the connection is ours, and `StopRound` releases it before
	canceling the thread.

	Returns false when the round was discarded during the wait.
]=]
function WaveService:awaitWaveEnd(generation : number)
	local thread = coroutine.running()
	local finished = false
	local connection

	local function release()
		if finished then return end
		finished = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
		self.WaveAwaiter = nil
	end

	connection = self.Signals.Ended:Connect(function()
		if finished then return end
		release()
		task.spawn(thread)
	end)

	self.WaveAwaiter = release

	coroutine.yield()

	return self:isCurrent(generation)
end

function WaveService:runRound(generation : number)
	self:waitForAllPlayers()
	if not self:isCurrent(generation) then return end

	-- The tutorial does not vote: its match is designed to be won, and choosing
	-- `Nightmare` there would be choosing to lose. Receiving a preset from
	-- `TutorialMatchService`, the vote does not even open, and the client, which only shows
	-- the screen when the server announces it, shows nothing.
	local tutorial = self.Services.TutorialMatchService
	local forced = tutorial and tutorial:GetForcedPreset()

	local preset = forced or self.Services.DifficultyService:RunSelection(SELECTION_TIME)
	if not self:isCurrent(generation) then return end
	self.Difficulty = preset

	-- Skipping the vote must not mean "nobody decided anything": the decided-difficulty
	-- state is what makes the hotbar appear on screen.
	if forced then
		self.Services.DifficultyService:Force(TutorialConfig.Match.Difficulty)
	end

	--[[
		The tutorial's first step happens **here**, in the intermission, not in a wave: it
		points at the Ready button and closes when the countdown ends, on time or earlier
		if the player clicks. It opens before the countdown on purpose, so the dialog runs
		with the clock still full.

		Outside the tutorial both calls do nothing.
	]]
	if tutorial then
		tutorial:BeginIntermission()
	end

	self:runIntermission(preset.IntermissionTime or INTERMISSION_TIME)
	if not self:isCurrent(generation) then return end

	if tutorial then
		tutorial:NoteIntermissionEnd()
	end

	local won = false
	while not self.GameOver do
		self:setWave((self.WaveCount or 0) + 1)

		-- The tutorial script opens **before** enemies spawn, and may hold the
		-- wave while the step is not completed (wave 1 does not spawn with the map
		-- empty). Outside the tutorial both calls do nothing.
		if tutorial then
			tutorial:BeginStep(self.WaveCount)
			tutorial:AwaitStep(self.WaveCount)

			if not self:isCurrent(generation) then return end
		end

		--[[
			Real time on purpose, even when sped up: this wait exists for the path arrows to
			finish running before the first enemy spawns, and `WaveController` draws them,
			animating in screen time. Shortening only this side would put the enemy on the
			map with the arrow still midway through the route.

			Only wave 1 waits, because only wave 1 has arrows: the client plays them once
			to teach the path, and from wave 2 on there is nothing running on the route to
			wait for; the wait would be idle time with an empty map.
		]]
		if self.WaveCount == 1 then
			task.wait(self:getArrowLeadTime())
			if not self:isCurrent(generation) then return end
		end

		--[[
			The base can fall **between** two waves.

			What is left on the map is the skipped wave (`SkipWave`): the loop moves on
			with its enemies still walking, and they keep reaching the end of the path
			during the intermission, the tutorial step, and the arrow wait above.
			`MobService`'s `onGameOver` raises the flag in the meantime, but its `Ended`
			wakes nobody: the loop was not waiting for any wave end.

			Without this check the next wave would spawn anyway and the match would go on
			with the base down. The wave announced now never spawned, so the counter goes
			back to the last one that actually happened: the reward comes from it.
		]]
		if self.GameOver then
			self.WaveCount = math.max(0, (self.WaveCount or 1) - 1)
			break
		end

		-- Real time, like the arrow wait just above: `SkipService` counts from here the
		-- seconds until offering the skip vote.
		self.WaveStartedAt = os.clock() --.

		if preset.Endless then
			for _, player in Players:GetPlayers() do
				self:recordEndlessBest(player, self.WaveCount)
			end
		end

		self.Services.MobService:SpawnWave(self.WaveCount)

		if not self:awaitWaveEnd(generation) then return end
		if self.GameOver then break end

		-- Before the victory check on purpose: the last wave is also a completed
		-- wave, and it pays like the others.
		self:payWaveCash()

		if preset.Endless then
			self:awardEndlessMilestones(self.WaveCount)
		end

		if self.WaveCount >= self:getMaxWaves(preset) then
			won = true
			self.GameOver = true
			break
		end

		-- The breather between waves is match pace, so it shrinks with it.
		GameClock.Wait(preset.WaveInterval or WAVE_INTERVAL)
		if not self:isCurrent(generation) then return end
	end

	self:onRoundEnded(won)
end

--[[ skipping the wave ]]

--[=[
	Whether the wave on now can be skipped.

	There are four conditions, all about the round loop, not the player: the round must
	be running, the loop must be **waiting for a wave to end** (`WaveAwaiter`), the wave
	must have finished spawning (`AllMobsSpawned`), and there must be a next wave.

	`AllMobsSpawned` is the most important of the four: skipping mid-spawn would put two
	`SpawnWave` coroutines in the air at once, and the first to finish would say the whole
	wave spawned when only one of them did.

	The last wave does not skip because there is nowhere to go: `WaveCount >= MaxWaves`
	is the victory condition right below `awaitWaveEnd`, and bringing it forward would
	hand over the match with enemies still on the path.
]=]
function WaveService:CanSkipWave() : boolean
	if self.State ~= ROUND_STATE.Running or self.GameOver then return false end
	if not self.WaveAwaiter then return false end
	if (self.WaveCount or 0) >= self:getMaxWaves() then return false end

	local mobService = self.Services.MobService

	return mobService ~= nil and mobService.AllMobsSpawned == true
end

--[=[
	Starts the next wave without waiting for the current one to end. `SkipService` calls
	it when the vote closes.

	It is the same `Ended` `MobService` fires when the last enemy dies: to the round
	loop, the wave is over, and it pays like any other (wave money and farm income). The
	difference is on the map, not in the code: the leftover enemies keep walking, keep
	paying for damage and kills, and can still take down the base. Skipping trades
	waiting for risk, not for a discount.

	The two `Ended`s do not interfere: until the next wave calls `awaitWaveEnd` again
	nobody is listening, and from then on `MobService` only fires when **all** living
	enemies die, leftovers included.
]=]
function WaveService:SkipWave() : boolean
	if not self:CanSkipWave() then return false end

	log:Debug(string.format("wave %d skipped by vote.", self.WaveCount or 0))
	self.Signals.Ended:Fire()

	return true
end

--[=[
	Starts a round from scratch. It cleans nothing: for a clean match call
	`ResetRound()`, which resets the services and calls this at the end.
]=]
function WaveService:StartRound()
	if self.State == ROUND_STATE.Running then
		log:StudioWarn("StartRound ignored; a round is already running.")
		return false
	end

	self.Generation += 1
	local generation = self.Generation

	self.State = ROUND_STATE.Running
	self.GameOver = false
	self.WaveCount = 0
	table.clear(self.PaidRewards)

	self.Signals.RoundStarted:Fire()

	self.RoundThread = task.spawn(function()
		self:runRound(generation)

		-- Only ends if nobody started another round along the way.
		if self:isCurrent(generation) then
			self.State = ROUND_STATE.Finished
			self.RoundThread = nil

			self.Signals.RoundClosed:Fire()

			-- The play-again vote opens with the results screen.
			self:broadcastPlayAgain()
		end
	end)

	return true
end

--[=[
	Aborts whatever is going on (vote, intermission, mid-wave) and leaves the server in
	Idle. It does not clear enemies or units; that is `ResetRound`.
]=]
function WaveService:StopRound(reason : string?)
	local wasRunning = self.State == ROUND_STATE.Running

	-- Invalidates the generation before anything else: whatever escapes the cancellation
	-- finds a different generation at the next wait point and ends on its own.
	self.Generation += 1

	-- A scheduled play-again must not survive a stop.
	self:cancelPlayAgainRestart()

	if self.WaveAwaiter then
		self.WaveAwaiter()
		self.WaveAwaiter = nil
	end

	-- Canceling our own thread would kill whoever asked for the stop.
	if self.RoundThread and self.RoundThread ~= coroutine.running() then
		pcall(task.cancel, self.RoundThread)
	end
	self.RoundThread = nil

	self.State = ROUND_STATE.Idle
	self.IntermissionActive = false
	self.IntermissionEndsAt = nil
	self.GameOver = false
	table.clear(self.ReadyPlayers)

	if wasRunning then
		self.Signals.RoundClosed:Fire()
	end

	if reason then
		log:Debug(string.format("round interrupted (%s).", reason))
	end
end

--- Whether a round is `Running` now (from waiting for players until the end).
function WaveService:IsRoundRunning() : boolean
	return self.State == ROUND_STATE.Running
end

--[=[
	Returns the match to zero. It can be called at any time (during the difficulty vote,
	mid-wave, on the results screen) and from anywhere on the server:

		local Framework = require(ReplicatedStorage.Shared.Vendor.Me).new()
		Framework:Get("WaveService"):ResetRound()

	`autoStart = false` leaves the server stopped in Idle waiting for a `StartRound()`;
	any other value restarts immediately.
]=]
function WaveService:ResetRound(autoStart : boolean?)
	self:StopRound("reset")

	self.WaveCount = 0
	self.Difficulty = nil
	table.clear(self.ReadyPlayers)
	table.clear(self.PlayAgainVotes)
	table.clear(self.PaidRewards)

	for _, serviceName in ROUND_SCOPED_SERVICES do
		local service = self.Services[serviceName]
		if service and service.ResetRound then
			service:ResetRound()
		end
	end

	-- Only `RoundRestarted`: firing `SetWave` here would make the client play the sound
	-- and arrows of a "wave 0". WaveController resets the counter itself.
	for _, player in Players:GetPlayers() do
		Framework:Fire("RoundRestarted", player)
	end

	if autoStart ~= false then
		self:StartRound()
	end
end

--[[ play-again vote ]]

function WaveService:playAgainTally()
	local voted = 0
	local total = 0

	for _, player in Players:GetPlayers() do
		total += 1
		if self.PlayAgainVotes[player.UserId] then
			voted += 1
		end
	end

	return voted, total
end

function WaveService:broadcastPlayAgain()
	local voted, total = self:playAgainTally()

	for _, player in Players:GetPlayers() do
		Framework:Fire("PlayAgainState", player, {
			votes = voted,
			total = total,
			voted = self.PlayAgainVotes[player.UserId] == true,
			active = self.State == ROUND_STATE.Finished,
		})
	end
end

function WaveService:cancelPlayAgainRestart()
	if self.PlayAgainRestart then
		pcall(task.cancel, self.PlayAgainRestart)
		self.PlayAgainRestart = nil
	end
end

--[=[
	Unanimity among those on the server. Players who leave stop counting, so a player
	who abandons the results screen does not block the others' restart.

	Once the vote closes, the reset waits PLAY_AGAIN_DELAY, time for the last player to
	see the full counter before the screen leaves. The window is cancelable: anyone
	removing their vote (or joining the server) in that interval drops the schedule, and
	the condition is checked again at firing time.
]=]
function WaveService:evaluatePlayAgain()
	if self.State ~= ROUND_STATE.Finished then
		self:cancelPlayAgainRestart()
		return
	end

	local voted, total = self:playAgainTally()
	if total == 0 or voted < total then
		self:cancelPlayAgainRestart()
		return
	end

	if self.PlayAgainRestart then return end

	self.PlayAgainRestart = task.delay(PLAY_AGAIN_DELAY, function()
		-- Cleared first: the ResetRound below goes through StopRound, which would cancel
		-- exactly this thread if it were still registered.
		self.PlayAgainRestart = nil

		if self.State ~= ROUND_STATE.Finished then return end

		local currentVoted, currentTotal = self:playAgainTally()
		if currentTotal == 0 or currentVoted < currentTotal then return end

		self:ResetRound()
	end)
end

--[[ leaving to the Lobby ]]

function WaveService:sendToLobby(player : Player)
	if not player or not player.Parent then return end

	-- Match cash is volatile, but the round reward already went to the profile:
	-- saving before leaving avoids losing the last reward.
	local dataService = self.Services.DataService
	if dataService and dataService.Save then
		dataService:Save(player)
	end

	--[[
		The return from the tutorial carries a ticket: `TutorialDone`.

		That is how the Lobby knows to point at the shop as soon as the player lands
		there, and it is **only** a ticket: nothing is saved to the profile. A nudge that
		happens once, right after the match, not a milestone that survives a logout.
	]]
	local tutorialMatch = self.Services.TutorialMatchService
	local options = nil

	if tutorialMatch and tutorialMatch:IsTutorial() then
		options = Instance.new("TeleportOptions")
		options:SetTeleportData({ TutorialDone = true })
	end

	local success, err = pcall(function()
		TeleportService:TeleportAsync(Environment.GetPlaceId("Lobby"), { player }, options)
	end)

	if not success then
		log:Warn(string.format("teleport of %s to the lobby failed (%s).", player.Name, tostring(err)))
		Framework:Fire("LobbyTeleportFailed", player)
	end
end

function WaveService:construct()
	Framework:Listen("ReadyWave", function(player)
		if not self.IntermissionActive then return end
		if self.ReadyPlayers[player.UserId] then
			self.ReadyPlayers[player.UserId] = nil
		else
			self.ReadyPlayers[player.UserId] = true
		end
		self:broadcastReadyState(self:timeLeft())
	end)

	Framework:Listen("VotePlayAgain", function(player)
		if self.State ~= ROUND_STATE.Finished then return end

		if self.PlayAgainVotes[player.UserId] then
			self.PlayAgainVotes[player.UserId] = nil
		else
			self.PlayAgainVotes[player.UserId] = true
		end

		self:broadcastPlayAgain()
		self:evaluatePlayAgain()
	end)

	Framework:Listen("RequestLobbyTeleport", function(player)
		self:sendToLobby(player)
	end)

	--[[
		The leave reward does not go here: it needs the profile open, and the order
		between this `PlayerRemoving` and `DataService`'s is not guaranteed.
		`DataService` itself calls `GrantLeaveReward`, right before closing the session,
		which also covers server shutdown, where `PlayerRemoving` does not always fire.
	]]
	local dataService = self.Services.DataService
	if dataService and dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player)
			self:GrantLeaveReward(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		self.PlayAgainVotes[player.UserId] = nil

		-- The player who left may have been the only missing vote.
		if self.State == ROUND_STATE.Finished then
			task.defer(function()
				self:broadcastPlayAgain()
				self:evaluatePlayAgain()
			end)
		end
	end)

	TeleportService.TeleportInitFailed:Connect(function(player, _result, message)
		log:Warn(string.format("TeleportInitFailed for %s (%s).", player.Name, tostring(message)))
		Framework:Fire("LobbyTeleportFailed", player)
	end)

	self:StartRound()
end

function WaveService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function WaveService:init()
	Framework:Listen("SetWave", function() end)
	Framework:Listen("WaveIntermission", function() end)
	Framework:Listen("Win", function() end)
	Framework:Listen("RoundReward", function() end)
	Framework:Listen("PlayAgainState", function() end)
	Framework:Listen("RoundRestarted", function() end)
	Framework:Listen("LobbyTeleportFailed", function() end)
end

return WaveService