local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Units = Assets:WaitForChild("Units")

local SharedConfig = require(Configs.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local DeckConfig = SharedConfig.DeckConfig
local CardModifier = SharedConfig.CardModifier
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared:WaitForChild("Util"):WaitForChild("PathUtil"))
local PlacementUtil = require(Shared:WaitForChild("Util"):WaitForChild("PlacementUtil"))
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("UnitService")

local TARGET_SCANS_PER_FRAME = 8

-- One money effect per unit every so often. See `playAuraVFX`.
local AURA_VFX_COOLDOWN = 0.35

local MAX_PLACE_DISTANCE = 2048

--[[
	The width, in studs, of the streak a `Piercing` projectile leaves, when the unit does
	not give another in `Projectile.PierceWidth`.

	It is not the arrow's thickness: it is the slack that decides who was "in the way".
	Two studs catch an enemy the line grazes (they are about two wide) without turning the
	arrow into a cone that clears the next lane over.
]]
local PIERCE_WIDTH = 2

-- Per-unit total damage only feeds an upgrade card label, so it goes
-- in batches a few times per second instead of one event per hit.
local DAMAGE_FLUSH_INTERVAL = 0.25

-- Placement decisions, Studio only.
local placeLog = Log.new("UnitService/Place")

local function formatVector(v : Vector3?)
	if not v then return "nil" end
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

--[[
	The multiplier for units under no card at all.

	A single table, shared by every unit while the modifier list is empty, which is the
	start of every match. Without it each unit would get an "all 1" table per frame, and a
	match with no cards would pay for a system it is not using.

	It is never written: units with modifiers get their own table in
	`refreshCardModifiers`.
]]
local NO_CARD_MULTIPLIERS = {
	Damage = 1,
	AttackSpeed = 1,
	Range = 1,
	Income = 1,
	HitIncome = 1,

	-- `Cleave` is not a number: it is the cleave's table of numbers, or nothing. See
	-- `CardModifier.FlagValue`.
	Cleave = nil,
}

local UnitService = {
	Services = {
		MobService = {},
		DataService = {},
		WaveService = {},
		WeatherService = {},
		CardModifierService = {},
		TutorialMatchService = {},
	},

	Signals = {
		--[[
			(player, unitName): a unit entered the map. `ContractTrackerService` listens,
			for "win with only Fire units": it keeps the classes of everything the player
			placed in the match, including what was sold later.
		]]
		UnitPlaced = Signal.new(),
	},

	PlacedUnits = {},
	UnitsById = {},
	UnitSizes = {},
	UnitBounds = {},
	SessionCards = {},
	SessionCardMax = {},
	DamageDirty = {},
	LastDamageFlush = 0,

	-- The aura farms on the map. Rebuilt every frame in `stepCombat`.
	AuraSources = {},

	-- mobId -> the strongest Cryomancer slow over it this frame. Refilled every frame in
	-- `stepSlowAuras`; `HadAuraSlows` says whether the last one applied any.
	AuraSlows = {},
	HadAuraSlows = false,

	--[[
		The field as `CardModifier` sees it: the unit list (for neighborhood conditions and
		Abrakadabra) and the base health fraction (for No Pain, No Gain).

		Reused instead of rebuilt: it is refilled every frame, and the inner list is cleared
		with `table.clear` so the array is not reallocated sixty times a second.
	]]
	CardWorld = { Units = {}, BaseHealthRatio = 1 },

	-- The modifiers in effect this frame, read from `CardModifierService`.
	CardModifiers = {},
}

for _, model in Units:GetChildren() do
	local _, size = model:GetBoundingBox()
	UnitService.UnitSizes[model.Name] = size.X
	UnitService.UnitBounds[model.Name] = size
end

function UnitService:getCardCount(player, unitName)
	local cards = self.SessionCards[player.UserId]
	if not cards then return 0 end
	return cards[unitName] or 0
end

function UnitService:setCardCount(player, unitName, count)
	local cards = self.SessionCards[player.UserId]
	if not cards then return end
	cards[unitName] = count
	Framework:Fire("UpdateCardCounts", player, unitName, count)
end

function UnitService:decrementCardCount(player, unitName)
	local current = self:getCardCount(player, unitName)
	self:setCardCount(player, unitName, math.max(0, current - 1))
end

function UnitService:incrementCardCount(player, unitName)
	local current = self:getCardCount(player, unitName)
	local maxCards = self.SessionCardMax[player.UserId]
	local cap = maxCards and maxCards[unitName] or current
	self:setCardCount(player, unitName, math.min(cap, current + 1))
end

--[=[
	The cards a player takes into the match come from the **deck** they built in the Lobby
	(`EquippedUnits`), not the whole inventory: only units in a slot come in, and each
	one's count is that slot's `Amount`.

	A player who never built a deck gets an automatic one (`DeckConfig.resolve`), built
	from what they own; without that they would enter the match with no cards, and
	`getCardCount` would refuse every placement.

	The client builds the hotbar from the same profile and the same functions, so both
	arrive at the same deck without needing a new event.

	See docs/game/units.md.
]=]
function UnitService:initPlayerCards(player)
	self.Services.DataService:Get(player, function(profileData)
		local deck = DeckConfig.resolve(profileData)

		local cards = {}
		local cardMax = {}

		-- The tutorial gives its own deck: one Slingshot and two Archers, one card per
		-- `PlacementPoint` on the map. The profile is not touched: a player who came in with a
		-- built deck finds it intact back in the Lobby, and one who came in without any
		-- (the case the tutorial exists for) has something to place.
		local tutorial = self.Services.TutorialMatchService
		local tutorialDeck = tutorial and tutorial:GetDeck()

		for unitName, amount in (tutorialDeck or DeckConfig.tally(deck)) do
			cards[unitName] = amount
			cardMax[unitName] = amount
		end

		self.SessionCards[player.UserId] = cards
		self.SessionCardMax[player.UserId] = cardMax

		-- The tutorial hotbar does not come from the profile, so it must be sent. It goes
		-- **before** the counts: the list is what creates the cards on screen, and a
		-- counter for a card that does not exist yet has nowhere to be written.
		if tutorialDeck and tutorial then
			Framework:Fire("TutorialDeck", player, tutorial:GetDeckOrder())
		end

		for unitName, count in cards do
			Framework:Fire("UpdateCardCounts", player, unitName, count)
		end
	end)
end

--[=[
	Returns the service to its pre-match state: takes down everything placed on the map
	and reloads each player's cards from the profile.

	Each unit leaves through `RemoveUnit`, the same event as selling, so clients clean up
	model, dotted line, mines, and selection through the path that already exists.
]=]
function UnitService:ResetRound()
	for _, entry in ipairs(self.PlacedUnits) do
		for _, player in ipairs(Players:GetPlayers()) do
			Framework:Fire("RemoveUnit", player, entry.unitId)
		end
	end

	table.clear(self.PlacedUnits)
	table.clear(self.UnitsById)
	table.clear(self.DamageDirty)

	-- The map may have changed between rounds.
	self.GridParts = nil

	for _, player in ipairs(Players:GetPlayers()) do
		self:initPlayerCards(player)
	end
end

--[=[
	The path parts of the map in play.

	On the server `GetTagged("Grid")` also returns the parts of the maps stored in
	`ServerStorage.Maps`: hundreds of them, against the hundred or so of the loaded map.
	They could never be hit by a `GetPartsInPart` (they are not in the Workspace), so the
	validation result does not change; what changes is not building a list of hundreds of
	entries on every placement attempt.

	The cache drops on ResetRound, along with the possibility of the map having changed.
]=]
function UnitService:getGridParts()
	if self.GridParts then
		return self.GridParts
	end

	local mapRoot = workspace:FindFirstChild("Map")

	local parts = {}
	for _, part in CollectionService:GetTagged("Grid") do
		if part:IsA("BasePart") and part:IsDescendantOf(mapRoot or workspace) then
			table.insert(parts, part)
		end
	end

	-- Without the map in the Workspace the list may be incomplete; do not store it.
	if mapRoot then
		self.GridParts = parts
	end

	return parts
end

--[=[
	Does this unit fit at this CFrame?

	These are placement's three refusals, in the order they get expensive: on the path,
	too close to another unit, on top of a player.

	It exists as its own function because there are **two** paths that put a unit
	somewhere: the usual `PlaceUnit` and Zippers, which drags it from one place to
	another. Two copies of the same check would end up diverging, and the divergence that
	shows is the worst possible: a card that puts the tower on the path.

	`ignoreEntry` is the unit itself, when it is moving: without it Zippers would always
	refuse, because the tower would be too close to itself.

	`label` only goes into the placement log, which only exists in Studio.
]=]
function UnitService:isSpotFree(cf : CFrame, unitName : string, label : string?, ignoreEntry : any?) : boolean
	local position = cf.Position
	local unitSizeX = self.UnitSizes[unitName] or 2

	--[[
		The test box must be the same the client uses to paint the ghost green: the model's
		real bounding box, rotated by the CFrame it sent. A larger box (e.g. a 6-stud-tall
		cube) goes below the ground and touches the path's thin rails, refusing placements
		the client already approved.

		`PathProbe` stretches that box downward: the unit's volume alone is not enough,
		because anything lifting it above the rail takes the path out of the box. See
		`PlacementUtil.PathClearance`.
	]]
	local checkSize = self.UnitBounds[unitName] or Vector3.new(unitSizeX, 2, unitSizeX)
	local probeCF, probeSize = PlacementUtil.PathProbe(cf, checkSize)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = self:getGridParts()
	local gridProbe = Instance.new("Part")
	gridProbe.Size = probeSize
	gridProbe.Anchored = true
	gridProbe.CanCollide = false
	gridProbe.CanQuery = false
	gridProbe.CanTouch = false
	gridProbe.Transparency = 1
	gridProbe.CFrame = probeCF
	gridProbe.Parent = workspace
	local gridParts = workspace:GetPartsInPart(gridProbe, overlapParams)
	gridProbe:Destroy()
	if #gridParts > 0 then
		placeLog:Debug(label, unitName, "refused: on the path", formatVector(position),
			"probe box", formatVector(probeSize),
			string.format("%d Grid part(s), first: %s at %s", #gridParts, gridParts[1]:GetFullName(), formatVector(gridParts[1].Position)))
		return false
	end

	for _, entry in ipairs(self.PlacedUnits) do
		if entry == ignoreEntry then continue end

		local otherSizeX = self.UnitSizes[entry.unitName] or 2
		local minDist = (unitSizeX + otherSizeX) / 2
		local posA = Vector3.new(position.X, 0, position.Z)
		local posB = Vector3.new(entry.cf.Position.X, 0, entry.cf.Position.Z)
		local dist = (posA - posB).Magnitude
		if dist < minDist then
			placeLog:Debug(label, unitName, "refused: too close to another unit",
				formatVector(position), string.format("%s at %.2f studs (minimum %.2f)", entry.unitName, dist, minDist))
			return false
		end
	end

	--[[
		Nobody is born inside a player.

		This is where the rule really counts: the client paints the ghost red so the player
		can see it, but the server accepts or refuses: a tampered client sends whatever
		CFrame it wants.
	]]
	local blockingCharacter = PlacementUtil.FindBlockingCharacter(cf, checkSize)
	if blockingCharacter then
		placeLog:Debug(label, unitName, "refused: on top of a character",
			formatVector(position), "character", blockingCharacter:GetFullName())
		return false
	end

	return true
end

--[=[
	Moves an already placed unit. It is Zippers, the only card that changes the board
	instead of the numbers.

	The destination goes through the **same** checks as `PlaceUnit`: off the path, away
	from other towers, nobody on top. A refused destination returns `nil` and a reason,
	and the caller does not spend the card: getting the spot wrong must not cost the
	purchase.

	`rotation` is the Y-axis rotation in radians, optional; without it the tower keeps
	what it had. It enters the check along with the point, not after: the box
	`isSpotFree` tests is the **rotated** model's, which is the same the client's ghost
	painted green.

	On screen the unit is removed and re-added (`RemoveUnit` + `ReplicateUnit`) instead of
	sliding to the destination. The `unitId` stays the same, so its card, priority, and
	damage scoreboard survive the trip; the only loss is a move animation, and the
	repositioning path is the same one that already replicates every unit.

	The current target is dropped too: aiming from the old spot after moving would make
	the tower shoot at enemies it no longer reaches.
]=]
function UnitService:MoveUnit(unitId : any, position : any, rotation : number?)
	local entry = self.UnitsById[unitId]
	if not entry then
		return nil, "unit does not exist"
	end

	if typeof(position) ~= "Vector3" then
		return nil, "destino invalido"
	end

	if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
		return nil, "destino NaN"
	end

	if position.Magnitude > MAX_PLACE_DISTANCE then
		return nil, "destino longe demais"
	end

	--[[
		The rotation comes from the ghost, as in a new placement: someone moving a tower
		chooses a spot **and** a direction, and the keyboard's R rotates the Zippers ghost
		the same way it rotates a just-bought tower's.

		With no rotation in the request the tower keeps what it had. That is not just
		backward compatibility: it keeps honest the case where the client had no ghost to
		rotate.

		The height already came in `position`, measured on the client by the same CFrame
		`PlaceUnit` validates.
	]]
	local spin = if rotation then CFrame.Angles(0, rotation, 0) else (entry.cf - entry.cf.Position)
	local cf = CFrame.new(position) * spin

	if not self:isSpotFree(cf, entry.unitName, "Zippers", entry) then
		return nil, "destino ocupado"
	end

	entry.cf = cf
	entry.targetMobId = nil

	--[[
		The client drops the unit's damage scoreboard along with its model (see
		`RemoveUnit` in `UnitPlacementController`), and the batch only sends dirty entries:
		without this the card would show zero until the tower hit again.
	]]
	self.DamageDirty[entry.unitId] = true

	-- An already armed mine stays where it landed: it belongs to the map from the throw on,
	-- not the tower. Only later throws come from the new spot.
	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("RemoveUnit", plr, entry.unitId)
		Framework:Fire("ReplicateUnit", plr, entry.unitName, cf, entry.ownerUserId, entry.unitId, entry.upgrades or 0, entry.priority)
	end

	return entry
end

--[[ BORROWED TOWERS (Endless card shop) ]]

function UnitService:_owns(player : Player, unitName : string) : boolean
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	local owned = entry and entry.Profile.Data.Units

	return typeof(owned) == "table" and (owned[unitName] or 0) > 0
end

function UnitService:CanPlaceLoan(player : Player, unitName : any, position : Vector3, rotation : number?) : (boolean, string?)
	if typeof(unitName) ~= "string" or not SharedConfig.UnitStats[unitName] then
		return false, "unknown unit"
	end

	if not Units:FindFirstChild(unitName) then
		return false, "unit has no model"
	end

	if not self:_owns(player, unitName) then
		return false, "unit not owned"
	end

	local cf = CFrame.new(position) * CFrame.Angles(0, rotation or 0, 0)
	if not self:isSpotFree(cf, unitName, player.Name) then
		return false, "spot is taken"
	end

	return true
end

--- Places a tower with no cash and no deck count; it is removed when its last wave ends.
function UnitService:PlaceLoanedUnit(player : Player, unitName : string, position : Vector3, rotation : number?, waves : number?)
	local ok, reason = self:CanPlaceLoan(player, unitName, position, rotation)
	if not ok then
		return nil, reason
	end

	local cf = CFrame.new(position) * CFrame.Angles(0, rotation or 0, 0)
	local unitId = HttpService:GenerateGUID(false)

	local waveService = self.Services.WaveService
	local currentWave = (waveService and waveService.WaveCount) or 0

	local entry = {
		unitId = unitId,
		unitName = unitName,
		cf = cf,
		ownerUserId = player.UserId,
		upgrades = 0,
		invested = 0, -- selling a loan refunds nothing
		lastAttack = 0,
		priority = TargetPriority.Default,
		loanUntilWave = currentWave + math.max(1, waves or 1) - 1,
	}

	table.insert(self.PlacedUnits, entry)
	self.UnitsById[unitId] = entry

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("ReplicateUnit", plr, unitName, cf, player.UserId, unitId, 0, entry.priority)
	end

	self.Signals.UnitPlaced:Fire(player, unitName)

	return entry
end

--- Called when a wave starts: removes loans whose last wave was before it.
function UnitService:ExpireLoans(waveNumber : number)
	for index = #self.PlacedUnits, 1, -1 do
		local entry = self.PlacedUnits[index]

		if entry.loanUntilWave and entry.loanUntilWave < waveNumber then
			table.remove(self.PlacedUnits, index)
			self.UnitsById[entry.unitId] = nil
			self.DamageDirty[entry.unitId] = nil

			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("RemoveUnit", plr, entry.unitId)
			end
		end
	end
end


--[=[
	Credits damage to a unit. The value is what actually hit the enemy (`DamageMob`
	returns it), not the hit's full damage, so the card's `DmgDone` adds up to the health
	enemies lost.
]=]
function UnitService:addDamageDone(entry, amount)
	if not entry or not amount or amount <= 0 then return end

	entry.damageDone = (entry.damageDone or 0) + amount
	self.DamageDirty[entry.unitId] = true
end

--[=[
	A unitId -> total damage map, for every unit on the map. It goes with `ClientReady`,
	so a player joining mid-match sees the total of units that already stopped shooting
	(the batch flush only sends what changed since the last send).
]=]
function UnitService:getDamageSnapshot()
	local snapshot = {}
	for _, entry in ipairs(self.PlacedUnits) do
		if (entry.damageDone or 0) > 0 then
			snapshot[entry.unitId] = entry.damageDone
		end
	end
	return snapshot
end

function UnitService:flushDamageDone()
	if next(self.DamageDirty) == nil then return end

	local batch = {}
	local hasEntries = false
	for unitId in self.DamageDirty do
		local entry = self.UnitsById[unitId]
		if entry then
			batch[unitId] = entry.damageDone or 0
			hasEntries = true
		end
	end
	table.clear(self.DamageDirty)

	if not hasEntries then return end

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitDamageStats", plr, batch)
	end
end

--[[ WEATHER ]]

--[[ ROUND CARDS ]]

--[=[
	Redoes, once per frame, what round cards are doing to each unit.

	**Once per frame, not per question.** Combat asks every unit's damage, attack speed,
	and range every frame, and two of `CardModifier`'s conditions (Iceolated and Ice to
	Meet You) sweep the whole neighborhood to answer: asking per unit and per stat would
	multiply that sweep by five. Here the math is done once and stored in
	`entry.CardMult`, and the rest of the frame only reads the table.

	Each unit's descriptor is also reused (`entry.CardDescriptor`): the position is
	rewritten, not the table rebuilt. Without that there would be a few dozen tables per
	frame just to tell `CardModifier` things it could already read.

	With no card on the field, everyone points at `NO_CARD_MULTIPLIERS` and the function
	takes the short path, which is the whole match until the first shop.
]=]
function UnitService:refreshCardModifiers()
	local service = self.Services.CardModifierService
	local modifiers = service and service:GetActive() or nil

	self.CardModifiers = modifiers

	if not modifiers or #modifiers == 0 then
		for _, entry in self.PlacedUnits do
			entry.CardMult = NO_CARD_MULTIPLIERS
		end

		return
	end

	local world = self.CardWorld
	table.clear(world.Units)

	local mobService = self.Services.MobService
	local maxHealth = mobService and mobService.MaxBaseHealth or 0
	world.BaseHealthRatio = if maxHealth > 0 then (mobService.BaseHealth or 0) / maxHealth else 1

	for _, entry in self.PlacedUnits do
		local descriptor = entry.CardDescriptor

		if not descriptor then
			descriptor = { UnitId = entry.unitId, UnitName = entry.unitName }
			entry.CardDescriptor = descriptor
		end

		-- The position changes when Zippers moves the tower; the rest of the descriptor is
		-- fixed for the unit's life.
		descriptor.Position = entry.cf.Position

		table.insert(world.Units, descriptor)
	end

	for _, entry in self.PlacedUnits do
		local descriptor = entry.CardDescriptor
		local values = entry.CardMult

		-- The shared table must not be written: whoever leaves the short path
		-- gets their own.
		if not values or values == NO_CARD_MULTIPLIERS then
			values = {}
			entry.CardMult = values
		end

		values.Damage = CardModifier.Multiplier(modifiers, "Damage", descriptor, world)
		values.AttackSpeed = CardModifier.Multiplier(modifiers, "AttackSpeed", descriptor, world)
		values.Range = CardModifier.Multiplier(modifiers, "Range", descriptor, world)
		values.Income = CardModifier.Multiplier(modifiers, "Income", descriptor, world)
		values.HitIncome = CardModifier.Multiplier(modifiers, "HitIncome", descriptor, world)
		values.Cleave = CardModifier.FlagValue(modifiers, "Cleave", descriptor, world)
	end
end

--[=[
	A unit's card multiplier, for the current frame.

	A unit that has not gone through `refreshCardModifiers` yet (one placed this same
	frame, before combat ran) is 1 across the board. That is the right value for the gap:
	it comes in on the next frame, and an empty multiplier never invents a bonus the
	player did not buy.
]=]
function UnitService:cardMultiplier(entry, stat : string) : number
	local values = entry and entry.CardMult

	return (values and values[stat]) or 1
end

--[=[
	The same, for what is not a number: today only Cleave It To Me's cleave.

	It returns that behavior's number table (how many bodies, how much the one behind
	loses, the streak width) or `nil` when it is off, which is why callers can test the
	return as a yes-or-no.
]=]
function UnitService:cardFlag(entry, flag : string)
	local values = entry and entry.CardMult

	return values and values[flag] or nil
end

--[=[
	A unit's range: the table's, with weather, times what cards did to it.

	It exists so there are not two range computations in the file. Combat aims by it, the
	mine lands by it, the farm aura covers by it, and the client draws the circle by the
	same multiplication, on the other side (`CardModifierController`).
]=]
function UnitService:getRange(entry, weather : string?) : number
	local base = SharedConfig.UnitUpgradeConfig:GetRange(entry.unitName, entry.upgrades or 0, weather)

	return base * self:cardMultiplier(entry, "Range")
end

--[=[
	The active weather, read from `WeatherService` every combat frame.

	It comes from there and not from `WeatherRoundService` on purpose: what matters to
	combat is what is in the sky, whether it came from the round or the `weather`
	command: testing a weather by hand must produce exactly the match the round would.
]=]
function UnitService:GetWeather() : string?
	local weatherService = self.Services.WeatherService
	return weatherService and weatherService:GetCurrent() or nil
end

--[=[
	A unit's temporary multiplier (`Damage` or `AttackSpeed`).

	Today only the thunder bolt charges an `Electric` unit, but the field is generic:
	anything needing a timed buff writes `entry.Charge` and combat already respects it.
]=]
function UnitService:chargeMultiplier(entry, stat : string, now : number) : number
	local charge = entry.Charge
	if not charge then return 1 end

	if now >= charge.expiresAt then
		entry.Charge = nil
		return 1
	end

	return charge[stat] or 1
end

--[=[
	Gives a unit a timed buff. Recharging before it ends refreshes the deadline instead of
	stacking: two bolts in a row on the same unit give the full buff duration from the
	second, not 50% on top of 50%.
]=]
function UnitService:ChargeUnit(entry, damage : number?, attackSpeed : number?, duration : number)
	if not entry then return end

	entry.Charge = {
		Damage = damage or 1,
		AttackSpeed = attackSpeed or 1,
		expiresAt = GameClock.Now() + (duration or 0),
	}

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitCharged", plr, entry.unitId, duration or 0)
	end
end

--[=[
	Stuns a unit. The longer deadline rules: a 5s chain must not shorten a 20s stun that
	was already running.

	`source` is the weather that caused the stun, and it travels to the client: stopping
	attacks is always the same yellow highlight, but the snow freeze has its own VFX
	(`Effects.Snow.Freeze.Asset`, `IcedVFX`) and lightning does not. Without `source` (the
	enemy gimmick) the client only draws the highlight.
]=]
function UnitService:StunUnit(entry, duration : number, source : string?)
	if not entry then return end

	--[[
		The Staff of Healing makes the unit immune for a few seconds. The refusal is here,
		not in each thing that stuns: lightning, the snow freeze, and the enemy gimmick all
		go through this function, and a check per caller would end with one of them
		forgotten, which is exactly what the player would read as "the card did not work".
	]]
	if GameClock.Now() < (entry.StunImmuneUntil or 0) then return end

	local until_ = GameClock.Now() + (duration or 0)
	if (entry.StunnedUntil or 0) >= until_ then return end

	entry.StunnedUntil = until_

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitStunned", plr, entry.unitId, duration or 0, source)
	end
end

--[=[
	The units weather can stun.

	Units immune to the weather (Magic, in today's weathers) are left out: there is no
	point drawing among them and then giving up, because that would waste the draw and
	make the snow freeze fail silently on a map full of Magic.

	Without `weatherName` it returns all: the enemy gimmick's case, which stuns with
	nothing to do with weather.
]=]
function UnitService:GetStunnableUnits(weatherName : string?)
	if not weatherName then
		return self.PlacedUnits
	end

	local candidates = {}
	for _, entry in ipairs(self.PlacedUnits) do
		if not SharedConfig.WeatherConfig.IsImmune(weatherName, entry.unitName) then
			table.insert(candidates, entry)
		end
	end

	return candidates
end

--[=[
	Stuns a random unit. `weatherName` restricts the draw to units not immune to that
	weather.
]=]
function UnitService:StunRandomUnit(duration, weatherName : string?)
	local candidates = self:GetStunnableUnits(weatherName)
	if #candidates == 0 then return nil end

	local entry = candidates[math.random(1, #candidates)]
	self:StunUnit(entry, duration or 0, weatherName)

	return entry
end

--[=[
	Removes the stun from units in the circle and makes them immune for `immunity`
	seconds. It is the Staff of Healing.

	Returns how many units the circle caught, including those that were not stunned,
	because the immunity applies to them just the same: the card is both remedy and
	umbrella, and throwing it on a corner of the map before the bolt falls is the right
	play.

	Distance is measured on the plane, like everything else that is a circle in this game:
	the ring the player saw on screen is a drawing on the ground.
]=]
function UnitService:CleanseUnits(position : Vector3, radius : number, immunity : number) : number
	if typeof(position) ~= "Vector3" then return 0 end

	local center = Vector3.new(position.X, 0, position.Z)
	local until_ = GameClock.Now() + math.max(0, immunity or 0)
	local touched = 0

	for _, entry in self.PlacedUnits do
		local at = entry.cf.Position
		if (Vector3.new(at.X, 0, at.Z) - center).Magnitude > radius then continue end

		touched += 1

		-- The longer deadline rules: a second staff on top of the first extends the
		-- immunity, and never shortens it.
		entry.StunImmuneUntil = math.max(entry.StunImmuneUntil or 0, until_)

		local wasStunned = (entry.StunnedUntil or 0) > GameClock.Now()
		entry.StunnedUntil = 0

		--[[
			The client needs to know, and not only because of the yellow highlight: the snow
			freeze has a particle aura that stays up for its whole deadline, and it has no way
			to guess the deadline ended early.
		]]
		if wasStunned then
			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("UnitCleansed", plr, entry.unitId)
			end
		end
	end

	return touched
end

function UnitService:construct()
	Framework:Listen("ReplicateUnit", function() end)
	Framework:Listen("RemoveUnit", function() end)
	Framework:Listen("UnitStunned", function() end)
	Framework:Listen("UnitCharged", function() end)
	Framework:Listen("UnitCleansed", function() end)
	Framework:Listen("UpdateCardCounts", function() end)
	Framework:Listen("RequestCardCounts", function(player)
		--[[
			The tutorial hotbar goes with the counts, and for the same reason they are
			requested: the client asks when **it** is ready. The first batch goes out when the
			profile opens, which usually happens before the controller on the other side
			registered its `Listen`, and a Warp event that arrives before the listener does not
			wait; it is lost.
		]]
		local tutorial = self.Services.TutorialMatchService
		local order = tutorial and tutorial:GetDeckOrder()
		if order then
			Framework:Fire("TutorialDeck", player, order)
		end

		local cards = self.SessionCards[player.UserId]
		if not cards then return end
		for unitName, count in cards do
			Framework:Fire("UpdateCardCounts", player, unitName, count)
		end
	end)

	Framework:Listen("UnitUpgraded", function() end)
	Framework:Listen("UnitPriorityChanged", function() end)
	Framework:Listen("UnitDamageStats", function() end)
	Framework:Listen("UnitSwing", function() end)
	Framework:Listen("TripmineThrown", function() end)
	Framework:Listen("TripmineTriggered", function() end)
	Framework:Listen("FarmPayout", function() end)
	Framework:Listen("AuraBonusVFX", function() end)
	Framework:Listen("ChainLightning", function() end)
	Framework:Listen("ArchmageMeteor", function() end)
	Framework:Listen("ArchmageLightning", function() end)
	Framework:Listen("BonfireState", function() end)

	Framework:Listen("SellUnit", function(player, unitId)
		-- The tutorial match does not sell towers (`CanSell`): wave 1's Slingshot is the
		-- tower the script teaches weather, the shop, and speed with, and returning it to the
		-- hand undoes a step already completed. The client already locks the button; this is
		-- what counts.
		local tutorial = self.Services.TutorialMatchService
		if tutorial and not tutorial:CanSell() then return end

		local foundIndex = nil
		for i, entry in ipairs(self.PlacedUnits) do
			if entry.unitId == unitId and entry.ownerUserId == player.UserId then
				foundIndex = i
				break
			end
		end

		if not foundIndex then return end

		local entry = self.PlacedUnits[foundIndex]
		table.remove(self.PlacedUnits, foundIndex)
		self.UnitsById[entry.unitId] = nil

		local refund = math.floor((entry.invested or 0) * SharedConfig.SellRefundRatio)

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("RemoveUnit", plr, entry.unitId)
		end

		self.Services.MobService:addCash(player, refund)
		if not entry.loanUntilWave then
			self:incrementCardCount(player, entry.unitName)
		end
	end)

	Framework:Listen("UpgradeUnit", function(player, unitId)
		local entry = self.UnitsById[unitId]
		if not entry or entry.ownerUserId ~= player.UserId then return end

		-- The tutorial match does not sell upgrades (`CanUpgrade`): its money is counted
		-- for the deck, and upgrading towers is the lesson of the first real
		-- match. The client already locks the button; this is what counts.
		local tutorial = self.Services.TutorialMatchService
		if tutorial and not tutorial:CanUpgrade() then return end

		local currentLevel = entry.upgrades or 0
		if SharedConfig.UnitUpgradeConfig:IsMaxed(currentLevel) then return end

		local cost = SharedConfig.UnitUpgradeConfig:GetCost(entry.unitName, currentLevel)
		local currentCash = self.Services.MobService:getCash(player)
		if currentCash < cost then return end

		entry.upgrades = currentLevel + 1
		entry.invested = (entry.invested or 0) + cost
		self.Services.MobService:spendCash(player, cost)

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("UnitUpgraded", plr, unitId, entry.upgrades)
		end
	end)

	--[=[
		Changes a unit's target priority. The client sends the mode it wants (not "cycle
		one") so the request does not depend on who is up to date with whom: two quick
		clicks arrive as two modes, and the second wins.
	]=]
	Framework:Listen("SetUnitPriority", function(player, unitId, priority)
		local entry = self.UnitsById[unitId]
		if not entry or entry.ownerUserId ~= player.UserId then return end
		if not TargetPriority.Exists(priority) then return end
		if entry.priority == priority then return end

		entry.priority = priority

		-- The current target drops too: without that the unit would only obey the new
		-- priority after the current enemy left its range.
		entry.targetMobId = nil

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("UnitPriorityChanged", plr, unitId, priority)
		end
	end)

	self.PlayersReady = {}
	Framework:Listen("ClientReady", function(player)
		self.PlayersReady[player.UserId] = true
		for _, entry in self.PlacedUnits do
			Framework:Fire("ReplicateUnit", player, entry.unitName, entry.cf, entry.ownerUserId, entry.unitId, entry.upgrades or 0, entry.priority)
		end

		for _, entry in self.PlacedUnits do
			if entry.Bonfire then
				self:broadcastBonfire(entry, player)
			end
		end

		local cards = self.SessionCards[player.UserId]
		if cards then
			for unitName, count in cards do
				Framework:Fire("UpdateCardCounts", player, unitName, count)
			end
		end

		local damageSnapshot = self:getDamageSnapshot()
		if next(damageSnapshot) ~= nil then
			Framework:Fire("UnitDamageStats", player, damageSnapshot)
		end
	end)

	Framework:Listen("PlaceUnit", function(player, unitName, cf)
		if typeof(unitName) ~= "string" or typeof(cf) ~= "CFrame" then
			placeLog:Debug(player.Name, "refused: invalid arguments", typeof(unitName), typeof(cf))
			return
		end

		local position = cf.Position
		if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
			placeLog:Debug(player.Name, unitName, "refused: NaN position")
			return
		end
		if position.Magnitude > MAX_PLACE_DISTANCE then
			placeLog:Debug(player.Name, unitName, "refused: too far away", formatVector(position),
				string.format("magnitude %.2f > %d", position.Magnitude, MAX_PLACE_DISTANCE))
			return
		end

		local stats = SharedConfig.UnitStats[unitName]
		if not stats then
			placeLog:Debug(player.Name, unitName, "refused: unit has no stats in SharedConfig")
			return
		end

		-- The tutorial rules while a placement step is open: a wrong card or one far
		-- from the point does not get in. The client already dims the other cards; this is
		-- what counts, because the client does not police itself.
		local tutorial = self.Services.TutorialMatchService
		if tutorial and not tutorial:CanPlace(unitName, cf) then
			placeLog:Debug(player.Name, unitName, "refused: outside the tutorial step")
			return
		end

		--[[
			The price with the current weather: rain takes 25% off Ice. It comes from
			`GetPlaceCost` because the hotbar card shows it through the same function; without
			that the player would see one price and pay another.
		]]
		local placeCost = SharedConfig.UnitUpgradeConfig:GetPlaceCost(unitName, self:GetWeather())
		local cash = self.Services.MobService:getCash(player)
		if cash < placeCost then
			placeLog:Debug(player.Name, unitName, "refused: not enough cash",
				string.format("has %d, costs %d", cash, placeCost))
			return
		end

		local cardCount = self:getCardCount(player, unitName)
		if cardCount <= 0 then
			placeLog:Debug(player.Name, unitName, "refused: no units left on the card", "count", cardCount)
			return
		end

		local isValid = self:isSpotFree(cf, unitName, player.Name)

		if isValid then
			local unitId = HttpService:GenerateGUID(false)
			--[[
				`invested` is the **table** price, not what was charged.

				The sell value comes from it, and the client computes the same number through
				`GetInvested` without knowing how much this unit actually cost: `invested` is not
				replicated. Storing the discounted price would make the card promise one refund
				and the sale give another. The discount is still only an advantage: buying for
				75 and selling for 50 is never profit.
			]]
			local sticker = SharedConfig.UnitUpgradeConfig:GetPlaceCost(unitName)

			local newEntry = { unitId = unitId, unitName = unitName, cf = cf, ownerUserId = player.UserId, upgrades = 0, invested = sticker, lastAttack = 0, priority = TargetPriority.Default }
			table.insert(self.PlacedUnits, newEntry)
			self.UnitsById[unitId] = newEntry

			self.Services.MobService:spendCash(player, placeCost)
			self:decrementCardCount(player, unitName)

			placeLog:Debug(player.Name, unitName, "accepted", "CFrame from the client:", formatVector(position),
				"unitId", unitId)

			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("ReplicateUnit", plr, unitName, cf, player.UserId, unitId, 0, newEntry.priority)
			end

			self.Signals.UnitPlaced:Fire(player, unitName)
		end
	end)

	RunService.Heartbeat:Connect(function()
		self:stepCombat()

		local now = os.clock()
		if now - self.LastDamageFlush >= DAMAGE_FLUSH_INTERVAL then
			self.LastDamageFlush = now
			self:flushDamageDone()
		end
	end)
end

--[[ ENTREPRENEUR AURA ]]

--[=[
	The aura farms on the map now, rebuilt once per frame.

	Rebuilt instead of maintained on placement and sale because `stepCombat` already
	sweeps the whole list every frame: a second loop over the same array is not
	measurable, and in exchange there is no state to invalidate when a unit enters, leaves,
	is sold, or the round restarts.
]=]
function UnitService:collectAuraSources()
	table.clear(self.AuraSources)

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local farm = stats and stats.Farm

		if farm and farm.Aura then
			table.insert(self.AuraSources, entry)
		end
	end
end

--[=[
	How much extra cash a unit gets for being in a farm's aura.

	Returns an additive fraction (0.15 is "+15%") and overlapping auras add up: two farms
	covering the same tower count both. Zero means "outside all of them".

	The owner does not enter the math: the aura applies to any allied unit, and the money
	still goes to the owner of the unit that hit.

	Each farm's radius is its range through `GetRange`, that is, the same circle the player
	sees when selecting it, including what weather does to it.
]=]
function UnitService:getAuraBonus(entry, weather : string?) : number
	local sources = self.AuraSources
	if #sources == 0 then return 0 end

	local position = entry.cf.Position
	local bonus = 0

	for _, source in ipairs(sources) do
		-- A farm does not bathe in its own aura; it deals no damage anyway, but keeping the
		-- rule written avoids surprises if a farm ever attacks.
		if source == entry then continue end

		local level = source.upgrades or 0
		local radius = self:getRange(source, weather)

		if (source.cf.Position - position).Magnitude <= radius then
			bonus += SharedConfig.UnitUpgradeConfig:GetAuraBonus(source.unitName, level)
		end
	end

	return bonus
end

--[=[
	The little money burst out of the unit that just earned extra.

	Throttled per unit: a MultiShot is four hits and an AOE is one damage call per enemy
	hit, so without this a Rocket inside the aura would send ten effects on the same frame
	for the same tower. One every `AURA_VFX_COOLDOWN` is enough for the player to
	understand that tower is earning.
]=]
function UnitService:playAuraVFX(entry)
	local now = os.clock()
	if now - (entry.lastAuraVFX or 0) < AURA_VFX_COOLDOWN then return end

	entry.lastAuraVFX = now

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("AuraBonusVFX", plr, entry.unitId)
	end
end

--[=[
	Applies damage and credits the hitter: the unit's damage scoreboard, the owner's cash
	(with the aura bonus), and the money effect when the bonus applied.

	All damage from a unit goes through here: normal attacks, area, and mines.
]=]
function UnitService:creditDamage(entry, mobId, damage : number, auraBonus : number) : number
	--[[
		The Robux Royalty ring's `HitIncome` enters as a **scale** on the reward, not added
		to the aura bonus: the aura is a fraction that stacks between farms (15% + 15% =
		30%), and the card is a multiplier on what is left. Adding the two would turn "1.1x"
		into "+10 percentage points", which is another number.
	]]

	-- Where the target was **before** the damage, for units that spread frost around it
	-- (`Frost.Radius`): a target that dies from the shot has no position to give
	-- afterward, and the area must go out anyway.
	local unitStats = SharedConfig.UnitStats[entry.unitName]
	local frostCenter = unitStats and unitStats.Frost and unitStats.Frost.Radius
		and self.Services.MobService:getMobPosition(mobId)

	local dealt = self.Services.MobService:DamageMob(
		mobId, damage, entry.ownerUserId, auraBonus, self:cardMultiplier(entry, "HitIncome"),
		SharedConfig.WeatherConfig.GetClasses(entry.unitName)
	)
	self:addDamageDone(entry, dealt)

	-- A hit that touched nobody (the enemy was already dead) does not even yield an
	-- effect: `DamageMob` returns 0 and paid nothing.
	if dealt > 0 and auraBonus > 0 then
		self:playAuraVFX(entry)
	end

	--[[
		What the hit **leaves** on the enemy besides damage: ice slow, fire burn, and bleed.
		They are declared on the unit itself (`UnitStats[name].Slow` / `.Burn` / `.Bleed`)
		and run by `MobService`, which owns enemy state.

		Only after the damage landed: a hit that touched nobody freezes and burns nobody.

		> Today the Electro leaves something (the jolt just below, which applies to **each
		> link** of the chain, because this path is the same for any target that took
		> damage), as does the Frostione, with frost stacks that use the slow internally.
		> The burn is the Pyre's, and the Fire Hazard card multiplies its ticks. The bleed
		> is the Slasher's and the Berserker's.
	]]
	if dealt > 0 then
		local stats = SharedConfig.UnitStats[entry.unitName]

		local slow = stats and stats.Slow
		if slow then
			self.Services.MobService:ApplySlow(mobId, slow.Amount, slow.Duration)
		end

		local burn = stats and stats.Burn
		if burn then
			self.Services.MobService:ApplyBurn(mobId, burn.Damage, burn.Ticks, burn.Interval, entry.ownerUserId)
		end

		local bleed = stats and stats.Bleed
		if bleed then
			self.Services.MobService:ApplyBleed(mobId, bleed.Damage, bleed.Ticks, bleed.Interval, entry.ownerUserId, bleed.Vulnerability)
		end

		--[[
			The jolt: the enemy stops completely for an instant, and only then walks again
			(slowed, if the hit also left `Slow`; none does today). It is the same
			`StunnedUntil` as Time Stop, applied to a single enemy.

			It comes **after** the slow on purpose, and the order matters: `ApplySlow` does
			not notify the screen while the enemy is stopped, so slow first and jolt after
			keeps both ends telling the same story. The other way around, the new speed
			notification would go out over the "stopped".
		]]
		-- The time is the unit level's (the jolt grows with upgrades), and the owner goes
		-- along: the stun counts for their contracts.
		local stunDuration = SharedConfig.UnitUpgradeConfig:GetStunDuration(entry.unitName, entry.upgrades or 0)
		if stunDuration > 0 then
			self.Services.MobService:StunMob(mobId, stunDuration, entry.ownerUserId)
		end

		-- The Frostione's frost stacks: slow while they last, freeze on the
		-- last one. The `unitId` goes along because the count belongs to each unit, not the
		-- enemy. See `MobService:ApplyFrost`.
		local frost = stats and stats.Frost
		if frost then
			local mobService = self.Services.MobService
			mobService:ApplyFrost(mobId, frost, entry.ownerUserId, entry.unitId)

			--[[
				The frost area around the target: anyone in it gets a stack from the same unit,
				as if they had been shot, but without damage; the damage is only the target's.
				The radius grows with level (`GetFrostRadius`).

				The center is the target's position **before** the damage (`frostCenter`,
				above): the target may have died from this shot, and the area goes out anyway.
				It is left out of the list because it already got its stack just above.
			]]
			local radius = SharedConfig.UnitUpgradeConfig:GetFrostRadius(entry.unitName, entry.upgrades or 0)
			if frostCenter and radius > 0 then
				for _, nearbyId in mobService:GetMobsInRadius(frostCenter, radius) do
					if nearbyId ~= mobId then
						mobService:ApplyFrost(nearbyId, frost, entry.ownerUserId, entry.unitId)
					end
				end
			end
		end
	end

	return dealt
end

--[=[
	Charges the damage and records the hit in the list that goes in `AttackVisual`.

	The number that crosses is what `DamageMob` **returned**, not what we asked of it. The
	two multipliers living inside it (the Staff of Azure Ever Ice's "brittle" and the
	bleed's open wound, `BleedVulnerability`) do not appear here, and the killing blow is
	still cut at the remaining health.

	That matters because the client does **not** receive the enemy's health on every hit:
	it keeps a copy and subtracts exactly this number from it (see `MobController`'s
	`MobHealth`). Sending the requested value would make the copy drop less than the
	server's, and the difference would never be corrected: the bar would stop at a
	remainder while the server had already killed. On a boss, which takes too many hits
	for the difference to go unnoticed, that would be a whole extra bar.

	A hit that touched nobody (the target died during the windup) is left out of the
	list: `DamageMob` returns 0, and a floating "0" would only clutter the screen.
]=]
function UnitService:creditHit(entry, hits, mobId, damage : number, auraBonus : number) : number
	local dealt = self:creditDamage(entry, mobId, damage, auraBonus)

	if dealt > 0 then
		table.insert(hits, { mobId = mobId, damage = dealt })
	end

	return dealt
end

--[[ SLOW AURAS ]]

--[=[
	The Cryomancer's rings: every enemy inside one walks slower, for exactly as long as
	it stays inside.

	Each frame rebuilds who is in which ring and hands the whole map to
	`MobService:SetAuraSlows`, which only notifies clients of the enemies whose speed
	changed. Overlapping rings do not add up: the enemy gets the strongest.

	The radius is `getRange`, the same circle the player sees when selecting the unit,
	weather and cards included, measured flat (X and Z): the ring is drawn on the
	ground, and with a radius of a few studs the height between the unit's position and
	the enemy's would shrink the real area well below the drawn one. A Cryomancer the weather turned off or a boss stunned
	slows nobody while it lasts, like any tower that stops working.

	`HadAuraSlows` saves the sweep over every enemy on maps without a Cryomancer, while
	still letting one last empty sweep release the enemies when the last ring goes away
	(sold, stunned, or turned off).
]=]
function UnitService:stepSlowAuras(now : number, weather : string?)
	local mobService = self.Services.MobService
	if not mobService then return end

	local slows = self.AuraSlows
	table.clear(slows)

	local any = false

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		if not (stats and stats.SlowAura) then continue end

		if SharedConfig.WeatherConfig.IsDisabled(weather, entry.unitName) then continue end
		if now < (entry.StunnedUntil or 0) then continue end

		local amount = SharedConfig.UnitUpgradeConfig:GetAuraSlow(entry.unitName, entry.upgrades or 0)
		if amount <= 0 then continue end

		any = true

		local center = entry.cf.Position
		local range = self:getRange(entry, weather)
		local rangeSquared = range * range

		for mobId in mobService.ActiveMobs do
			if amount <= (slows[mobId] or 0) then continue end

			local pos = mobService:getMobPosition(mobId)
			if not pos then continue end

			local dx, dz = pos.X - center.X, pos.Z - center.Z
			if dx * dx + dz * dz <= rangeSquared then
				slows[mobId] = amount
			end
		end
	end

	if not any and not self.HadAuraSlows then return end
	self.HadAuraSlows = any

	mobService:SetAuraSlows(slows)
end

--[[ BONFIRE ]]

-- How often a Bonfire with nothing going on looks for a target. Mid-fight it never waits.
local BONFIRE_IDLE_SCAN_INTERVAL = 0.1

--[=[
	Tells clients where a Bonfire is in its life cycle: state, ramp stage, and target.

	Fired on a change only (state, stage, target, or tick interval), never per frame; the
	client draws the beam and moves it with the enemy on its own. `false` stands for "no
	target", as in `UnitSwing`, because Warp does not carry nil. `onlyPlayer` is the
	late-join resend.

	The tick interval goes along so the client can fit each loop of the stage's
	animation to whole ticks (`BonfireController`), the same idea as `UnitSwing`'s window.
]=]
function UnitService:broadcastBonfire(entry, onlyPlayer : Player?)
	local bonfire = entry.Bonfire
	if not bonfire then return end

	local mobId = bonfire.targetMobId
	if bonfire.state ~= "Fire" and bonfire.state ~= "Charge" then
		mobId = nil
	end

	local recipients = if onlyPlayer then { onlyPlayer } else Players:GetPlayers()

	for _, plr in ipairs(recipients) do
		Framework:Fire("BonfireState", plr, entry.unitId, bonfire.state, bonfire.stage or 1, mobId or false, bonfire.interval or 0)
	end
end

-- Time between damage ticks: `getCooldown`, so an attack-speed card shortens it too.
function UnitService:getBonfireInterval(entry, now : number, weather : string?) : number
	return math.max(0.05, self:getCooldown(entry, now, weather))
end

--[=[
	One frame of a burning Bonfire: the ramp, the stage, and the damage ticks.

	Damage per tick is the regular damage before rounding (`getRawDamage`: upgrades,
	weather, cards, charge), with the fraction carried between ticks, times
	the ramp factor (`GetRampMultiplier`), so every card that touches damage still
	touches this tower. The tick interval is `getCooldown`, so an attack-speed card
	shortens it too. Each tick goes through `creditDamage` (cash, aura, damage
	scoreboard) and is shown with a `MobDamageTick`, the same path the mines use for
	damage that has no swing.
]=]

function UnitService:isBonfireSpent(entry, bonfire) : boolean
	local cap = SharedConfig.UnitUpgradeConfig:GetDamageCap(entry.unitName, entry.upgrades or 0)
	return (bonfire.damageDealt or 0) >= cap
end

function UnitService:stepBonfireBeam(entry, stats, bonfire, now : number, weather : string?)
	local config = SharedConfig.UnitUpgradeConfig
	local level = entry.upgrades or 0
	local progress = config:GetRampProgress(entry.unitName, level, now - bonfire.fireStart)

	local interval = self:getBonfireInterval(entry, now, weather)
	local changed = false

	-- A new stage starts its animation on a tick: the tick clock restarts with it.
	local stage = config:GetBeamStage(entry.unitName, progress)
	if stage ~= bonfire.stage then
		bonfire.stage = stage
		bonfire.nextTick = now
		changed = true
	end

	-- Cards or weather changed the interval: the client refits the loop to it.
	if math.abs(interval - (bonfire.interval or 0)) > 0.001 then
		bonfire.interval = interval
		changed = true
	end

	if changed then
		self:broadcastBonfire(entry)
	end

	local ticks = 0

	-- Catch-up is capped: at high game speed a frame can span several ticks, but a lag
	-- spike must not turn into a burst of damage.
	while now >= bonfire.nextTick and ticks < 4 do
		ticks += 1
		bonfire.nextTick += interval

		--[[
			The fraction a tick cannot deal is carried to the next one. Ticks are small (2
			at level 0), so rounding each one would erase whole upgrades: level 1's 2.4
			would deal 2. Carried, it deals 2, 2, 3, 2, 3... and averages exactly 2.4.
		]]
		local raw = self:getRawDamage(entry, stats, weather) * config:GetRampMultiplier(entry.unitName, progress)
			+ (bonfire.carry or 0)
		local damage = math.max(1, math.floor(raw))
		bonfire.carry = math.max(0, raw - damage)

		local dealt = self:creditDamage(entry, bonfire.targetMobId, damage, self:getAuraBonus(entry, weather))
		bonfire.damageDealt = (bonfire.damageDealt or 0) + dealt

		if dealt > 0 then
			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("MobDamageTick", plr, bonfire.targetMobId, dealt)
			end
		end

		-- Cap reached: no more ticks this frame. `stepBonfire` sends it Tired next frame.
		if self:isBonfireSpent(entry, bonfire) then
			break
		end
	end

	if now >= bonfire.nextTick then
		bonfire.nextTick = now + interval
	end
end

--[=[
	Bonfire's state machine: Idle -> Charge -> Fire -> Tired -> Idle.

	Runs instead of the regular attack in `stepCombat`, and before the weather and stun
	checks: those count here as "no target", so a Bonfire that rain or a stun interrupts
	goes Tired like any other that lost its enemy instead of freezing mid-burn.

	Tired is a lock: nothing starts until `Tired.Duration` is over, even with an enemy in
	range. Losing the target while charging goes straight back to Idle (it never fired,
	so it is never tired). Replacing a dead target with another one in range keeps the
	ramp; only having nobody left in range ends it.
]=]
function UnitService:stepBonfire(entry, stats, now : number, weather : string?, disabled : boolean)
	local mobService = self.Services.MobService
	local beam = stats.Beam

	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[entry.unitName]
	local tiredDuration = attackConfig and attackConfig.Tired and attackConfig.Tired.Duration or 0
	local chargeUpTime = beam and beam.ChargeUpTime or 0

	local bonfire = entry.Bonfire
	if not bonfire then
		bonfire = {
			state = "Idle",
			stage = 1,
			untilTime = 0,
			nextScan = 0,
			nextTick = 0,
			fireStart = 0,
			targetMobId = nil,
			damageDealt = 0,
		}
		entry.Bonfire = bonfire
	end

	if bonfire.state == "Tired" then
		if now < bonfire.untilTime then return end

		-- Tired ended after hitting the damage cap: the tower is fresh again.
		if self:isBonfireSpent(entry, bonfire) then
			bonfire.damageDealt = 0
		end

		bonfire.state = "Idle"
		bonfire.targetMobId = nil
		self:broadcastBonfire(entry)
	end

	local position = entry.cf.Position
	local range = self:getRange(entry, weather)
	local canFight = not disabled
		and now >= (entry.StunnedUntil or 0)
		and mobService.ActiveMobCount > 0
		and not self:isBonfireSpent(entry, bonfire)

	local targetId = bonfire.targetMobId
	local targetValid = false

	if canFight and targetId and mobService.ActiveMobs[targetId] then
		local pos = mobService:getMobPosition(targetId)
		targetValid = pos ~= nil and (pos - position).Magnitude <= range
	end

	-- Mid-fight a lost target is replaced at once (a gap would read as "nobody left" and
	-- send it Tired); only a tower with nothing going on scans on a timer.
	if canFight and not targetValid and (bonfire.state ~= "Idle" or now >= bonfire.nextScan) then
		bonfire.nextScan = now + BONFIRE_IDLE_SCAN_INTERVAL

		local bestId = mobService:GetBestMobInRange(position, range, entry.priority)
		if bestId then
			targetId = bestId
			targetValid = true
		end
	end

	if bonfire.state == "Fire" then
		if not targetValid then
			bonfire.targetMobId = nil
			bonfire.fireStart = nil
			bonfire.stage = 1
			bonfire.state = "Tired"
			bonfire.untilTime = now + tiredDuration
			self:broadcastBonfire(entry)
			return
		end

		if targetId ~= bonfire.targetMobId then
			bonfire.targetMobId = targetId
			self:broadcastBonfire(entry)
		end

		self:stepBonfireBeam(entry, stats, bonfire, now, weather)
		return
	end

	if bonfire.state == "Charge" then
		if not targetValid then
			bonfire.targetMobId = nil
			bonfire.state = "Idle"
			self:broadcastBonfire(entry)
			return
		end

		if targetId ~= bonfire.targetMobId then
			bonfire.targetMobId = targetId
			self:broadcastBonfire(entry)
		end

		if now < bonfire.untilTime then return end
		-- Charge-up is over: falls through to start firing.
	elseif bonfire.state == "Idle" then
		if not targetValid then return end

		bonfire.targetMobId = targetId

		if chargeUpTime > 0 then
			bonfire.state = "Charge"
			bonfire.untilTime = now + chargeUpTime
			self:broadcastBonfire(entry)
			return
		end
	end

	bonfire.state = "Fire"
	bonfire.fireStart = now
	bonfire.nextTick = now
	bonfire.stage = 1
	bonfire.carry = 0
	bonfire.interval = self:getBonfireInterval(entry, now, weather)
	self:broadcastBonfire(entry)
end



function UnitService:stepCombat()
	local units = self.PlacedUnits
	local count = #units
	if count == 0 then
		-- No towers left, but a Cryomancer sold this frame still has enemies to let go.
		self:stepSlowAuras(GameClock.Now(), nil)
		return
	end

	local mobService = self.Services.MobService
	if not mobService then return end

	-- Match time, not `os.clock()`: it is the same "now" that recorded
	-- `lastAttack`, `StunnedUntil`, and the charge deadline, so speeding up the clock
	-- shortens all three together without touching any `UnitUpgradeConfig` number.
	local now = GameClock.Now()
	local scansLeft = TARGET_SCANS_PER_FRAME

	-- One read per frame, passed down: weather does not change mid
	-- loop, and querying per unit would only waste.
	local weather = self:GetWeather()

	--[[
		Cards before everything: damage, attack speed, and range read from here down
		already include what they did. One read per frame, like weather; see
		`refreshCardModifiers`.
	]]
	self:refreshCardModifiers()

	self:collectAuraSources()
	self:stepTripmines(now, weather)
	self:stepSlowAuras(now, weather)

	--[[
		The loop through the list starts with whoever was left without a scan the previous
		frame, not always at the first unit.

		A ready unit with nobody in range scans every frame, and eight of them at the start
		of the list would spend the whole budget alone: the ones after would never find a
		new target and would stand still with an enemy in front. Starting from the first one
		left out, every unit scans at most every `ceil(units / TARGET_SCANS_PER_FRAME)`
		frames.

		The cursor is an index, not the unit: selling or placing a tower midway only shifts
		the queue for one frame, and the modulo below keeps it within the list.
	]]
	local start = ((self.ScanCursor or 1) - 1) % count + 1
	local starved = nil

	for step = 0, count - 1 do
		local i = (start + step - 1) % count + 1
		local entry = units[i]
		local stats = SharedConfig.UnitStats[entry.unitName]

		-- A channeling unit (the Bonfire) runs its own state machine, and it goes before
		-- the weather check below: rain turning Fire units off has to send it Tired, not
		-- leave its beam up.
		if stats and stats.Beam then
			self:stepBonfire(entry, stats, now, weather,
				SharedConfig.WeatherConfig.IsDisabled(weather, entry.unitName))
			continue
		end

		--[[
			A unit turned off by weather does nothing in this loop: rain turns off all of
			`Fire`. It is not a stun: it has no deadline, lights no yellow highlight, and
			cannot be shortened; it comes back when the weather leaves.

			Farm income is left out because `payFarmUnits` pays it, not this loop. No farm
			today belongs to a class any weather turns off; the day one does, the rule must
			be repeated there.
		]]
		if SharedConfig.WeatherConfig.IsDisabled(weather, entry.unitName) then continue end

		if stats and stats.Farm then continue end

		-- A slow aura attacks nobody: its ring is `stepSlowAuras`, above.
		if stats and stats.SlowAura then continue end

		if stats and stats.Tripmine then
			if now >= (entry.StunnedUntil or 0) then
				self:stepTripminer(entry, stats, now, weather)
			end
			continue
		end

		if mobService.ActiveMobCount > 0
			and stats
			and now >= (entry.StunnedUntil or 0)
			and now - (entry.lastAttack or 0) >= self:getAttackDelay(entry, now, weather)
		then
			local unitPosition = entry.cf.Position
			local range = self:getRange(entry, weather)

			local targetId = entry.targetMobId
			local targetValid = false
			if targetId and mobService.ActiveMobs[targetId] then
				local pos = mobService:getMobPosition(targetId)
				targetValid = pos ~= nil and (pos - unitPosition).Magnitude <= range
			end

			--[[
				The scan happens on every attack, not only when the target leaves range:
				priority is about who is in range NOW. The weakest enemy changes with each
				hit, and the "strongest" that just entered range must steal the target from
				the one already there.

				The per-frame scan budget still rules: once exhausted, the unit keeps its
				previous target if it still works and is the first to scan next frame (see
				`ScanCursor` above).
			]]
			if scansLeft > 0 then
				scansLeft -= 1
				local bestId = mobService:GetBestMobInRange(unitPosition, range, entry.priority)
				if bestId then
					targetId = bestId
					targetValid = true
				elseif not targetValid then
					targetId = nil
				end
				entry.targetMobId = targetId
			else
				starved = starved or i

				if not targetValid then
					entry.targetMobId = nil
				end
			end

			if targetValid then
				entry.lastAttack = now
				self:executeAttack(entry, stats, targetId, weather)
			end
		end
	end

	-- Nobody was left without a scan: today's order works, and the cursor stays put.
	if starved then
		self.ScanCursor = starved
	end
end

--[=[
	How long the unit waits, since its last attack, to make the next one.

	Almost always the cooldown. The exception is the chained sequence (`ChainSequence` in
	`UnitAttackConfig`, the Archmage): mid-sequence the wait is `ChainDelay` counted from
	the start of the step that just went out (or its animation's `Duration`, if longer,
	so no step cuts the previous one), and after the last step it is its animation
	**plus** the cooldown: the cooldown counts from the end of the sequence, not the start
	of the last step.

	A sequence with no enemy in range does not advance: `stepCombat` only attacks with a
	target, and `attackStep` stays where it stopped until one appears.
]=]
function UnitService:getAttackDelay(entry, now : number, weather : string?) : number
	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[entry.unitName]
	local sequence = attackConfig and attackConfig.ChainSequence and attackConfig.AttackSequence
	local current = entry.attackStep or 0

	if not sequence or #sequence == 0 or current == 0 then
		return self:getCooldown(entry, now, weather)
	end

	local step = sequence[current]
	local animation = step and step.Duration or 0

	if current < #sequence then
		return math.max(animation, attackConfig.ChainDelay or 0)
	end

	return animation + self:getCooldown(entry, now, weather)
end

--[=[
	A unit's effective cooldown: the table's with weather, divided by any temporary
	charge it carries.

	The charge comes in outside `UnitUpgradeConfig` because it is match state (a specific
	unit that took a bolt 4 seconds ago) and the config only knows numbers that apply to
	everyone.
]=]
function UnitService:getCooldown(entry, now : number, weather : string?) : number
	local cooldown = SharedConfig.UnitUpgradeConfig:GetCooldown(entry.unitName, entry.upgrades or 0, weather)

	--[[
		The card goes in as a division, like weather: 1.15 is "hits 15% faster", that is,
		the same cycle in 1/1.15 of the time. It is here, and not in `UnitUpgradeConfig`,
		for the same reason as the lightning charge: the config only knows numbers that
		apply to everyone, and a card applies to whoever it chose.
	]]
	local cards = self:cardMultiplier(entry, "AttackSpeed")
	if cards > 0 then
		cooldown /= cards
	end

	local charge = self:chargeMultiplier(entry, "AttackSpeed", now)
	if charge <= 0 then return cooldown end

	return cooldown / charge
end

-- Damage per hit before rounding: the Bonfire carries the fraction between ticks.
function UnitService:getRawDamage(entry, stats, weather : string?) : number
	local base = stats.Damage or 0
	local multiplier = SharedConfig.UnitUpgradeConfig:GetDamageMultiplier(entry.unitName, entry.upgrades or 0, weather)
	local charge = self:chargeMultiplier(entry, "Damage", GameClock.Now())
	local cards = self:cardMultiplier(entry, "Damage")

	return base * multiplier * charge * cards
end

-- Damage per hit, with the same rounding as the config.
function UnitService:getDamage(entry, stats, weather : string?) : number
	return math.floor(self:getRawDamage(entry, stats, weather) + 0.5)
end

function UnitService:getMineLimit(entry, tripmineConfig)
	local limit = (tripmineConfig.BaseLimit or 3) + (entry.upgrades or 0) * (tripmineConfig.LimitPerUpgrade or 1)

	-- `MaxLimit` is the cap: later upgrades still count for damage.
	return math.min(limit, tripmineConfig.MaxLimit or math.huge)
end

function UnitService:getActiveMineCount(entry)
	local total = entry.pendingMines or 0
	if entry.mines then
		for _ in entry.mines do
			total += 1
		end
	end
	return total
end

function UnitService:getRandomPathPointInRange(entry, weather : string?)
	local unitPosition = entry.cf.Position
	local range = self:getRange(entry, weather)

	local step = 1
	local candidates = {}

	-- Sweeps every route: a mine can land on either side of the fork that is
	-- in range, and the trigger already tests every enemy regardless of route.
	for _, route in self.Services.MobService:getRoutes() do
		local routeSmooth = route.smooth
		if routeSmooth and routeSmooth.points and #routeSmooth.points >= 2 and routeSmooth.length > 0 then
			local d = 0
			while d <= routeSmooth.length do
				local p = PathUtil.GetPositionAtDistance(routeSmooth, d)
				if p then
					local flat = Vector3.new(p.X - unitPosition.X, 0, p.Z - unitPosition.Z)
					if flat.Magnitude <= range then
						table.insert(candidates, { smooth = routeSmooth, distance = d })
					end
				end
				d += step
			end
		end
	end

	if #candidates == 0 then return nil end

	local pick = candidates[math.random(1, #candidates)]
	local smooth = pick.smooth
	local distance = math.clamp(pick.distance + (math.random() - 0.5) * step, 0, smooth.length)

	local point = PathUtil.GetPositionAtDistance(smooth, distance)
	local ahead = PathUtil.GetPositionAtDistance(smooth, math.min(smooth.length, distance + 0.5))
	local direction = Vector3.new(ahead.X - point.X, 0, ahead.Z - point.Z)
	if direction.Magnitude < 0.001 then
		local behind = PathUtil.GetPositionAtDistance(smooth, math.max(0, distance - 0.5))
		direction = Vector3.new(point.X - behind.X, 0, point.Z - behind.Z)
	end

	local offset = Vector3.zero
	if direction.Magnitude > 0.001 then
		local perpendicular = direction.Unit:Cross(Vector3.yAxis)
		offset = perpendicular * ((math.random() - 0.5) * 2 * 1.5)
	end

	return point + offset + Vector3.new(0, 0.35, 0)
end

function UnitService:stepTripminer(entry, stats, now, weather : string?)
	local config = stats.Tripmine
	entry.mines = entry.mines or {}

	local cooldown = self:getCooldown(entry, now, weather)
	if now - (entry.lastAttack or 0) < cooldown then return end

	if self:getActiveMineCount(entry) >= self:getMineLimit(entry, config) then return end

	local position = self:getRandomPathPointInRange(entry, weather)
	if not position then return end

	entry.lastAttack = now
	entry.pendingMines = (entry.pendingMines or 0) + 1

	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[entry.unitName]
	local sequence = attackConfig and attackConfig.AttackSequence
	local windup = sequence and sequence[1] and sequence[1].HitTime or 0

	local mineId = HttpService:GenerateGUID(false)
	local yaw = math.random() * math.pi * 2
	local mineCF = CFrame.new(position) * CFrame.Angles(0, yaw, 0)

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitSwing", plr, entry.unitId, entry.unitName, false, 1, cooldown)
	end

	--[[
		The mine leaves the hand at the end of the windup and **only arms when it lands**.

		They are two instants, not one: if the mine entered `entry.mines` on the same frame
		the client started drawing the arc, it would spend the whole flight armed and
		invisible at the destination, and an enemy crossing the spot in that window would see
		the explosion come from a place with no mine yet.

		`ThrowTime` goes in the event instead of the client reading it from config: that way
		both sides spend the same number by construction, and the arc ends exactly on the
		frame the trigger arms.

		Both waits are match time (`GameClock`), like the cooldown and windup: at 3x the mine
		is thrown and lands three times faster, along with everything else.
	]]
	local throwTime = config.ThrowTime or 0

	GameClock.Delay(windup, function()
		if not self.UnitsById[entry.unitId] then
			entry.pendingMines = math.max(0, (entry.pendingMines or 1) - 1)
			return
		end

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("TripmineThrown", plr, entry.unitId, mineId, mineCF, throwTime)
		end

		GameClock.Delay(throwTime, function()
			-- The slot is only freed here: a mine in the air already counts toward the limit, or
			-- the 3s cooldown against windup plus flight would allow planting above it.
			entry.pendingMines = math.max(0, (entry.pendingMines or 1) - 1)

			if not self.UnitsById[entry.unitId] then return end

			-- `armedAt` starts the charge: see `Tripmine.Charge` and `mineChargeFactor`.
			entry.mines[mineId] = { position = position, cf = mineCF, armedAt = GameClock.Now() }
		end)
	end)
end

--[=[
	How much of its damage a mine delivers now: `StartDamage` on landing, rising linearly
	to 1 over `Charge.Time` seconds. With no `Charge` in the config the mine goes out full.
]=]
local function mineChargeFactor(mine, config, now : number) : number
	local charge = config.Charge
	if not charge or (charge.Time or 0) <= 0 then return 1 end

	local start = math.clamp(charge.StartDamage or 1, 0, 1)
	local progress = math.clamp((now - (mine.armedAt or now)) / charge.Time, 0, 1)

	return start + (1 - start) * progress
end

function UnitService:stepTripmines(now, weather : string?)
	local mobService = self.Services.MobService
	if mobService.ActiveMobCount == 0 then return end

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local config = stats and stats.Tripmine
		if config and entry.mines then
			for mineId, mine in entry.mines do
				--[[
					The stretch the enemy walked this frame, not where it stands.

					An enemy walks `CurrentSpeed * dt` per frame, and sped up that step exceeds
					the trigger's diameter: at 3x with the server at 30Hz, Nightmare's fastest
					enemy covers almost 6 studs at once and would cross the mine's 5-stud trigger
					without ever being seen inside it. With the segment, the mine explodes by
					distance, not by the luck of the frame landing on it.
				]]
				local triggeredBy = mobService:GetMobCrossing(mine.position, config.TriggerRadius or 2.5)
				if triggeredBy then
					entry.mines[mineId] = nil
					local fullDamage = self:getDamage(entry, stats, weather)
					local damage = math.floor(fullDamage * mineChargeFactor(mine, config, now) + 0.5)
					local radius = config.AOE and config.AOE.Radius or 6
					local mobsHit = mobService:GetMobsInRadius(mine.position, radius)

					-- The aura measures distance to the UNIT, not the mine: what needs to be near
					-- the farm is the tower, not the spot where it threw
					-- the explosive.
					local auraBonus = self:getAuraBonus(entry, weather)

					--[[
						The explosion has no `AttackVisual`: it is not a unit's hit, and its VFX
						already goes out in `TripmineTriggered` just below. But the number and the
						health bar must go out, which is why each hit goes as a `MobDamageTick`:
						the same path as burn ticks, which is what the client has for damage with
						no unit.

						Without this the mine would be the only damage in the game invisible to the
						bar: the client subtracts from a copy of the health (see `creditHit`), and
						what does not arrive there is never corrected: a boss stepping on a mine
						would keep that piece of bar until it died.
					]]
					local players = Players:GetPlayers()

					for _, mobId in ipairs(mobsHit) do
						local dealt = self:creditDamage(entry, mobId, damage, auraBonus)

						if dealt > 0 then
							for _, plr in ipairs(players) do
								Framework:Fire("MobDamageTick", plr, mobId, dealt)
							end
						end
					end

					for _, plr in ipairs(players) do
						Framework:Fire("TripmineTriggered", plr, entry.unitId, mineId)
					end
				end
			end
		end
	end
end

function UnitService:payFarmUnits()
	--[[
		Income is paid at the end of the wave, outside the combat loop: without this read
		it would go out with what cards were doing on the last frame someone attacked,
		which may have been before the staff's ring was drawn.
	]]
	self:refreshCardModifiers()

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local farm = stats and stats.Farm
		if farm then
			local player = Players:GetPlayerByUserId(entry.ownerUserId)
			if player then
				--[[
					No weather on purpose: farm income is not damage, and the sandstorm's 30% cut
					would change the match economy instead of combat, which is what weathers
					were made for.

					The **card**, however, does apply: the Robux Royalty ring is an economy card,
					and refusing it here would be refusing what it does.
				]]
				local income = SharedConfig.UnitUpgradeConfig:GetIncome(entry.unitName, entry.upgrades or 0)
					* self:cardMultiplier(entry, "Income")

				local amount = math.floor(income + 0.5)
				self.Services.MobService:addCash(player, amount)
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("FarmPayout", plr, entry.unitId, amount)
				end
			end
		end
	end
end

--[=[
	A sequence step with `Combo` (the Archmage): that step's attack, with the numbers from
	`UnitStats[name].Combo[step.Combo]`.

	The timings are the step's (`HitTime`, `HitEnd`), on the match clock. These steps'
	window is the animation's `Duration` (`getAttackDelay`), greater than or equal to it,
	so none is squeezed: the markers hold as they are.

	The target is whoever the unit was aiming at when the step started: the meteor's
	position, the bolt's direction, and who gets teleported come from it.
]=]
function UnitService:executeCombo(entry, unitStats, step, targetId, weather : string?)
	local combo = unitStats.Combo and unitStats.Combo[step.Combo]
	local mobService = self.Services.MobService
	if not combo or not mobService then return end

	local unitId = entry.unitId
	local unitName = entry.unitName
	local unitPosition = entry.cf.Position

	-- Frozen at the start of the step, for the same reason as a regular hit: a weather or
	-- a card that comes in midway does not change a step already started.
	local auraBonus = self:getAuraBonus(entry, weather)
	local damage = combo.Damage and self:getDamage(entry, combo, weather) or 0
	local range = self:getRange(entry, weather)

	-- Where the target was when the step started: that is where the meteor falls.
	local aimPos = targetId and mobService:getMobPosition(targetId)

	local function showHits(hits)
		if #hits == 0 then return end
		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("AttackVisual", plr, unitId, unitName, hits[1].mobId, hits)
		end
	end

	task.spawn(function()
		GameClock.Wait(step.HitTime or 0)

		if step.Combo == "Meteor" then
			if not aimPos then return end

			local fallTime = combo.FallTime or 1
			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("ArchmageMeteor", plr, unitId, aimPos, fallTime, combo.Height or 15)
			end

			-- Damage lands on impact, along with the explosion the client plays.
			GameClock.Wait(fallTime)

			local radius = SharedConfig.UnitUpgradeConfig:GetMeteorRadius(unitName, entry.upgrades or 0)
			local hits = {}
			for _, mobId in mobService:GetMobsInRadius(aimPos, radius) do
				self:creditHit(entry, hits, mobId, damage, auraBonus)
			end
			showHits(hits)
		elseif step.Combo == "Lightning" then
			-- The line locks here, at the start of the damage: where the target is now, or where
			-- it was at the start of the step if it already died.
			local through = (targetId and mobService:getMobPosition(targetId)) or aimPos
			if not through then return end

			local window = math.max(0, (step.HitEnd or step.HitTime or 0) - (step.HitTime or 0))
			local interval = math.max(0.05, combo.Interval or 0.1)
			local ticks = math.max(1, math.floor(window / interval + 1e-6))

			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("ArchmageLightning", plr, unitId, through, window)
			end

			for tick = 1, ticks do
				-- Whoever is on the line **on this** tick: an enemy entering the line in the
				-- middle of the bolt takes damage too.
				local hits = {}
				for _, mobId in mobService:GetMobsAlongLine(unitPosition, through, range, combo.Width or PIERCE_WIDTH) do
					self:creditHit(entry, hits, mobId, damage, auraBonus)
				end
				showHits(hits)

				if tick < ticks then
					GameClock.Wait(interval)
				end
			end
		elseif step.Combo == "Teleport" then
			if targetId and mobService.ActiveMobs[targetId] then
				mobService:TeleportMobBack(targetId)
			end
		end
	end)
end

function UnitService:executeAttack(entry, unitStats, initialMobId, weather : string?)
	local unitName = entry.unitName
	local unitId = entry.unitId
	local unitPosition = entry.cf.Position
	local upgradeLevel = entry.upgrades or 0

	--[[
		Damage and range are frozen here, at the start of the attack, not reread on each hit.
		A MultiShot takes almost a second from the first to the last hit, and a weather
		coming in midway would make the four hits of the same cycle come out with different
		numbers.
	]]
	local damage = self:getDamage(entry, unitStats, weather)

	-- Frozen for the same reason: the farm may be sold between the first and the
	-- last hit of a MultiShot, and the four hits of the same cycle must earn the
	-- same.
	local auraBonus = self:getAuraBonus(entry, weather)

	local aoe = unitStats.AOE

	--[[
		The piercing projectile: the attack stops being "the target" and becomes the line to
		it. Everyone on it takes the same damage, including those behind the target: the
		arrow does not stop at the first.
	]]
	local projectile = unitStats.Projectile
	local pierce = projectile and projectile.Subtype == "Piercing" and projectile or nil

	--[[
		The jumping bolt: the attack stops being "the target" and becomes the chain leaving
		from it. `MobService` builds the chain, since it owns everyone's position; here only
		each link's damage is charged and the drawing is sent.
	]]
	local chain = unitStats.Chain

	--[[
		The cleave the Cleave It To Me card turns on for melee, with its numbers inside.
		Frozen here with the damage, not reread on each hit, for the same reason: a MultiShot
		takes almost a second, and the card may expire midway.

		It only applies to units with no area, projectile, or chain: all three already hit
		more than one target on their own, and adding the cleave on top would be the same
		unit charging twice for the same idea.
	]]
	local cleave = (not aoe and not projectile and not chain) and self:cardFlag(entry, "Cleave") or nil

	local range = self:getRange(entry, weather)
	local totalHits = unitStats.Hits or 1

	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[unitName]
	local sequence = attackConfig and attackConfig.AttackSequence
	local stepIndex = 1
	local step = nil
	local windup = 0
	if sequence and #sequence > 0 then
		stepIndex = ((entry.attackStep or 0) % #sequence) + 1
		entry.attackStep = stepIndex
		step = sequence[stepIndex]
		windup = step.HitTime or 0
	end

	--[[
		The attack window goes along with the request: how much match time the unit has
		before it can attack again.

		Only the server knows that number (the table's, already through weather, upgrade,
		card, and charge), and the client needs it to fit the animation inside the attack
		(see `Unit:playAttackVisual`). Sending the raw `stats.Cooldown` would not work: an
		`AttackSpeed` card shortens the cycle and the animation must shorten with it.
	]]
	local swingWindow = self:getCooldown(entry, GameClock.Now(), weather)

	--[[
		A step with `Combo` (the Archmage) has its own path, and leaves here before
		everything that belongs to a regular attack: area, projectile, chain, hit combos.

		Its window is the animation's `Duration`, not the cooldown: in a chained sequence the
		cooldown only applies after the last step (`getAttackDelay`), and the animation must
		play whole, unsqueezed, so the markers keep matching the server's timings.
	]]
	if step and step.Combo then
		swingWindow = step.Duration or swingWindow

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("UnitSwing", plr, unitId, unitName, initialMobId, stepIndex, swingWindow)
		end

		self:executeCombo(entry, unitStats, step, initialMobId, weather)
		return
	end

	--[=[
		An attack that hits several times within the same animation, each hit at its own
		instant (`HitTimes`, in `UnitAttackConfig`) instead of spaced by `HitInterval`. The
		Berserker has this today, and its combo does not fit a regular interval: 0.83s from
		the first hit to the second and 1.12s from the second to the third.

		With the list on the step, it rules the hit count: `UnitStats`' `Hits` still exists
		for the card's DPS, and the two must stay equal (see the comment there).

		`squeeze` is the same shrink the client applies to the animation when it does not
		fit the attack window (`Unit:playAttackVisual`): both ends divide by the same factor,
		so the hit still lands on the marker's frame even with an `AttackSpeed` card
		tightening the cycle. Without it, the Berserker's last hit (2.5667s) would go out
		after the next attack had already started as soon as the window dropped below the
		animation's 2.9s. In the normal case (window larger than the animation) the factor
		is 1 and the instants are the table's.
	]=]
	local schedule = nil
	if step and step.HitTimes and #step.HitTimes > 0 then
		local duration = step.Duration or 0
		local squeeze = (swingWindow > 0 and duration > swingWindow) and (duration / swingWindow) or 1

		schedule = table.create(#step.HitTimes)
		for index, at in ipairs(step.HitTimes) do
			schedule[index] = at / squeeze
		end

		totalHits = #schedule
		windup = schedule[1]
	end

	--[=[
		How much each hit of the SAME attack is worth, as a fraction of full damage.

		The falloff is per **hit**, not per target: `PierceFalloff` discounts each body the
		arrow pierces within a single shot, this one discounts each beat of the combo, and
		whoever is in hit 2's area takes the same as whoever is in hit 1's. The two compose
		without conflict (the combo's falloff becomes the line falloff's base), though no
		current unit declares both.

		`UnitStats`' `HitFalloff` is the loss from one hit to the **next**, not the loss
		against full damage: with 0.1, the combo is worth 100%, 90%, 81%, 72.9%...
		Compounded for the same reason as the arrow: that way it never reaches zero, while
		subtracting 10 percentage points each time would make the 11th hit do nothing and
		the 12th heal the enemy.

		Damage is only rounded below, when charging, not at each falloff step: rounding at
		each would accumulate rounding error along the combo. The floor of 1 is the same as
		the rest of the file: it hit, it took health.
	]=]
	local hitFalloff = math.clamp(unitStats.HitFalloff or 0, 0, 1)

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitSwing", plr, unitId, unitName, initialMobId, stepIndex, swingWindow)
	end

	task.spawn(function()
		if windup > 0 then
			GameClock.Wait(windup)
		end

		for i = 1, totalHits do
			-- This hit's damage: the one frozen above, minus what the previous hits
			-- of the same attack already took off (see `hitFalloff`).
			local hitDamage = damage
			if hitFalloff > 0 and i > 1 then
				hitDamage = math.max(1, math.floor(damage * (1 - hitFalloff) ^ (i - 1) + 0.5))
			end

			local resolvedMobId = initialMobId
			-- The target died between two hits of the same attack: the replacement comes from
			-- the same priority, or hit 2 would go to the nearest while
			-- hit 1 went to the strongest.
			if resolvedMobId and not self.Services.MobService.ActiveMobs[resolvedMobId] then
				resolvedMobId = self.Services.MobService:GetBestMobInRange(unitPosition, range, entry.priority)
			end

			local predictedPos = resolvedMobId and self.Services.MobService:PredictPosition(resolvedMobId)

			local hits = {}
			if chain and resolvedMobId then
				--[=[
					The chain: the aimed target and the jumps from it.

					All take the **same** damage: this is the only way of hitting several
					targets in the file with no falloff at all (the arrow has `PierceFalloff`,
					the cleave has `Falloff`, the combo has `HitFalloff`). See `Chain` in
					`UnitStats`: the price is in `Targets` and the long cooldown, and that is
					where to adjust.

					The jolt does not appear here: it is the unit's `Stun`, applied by
					`creditDamage` on each link, the same path as anything a hit leaves on the
					enemy. What this block sends to the client is only the drawing, and `stun`
					goes along because the enemy's yellow highlight lasts exactly as long as it
					is stopped.
				]=]
				local mobService = self.Services.MobService
				local targets = mobService:GetChainTargets(resolvedMobId, chain.Targets, chain.Radius)

				-- The same time `creditDamage` applies, at this unit's level.
				local arc = {
					unitId = unitId,
					origin = unitPosition,
					stun = SharedConfig.UnitUpgradeConfig:GetStunDuration(entry.unitName, entry.upgrades or 0),
					targets = {},
				}

				for _, targetId in targets do
					--[[
						The position **before** the damage: the hit may take the enemy down, and a
						removed enemy has no position to give. Without this the bolt would lack its
						tip exactly on the one it killed.
					]]
					table.insert(arc.targets, {
						mobId = targetId,
						position = mobService:getMobPosition(targetId),
					})

					self:creditHit(entry, hits, targetId, hitDamage, auraBonus)
				end

				--[[
					The bolt goes out from here, not the client: this line runs at the instant of
					the `Hit` marker (`UnitAttackConfig`'s `HitTime` is this `task.spawn`'s
					windup), and the chain it draws is the same one that just dealt damage.
					Letting the client choose the targets would put the drawing on enemies that
					took nothing.
				]]
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("ChainLightning", plr, arc)
				end
			elseif aoe then
				local aoeCenter = predictedPos or unitPosition
				local mobsInRadius = self.Services.MobService:GetMobsInRadius(aoeCenter, aoe.Radius)
				for _, targetId in ipairs(mobsInRadius) do
					self:creditHit(entry, hits, targetId, hitDamage, auraBonus)
				end
				if #hits == 0 and resolvedMobId then
					self:creditHit(entry, hits, resolvedMobId, hitDamage, auraBonus)
				end
			elseif pierce and resolvedMobId then
				--[[
					The line leaves the unit, passes where the target will be, and continues to
					its **range**, not to the target. Stopping at the target would make the arrow
					pierce and hurt nobody on the other side, which is exactly what the unit
					sells.

					The aim is the predicted position, the same the client used to draw the
					shot: aiming where the enemy is now would put the line behind it. With no
					prediction (the enemy spawned this frame and has no path walked yet), there
					is no line to trace and the attack falls to the single target, below.
				]]
				local along = predictedPos and self.Services.MobService:GetMobsAlongLine(
					unitPosition, predictedPos, range, pierce.PierceWidth or PIERCE_WIDTH
				) or {}

				--[[
					The arrow loses strength with each body it pierces.

					The falloff **compounds**, not subtracted from full damage: with 10%, the
					second enemy takes 90% of the first, the third 90% of the second, and so on.
					Compounded it never reaches zero (an arrow that pierced ten enemies still
					hurts a little), while subtracting 10 percentage points each time would make
					the 11th take nothing and the 12th take negative damage.

					Rounding is the same as `getDamage`, and the floor of 1 exists so the end of
					the queue does not become a floating "0" on screen: it hit, it took health.
				]]
				local falloff = math.clamp(pierce.PierceFalloff or 0, 0, 1)

				for index, targetId in ipairs(along) do
					local scaled = hitDamage
					if falloff > 0 and index > 1 then
						scaled = math.max(1, math.floor(hitDamage * (1 - falloff) ^ (index - 1) + 0.5))
					end

					self:creditHit(entry, hits, targetId, scaled, auraBonus)
				end

				-- The target left the line between aim and shot (it turned a corner
				-- during the windup): it takes the shot anyway, or the whole attack
				-- would be lost because of a turn.
				if #hits == 0 then
					self:creditHit(entry, hits, resolvedMobId, hitDamage, auraBonus)
				end
			elseif cleave and resolvedMobId and predictedPos then
				--[[
					Cleave It To Me's cleave: the attack stops being worth per target and becomes
					worth per **queue**, like the Archer's arrow, but short. The line leaves the
					unit, passes where the target will be, and stops at its range, and only the
					first `Targets` in the queue take damage.

					The cap exists because melee is not a projectile: "those behind the target"
					are one or two enemies right behind, not the whole column. Without it, a
					well-placed Sword on a map that lines enemies up would clear the wave alone.
				]]
				local line = self.Services.MobService:GetMobsAlongLine(
					unitPosition, predictedPos, range, cleave.Width or PIERCE_WIDTH
				)

				local falloff = math.clamp(cleave.Falloff or 0, 0, 1)
				local limit = math.max(1, cleave.Targets or 1)

				for index, targetId in ipairs(line) do
					if index > limit then break end

					local scaled = hitDamage
					if falloff > 0 and index > 1 then
						-- The same rounding and floor of 1 as the arrow: it hit,
						-- it took health, and the end of the queue does not become a floating "0" on screen.
						scaled = math.max(1, math.floor(hitDamage * (1 - falloff) ^ (index - 1) + 0.5))
					end

					self:creditHit(entry, hits, targetId, scaled, auraBonus)
				end

				-- The target left the line between aim and hit: it takes it anyway, or
				-- a turn in the path would cancel the whole attack.
				if #hits == 0 then
					self:creditHit(entry, hits, resolvedMobId, hitDamage, auraBonus)
				end
			elseif resolvedMobId then
				self:creditHit(entry, hits, resolvedMobId, hitDamage, auraBonus)
			end

			local visualMobId = resolvedMobId or initialMobId
			if visualMobId then
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("AttackVisual", plr, unitId, unitName, visualMobId, hits)
				end
			end

			if i < totalHits then
				-- With `HitTimes`, the interval is the distance between two instants in the
				-- list; without it, `UnitStats`' regular `HitInterval`.
				GameClock.Wait(schedule and (schedule[i + 1] - schedule[i]) or unitStats.HitInterval)
			end
		end
	end)
end

function UnitService:getUnitNameById(unitId)
	local entry = self.UnitsById[unitId]
	return entry and entry.unitName or nil
end

function UnitService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	local waveService = self.Services.WaveService
	if waveService and waveService.Signals and waveService.Signals.Ended then
		waveService.Signals.Ended:Connect(function()
			if waveService.GameOver then return end
			self:payFarmUnits()
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		self:initPlayerCards(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:initPlayerCards(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.SessionCards[player.UserId] = nil
		self.SessionCardMax[player.UserId] = nil
	end)

	self:construct()
end

function UnitService:init()

end

return UnitService
