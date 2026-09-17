return {
	Name = "highlight",
	Aliases = { "spotlight" },
	Description = "Dims the screen except a GuiObject, by name path from PlayerGui (HUD.HUDLeft.Shop). Omit the path to clear it.",
	Group = "UI",
	Args = {
		{
			Type = "string",
			Name = "path",
			Description = "Name path from PlayerGui, dot separated. Omit to clear the highlight.",
			Optional = true,
		},

		{
			Type = "players",
			Name = "players",
			Description = "Who sees it. Omit for yourself.",
			Optional = true,
		},
	},
}
