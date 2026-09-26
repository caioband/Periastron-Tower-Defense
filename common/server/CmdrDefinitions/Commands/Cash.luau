return {
	Name = "cash",
	Aliases = { "money", "coins" },
	Description = "Sets, adds or removes the saved Cash of players (the lobby currency, Stats.Cash). Round money is 'roundcash'.",
	Group = "Currency",
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
			Type = "number",
			Name = "amount",
			Description = "How much. Never goes below zero.",
		},
	},
}
