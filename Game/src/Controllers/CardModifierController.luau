local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("CardModifierController")

local CardModifier = SharedConfig.CardModifier
local RoundCardConfig = SharedConfig.RoundCardConfig
local RINGS = RoundCardConfig.Rings

--[=[
	The client side of the rules round cards left on the field.

	The server rules: it keeps the list, prunes what expired, and charges damage by it.
	This controller exists for the two things that **only** show on screen:

	1. **The ring on the ground.** An area card leaves a circle where its rule applies,
	   and the drawing is that card's art (`Assets.VFX.Rings`, picked by its `Ring` in
	   the config). Without it, the card's whole decision (where to put the ring) would
	   become invisible a second after it was made.

	   The ring appears where the player clicked, with the **same radius** they saw
	   while aiming, and lives as long as the effect: until the end of the round for
	   zone staffs, and the immunity seconds for the Staff of Healing. The same zone
	   replicated by the server rules both, so a player joining mid-match sees what is
	   already on the ground.
	2. **The real range.** The Staff of the Winds gives 1.2x range to bow units. The
	   circle the player sees when selecting the tower and the number on the card come
	   from `UnitUpgradeConfig`, which knows nothing of cards, so the multiplication
	   goes through here, through the **same** function the server uses
	   (`CardModifier`), and not through a second computation that could diverge.

	It decides nothing. A list that has not arrived (the player just joined) is an
	empty list: the screen shows the table range, which is what it always showed.

	See docs/game/round-cards.md.
]=]
local CardModifierController = {
	Controllers = {
		UnitPlacementController = {},
		UILibraryController = {},
		BaseHealthController = {},
	},

	--- The list the server sent last.
	Modifiers = {},
}

--[[ INTERNAL ]]

--[=[
	The field as `CardModifier` sees it, built from what the client has: the unit
	models `UnitPlacementController` drew.

	Rebuilt on every question, not maintained: there is no state here to invalidate
	when a tower enters, leaves, or moves, and the list is short.

	> Callers doing a sweep (`WeatherFeedbackController`, which repaints every unit at
	> once) should build it **once** and pass it along. It is the same for all of them,
	> and rebuilding it per tower would turn the sweep into a quadratic loop.
]=]
function CardModifierController:GetWorld()
	local placement = self.Controllers.UnitPlacementController
	local classes = placement and placement.createdClasses

	local units = {}

	if classes then
		for model, class in classes do
			if not model.Parent or not class then continue end

			table.insert(units, {
				UnitId = class.unitId,
				UnitName = model.Name,
				Position = model:GetPivot().Position,
			})
		end
	end

	local base = self.Controllers.BaseHealthController

	return {
		Units = units,

		--[[
			Base health as a fraction. `No Pain, No Gain` depends on it, and the client only
			has it after the first `UpdateBaseHealth`; without it `CardModifier` leaves the
			modifier out, which is the right side to err on: showing the number without
			the bonus beats promising a bonus the server is not granting.
		]]
		BaseHealthRatio = base and base:GetHealthRatio() or nil,
	}
end

--[[ THE RINGS ON THE GROUND ]]

--[=[
	Where the rings live in the world: their own folder in the Workspace.

	Not in `workspace.CurrentCamera`, which is where the rest of this game's screen
	drawings live (the range circle, the dotted line, the mine in the air). Those live
	for seconds; a staff's ring lives the whole round, and the Camera is not a safe
	place for that: it is recreated in some situations and takes its children with it.

	The folder is local, not replicated: each client draws its own from the list the
	server sends. It is created with the first area card used in the match.
]=]
function CardModifierController:_ringContainer() : Instance
	local existing = workspace:FindFirstChild(RINGS.Container)
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = RINGS.Container
	folder.Parent = workspace

	return folder
end

--[=[
	The ground rings folder, found once.

	`false` means "already looked and did not find it": without it the lookup (and the
	warning) would repeat on every card used.
]=]
function CardModifierController:_ringFolder() : Instance?
	if self.RingFolder ~= nil then
		return self.RingFolder or nil
	end

	local current : Instance? = Assets
	for _, name in RINGS.Path do
		current = current and current:FindFirstChild(name)
	end

	if not current then
		log:StudioWarn(`could not find Assets.{table.concat(RINGS.Path, ".")}; area cards will have no ring on the ground.`)
		self.RingFolder = false
		return nil
	end

	self.RingFolder = current
	return current
end

--[=[
	This card's ring Model, or the default when it declares none.

	A new area card shows up on the ground without its own art, with a Studio-only
	warning: a generic ring beats no drawn zone at all, because the zone exists anyway
	and affects the towers inside it.
]=]
function CardModifierController:_ringTemplate(cardId : any) : Model?
	local folder = self:_ringFolder()
	if not folder then return nil end

	local definition = RoundCardConfig.Get(cardId)
	local name = definition and definition.Ring or RINGS.Default

	local template = folder:FindFirstChild(name) or folder:FindFirstChild(RINGS.Default)

	if not template or not template:IsA("Model") then
		if not self.WarnedRings[name] then
			self.WarnedRings[name] = true
			log:StudioWarn(`could not find ring '{name}' (nor '{RINGS.Default}') in Assets.{table.concat(RINGS.Path, ".")}.`)
		end

		return nil
	end

	return template
end

--[=[
	The scale that gives this ring the requested radius.

	The ruler is the `<name>_Ring` Part inside the Model, not its box: a VFX Model has
	emitters and attachments scattered around, and measuring the whole box would shrink
	the ring just because someone dragged a spark outside it.
]=]
function CardModifierController:_ringScale(ring : Model, radius : number) : number
	local part = ring:FindFirstChild(ring.Name .. RINGS.PartSuffix, true)

	if not part or not part:IsA("BasePart") or part.Size.X <= 0 then
		if not self.WarnedRings[ring.Name] then
			self.WarnedRings[ring.Name] = true
			log:StudioWarn(`ring '{ring.Name}' has no '{ring.Name}{RINGS.PartSuffix}' Part; its radius will be wrong.`)
		end

		return ring:GetScale()
	end

	return ring:GetScale() * (radius * 2) / part.Size.X
end

--[=[
	Draws a ring on the ground for each zone in the list.

	The rings are rebuilt entirely on each new list, not reconciled one by one. There
	are few (a full match has two or three) and the list arrives whole from the server:
	matching zone by zone would need its own bookkeeping to save a clone nobody
	notices.

	The ring grows from nothing to its size. It is the same gesture as the selected
	unit's range circle, and serves the same purpose: saying the drawing **just**
	appeared, instead of always having been there.

	The radius is the same the player saw while aiming: it comes from the
	`Zone.Radius` the server stored, which is the card's `Params.Radius`. The ring they
	aimed is the ring that stayed.
]=]
function CardModifierController:_drawZones()
	self.ZoneMaid:DoCleaning()

	for _, modifier in self.Modifiers do
		local zone = modifier.Zone
		if not zone or not zone.Position then continue end

		--[[
			One zone per card used, not per record: the staffs create two records (who
			they favor and who pays the toll) in the **same** zone, and two exactly
			overlapping rings would only paint the edge twice.
		]]
		if self.DrawnZones[modifier.Uid] then continue end
		self.DrawnZones[modifier.Uid] = true

		local template = self:_ringTemplate(modifier.Card)
		if not template then continue end

		local ring = template:Clone()

		--[[
			The ring is scenery, and needs three things before entering the world.

			**`Anchored` is the one that must not be missing.** The Models in
			`Assets.VFX.Rings` come from Studio with loose Parts, and the Workspace
			simulates everything inside it, including what hangs from the Camera. A loose
			Part falls, passes `FallenPartsDestroyHeight` about two seconds later, and
			**Roblox destroys the ring**: it appears in the right place and vanishes on its
			own, with no error in the log. Anchoring here, not in the asset, is what keeps
			a new ring drawn by someone else from bringing the problem back.

			The other two are about staying out of the way: it must not eat the ray that
			looks for the ground under the cursor (or aiming the next card over it would
			hit the ring itself), nor push anything.
		]]
		for _, descendant in ring:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
			end
		end

		local scale = self:_ringScale(ring, zone.Radius or 0)
		local center = CFrame.new(zone.Position)

		ring:ScaleTo(0.001)
		ring:PivotTo(center)
		ring.Parent = self:_ringContainer()

		self.ZoneMaid:GiveTask(ring)

		local grow = Instance.new("NumberValue")
		grow.Value = 0.001
		grow.Changed:Connect(function(value)
			if ring.Parent then
				ring:ScaleTo(value)
			end
		end)

		local tween = TweenService:Create(
			grow,
			TweenInfo.new(RINGS.Grow, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Value = scale }
		)

		self.ZoneMaid:GiveTask(function()
			tween:Cancel()
			grow:Destroy()
		end)

		tween:Play()
	end
end

--[[ API ]]

--[=[
	A stat's card multiplier for a unit, the way the server computes it.

	`unitId` can be nil (a unit that has not replicated yet, the placement ghost), and
	in that case only modifiers that do not depend on which unit it is (class, zone,
	condition) apply. That is what makes the ghost show, from the start, the range the
	tower will have when placed inside the ring.
]=]
function CardModifierController:Multiplier(stat : string, unitName : string?, position : Vector3?, unitId : string?) : number
	if #self.Modifiers == 0 then return 1 end

	local unit = { UnitId = unitId, UnitName = unitName, Position = position }

	return CardModifier.Multiplier(self.Modifiers, stat, unit, self:GetWorld())
end

--[=[
	An area of **this** player that a ring of radius `radius` at `position` would
	touch, or `nil` if the spot is free.

	It is the same math as `CardModifierService:FindZoneOverlap`, on purpose: the
	server refuses the use by its math, and aiming paints red by this one. Both read the
	same replicated list, so what the player sees before clicking is what the server
	will answer; if they diverged, there would be a green spot where the click does not
	count.

	There is no deadline pruning here: the server expires the zone, and the list
	arrives rebuilt on every change. A zone that expired on the last frame paints red
	for an extra instant, never the reverse: the error falls on the safe side.
]=]
function CardModifierController:FindZoneOverlap(position : Vector3, radius : number)
	if typeof(position) ~= "Vector3" or typeof(radius) ~= "number" then return nil end

	local userId = Players.LocalPlayer and Players.LocalPlayer.UserId

	for _, modifier in self.Modifiers do
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

--[[ LIFECYCLE ]]

function CardModifierController:construct()
	Framework:Listen("RoundCardModifiers", function(list)
		self.Modifiers = if typeof(list) == "table" then list else {}

		table.clear(self.DrawnZones)
		self:_drawZones()

		--[=[
			The range changed under the player, and neither the circle nor the card
			redraws on its own: it is the same pair a weather change already redrew (see
			`WeatherChanged` in `UnitPlacementController`).
		]=]
		local placement = self.Controllers.UnitPlacementController
		if placement then
			placement:resizeSelectionRing()
		end

		local library = self.Controllers.UILibraryController
		if library then
			library:doComponent("ToggleTower", "refresh")
		end
	end)

	--[[
		The round restarted: the previous round's rings must not stay on the ground. The
		server sends the empty list too, but `RoundRestarted` arrives first and clears
		the screen without waiting for the network.
	]]
	Framework:Listen("RoundRestarted", function()
		self.Modifiers = {}
		table.clear(self.DrawnZones)
		self.ZoneMaid:DoCleaning()
	end)

end

function CardModifierController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	-- What was already on the field when this client loaded. In `start`, not in
	-- `construct`: the request only makes sense once the `Listen`s are up, and its
	-- identifier is created on the server (see docs/architecture/me-framework.md).
	Framework:Fire("RequestRoundCardModifiers")
end

function CardModifierController:init()
	self.ZoneMaid = Maid.new()

	-- One ring per card use. See `_drawZones`.
	self.DrawnZones = {}

	-- Missing ring warning, once per name: the list is redrawn on every card used,
	-- and without this a missing Model would clog the output.
	self.WarnedRings = {}

	self:construct()
end

return CardModifierController
