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
		Nem a queimadura nem o estouro entram aqui, e por motivos diferentes.

		A queimadura porque so o servidor sabe se o alvo ja queimava: o desenho chega
		pelo evento `MobBurning` (`VFXController:PlayBurning`).

		O estouro porque ele mora no proprio projetil -- o attachment `Explosion` do
		`PyreProjectile`, que o `ProjectileController` dispara quando o tiro chega.
		Repetir aqui daria duas explosoes na mesma bolinha.
	]]
	["Pyre"] = { PLACEMENT_EFFECT },
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

	--[[
		O `FrozenVFX` estoura no inimigo quando o projetil chega nele: `OnAttack` e o
		evento da chegada do projetil (`Unit:playAttackVisual`). O alvo `MobRoot`
		pendura o asset no `HumanoidRootPart` do inimigo e o solda, para ele seguir
		quem anda -- ver `VFXController:attachToMob`.

		O congelamento nao entra aqui: ele depende da conta de acumulos, que so o
		servidor tem, e chega pelo evento `MobFrozen` (`VFXController:PlayIced`).
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
