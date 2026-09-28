local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Utils = Shared:WaitForChild("Util")

local PlacementUtil = require(Utils.PlacementUtil)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("CollisionService")

--[[
	How parts take part in collision and queries.

	Two things live here: the place's collision groups (the placement ghost's and
	player characters', and the pair between them is why the second exists: the ghost
	pushes nobody, and nobody pushes the ghost) and accessories' `CanQuery`, which is
	turned off for a related reason, below.

	**Why it needs a service.** `RegisterCollisionGroup` only runs on the server, and
	the ghost is a client model: `UnitPlacementController` knows how to put parts in
	the group, but not how to create it. Registration replicates to everyone, so it
	only needs to happen once, at boot.

	**Why the ghost needs a group.** The unit rig is R6 and the Humanoid must stay
	(without it the Highlight does not render on a transparent part, which is how the
	player sees whether a spot is valid). But the Humanoid rules a character's
	collision: when evaluating a new state it turns the torso's `CanCollide` back on,
	and the ghost starts pushing the player. Disabling the state machine fixes it
	incidentally; the group fixes it by definition: a part in a group that collides
	with nothing collides with nothing, whatever the Humanoid does.

	`UnitPlacementController` still does both: together they cost a line each, and the
	second is the fallback if registration here fails.

	**Why the character needs a group too.** The ghost already did not collide with
	`Default`, where the character lived, but only incidentally, not by contract: it
	followed from the loop that declares the ghost non-collidable with everything.
	With its own group, "the character does not bump into the ghost" becomes a named
	pair, and every BasePart on both sides is in it. The character still takes part in
	everything else as before: the map, placed units, and other characters.

	**Why accessories leave queries.** Collision groups solve physics, and accessories
	were never a physics problem: their problem is being a *queryable* part that sticks
	out meters past the body. Hats and wings entered placement's `GetPartsInPart` and
	refused spots that are empty on screen. Every part of every accessory of every
	character loses `CanQuery`, and the rule applies to every query in the game, not
	only those that remember to filter accessories by hand.

	No current query needs to see accessories: `FindBlockingCharacter` already skipped
	them on purpose, and the rest (footstep ground, enemy aiming, unit range) never
	looked at them.

	See docs/game/unit-placement.md.
]]

local CollisionService = {
	Services = {}
}

--[[ API ]]

--[=[
	Registers the groups and declares the ghost non-collidable with all of them,
	including `Default`, where the rest of the game lives, the characters' group, and
	itself, so two ghosts do not bump into each other.

	A new group starts out colliding with every existing one, so the loop runs over
	the whole list, and that is why the character group is registered **before** it.
	Registering a group after the loop would leave it out, colliding with the ghost;
	that is what would happen to any new group added from now on, and this function is
	where to look when it does.
]=]
function CollisionService:RegisterGroups()
	local ghost = PlacementUtil.GhostCollisionGroup

	for _, group in { PlacementUtil.CharacterCollisionGroup, ghost } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end

	-- Lowercase `name`: that is how `GetRegisteredCollisionGroups` returns it.
	for _, registered in PhysicsService:GetRegisteredCollisionGroups() do
		PhysicsService:CollisionGroupSetCollidable(ghost, registered.name, false)
	end
end

--[=[
	Prepares the character's parts: **every BasePart** goes into its group, and an
	accessory's part also loses `CanQuery`.

	`FindFirstAncestorOfClass("Accessory")` is the same question
	`FindBlockingCharacter` asks to skip accessories; the difference is that here it is
	asked once, on the part, instead of on every query.

	`DescendantAdded` stays connected because the character does not arrive complete:
	accessories come in after `CharacterAdded` (which `CharacterAppearanceLoaded`
	announces), and a tool equipped mid-match also becomes a BasePart inside the model.
	Without the signal, the hat would stay in `Default`, bumping into the ghost and
	showing up in queries, exactly the cases that motivated both. The signal arrives
	after the part is in place, so the ancestry question answers correctly.

	The connection dies with the character: respawn destroys the old model, and
	`Destroy` disconnects its signals.
]=]
function CollisionService:ApplyCharacterParts(character : Model)
	local group = PlacementUtil.CharacterCollisionGroup

	local function apply(instance : Instance)
		if not instance:IsA("BasePart") then return end

		instance.CollisionGroup = group

		if instance:FindFirstAncestorOfClass("Accessory") then
			instance.CanQuery = false
		end
	end

	for _, descendant in character:GetDescendants() do
		apply(descendant)
	end

	character.DescendantAdded:Connect(apply)
end

--[=[
	Applies the above to players already on the server and to those who arrive later.

	`player.Character` is read along with `CharacterAdded` on purpose: the service may
	start with the character already in the Workspace (a Studio reload, a `start` after
	the first spawn), and then the signal alone would only catch the next respawn.
]=]
function CollisionService:trackPlayer(player : Player)
	player.CharacterAdded:Connect(function(character)
		self:ApplyCharacterParts(character)
	end)

	local character = player.Character
	if character then
		self:ApplyCharacterParts(character)
	end
end

--[[ LIFECYCLE ]]

function CollisionService:construct()
	local ok, err = pcall(function()
		self:RegisterGroups()
	end)

	if not ok then
		-- The ghost is not left defenseless: `CanCollide = false` and the disabled state
		-- machine still apply on the client. But the reason must show up, because the
		-- symptom (the ghost pushing the player) is far from here.
		log:Warn(`could not register the collision groups: {err}`)
		return
	end

	--[[
		Only after registration: a `CollisionGroup` with an unregistered name errors,
		and erroring here would leave the character half done: part in the new group,
		part in `Default`.
	]]
	for _, player in Players:GetPlayers() do
		self:trackPlayer(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:trackPlayer(player)
	end)
end

function CollisionService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end
end

function CollisionService:init()
	self:construct()
end

return CollisionService
