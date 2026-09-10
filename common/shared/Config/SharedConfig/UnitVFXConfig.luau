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
	["Subspace Tripminer"] = { PLACEMENT_EFFECT },
	["Entrepreneur"] = { PLACEMENT_EFFECT },
	["Azure"] = { PLACEMENT_EFFECT },

	--[[
		So o efeito de colocar. O raio dela nao entra aqui de proposito: este config e
		para efeito que o **cliente** dispara sozinho a partir do golpe (`OnAttack`,
		`OnHit`), e o raio precisa da lista de inimigos que a corrente tocou -- uma
		coisa que so o servidor tem. Ele vem pelo evento `ChainLightning`, no
		`VFXController`.
	]]
	["Electro"] = { PLACEMENT_EFFECT },
}

return UnitVFXConfig
