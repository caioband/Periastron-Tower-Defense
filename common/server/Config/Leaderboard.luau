--[[
	The global leaderboards (`Workspace.Leaderboards` of each place).

	Each `Boards` entry links a map model to a profile number. `LeaderboardService`
	(common) reads it: in every place it **writes** each player's number to an
	OrderedDataStore; in the place named by `Place`, it also **reads** the top and
	draws it.

	  - `Model`:  the model name inside `Workspace.Leaderboards`.
	  - `Place`:  the place that draws it (the `Place` attribute on
	              `ServerScriptService.Services`). Missing means `"Lobby"`.
	  - `Store`:  the OrderedDataStore suffix. Changing it resets the board.
	  - `Path`:   where the number lives in the profile (`Data`), key by key.
	  - `Format`: how the number shows on the row:
	      "Level":  the level the XP gives (`LevelConfig:Resolve`)
	      "Number": abbreviated (`1.25M`, `3.4B`)
	      "Time":   seconds as `DD:HH:MM`

	**Why HIGHEST LEVEL stores XP, not the level.** The order is the same, and XP
	breaks ties: two players at level 50 stay ordered by who played more.

	**Game size does not matter.** The OrderedDataStore already keeps keys in order,
	so asking for the top is one page of `TOP` entries: the same cost with a hundred
	players or a hundred million. Nothing here walks the whole store.

	**Titles.** A nametag with `Leaderboard = "<Store>"` (`NametagConfig`) goes to
	whoever holds #1 on that store; tied players all hold it. Every place reads the
	champions every `TITLE_INTERVAL`, a page of `TITLE_PAGE` (how many tied #1s fit).
	Boards this place already draws reuse that read.

	See docs/common/leaderboards.md.
]]

return {
	FOLDER_NAME = "Leaderboards",

	-- How many rows each board shows. A single `GetSortedAsync` page, which
	-- accepts up to 100.
	TOP = 50,

	--[[
		How often each server sends its players' numbers (only those that changed) and
		how often the Lobby redraws the top.

		The write limit is 60 + 10 per player per minute, per server. With 9 boards and
		120s, the worst case (all changed) is 4.5 per player per minute, and the usual
		case is 2, for both intervals.
	]]
	WRITE_INTERVAL = 120,
	READ_INTERVAL = 120,

	TITLE_INTERVAL = 120,
	TITLE_PAGE = 25,

	Boards = {
		{ Model = "HighestLevelLB", Store = "XP", Path = { "Stats", "XP" }, Format = "Level" },
		-- The total earned, not the balance: spending in the shop does not knock anyone off the board.
		{ Model = "MostCoinsLB", Store = "CoinsEarned", Path = { "Stats", "CoinsEarned" }, Format = "Number" },
		{ Model = "MostMatchesWonLB", Store = "Wins", Path = { "Stats", "Wins" }, Format = "Number" },
		{ Model = "NightmareWinsLB", Store = "NightmareWins", Path = { "Stats", "DifficultyWins", "Nightmare" }, Format = "Number" },
		{ Model = "MostBoxesOpened", Store = "BoxesOpened", Path = { "Stats", "BoxesOpened" }, Format = "Number" },
		{ Model = "MostMatchesPlayedLB", Store = "MatchesPlayed", Path = { "Stats", "MatchesPlayed" }, Format = "Number" },
		{ Model = "MostTimeInMatchesLB", Store = "TimeInMatches", Path = { "Stats", "TimeInMatches" }, Format = "Time" },
		{ Model = "MostTimePlayedLB", Store = "TimePlayed", Path = { "Stats", "TimePlayed" }, Format = "Time" },
		{ Model = "HighestEndlessLB", Store = "EndlessWave", Path = { "Stats", "EndlessBestWave" }, Format = "Number" },
		-- MOST AFK TIME, on the AFK place's map.
		{ Model = "MostAfkTimeLB", Store = "TimeInAfkArea", Path = { "Stats", "TimeInAfkArea" }, Format = "Time", Place = "Afk" },
	},
}