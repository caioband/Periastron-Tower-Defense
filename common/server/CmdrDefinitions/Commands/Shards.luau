return {
	Name = "shards",
	Aliases = { "shard" },
	Description = "Sets, adds or removes the saved Shards of players (the premium currency, Stats.Shards).",
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
