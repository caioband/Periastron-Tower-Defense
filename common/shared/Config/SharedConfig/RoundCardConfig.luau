--[[
	The round card shop: `StarterGui.RoundCardShop`.

	Every few waves the shop button slides in from the right and offers **three
	cards drawn** from this table. A bought card costs round cash (`MobService`'s
	`roundcash`, not the profile's `Cash`), goes to the player's hotbar, and is worth
	**one use**: clicking it fires the effect and the card disappears.

	These are match cards, not deck cards: they do not go through the profile, do not
	survive the round, and have nothing to do with `DeckConfig`. They change the
	room's state (enemies, the clock, the sky), so **the server runs the effect**
	(`CardShopService`); this only declares which effect a card triggers and with
	what numbers.

	It is shared because both sides need it: the client reads title, description,
	price, and art to draw the card; the server reads the same `Id` to know what a
	purchase authorizes and what a use runs. Drawing and charging happen **only on
	the server**.

	See docs/game/round-cards.md and docs/game/round-card-shop.md.
]]

local RoundCardConfig = {}

--[[ WHERE THE SHOP LIVES IN THE GUI ]]

--[[
	The authored names, in one place. The controller looks nothing up by hand-written
	path: renaming a piece in Studio is one line here.
]]
RoundCardConfig.Gui = {
	ScreenGui = "RoundCardShop",

	-- The button at the screen edge, and the `ImageButton` inside it.
	Frame = "RCSFrame",
	Button = "CardShop",

	-- The full-screen backdrop and the row of cards inside it.
	Background = "Background",
	Row = "RoundCardShop",

	-- A card's template: the wrapper enters the row's `UIListLayout`, and the
	-- template is the card itself (the part that animates).
	Wrapper = "CardWrapper",
	Card = "CardTemplate",

	Title = "CardTitle",
	Description = "CardDescription",

	-- The price lives on its own plate, which leaves the card when it goes to the
	-- hotbar: in the hand the card is already paid for.
	Price = "PriceLabel",
	PriceLabel = "CardPrice",
}

--[[ WHEN THE SHOP APPEARS ]]

--[[
	Every how many waves the shop is offered, per difficulty.

	The number is the interval, not the wave: with 4, the shop appears on waves 4,
	8, 12... Longer difficulties space it more: Nightmare has 35 waves against Easy's
	15, and a fixed interval would give the top match more than twice the cards.

	A preset without an entry falls back to `DefaultInterval`.
]]
RoundCardConfig.Intervals = {
	Easy = 4,
	Medium = 4,
	Hard = 5,
	Impossible = 6,
	Nightmare = 6,
	Endless = 3,
}

RoundCardConfig.DefaultInterval = 4

--- How many cards the shop shows per offer.
RoundCardConfig.DrawCount = 3

--[[
	The `Visual` keyframe marker's **parameters**, not marker names. The animation
	carries a single marker (whatever the card's `Visual.Marker` says), and its
	parameter says which half of the gesture fires.

	They live here because both sides need the same word: the client compares it
	with what the marker delivers, and the server looks for `VFX` in the animation
	when checking `EffectDelay`.
]]
RoundCardConfig.Markers = {
	Sound = "Sound",
	VFX = "VFX",
}

--[[ HOW A CARD IS USED ]]

--[=[
	A card's use type: what happens between clicking it and the effect.

	| Type | Clicking in the hotbar... |
	| --- | --- |
	| `Instant` | is the use. The card disappears and the effect starts |
	| `Unit` | asks for **a unit**: the next map click picks the tower |
	| `Area` | asks for **a spot**: a ring follows the pointer and a click confirms |
	| `Move` | asks for both, in order: the unit and where it goes |

	`Move` is not a fourth concept, it is the two before in sequence: what Zippers
	needs (which tower, and where to), written as its own type so the card does not
	invent a second click outside the flow.

	A card without `Use` is `Instant`, so the original cards keep working without a
	field that changes nothing.

	**The server checks.** The client picks the target and sends it with the use;
	`CardShopService` refuses a target that does not match the card's type (a unit
	that does not exist, a spot too far away, a missing target). The type here is
	what the **screen** needs to ask for the right thing.
]=]
RoundCardConfig.Use = {
	Instant = "Instant",
	Unit = "Unit",
	Area = "Area",
	Move = "Move",
	Place = "Place",

}

--[=[
	Aiming: what the player sees while the card waits for a target.

	The ring is the same model placement already uses for a tower's range
	(`Assets.UI.AOE.Ring`), on purpose: the player already learned that drawing means
	"this area".

	**There is no panel or cancel button.** The card in the hotbar says aiming is
	open: it grows and dims its neighbors, like an equipped unit card. Giving up is
	clicking it again (the same as dropping a unit), or Esc on PC.

	Colors separate what aiming asks for: green is "pick a spot" and yellow is "pick
	a tower". Red is the area ring's third state: "not here", where the spot under the
	cursor touches an area **this same player** already drew and a click does not
	count. It is the same green/red pair as a tower's placement ghost, a sentence the
	player already reads.

	Zippers' second step (tower chosen, destination missing) has no color here
	because it is not aiming: it is full placement, drawn by
	`UnitPlacementController:visualize`, with the tower's own ghost in green or red
	and its range ring. See `_beginMovePlacement`.

	`Unit`'s yellow is the highlight on the tower under the pointer, on both paths: a
	card that changes no stat (Zippers) is painted by `RoundCardShopController`
	itself, and one that does is painted by `WeatherFeedbackController` along with
	the icons of what it will feel. One highlight on the tower, or the two colors
	would fight on the same model. That is why the color lives here and both read it.
]=]
RoundCardConfig.Targeting = {
	RingAsset = { "AOE", "Ring" },

	-- The part inside the ring whose diameter is the ruler for scaling. The name came
	-- that way from Studio, and it is the same one `UnitPlacementController` looks for.
	RingPart = "Renge",

	-- The ring radius for an area card that declares none, in studs.
	DefaultRadius = 6,

	--[[
		How far from the map center a target may be.

		The same cap as `PlaceUnit`, for the same reason: a tampered client sends any
		position it wants, and an area effect centered ten thousand studs away is not a
		play, it is garbage in the room's state.
	]]
	MaxDistance = 2000,

	Colors = {
		Area = Color3.fromRGB(120, 235, 140),
		Unit = Color3.fromRGB(255, 215, 60),

		-- The area ring over another area of the same player: not here.
		Blocked = Color3.fromRGB(235, 85, 85),
	},
}

--[=[
	The burst a tower emits when a single-target card lands on it.

	The name of an asset in `Assets.VFX` (an Attachment of burst emitters), attached
	to the tower's `HumanoidRootPart` and emitted by `VFXController`. It is the "got
	it": aiming already said which tower, and with nothing happening at the moment
	of use, the card leaves the hand and the player does not know whether it worked.

	The server fires it, so everyone in the room sees the burst on the same tower,
	like lightning and aura money.
]=]
RoundCardConfig.AppliedVFX = "EffectUnitAppliedVFX"

--[=[
	The ring that **stays** on the ground after an area card is used.

	Not the aiming one. The aiming ring is placement's neutral circle, which only
	says "this area" while the player chooses; this is the card's art, one Model per
	effect in `Assets.VFX.Rings` (the Robux gold, the Winds wind, the Celestial blue).
	It appears where the player clicked and lives exactly as long as the effect:
	until the end of the round for zone staffs, the immunity seconds for the Staff of
	Healing.

	`Path` is the path from `ReplicatedStorage.Shared.Assets`. `Default` is the ring
	for cards without their own `Ring`, so a new area card appears on the ground
	without new art. `PartSuffix` is how the radius ruler is found inside the Model:
	`Celestial` has a `Celestial_Ring`, and **that** Part's diameter drives the scale.

	The ruler is a named Part, not the Model's box, on purpose: a VFX Model has
	emitters and attachments spread around, and measuring the whole box would shrink
	the ring just because someone dragged a spark outside it.
]=]
RoundCardConfig.Rings = {
	Path = { "VFX", "Rings" },
	Default = "Base",
	PartSuffix = "_Ring",

	-- The folder the client creates in the Workspace to hold drawn rings. See
	-- `CardModifierController:_ringContainer`.
	Container = "RoundCardRings",

	-- How long the ring takes to grow to its size, in real seconds.
	Grow = 0.35,
}

--[[ ANIMATION ]]

--[[
	Screen timings, in real seconds.

	Nothing here goes through `GameClock`: it is time for the player to read and
	choose, not match pace. Speeding the game to 2x must not shorten reading three
	cards.
]]
RoundCardConfig.Animation = {
	--[[
		The button slides in from the right: it starts at `HiddenX` (off screen) and
		runs to the X the designer authored on `RCSFrame`. `Circular` arrives slowly
		at the end, which gives the snap against the edge.
	]]
	HiddenX = 1,
	SlideIn = 0.5,
	SlideOut = 0.35,
	SlideEasing = Enum.EasingStyle.Circular,

	--[[
		The button's sway while the offer is up and nobody clicked it.

		It rises `IdleLift` pixels and swings between `+IdleSwing` and `-IdleSwing`
		degrees, taking `IdleSwingTime` for each pass. It is a lure: the offer lasts a
		few waves and the button sits at the screen edge, easy to miss.

		A click stops the sway and returns the button to its authored state in
		`IdleReturn` seconds. The return target is read from `CardShop` at bind, not
		written here, so rotating or moving the button in Studio does not leave it
		crooked after the first shop.
	]]
	IdleSwing = 10,
	IdleSwingTime = 0.9,
	IdleLift = 6,
	IdleLiftTime = 0.35,
	IdleReturn = 0.2,
	IdleEasing = Enum.EasingStyle.Sine,

	-- The full-screen backdrop. The target is `Background`'s authored transparency,
	-- not a value written here.
	BackgroundFade = 0.3,

	--[[
		The card drops from above: `DropOffset` is in the card's own heights, so
		resizing it in Studio does not make the drop too short.

		Two halves, in order: first the card descends and its **image** appears
		(`CardDrop`); only when that ends does the content (title, description, price,
		outlines, shadow) fade from transparent to its authored value (`CardReveal`).
		Revealing everything together would make the text float before the card exists
		behind it.
	]]
	DropOffset = 1.25,
	CardDrop = 0.4,
	CardReveal = 0.3,

	--- The gap between one card's start and the next.
	CardStagger = 0.5,

	--[[
		Leaving without buying: a click outside the cards plays the entrance backward:
		the content goes first (`CardReveal`) and only then the card rises with its
		image fading (`CardDrop`).

		The exit stagger is much shorter than the entrance's `CardStagger` because there
		is nothing to read: the player already decided against all three, and the offer
		stays up on the edge button.
	]]
	CardExitStagger = 0.08,
	BackgroundFadeOut = 0.25,

	CardEasing = Enum.EasingStyle.Quad,
	CardDirection = Enum.EasingDirection.Out,
}

--[[
	The size the wrapper takes when it enters the hotbar.

	The only thing a round card must get right in the hand to live with unit cards:
	its template comes from the shop, where the card is large, and a hotbar slot is
	much smaller. From then on `Components/Card` handles it (position, arc, scale,
	and queue order), like the others.
]]
RoundCardConfig.DeckCardSize = UDim2.fromScale(0.128, 1.07)

--[[ THE CARDS ]]

--[[
	The catalog.

	Each entry is a card that can be drawn:

	| Field | What it is |
	| --- | --- |
	| `Id` | the key, and what crosses the network; the rest is screen text |
	| `Title` / `Description` | what the player reads on the card |
	| `Price` | how much round cash (`roundcash`) it costs |
	| `Weight` | the draw weight; without it, 1 |
	| `Use` | what the card asks for before acting (see `RoundCardConfig.Use`); without it, `Instant` |
	| `Effect` | the effect's name in `CardShopService.Effects` |
	| `Params` | the numbers the effect reads |
	| `Image` | the card art; without it, the art authored on `CardTemplate` |
	| `Ring` | the ring left on the ground by area cards (see `RoundCardConfig.Rings`) |
	| `Visual` | what the **character** does when using the card; without it, nothing |

	`Visual` is an animation and what it fires:

	| Field | What it is |
	| --- | --- |
	| `Animation` | the `AnimationId` played on the user's character |
	| `Marker` | the keyframe marker name the animation carries |
	| `Sound` | the `Sound` in `SoundService` the `"Sound"` marker plays |
	| `VFX` | the asset in `Assets.VFX` the `"VFX"` marker emits |
	| `EffectDelay` | the second in the animation the **effect** starts (the `"VFX"` marker's instant) |
	| `SoundDelay` | the second in the animation the **sound** starts (the `"Sound"` marker's instant) |

	**The animation keeps time, not a `task.delay`.** The same marker fires both, and
	its **parameter** separates them: `"Sound"` plays the sound, `"VFX"` emits the
	particles. Re-animating the card in Moon Animator re-marks both without going
	through here.

	`EffectDelay` and `SoundDelay` are the necessary exceptions: **they apply to
	whoever is not playing the animation**. The marker only reaches whoever loaded the
	track; the server listens to no marker, and neither does a client *watching*
	another player's gesture. Both numbers copy the `"VFX"` and `"Sound"` marker
	instants, which is how the freeze lands with the burst (on the server) and how
	particles and sound come out on the same frame on everyone's screen.

	Copies go stale, so `CardShopService` checks both against the real animation on
	start and warns if they drift.

	A new card is an entry here **plus** a function in `CardShopService.Effects` named
	after its `Effect`. The draw only offers cards with an effect on the other side: an
	entry with an unknown `Effect` is dropped with a warning instead of becoming a
	card the player pays for that does nothing.

	## Most cards use the same effect

	Almost everything a round card does is **leave a rule on the field**, and that
	rule has its own grammar: `CardModifier`. So most of the catalog has
	`Effect = "Modifier"` and describes in `Params.Modifiers` the records it creates;
	`CardModifierService` keeps, prunes, and replicates them.

	Inside `Params`:

	| Field | What it is |
	| --- | --- |
	| `Modifiers` | the list of `CardModifier` records the card creates |
	| `Duration` | how many match seconds they last; without it, until the end of the round |
	| `Radius` | the ring radius, on area cards, and the effect's reach inside it |

	Two record fields are filled **on use**, not here, because they depend on the
	target the player picked:

	- `Zone = true` becomes `{ Position = <where they clicked>, Radius = Params.Radius }`;
	- `Target = true` becomes `UnitId = <the tower they picked>`.

	**A card without `Duration` lasts the whole round.** Not an oversight: a field
	buff bought with round cash is a build decision, and a short timer would turn
	every rule card into a worse Bloxy Cola. Timers exist where they are the card's
	point: the drinks, which double a number for ten seconds.
]]
RoundCardConfig.Cards = {
	--[[ ============================ THE ORIGINALS ============================ ]]

	{
		Id = "TimeStop",
		Title = "TIME STOP",
		Description = "Freezes every enemy for 4 seconds",
		Price = 350,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Effect = "TimeStop",
		Params = { Duration = 4 },
		Visual = {
			Animation = "rbxassetid://76323247675563",
			Marker = "TimeStop",
			Sound = "TimeStopSFX",
			VFX = "PlayerStopTime",

			-- The markers are at 0.917 s (`VFX`) and 0.75 s (`Sound`) of the animation,
			-- which is 1.317 s long.
			EffectDelay = 0.917,
			SoundDelay = 0.75,
		},
	},

	{
		Id = "TimeAcceleration",
		Title = "TIME ACCELERATION",
		Description = "Game speed goes to 3x for 15 seconds",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://80964149470422",
		Effect = "TimeAcceleration",
		Params = { Scale = 3, Duration = 15 },
	},

	--[[
		An umbrella for the wave in progress, not a cancellation of the weather.

		A weather lasts several waves (`RoundConfig.Duration`), and the card clears only
		the current one: bought on the first wave of a three-wave blizzard, the blizzard
		returns on the second. Clearing all three takes three cards, which is what
		separates this 300 card from one that turned the whole weather off.

		Bought on the weather's last wave, it ends there and does not return; with a
		clear sky it does nothing, since there is no weather wave to skip.

		No `Params`: the only wave it knows is the current one.
	]]
	{
		Id = "WeatherReport",
		Title = "WEATHER REPORT",
		Description = "Clears the weather for the current wave only",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://78191968209780",
		Effect = "WeatherReport",
	},

	--[[ ============================== INSTANT ============================== ]]

	--[[
		Cash in hand. The only card that pays more than it costs, and the price is the
		brake: 400 for 500 is 100 profit for an offer slot and a hotbar use. Changing
		both numbers together keeps the card a choice instead of a tax on players who
		skip it.
	]]
	{
		Id = "MoneyBag",
		Title = "MONEY BAG",
		Description = "Gives you 500 cash",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://131268059067009",
		Effect = "GrantCash",
		Params = { Amount = 500 },
	},

	--[[
		The bouquet for the whole room: 15% attack speed on every unit, for 30 match
		seconds.

		The timer puts it in the drinks' family, not the staffs': it is a window to push
		through a hard wave, not a build decision. Like every card with `Duration`, it
		leaves the draw after use and only returns at the next shop opening (see
		`CardShopService:_isTemporary`).
	]]
	{
		Id = "Trumpet",
		Title = "TRUMPET",
		Description = "Every unit attacks 15% faster for 30 seconds",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://74040128583244",
		Effect = "Modifier",
		Params = {
			Duration = 30,
			Modifiers = {
				{ Stats = { AttackSpeed = 1.15 } },
			},
		},
	},

	--[[
		Overcharge's deal: 25% more for Electric, 11% less for everyone else. The two
		sides are separate records because `Exclude` makes the second catch exactly
		whoever the first did not, including a unit with no class, which takes the cut
		too.
	]]
	{
		Id = "Overcharge",
		Title = "OVERCHARGE",
		Description = "Electric units deal +25% damage, every other unit deals -11%",
		Price = 350,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://120364507379076",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Electric" }, Stats = { Damage = 1.25 } },
				{ Classes = { "Electric" }, Exclude = true, Stats = { Damage = 0.89 } },
			},
		},
	},

	--[[
		"Cooldown +1.15x" in the original request means attack speed, not recharge: the
		card promises three buffs together, and a 15% longer recharge would be a nerf
		hidden between two buffs. `AttackSpeed = 1.15` is what the player reads as
		"recharges faster" on the card icon; see the `Feedback` comment in `WeatherConfig`.
	]]
	{
		Id = "WattsUp",
		Title = "WATT'S UP?",
		Description = "Electric units get +15% damage, range and attack speed",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://101249133973372",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Electric" }, Stats = { Damage = 1.15, Range = 1.15, AttackSpeed = 1.15 } },
			},
		},
	},

	{
		Id = "PunchLine",
		Title = "PUNCH LINE",
		Description = "Melee units deal +25% damage, but attack 25% slower",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://125434264829869",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Melee" }, Stats = { Damage = 1.25, AttackSpeed = 0.75 } },
			},
		},
	},

	{
		Id = "Axecellent",
		Title = "AXECELLENT!",
		Description = "Melee units attack 15% faster, ranged units 15% slower",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://132735756087334",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Melee" }, Stats = { AttackSpeed = 1.15 } },
				{ Classes = { "Ranged" }, Stats = { AttackSpeed = 0.85 } },
			},
		},
	},

	--[[
		Melee also hits whoever is behind the target. It is `Flags`, not a multiplier:
		there is no "cleave 30% of the one behind"; the swing reaches the line or it
		does not. `UnitService:executeAttack` reads it, and the bodies per swing are in
		`Params`.
	]]
	{
		Id = "CleaveItToMe",
		Title = "CLEAVE IT TO ME!",
		Description = "Melee units also hit the enemy behind their target",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://134174928139643",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				--[[
					The cleave numbers live in the `Flags` entry itself, not a
					`UnitService` constant: the card chooses how many bodies a cleave hits,
					and a second cleave card with its own numbers should not need combat
					changes.

					Two bodies per swing, and the second takes 30% less. The falloff exists
					for the same reason as the Archer's arrow (see `UnitStats`): hitting two
					for free would double melee DPS on any map that lines enemies up.

					`Width` is the slack of the line from the unit through the target, the
					same idea as `PierceWidth`, a little wider because a melee swing is an
					arc, not an arrow.
				]]
				{ Classes = { "Melee" }, Flags = { Cleave = { Targets = 2, Falloff = 0.3, Width = 3 } } },
			},
		},
	},

	--[[
		Magic that grows with magic: +0.1% damage per Magic unit on the map. Ten Magic
		on the field give 1%, fifty give 5%; `Scaling` is recounted every combat frame,
		so selling a tower shrinks the bonus at once.
	]]
	{
		Id = "Abrakadabra",
		Title = "ABRAKADABRA",
		Description = "Magic units deal +0.1% damage for every magic unit placed",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,

		-- No `Image`: this card came without art, and without the field it keeps the art
		-- authored on `CardTemplate` instead of vanishing from the screen.

		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Magic" }, Scaling = { Stat = "Damage", Class = "Magic", Amount = 0.001 } },
			},
		},
	},

	--[[
		Ice that works better alone: an Ice unit with no neighbor within ten studs
		attacks 25% faster. The condition is recounted every frame, so placing a tower
		next to it removes the bonus at once, and selling it restores it.
	]]
	{
		Id = "Iceolated",
		Title = "ICEOLATED",
		Description = "Ice units get +25% attack speed while no other unit is nearby",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://89798319191056",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{
					Classes = { "Ice" },
					Condition = "Isolated",
					ConditionRadius = 10,
					Stats = { AttackSpeed = 1.25 },
				},
			},
		},
	},

	--[[
		The opposite of Iceolated: here ice is good for itself and bad for its
		neighbors. The second record catches units that are **not** Ice and have an Ice
		within ten studs.
	]]
	{
		Id = "IceToMeetYou",
		Title = "ICE TO MEET YOU",
		Description = "Ice units attack 50% faster; units near them attack 50% slower",
		Price = 350,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://105810324385179",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Ice" }, Stats = { AttackSpeed = 1.5 } },
				{
					Classes = { "Ice" },
					Exclude = true,
					Condition = "NearClass",
					ConditionClass = "Ice",
					ConditionRadius = 10,
					Stats = { AttackSpeed = 0.5 },
				},
			},
		},
	},

	--[[
		The slow ice units leave on enemies weighs 10% more.

		A **global** modifier (no class, no zone, no unit): it describes the state the
		tower left on the enemy, not the tower. `MobService:ApplySlow` reads it through
		`CardModifier.Global`.
	]]
	{
		Id = "ChillOut",
		Title = "CHILL OUT",
		Description = "Ice units slow enemies 10% harder",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://76479415282650",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Stats = { Slow = 1.1 } },
			},
		},
	},

	-- Chill Out's counterpart on the fire side: each burn tick charges 20% more. Also
	-- global, for the same reason.
	{
		Id = "FireHazard",
		Title = "FIRE HAZARD",
		Description = "Burning enemies take +20% burn damage",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://107866423132745",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Stats = { Burn = 1.2 } },
			},
		},
	},

	--[[
		The last stand: while the base is below 20% health, everyone hits 20% harder.

		> ⚠️ The original request was "+20% HP on units". **Units have no health in
		> this game**: nothing ever attacks a tower, and there is no bar to fill. The
		> card keeps the same promise on the side that exists: a last-minute bonus that
		> only lights when the match is hanging by a thread. If towers ever get health,
		> swap `Damage` for `Health` on this line.
	]]
	{
		Id = "NoPainNoGain",
		Title = "NO PAIN, NO GAIN",
		Description = "While the base is under 20% HP, every unit deals +20% damage",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://108872703336271",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ BaseHealthBelow = 0.2, Stats = { Damage = 1.2 } },
			},
		},
	},

	--[[
		Ice on everyone at once. During snow it doubles down: the slow rises from 50% to
		75% and enemies also become brittle, taking 20% more damage from any source.

		The server reads the weather at the moment of use: buying the card and waiting
		for snow is the play, so the bonus is decided when it is used, not when bought.
	]]
	{
		Id = "AzureEverIce",
		Title = "STAFF OF AZURE EVER ICE",
		Description = "Slows every enemy by 50% for 10s -- 75% and brittle during snow",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://112747378880473",
		Effect = "ChillEnemies",
		Params = {
			Slow = 0.5,
			Duration = 10,

			-- What changes when the card is used with this weather in effect.
			Weather = "Snow",
			WeatherSlow = 0.75,
			WeatherBrittle = 1.2,
		},
	},

	--[[ ========================== TARGET: ONE UNIT ========================== ]]

	{
		Id = "BloxyCola",
		Title = "BLOXY COLA",
		Description = "Doubles one unit's fire rate for 10 seconds",
		Price = 200,
		Weight = 1,
		Use = RoundCardConfig.Use.Unit,
		Image = "rbxassetid://71582562553170",
		Effect = "Modifier",
		Params = {
			Duration = 10,
			Modifiers = {
				{ Target = true, Stats = { AttackSpeed = 2 } },
			},
		},
	},

	{
		Id = "Bloxiade",
		Title = "BLOXIADE",
		Description = "Doubles one unit's damage for 10 seconds",
		Price = 200,
		Weight = 1,
		Use = RoundCardConfig.Use.Unit,
		Image = "rbxassetid://95661475359990",
		Effect = "Modifier",
		Params = {
			Duration = 10,
			Modifiers = {
				{ Target = true, Stats = { Damage = 2 } },
			},
		},
	},

	--[[ ========================== TARGET: ONE SPOT ========================== ]]

	--[[
		Clears stuns on units in the circle and makes them immune for ten seconds. The
		answer to thunder and snow freeze, the two things that take a tower out of a
		whole wave today.

		The immunity has a timer on purpose: without it, a well-placed staff would erase
		the weather mechanic in that corner until the end of the round.
	]]
	{
		Id = "StaffOfHealing",
		Title = "STAFF OF HEALING",
		Description = "Clears stun in an area and grants 10s of stun immunity",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Area,
		Image = "rbxassetid://109636982142517",
		Effect = "Cleanse",
		Ring = "Healing",
		Params = {
			Radius = 6,
			Immunity = 10,

			--[[
				A modifier that modifies nothing.

				It exists for one thing: **being the circle on the ground**. This card's
				effect is not a multiplier (it is `CleanseUnits`, instant), but the
				immunity lasts ten seconds, and the player must see how far it reached and
				for how long. As a zone, the ring appears and disappears with it without a
				drawing path of its own.

				No `Stats` and no `Flags` on purpose: multiplier readers skip it.
			]]
			Modifiers = {
				{ Zone = true },
			},
		},
	},

	--[[
		The three staffs are the same idea: a ring on the ground that trades one thing
		for another for whoever stands inside. The first record is who the card favors,
		the second is the toll everyone else pays, and `Exclude` makes the two cover the
		whole map with no overlap.

		The ring **stays**: without `Duration`, it lasts until the end of the round.
		Where the player draws it is the card's whole decision.
	]]
	{
		Id = "CelestialStaff",
		Title = "CELESTIAL STAFF",
		Description = "Ring of mana: magic units get 1.2x damage and 1.1x fire rate, everyone else is weakened",
		Price = 500,
		Weight = 1,
		Use = RoundCardConfig.Use.Area,
		Image = "rbxassetid://82581504689393",
		Ring = "Celestial",
		Effect = "Modifier",
		Params = {
			Radius = 7,
			Modifiers = {
				{ Zone = true, Classes = { "Magic" }, Stats = { Damage = 1.2, AttackSpeed = 1.1 } },
				{
					Zone = true,
					Classes = { "Magic" },
					Exclude = true,
					Stats = { Damage = 0.8, AttackSpeed = 0.9, Income = 0.9 },
				},
			},
		},
	},

	{
		Id = "RobuxRoyaltyStaff",
		Title = "STAFF OF ROBUX ROYALTY",
		Description = "Ring of Robux: 1.1x hit income and 1.15x eco income, at 0.8x damage and fire rate",
		Price = 450,
		Weight = 1,
		Use = RoundCardConfig.Use.Area,
		Image = "rbxassetid://118780034086303",
		Ring = "Robux",
		Effect = "Modifier",
		Params = {
			Radius = 7,
			Modifiers = {
				{ Zone = true, Stats = { HitIncome = 1.1, Damage = 0.8, AttackSpeed = 0.8 } },

				-- Farm income on top of the previous record: an income unit inside the ring gets
				-- both records, and they multiply.
				{ Zone = true, Farm = true, Stats = { Income = 1.15 } },
			},
		},
	},

	--[[
		The wind ring favors units with the bow symbol, which in this game is the
		`Ranged` class, the same the card icon draws (see `ClassConfig.Icons`).
	]]
	{
		Id = "WindsStaff",
		Title = "STAFF OF THE WINDS",
		Description = "Windy zone: ranged units get 1.1x damage and 1.2x range, everyone else 0.8x damage",
		Price = 450,
		Weight = 1,
		Use = RoundCardConfig.Use.Area,
		Image = "rbxassetid://109862438058085",
		Ring = "Windy",
		Effect = "Modifier",
		Params = {
			Radius = 7,
			Modifiers = {
				{ Zone = true, Classes = { "Ranged" }, Stats = { Damage = 1.1, Range = 1.2 } },
				{ Zone = true, Classes = { "Ranged" }, Exclude = true, Stats = { Damage = 0.8 } },
			},
		},
	},

	--[[ ==================== TARGET: ONE UNIT AND ONE SPOT ==================== ]]

	--[[
		The only card that changes the board instead of the numbers. The destination
		goes through the same checks as `PlaceUnit` (off the path, away from other
		towers, nobody standing there), and a refused destination **does not spend the
		card**.

		"The same checks" is literal: once the tower is picked, the second step calls
		`UnitPlacementController:visualize`, the same ghost as placing a new tower. The
		player picks the destination seeing the tower's own model half-transparent,
		green where it fits and red where it does not, with its range ring, and rotates
		with R. The ghost starts at the tower's current rotation.
	]]
	{
		Id = "Zippers",
		Title = "ZIPPERS",
		Description = "Move one placed unit to any other valid spot",
		Price = 150,
		Weight = 1,
		Use = RoundCardConfig.Use.Move,
		Image = "rbxassetid://137527028552020",
		Effect = "MoveUnit",

		--[[
			No `Params`: this card has no area or number to tune. The tower's ghost marks
			the destination, and the ring shown is its range, from the unit's own stats.
		]]
	},
}


--[[ ENDLESS SHOP: BORROWED TOWERS AND WEATHER ]]

local UnitStats = require(script.Parent:WaitForChild("UnitStats"))

RoundCardConfig.TowerLoan = {
	PriceRatio = 0.6, -- share of the tower's normal placement cost
	Waves = 5,        -- how many waves the borrowed tower stays
	Weight = 0.6,
}

RoundCardConfig.TowerCards = {}

for unitName, stats in UnitStats do
	-- Income towers are left out: a loan that pays itself back would be free money.
	if typeof(stats) ~= "table" or typeof(stats.Cost) ~= "number" or stats.Farm then
		continue
	end

	table.insert(RoundCardConfig.TowerCards, {
		Id = "Tower:" .. unitName,
		Title = string.upper(unitName),
		Description = "",
		Price = math.floor(stats.Cost * RoundCardConfig.TowerLoan.PriceRatio + 0.5),
		Weight = RoundCardConfig.TowerLoan.Weight,
		Use = RoundCardConfig.Use.Place,
		Effect = "LoanUnit",
		Tower = true,
		Params = { Unit = unitName, Waves = RoundCardConfig.TowerLoan.Waves },
	})
end

table.sort(RoundCardConfig.TowerCards, function(a, b)
	return a.Id < b.Id
end)

local WEATHER_CARDS = {
	{ Weather = "Rain",      Title = "SUMMON RAIN",       Noun = "rain" },
	{ Weather = "Snow",      Title = "SUMMON BLIZZARD",   Noun = "a blizzard" },
	{ Weather = "Wind",      Title = "SUMMON WIND",       Noun = "wind" },
	{ Weather = "Fog",       Title = "SUMMON FOG",        Noun = "fog" },
	{ Weather = "Thunder",   Title = "SUMMON THUNDER",    Noun = "thunder" },
	{ Weather = "Sandstorm", Title = "SUMMON SANDSTORM",  Noun = "a sandstorm" },
	{ Weather = "Drought",   Title = "SUMMON DROUGHT",    Noun = "a drought" },
}

RoundCardConfig.WeatherCards = {}

for _, data in WEATHER_CARDS do
	table.insert(RoundCardConfig.WeatherCards, {
		Id = "Weather:" .. data.Weather,
		Title = data.Title,
		Description = "Calls down " .. data.Noun .. " for 2 waves",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Effect = "SummonWeather",
		Params = { Weather = data.Weather, Waves = 2 },
	})
end



--[[ API ]]

local byId = {}
for _, list in { RoundCardConfig.Cards, RoundCardConfig.TowerCards, RoundCardConfig.WeatherCards } do
	for _, card in list do
		byId[card.Id] = card
	end
end

--- The loan card for a unit name, or nil.
function RoundCardConfig.GetTowerCard(unitName : any)
	if typeof(unitName) ~= "string" then
		return nil
	end

	return byId["Tower:" .. unitName]
end

--- The card for the `Id`, or nil. The `Id` comes from the network, so it can be anything.
function RoundCardConfig.Get(id : any)
	if typeof(id) ~= "string" then
		return nil
	end

	return byId[id]
end

--[=[
	A card's use type, always one of `RoundCardConfig.Use`.

	A card without the field, and a card that does not exist (the `Id` came from the
	network), is `Instant`. The right default in both cases: an unknown `Id` must not
	put the screen in an aiming mode the player could not leave.
]=]
function RoundCardConfig.GetUse(id : any) : string
	local card = RoundCardConfig.Get(id)
	local use = card and card.Use

	return RoundCardConfig.Use[use] or RoundCardConfig.Use.Instant
end

--[[ ENDLESS PRICE SCALING ]]

--[[
	Gentle curve: multiplier = 1 + Linear * wave + Curve * wave^2.

	The linear term keeps early waves calm (+10% of base per wave); the small quadratic
	term makes the climb speed up gradually, so late waves still get expensive without
	any sudden step between one shop and the next.

	Example, a 450 card: wave 3 = 594, wave 12 = 1121, wave 30 = 2610, wave 60 = 6390.
]]
RoundCardConfig.EndlessPriceLinear = 0.10
RoundCardConfig.EndlessPriceCurve = 0.002

--- The price of a card on a given wave. Only Endless scales; everything else is the base price.
function RoundCardConfig.GetPrice(card, wave : number?, endless : boolean?) : number
	local base = math.max(0, card.Price or 0)
	if not endless then return base end

	local w = math.max(0, wave or 0)
	local multiplier = 1 + RoundCardConfig.EndlessPriceLinear * w + RoundCardConfig.EndlessPriceCurve * w * w

	return math.floor(base * multiplier + 0.5)
end

--- This card's ring radius, for aiming and for the zone it leaves.
function RoundCardConfig.GetRadius(id : any) : number
	local card = RoundCardConfig.Get(id)
	local radius = card and card.Params and card.Params.Radius

	return radius or RoundCardConfig.Targeting.DefaultRadius
end

--- Every how many waves the shop appears at this difficulty.
function RoundCardConfig.GetInterval(difficultyName : string?) : number
	local interval = difficultyName and RoundCardConfig.Intervals[difficultyName]

	return interval or RoundCardConfig.DefaultInterval
end

--[=[
	Whether this wave is a shop wave.

	An exact multiple of the interval. Wave 0 is left out on purpose: it is not a
	wave, it is the intermission before the first.
]=]
function RoundCardConfig.IsShopWave(waveNumber : number?, difficultyName : string?) : boolean
	if typeof(waveNumber) ~= "number" or waveNumber < 1 then
		return false
	end

	return waveNumber % RoundCardConfig.GetInterval(difficultyName) == 0
end

--[=[
	Draws `count` cards **without repeats**, weighted.

	`pool` is the candidate list (the service passes only cards with a registered
	effect, and in the Lobby only those the shop can sell). The draw is without
	replacement: a drawn card leaves the urn and the others' weights stay relative, so
	a rare card does not become likelier just because the common one came out.

	A pool smaller than `count` returns the whole pool shuffled: with two cards in
	the catalog, showing two beats repeating one.

	`rng` is a dedicated `Random`, which makes a draw **reproducible**: the Lobby card
	shop's stock is recomputed from scratch on each server from the time and the
	player (see `RoundCardShopConfig.stockFor`). With the global `math.random`, each
	server would draw differently, and a restart mid-block would swap the stock early.

	Without `rng`, the draw uses `math.random`: the round offer's draw, which is per
	player and per wave and must not be predictable.
]=]
function RoundCardConfig.Draw(count : number, pool : { any }?, rng : Random?) : { any }
	local candidates = {}
	for _, card in (pool or RoundCardConfig.Cards) do
		table.insert(candidates, card)
	end

	local drawn = {}

	for _ = 1, math.min(count, #candidates) do
		local total = 0
		for _, card in candidates do
			total += math.max(0, card.Weight or 1)
		end

		if total <= 0 then
			break
		end

		local roll = (rng and rng:NextNumber() or math.random()) * total
		local cursor = 0

		for index, card in candidates do
			cursor += math.max(0, card.Weight or 1)

			if roll <= cursor then
				table.insert(drawn, card)
				table.remove(candidates, index)
				break
			end
		end
	end

	return drawn
end

return RoundCardConfig