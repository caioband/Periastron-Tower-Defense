return {
	Name = "dialog",
	Aliases = { "testdialog" },
	Description = "Plays the test dialogue from DialogConfig.Demo in SharedUIs.DialogGUI.Container. Omit the players to send it to everyone.",
	Group = "UI",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Who sees the dialogue. Omit for everyone.",
			Optional = true,
		},

		{
			Type = "boolean",
			Name = "auto",
			Description = "true runs the lines by itself instead of waiting for the player to advance. Defaults to false.",
			Optional = true,
		},
	},
}
