return {
	Name = "globalannounce",
	Aliases = { "gannounce" },
	Description = "Shows a purple/white announcement on every player's screen, in every server and both places.",
	Group = "Server",
	Args = {
		{
			Type = "string",
			Name = "message",
			Description = "The announcement text.",
		},
	},
}