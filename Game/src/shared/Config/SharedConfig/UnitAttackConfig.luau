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
