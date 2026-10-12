return {
	Name = "skin",
	Aliases = { "skins" },
	Description = "Gives, takes, equips or unequips a unit skin. Players on this server.",
	Group = "Currency",
	Args = {
		{
			Type = "skinAction",
			Name = "action",
			Description = "give, take, equip or unequip. Tab completes.",
		},

		{
			Type = "players",
			Name = "players",
			Description = "Who.",
		},

		{
			Type = "skinName",
			Name = "skin",
			Description = "The skin id from SkinConfig. Tab completes.",
		},
	},
}