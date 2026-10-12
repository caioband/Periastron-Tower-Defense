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
		Template = "Default",
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