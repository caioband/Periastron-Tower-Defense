local PLACEMENT_EFFECT = {
	Event = "OnPlace",
	Target = "Unit",
	Effect = "PlacementVFX",
	Offset = Vector3.new(0, -0.95, 0),
}

local UnitVFXConfig = {
	["Rocket"] = {
		PLACEMENT_EFFECT,
		{
			Event = "OnHit",
			Target = "Mob",
			Effect = "ExplosionRocketeer",
			Offset = Vector3.new(0, 0, 0),
			Attach = false,
			Duration = 1.5,
		},
	},
	["Slasher"] = { PLACEMENT_EFFECT },
	["Sword"] = { PLACEMENT_EFFECT },
	["Slingshot"] = { PLACEMENT_EFFECT },
	["Subspace Tripminer"] = { PLACEMENT_EFFECT },
	["Entrepreneur"] = { PLACEMENT_EFFECT },
	["Azure"] = { PLACEMENT_EFFECT },
}

return UnitVFXConfig
