--[[
	Each unit's numbers.

	Two rules hold this table together, and they are worth checking before any change:

	1. Damage per second divided by cost. It decides whether a unit is worth
	   buying, and the cap is 15 per 100 cash. The rule exists because a Slasher
	   once sat at 26.7, almost three times the runner-up, and filling the map with
	   Slashers was the optimal play on every difficulty. Rarity is not a ladder
	   here: a Common can beat a Legendary per cash, and what separates units is
	   range and role (see each unit's note).

	2. Range as the axis of difference. When most units had range 3, placement did
	   not matter: every one of them had to hug the path. The bands are now short
	   (4 to 7), medium (10), and long (12 and up), and long range belongs to units
	   with no high single-target damage.

	DPS = Damage * Hits / Cooldown.

	`RangeStats` is how range grows with upgrades, in one of two shapes. The linear
	one is `{ Increment, Max }`: add `Increment` per level up to the cap. The other is
	`{ Levels = { ... } }`, one range per level (index = level + 1), for units whose
	range rises in uneven steps: the Sword stays at 4 until level 3 and only then goes
	to 5, which no fixed increment can express. With `Levels`, the `Range` above must
	be the first item of the list, since that is what the rest of the code reads as
	the level 0 range. `UnitUpgradeConfig:GetRange` does the math.

	`Class` is the unit type for weather effects: "Melee", "Ranged", "Magic",
	"Fire", "Ice", or "Electric" (the list lives in `WeatherConfig.ClassList`). It
	accepts a list when a unit has two types: `Class = {"Melee", "Fire"}`. This is
	the only place the class is written; `WeatherConfig` reads it.

	`Projectile` marks a unit that shoots instead of striking. Both sides read it
	(the client draws the flight, the server resolves who took damage), so it lives
	here and not in a screen config:

	| Field | What it is |
	| --- | --- |
	| `Asset` | the model name in `Assets.Projectiles` |
	| `Speed` | flight speed in studs per second |
	| `Subtype` | `"Piercing"` makes the arrow pass through; without it, the shot stops at the target |
	| `PierceWidth` | studs of slack around the hit line; without it, 2 |
	| `PierceFalloff` | how much damage the arrow loses per body pierced, from 0 to 1 |
	| `PierceRange` | how far the drawing continues after the shot; without it, 24 |

	**Piercing changes who the hit reaches, not how hard it hits.** A `Piercing` shot
	hits every enemy on the line from the unit to the end of its range, including
	those behind the target. `PierceWidth` is the only thing between "catches whoever
	the line grazes" and "clears the next lane over".

	`Slow`, `Stun`, `Burn`, `Bleed`, and `Frost` are what the hit **leaves** on the
	enemy besides damage. Today they come from the Electro (the shock jolt), the
	Frostione (frost stacks), the Pyre (burn), and the Slasher and Berserker (bleed):

	| Field | What it is |
	| --- | --- |
	| `Slow` | `{ Amount, Duration }`: `Amount` is the fraction of speed removed (0.3 is "walks 30% slower") |
	| `Stun` | `{ Duration }`: the enemy stops **completely** for that many seconds |
	| `Burn` | `{ Damage, Ticks, Interval }`: that many ticks of that much damage, every that many seconds. Does not stack: a hit on an enemy already burning neither adds damage nor refreshes the timer |
	| `Bleed` | `{ Damage, Ticks, Interval, Vulnerability }`: like `Burn`, with its own timer (bleeding and burning coexist on the same target) and without the fire card. `Vulnerability` is how much more **all** damage to the target is worth while it bleeds (1.3 is "+30%"), from any source; without the field, 1 |
	| `Frost` | `{ Slow, Duration, FreezeStacks, FreezeDuration, FreezeImmunity, Radius, MaxRadius }`: one stack per hit, counted **per unit**; with any stack the enemy is `Slow` slower, a unit's hit refreshes only its own stacks' timer, and `FreezeStacks` from the same unit freeze the enemy for `FreezeDuration` and reset every unit's count. Once thawed, it spends `FreezeImmunity` more seconds accepting no stacks. `Radius` (up to `MaxRadius` at max level) gives the same stack, without damage, to enemies around the target |

	`Slow` and `Stun` are not the same thing at different strengths: slow changes the
	enemy's speed, and stun takes it out of the movement loop. Both fit on the same hit
	(no current unit declares both), and because they are different things the stun
	can be this short: stopped is stopped, and a third of a second of it is a stretch
	of path the enemy did not walk.

	`MobService` runs them (`ApplySlow`, `StunMob`, `ApplyBurn`, `ApplyBleed`), since
	it owns enemy state; `UnitService:creditDamage` triggers them after the damage
	lands. The Chill Out and Fire Hazard round cards multiply exactly these numbers.

	`Chain` is the hit that **jumps** from enemy to enemy. It uses the target neither as
	an area nor as a line: the first is the aimed target, and from there it keeps
	jumping to the nearest enemy not yet touched, up to `Targets` enemies.

	| Field | What it is |
	| --- | --- |
	| `Targets` | how many enemies the bolt touches in total, counting the first |
	| `Radius` | studs a jump reaches **from each enemy**, not from the unit |

	`Radius` starting from each enemy is what separates a chain from an area: a
	4-stud jump follows the queue along the path and reaches well past the unit's
	range, while an area of the same size would only catch enemies bunched together.
	Whoever lines up enemies better gets more out of the unit, the same idea as
	`Piercing`, but without a straight line, so a path bend does not cut the hit in
	half.

	**There is no per-enemy falloff**, unlike `PierceFalloff`: the fourth enemy in the
	chain takes the same as the first. That is deliberate and expensive, so the price
	sits in `Targets` and `Cooldown`; that is where to adjust if the unit gets too
	strong, not in a falloff it does not have.

	`HitFalloff` is the same idea as the arrow's falloff, but between the **hits** of a
	single attack instead of between the targets of one hit: it is the loss from one
	hit to the **next**, not against full damage. With 0.1, the combo is worth 100%,
	90%, 81%, and 72.9%. It applies to any unit with several `Hits` (only the Berserker
	declares it today), regardless of how the hits are spaced (`HitInterval` or
	`HitTimes`). Compounded and floored at 1, like `PierceFalloff`; without the field,
	every hit in the cycle is worth the same.

	`PierceFalloff` is what keeps piercing from being free. It **compounds**: with
	0.1, the second enemy takes 90% of the first, the third 90% of the second. It
	never reaches zero on purpose (an arrow that pierced ten bodies still hurts a
	little), and the result is rounded with a floor of 1, so the end of the queue does
	not show a floating "0". Without the field, the arrow pierces without losing anything.

	See docs/game/units.md.
]]

local UnitStats = {
	--[[ COSMIC ]]

	--[=[
		Three attacks in sequence, and only then the cooldown: `Meteor`, `Lightning`,
		and `Teleport`, in the order of `UnitAttackConfig`'s `AttackSequence`, which
		turns chaining on with `ChainSequence`. Between the start of one step and the
		next, the wait is that config's `ChainDelay` (5s); `Cooldown` counts after the
		last step's animation. With no enemy in range, the sequence waits at the step
		where it stopped.

		`Damage` is the meteor's, and it is what the card shows. The lightning uses its
		own (`Combo.Lightning.Damage`), and both grow with the same upgrade, card, and
		charge multiplier (`UnitService:getDamage`).

		| Field | What it is |
		| --- | --- |
		| `Combo.Meteor` | `{ Damage, Radius, MaxRadius, FallTime, Height }`: spawns `Height` studs above the unit at the step's `HitTime`, falls in `FallTime` seconds to where the target was when the step began, and explodes in `Radius` (up to `MaxRadius` at max level) |
		| `Combo.Lightning` | `{ Damage, Interval, Width }`: a straight line to the end of range, locked toward the target at `HitTime`; anyone on it takes `Damage` every `Interval` seconds until the step's `HitEnd` |
		| `Combo.Teleport` | `{}`: the target goes back to the previous path node, or to the start if it has not passed the first (`MobService:TeleportMobBack`) |

		The card's DPS comes from `Damage / Cooldown` and counts neither the lightning
		nor the sequence: it is only a reference.
	]=]
	["Archmage"] = {
		Rarity = "Cosmic",
		Class = "Magic",
		Cost = 800,
		Damage = 120,
		Range = 15,
		Cooldown = 8,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Combo = {
			Meteor = { Damage = 120, Radius = 8, MaxRadius = 10, FallTime = 1, Height = 15 },
			Lightning = { Damage = 25, Interval = 0.1, Width = 2 },
			Teleport = {},
		},
	},

	--[[ LEGENDARY ]]

	-- The strongest in raw damage, with short range: four hits per cycle, but
	-- only against enemies that come close.
	["Azure"] = {
		Rarity = "Legendary",
		-- No `Class` on purpose: it has not been classified yet. So it only takes
		-- what weather does to `All` and falls under no per-type rule.

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

	--[=[
		The jumping bolt: one hit every 2.5s that touches four enemies and stops each
		of them in place for an instant.

		**It sells hit reach, not per-target damage.** 4 x 18 is 72 damage per cycle,
		or 28.8 DPS with a full chain: 8.2 per 100 cash, within rule 1's cap. Against a
		lone target it is 7.2 DPS, 2.1 per 100: there it is among the worst in the
		table, and that is correct, because alone it does none of what it does.

		On top of that comes the stun: 0.3s stopped in a 2.5s cycle at level 0 (12% of
		the path the four would walk), rising to 0.5s at max (20%). It leaves no slow:
		the enemy stops and then walks again at its usual pace.

		The numbers that matter are `Targets` and `Cooldown`, and `Stun.Duration` is
		what keeps it from being crowd control: raising the stun close to the whole
		cycle turns it into "the queue moves when the Electro lets it", which is a
		different unit. Real stopping belongs to Time Stop, which costs a card.

		**The cooldown is fixed; upgrades buy damage, range, and stun.** With no
		`CooldownMultiplier` in `UnitUpgradeConfig`, the 2.5s holds at every level, and
		the stun rises linearly:

		| Level | 0    | 1    | 2    | 3    | 4    | 5    |
		| Stun  | 0.30 | 0.34 | 0.38 | 0.42 | 0.46 | 0.50 |

		The 2.5s still fits the `Attack` animation, which lasts 1.67s.

		Medium range (10), like the Subspace Tripminer: it must reach the queue for the
		jump to have somewhere to start, but the jump is already what takes it farther;
		adding long range on top would be paying twice for the same thing.
	]=]
	["Electro"] = {
		Rarity = "Legendary",
		Class = "Electric",
		Cost = 350,
		Damage = 18,
		Range = 10,
		Cooldown = 2.5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,

		-- Four enemies in total (the target plus three jumps), with no damage loss
		-- between them. See `Chain` in the header.
		Chain = { Targets = 4, Radius = 8 },

		--[[
			The shock's jolt, and the only thing the hit leaves: each link in the chain
			stops completely for an instant and then walks again at its usual pace.

			The stun grows with upgrades: `Duration` at level 0 (0.3s) up to
			`MaxDuration` at max level (0.5s), linearly; see
			`UnitUpgradeConfig:GetStunDuration`. A unit without `MaxDuration` always
			stuns the same amount.

			**No `Slow` on purpose.** It is not a crowd-control unit, and the fields
			exist (see `Stun` and `Slow` in the header) precisely so the two are not
			confused: slow changes speed, stun takes the enemy out of the loop.
			`MobService:StunMob` runs it, with the same `StunnedUntil` as Time Stop.
		]]
		Stun = { Duration = 0.3, MaxDuration = 0.5 },

		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	--[[
		Area at long range: the explosion radius fits comfortably inside the range. At
		range 3 the unit exploded an area it could not see.

		It shares the long band (12) with the Slingshot and the Archer on purpose: all
		three reach the same distance and differ in what they do there. The Slingshot
		pokes cheaply, the Archer hits harder and slower, and this one explodes. Reread
		rule 2 at the top before changing the three together: range only
		differentiates while the bands stay distinct.
	]]
	["Rocket"] = {
		Rarity = "Epic",
		Class = "Ranged",
		Cost = 450,
		Damage = 50,
		Range = 12,
		Cooldown = 2.5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Rocket", Speed = 55 },
		AOE = { Radius = 2 },

		RangeStats = {
			Increment = 1,
			Max = 15,
		},
	},

	--[=[
		The four-beat combo: the only attack in the table whose hits are not spaced by
		`HitInterval`.

		The four hits come out at the `Hit` markers of the `Attack` animation
		(0.4333s, 1.2667s, 2.3833s, and 2.5667s), written in `UnitAttackConfig` as
		`HitTimes`. The gaps between them are uneven on purpose (0.83s, 1.12s, and
		0.18s), and the animation's choreography rules: the last two almost touch and
		are the quick pair that closes the combo. **`Hits = 4` here must keep matching
		the length of that list**: the damage code counts from the list, but the
		card's DPS comes from this number.

		**`Cooldown = 6` is the animation plus the recovery**: 2.9s of gesture and 3.1s
		idle after it. This table's cooldown always counted from the start of one attack
		to the start of the next, so "idle after the animation ends" is the sum of the
		two. There is no separate recovery field, and the 6s window is the same one
		`swingWindow` sends to the client to fit the animation. If the animation
		changes, 2.9 changes here and `Duration` changes there. `UnitUpgradeConfig`'s
		`Cooldowns` goes down to 4.8s at max level, and even there it leaves almost
		twice the animation.

		**Each hit is a radius-3 area, and each hits less than the one before**
		(`HitFalloff = 0.1`): 39, 35, 32, and 28 damage. The falloff is per hit, not
		per target (everyone in the second hit's area takes the same 35), and it keeps
		four areas in a row from being simply four times the hit: the combo is worth
		3.44 full hits, not 4.

		Radius 3 is smaller than its range (7) on purpose, and larger than the
		Rocket's (2): the Rocket explodes at range 12, and this one needs an enemy at 7
		to strike. The area is what the short range buys.

		**`Damage` in this table is per hit, not per cycle.** The four hits add up to
		134 damage, or 22.3 DPS: 5.6 per 100 cash against a single target, well below
		most of the table, and that is correct. It sits next to the Rocket (4.4), the
		other area Legendary, for the same reason: rule 1 measures a single target and
		not an area, so it charges both for something they do not sell. The number that
		matters for this unit is the group one: three enemies inside the radius make
		16.7 per 100, right at the cap of 15. It pays full price when it hits the whole
		cluster and is weak against a lone target.

		What it sells is not average DPS: it is 134 area damage packed into 2.9s and a
		3.1s window where it does nothing, so it clears whatever is bunched up and lets
		the queue behind pass. It is the short-range Legendary next to the Azure (both
		only hurt enemies that come close), and what separates them is rhythm and
		target: the Azure chips away at one enemy, and this one clears the whole
		cluster at once and stops.

		**Every hit leaves the target bleeding**: 4 damage per second, 5 ticks
		(`MobService:ApplyBleed`). Like the Slasher's, it **neither stacks nor
		refreshes**: of the combo's four hits only the first opens the wound, and the
		other three land on an enemy already bleeding and are worth only the hit's
		damage. That is 20 damage per target each cycle, ticking while the unit sits in
		its 3.1s recovery.

		The wound opens the target as much as the Slasher's (`Vulnerability = 1.3`):
		while the enemy bleeds, all damage to it is worth 30% more, from any source,
		including the combo's next hits and the bleed's own ticks. That is what makes
		the 5 seconds after the area pay off for the whole team, not only for this
		unit. A Slasher and a Berserker on the same target double nothing: whoever
		opened the wound first rules until the timer runs out.
	]=]
	["Berserker"] = {
		Rarity = "Legendary",
		Class = "Melee",
		Cost = 400,
		Damage = 39,
		Range = 7,
		Cooldown = 6,
		AttackType = "MultiShot",

		-- Unused on this unit: the gaps come from the differences in `HitTimes`
		-- (see `UnitAttackConfig`). It stays at 0 so the line does not lie.
		HitInterval = 0,
		Hits = 4,
		AOE = { Radius = 3 },
		HitFalloff = 0.1,
		Bleed = { Damage = 4, Ticks = 5, Interval = 1, Vulnerability = 1.3 },
		RangeStats = {
			Increment = 1,
			Max = 11,
		},
	},

		--[=[
		The channeled beam: 8 DPS at 0% ramp and 32 at 100% (`Damage` 2 every 0.25 s,
		times `MaxMultiplier` 4), against a 1,000 placement cost. Small, frequent ticks
		so it reads as continuous damage, like the Archmage's `Lightning`. The numbers
		are provisional.

		It fires only after `ChargeUpTime`. When nothing is left in range it plays
		`Tired` (`UnitAttackConfig`), cannot fire until that ends, and then charges up
		again from 0% ramp. A dead target replaced by another one in range keeps the ramp.

		Fire, so rain turns it off (see `WeatherConfig`), which sends it Tired.
	]=]

	
	["Bonfire"] = {
		Rarity = "Legendary",
		Class = "Fire",
		Cost = 1000,
		Damage = 2,
		Range = 10,
		Cooldown = 0.25,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Beam = {
			RampTime = 8,
			MaxRampTime = 6,
			StartMultiplier = 1,
			MaxMultiplier = 4,
			ChargeUpTime = 1,
		},
		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},



	--[[ EPIC ]]

	["Subspace Tripminer"] = {
		Rarity = "Epic",
		Class = "Magic",
		Cost = 350,
		-- The server rounds the damage it applies: at level 0 the mine deals 38.
		Damage = 37.5,
		Range = 10,
		-- The level 0 value; upgrades bring it down to 3s at max (see `UnitUpgradeConfig`).
		Cooldown = 5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Tripmine = {
			BaseLimit = 3,
			LimitPerUpgrade = 1,
			-- Cap on mines on the map: 3, 4, 5, then it stops at 6 on levels 3 to 5.
			MaxLimit = 6,
			TriggerRadius = 2.5,
			AOE = { Radius = 6 },

			--[[
				How long the mine spends in the air, from the end of the throw to the ground.

				It is match time, like everything else: sped up, it flies faster along
				with the rest. It is the only number in this table both sides use for the
				same thing: the server **arms the mine only when it lands**, and the
				client spends exactly this time drawing the arc. Changing it here moves
				both together; splitting them would have the mine exploding while the
				model is still in the air (or the reverse).
			]]
			ThrowTime = 0.35,

			--[[
				The mine's charge-up after landing.

				It arms as soon as it touches the ground, but explodes with only
				`StartDamage` of its damage (0.35 = 35%) and rises linearly to 100% over
				`Time` seconds. Stepped on at 2.5s, it deals 67.5%. Match time, like
				`ThrowTime`: at 3x it charges three times faster.
			]]
			Charge = {
				Time = 5,
				StartDamage = 0.35,
			},
		},
		RangeStats = {
			Increment = 1,
			Max = 12,
		},
	},

	--[[
		Single-target ice: the shot is the Slingshot's (no area), and what it sells is
		control, not damage. Each hit leaves a `Frost` stack; with any stack the enemy
		walks 30% slower, and on the fourth it freezes for 3s.

		Its DPS per cash is middling (rule 1): 12 every 1s is 12 DPS, or 8.9 per 100
		cash. The rest of the price is the freeze: fast shots close the four stacks
		in 3s, freeze for 3s, and the enemy still spends 2s immune before it can stack
		again. Close to a third of the time stopped, and never locked for good, however
		fast the unit gets.
	]]
	["Frostione"] = {
		Rarity = "Epic",
		Class = "Ice",
		Cost = 135,
		Damage = 12,
		Range = 10,
		Cooldown = 1,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "FrostioneProjectile", Speed = 60 },

		--[[
			The frost stacks (see `MobService:ApplyFrost`).

			Stacks are counted **per unit**: each Frostione has its own count on the
			enemy, and its hit refreshes only its own stacks' timer. `Duration` is how
			long they last without a new hit. `FreezeStacks` stacks from the same unit
			freeze the enemy for `FreezeDuration` seconds and reset every unit's count,
			and for `FreezeImmunity` more seconds after thawing it accepts no stacks:
			without that slack, the Frostione rebuilds the four and locks the same enemy
			forever once its cooldown gets short.

			`Slow` is the slow, a single one, while any Frostione has a stack on the
			enemy; the Chill Out card multiplies this number.

			`Radius` is the area around the target: every enemy in it gets a stack from
			the same unit, as if it had been shot, but without damage; the damage stays
			on the target only. It rises linearly to `MaxRadius` at max level
			(`UnitUpgradeConfig:GetFrostRadius`).
		]]
		Frost = {
			Slow = 0.3,
			Duration = 4,
			FreezeStacks = 4,
			FreezeDuration = 3,
			FreezeImmunity = 2,
			Radius = 2,
			MaxRadius = 4,
		},

		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	--[[
		The unit that does not attack: it pays cash at the end of each wave and makes
		the units around it earn more.

		Both grow with upgrades, along different paths. Income is a hand-written ladder
		(`Incomes`, in `UnitUpgradeConfig`) that more than doubles from level 0 to 5
		(60 to 225), with a 50% jump on the last step against the others' 25%: its max
		level is the table's only economy investment. The aura rises 5 points per level
		and **stops at 30%** (`Aura.MaxBonus`), so levels 4 and 5 give the same bonus,
		and what the last one buys is income and radius.

		The radius is `Range` (see `Aura` below), and it goes from 4 to 8 in uneven
		steps. It is the only unit whose range doubles with upgrades, because here
		range is not aim: it is how many towers fit under the aura.
	]]
	["Entrepreneur"] = {
		Rarity = "Epic",
		Class = "Melee",
		Cost = 200,
		Damage = 0,
		Range = 4,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Farm = {
			-- The level 0 value; the whole ladder is `Incomes` in `UnitUpgradeConfig`, and
			-- `GetIncome` does the math for both sides.
			Income = 60,

			--[[
				The aura: every allied unit inside the Entrepreneur's range gets `Bonus`
				more cash on top of what it earns from damage and kills. It applies to
				any owner (a neighbor's tower also earns more near my farm), and the
				payout always goes to the tower's owner.

				The radius is not written here on purpose: it is the `Range` above, read
				through `UnitUpgradeConfig:GetRange`, which is exactly the circle the
				player sees when selecting the farm. Changing `Range` moves the aura and
				the circle together, and neither can lie about the other.

				`Bonus` is an additive fraction: 0.15 is "+15%", and two farms covering
				the same tower give 30%. `BonusPerUpgrade` is what each level adds
				(added, not multiplied like income), because a percentage that grows in
				round steps (15, 20, 25...) is what the card can show without decimals.

				`UnitUpgradeConfig:GetAuraBonus` does the math, so the server and the
				card never disagree.
			]]
			Aura = {
				Bonus = 0.10,
				BonusPerUpgrade = 0.05,

				--[[
					The aura cap, and why levels 4 and 5 give the same 30%.

					Without it the math would continue linearly to 35% at max, and two
					adjacent farms would stack 70% on each tower. The bonus adds up across
					farms (see `Bonus` above), so what limits stacking is this number, not
					the number of farms. The last upgrade is not empty because of it: it
					buys the income jump (150 -> 225) and one more stud of radius.
				]]
				MaxBonus = 0.30,
			},
		},
		RangeStats = {
			Levels = { 4, 5, 5, 6, 7, 8 },
		},
	},

	--[[ RARE ]]

	--[[
		The cheap long-range poker: 10 damage every 1.1 s, 9.1 DPS, 6.1 per 100 cash.
		What it sells is constant poking from afar, and at max level the cycle drops
		to 0.75 s and the damage almost triples (28).

		**The cooldown is no longer shorter than the shot's windup** (0.7 s in
		`UnitAttackConfig`) at the first levels, but it gets close again at the top,
		so its step is still written as `HitTimes` + `Duration` instead of `HitTime`:
		with a 0.75 s cycle against a 1.25 s animation, both ends compress the instant
		along with the gesture. See its comment there.

		Range rises in steps up to 16 (`RangeStats.Levels`): rule 2's long band, shared
		with the Archer (also 12 at base, 17 at max).
	]]
	["Slingshot"] = {
		Rarity = "Rare",
		Class = "Ranged",
		Cost = 150,
		Damage = 10,
		Range = 12,
		Cooldown = 1.1,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Bullet", Speed = 75 },
		RangeStats = {
			Levels = { 12, 13, 14, 15, 15, 16 },
		},
	},

	--[[
		The Slingshot with a different model: same family (single-shot Ranged with a
		`Bullet` projectile), but the bow draws slower and hits harder.

		**The numbers are provisional** and exist so the unit enters play coherent, not
		to settle balance. Two things in them are not guesses and are worth knowing
		before changing them:

		- **From level 4 up the cooldown is shorter than the `Attack` animation**
		  (2.083s): `UnitUpgradeConfig`'s `Cooldowns` goes from 3s down to 1.9s at max
		  level. `Unit:playAttackVisual` plays the track faster to fit the window and
		  restarts it on each attack, so the gesture still shows whole, and the shot
		  is squeezed with it on both sides (`HitTimes` + `Duration` in
		  `UnitAttackConfig`).
		- 16 damage in 3s is 5.3 DPS, or 4.3 per 100 cash: below the Slingshot (6.1),
		  the other shooting Rare, and well below rule 1's cap of 15. At max level it
		  is 23.7 DPS.

		**The arrow pierces** (`Projectile.Subtype = "Piercing"`), and that is what
		separates the Archer from the Slingshot now that both have the same range: the
		shot stops being worth per target and becomes worth per **queue**. Against a
		lone enemy it is still the same 5.3 DPS; against the line walking single file
		down the path, it charges every enemy on the line, so where the unit is placed
		matters more than its number.

		`PierceFalloff = 0.1` is the brake on that. Each body pierced takes 10% off
		what the previous one took, so the 16 damage comes out 16, 14, 13, 12, 10, 9,
		9, 8: eight enemies in line add up to 91 damage, not the 128 of eight full
		shots. Without the falloff, a well-placed Archer on a map that lines enemies up
		would break rule 1's cap of 15 per 100 cash on its own; with it, lining up more
		enemies stays worthwhile and stops scaling linearly.

		Against a single target it grows a lot with levels (damage almost triples,
		16 to 45, while the cycle drops from 3s to 1.9s), and against a queue it
		scales with both.

		If it still becomes the obvious pick on some map, the knobs to turn are
		`Damage` and `PierceFalloff`, in that order: the subtype is the unit's
		identity, not a balance number.
	]]
	["Archer"] = {
		Rarity = "Rare",
		Class = "Ranged",
		Cost = 125,
		Damage = 16,
		Range = 12,
		Cooldown = 3,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Bullet", Speed = 75, Subtype = "Piercing", PierceFalloff = 0.1 },
		RangeStats = {
			Increment = 1,
			Max = 17,
		},
	},

	--[[
		The first `Fire` unit: a single shot with a projectile, and the hit leaves the
		target burning: 3 damage every 0.75s for 9s, 36 in total, through
		`MobService:ApplyBurn`.

		**Burn does not stack**, whoever applies it: a hit on an enemy already burning
		only deals the shot's damage, without adding ticks or refreshing the timer. So
		its value is in **spreading** fire, not in hammering the same target.

		**The cost and range numbers are provisional.** The cooldown is level 0's
		(2.58s); upgrades bring it down to 2.1s, just above the `Attack` animation
		(2.033s), and not below (see `UnitUpgradeConfig`). 15 damage in 2.58s is 5.8
		DPS from the shot, and with the full burn (4 DPS) it reaches 9.8: 6.5 per 100
		cash, below rule 1's cap of 15.

		The burn does not grow with upgrades, weather, or damage cards: only the Fire
		Hazard card changes it.
	]]
	["Pyre"] = {
		Rarity = "Rare",
		Class = "Fire",
		Cost = 150,
		Damage = 15,
		Range = 10,
		Cooldown = 2.58,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "PyreProjectile", Speed = 60 },

		--[[
			The shot bursts where it lands: anyone within 2 studs of the aim point takes
			full damage **and** catches fire, because the burn comes from `creditDamage`,
			which runs once per target hit.

			That is what separates the Pyre from the Rocket, which has the same radius-2
			area and leaves nothing: here the area is not the hit, it is what spreads the
			burn. In a tight queue one shot lights several enemies, and each burns on its
			own for the 9s. `BurningUntil` is per enemy, and the no-stacking rule still
			applies per enemy, not per shot.

			No per-target falloff, on purpose: the area is small (2 against the
			tripmine's 6) and the cooldown is long. If it needs reining in, the place is
			the radius.
		]]
		AOE = { Radius = 2 },

		Burn = { Damage = 3, Ticks = 12, Interval = 0.75 },
		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	--[[ COMMON ]]

	--[[
		The heavy, slow hit, against the Slasher's fast, weak one.

		35 damage every 2 s is 17.5 DPS, or 8.8 per 100 cash: the better value of the
		two Commons, and the price is range: it only reaches 4, and upgrades only take
		it to 5 (`RangeStats.Levels`), from level 3 up. It is the unit that has to hug
		the path more than any other.
	]]
	["Sword"] = {
		Rarity = "Common",
		Class = "Melee",
		Cost = 200,
		Damage = 35,
		Range = 4,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		RangeStats = {
			Levels = { 4, 4, 4, 5, 5, 5 },
		},
	},

	--[[
		The starter unit: 90 cash, the lowest price in the table, because it is what
		the player buys on wave 1.

		5 damage every 0.85 s is 5.9 DPS, or 6.5 per 100 cash: far from rule 1's cap of
		15, and **above** the Slingshot (6.1) and the Archer (4.3), which are Rare and
		cost more. Rarity is not a ladder (see rule 1 at the top), and what separates
		the three is still range: it has to hug the path to strike, and they do not.

		Range rises in steps up to 6 (`RangeStats.Levels`) and stops there on purpose:
		in the medium band it would reach as far as the shooting units without having
		stopped being melee in any way.
	]]
	--[[
		Each hit leaves the target bleeding: 1 damage per second, 5 ticks. Like burn,
		it **neither stacks nor refreshes**: a hit on an enemy already bleeding only
		deals the hit's damage. Upgrades, weather, and cards do not change the bleed.

		The wound also opens the target: while it bleeds, all damage to it is worth 30%
		more (`Vulnerability`), from any source. That is worth far more to the team
		than to the unit (the 5 ticks of 1 are pocket change next to 30% of what the
		other towers pour into the same target), and it is on purpose: the Slasher is
		the starter unit, and what it does best is mark the target for the others.
	]]
	["Slasher"] = {
		Rarity = "Common",
		Class = "Melee",
		Cost = 90,
		Damage = 5,
		Range = 4,
		Cooldown = 0.85,
		AttackType = "MultiShot",
		HitInterval = 0,
		Hits = 1,
		Bleed = { Damage = 1, Ticks = 5, Interval = 1, Vulnerability = 1.3 },
		RangeStats = {
			Levels = { 4, 5, 5, 5, 6, 6 },
		},
	},

	--[=[
		Deals no damage and attacks nobody: it keeps a ring of frost on the ground
		around itself (`SlowAura.Ring`, a Model in `Assets.VFX.Rings`), and every enemy
		inside it walks slower.

		The slow per level is `Slows` in `UnitUpgradeConfig`: 12% when placed, 30% at
		max, in uneven steps (see the table there).

		The radius is `Range`, read through `UnitUpgradeConfig:GetRange`, which is the
		circle the player sees when selecting it, weather and cards included; the same
		rule as the Entrepreneur's aura.

		Rings do not stack, with each other or with any other slow: the enemy walks at the
		strongest one (`MobService:SetAuraSlows`), and back at its own pace the moment it
		leaves the ring. `Cooldown` is inert: nothing here runs on a cycle.

		Range rises in uneven steps (4 to 6), so it is a `RangeStats.Levels` ladder.
		Numbers from the 2026-10-07 balance sheet.
	]=]
	["Cryomancer"] = {
		Rarity = "Common",
		Class = "Ice",
		Cost = 165,
		Damage = 0,
		Range = 4,
		Cooldown = 1,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		SlowAura = { Ring = "Frigid" },
		RangeStats = {
			Levels = { 4, 4.3, 4.7, 5, 5.4, 6 },
		},
	},
}

return UnitStats
