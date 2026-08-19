--[[
	Os numeros de cada unidade.

	Duas regras seguram esta tabela, e vale conferi-las antes de mexer:

	1. Dano por segundo dividido pelo custo. E o que decide se uma unidade vale a
	   pena, e o teto e 15 por 100 de caixa. O Slasher ficava em 26,7 — quase tres
	   vezes o segundo colocado — e por isso encher o mapa de Slasher era a jogada
	   otima em qualquer dificuldade. A escada agora e por raridade: Common ~10,
	   Rare ~10,5 com alcance, Epic ~11 com utilidade, Legendary 11 a 14.

	2. Alcance como eixo de diferenciacao. Cinco das sete unidades tinham alcance
	   3, o que tornava posicionamento irrelevante — todas precisavam colar no
	   caminho. As faixas agora sao curto (4 a 6), medio (10) e longo (16), e o
	   alcance longo e do Slingshot, que nao tem area nem dano alto.

	DPS = Damage * Hits / Cooldown.
]]

local UnitStats = {
	--[[ LEGENDARY ]]

	-- A mais forte em dano bruto, e de alcance curto: quatro golpes por ciclo, mas
	-- so contra quem chega perto.
	["Azure"] = {
		Rarity = "Legendary",
		Cost = 250,
		Damage = 17,
		Range = 6,
		Cooldown = 2,
		AttackType = "MultiShot",
		HitInterval = 0.25,
		Hits = 4,
		RangeStats = {
			Increment = 1,
			Max = 10,
		},
	},

	-- Area grande e alcance medio: o raio da explosao (8) cabe dentro do alcance,
	-- que era 3 e fazia a unidade explodir uma area que ela nao enxergava.
	["Rocket"] = {
		Rarity = "Legendary",
		Cost = 450,
		Damage = 120,
		Range = 10,
		Cooldown = 2.5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Rocket", Speed = 55 },
		AOE = { Radius = 8 },

		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	--[[ EPIC ]]

	["Subspace Tripminer"] = {
		Rarity = "Epic",
		Cost = 350,
		Damage = 75,
		Range = 10,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Tripmine = {
			BaseLimit = 3,
			LimitPerUpgrade = 1,
			TriggerRadius = 2.5,
			AOE = { Radius = 6 },
		},
		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	["Entrepreneur"] = {
		Rarity = "Epic",
		Cost = 200,
		Damage = 0,
		Range = 6,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Farm = {
			Income = 60,
		},
	},

	--[[ RARE ]]

	-- O alcance e o que ela vende: enxerga o caminho inteiro de onde esta.
	["Slingshot"] = {
		Rarity = "Rare",
		Cost = 150,
		Damage = 22,
		Range = 16,
		Cooldown = 1.4,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Bullet", Speed = 75 },
		RangeStats = {
			Increment = 1,
			Max = 20,
		},
	},

	--[[ COMMON ]]

	-- O golpe pesado e lento, contra o Slasher que e rapido e fraco.
	["Sword"] = {
		Rarity = "Common",
		Cost = 175,
		Damage = 35,
		Range = 4,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1
	},

	-- A unidade de entrada: continua custando 100 porque e o que o jogador compra
	-- na wave 1, mas o dano caiu de 20 para 9 -- 26,7 de DPS por 100 de caixa era
	-- o dobro do teto.
	["Slasher"] = {
		Rarity = "Common",
		Cost = 100,
		Damage = 9,
		Range = 5,
		Cooldown = 0.85,
		AttackType = "MultiShot",
		HitInterval = 0,
		Hits = 1
	},
}

return UnitStats
