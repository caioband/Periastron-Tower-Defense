local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.AfkConfig

--[[
	Decides whether the local player is AFK and tells the server when that changes.

	The player is AFK when the window lost focus (`Config.FocusLossIsAfk`) or when
	there has been no input for `Config.IdleSeconds`. Any input brings them back at
	once.

	**Why the client decides.** Input and window focus only exist on the client; the
	server cannot see either. `Player.Idled` is not used: it is client-only too, only
	fires after about two minutes, and measures the same input this module already
	listens to.

	**Only changes go to the server**, as `AfkChanged(isAfk)`. There is no periodic
	"still here" ping: it would cost traffic and prove nothing, since an exploiter
	can send it just as well.

	**Mouse movement counts.** `InputBegan` does not fire for it, so `InputChanged`
	covers the mouse, the wheel, touch drags, and the sticks (past a deadzone). Chat
	typing reaches `InputBegan` with `gameProcessedEvent` set, and still counts.

	See docs/common/afk.md.
]]

local AfkController = {
	Controllers = {}
}

-- `os.clock()` of the last input that counts.
AfkController.LastInput = os.clock()

-- Assumed focused on load: the player just clicked Play or arrived by teleport.
AfkController.Focused = true

-- The state the server was last told.
AfkController.Afk = false

local POINTER_TYPES = {
	[Enum.UserInputType.MouseMovement] = true,
	[Enum.UserInputType.MouseWheel] = true,
	[Enum.UserInputType.Touch] = true,
}

local THUMBSTICKS = {
	[Enum.KeyCode.Thumbstick1] = true,
	[Enum.KeyCode.Thumbstick2] = true,
}

--[[ INTERNAL ]]

function AfkController:_isActiveChange(input : InputObject) : boolean
	if POINTER_TYPES[input.UserInputType] then
		return true
	end

	return THUMBSTICKS[input.KeyCode] == true and input.Position.Magnitude > Config.ThumbstickDeadzone
end

function AfkController:_touch()
	self.LastInput = os.clock()
end

--- Recomputes the state and reports it if it changed.
function AfkController:_evaluate()
	local afk = (Config.FocusLossIsAfk and not self.Focused)
		or os.clock() - self.LastInput >= Config.IdleSeconds

	if afk == self.Afk then return end
	self.Afk = afk

	Framework:Fire("AfkChanged", afk)
end

--[[ PUBLIC ]]

--- Whether the local player is AFK right now.
function AfkController:IsAfk() : boolean
	return self.Afk
end

--[[ LIFECYCLE ]]

function AfkController:construct()
	UserInputService.InputBegan:Connect(function()
		self:_touch()
		self:_evaluate()
	end)

	UserInputService.InputChanged:Connect(function(input : InputObject)
		if not self:_isActiveChange(input) then return end

		self:_touch()

		-- Mouse movement fires many times a frame; only an AFK player has a
		-- state to leave.
		if self.Afk then
			self:_evaluate()
		end
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		self.Focused = false
		self:_evaluate()
	end)

	UserInputService.WindowFocused:Connect(function()
		self.Focused = true
		self:_touch()
		self:_evaluate()
	end)

	task.spawn(function()
		while true do
			task.wait(Config.CheckInterval)
			self:_evaluate()
		end
	end)
end

function AfkController:start()
end

function AfkController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return AfkController
