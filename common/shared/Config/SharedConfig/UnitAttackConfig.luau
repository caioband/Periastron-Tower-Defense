local UnitAttackConfig = {

	--[[
		AttackSequence: ordered list of attack steps that cycle on each attack.
		  Animation  - name of the Animation child on the unit model to play
		  HitTime    - seconds into the animation when the hit fires to the server
		              (set to 0 to fire immediately on swing start)
		  HitTimes   - list of instants, instead of `HitTime`, when the attack hits
		              more than once within the SAME animation
		  Duration   - the animation length, in seconds; only needed with `HitTimes`
		              (see below)
		The sequence loops back to step 1 after the last step.
		See docs/game/units.md.
	--]]

	--[=[
		`HitTimes` is an attack that hits several times **at its own instants**, not
		the `Hits`/`HitInterval` of `UnitStats`, which space hits evenly after the
		windup.

		They do not mix: with `HitTimes` on the step, the number of hits is the list
		length and the intervals are its differences; that unit's `HitTime`, `Hits`,
		and `HitInterval` are left out. `Hits` in `UnitStats` must still equal
		`#HitTimes`, because `GetDPS` uses it for the number the card shows.

		The instants are the animation's `Hit` markers, copied by hand, the same rule
		as the Archer's `HitTime` below and for the same reason: the server applies
		the damage and has no `AnimationTrack` to listen to. Move the marker, update
		this too.

		`Duration` is the animation length, so the server can **squeeze the hits
		along with the gesture**. The client already shrinks the animation when it
		does not fit the attack window (see `Unit:playAttackVisual`); without the same
		factor here, a unit sped up by a card would hit on the old timing while the
		model moves on the new one, and the last hit would land after the next attack
		started. With the window longer than the animation (the normal case), the
		factor is 1 and the instants are the list's.
	]=]

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


	--[[
		Written as `HitTimes` + `Duration`, not `HitTime`, for the same reason as the
		Frostione below: its cooldown is **shorter than the animation**. 1.1 s at
		level 0 and 0.75 s at max, against 1.25 s; `HitTime` is a fixed wait that
		only the client shrinks along with the track, so the shot would land later
		and later in the cycle as the unit got faster. With the list, both sides
		divide by the same factor (see `UnitService`'s `squeeze` and
		`Unit:playAttackVisual`'s `fit`).

		1.25 s is the `Attack` animation length.
	]]
	["Slingshot"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTimes = { 0.7 }, Duration = 1.25 },
		},
	},

	--[[
		1.3667 s is the frame of the `Hit` marker in the Archer's `Attack` animation
		(2.0833 s long): the instant the animator said the arrow leaves the bow.

		**The number is written here even though the marker exists**, instead of
		`HitTime = 0` for `Unit:playAttackVisual` to listen to the track. The server
		applies the damage (`UnitService:executeAttack`), reads this field as the
		windup, and has no `AnimationTrack` to listen to: with zero here, damage would
		land at the request while the model is still drawing the bow. The marker
		branch there is only a client fallback for units without `HitTime`.

		In short: the marker is the **source** of the number, and this field is the
		copy both sides obey. Move the marker, update this too.

		Written as `HitTimes` + `Duration`, not `HitTime`, for the same reason as the
		Slingshot above: at max level its cooldown (1.9 s) is shorter than the
		animation, and both sides must squeeze the shot along with the gesture.
	]]
	["Archer"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTimes = { 1.3667 }, Duration = 2.0833 },
		},
	},

	-- 1.017 s is the `Hit` marker of the Pyre's `Attack` animation (2.033 s long).
	-- Same rule as the Archer above: the marker is the source, this number the copy.
	-- `HitTime` is enough here: its cooldown never drops below the animation.
	["Pyre"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1.017 },
		},
	},

	--[=[
		Four hits in one animation, not four animations: the instants are the `Hit`
		markers of the Berserker's `Attack` (0.4333 s, 1.2667 s, 2.3833 s, and
		2.5667 s of a 2.9 s animation).

		The gaps between them are far from even (0.83 s, then 1.12 s, then 0.18 s),
		which is why the unit did not fit `Hits`/`HitInterval`: that spaces hits
		evenly, and the model's fight has its own rhythm. The last two almost touch
		on purpose: the quick pair that closes the combo. The `UnitStats` cooldown
		counts the whole animation plus the recovery, so the fourth hit falls well
		inside the attack window.
	]=]
	["Berserker"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTimes = { 0.4333, 1.2667, 2.3833, 2.5667 }, Duration = 2.9 },
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

	--[[
		1.05 s is the `Hit` marker of the Electro's `Attack` animation (1.6667 s long),
		with the same rule as the Archer above: the marker is the **source**, this
		field is the copy both sides obey, and the server applies the damage without
		an `AnimationTrack` to listen to.

		It matters more here, because for this unit the instant does not only decide
		when health drops: the chain lightning fires on the same line as the damage
		(`UnitService:executeAttack`), so this number is literally the frame the
		player sees the bolt. Move the marker, update this too, or the bolt fires
		with the model still raising its hand.
	]]
	["Electro"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1.05 },
		},
	},

	--[[
		1.1 s is the `Hit` marker of the Frostione's `Attack` animation (1.8333 s
		long). Same rule as the others: the marker is the source, this number is the
		copy both sides obey. The projectile leaves and the server applies damage on it.

		Written as `HitTimes` + `Duration`, not `HitTime`, because of the cooldown:
		it starts at 1 s, already below the animation, and drops to 0.48 s at max. `HitTime` is a fixed wait
		only the client shrinks with the track; both sides divide `HitTimes` by the
		same factor (see `UnitService`'s `squeeze` and `Unit:playAttackVisual`'s
		`fit`), so the shot still leaves on the marker frame with the animation
		squeezed.
	]]
	["Frostione"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTimes = { 1.1 }, Duration = 1.8333 },
		},
	},

	--[=[
		Meteor, Lighting, and Teleport, in sequence. `ChainSequence` turns on chaining:
		between the start of one step and the next the wait is `ChainDelay` (5 s), and
		the `UnitStats` cooldown only counts after the last step's animation
		(`UnitService:getAttackDelay`). `ChainDelay` never shortens an animation: if a
		step lasts longer, the wait is the step's `Duration`.

		`Combo` says which attack of `UnitStats[name].Combo` the step runs
		(`UnitService:executeCombo`). The times are the animations' markers, copied by
		hand as for the other units: `Meteor`'s `Hit` (1.7167 s), `Lighting`'s
		`HitInitial` and `HitEnd` (0.9167 s and 1.4167 s), and `Teleport`'s `Hit`
		(0.4167 s). Move a marker, update this too.
	]=]
	["Archmage"] = {
		ChainSequence = true,
		ChainDelay = 5,
		AttackSequence = {
			{ Animation = "Meteor", Combo = "Meteor", HitTime = 1.7167, Duration = 2.4167 },
			{ Animation = "Lighting", Combo = "Lightning", HitTime = 0.9167, HitEnd = 1.4167, Duration = 2.0333 },
			{ Animation = "Teleport", Combo = "Teleport", HitTime = 0.4167, Duration = 1.3667 },
		},
	},

		--[=[
		The Bonfire does not swing, it channels, so none of the steps above apply. It has
		its own fields instead:

		| Field | What it is |
		| --- | --- |
		| `BeamStages` | one stage per slice of the ramp: `At` is the ramp progress (0 to 1) where it begins, `Animation` loops on the model while it lasts, each loop a whole number of damage ticks, the count closest to its own length (its speed is fit to that), `Beam` is the model in `Assets.VFX` drawn between the unit and its target; a new stage starts on a tick |
		| `Charge` | the wind-up `Animation`, played once and slowed to last the whole `Beam.ChargeUpTime` (`UnitStats`), so it ends on the first tick |
		| `Tired` | the animation played when nothing is left in range, and `Duration`, how long the tower is locked |
		| `BeamAttachment` | the `Part` of the model holding the attachment the beam starts from, and the `Names` tried, in order |
		| `BeamEndOffset` | where on the enemy the beam ends, added to its pivot |

		`Tired.Duration` is the **source**, not a copy of the animation: it is a balance
		number, and the client plays the animation at whatever speed makes it last exactly
		that long. Change it freely; the art follows.

		The Tired lock is the whole animation: nothing fires until it ends, even with an
		enemy back in range.
	]=]
	["Bonfire"] = {
		BeamStages = {
			{ At = 0,    Animation = "Attack",  Beam = "FireBeam1" },
			{ At = 0.33, Animation = "Attack2", Beam = "FireBeam2" },
			{ At = 0.66, Animation = "Attack3", Beam = "MaxFireBeam" },
		},
		Charge = { Animation = "StartAttack" },
		Tired = { Animation = "Tired", Duration = 4 },
		BeamAttachment = {
			Part = "Right Arm",
			Names = { "BeamAttachment", "BeamAttatchment", "BeamPart" },
		},
		BeamTargetParts = { "Torso", "UpperTorso", "HumanoidRootPart" },
		BeamEndOffset = Vector3.zero,
	},

	["Vindicator"] = {
	AttackSequence = {
		{ Animation = "Attack", HitTimes = {  0.7667 }, Duration = 1.4167 },
	},
},

	--[[
		0.75 s is the `Hit` marker of the Volt's `Attack` animation (1.3333 s long).
		`HitTimes` + `Duration` for the Frostione's reason: the cooldown (0.7 s at
		level 0, 0.46 s at max) is already shorter than the animation, so both sides
		squeeze the instant along with the gesture.
	]]
	["Volt"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTimes = { 0.75 }, Duration = 1.3333 },
		},
	},


}

return UnitAttackConfig
