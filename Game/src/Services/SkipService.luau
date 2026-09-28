local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local SkipConfig = SharedConfig.SkipConfig

--[=[
	The skip-wave vote.

	The prompt has no button to open it: it appears `SkipConfig.OfferDelay` seconds
	after the wave starts. `WaveService` marks the start (`WaveStartedAt`); this only
	reads the clock.

	Once the vote closes, `WaveService:SkipWave()` skips the wave: the next one starts
	with the previous one's enemies still on the path.

	**The vote belongs to the wave.** Unit damage closes nothing: once open, it only
	leaves the screen when the wave can no longer be skipped (it ended on its own, was
	skipped, or the round stopped), and votes count until then.

	Each opening has a `Token`. It lets the client hide the prompt when the player
	clicks Cancel without hiding the next one: a new token is a new vote, which
	appears again for everyone.

	See docs/game/skip-wave.md.
]=]
local SkipService = {
	Services = {
		WaveService = {},
	},

	-- Votes of the open vote, by UserId. Reset on every opening and every
	-- closing; see the comment above.
	Votes = {},
	Active = false,
	Token = 0,
}

--[[ INTERNAL ]]

function SkipService:_tally() : (number, number, number)
	local voted = 0
	local total = 0

	for _, player in Players:GetPlayers() do
		total += 1
		if self.Votes[player.UserId] then
			voted += 1
		end
	end

	return voted, total, SkipConfig.RequiredVotes(total)
end

--[=[
	The vote state for one player. `required` goes along because the on-screen
	counter shows it: "1/3" is one vote cast out of three needed, not one of three
	players.
]=]
function SkipService:_sendTo(player : Player)
	local voted, total, required = self:_tally()

	Framework:Fire("SkipState", player, {
		active = self.Active,
		votes = voted,
		total = total,
		required = required,
		voted = self.Votes[player.UserId] == true,
		token = self.Token,
	})
end

function SkipService:_broadcast()
	for _, player in Players:GetPlayers() do
		self:_sendTo(player)
	end
end

function SkipService:_open()
	if self.Active then return end

	self.Active = true
	self.Token += 1
	table.clear(self.Votes)

	self:_broadcast()
end

function SkipService:_close()
	if not self.Active then return end

	self.Active = false
	table.clear(self.Votes)

	self:_broadcast()
end

--[=[
	Whether the vote should be on screen now: a skippable wave running, started at
	least `OfferDelay` seconds ago.
]=]
function SkipService:_shouldOffer() : boolean
	local waveService = self.Services.WaveService

	if not waveService then return false end
	if not waveService:CanSkipWave() then return false end

	local startedAt = waveService.WaveStartedAt
	return startedAt ~= nil and (os.clock() - startedAt) >= SkipConfig.OfferDelay
end

--[=[
	Counts the votes and skips the wave if possible. It closes the vote either way:
	closed successfully, it did what it had to do; refused by `SkipWave` (the wave
	ended on its own between the vote and the count), it lost its object.
]=]
function SkipService:_evaluate()
	if not self.Active then return end

	local waveService = self.Services.WaveService
	if not waveService then return end

	local voted, total, required = self:_tally()
	if total == 0 or voted < required then return end

	self:_close()
	waveService:SkipWave()
end

--[=[
	The loop that watches the match. It runs for the whole round, not only when there
	is a wave: the condition for opening is the same as for staying open, so the
	prompt comes and goes on its own as the match stalls and unstalls.
]=]
function SkipService:_watch()
	task.spawn(function()
		while true do
			task.wait(SkipConfig.PollInterval)

			local shouldOffer = self:_shouldOffer()

			if self.Active and not shouldOffer then
				self:_close()
			elseif not self.Active and shouldOffer then
				self:_open()
			end
		end
	end)
end

--[[ LIFECYCLE ]]

function SkipService:construct()
	--[[
		`wants` is explicit instead of toggling the vote: the prompt has two buttons,
		and Cancel must be able to remove the vote of someone who clicked Confirm
		without relying on the client knowing what state it was in.
	]]
	Framework:Listen("VoteSkip", function(player : Player, wants : boolean?)
		if not self.Active then return end

		local vote = if wants == false then nil else true
		if self.Votes[player.UserId] == vote then return end

		self.Votes[player.UserId] = vote

		self:_broadcast()
		self:_evaluate()
	end)

	--[[
		The client asks for the state when it finishes loading the Interface. Without
		this, a player joining in the middle of an open vote would only see it on the
		next vote: the `PlayerAdded` `SkipState` goes out before their controller is
		listening.
	]]
	Framework:Listen("RequestSkipState", function(player : Player)
		self:_sendTo(player)
	end)

	--[[
		A player joining changes how many votes are missing for everyone, and so does a
		player leaving, which may even close the vote if they were the missing vote.
	]]
	Players.PlayerAdded:Connect(function()
		self:_broadcast()
		self:_evaluate()
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.Votes[player.UserId] = nil

		task.defer(function()
			self:_broadcast()
			self:_evaluate()
		end)
	end)

	self:_watch()
end

function SkipService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function SkipService:init()
	-- Only what goes from here to the client: `VoteSkip` and `RequestSkipState` get
	-- their remote in `construct`, when we actually listen to them.
	Framework:Listen("SkipState", function() end)
end

return SkipService
