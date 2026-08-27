local UnitAttackConfig = {

	--[[
		AttackSequence: ordered list of attack steps that cycle on each attack.
		  Animation  - name of the Animation child on the unit model to play
		  HitTime    - seconds into the animation when the hit fires to the server
		              (set to 0 to fire immediately on swing start)
		The sequence loops back to step 1 after the last step.
	--]]

	["Azure"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1, SwingSound = "AzurePeriastron" },
		},
	},

	["Entrepreneur"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 0.5 },
		},
	},

	["Subspace Tripminer"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1.15 },
		},
	},


	["Slingshot"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 0.7 },
		},
	},

	--[[
		1,017s e o frame do marcador `Hit` da animacao `Attack` do Archer -- o
		instante em que quem animou disse que a flecha sai do arco.

		**O numero fica escrito aqui mesmo com o marcador existindo**, e nao em
		`HitTime = 0` para o `Unit:playAttackVisual` escutar a track. Quem cobra o
		dano e o servidor (`UnitService:executeAttack`), que le este campo como
		windup e nao tem `AnimationTrack` nenhuma para escutar: com zero aqui, o dano
		sairia no instante do pedido enquanto o boneco ainda puxa a corda. O ramo do
		marcador la e so um fallback de cliente para unidade sem `HitTime`.

		Ou seja: o marcador e a **fonte** do numero, e este campo e a copia que as
		duas pontas obedecem. Mexeu o marcador, mexe aqui junto.
	]]
	["Archer"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1.017 },
		},
	},

	["Sword"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1 },
		},
	},

	["Slasher"] = {
		AttackSequence = {
			{ Animation = "Slash1", HitTime = 0.1 },
			{ Animation = "Slash2", HitTime = 0.1 },
		},

	},

	["Rocket"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1.5 },
		},
	},
}

return UnitAttackConfig
