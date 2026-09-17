return {
	Name = "tutorial",
	Aliases = { "tutorialprompt" },
	Description = "Sends the tutorial welcome dialogue, ignoring whether the player already did it. Nothing is written to the profile.",
	Group = "UI",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Who sees the offer. Omit for yourself.",
			Optional = true,
		},
	},
}
