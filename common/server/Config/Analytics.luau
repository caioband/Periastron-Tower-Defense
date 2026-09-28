--[[
	The game's telemetry: SERVER ONLY.

	Roblox's analytics API only answers **server** calls in a **published** place:
	nothing here needs to reach the client, which is why this file lives in
	`ServerScriptService.Config` next to the DataStore key and the admin list, and
	not in `SharedConfig`.

	`AnalyticsService` (`common/server/Services`) reads it, and it is the only place
	in the game that touches `game:GetService("AnalyticsService")`.

	See docs/common/tutorial.md.
]]

return {
	--[[
		The **onboarding funnel**: the new player's path, from the tutorial offer in the
		Lobby to the crate opened on the way back.

		`LogOnboardingFunnelStepEvent` is the right type for a conversion that happens
		**once per player**, the same thing the profile's `Tutorial` key says. It does
		not ask for a `funnelSessionId`, and that is what lets the funnel cross
		Lobby → Game → Lobby without an id traveling in `TeleportData`. Roblox counts
		only the first time of each step per user, so redoing the tutorial through
		`tutorialreset` does not inflate the dashboard.
	]]
	Funnel = {
		--[=[
			**The order IS the step number**: the index in the list becomes the `step`
			Roblox receives. New steps go at the end, or the dashboard starts comparing
			numbers that mean something other than they did yesterday.

			From the fourth to the ninth, the name is **the same `Id`** as the step in
			`TutorialConfig.Match.Steps`, so `CompleteStep` sends `step.Id` directly,
			with no translation table in between that could fall behind when the
			script changes.
		]=]
		Onboarding = {
			"PromptShown",   -- 1  the offer appeared in the Lobby
			"Accepted",      -- 2  clicked SURE!
			"MatchJoined",   -- 3  landed on the tutorial match server

			"ClickReady",    -- 4  \
			"PlaceFirst",    -- 5   |
			"BuyReport",     -- 6   |  the script's steps, by `Id`
			"UseReport",     -- 7   |
			"UseSpeed",      -- 8   |
			"PlaceRest",     -- 9  /

			"MatchWon",      -- 10 won the 5 waves
			"BackToLobby",   -- 11 returned to the Lobby with the `TutorialDone` ticket
			"CrateBought",   -- 12 bought the Crate of Beginnings
			"CrateOpened",   -- 13 opened the crate: the end of the tutorial
		},
	},

	--[[
		The standalone events, which cover what the funnel **cannot** say.

		`Declined` separates "answered no" from "ignored the dialog box": both stop at
		step 1 of the funnel, and they are different decisions.

		`Abandoned` is a match left midway, which leaves the profile key at `false`
		and would otherwise leave no record at all. The event's value is the wave the
		player was on.
	]]
	Events = {
		Declined = "TutorialDeclined",
		Abandoned = "TutorialAbandoned",
	},
}
