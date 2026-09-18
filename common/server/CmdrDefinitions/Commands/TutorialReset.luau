return {
	Name = "tutorialreset",
	Aliases = { "resettutorial" },
	Description = "Clears the Tutorial flag in the profile, so the welcome offer shows up again. Re-opens it right away in the lobby.",
	Group = "UI",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Whose profile to clear. Omit for yourself.",
			Optional = true,
		},
	},
}
