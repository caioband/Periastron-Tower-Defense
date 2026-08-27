return {
	Name = "roundshop",
	Aliases = { "cardshop", "rcs" },
	Description = "Opens the round card shop offer, the same one that shows up every few waves. Rerolls the three cards.",
	Group = "Round",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Who gets the offer. Omit for everybody in the server.",
			Optional = true,
		},
	},
}
