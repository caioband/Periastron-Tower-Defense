return {
	Name = "arrow",
	Aliases = { "indicator" },
	Description = "Points the indicator arrow at a world position. Omit the position to clear it.",
	Group = "UI",
	Args = {
		{
			Type = "vector3",
			Name = "position",
			Description = "Where to point, as x,y,z. Omit to clear the arrow.",
			Optional = true,
		},

		{
			Type = "players",
			Name = "players",
			Description = "Who sees it. Omit for yourself.",
			Optional = true,
		},
	},
}
