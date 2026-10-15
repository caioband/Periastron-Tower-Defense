--[[
	The game's telemetry: SERVER ONLY.

	See docs/common/tutorial.md.
]]

return {
	Funnel = {
		--[=[
			The order IS the step number. New steps only ever go at the end.

			4-9 are the old script's step Ids, kept so existing dashboard history
			keeps its numbers. 14 onwards are the reworked script's step Ids.
		]=]
		Onboarding = {
			"PromptShown",     -- 1  the map pick started in the Lobby
			"Accepted",        -- 2  opened a tutorial portal group
			"MatchJoined",     -- 3  landed on the tutorial match server

			"ClickReady",      -- 4  (old script)
			"PlaceFirst",      -- 5  (old script)
			"BuyReport",       -- 6  (old script)
			"UseReport",       -- 7  (old script)
			"UseSpeed",        -- 8  (old script)
			"PlaceRest",       -- 9  (old script)

			"MatchWon",        -- 10 won the tutorial match
			"BackToLobby",     -- 11 returned with the `TutorialDone` ticket
			"CrateBought",     -- 12 bought the Crate of Beginnings
			"CrateOpened",     -- 13 opened it

			"PlaceNearSpawn",  -- 14 placed the first tower near the spawn
			"UseSpeed2x",      -- 15 sped the match up to 2x
			"BuyAnyCard",      -- 16 bought a round card
			"CardTip",         -- 17 saw the card tip
			"WeatherWarning",  -- 18 saw the weather warning
			"WeatherArrived",  -- 19 saw the weather arrive
			"FinishUp",        -- 20 the script's last lesson
			"UpgradeTowers",   -- 21 learned upgrading and selling
		},
	},

	Events = {
		Declined = "TutorialDeclined",
		Abandoned = "TutorialAbandoned",
	},
} 