return {
	Name = "richtext",
	Aliases = { "textlab" },
	Description = "Opens the rich text lab: a textbox for the markup, a DISPLAY button and a container that renders it. Run it again to close.",
	Group = "UI",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Who gets the lab. Omit for yourself.",
			Optional = true,
		},
	},
}
