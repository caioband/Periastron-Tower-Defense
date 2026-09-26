return {
	Name = "viewdata",
	Aliases = { "inspectdata", "olddata" },
	Description = "Reads a player's saved profile (read-only, works offline). Pick an old store key and/or a past date to see old data.",
	Group = "Data",
	Args = {
		{
			Type = "playerId",
			Name = "player",
			Description = "Username or #UserId. Does not need to be in the server.",
		},

		{
			Type = "string",
			Name = "store",
			Description = "ProfileStore key, e.g. PROD_KEY_1. Omit (or use 'current') for the key in use now.",
			Optional = true,
		},

		{
			Type = "string",
			Name = "date",
			Description = "UTC date YYYY-MM-DD or YYYY-MM-DDTHH:MM. Shows the last save up to that moment. Omit for the latest save.",
			Optional = true,
		},
	},
}
