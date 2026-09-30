return {
	Name = "level",
	Aliases = { "levels", "setlevel", "lvl" },
	Description = "Sets, adds or removes levels of players. The level is not saved, Stats.XP is: the result lands at the start of the level (zero progress).",
	Group = "Data",
	Args = {
		{
			Type = "currencyAction",
			Name = "action",
			Description = "set, add or remove. Tab completes.",
		},

		{
			Type = "playerIds",
			Name = "players",
			Description = "Who gets it: usernames or #UserIds, online or not (me/all/others still work for this server).",
		},

		{
			Type = "integer",
			Name = "amount",
			Description = "How many levels. Always stays between 1 and the max level.",
		},
	},
}
