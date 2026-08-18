return {
	Name = "strike",
	Aliases = { "lightning", "thunderstrike" },
	Description = "Drops a lightning bolt on a placed unit. Without a name, picks any of them.",
	Group = "Weather",
	Args = {
		{
			Type = "unitName",
			Name = "unit",
			Description = "Only hit a placed unit of this type. Omit for any. Tab completes.",
			Optional = true,
		},
	},
}
