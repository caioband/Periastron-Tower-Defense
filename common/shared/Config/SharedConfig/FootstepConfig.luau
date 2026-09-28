--[[
	Footstep sounds, per surface.

	The game is built from studs, so a part's Material says nothing about the
	floor; the surface comes from an attribute on the Part (or any ancestor).
	FootstepController reads it on whatever the ray under the foot hits.

		Part.Surface = "Grass"

	Each surface has a list of ids, its variations. The controller draws one per
	step and avoids repeating the previous one, so three or four are enough not to
	sound mechanical. A surface without ids plays nothing (and warns once in
	Studio). See docs/common/footsteps.md.
]]

local FootstepConfig = {}

-- Name of the attribute read on the part stepped on.
FootstepConfig.Attribute = "Surface"

--[[
	Surface used when the part has the attribute nowhere in its hierarchy. `nil`
	means silence, on purpose: an untagged part is obviously mute instead of
	pretending to be grass.
]]
FootstepConfig.Default = nil :: string?

-- How far the ray goes down from the foot looking for the floor.
FootstepConfig.RayLength = 5

-- Overall volume, multiplied by the surface's Volume.
FootstepConfig.Volume = 0.5

-- Each step draws a PlaybackSpeed in this range.
FootstepConfig.PitchRange = { 0.94, 1.06 }

-- Safety limit against a duplicated marker or an animation sped up too much.
FootstepConfig.MinInterval = 0.1

-- Rolloff of the 3D sound at the foot.
FootstepConfig.RollOffMin = 4
FootstepConfig.RollOffMax = 45

--[[
	One entry per surface. Besides `Ids`, it accepts its own `Volume` and
	`PitchRange`, which replace the general ones above.

		Stone = {
			Ids = { "rbxassetid://111", "rbxassetid://222" },
			Volume = 0.8,
			PitchRange = { 0.9, 1.1 },
		},
]]
FootstepConfig.Surfaces = {
	Grass = {
		Ids = {
			"rbxassetid://122259384750055",
			"rbxassetid://79848070365594",
			"rbxassetid://73277262867221",
		},
	},
}

--[[
	Jump. Same shape as the surfaces (accepts its own `Volume` and `PitchRange`)
	and preloaded with them, but it does not depend on the floor: it plays on the
	jump, whatever the surface. More than one id becomes variations, as for steps.
]]
FootstepConfig.Jump = {
	Ids = {
		"rbxassetid://136494849780065",
	},
}

return FootstepConfig
