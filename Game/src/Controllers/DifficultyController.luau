local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local Framework = Me.new()
local log = Log.new("DifficultyController")

local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local SELECTED_TRANSPARENCY = 0
local IDLE_TRANSPARENCY = 0.4

-- The lock frame inside the button, and its label. A button without `Locked` is a
-- button the art declared as always open; see `collectLock`.
local LOCK_NAME = "Locked"
local LOCK_LABEL_NAME = "Time"

-- The notification for a mode the map imposed (`DifficultyImposed`). `SetCore` can
-- fail while the CoreGui is still loading, hence the retries.
local IMPOSED_TITLE = "Gamemode chosen"
local IMPOSED_TEXT = "This map plays %s. Press Ready when you're set!"
local IMPOSED_DURATION = 8
local SETCORE_ATTEMPTS = 10
local SETCORE_RETRY = 0.5

local DifficultyController = {
	Buttons = {},

	-- What the match asks of the hotbar (difficulty decided or not). See
	-- `setHotbarVisible`.
	HotbarWanted = false,

	-- Who is holding the hotbar off screen: `{ [reason] = true }`. See `HoldHotbar`.
	HotbarHolds = {},

	-- { [difficulty] = { Button, Frame, Label, WasActive, WasAutoButtonColor } }
	Locks = {},
}

local function formatClock(seconds : number)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

function DifficultyController:updateClock(state)
	local clock = self.clock
	if not clock then return end

	clock.Visible = state.active == true
	clock.Time.Text = formatClock(state.timeLeft or 0)
end

--[=[
	The hotbar only appears once the difficulty is decided. Before that there is no
	match (the server is waiting for everyone to load, or the vote is open) and the
	cards would have nowhere to be placed.
]=]
function DifficultyController:setHotbarVisible(visible : boolean)
	self.HotbarWanted = visible == true

	self:applyHotbar()
end

--[=[
	Writes `TowerContainer`'s `Visible`: the match asks for it **and** nobody holds it.

	There is still a single owner of the switch (this controller); anyone who needs
	the hotbar off screen for a while asks with `HoldHotbar` instead of writing
	`Visible` from outside: `DifficultyLocked` or the vote's next state would light the
	hotbar back up mid-request.
]=]
function DifficultyController:applyHotbar()
	if self.hotbar then
		self.hotbar.Visible = self.HotbarWanted and next(self.HotbarHolds) == nil
	end
end

--[=[
	Holds (or releases) the hotbar off screen on behalf of `reason`. Releasing the last
	request returns the hotbar to what the match wants: if the difficulty has not been
	decided yet, it stays hidden.

	Today `TutorialStepController` asks for it, on the Ready step (`HideDeck`).
]=]
function DifficultyController:HoldHotbar(reason : string, held : boolean)
	self.HotbarHolds[reason] = if held then true else nil

	self:applyHotbar()
end

--[=[
	Checks that each button on the board has a preset on the other side.

	The instance name **is** the vote: the controller fires `SelectDifficulty` with it,
	and the server silently refuses anything not in `DifficultyConfig`. A button with
	the wrong name breaks nothing visibly: it just never counts a vote, and the player
	keeps clicking a dead button with no warning anywhere.

	A board that had `Extreme` labeled "IMPOSSIBLE" (vote refused, difficulty
	unreachable) and `Impossible` labeled "NIGHTMARE" (vote accepted as Impossible,
	with the player reading Nightmare and getting the lower one's reward) left no
	trace at all. This check is what catches that.

	The preset list only comes from the server (`state.options`), so the check cannot
	happen at bind: it lives here, the first time a state arrives, and runs once.
]=]
function DifficultyController:auditButtons(options : { string }?)
	if self.audited or not options then return end
	self.audited = true

	local known = {}
	for _, name in options do
		known[name] = true
	end

	for name in self.Buttons do
		if not known[name] then
			log:StudioWarn(string.format(
				"DifficultyBoard button '%s' is not a difficulty (%s). The server refuses its vote; rename the instance to the preset name.",
				name, table.concat(options, ", ")))
		end
	end

	for _, name in options do
		if not self.Buttons[name] then
			log:StudioWarn(string.format(
				"difficulty '%s' has no button on the DifficultyBoard; nobody can vote for it.",
				name))
		end
	end
end

--[=[
	Stores a button's lock, if it has one.

	The button's original state goes along (`WasActive`, `WasAutoButtonColor`) because
	unlocking must **restore** what the art authored, not guess `true`: a button born
	without `AutoButtonColor` must not gain the effect when it opens.
]=]
function DifficultyController:collectLock(button : ImageButton)
	local frame = button:FindFirstChild(LOCK_NAME)
	if not frame or not frame:IsA("GuiObject") then return end

	self.Locks[button.Name] = {
		Button = button,
		Frame = frame,
		Label = frame:FindFirstChild(LOCK_LABEL_NAME),
		WasActive = button.Active,
		WasAutoButtonColor = button.AutoButtonColor,
	}
end

--[=[
	This player's wins and XP, or nil until the replica arrives.

	Nil is the safe guess: without a profile, `isUnlocked` answers "locked" and the
	screen shows everything locked. Erring the other way would open Nightmare for an
	instant and shut it in the player's face when the profile arrived.
]=]
function DifficultyController:stats() : { [string] : any }?
	local replica = self.replica
	local stats = replica and replica.Data and replica.Data.Stats

	return typeof(stats) == "table" and stats or nil
end

--[=[
	Paints each button's lock from the current profile.

	Three things change together, which is why they live in the same function:
	`Locked` appears, the button stops responding, and the label says what is missing.
	Leaving the button alive under a drawn lock would be a difficulty that looks locked
	and votes on click.

	`Active = false` is already enough for `MouseButton1Click` not to fire; the click
	checks again anyway, because a button without `Locked` in the art never goes
	through here and would stay clickable.
]=]
function DifficultyController:renderLocks()
	local stats = self:stats()

	for name, lock in self.Locks do
		local unlocked = UnlockConfig.isUnlocked(name, stats)

		lock.Frame.Visible = not unlocked

		if lock.Label and not unlocked then
			lock.Label.Text = UnlockConfig.lockText(name, stats)
		end

		lock.Button.Active = unlocked and lock.WasActive
		lock.Button.AutoButtonColor = unlocked and lock.WasAutoButtonColor
	end
end

--[=[
	Holds the player's replica and repaints the locks on every write to `Stats`.

	The same shape as the HUD counter and the map locks: `DataService` writes the whole
	`Stats` key, but the listener is `OnChange` so a deeper write
	(`Stats.DifficultyWins`) also counts. That way the win that opens Hard shows on the
	next round's board without the player switching servers.
]=]
function DifficultyController:watchProfile()
	task.spawn(function()
		--[[
			`DataController` is requested here, not through the `Controllers` table the
			other controllers declare at the top: that table is filled in `start`, and
			this controller builds in `init`. With the GUI already on screen, `construct`
			does not yield on any `WaitForChild` and finishes before any `start` runs, so
			the reference would still be the empty placeholder. The yielding `Get` waits
			for the loader.
		]]
		local dataController = Framework:Get("DataController", false, true)

		local replica = dataController:GetReplica()
		if not replica then return end

		self.replica = replica
		self:renderLocks()

		replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
				return
			end

			self:renderLocks()
		end)
	end)
end

function DifficultyController:updateUI(state)
	self:updateClock(state)
	self:setHotbarVisible(state.locked ~= nil)

	self:auditButtons(state.options)

	local board = self.board
	if not board then return end

	board.Visible = state.active == true

	local countdown = board:FindFirstChild("Countdown")
	if countdown then
		countdown.Text = tostring(state.timeLeft or 0) .. "s"
	end

	local votes = state.votes or {}

	for name, button in self.Buttons do
		local isSelected = state.selected == name

		if not state.selected or isSelected then
			button.ImageTransparency = SELECTED_TRANSPARENCY
		else
			button.ImageTransparency = IDLE_TRANSPARENCY
		end

		local voteLabel = button:FindFirstChild("VoteCount")
		if voteLabel then
			voteLabel.Text = tostring(votes[name] or 0)
		end
	end
end

--[=[
	Tells the player the map chose the mode for them, so the missing vote does not
	look like a bug.
]=]
function DifficultyController:announceImposed(displayName : string)
	local notification = {
		Title = IMPOSED_TITLE,
		Text = string.format(IMPOSED_TEXT, displayName),
		Duration = IMPOSED_DURATION,
	}

	for _ = 1, SETCORE_ATTEMPTS do
		if pcall(StarterGui.SetCore, StarterGui, "SendNotification", notification) then
			return
		end

		task.wait(SETCORE_RETRY)
	end

	log:StudioWarn(`could not send the "{displayName}" gamemode notification.`)
end

function DifficultyController:construct()
	local Interface = PlayerGui:WaitForChild("Interface", 60)
	local clock = Interface and Interface:WaitForChild("Clock", 60)
	if clock and clock:FindFirstChild("Time") then
		self.clock = clock
		clock.Visible = false
	end

	local hotbar = Interface and Interface:WaitForChild("TowerContainer", 60)
	if hotbar then
		self.hotbar = hotbar

		-- Hidden from the start: the client usually finishes loading before the server
		-- opens the vote, and until the first state arrives there is no match.
		hotbar.Visible = false
	end

	local screen = PlayerGui:WaitForChild("Difficulty", 60)
	if not screen then return end

	self.board = screen:WaitForChild("DifficultyBoard", 60)
	if not self.board then return end

	self.board.Visible = false

	for _, child in self.board:GetChildren() do
		if child:IsA("ImageButton") then
			self.Buttons[child.Name] = child
			self:collectLock(child)

			child.MouseButton1Click:Connect(function()
				if not UnlockConfig.isUnlocked(child.Name, self:stats()) then return end

				Framework:Fire("SelectDifficulty", child.Name)
			end)
		end
	end

	-- Before the replica arrives everything shows locked, and it stays that way if it
	-- never arrives: the server would refuse the vote anyway.
	self:renderLocks()
	self:watchProfile()

	Framework:Listen("DifficultySelection", function(state)
		self:updateUI(state)
	end)

	Framework:Listen("DifficultyLocked", function(difficultyName)
		self.Locked = difficultyName
		self.board.Visible = false

		self:setHotbarVisible(true)

		if self.clock then
			self.clock.Visible = false
		end
	end)

	Framework:Listen("DifficultyImposed", function(displayName)
		task.spawn(self.announceImposed, self, displayName)
	end)
end

function DifficultyController:start()
end

function DifficultyController:init()
	self:construct()
end

return DifficultyController
