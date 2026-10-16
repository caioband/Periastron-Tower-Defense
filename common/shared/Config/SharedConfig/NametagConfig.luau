local LevelConfig = require(script.Parent.LevelConfig)

local NametagConfig = {}

NametagConfig.PROFILE_KEY = "Nametags"
NametagConfig.ATTRIBUTE = "EquippedNametag"
NametagConfig.LEVEL_ATTRIBUTE = "Level"
NametagConfig.ASSET_FOLDER = "Nametags"
NametagConfig.TAG_NAME = "Nametag"
NametagConfig.DEFAULT = "Default"
NametagConfig.LEVEL_FORMAT = "LVL %d"
NametagConfig.LOCKED_FORMAT = "LVL %d"
NametagConfig.TITLE_SCALE = 0.8
NametagConfig.SHOW_OWN = true

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)),
	ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 160, 50)),
	ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 235, 70)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 230, 110)),
	ColorSequenceKeypoint.new(0.67, Color3.fromRGB(70, 170, 255)),
	ColorSequenceKeypoint.new(0.83, Color3.fromRGB(170, 100, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 70, 70)),
})

--[[
	`UserIds = { [userId] = true }` restricts a nametag to those players: the server
	grants it to them on load, strips it from everyone else, and refuses to grant or
	equip it for anyone not listed (see `NametagService`).

	`Gamepass = "<GamepassConfig key>"` ties a nametag to a pass: the server grants it
	while the player owns the pass (bought or gifted) and takes it away when they no
	longer do.
]]
NametagConfig.Nametags = {
	Default = {
		DisplayName = "Default",
		Description = "The standard nametag.",
		Template = "Default",
		Icon = "",
		Free = true,
		Order = 0,
	},

	Golden = {
		DisplayName = "Golden",
		Description = "Shines a little brighter.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 1,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(92, 58, 0),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 236, 140)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 196, 40)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 236, 140)),
				}),
				GradientRotation = 90,
			},
			Level = {
				TextColor3 = Color3.fromRGB(255, 220, 120),
				StrokeColor = Color3.fromRGB(92, 58, 0),
			},
		},
	},

	Amethyst = {
		DisplayName = "Amethyst",
		Description = "A shifting violet glow.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 2,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(40, 8, 64),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 40, 200)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(190, 110, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(245, 215, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(190, 110, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 40, 200)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(40, 8, 64),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 70, 230)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(220, 170, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 70, 230)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
		},
	},

	PumpkinPatch = {
		DisplayName = "Pumpkin Patch",
		Description = "Carved, lit, and grinning.",
		Template = "HalloweenPumpkin",
		Icon = "",
		Free = false,
		Order = 3,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(38, 14, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 228, 120)),
					ColorSequenceKeypoint.new(0.35, Color3.fromRGB(255, 160, 30)),
					ColorSequenceKeypoint.new(0.7, Color3.fromRGB(235, 96, 10)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 50, 0)),
				}),
				GradientRotation = 90,
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(38, 14, 0),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 90)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(230, 100, 20)),
				}),
				GradientRotation = 90,
			},
		},
	},

	GraveCandle = {
		DisplayName = "Grave Candle",
		Description = "Still burning after all these years.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 4,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(20, 18, 16),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 252, 240)),
					ColorSequenceKeypoint.new(0.4, Color3.fromRGB(236, 226, 196)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(214, 196, 120)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 132, 70)),
				}),
				GradientRotation = 90,
			},
			Level = {
				TextColor3 = Color3.fromRGB(240, 230, 200),
				StrokeColor = Color3.fromRGB(20, 18, 16),
			},
		},
	},

	Phantom = {
		DisplayName = "Phantom",
		Description = "You can see right through it.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 5,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(10, 24, 22),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 255, 180)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(200, 255, 235)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(150, 110, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(200, 255, 235)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 255, 180)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.35 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(10, 24, 22),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 255, 200)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(180, 150, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 255, 200)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.35 },
			},
		},
	},

	BloodMoon = {
		DisplayName = "Blood Moon",
		Description = "Rises once a year. Tonight.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 6,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(24, 0, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 40, 40)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(120, 0, 10)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 110, 40)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(120, 0, 10)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 40, 40)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Rotate", Speed = 0.3 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(24, 0, 0),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 50)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(150, 10, 20)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 70, 50)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Rotate", Speed = 0.3 },
			},
		},
	},

	WitchsBrew = {
		DisplayName = "Witch's Brew",
		Description = "Double, double, toil and trouble.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 7,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(16, 4, 24),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(140, 255, 40)),
					ColorSequenceKeypoint.new(0.2, Color3.fromRGB(170, 60, 255)),
					ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 140, 20)),
					ColorSequenceKeypoint.new(0.6, Color3.fromRGB(170, 60, 255)),
					ColorSequenceKeypoint.new(0.8, Color3.fromRGB(60, 210, 40)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 255, 40)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 1.2 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(16, 4, 24),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(140, 255, 40)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(190, 90, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 255, 40)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 1.2 },
			},
		},
	},

	CandyCorn = {
		DisplayName = "Candy Corn",
		Description = "Love it or hate it, it's here.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 8,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(60, 24, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 252, 240)),
					ColorSequenceKeypoint.new(0.32, Color3.fromRGB(255, 252, 240)),
					ColorSequenceKeypoint.new(0.34, Color3.fromRGB(255, 150, 20)),
					ColorSequenceKeypoint.new(0.65, Color3.fromRGB(255, 150, 20)),
					ColorSequenceKeypoint.new(0.67, Color3.fromRGB(255, 214, 40)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 214, 40)),
				}),
				GradientRotation = 90,
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(60, 24, 0),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 200)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 160, 30)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 214, 40)),
				}),
				GradientRotation = 90,
			},
		},
	},

	Bonechiller = {
		DisplayName = "Bonechiller",
		Description = "Rattles when it walks.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 9,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(26, 22, 18),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(240, 232, 210)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(176, 166, 146)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 252, 242)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(176, 166, 146)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(240, 232, 210)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.25 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(26, 22, 18),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(210, 200, 178)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 250, 236)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(210, 200, 178)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.25 },
			},
		},
	},

	Cobweb = {
		DisplayName = "Cobweb",
		Description = "Nobody's dusted in centuries.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 10,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(14, 14, 18),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(96, 98, 108)),
					ColorSequenceKeypoint.new(0.2, Color3.fromRGB(170, 172, 182)),
					ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.6, Color3.fromRGB(170, 172, 182)),
					ColorSequenceKeypoint.new(0.8, Color3.fromRGB(70, 72, 82)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(96, 98, 108)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.3 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(14, 14, 18),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(140, 142, 152)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(235, 236, 240)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 142, 152)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.3 },
			},
		},
	},

	Banshee = {
		DisplayName = "Banshee",
		Description = "You'll hear it before you see it.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 11,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(8, 18, 34),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 190, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(220, 240, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(150, 160, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(220, 240, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 190, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.9 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(8, 18, 34),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 205, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(235, 245, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 205, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.9 },
			},
		},
	},

	Nightshade = {
		DisplayName = "Nightshade",
		Description = "Pretty. Poisonous. Pick carefully.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 12,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(10, 0, 16),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(110, 20, 170)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(30, 6, 46)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(230, 60, 200)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(30, 6, 46)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 20, 170)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Rotate", Speed = 0.25 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(10, 0, 16),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 50, 220)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(240, 110, 220)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 50, 220)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Rotate", Speed = 0.25 },
			},
		},
	},

	Cursed = {
		DisplayName = "Cursed",
		Description = "Don't read it out loud.",
		Template = "Default",
		Icon = "",
		Free = false,
		Order = 13,
		Style = {
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(0, 12, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(110, 255, 60)),
					ColorSequenceKeypoint.new(0.2, Color3.fromRGB(10, 30, 8)),
					ColorSequenceKeypoint.new(0.4, Color3.fromRGB(190, 255, 120)),
					ColorSequenceKeypoint.new(0.6, Color3.fromRGB(10, 30, 8)),
					ColorSequenceKeypoint.new(0.8, Color3.fromRGB(60, 200, 30)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 255, 60)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Rotate", Speed = 0.6 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(0, 12, 0),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(110, 255, 60)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(30, 90, 20)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 255, 60)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Rotate", Speed = 0.6 },
			},
		},
	},

	SoulReaper = {
		DisplayName = "Soul Reaper",
		Description = "Collects what's owed.",
		Template = "Default",
		Icon = "",
		Free = false,
		Title = "REAPER",
		Order = 14,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(10, 0, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 205, 215)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(60, 62, 70)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(60, 62, 70)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 205, 215)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(10, 0, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 10, 30)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(30, 0, 4)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 70, 70)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(30, 0, 4)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 10, 30)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(10, 0, 0),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(220, 40, 50)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(235, 235, 240)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 40, 50)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
		},
	},

	VIP = {
		DisplayName = "VIP",
		Description = "Thanks for supporting the game.",
		Template = "Default",
		Icon = "",
		Free = false,
		Title = "VIP",
		Gamepass = "VIP",
		Order = 40,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(16, 12, 24),
				StrokeThickness = 0.15,
				Gradient = RAINBOW,
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.2 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(16, 12, 24),
				StrokeThickness = 0.15,
				Gradient = RAINBOW,
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.18 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(16, 12, 24),
				Gradient = RAINBOW,
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.22 },
			},
		},
	},

	Tester = {
		DisplayName = "Tester",
		Description = "Found it, logged it, broke it again.",
		Template = "Default",
		Icon = "",
		Free = false,
		Title = "TESTER",
		Order = 50,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(0, 20, 12),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(57, 255, 120)),
					ColorSequenceKeypoint.new(0.2, Color3.fromRGB(0, 140, 70)),
					ColorSequenceKeypoint.new(0.4, Color3.fromRGB(220, 255, 230)),
					ColorSequenceKeypoint.new(0.6, Color3.fromRGB(0, 200, 255)),
					ColorSequenceKeypoint.new(0.8, Color3.fromRGB(0, 140, 70)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(57, 255, 120)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.9 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(0, 20, 12),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 230, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(57, 255, 120)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(240, 255, 245)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(57, 255, 120)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 230, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.6 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(0, 20, 12),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 255, 170)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 210, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 255, 170)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.6 },
			},
		},
	},

	Gode = {
		DisplayName = "Gode",
		Description = "One of a kind.",
		Template = "DevGode",
		Icon = "",
		Free = false,
		Title = "GODE",
		UserIds = { [1038697440] = true },
		Order = 60,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(46, 18, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 130, 20)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 160, 50)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 130, 20)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.7 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(46, 18, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 130, 20)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 240, 220)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(255, 130, 20)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(46, 18, 0),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 150, 40)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 150, 40)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
		},
	},

	Programmer = {
		DisplayName = "Programmer",
		Description = "It works on my machine.",
		Template = "DevProgrammer",
		Icon = "",
		Free = false,
		Title = "PROGRAMMER",
		UserIds = { [4133615556] = true },
		Order = 61,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(26, 8, 46),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(170, 90, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 140, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 90, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.7 },
				Bounce = { Height = 0.16, Speed = 0.5, Sweep = 0.6, Hop = 0.3 },

			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(26, 8, 46),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(170, 90, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(240, 225, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(170, 90, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
				Bounce = { Height = 0.16, Speed = 0.5, Sweep = 0.6, Hop = 0.3 },

			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(26, 8, 46),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(185, 120, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(185, 120, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
				Bounce = { Height = 0.16, Speed = 0.5, Sweep = 0.6, Hop = 0.3 },

			},
		},
	},

	Caio = {
		DisplayName = "Caio",
		Description = "The one who started it all.",
		Template = "DevCaio",
		Icon = "",
		Free = false,
		Title = "CAIO",
		UserIds = { [46871391] = true },
		Order = 62,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(4, 18, 44),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(60, 150, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(110, 185, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 150, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.7 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(4, 18, 44),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(60, 150, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(225, 240, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(60, 150, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(4, 18, 44),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 170, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 170, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.5 },
			},
		},
	},

		Contributor = {
		DisplayName = "Contributor",
		Description = "Helped build the game.",
		Template = "Default",
		Icon = "",
		Free = false,
		Title = "CONTRIBUTOR",
		Order = 55,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(6, 18, 36),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 220, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 120, 200)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 220, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.4 },
				Bounce = { Height = 0.2, Speed = 0.5, Sweep = 0.6, Hop = 0.3 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(6, 18, 36),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(80, 220, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 200, 235)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(80, 220, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.3 },
				Bounce = { Height = 0.16, Speed = 0.5, Sweep = 0.6, Hop = 0.3 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(6, 18, 36),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(110, 225, 255)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 160, 220)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 225, 255)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.3 },
			},
		},
	},



	LevelBronze = {
		DisplayName = "Bronze",
		Description = "Reach level 15.",
		Template = "PrestigeBronze",
		Icon = "",
		Free = false,
		UnlockLevel = 15,
		Title = "SEASONED",
		Order = 100,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(48, 22, 6),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(176, 105, 52)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(110, 58, 24)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 206, 150)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(110, 58, 24)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(176, 105, 52)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.3 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(48, 22, 6),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(205, 127, 50)),
					ColorSequenceKeypoint.new(0.3, Color3.fromRGB(150, 82, 32)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 220, 175)),
					ColorSequenceKeypoint.new(0.7, Color3.fromRGB(150, 82, 32)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(205, 127, 50)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.3 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(48, 22, 6),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(205, 127, 50)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 200, 140)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(205, 127, 50)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.3 },
			},
		},
	},

	LevelSilver = {
		DisplayName = "Silver",
		Description = "Reach level 25.",
		Template = "PrestigeSilver",
		Icon = "",
		Free = false,
		UnlockLevel = 25,
		Title = "VETERAN",
		Order = 101,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(30, 34, 44),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(170, 178, 190)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(100, 108, 122)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(100, 108, 122)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 178, 190)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.45 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(30, 34, 44),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(192, 198, 208)),
					ColorSequenceKeypoint.new(0.3, Color3.fromRGB(128, 136, 150)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(0.7, Color3.fromRGB(128, 136, 150)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(192, 198, 208)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.45 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(30, 34, 44),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 188, 200)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(245, 248, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 188, 200)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.45 },
			},
		},
	},

	LevelGold = {
		DisplayName = "Gold",
		Description = "Reach level 50.",
		Template = "PrestigeGold",
		Icon = "",
		Free = false,
		UnlockLevel = 50,
		Title = "LEGEND",
		Order = 102,
		Style = {
			Title = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(70, 40, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(230, 170, 30)),
					ColorSequenceKeypoint.new(0.2, Color3.fromRGB(150, 95, 0)),
					ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 245, 190)),
					ColorSequenceKeypoint.new(0.6, Color3.fromRGB(255, 210, 60)),
					ColorSequenceKeypoint.new(0.8, Color3.fromRGB(150, 95, 0)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(230, 170, 30)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.6 },
			},
			Username = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(70, 40, 0),
				StrokeThickness = 0.15,
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 40)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(190, 125, 0)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 250, 210)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(190, 125, 0)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 200, 40)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.6 },
			},
			Level = {
				TextColor3 = Color3.new(1, 1, 1),
				StrokeColor = Color3.fromRGB(70, 40, 0),
				Gradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(240, 180, 30)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 240, 170)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(240, 180, 30)),
				}),
				GradientRotation = 0,
				Animation = { Mode = "Scroll", Speed = 0.6 },
			},
		},
	},
}

function NametagConfig.Get(id : any)
	if typeof(id) ~= "string" then
		return nil
	end

	return NametagConfig.Nametags[id]
end

function NametagConfig.IsFree(id : any) : boolean
	local nametag = NametagConfig.Get(id)
	return nametag ~= nil and nametag.Free == true
end

--- Whether the nametag is limited to the players in its `UserIds`.
function NametagConfig.IsRestricted(id : any) : boolean
	local nametag = NametagConfig.Get(id)
	return nametag ~= nil and typeof(nametag.UserIds) == "table"
end

--- Whether `userId` may own the nametag: always for unrestricted ones, only listed ids otherwise.
function NametagConfig.AllowsUser(id : any, userId : number?) : boolean
	local nametag = NametagConfig.Get(id)
	if not nametag then
		return false
	end

	if typeof(nametag.UserIds) ~= "table" then
		return true
	end

	return userId ~= nil and nametag.UserIds[userId] == true
end

--- The `GamepassConfig` key the nametag comes with, or nil.
function NametagConfig.GamepassOf(id : any) : string?
	local nametag = NametagConfig.Get(id)
	local pass = nametag and nametag.Gamepass
	return if typeof(pass) == "string" and pass ~= "" then pass else nil
end

function NametagConfig.UnlockLevelOf(id : any) : number?
	local nametag = NametagConfig.Get(id)
	local level = nametag and nametag.UnlockLevel
	return if typeof(level) == "number" then level else nil
end

function NametagConfig.IsLevelUnlocked(id : any, level : number?) : boolean
	local required = NametagConfig.UnlockLevelOf(id)
	return required ~= nil and (tonumber(level) or 0) >= required
end

function NametagConfig.IsAvailable(id : any, owned : { [string] : boolean }?, level : number?) : boolean
	if not NametagConfig.Get(id) then
		return false
	end

	if NametagConfig.IsFree(id) or NametagConfig.IsLevelUnlocked(id, level) then
		return true
	end

	return owned ~= nil and owned[id] == true
end

function NametagConfig.LevelOf(data : any) : number
	local stats = typeof(data) == "table" and data.Stats or nil
	local xp = typeof(stats) == "table" and stats.XP or 0
	return LevelConfig:Resolve(xp).Level
end

function NametagConfig.Resolve(id : any) : (string, any)
	local nametag = NametagConfig.Get(id)
	if nametag then
		return id, nametag
	end

	return NametagConfig.DEFAULT, NametagConfig.Nametags[NametagConfig.DEFAULT]
end

function NametagConfig.createEmpty()
	return { Owned = {}, Equipped = nil }
end

function NametagConfig.sanitize(raw : any, level : number?)
	local clean = NametagConfig.createEmpty()
	if typeof(raw) ~= "table" then
		return clean
	end

	if typeof(raw.Owned) == "table" then
		for id, owned in raw.Owned do
			if typeof(id) == "string" and owned == true then
				clean.Owned[id] = true
			end
		end
	end

	local equipped = raw.Equipped
	if NametagConfig.IsAvailable(equipped, clean.Owned, level) then
		clean.Equipped = equipped
	end

	return clean
end

function NametagConfig.ordered() : { string }
	local ids = {}
	for id in NametagConfig.Nametags do
		table.insert(ids, id)
	end

	table.sort(ids, function(a, b)
		local orderA = NametagConfig.Nametags[a].Order or 0
		local orderB = NametagConfig.Nametags[b].Order or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a < b
	end)

	return ids
end

function NametagConfig.nonEmpty(value : any) : string?
	return if typeof(value) == "string" and value ~= "" then value else nil
end

return NametagConfig