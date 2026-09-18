return {
	Name = "tutorialshop",
	Aliases = { "tutorial2" },
	Description = "Runs the second half of the tutorial, the one that happens in the lobby: points at the shop until the Crate of Beginnings is bought.",
	Group = "UI",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Who gets it. Omit for yourself.",
			Optional = true,
		},
	},
}
