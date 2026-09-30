local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local AfkShared = ReplicatedStorage:WaitForChild("Afk")

local AfkRewards = require(AfkShared:WaitForChild("AfkRewards"))

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	The AFK area's HUD:

	  - **The countdown.** `ScreenGui.RewardFrame.TimerLabel` shows how long is left
	    until the next payout. `AfkAreaService` puts the moment the player's timer
	    started in a player attribute (`AfkRewards.EnteredAttribute`, in server time),
	    so the client works out `elapsed` from that and, for each reward in
	    `AfkRewards.Rewards`, `Interval - elapsed % Interval`. The smallest one wins,
	    so a second reward with a shorter interval shows up on its own. Nothing is
	    sent every second: the server never has to tell the client the time.

	  - **The RETURN button.** `ScreenGui.ReturnFrame.ReturnButton` asks the server to
	    send the player back to the Lobby (`AfkReturnToLobby`). The server does the
	    teleport and has its own cooldown; the debounce here only keeps the button from
	    being spammed and shows that the click was taken.

	`ScreenGui` has `ResetOnSpawn`, so on every respawn Roblox throws the elements
	away and puts fresh copies from `StarterGui` in their place. That is why they are
	*observed* (bound again each time one appears) instead of found once. They are
	matched by name **and** parent name, so a GUI in another place that happens to
	use the same names is left alone.
]]

local TIMER_NAME = "TimerLabel"
local TIMER_PARENT = "RewardFrame"

local BUTTON_NAME = "ReturnButton"
local BUTTON_PARENT = "ReturnFrame"
local BUTTON_TEXT = "ButtonText"

-- Shown until the player's timer has started (the profile is still loading).
local PLACEHOLDER = "--:--"

-- Seconds between countdown redraws. The text only changes once a second.
local REFRESH_SECONDS = 0.2

-- Seconds the button ignores clicks after one, and shows "..." instead of its text.
local RETURN_DEBOUNCE = 3

local AfkAreaController = {
	-- The live label, `nil` while the GUI is being rebuilt.
	Timer = nil,

	-- `os.clock()` of the last accepted click on RETURN.
	LastReturn = -math.huge,
}

--[[ INTERNAL ]]

--- `MM:SS`, or `H:MM:SS` from one hour up.
local function formatCountdown(seconds : number) : string
	-- Rounded up: the display reads 00:01 until the payout, never 00:00 before it.
	local total = math.max(0, math.ceil(seconds))

	local hours = total // 3600
	local minutes = total % 3600 // 60
	local secs = total % 60

	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end

	return string.format("%02d:%02d", minutes, secs)
end

--- Seconds until the soonest payout, or `nil` while the timer has not started.
function AfkAreaController:_secondsUntilReward() : number?
	local enteredAt = Players.LocalPlayer:GetAttribute(AfkRewards.EnteredAttribute)
	if typeof(enteredAt) ~= "number" then
		return nil
	end

	local elapsed = math.max(0, workspace:GetServerTimeNow() - enteredAt)

	local soonest : number? = nil
	for _, reward in AfkRewards.Rewards do
		local interval = reward.Interval
		if typeof(interval) ~= "number" or interval <= 0 then continue end

		local remaining = interval - elapsed % interval
		if soonest == nil or remaining < soonest then
			soonest = remaining
		end
	end

	return soonest
end

function AfkAreaController:_render()
	local timer = self.Timer
	if not timer then return end

	local remaining = self:_secondsUntilReward()
	local text = if remaining then formatCountdown(remaining) else PLACEHOLDER

	if timer.Text ~= text then
		timer.Text = text
	end
end

function AfkAreaController:_bindTimer(label : TextLabel)
	self.Timer = label
	self:_render()

	label.Destroying:Once(function()
		if self.Timer == label then
			self.Timer = nil
		end
	end)
end

function AfkAreaController:_requestReturn(button : ImageButton)
	local now = os.clock()
	if now - self.LastReturn < RETURN_DEBOUNCE then return end
	self.LastReturn = now

	Framework:Fire("AfkReturnToLobby")

	-- Feedback that the click was taken; the server may need a moment to teleport.
	local label = button:FindFirstChild(BUTTON_TEXT)
	if label and label:IsA("TextLabel") then
		local original = label.Text
		label.Text = "..."

		task.delay(RETURN_DEBOUNCE, function()
			if label.Parent then
				label.Text = original
			end
		end)
	end
end

function AfkAreaController:_bindButton(button : ImageButton)
	-- The connection dies with the button when the GUI is rebuilt.
	button.Activated:Connect(function()
		self:_requestReturn(button)
	end)
end

function AfkAreaController:_observeGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function consider(instance : Instance)
		local parent = instance.Parent
		if not parent then return end

		if instance.Name == TIMER_NAME and instance:IsA("TextLabel") and parent.Name == TIMER_PARENT then
			self:_bindTimer(instance)
		elseif instance.Name == BUTTON_NAME and instance:IsA("ImageButton") and parent.Name == BUTTON_PARENT then
			self:_bindButton(instance)
		end
	end

	playerGui.DescendantAdded:Connect(consider)

	for _, descendant in playerGui:GetDescendants() do
		consider(descendant)
	end
end

--[[ LIFECYCLE ]]

function AfkAreaController:construct()
	self:_observeGui()

	task.spawn(function()
		while true do
			task.wait(REFRESH_SECONDS)
			self:_render()
		end
	end)
end

function AfkAreaController:start()
	self:construct()
end

function AfkAreaController:init()
end

return AfkAreaController
