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
			Type = "players",
			Name = "players",
			Description = "Who gets it.",
		},

		{
			Type = "number",
			Name = "amount",
			Description = "How much. Never goes below zero.",
		},
	},
}
