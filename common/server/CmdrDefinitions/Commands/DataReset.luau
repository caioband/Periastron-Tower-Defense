return {
	Name = "datareset",
	Aliases = { "resetdata" },
	Description = "Test cleanup: resets the whole profile to a new player's and kicks the player, so they rejoin fresh. QA and Studio only.",
	Group = "Data",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Whose profile to reset. Omit for yourself.",
			Optional = true,
		},
	},
}
