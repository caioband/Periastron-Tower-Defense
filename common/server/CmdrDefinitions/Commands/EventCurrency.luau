return {
	Name = "eventcurrency",
	Aliases = { "ec" },
	Description = "Sets, adds or removes the event currency (Stats.EventCurrency) of players on this server.",
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
			Description = "Who gets it. Players on this server only.",
		},

		{
			Type = "number",
			Name = "amount",
			Description = "How much. Never goes below zero.",
		},
	},
}
