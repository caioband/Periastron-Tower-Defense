return {
	Name = "unbox",
	Aliases = { "openbox" },
	Description = "Rolls a crate rarity for a player and plays the unboxing in front of them, for the whole server.",
	Group = "Crates",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "The players the crate is opened for. Everyone in the lobby sees it.",
		},

		{
			Type = "crateRarity",
			Name = "rarity",
			Description = "Crate rarity (Common, Rare, Epic, Legendary).",
		},
	},
}
