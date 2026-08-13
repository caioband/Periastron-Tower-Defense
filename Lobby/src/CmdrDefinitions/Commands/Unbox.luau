return {
	Name = "unbox",
	Aliases = { "openbox" },
	Description = "Plays the unboxing animation of a crate rarity on a player's screen.",
	Group = "Crates",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "The players who will see the unboxing.",
		},

		{
			Type = "crateRarity",
			Name = "rarity",
			Description = "Crate rarity (Common, Rare, Epic, Legendary).",
		},
	},
}
