local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local WarningConfig = SharedConfig.WarningConfig
local Config = WarningConfig.Restart

--[[
	"WARNING! SERVER RESTART FOR GAME UPDATE IN 2 MINUTES".

	The server sends `ServerRestartScheduled` with the `Enum.CloseReason` name and
	how many seconds are left; the sentence is built here, and `WarningController`
	animates it in `Interface.WeatherWarning`.

	**The deadline is anchored to the local clock.** What arrives is "N seconds
	left", not a time of day: from then on the controller counts with `os.clock()`,
	which is monotonic and does not depend on the player's machine having the right
	time.

	**The warning comes back.** A restart is usually scheduled minutes ahead, and an
	eight-second sentence in the middle of a wave gets lost. The `Config.Reminders`
	marks (5min, 2min, 1min, 30s, 10s) bring the warning back with the new number,
	and the last one is the one the player actually reads.

	It lives in `common/` because the restart takes down both places.

	See docs/common/screen-warnings.md.
]]

local ServerRestartController = {
	Controllers = {
		WarningController = {}
	}
}

-- The restart instant on the local clock (`os.clock`), or nil if the server could
-- not say when.
ServerRestartController.Deadline = nil :: number?
ServerRestartController.Source = nil :: string?

-- One schedule per session: the marks' `task.delay` calls only apply while nobody
-- has rescheduled on top.
ServerRestartController.Session = 0

--[[ INTERNAL ]]

--[=[
	The sentence, with the time left now, not what was left when the warning was
	scheduled.
]=]
function ServerRestartController:_text() : string
	local source = WarningConfig.GetRestartSource(self.Source)

	local deadline = self.Deadline
	if not deadline then
		return string.format(Config.TextNow, source)
	end

	local remaining = deadline - os.clock()
	if remaining <= Config.NowThreshold then
		return string.format(Config.TextNow, source)
	end

	return string.format(Config.Text, source, WarningConfig.FormatDuration(remaining))
end

--[=[
	Puts the warning on screen, if the session is still the current one.
]=]
function ServerRestartController:_announce(session : number)
	if self.Session ~= session then return end

	local warning = self.Controllers.WarningController
	if not warning then return end

	warning:Show(self:_text(), {
		Priority = WarningConfig.Priority.Restart,
		Hold = Config.Hold,
	})
end

--[[ API ]]

--[=[
	Registers the restart and warns the player: now, and at every `Reminders` mark
	that still fits.

	`remaining` is in seconds, counted from now. A mark that would land on top of the
	previous warning is dropped: two warnings in a row with the same number on screen
	would only cut each other's animation.
]=]
function ServerRestartController:Schedule(source : string?, remaining : number?)
	self.Session += 1
	local session = self.Session

	self.Source = source
	self.Deadline = if remaining then os.clock() + math.max(remaining, 0) else nil

	self:_announce(session)

	if not remaining then return end

	for _, mark in Config.Reminders do
		local delay = remaining - mark
		if delay <= Config.Hold then continue end

		task.delay(delay, function()
			self:_announce(session)
		end)
	end
end

--[[ LIFECYCLE ]]

function ServerRestartController:construct()
	Framework:Listen("ServerRestartScheduled", function(source : string?, remaining : number?)
		self:Schedule(
			if typeof(source) == "string" then source else nil,
			tonumber(remaining)
		)
	end)

	-- A player who joins after the restart is already scheduled needs to know.
	Framework:Fire("RequestServerRestart")
end

function ServerRestartController:start()
end

function ServerRestartController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return ServerRestartController
