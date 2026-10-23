local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local SharedConfig = require(Configs.SharedConfig)

local DifficultyConfig = ServerConfig.Difficulty
local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local Framework = Me.new()
local log = Log.new("DifficultyService")

local ALL_VOTED_GRACE = 2

-- How long it is worth waiting for a newly joined player's client to report that
-- it loaded. Past that, it will not report anymore.
local CLIENT_READY_TIMEOUT = 60

local DifficultyService = {
	Services = {
		MobService = {},

		-- Where the per-difficulty wins and the XP that unlock the higher presets come
		-- from. See `isUnlockedFor`.
		DataService = {}
	},
	Votes = {},
	Selected = nil,
	SelectionActive = false,

	--[[
		A whole preset imposed for the match (`ForcePreset`: challenges). While set, it
		is what `GetSelected` returns, so everything that reads the difficulty
		(`MobService`, `CardShopService`, weather) sees the modified numbers instead of
		the plain preset with the same name.
	]]
	ForcedPreset = nil,
}

function DifficultyService:GetSelected()
	if self.ForcedPreset then
		return self.ForcedPreset
	end

	return DifficultyConfig.Get(self.Selected)
end

--[=[
	Whether this player can already vote for this difficulty.

	It is the same math `DifficultyController` uses to draw the lock, with the same
	config, and here it actually counts: the vote is a name, and a name is something
	any client can send. Without this line, Nightmare would open to someone who never
	won a match, and **one** such vote would be enough to drag the whole room there.

	A profile that has not loaded counts as zero wins and level 1: it shows locked,
	which is the safe side, and the player's screen shows the same thing by the same
	math.

	See docs/game/difficulty-vote.md.
]=]
function DifficultyService:isUnlockedFor(player : Player, difficultyName : string?) : boolean
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	local stats = entry and entry.Profile.Data.Stats

	return UnlockConfig.isUnlocked(difficultyName, typeof(stats) == "table" and stats or nil)
end

function DifficultyService:timeLeft()
	if not self.SelectionEndsAt then return 0 end
	return math.max(0, math.ceil(self.SelectionEndsAt - os.clock()))
end

function DifficultyService:tally()
	local counts = {}
	for _, name in DifficultyConfig.Order do
		counts[name] = 0
	end

	for _, name in self.Votes do
		if counts[name] then
			counts[name] += 1
		end
	end

	return counts
end

function DifficultyService:allVoted()
	local players = Players:GetPlayers()
	if #players == 0 then return false end

	for _, player in players do
		if not self.Votes[player.UserId] then
			return false
		end
	end

	return true
end

function DifficultyService:winner()
	local counts = self:tally()
	local best = nil
	local bestCount = 0

	for _, name in DifficultyConfig.Order do
		if counts[name] > bestCount then
			best = name
			bestCount = counts[name]
		end
	end

	return best or DifficultyConfig.Default
end

--[=[
	The state as this player sees it: the vote is each player's own, the rest is the
	server's. `locked` says whether the match has started; while it is `nil` nobody
	has chosen any difficulty.
]=]
function DifficultyService:stateFor(player : Player, timeLeft : number?, counts : { [string] : number }?)
	return {
		active = self.SelectionActive == true,
		options = DifficultyConfig.Order,
		votes = counts or self:tally(),
		timeLeft = timeLeft,
		selected = self.Votes[player.UserId],
		locked = self.Selected,
	}
end

function DifficultyService:broadcastSelectionState(timeLeft)
	local counts = self:tally()
	for _, player in Players:GetPlayers() do
		Framework:Fire("DifficultySelection", player, self:stateFor(player, timeLeft, counts))
	end
end

--[=[
	Sends the current state to a player who just joined. The vote only speaks while it
	is open, so without this a player who lands in a round that already started would
	never receive a `DifficultySelection`, and their hotbar, which only appears once
	the difficulty is decided, would stay hidden the whole match.

	It waits for the `ClientReady` tag `DataService` sets when the client reports it
	loaded: before that, the controller on the other side is not even listening.
]=]
function DifficultyService:syncPlayer(player : Player)
	local deadline = os.clock() + CLIENT_READY_TIMEOUT

	while not player:HasTag("ClientReady") do
		if os.clock() > deadline or not player:IsDescendantOf(Players) then
			return
		end
		task.wait(0.25)
	end

	Framework:Fire("DifficultySelection", player, self:stateFor(player, self:timeLeft()))
end

--[=[
	Imposes a difficulty without a vote and announces it as decided.

	It is what the tutorial uses. The announcement is not a detail: this state's
	`locked` is what makes the **hotbar appear** on the client
	(`DifficultyController:setHotbarVisible`); without a decided match there is
	nowhere to put cards, and the hotbar starts hidden. Skipping the vote without
	telling anyone would leave the screen with no cards the whole match.

	Players who join later receive the same state through `syncPlayer`, which already
	exists for players landing in a started round.
]=]
function DifficultyService:Force(name : string)
	self.ForcedPreset = nil
	self.Selected = name
	self.SelectionActive = false

	self:broadcastSelectionState(0)
end

--[=[
	Imposes a **whole preset** without a vote: the challenges' difficulty with its
	modifiers already applied (`ChallengeService:GetForcedPreset`).

	Unlike `Force`, it goes the whole way a finished vote goes: the preset reaches
	`MobService` (base health, starting cash) and `DifficultyLocked` goes out, and
	`GetSelected` returns this preset for the rest of the match.
]=]
function DifficultyService:ForcePreset(preset)
	self.ForcedPreset = preset
	self.Selected = preset.Name
	self.SelectionActive = false

	self:broadcastSelectionState(0)

	local mobService = self.Services.MobService
	if mobService then
		mobService:ApplyDifficulty(preset)
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("DifficultyLocked", player, preset.Name)
	end
end

--[=[
	Tells every player which mode the match imposed in place of the vote (a map that
	only plays one mode, see `Config.Difficulty.MapPresets`). The client shows it as a
	notification; the intermission that follows is the usual one.
]=]
function DifficultyService:AnnounceImposed(preset)
	local displayName = preset.DisplayName or preset.Name

	for _, player in Players:GetPlayers() do
		Framework:Fire("DifficultyImposed", player, displayName)
	end
end

function DifficultyService:RunSelection(duration)
	self.ForcedPreset = nil
	self.Votes = {}
	self.Selected = nil
	self.SelectionActive = true
	self.SelectionEndsAt = os.clock() + duration

	self:broadcastSelectionState(self:timeLeft())

	local lastShown = nil
	local shortened = false
	while os.clock() < self.SelectionEndsAt do
		if not shortened and self:allVoted() then
			shortened = true
			self.SelectionEndsAt = math.min(self.SelectionEndsAt, os.clock() + ALL_VOTED_GRACE)
		end

		local remaining = self:timeLeft()
		if remaining ~= lastShown then
			lastShown = remaining
			self:broadcastSelectionState(remaining)
		end
		task.wait(0.2)
	end

	self.Selected = self:winner()
	self.SelectionActive = false
	self:broadcastSelectionState(0)

	local preset = self:GetSelected()

	local mobService = self.Services.MobService
	if mobService then
		mobService:ApplyDifficulty(preset)
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("DifficultyLocked", player, preset.Name)
	end

	return preset
end

--[=[
	Returns the service to its pre-vote state. The chosen difficulty goes too: the
	next round votes again.
]=]
function DifficultyService:ResetRound()
	table.clear(self.Votes)
	self.ForcedPreset = nil
	self.Selected = nil
	self.SelectionActive = false
	self.SelectionEndsAt = nil

	self:broadcastSelectionState(0)
end

function DifficultyService:construct()
	Framework:Listen("SelectDifficulty", function(player, difficultyName)
		if not self.SelectionActive then return end
		if not DifficultyConfig.Exists(difficultyName) then return end

		if not self:isUnlockedFor(player, difficultyName) then
			log:StudioWarn(string.format(
				"%s voted for %s, which is still locked for them.",
				player.Name, difficultyName))
			return
		end

		if self.Votes[player.UserId] == difficultyName then
			self.Votes[player.UserId] = nil
		else
			self.Votes[player.UserId] = difficultyName
		end

		self:broadcastSelectionState(self:timeLeft())
	end)

	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			self:syncPlayer(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.Votes[player.UserId] = nil
	end)
end

function DifficultyService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function DifficultyService:init()
	Framework:Listen("DifficultySelection", function() end)
	Framework:Listen("DifficultyLocked", function() end)
	Framework:Listen("DifficultyImposed", function() end)
end

return DifficultyService