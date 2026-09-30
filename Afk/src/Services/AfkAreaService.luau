local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local AfkShared = ReplicatedStorage:WaitForChild("Afk")

local AfkRewards = require(AfkShared:WaitForChild("AfkRewards"))

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)

local Framework = Me.new()
local log = Log.new("AfkAreaService")

--[[
	How long each player has been in the AFK area, and what the area pays for it.

	  - **The timer.** It starts when the player's profile opens and runs until they
	    leave. It is shown over every head with the `TimeSpent` billboard from
	    `ReplicatedStorage`, which is cloned into each character's `Head` and
	    rewritten every second here, so every player sees everyone's time.

	  - **The rewards.** `ReplicatedStorage.Afk.AfkRewards` is the list. An entry with
	    `Interval = 300` pays every time the timer crosses another multiple of 300.
	    Payouts are worked out from the elapsed time, not by counting ticks, so a
	    slow tick never loses one: it pays everything owed on the next.

	  - **The write.** Payouts go through `CurrencyService:Apply`, which goes
	    through `DataService:Update`: that is what changes the profile *and* what
	    replicates the new value to the client (the coin counter listens to it).
	    Right after a payout the profile is also saved, instead of waiting for
	    ProfileStore's autosave, so a crash cannot take back coins the player
	    already saw arrive.

	The payout does **not** touch `Stats.CoinsEarned`: that counter is the MOST COINS
	leaderboard, meant for coins earned by playing matches.

	AFK state (`AfkService`) is irrelevant here on purpose: this area exists for
	people who are idle, so being away from the keyboard still counts as time in it.
]]

-- The billboard in `ReplicatedStorage` that goes over every head, and the name it
-- gets on the head.
local TIME_SPENT_GUI = "TimeSpent"

-- Seconds between timer updates.
local TICK_SECONDS = 1

-- Player attribute holding when the timer started (`workspace:GetServerTimeNow()`); the client reads it for the reward countdown.
local ENTERED_ATTRIBUTE = AfkRewards.EnteredAttribute

-- Seconds before the same player can ask to go back to the Lobby again. It also stops a spammer queueing a teleport per click.
local RETURN_COOLDOWN = 10

local AfkAreaService = {
	Services = {
		DataService = {},
		CurrencyService = {},
	},

	-- [Player] = `os.clock()` when their profile opened. Time in the area counts from here.
	Entered = {},

	-- [Player] = { [reward Id] = payouts already made }.
	Granted = {},

	-- [Player] = the `TextLabel` of the billboard on their current character.
	Labels = {},

	-- [Player] = true while a request to go back to the Lobby is cooling down.
	Leaving = {},
}

--[[ INTERNAL ]]

--- `HH:MM:SS`, the same shape as the billboard's placeholder text.
local function formatDuration(totalSeconds : number) : string
	local seconds = math.max(0, math.floor(totalSeconds))

	return string.format("%02d:%02d:%02d", seconds // 3600, seconds % 3600 // 60, seconds % 60)
end

function AfkAreaService:_hasProfile(player : Player) : boolean
	local profiles = self.Services.DataService.Profiles

	return profiles ~= nil and profiles[player] ~= nil
end

function AfkAreaService:_track(player : Player)
	if self.Entered[player] ~= nil then return end

	self.Entered[player] = os.clock()
	self.Granted[player] = {}
	player:SetAttribute(ENTERED_ATTRIBUTE, workspace:GetServerTimeNow())

	log:Debug(player.Name, "entered the area.")
end

function AfkAreaService:_forget(player : Player)
	self.Entered[player] = nil
	self.Granted[player] = nil
	self.Labels[player] = nil
	self.Leaving[player] = nil
	player:SetAttribute(ENTERED_ATTRIBUTE, nil)
end

function AfkAreaService:_updateLabel(player : Player, elapsed : number)
	local label = self.Labels[player]
	if label and label.Parent then
		label.Text = formatDuration(elapsed)
	end
end

--[=[
	Pays whatever the player is owed on every reward. Nothing is marked as paid
	unless `Apply` accepted it, so a failed payout is retried on the next tick.
]=]
function AfkAreaService:_payRewards(player : Player, elapsed : number)
	local granted = self.Granted[player]
	if not granted then return end

	local paidSomething = false

	for _, reward in self.Active do
		local alreadyPaid = granted[reward.Id] or 0
		local owed = math.floor(elapsed / reward.Interval) - alreadyPaid
		if owed <= 0 then continue end

		local _, updated, err = self.Services.CurrencyService:Apply(player, reward.Currency, "add", reward.Amount * owed)
		if err then
			log:Warn(string.format("could not pay '%s' to %s: %s", reward.Id, player.Name, err))
			continue
		end

		granted[reward.Id] = alreadyPaid + owed
		paidSomething = true

		log:Debug(string.format("paid %d %s to %s for '%s' (now %d).", reward.Amount * owed, reward.Currency, player.Name, reward.Id, updated or 0))
	end

	if paidSomething then
		-- `Save` yields on the DataStore: it must not hold up everyone else's tick.
		task.spawn(function()
			self.Services.DataService:Save(player)
		end)
	end
end

function AfkAreaService:_step(player : Player)
	local elapsed = self:GetTimeInArea(player)

	self:_updateLabel(player, elapsed)
	self:_payRewards(player, elapsed)
end

function AfkAreaService:_attachBillboard(player : Player, character : Model)
	local head = character:WaitForChild("Head", 10)

	-- Gone (or replaced by a respawn) while waiting for the head.
	if not head or player.Character ~= character then return end

	local previous = head:FindFirstChild(TIME_SPENT_GUI)
	if previous then
		previous:Destroy()
	end

	local billboard = self.Template:Clone()
	billboard.Name = TIME_SPENT_GUI
	billboard.Parent = head

	self.Labels[player] = billboard:FindFirstChildWhichIsA("TextLabel")

	-- Do not wait for the next tick to show the right time on a fresh character.
	self:_updateLabel(player, self:GetTimeInArea(player))
end

function AfkAreaService:_observePlayer(player : Player)
	player.CharacterAdded:Connect(function(character : Model)
		self:_attachBillboard(player, character)
	end)

	if player.Character then
		task.spawn(self._attachBillboard, self, player, player.Character)
	end
end

--[=[
	Sends the player back to the Lobby of this environment. The RETURN button on the
	client asks for it with `AfkReturnToLobby`.

	The destination is resolved by `Environment`, so a QA player goes to the QA Lobby.
	The teleport is wrapped in `pcall` because it is a web call that can fail; when it
	does, the cooldown ends and the player can try again.
]=]
function AfkAreaService:_returnToLobby(player : Player)
	if self.Leaving[player] then return end
	self.Leaving[player] = true

	local ok, err = pcall(function()
		return TeleportService:TeleportAsync(Environment.GetPlaceId("Lobby"), { player })
	end)

	if not ok then
		log:Warn(`could not send {player.Name} to the Lobby: {err}`)
	end

	task.delay(RETURN_COOLDOWN, function()
		self.Leaving[player] = nil
	end)
end

--[[ API ]]

--- Seconds the player has been in the area, `0` until their profile opens.
function AfkAreaService:GetTimeInArea(player : Player) : number
	local entered = self.Entered[player]
	if not entered then
		return 0
	end

	return os.clock() - entered
end

--[[ LIFECYCLE ]]

function AfkAreaService:construct()
	local dataService = self.Services.DataService

	Framework:Listen("AfkReturnToLobby", function(player : Player)
		-- `TeleportAsync` yields: keep it off the networking thread.
		task.spawn(self._returnToLobby, self, player)
	end)
	self.Template = ReplicatedStorage:WaitForChild(TIME_SPENT_GUI)

	--[[
		The rewards that can actually be paid. They are the same tables as in the
		config, not copies, so a change to one of them is seen on the next tick. A
		bad entry is reported once, here, instead of on every tick for every player.
	]]
	self.Active = {}
	for _, reward in AfkRewards.Rewards do
		if typeof(reward.Id) ~= "string" or typeof(reward.Amount) ~= "number" or reward.Amount <= 0 then
			log:Warn("skipping an AfkRewards entry with no Id or no positive Amount.")
		elseif typeof(reward.Interval) ~= "number" or reward.Interval <= 0 then
			log:Warn(string.format("skipping AfkRewards '%s': Interval must be a positive number of seconds.", reward.Id))
		elseif not self.Services.CurrencyService.Stats[reward.Currency] then
			log:Warn(string.format("skipping AfkRewards '%s': '%s' is not a currency CurrencyService can change.", reward.Id, tostring(reward.Currency)))
		else
			table.insert(self.Active, reward)
		end
	end

	Players.PlayerAdded:Connect(function(player : Player)
		self:_observePlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_observePlayer(player)
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_track(player)
	end)

	-- Players who loaded before this service started: their signal already fired.
	for _, player in Players:GetPlayers() do
		if self:_hasProfile(player) then
			self:_track(player)
		end
	end

	-- Stop paying before the profile closes: a payout after `EndSession` would be lost.
	dataService:OnBeforeRelease(function(player : Player)
		self:_forget(player)
	end)

	-- Cleanup for players who left without an open profile (the hook above does not even run).
	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self:_forget(player)
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(TICK_SECONDS)

			for player in self.Entered do
				-- One pcall per player: an error must not stop the loop for everyone.
				local ok, err = pcall(self._step, self, player)
				if not ok then
					log:Warn(string.format("tick failed for %s: %s", player.Name, tostring(err)))
				end
			end
		end
	end)
end

function AfkAreaService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function AfkAreaService:init()
end

return AfkAreaService
