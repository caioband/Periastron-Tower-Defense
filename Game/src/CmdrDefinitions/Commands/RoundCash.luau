return {
	Name = "roundcash",
	Aliases = { "sessioncash" },
	Description = "Sets, adds or removes the money players spend on towers during the round. Does not touch the saved Cash.",
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
