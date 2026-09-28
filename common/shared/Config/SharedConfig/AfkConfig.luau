--[[
	AFK detection. `AfkController` decides on the client, `AfkService` keeps the
	state on the server and tells the other services.

	The client needs the thresholds, so the config lives here. Nothing in it is
	secret: knowing that five minutes marks you AFK does not help anyone cheat.

	See docs/common/afk.md.
]]

local AfkConfig = {}

-- Seconds without any input before the player is AFK.
AfkConfig.IdleSeconds = 5 * 60

-- Losing window focus (Alt-Tab, minimizing, the app going to the background on
-- mobile) marks the player AFK right away, without waiting for `IdleSeconds`.
AfkConfig.FocusLossIsAfk = true

-- How often the client rechecks the idle timer, in seconds. Only a state change
-- goes to the server, so this costs nothing on the network.
AfkConfig.CheckInterval = 1

-- A gamepad stick counts as input only past this magnitude: a worn stick drifts
-- and would keep an idle player "active" forever.
AfkConfig.ThumbstickDeadzone = 0.2

-- The attribute `AfkService` sets on the `Player` while they are AFK (removed when
-- they come back), for anything that only needs to read the state.
AfkConfig.Attribute = "Afk"

-- Where `PlaytimeService` stops counting `Stats.TimePlayed` while the player is AFK.
AfkConfig.PausePlaytime = {
	Lobby = true,
	Game = false,
}

return AfkConfig
