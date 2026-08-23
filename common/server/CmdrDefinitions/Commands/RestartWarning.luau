return {
	Name = "restartwarning",
	Aliases = { "testrestart" },
	Description = "Fakes a game.ServerRestartScheduled so the on-screen restart warning can be tested. Nothing is actually restarted.",
	Group = "Server",
	Args = {
		{
			Type = "closeReason",
			Name = "source",
			Description = "Enum.CloseReason name (DeveloperUpdate, RobloxMaintenance, ...). Tab completes.",
		},

		{
			Type = "number",
			Name = "seconds",
			Description = "Seconds until the fake restart. Omit for 5 minutes.",
			Optional = true,
		},
	},
}
