return {
	Name = "weather",
	Aliases = { "setweather" },
	Description = "Applies a weather from Assets.Weathers to the loaded map. Use 'off' to clear it.",
	Group = "Weather",
	Args = {
		{
			Type = "weatherName",
			Name = "weather",
			Description = "Weather name (Snow, Thunder, ...) or 'off'. Tab completes.",
		},

		{
			Type = "number",
			Name = "duration",
			Description = "Lighting transition seconds. 0 cuts. Omit for the configured default.",
			Optional = true,
		},
	},
}
