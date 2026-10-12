return {
	Name = "nametag",
	Aliases = { "nametags" },
	Description = "Gives, takes, equips or unequips a nametag. Players on this server.",
	Group = "Currency",
	Args = {
		{
			Type = "nametagAction",
			Name = "action",
			Description = "give, take, equip or unequip. Tab completes.",
		},

		{
			Type = "players",
			Name = "players",
			Description = "Who.",
		},

		{
			Type = "nametagName",
			Name = "nametag",
			Description = "The nametag id from NametagConfig. Tab completes.",
		},
	},
}