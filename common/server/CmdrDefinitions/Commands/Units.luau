return {
	Name = "units",
	Aliases = { "unit", "giveunit", "inventory" },
	Description = "Sets, adds or removes units in the saved inventory. This is the profile, not the round: it survives the session and is what the Lobby builds decks from.",
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
			Type = "unitName",
			Name = "unit",
			Description = "Which unit. Tab completes. Quote names with a space: \"Subspace Tripminer\".",
		},

		{
			Type = "number",
			Name = "amount",
			Description = "How many. Omit for 1. Never goes below zero.",
			Optional = true,
		},
	},
}
