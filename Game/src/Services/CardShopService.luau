local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("CardShopService")

local RoundCardConfig = SharedConfig.RoundCardConfig
local RoundCardShopConfig = SharedConfig.RoundCardShopConfig
local WeatherConfig = SharedConfig.WeatherConfig

--[[
	How far `EffectDelay` may drift from the animation marker before it becomes a
	warning, in seconds. See `_auditVisualDelays`.

	It is not zero because the config number is written by hand, rounded from what Moon
	Animator shows: a thousandth of difference is transcription, not a mismatch.
]]
local EFFECT_DELAY_TOLERANCE = 0.05

--[=[
	The round card shop.

	Every X waves (the interval is per difficulty; see `RoundCardConfig.Intervals`) each
	player gets their own offer of three drawn cards. Buying takes the money from match
	cash (`MobService.SessionCash`, the same that pays for towers) and puts the card in
	their hotbar; using it spends the card and fires the effect.

	**Everything that decides anything lives here.** The client does not draw, charge, or
	run any effect: it sends "I want to buy card X from the offer with token T" and "I
	want to use card with id U", and the server checks both against what it stored
	itself. A card the player does not have, or an offer that already closed, simply
	produces nothing.

	**The offer is per player.** Match cash is individual, so a shared draw would have the
	same card fought over by people who do not compete for money. Each one draws their
	own, buys their own, and uses their own, but the **effect** belongs to the room: Time
	Stop stops everyone's enemies.

	**So is the pool.** The draw does not sweep the catalog: it sweeps what that player
	unlocked in the Lobby card shop (`Data.RoundCards`; see `RoundCardShopService`).
	Sweeping the whole `RoundCardConfig.Cards` would give everyone all twenty-odd cards on
	their first match, and the Lobby shop would have nothing to sell.

	**The offer closes on purchase.** One purchase per opening: that is why
	`Offers[userId]` leaves the table as soon as the card is paid for, not only on the
	buyer's screen.

	See docs/game/round-card-shop.md.
]=]
local CardShopService = {
	Services = {
		WaveService = {},
		MobService = {},
		DifficultyService = {},
		SpeedService = {},
		WeatherRoundService = {},
		UnitService = {},
		CardModifierService = {},

		-- To read the profile's `RoundCards`: it says which cards this player can
		-- draw. See `_poolFor`.
		DataService = {},
	},

	--[[
		Each player's open offer: `[UserId] = { Token, Wave, Cards = { id } }`. It leaves
		the table on purchase, at the end of the round, and when the player leaves.
	]]
	Offers = {},

	--[[
		Cards bought and not yet used:
		`[UserId] = { [uid] = cardId }`.

		The `uid` exists because the same card can be bought twice in different offers,
		and using one must not spend the other.
	]]
	Owned = {},

	--[[
		Timed cards that are resting: `[UserId] = { [cardId] = Token }`.

		The number is the **last** opening in which the card is still out of that player's
		draw. See `_rest`, which writes it, and `_poolFor`, which reads it.
	]]
	Resting = {},

	--[[
		One-time cards this player already took off the table: `[UserId] = { [cardId] = true }`.

		There is no way back in this table: it is only emptied at the end of the round. See
		`_isStacking`, which says what goes in here, and `_spend`, which writes it.
	]]
	Spent = {},

	-- Goes up on every opening. It is what keeps a late click on an old offer from
	-- buying anything from the new one.
	Token = 0,
}

--[[ EFFECTS ]]

--[=[
	What each card does, by the name `RoundCardConfig` declares in `Effect`.

	Each function receives the user, the card's `Params`, and the use's `context` (the
	chosen target, the spent card's `uid`, and its `Id`), and returns the sentence that
	goes to the server log. None of them knows the shop: they call the services that
	already own that state: freezing belongs to `MobService`, the clock to
	`SpeedService`, the sky to `WeatherRoundService`, field rules to
	`CardModifierService`, and the board to `UnitService`.

	**There are seven effects for twenty-odd cards**, not one per card. Almost everything
	a round card does is leave a rule in effect on the field, and that rule has its own
	grammar (`CardModifier`): hence `Modifier`, which reads the list the card declared and
	hands it to the service. A new card that only changes numbers needs no code at all:
	it is an entry in `RoundCardConfig` and nothing else.

	A card whose effect does not exist in this table is dropped from the draw with a
	warning (see `_pool`), instead of becoming a card the player pays for that does
	nothing.
]=]
CardShopService.Effects = {
	--[=[
		The effect of almost the whole catalog: putting the card's rules on the field.

		The records come from the config; what the **use** adds is the target (the zone
		where the player drew the ring, or the tower they chose) and the deadline.
		`CardModifierService` stores, prunes, and replicates them.
	]=]
	Modifier = function(self, player : Player, params, context)
		local service = self.Services.CardModifierService
		if not service then return "no CardModifierService" end

		local records = params.Modifiers
		if typeof(records) ~= "table" or #records == 0 then
			return "the card declared no modifier"
		end

		local target = context.Target

		local zone = nil
		if target and target.Position then
			zone = { Position = target.Position, Radius = RoundCardConfig.GetRadius(context.Card) }
		end

		local applied = service:Apply(records, {
			Uid = context.Uid,
			Card = context.Card,
			Duration = params.Duration,
			Zone = zone,
			UnitId = target and target.UnitId or nil,

			-- So this player's next ring knows this spot is taken. See
			-- `FindZoneOverlap`.
			OwnerUserId = player.UserId,
		})

		return string.format("%d field rule(s)%s", applied,
			params.Duration and string.format(" for %ss", tostring(params.Duration)) or " until the end of the round")
	end,

	--[=[
		Cash straight into the user's hand.

		It is **match** cash (`roundcash`), the same that pays for towers and paid for the
		card itself, not the profile's `Cash`. A round card must not become a tap of
		progression currency.
	]=]
	GrantCash = function(self, player : Player, params)
		local mobService = self.Services.MobService
		if not mobService then return "no MobService" end

		local amount = math.max(0, params.Amount or 0)
		mobService:addCash(player, amount)

		return string.format("%d cash to %s", amount, player.Name)
	end,

	--[=[
		The Staff of Healing: removes the stun from units in the circle and makes them
		immune for a few seconds.

		It applies to **everyone's** towers inside the circle, not only the user's. The
		same rule as the rest of the cards: one person pays, but the effect belongs to the
		room.
	]=]
	Cleanse = function(self, player : Player, params, context)
		local unitService = self.Services.UnitService
		if not unitService then return "no UnitService" end

		local target = context.Target
		if not target or not target.Position then return "no area picked" end

		local radius = RoundCardConfig.GetRadius(context.Card)
		local touched = unitService:CleanseUnits(target.Position, radius, params.Immunity or 0)

		--[[
			The circle on the ground while the immunity lasts.

			It comes in the same way as the staffs' zones (a modifier with `Zone`, stored
			in `CardModifierService`), which is why it appears, disappears, and reappears
			for players joining mid-match without any drawing of its own. The modifier
			changes no stat: it **is** the ring. See this card's `Modifiers` in
			`RoundCardConfig`.
		]]
		local modifiers = self.Services.CardModifierService
		if modifiers and params.Modifiers then
			modifiers:Apply(params.Modifiers, {
				Uid = context.Uid,
				Card = context.Card,
				Duration = params.Immunity,
				Zone = { Position = target.Position, Radius = radius },
				OwnerUserId = player.UserId,
			})
		end

		return string.format("%d unit(s) healed and immune for %ss", touched, tostring(params.Immunity or 0))
	end,

	--[=[
		The Staff of Azure Ever Ice: the whole room slower for a few seconds.

		The weather is read **on use**, not on purchase: buying the card and holding it
		until snow arrives is the play, and deciding the bonus on purchase would take the
		decision away from the player.
	]=]
	ChillEnemies = function(self, player : Player, params)
		local mobService = self.Services.MobService
		if not mobService then return "no MobService" end

		local slow = params.Slow or 0.5
		local brittle = nil

		local weather = mobService:GetWeather()
		if params.Weather and weather == params.Weather then
			slow = params.WeatherSlow or slow
			brittle = params.WeatherBrittle
		end

		local chilled = mobService:ChillAll(slow, params.Duration, brittle)

		return string.format("%d enemies at -%d%% for %ss%s", chilled, math.floor(slow * 100 + 0.5),
			tostring(params.Duration), brittle and " (brittle)" or "")
	end,

	--[=[
		Zippers: the chosen unit moves.

		The destination goes through the same checks as `PlaceUnit`. If refused, the
		effect returns the reason, but the card **is already spent**, which is why the
		destination is checked beforehand, in `Use`: when this effect runs, the spot has
		already been accepted.
	]=]
	MoveUnit = function(self, player : Player, params, context)
		local unitService = self.Services.UnitService
		if not unitService then return "no UnitService" end

		local target = context.Target
		if not target or not target.UnitId or not target.Position then
			return "missing the unit or the destination"
		end

		local entry, reason = unitService:MoveUnit(target.UnitId, target.Position, target.Rotation)
		if not entry then
			return string.format("move refused (%s)", tostring(reason))
		end

		return string.format("%s moved", entry.unitName)
	end,

	TimeStop = function(self, player : Player, params)
		local mobService = self.Services.MobService
		if not mobService then return "no MobService" end

		local duration = params.Duration or 4
		local frozen = mobService:FreezeAll(duration)

		return string.format("%d enemies frozen for %ss", frozen, tostring(duration))
	end,

	TimeAcceleration = function(self, player : Player, params)
		local speedService = self.Services.SpeedService
		if not speedService then return "no SpeedService" end

		local scale = params.Scale or 3
		local duration = params.Duration or 15

		speedService:SetOverride(scale, duration)

		return string.format("match at %sx for %ss", tostring(scale), tostring(duration))
	end,

	--[[
		The card skips **this** wave's weather, not the whole weather: a three-wave
		blizzard bought on the first returns on the second. See
		`WeatherRoundService:SkipCurrentWave`.

		No `Params`: there is no wave count to tune, and the only wave the card knows is
		the one in progress.
	]]
	WeatherReport = function(self, player : Player)
		local weatherRound = self.Services.WeatherRoundService
		if not weatherRound then return "no WeatherRoundService" end

		if not weatherRound:SkipCurrentWave() then
			return "there was no weather on"
		end

		return "clear sky this wave"
	end,

	--[[ Endless shop: borrow one of the player's own towers. ]]
	LoanUnit = function(self, player : Player, params, context)
		local unitService = self.Services.UnitService
		if not unitService then return "no UnitService" end

		local target = context.Target
		if not target or not target.Position then return "no spot picked" end

		local entry, reason = unitService:PlaceLoanedUnit(player, params.Unit, target.Position, target.Rotation, params.Waves)
		if not entry then
			return string.format("loan refused (%s)", tostring(reason))
		end

		return string.format("%s loaned to %s", entry.unitName, player.Name)
	end,

	--[[ Endless shop: put a weather on now. ]]
	SummonWeather = function(self, player : Player, params)
		local weatherRound = self.Services.WeatherRoundService
		if not weatherRound then return "no WeatherRoundService" end

		local ok, reason = weatherRound:Summon(params.Weather, params.Waves)
		if not ok then
			return string.format("weather refused (%s)", tostring(reason))
		end

		return string.format("%s for %d wave(s)", params.Weather, params.Waves or 1)
	end,


}

--[[ INTERNAL ]]

--[=[
	The cards this server knows how to run: those in the catalog whose `Effect` actually
	exists.

	It is the first of the draw's two filters, and the only one about the **game**: a card
	with no registered effect must not go out to anyone. The warning goes out once per
	broken card, not on every draw: hand-written config gets names wrong, and a card the
	player pays for that does nothing is worse than a card that never appears.
]=]
function CardShopService:_pool()
	local pool = {}

	for _, card in RoundCardConfig.Cards do
		if self.Effects[card.Effect] then
			table.insert(pool, card)
			continue
		end

		if not self.WarnedEffects[card.Id] then
			self.WarnedEffects[card.Id] = true
			log:StudioWarn(string.format("card '%s' asks for effect '%s', which does not exist in Effects.",
				card.Id, tostring(card.Effect)))
		end
	end

	return pool
end


-- endless

--- By the preset's `Endless` flag, not its name, like `WaveService`.
function CardShopService:_isEndless() : boolean
	local preset = self:_difficulty()

	return preset ~= nil and preset.Endless == true
end

--- Loan cards for the towers this player owns (profile `Units`).
function CardShopService:_ownedTowerCards(player : Player) : { any }
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	local owned = entry and entry.Profile.Data.Units

	if typeof(owned) ~= "table" then return {} end

	local cards = {}
	for unitName, amount in owned do
		if typeof(amount) == "number" and amount > 0 then
			local card = RoundCardConfig.GetTowerCard(unitName)
			if card then
				table.insert(cards, card)
			end
		end
	end

	return cards
end

--- Weather cards for the weathers this map can actually roll.
function CardShopService:_weatherCards() : { any }
	local weatherRound = self.Services.WeatherRoundService
	local mapName = weatherRound and weatherRound:GetMapName()

	local allowed = {}
	for _, name in WeatherConfig.GetPool(mapName) do
		allowed[name] = true
	end

	local cards = {}
	for _, card in RoundCardConfig.WeatherCards do
		if allowed[card.Params.Weather] then
			table.insert(cards, card)
		end
	end

	return cards
end

-- Endless draw odds. Tune these.
local ENDLESS_MIN_NORMAL = 2        -- normal (buff) cards guaranteed per offer, when the player has them
local ENDLESS_WEATHER_CHANCE = 0.15 -- chance an offer includes a weather card (0.15 = 15%)
local ENDLESS_TOWER_CHANCE = 0.6    -- chance an offer includes a tower loan

--[=[
	The Endless offer: mostly normal cards, with a tower loan and a weather card as
	occasional extras. Normal cards take at least `ENDLESS_MIN_NORMAL` slots, so the
	extras only compete for what is left. Weather is rolled first, then the tower.
	If the player has too few normal cards, the empty slots fall back to towers, then
	weather, so the offer is never short. Shuffled so slot 1 isn't always a normal card.
]=]
function CardShopService:_drawEndless(candidates : { any }, towers : { any }, weathers : { any }) : { any }
	local picks = {}
	local drawCount = RoundCardConfig.DrawCount

	local function take(list : { any })
		local card = RoundCardConfig.Draw(1, list)[1]
		if not card then return end

		table.insert(picks, card)
		table.remove(list, table.find(list, card))
	end

	-- Slots the extras may use: whatever the guaranteed normal cards leave free.
	local maxExtras = math.max(0, drawCount - math.min(ENDLESS_MIN_NORMAL, #candidates))

	if #picks < maxExtras and math.random() < ENDLESS_WEATHER_CHANCE then
		take(weathers)
	end

	if #picks < maxExtras and math.random() < ENDLESS_TOWER_CHANCE then
		take(towers)
	end

	-- Fill the rest: normal cards first, then leftover towers, then weather.
	while #picks < drawCount do
		if #candidates > 0 then
			take(candidates)
		elseif #towers > 0 then
			take(towers)
		elseif #weathers > 0 then
			take(weathers)
		else
			break
		end
	end

	for index = #picks, 2, -1 do
		local swap = math.random(1, index)
		picks[index], picks[swap] = picks[swap], picks[index]
	end

	return picks
end


--[=[
	Is the card timed?

	It is the question that decides who rests after use, and the answer is
	`Params.Duration` itself: a card whose effect **expires on its own** is a window, and
	one without a deadline is a decision that lasts the whole round.

	The rule is derived from the config, not a hand-written list, on purpose: a new card
	with `Duration` starts resting from day one, and a card that loses its deadline in a
	balance tweak stops resting in the same commit. A parallel list would diverge from the
	catalog at the first number someone changed.
]=]
function CardShopService:_isTemporary(card) : boolean
	local duration = card and card.Params and card.Params.Duration

	return typeof(duration) == "number" and duration > 0
end

--[=[
	Puts the card to rest for one opening in this player's hand.

	The deadline is written in **shop openings**, not waves or seconds: what the rule
	promises is "not in the next offer", and the next offer is the next time `Open` runs:
	on a difficulty with interval 6 that is longer than on one with 4, which is exactly
	right, because the offer is the scarce resource, not the clock.

	`Token + 1` is the opening after this one, and `_poolFor`'s comparison is `<=`: used
	after the wave 4 offer (Token 1), the card stays out of wave 8 (Token 2) and returns on
	wave 12 (Token 3).

	It rests **per player**, along with the pool: whoever used Time Stop does not see it in
	the next offer, and whoever did not can still draw it.
]=]
function CardShopService:_rest(player : Player, cardId : string)
	local resting = self.Resting[player.UserId]
	if not resting then
		resting = {}
		self.Resting[player.UserId] = resting
	end

	resting[cardId] = self.Token + 1
end

--[=[
	Does the card stack on itself forever?

	It is three things at once, and the answer comes from the config itself:

	1. its effect is a **field rule** (`Effect = "Modifier"`), and `CardModifierService`'s
	   list accepts two copies of the same record, which multiply;
	2. it **has no deadline**, so the rule lasts until the end of the round;
	3. it **draws no area**, so what it changes is the whole map.

	All three together are the only case where buying the same card again is always the
	best possible play: Overcharge twice is 1.56x damage on Electric, three times 1.95x,
	and nothing in the game brakes that. A timed one solves itself (it expires), an area
	one solves itself through the ground (two cannot touch), and a non-`Modifier` one
	stacks no rule: Money Bag gives money, Zippers moves a tower, Weather Report clears one
	wave's sky.

	Whatever answers yes leaves that player's draw **on purchase**, and does not return
	this match. See `_spend`.
]=]
function CardShopService:_isStacking(card) : boolean
	if not card or card.Effect ~= "Modifier" then return false end
	if self:_isTemporary(card) then return false end

	local records = card.Params and card.Params.Modifiers
	if typeof(records) ~= "table" then return false end

	for _, record in records do
		if record.Zone then return false end
	end

	return true
end

--[=[
	Takes the card off this player's table for the rest of the match.

	Called on **purchase**, not only on use: a bought card is a decision already made,
	even if it spends the whole wave in the hotbar. Without this the player would keep
	three copies of Overcharge in hand and use them at once, exactly the stacking the rule
	removes from the game.

	Also called on use, for a card that reached the hand outside the shop (a Cmdr command,
	a gift). It is cheap, and writing `true` twice to the same key costs nothing.

	It lasts the match, not the profile: the next match starts with a clean table, like
	cash and the hotbar. See `ResetRound`.
]=]
function CardShopService:_spend(player : Player, cardId : string)
	local spent = self.Spent[player.UserId]
	if not spent then
		spent = {}
		self.Spent[player.UserId] = spent
	end

	spent[cardId] = true
end

--[=[
	The cards **this player** can draw: those in `_pool` they unlocked in the Lobby card
	shop.

	The second filter, and the only one about the **player**. What they unlocked lives in
	the profile's `RoundCards` and is written there, in the Lobby, by
	`RoundCardShopService`; here it is only read.

	A profile that has not loaded counts as empty, not as the whole catalog: unlocking
	everything while the data has not arrived would give the player an offer they did not
	pay for, and the first shop wave is early enough for that race to really happen.

	A timed card they just used is left out of this opening (see `_rest`): it is unlocked,
	but resting. There is no notice on screen: from a three-card offer you cannot tell
	which were not drawn, and the card comes back on its own.

	A one-time card they already bought is left out **for the rest of the match** (see
	`_spend`). That one does not come back: their pool shrinks as they build, which is
	what makes each of those cards a choice instead of a number to repeat.

	An empty pool is not an error: it is the player who spent their shards on something
	else and has no card unlocked. The offer simply does not open for them; see `Open`.
]=]
function CardShopService:_poolFor(player : Player, pool : { any })
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	local profile = entry and entry.Profile.Data or nil

	local unlocked = RoundCardShopConfig.unlockedOf(profile)
	local resting = self.Resting[player.UserId] or {}
	local spent = self.Spent[player.UserId] or {}
	local candidates = {}

	for _, card in pool do
		if not unlocked[card.Id] then continue end
		if spent[card.Id] then continue end

		-- The number is the last opening in which it still rests, and this is the current one.
		local restingUntil = resting[card.Id]
		if restingUntil and self.Token <= restingUntil then continue end

		table.insert(candidates, card)
	end

	return candidates
end

--[=[
	Checks the target the client sent against the card's use type. Returns the cleaned
	target, or `nil` and the reason.

	The client chooses the target, which is why **nothing** it sends gets in without going
	through here: a unit `Id` that does not exist, a point ten thousand studs away, a
	`Vector3` that is actually a string. None of these is a program error: it is what
	arrives from a tampered client, and what arrives from a legitimate click on a tower
	sold on the same frame.

	The returned target is **rebuilt**, field by field, instead of passed through: that
	way nothing beyond these two keys crosses to the effect, however much the client
	stuffed into the table.

	The last check for an area card is that the spot is free of **this player's** other
	areas (see `CardModifierService:FindZoneOverlap`). It is done here, not inside the
	effect, for the same reason as the others: a refused target does not spend the card,
	and the player returns to aiming with it still in hand.
]=]
function CardShopService:_checkTarget(player : Player, card, target : any)
	local use = RoundCardConfig.GetUse(card.Id)

	if use == RoundCardConfig.Use.Instant then
		return {}
	end

	if typeof(target) ~= "table" then
		return nil, "no target"
	end

	local checked = {}

	if use == RoundCardConfig.Use.Unit or use == RoundCardConfig.Use.Move then
		local unitService = self.Services.UnitService
		if not unitService then
			return nil, "no UnitService"
		end

		if typeof(target.UnitId) ~= "string" or not unitService.UnitsById[target.UnitId] then
			return nil, "unit is not on the map"
		end

		checked.UnitId = target.UnitId
	end

	if use == RoundCardConfig.Use.Area or use == RoundCardConfig.Use.Move or use == RoundCardConfig.Use.Place then
		local position = target.Position

		if typeof(position) ~= "Vector3" then
			return nil, "no position"
		end

		-- NaN passes any size comparison, so it is caught by the only test it does
		-- not pass: being equal to itself.
		if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
			return nil, "NaN position"
		end

		if position.Magnitude > RoundCardConfig.Targeting.MaxDistance then
			return nil, "position too far away"
		end

		checked.Position = position
	end

	--[[
		The rotation the player chose on the ghost, in radians, on the Y axis only: towers
		stand upright, and placement never offered another axis.

		It is **optional**: a client that sends nothing is still valid, and the tower keeps
		its current rotation. What is not valid is sending garbage, which is why the number
		goes through the same three tests as the position (being a number, not NaN, and not
		infinite) before being wrapped to one turn.
	]]
	if (use == RoundCardConfig.Use.Move or use == RoundCardConfig.Use.Place) and target.Rotation ~= nil then
		local rotation = target.Rotation

		if typeof(rotation) ~= "number" or rotation ~= rotation or math.abs(rotation) == math.huge then
			return nil, "invalid rotation"
		end

		checked.Rotation = rotation % (2 * math.pi)
	end

	--[[
		Area touching area, only for `Use.Area`: `Move` also sends a position, but it is a
		tower's destination, not a ring: `PlacementUtil` checks that, by the placement
		rules.

		The client already paints the aim red here and does not allow confirming, so
		reaching this branch is a tampered client or a real race: two area cards used on the
		same frame, the second on top of the first.
	]]

	if use == RoundCardConfig.Use.Place then
		local unitService = self.Services.UnitService
		if not unitService then
			return nil, "no UnitService"
		end

		local ok, reason = unitService:CanPlaceLoan(player, card.Params and card.Params.Unit, checked.Position, checked.Rotation)
		if not ok then
			return nil, reason
		end
	end


	if use == RoundCardConfig.Use.Area then
		local modifiers = self.Services.CardModifierService
		local overlap = modifiers and modifiers:FindZoneOverlap(
			player.UserId,
			checked.Position,
			RoundCardConfig.GetRadius(card.Id)
		)

		if overlap then
			return nil, string.format("area touches the one from %s", tostring(overlap.Card))
		end
	end

	return checked
end

--- The difficulty preset in use, or nil.
function CardShopService:_difficulty()
	local waveService = self.Services.WaveService

	return (waveService and waveService.Difficulty)
		or (self.Services.DifficultyService and self.Services.DifficultyService:GetSelected())
end

--- The cards this player has in hand, as a list of `{ Uid, Id }`.
function CardShopService:_ownedList(player : Player)
	local owned = self.Owned[player.UserId]
	if not owned then return {} end

	local list = {}
	for uid, cardId in owned do
		table.insert(list, { Uid = uid, Id = cardId })
	end

	return list
end

--[=[
	The shop state as this player sees it: their open offer (if any) and the cards they
	already bought and have not used.

	Both together on purpose: this bundle is what rebuilds the whole screen of a player
	who just loaded the interface, not only the part that changed.
]=]
function CardShopService:_sendState(player : Player)
	local offer = self.Offers[player.UserId]

	Framework:Fire("RoundCardState", player, {
		token = offer and offer.Token or nil,
		wave = offer and offer.Wave or nil,
		cards = offer and offer.Cards or nil,
		prices = offer and offer.Prices or nil,
		owned = self:_ownedList(player),
	})
end

--[=[
	Opens an offer for these players. Without a list, for the whole room.

	Each one draws their own, from **their pool** (the cards they unlocked in the Lobby),
	but the `Token` is the same for the opening: it invalidates previous offers at once,
	including those of players who bought nothing last round.

	A player with no unlocked card gets no offer, and theirs is **erased** instead of left
	as it was: without that they would keep the previous shop wave's offer on screen, and
	the new `Token` would make every click on it be refused as an "expired offer".

	Returns true when at least one player got an offer.
]=]
function CardShopService:Open(players : { Player }?, waveNumber : number?)
	local tutorialService = Framework:Get("TutorialMatchService", false, false)
	local pool = self:_pool()
	if #pool == 0 then
		log:Warn("no card has a registered effect; the shop did not open.")
		return false
	end

	local waveService = self.Services.WaveService
	local wave = waveNumber or (waveService and waveService.WaveCount) or 0

	self.Token += 1

	local opened = false

-- new
	local endless = self:_isEndless()

	for _, player in (players or Players:GetPlayers()) do
		local candidates = self:_poolFor(player, pool)
		local towers = if endless then self:_ownedTowerCards(player) else {}
		local weathers = if endless then self:_weatherCards() else {}

		if #candidates == 0 and #towers == 0 and #weathers == 0 then
			self.Offers[player.UserId] = nil
			self:_sendState(player)

			continue
		end

		local drawn
		if endless then
			drawn = self:_drawEndless(candidates, towers, weathers)
		else
			drawn = RoundCardConfig.Draw(RoundCardConfig.DrawCount, candidates)
		end

				-- The offer and the client work with card ids, not the full card tables.
		local cards = {}
		for _, card in drawn do
			table.insert(cards, card.Id)
		end

		--[[
			The tutorial plants the step's card in the rotation.

			It **replaces** the first drawn card instead of adding a fourth: the offer has
			three slots on screen, and a fourth card would fall outside the drawing. If it
			was already drawn, nothing changes.
		]]
		local forcedCard = tutorialService and tutorialService:ForcedCard(wave)
		if forcedCard and not table.find(cards, forcedCard) then
			cards[1] = forcedCard
		end

		-- Prices are fixed when the offer opens, so the client and the charge always agree.
		local prices = {}
		for _, cardId in cards do
			local card = RoundCardConfig.Get(cardId)
			if card then
				prices[cardId] = RoundCardConfig.GetPrice(card, wave, endless)
			end
		end

		self.Offers[player.UserId] = {
			Token = self.Token,
			Wave = wave,
			Cards = cards,
			Prices = prices,
		}

		self:_sendState(player)
		opened = true
	end

	return opened
end

--[[ API ]]

--[=[
	The purchase. Returns the bought card and its `uid`, or nil and the reason.

	The four checks are the four ways the request can be stale or off: an offer that does
	not exist, an offer from another opening, a card that was not in that offer, and
	money that is not enough. None of them is a program error: it is what arrives when
	the player double-clicks, when two shop tabs cross, or when someone sends the event by
	hand.
]=]
function CardShopService:Buy(player : Player, token : any, cardId : any)
	local offer = self.Offers[player.UserId]
	if not offer then
		return nil, "no open offer"
	end

	if offer.Token ~= token then
		return nil, "expired offer"
	end

	if not table.find(offer.Cards, cardId) then
		return nil, "card is not in the offer"
	end

	local card = RoundCardConfig.Get(cardId)
	if not card then
		return nil, "unknown card"
	end

	-- With a purchase step open, the tutorial only lets its card through.
	local tutorialService = Framework:Get("TutorialMatchService", false, false)
	if tutorialService and not tutorialService:CanBuy(cardId) then
		return nil, "outside the tutorial step"
	end

	local mobService = self.Services.MobService
	if not mobService then
		return nil, "no MobService"
	end

	local price = math.max(0, (offer.Prices and offer.Prices[cardId]) or card.Price or 0)
	if mobService:getCash(player) < price then
		return nil, "not enough cash"
	end

	mobService:spendCash(player, price)

	if tutorialService then
		tutorialService:NoteBuy(cardId)
	end

	local uid = HttpService:GenerateGUID(false)
	local owned = self.Owned[player.UserId]
	if not owned then
		owned = {}
		self.Owned[player.UserId] = owned
	end
	owned[uid] = card.Id

	--[[
		A stacking card leaves their table here, on purchase: from then on it is not drawn
		again this match, used or not. See `_isStacking`.
	]]
	if self:_isStacking(card) then
		self:_spend(player, card.Id)
	end

	-- One purchase per opening: the offer closes for the buyer.
	self.Offers[player.UserId] = nil

	Framework:Fire("RoundCardBought", player, {
		token = token,
		id = card.Id,
		uid = uid,
	})

	log:Debug(string.format("%s bought '%s' for %d.", player.Name, card.Id, price))

	return card, uid
end

--[=[
	The use. The card is spent **before** the effect runs: if the effect errors, the card
	does not return to the player's hand with the room's state already half changed.

	**The effect waits for the gesture.** A card with `Visual.EffectDelay` runs the effect
	that many seconds later, the instant of the animation's `VFX` marker: the freeze lands
	with the particle burst, not on the click. What does **not** wait is everything else:
	the card leaves the hand and `RoundCardUsed` fires immediately, or the player would
	click again thinking the first click did not register.

	The delay lives here, not on the client playing the animation. The client holds the
	marker, but the server runs effects: letting the client say "now" would let it choose
	when to freeze the whole room.

	Returns the used card, or nil and the reason.
]=]
function CardShopService:Use(player : Player, uid : any, target : any)
	local tutorialService = Framework:Get("TutorialMatchService", false, false)
	local owned = self.Owned[player.UserId]
	local cardId = owned and owned[uid]

	if not cardId then
		return nil, "the player does not hold the card"
	end

	local card = RoundCardConfig.Get(cardId)
	if not card then
		owned[uid] = nil
		return nil, "unknown card"
	end

	local effect = self.Effects[card.Effect]
	if not effect then
		return nil, "card has no effect"
	end

	-- The tutorial locks its card until the step that asks for it opens.
	if tutorialService and not tutorialService:CanUse(cardId) then
		return nil, "the card cannot be used in the tutorial yet"
	end

	--[[
		The target is checked **before** the card leaves the hand. Getting the spot wrong
		(clicking the sky, choosing a tower that was just sold) returns aiming to the player
		with the card still in the hotbar; only an accepted target spends the purchase.

		It is the only thing checked beforehand: the rest (the effect erroring, for
		example) happens with the card already spent, on purpose, so the room's state is
		never half changed with the card back in hand.
	]]
	local checked, reason = self:_checkTarget(player, card, target)
	if not checked then
		return nil, reason
	end

	owned[uid] = nil

	-- The tutorial step that asked for this card closes here: the card left the hand
	-- with an accepted target, which is what "using" means.
	if tutorialService then
		tutorialService:NoteUse(cardId)
	end

	--[[
		A timed card leaves their draw for one opening, and this is where that is marked:
		on **use**, not purchase. Buying and keeping it in the hotbar spent no window; what
		the rule charges is having had the effect on the field.

		A stacking card already left the table on purchase, and is marked again here only
		for the path outside the shop: a card that reached the hand without going through
		`Buy` never saw `_spend`.
	]]
	if self:_isTemporary(card) then
		self:_rest(player, card.Id)
	elseif self:_isStacking(card) then
		self:_spend(player, card.Id)
	end

	Framework:Fire("RoundCardUsed", player, {
		uid = uid,
		id = card.Id,
	})

	--[[
		The gesture goes to the whole room, not only the payer.

		`RoundCardUsed` stays private because it changes the user's **hand** (removes the
		card from their deck), and that is nobody else's business. What is everyone's
		business is the scene: Time Stop freezes the room's enemies, and without this only
		the owner would hear and see it happen.

		It only goes to the others: the user already received `RoundCardUsed`, which fires
		the full gesture on their screen (animation, lock, and their own animation's marker
		in charge). Sending both to the same person would play the sound twice.

		The animation itself does not travel here: it plays on the user's character, and
		the `Animator` replicates that to everyone on its own. What the other screens lack,
		and what this event carries, is the sound and the particles.
	]]
	if card.Visual then
		for _, plr in Players:GetPlayers() do
			if plr ~= player then
				Framework:Fire("RoundCardVisual", plr, {
					id = card.Id,
					user = player,
				})
			end
		end
	end

	local context = { Uid = uid, Card = card.Id, Target = checked }

	local function run()
		local ok, result = pcall(effect, self, player, card.Params or {}, context)

		if not ok then
			log:Warn(string.format("the effect of '%s' errored (%s).", card.Id, tostring(result)))
			return
		end

		log:Debug(string.format("%s used '%s': %s.", player.Name, card.Id, tostring(result)))

		--[[
			The burst on the tower the card took.

			Together with the effect, not on the click: a card with `EffectDelay` comes in
			after the gesture, and the burst must land with it. And after the effect
			succeeded: an effect that errored touched no tower, and the burst would promise
			something that did not happen.

			It lives here, not inside each effect, because what knows the card had a tower
			as its target is its target: a new single-target effect gets the burst without
			writing anything.

			It goes to **everyone**: the card is bought by one person, but the whole room
			sees the tower react.
		]]
		if checked.UnitId then
			for _, plr in Players:GetPlayers() do
				Framework:Fire("RoundCardApplied", plr, checked.UnitId)
			end
		end
	end

	--[[
		Real time, not `GameClock`: the gesture is an animation playing on the character,
		and it does not speed up with the match. Going through the sped-up clock would make
		the effect land before the burst exactly when the game is at 3x.
	]]
	local delay = card.Visual and card.Visual.EffectDelay

	if delay and delay > 0 then
		task.delay(delay, run)
	else
		run()
	end

	return card
end

--[=[
	Resets with the round. Cards belong to the match: there is nothing to carry to the
	next one, nor an open offer that survives the results screen.
]=]
function CardShopService:ResetRound()
	table.clear(self.Offers)
	table.clear(self.Owned)

	-- Rest is counted in this match's openings, and the table is this match's: the
	-- next one starts from zero, with the whole catalog back in each player's pool.
	table.clear(self.Resting)
	table.clear(self.Spent)

	-- The rules cards left on the field go too: a staff's ring must not
	-- survive the results screen.
	local modifiers = self.Services.CardModifierService
	if modifiers then
		modifiers:ResetRound()
	end

	for _, player in Players:GetPlayers() do
		self:_sendState(player)
	end
end

--[[ LIFECYCLE ]]

--[=[
	Checks whether the cards' `EffectDelay` and `SoundDelay` still match their animation.

	The config numbers are **copies** of the `VFX` and `Sound` marker instants, and copies
	go stale: reanimating the card in Moon Animator moves the markers and leaves the
	effect landing off the gesture, with no error in the log, just off on screen. It is
	the same kind of silent mismatch mislabeled difficulty buttons can cause, and the
	answer is the same: check on startup and warn.

	Both numbers apply to **whoever is not playing the animation**: `EffectDelay` times the
	effect here on the server, and both time the sound and particles on the screen of
	someone watching another player's gesture (the marker only reaches whoever loaded the
	track). A drift here shows up as the room's sound off the owner's gesture, which is
	why both are checked and not just one.

	**It only warns.** It does not correct the number with what it downloaded: timing the
	room's effect by a web call that may fail or lag would be worse than the drift it
	catches. A download failure also passes quietly: the game does not depend on it.
]=]
function CardShopService:_auditVisualDelays()
	--[[
		Each line is "the config field" against "the marker parameter it copies". A
		`Visual` that declares only one of the two is checked only on it: `SoundDelay` is
		not required, and a card that plays no sound does not need it.
	]]
	local MIRRORED = {
		{ Field = "EffectDelay", Parameter = RoundCardConfig.Markers.VFX, What = "applies the effect" },
		{ Field = "SoundDelay", Parameter = RoundCardConfig.Markers.Sound, What = "plays the sound" },
	}

	for _, card in RoundCardConfig.Cards do
		local visual = card.Visual
		if not visual or not visual.Animation then continue end

		local ok, sequence = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(visual.Animation)
		end)

		if not ok or not sequence then continue end

		for _, mirrored in MIRRORED do
			local copied = visual[mirrored.Field]
			if not copied then continue end

			local markedAt = nil
			for _, keyframe in sequence:GetKeyframes() do
				for _, marker in keyframe:GetMarkers() do
					if marker.Name == visual.Marker and marker.Value == mirrored.Parameter then
						markedAt = keyframe.Time
					end
				end
			end

			if not markedAt then
				log:StudioWarn(string.format(
					"the animation of '%s' has no '%s' marker with the '%s' parameter; %s will fire at %.3fs with nothing happening on screen.",
					card.Id, tostring(visual.Marker), mirrored.Parameter, mirrored.Field, copied))
				continue
			end

			if math.abs(markedAt - copied) > EFFECT_DELAY_TOLERANCE then
				log:StudioWarn(string.format(
					"'%s' %s at %.3fs, but the animation's '%s' marker is at %.3fs. Fix %s in RoundCardConfig.",
					card.Id, mirrored.What, copied, mirrored.Parameter, markedAt, mirrored.Field))
			end
		end
	end
end

function CardShopService:construct()
	local tutorial = Framework:Get("TutorialMatchService", false, false)

	-- On its own thread: it downloads the cards' animations, and the shop has no reason
	-- to wait for that to exist.
	task.spawn(function()
		self:_auditVisualDelays()
	end)

	local waveService = self.Services.WaveService

	if waveService and waveService.Signals and waveService.Signals.WaveStarted then
		waveService.Signals.WaveStarted:Connect(function(waveNumber, preset)
			-- Borrowed towers whose wave is over leave before the next wave's shop opens.
			local unitService = self.Services.UnitService
			if unitService and unitService.ExpireLoans then
				unitService:ExpireLoans(waveNumber)
			end


			local scripted = tutorial and tutorial:ShopIsScripted()
			local forced = tutorial and tutorial:ShouldOpenShop(waveNumber)

			if scripted then
				if not forced then return end
			elseif not RoundCardConfig.IsShopWave(waveNumber, preset and preset.Name) then
				return
			end

			self:Open(nil, waveNumber)
		end)
	else
		log:Warn("WaveService has no WaveStarted signal; the shop will not open on its own.")
	end

	Framework:Listen("BuyRoundCard", function(player : Player, token : any, cardId : any)
		local card, reason = self:Buy(player, token, cardId)

		if not card then
			-- The client had already closed the shop on the click; the state returns the
			-- truth to its screen.
			self:_sendState(player)

			log:Debug(string.format("purchase by %s refused (%s).", player.Name, tostring(reason)))
		end
	end)

	Framework:Listen("UseRoundCard", function(player : Player, uid : any, target : any)
		local card, reason = self:Use(player, uid, target)

		if not card then
			self:_sendState(player)

			log:Debug(string.format("use by %s refused (%s).", player.Name, tostring(reason)))
		end
	end)

	--[[
		The client asks when it finishes setting up the interface. Without this, a player
		reloading the GUI in the middle of an open offer would only see it at the next
		opening, and the cards already bought would vanish from their hotbar.
	]]
	Framework:Listen("RequestRoundCardState", function(player : Player)
		self:_sendState(player)
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.Offers[player.UserId] = nil
		self.Owned[player.UserId] = nil
		self.Resting[player.UserId] = nil
		self.Spent[player.UserId] = nil
	end)
end

function CardShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function CardShopService:init()
	self.WarnedEffects = {}

	-- Only the server fires these; without the empty Listen the client would wait ten
	-- seconds for the identifier to appear (see docs/architecture/me-framework.md).
	Framework:Listen("RoundCardState", function() end)
	Framework:Listen("RoundCardBought", function() end)
	Framework:Listen("RoundCardUsed", function() end)
	Framework:Listen("RoundCardVisual", function() end)
	Framework:Listen("RoundCardApplied", function() end)
end

return CardShopService
