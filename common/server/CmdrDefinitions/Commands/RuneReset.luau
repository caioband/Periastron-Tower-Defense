return {
	Name = "runereset",
	Aliases = { "clearrunes", "resetrunes" },
	Description = "Removes every active rune from the profile (and its match lock), so the rune shop can be tested from scratch. Players on this server.",
	Group = "Currency",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Whose runes to clear. Omit for yourself.",
			Optional = true,
		},
	},
}
