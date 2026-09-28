local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Utils.GameClock)

local Me = require(Vendor.Me)

local Framework = Me.new()

local CardModifier = SharedConfig.CardModifier

--[=[
	The rules round cards left in effect on the field.

	A round card almost never does one thing and ends: it changes how the match works
	from then on. The Trumpet speeds everyone up, Overcharge separates Electric from
	the rest, a staff draws a ring where the rule only applies inside, and Bloxy Cola
	doubles one tower's attack speed for ten seconds. This service is the list of those
	rules: who enters, when they leave, and who needs to know.

	**The grammar does not live here.** `CardModifier` answers "does this modifier
	apply to this unit, and how much?", and it is shared precisely because both ends
	need the same answer: the server charges damage by it, and the range circle the
	player sees on screen comes from the same math. Only **state** lives here: the live
	list, each entry's deadline, and replication.

	## The deadline

	A modifier with `Duration` gets an `ExpiresAt` on the **match** clock, not real
	time: Bloxy Cola's ten seconds are ten seconds of play, so speeding up to 3x
	shortens the buff along with everything else, the same as stuns, lightning
	charge, and Time Stop.

	Without `Duration` the modifier lasts until the end of the round. That is the
	default on purpose: a field buff bought with match cash is a build decision, and a
	short deadline would turn every rule card into a worse version of the drinks.

	## Replication

	The client receives the whole list on every change, not an "X entered". There are
	few records (a full match has a dozen), and the complete list is the only way for
	someone joining mid-match (or reloading the interface) to see the same field the
	server sees. The same reason as `CardShopService`'s `_sendState`.

	The client needs it for two things: drawing the staffs' rings on the ground and
	showing the tower's real range on the card.

	See docs/game/round-cards.md.
]=]
local CardModifierService = {
	Services = {
		MobService = {},
	},

	--[[
		The modifiers in effect now. It is a list, not a per-card dictionary: two copies
		of the same card stack on purpose, and each use is its own record with the
		`Uid` of the purchase that created it.
	]]
	Active = {},
}

--[[ INTERNAL ]]

--[=[
	Removes what already expired from the list. Returns `true` if anything left.

	Run on read, not in a Heartbeat loop: combat is the reader, sixty times a second,
	and a loop of its own would only wake up to find nothing expired. The price is that
	a buff expiring with nobody looking stays in the list until the next read, and
	since the reader is combat itself, that never lasts more than a frame.
]=]
function CardModifierService:_prune() : boolean
	local now = GameClock.Now()
	local removed = false

	for index = #self.Active, 1, -1 do
		local modifier = self.Active[index]

		if modifier.ExpiresAt and now >= modifier.ExpiresAt then
			table.remove(self.Active, index)
			removed = true
		end
	end

	return removed
end

--[[ API ]]

--[=[
	The live list, without what expired.

	Returns the **real** list, not a copy: it is read per unit and per stat every
	combat frame, and copying there would allocate a few hundred tables per second to
	change nothing. Nobody writes to it from outside: the only hands on it are `Apply`
	and `Remove` here.
]=]
function CardModifierService:GetActive()
	if self:_prune() then
		self:_broadcast()
	end

	return self.Active
end

--[=[
	Puts a list of modifiers on the field.

	`records` are the raw records the card declared in `RoundCardConfig`, and
	`options` is what only the **use** knows:

	| Field | What it is |
	| --- | --- |
	| `Uid` | the used card's uid; `Remove` takes it off by this |
	| `Card` | the card's `Id`, for the log and the ring's color on screen |
	| `Duration` | match seconds; without it, the record lasts the round |
	| `Zone` | `{ Position, Radius }`, for records marked `Zone = true` |
	| `UnitId` | the chosen tower, for records marked `Target = true` |
	| `OwnerUserId` | who used the card; `FindZoneOverlap` separates areas by it |

	The records are **copied**, never referenced: the config's is the card's
	declaration, and two copies of the same card in the same match would write target
	and deadline over each other if both pointed to the same table.
]=]
function CardModifierService:Apply(records, options) : number
	if typeof(records) ~= "table" then return 0 end

	options = options or {}

	local expiresAt = nil
	if options.Duration and options.Duration > 0 then
		expiresAt = GameClock.Now() + options.Duration
	end

	local added = 0

	for _, record in records do
		local modifier = {
			Uid = options.Uid,
			Card = options.Card,
			ExpiresAt = expiresAt,

			--[[
				Who used the card. It does not change what the modifier does (the effect
				belongs to the room, whoever it came from), and it exists for a single
				question: whether **this player's** next area may land here. See
				`FindZoneOverlap`.
			]]
			OwnerUserId = options.OwnerUserId,

			Stats = record.Stats,
			Flags = record.Flags,
			Classes = record.Classes,
			Exclude = record.Exclude,
			Farm = record.Farm,
			Condition = record.Condition,
			ConditionClass = record.ConditionClass,
			ConditionRadius = record.ConditionRadius,
			Scaling = record.Scaling,
			BaseHealthBelow = record.BaseHealthBelow,
		}

		--[[
			The two fields only the use fills in. A record that **asks** for a zone and
			does not get one is left out: with no center or radius it would become a
			global buff, which is exactly the opposite of what an area staff promises.
		]]
		if record.Zone then
			if not options.Zone then continue end
			modifier.Zone = { Position = options.Zone.Position, Radius = options.Zone.Radius }
		end

		if record.Target then
			if not options.UnitId then continue end
			modifier.UnitId = options.UnitId
		end

		table.insert(self.Active, modifier)
		added += 1
	end

	if added > 0 then
		self:_broadcast()
	end

	return added
end

--- Removes from the field everything that came from one use. It undoes what a card did.
function CardModifierService:Remove(uid : any) : number
	local removed = 0

	for index = #self.Active, 1, -1 do
		if self.Active[index].Uid == uid then
			table.remove(self.Active, index)
			removed += 1
		end
	end

	if removed > 0 then
		self:_broadcast()
	end

	return removed
end

--[=[
	This player's area that a new one of radius `radius` at `position` would touch, or
	`nil` if the spot is free.

	**Two areas of the same player must not touch**: the math is the distance between
	centers against the sum of the radii, the test for two intersecting circles.
	Without it, stacking three staffs on the same handful of towers multiplied the
	three buffs in the same place, and the decision the card sells (*where* to draw the
	ring) disappeared: the best spot was always the previous ring's spot.

	**Only the player's own count.** In a room of four, denying a spot because of
	another player's staff would take away the few worthwhile spots from whoever came
	later, and competing for ground is not what the card charges for. Each player
	arranges their own board.

	`Y` is left out of the math: the ring is a circle on the ground, and the map has
	height. Measuring in three dimensions would let two touching areas pass just
	because one is on a ramp.

	It reads through `GetActive`, not the raw list: a zone that already expired (the
	Staff of Healing's ten seconds) no longer holds any spot.
]=]
function CardModifierService:FindZoneOverlap(userId : number?, position : Vector3, radius : number)
	if typeof(position) ~= "Vector3" or typeof(radius) ~= "number" then return nil end

	for _, modifier in self:GetActive() do
		local zone = modifier.Zone
		if not zone or modifier.OwnerUserId ~= userId then continue end

		local delta = zone.Position - position
		local flat = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)

		if flat < (zone.Radius or 0) + radius then
			return modifier
		end
	end

	return nil
end

--[=[
	The multiplier for a stat that belongs to no unit: the slow ice leaves, the burn
	fire leaves.

	A shortcut for code that only has the stat in hand (`MobService`) and has no reason
	to know `CardModifier`.
]=]
function CardModifierService:GetGlobal(stat : string) : number
	return CardModifier.Global(self:GetActive(), stat)
end

--[=[
	Resets with the round. Cards belong to the match, and so do the rules they left: a
	staff's ring must not survive the results screen.
]=]
function CardModifierService:ResetRound()
	if #self.Active == 0 then return end

	table.clear(self.Active)
	self:_broadcast()
end

--[[ REPLICATION ]]

--- Sends the whole list to a player (or to everyone, without `player`).
function CardModifierService:_broadcast(player : Player?)
	if player then
		Framework:Fire("RoundCardModifiers", player, self.Active)
		return
	end

	for _, plr in Players:GetPlayers() do
		Framework:Fire("RoundCardModifiers", plr, self.Active)
	end
end

--[[ LIFECYCLE ]]

function CardModifierService:construct()
	-- Only the server fires this one; without the empty Listen the client would wait
	-- ten seconds for the identifier to appear (see docs/architecture/me-framework.md).
	Framework:Listen("RoundCardModifiers", function() end)

	--[[
		The client asks when it finishes setting up the interface. Without this, a player
		joining mid-match would not see the rings already on the ground nor the towers'
		real range, and would only discover both at the next card used.
	]]
	Framework:Listen("RequestRoundCardModifiers", function(player : Player)
		self:_broadcast(player)
	end)
end

function CardModifierService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function CardModifierService:init()
end

return CardModifierService
