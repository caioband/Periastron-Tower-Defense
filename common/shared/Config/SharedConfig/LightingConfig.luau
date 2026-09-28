--[[
	Lighting presets.

	A preset is a Folder inside `ReplicatedStorage.Shared.Assets.Lighting`:

		Assets.Lighting
		└── Blizzard              (Folder)
			│   attributes: Ambient, Brightness, ClockTime, FogColor, ...
			├── Atmosphere        (Atmosphere)
			├── Sky               (Sky)
			└── ColorCorrection   (ColorCorrectionEffect)

	The Folder's **attributes** become properties of `Lighting` itself; its
	**children** are the instances that go inside it. `LightingService` swaps the
	contents at once and `LightingController` turns the swap into a transition,
	interpolating what can be interpolated.

	It lives in `common/` because both places use it. See docs/common/lighting.md.
]]

local LightingConfig = {}

-- Where presets live. Path from `ReplicatedStorage`; the service creates the
-- folder if it does not exist.
LightingConfig.PresetsPath = { "Shared", "Assets", "Lighting" }

--[[
	Name of the preset the service builds on start from the Lighting authored in
	the place. It guarantees every transition is preset -> preset: the client always
	has start values to read, even on the first change.
]]
LightingConfig.BaselineName = "Default"

--[[
	Preset applied as soon as the server starts. `nil` keeps the baseline.

	Careful in the Game: `MapService` applies the map's `Lighting` folder while
	loading, and the service's `start` runs after that, so setting this would
	overwrite the map lighting.
]]
LightingConfig.DefaultPreset = nil :: string?

--[[
	Prefix of the presets `MapService` registers from each map's `Lighting` folder,
	so a map name never collides with a hand-authored preset:
	`Assets.Lighting.Map_Farm` is clearly the map's, `Assets.Lighting.Farm` is not.
]]
LightingConfig.MapPrefix = "Map_"

--[[
	A Lighting child with this attribute set to `true` survives the clear: for
	something another system hung there that belongs to no preset (a menu
	BlurEffect, for example).
]]
LightingConfig.KeepAttribute = "LightingKeep"

LightingConfig.Transition = {
	Time = 1.5,
	Style = Enum.EasingStyle.Quad,
	Direction = Enum.EasingDirection.Out,
}

--[[
	Which properties each class exposes to the transition.

	Roblox has no runtime reflection (you cannot ask an instance for its
	properties), so the list is written by hand. A class not listed still enters
	Lighting normally, it just does not interpolate; to make a new class take part,
	add its entry.

	`TimeOfDay` is left out on purpose: it is `ClockTime` as a string, and the two
	together would only fight over who writes last.
]]
LightingConfig.Properties = {
	Lighting = {
		"Ambient",
		"Brightness",
		"ColorShift_Bottom",
		"ColorShift_Top",
		"EnvironmentDiffuseScale",
		"EnvironmentSpecularScale",
		"GlobalShadows",
		"OutdoorAmbient",
		"ShadowSoftness",
		"ClockTime",
		"GeographicLatitude",
		"ExposureCompensation",
		"FogColor",
		"FogEnd",
		"FogStart",
	},

	Atmosphere = {
		"Density",
		"Offset",
		"Color",
		"Decay",
		"Glare",
		"Haze",
	},

	Sky = {
		"CelestialBodiesShown",
		"MoonAngularSize",
		"MoonTextureId",
		"SkyboxBk",
		"SkyboxDn",
		"SkyboxFt",
		"SkyboxLf",
		"SkyboxRt",
		"SkyboxUp",
		"StarCount",
		"SunAngularSize",
		"SunTextureId",
	},

	ColorCorrectionEffect = {
		"Enabled",
		"Brightness",
		"Contrast",
		"Saturation",
		"TintColor",
	},

	BloomEffect = {
		"Enabled",
		"Intensity",
		"Size",
		"Threshold",
	},

	BlurEffect = {
		"Enabled",
		"Size",
	},

	SunRaysEffect = {
		"Enabled",
		"Intensity",
		"Spread",
	},

	DepthOfFieldEffect = {
		"Enabled",
		"FarIntensity",
		"FocusDistance",
		"InFocusRadius",
		"NearIntensity",
	},
}

--[[
	Each class's values that mean "this effect is doing nothing".

	This is what lets an instance **enter and leave** by interpolating instead of
	popping. Changing maps changes which effects exist far more than the values of
	those that remain; without this, most of the visual change is a hard cut.

	Only intensity properties are listed. `Atmosphere.Color` does not need to be,
	for example: with `Density = 0` it paints nothing.

	A class without an entry appears and disappears at once, which is right: `Sky`
	is a texture and has no halfway.
]]
LightingConfig.Neutral = {
	Atmosphere = {
		Density = 0,
		Haze = 0,
		Glare = 0,
	},

	ColorCorrectionEffect = {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = Color3.new(1, 1, 1),
	},

	BloomEffect = {
		Intensity = 0,
	},

	BlurEffect = {
		Size = 0,
	},

	SunRaysEffect = {
		Intensity = 0,
	},

	DepthOfFieldEffect = {
		FarIntensity = 0,
		NearIntensity = 0,
	},
}

function LightingConfig:GetProperties(className: string): { string }
	return self.Properties[className] or {}
end

--[[
	A copy of `values` with the intensity properties zeroed: the start for an
	entering instance and the end for an exiting one. A class without a neutral
	returns `values` unchanged, leaving nothing to interpolate.
]]
function LightingConfig:GetNeutral(className: string, values: { [string]: any }): { [string]: any }
	local neutral = self.Neutral[className]
	if not neutral then
		return values
	end

	local result = table.clone(values)
	for propertyName, value in neutral do
		if result[propertyName] ~= nil then
			result[propertyName] = value
		end
	end

	return result
end

return LightingConfig
