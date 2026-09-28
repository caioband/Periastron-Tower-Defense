--[[
	The big center-screen warning: `StarterGui.Interface.WeatherWarning`, a
	TextLabel with a UIStroke inside.

	The label is named after weather because it was born for it, but there is
	**one** label for anyone who needs a short, urgent sentence on screen. Today it
	has two owners: the upcoming weather (`WeatherWarningController`) and the server
	restart (`ServerRestartController`). `WarningController` is the only code that
	touches the label.

	`Label` is the animation: the text slides down from `SlideOffset` above its
	target while the transparency (of the text **and** the stroke) goes from 1 to
	0, holds for `Hold` seconds, and leaves the same way. The target is the
	position the designer left in StarterGui.

	`Priority` settles the two owners: a warning only replaces the current one if
	its priority is greater or equal, so weather never erases "the server will
	restart in 1 minute".

	It lives in `common/` because restarts happen in both places. See
	docs/common/screen-warnings.md.
]]

local WarningConfig = {}

WarningConfig.Label = {
	Name = "WeatherWarning",

	SlideOffset = 0.06,
	FadeIn = 0.5,
	Hold = 5,
	FadeOut = 0.4,
}

WarningConfig.Priority = {
	Weather = 1,
	Restart = 2,
}

--[[
	Server restart warning.

	`Text` says who asked for the restart and how long is left ("WARNING! SERVER
	RESTART FOR GAME UPDATE IN 2 MINUTES"). Under `NowThreshold`, or with no time
	at all, `TextNow` applies, which promises no deadline it does not have.

	`Sources` translates the `Enum.CloseReason` the server received, separating a
	developer restart (a game update) from a Roblox one (maintenance, moderation,
	memory): only one of them means "come back, there is something new".

	`Reminders` are the marks, in seconds left, at which the warning returns. A
	restart is scheduled minutes ahead; showing it once would miss players who
	joined later or were looking at the map. A mark that would overlap the previous
	warning is skipped by the controller.
]]
WarningConfig.Restart = {
	Text = "WARNING! SERVER RESTART FOR %s IN %s",
	TextNow = "WARNING! SERVER RESTARTING FOR %s",

	Hold = 8,
	Reminders = { 300, 120, 60, 30, 10 },
	NowThreshold = 5,

	Sources = {
		-- The developer: `DeveloperUpdate` is `UpdatePlace`, `DeveloperShutdown` is the
		-- dashboard's shutdown button.
		DeveloperUpdate = "GAME UPDATE",
		DeveloperShutdown = "GAME UPDATE",

		-- Roblox.
		RobloxMaintenance = "ROBLOX MAINTENANCE",
		Moderation = "MODERATION",
		OutOfMemory = "SERVER MEMORY",
		ServerEmpty = "INACTIVITY",
		Unknown = "MAINTENANCE",
	},
	DefaultSource = "MAINTENANCE",

	--[[
		How the remaining time is written. The largest unit that fits wins: 90
		seconds becomes "2 MINUTES", not "1 MINUTE 30 SECONDS"; it is a one-line
		warning, not a stopwatch.
	]]
	Durations = {
		{ Seconds = 3600, One = "%d HOUR", Many = "%d HOURS" },
		{ Seconds = 60, One = "%d MINUTE", Many = "%d MINUTES" },
		{ Seconds = 1, One = "%d SECOND", Many = "%d SECONDS" },
	},
}

--[=[
	What to write for an `Enum.CloseReason`.

	Takes the enum **name** (how it crosses the network) and returns
	`DefaultSource` for anything not in the table: a new Roblox reason becomes a
	generic warning instead of no warning.
]=]
function WarningConfig.GetRestartSource(sourceName : string?) : string
	local restart = WarningConfig.Restart

	return (sourceName and restart.Sources[sourceName]) or restart.DefaultSource
end

--[=[
	"2 MINUTES", "45 SECONDS", "1 HOUR".

	Rounds to the nearest unit instead of truncating: at 119 seconds, "2 MINUTES"
	is off by one second and "1 MINUTE" by fifty-nine. Never goes below 1; "0
	MINUTES" would be wrong both ways.
]=]
function WarningConfig.FormatDuration(seconds : number) : string
	local remaining = math.max(seconds, 0)

	for _, duration in WarningConfig.Restart.Durations do
		if remaining < duration.Seconds then continue end

		local amount = math.max(math.floor(remaining / duration.Seconds + 0.5), 1)

		return string.format(if amount == 1 then duration.One else duration.Many, amount)
	end

	-- Under a second: `TextNow` should have spoken, but a caller that gets here
	-- anyway still receives something readable.
	local last = WarningConfig.Restart.Durations[#WarningConfig.Restart.Durations]

	return string.format(last.One, 1)
end

return WarningConfig
