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
