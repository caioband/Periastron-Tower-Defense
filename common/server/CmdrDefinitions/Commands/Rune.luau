return {
	Name = "rune",
	Aliases = { "runes" },
	Description = "Grants a rune tier for free, with the shop's rules (same tier extends, higher replaces, lower is refused), or removes it with tier 0. Players on this server.",
	Group = "Currency",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Who gets it.",
		},

		{
			Type = "runeName",
			Name = "rune",
			Description = "The rune. Tab completes.",
		},

		{
			Type = "integer",
			Name = "tier",
			Description = "1 to 3, or 0 to remove the rune.",
		},

		{
			Type = "positiveInteger",
			Name = "seconds",
			Description = "How long it lasts, to test expiry. Omit for the normal duration.",
			Optional = true,
		},
	},
}
