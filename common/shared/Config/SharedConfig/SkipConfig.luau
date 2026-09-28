--[[
	The skip-wave vote: `StarterGui.Interface.SkipPrompt`.

	The prompt appears by itself `OfferDelay` seconds after the wave starts and
	stays until it ends. Unit damage does not hide it: the vote belongs to the
	wave. `SkipService` decides; `SkipPromptController` draws.

	`OfferDelay` is measured in **real time**, not `GameClock`: it measures the
	patience of whoever is watching, not the match pace.

	The animation is the same as `WeatherWarning` (see `WarningConfig`): the prompt
	slides down from `SlideOffset` above its authored place while **every**
	descendant fades from 1 to the transparency the designer left. Fading to the
	authored value, not to zero, keeps a transparent background or a 20% shadow.

	Only the Game uses it (the Lobby has no waves), but the config lives here
	because the client needs the timings and texts. See docs/game/skip-wave.md.
]]

local SkipConfig = {}

-- The ImageLabel inside `PlayerGui.Interface`.
SkipConfig.Name = "SkipPrompt"

-- Names inside the prompt.
SkipConfig.ConfirmName = "Confirm"
SkipConfig.CancelName = "Cancel"
SkipConfig.CountName = "PlayerCount"

--[[
	Seconds between the wave starting (when its enemies begin to spawn) and the
	prompt appearing. If the wave is still spawning then, it waits for the last
	enemy; see `WaveService:CanSkipWave`.
]]
SkipConfig.OfferDelay = 5

-- How often the server checks whether to open or close. It need not be fine:
-- what it measures is a five-second window.
SkipConfig.PollInterval = 0.25

--[[
	Animation, the same as the center-screen warning. `SlideOffset` is in screen
	Y scale, counted upward from the authored position.
]]
SkipConfig.SlideOffset = 0.06
SkipConfig.FadeIn = 0.35
SkipConfig.FadeOut = 0.25

-- The prompt's counter: votes cast over votes required.
SkipConfig.CountText = "%d/%d"

--[=[
	How many votes close the vote, given who is on the server.

	Strict majority: a lone player decides alone, two must agree, four need three.
	One vote fewer would let half the room skip the other half's wave.
]=]
function SkipConfig.RequiredVotes(total : number) : number
	if total <= 0 then
		return 0
	end

	return math.floor(total / 2) + 1
end

return SkipConfig
