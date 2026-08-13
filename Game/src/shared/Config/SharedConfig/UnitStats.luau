local UnitStats = {
	["Azure"] = {
		Cost = 250,
		Damage = 5,
		Range = 3,
		Cooldown = 2,
		AttackType = "MultiShot",
		HitInterval = 0.25,
		Hits = 4,


	},

	["Subspace Tripminer"] = {
		Cost = 350,
		Damage = 70,
		Range = 8,
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
			Max = 12,
		},
	},

	["Entrepreneur"] = {
		Cost = 200,
		Damage = 0,
		Range = 3,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Farm = {
			Income = 60,
		},
	},

	["Sword"] = {
		Cost = 175,
		Damage = 35,
		Range = 3,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1
	},

	["Slasher"] = {
		Cost = 100,
		Damage = 20,
		Range = 3,
		Cooldown = 0.75,
		AttackType = "MultiShot",
		HitInterval = 0,
		Hits = 1
	},

	["Slingshot"] = {
		Cost = 150,
		Damage = 20,
		Range = 14,
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

	["Rocket"] = {
		Cost = 500,
		Damage = 50,
		Range = 3,
		Cooldown = 2.5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Rocket", Speed = 55 },
		AOE = { Radius = 8 },

		RangeStats = {
			Increment = 1,
			Max = 20,
		},
	}
}

return UnitStats
