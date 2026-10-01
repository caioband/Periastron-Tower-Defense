return {
	Name = "friendinvite",
	Aliases = { "invitefriend" },
	Description = "Suggests an online friend to invite, now, in a CoreGui notification. Runs outside the automatic schedule.",
	Group = "UI",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Who gets the suggestion. Omit for yourself.",
			Optional = true,
		},

		{
			Type = "boolean",
			Name = "ignoreCooldown",
			Description = "true puts friends suggested in the last hour back in the draw.",
			Optional = true,
		},
	},
}
