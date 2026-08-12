return {
	Name = "setcrates",
	Aliases = { "setcrate" },
	Description = "Sets how many crates of a rarity a player owns.",
	Group = "Crates",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "The players whose crates will be set.",
		},

		{
			Type = "crateRarity",
			Name = "rarity",
			Description = "Crate rarity (Common, Rare, Epic, Legendary).",
		},

		{
			Type = "nonNegativeInteger",
			Name = "amount",
			Description = "Amount of crates to set the rarity to.",
		},
	},
}
