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
	["Berserker"] = { PLACEMENT_EFFECT },
	["Slingshot"] = { PLACEMENT_EFFECT },
	["Archer"] = { PLACEMENT_EFFECT },
	--[[
		Neither the burn nor the burst belongs here, for different reasons.

		The burn, because only the server knows whether the target was already
		burning: the drawing arrives through `MobBurning` (`VFXController:PlayBurning`).

		The burst, because it lives in the projectile itself: the `Explosion`
		attachment of `PyreProjectile`, fired by `ProjectileController` on arrival.
		Repeating it here would give two explosions on the same ball.
	]]
	["Pyre"] = { PLACEMENT_EFFECT },
	["Subspace Tripminer"] = { PLACEMENT_EFFECT },
	["Entrepreneur"] = { PLACEMENT_EFFECT },
	["Azure"] = { PLACEMENT_EFFECT },

	--[[
		Only the placement effect. Its lightning is left out on purpose: this config
		is for effects the **client** fires by itself from an attack (`OnAttack`,
		`OnHit`), and the lightning needs the list of enemies the chain touched,
		which only the server has. It arrives through `ChainLightning`, in
		`VFXController`.
	]]
	["Electro"] = { PLACEMENT_EFFECT },

	--[[
		`FrozenVFX` bursts on the enemy when the projectile reaches it: `OnAttack` is
		the projectile's arrival (`Unit:playAttackVisual`). The `MobRoot` target
		attaches the asset to the enemy's `HumanoidRootPart` and welds it, so it
		follows a walking enemy; see `VFXController:attachToMob`.

		The freeze is not here: it depends on the stack count, which only the server
		has, and arrives through `MobFrozen` (`VFXController:PlayIced`).
	]]
	["Frostione"] = {
		PLACEMENT_EFFECT,
		{
			Event = "OnAttack",
			Target = "MobRoot",
			Effect = "FrozenVFX",
		},
	},
}

return UnitVFXConfig
