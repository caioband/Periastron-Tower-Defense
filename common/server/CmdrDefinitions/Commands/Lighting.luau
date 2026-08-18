return {
	Name = "lighting",
	Aliases = { "setlighting" },
	Description = "Applies a Lighting preset from Assets.Lighting to everyone.",
	Group = "Lighting",
	Args = {
		{
			Type = "lightingPreset",
			Name = "preset",
			Description = "Preset name (Default, Map_Farm, …). Tab completes.",
		},

		{
			Type = "number",
			Name = "duration",
			Description = "Transition seconds. 0 cuts. Omit for the configured default.",
			Optional = true,
		},
	},
}
