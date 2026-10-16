local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("ArrowController")

local Config = SharedConfig.IndicatorArrowConfig

local TAU = math.pi * 2

-- Turns the downward arrow so its tip faces forward and its face points up.
local LAY_FLAT = CFrame.Angles(math.pi / 2, 0, 0)

--[[
	The arrow that points at a place in the world.

		local Arrow = Framework:Get("ArrowController")

		local arrow = Arrow:Point(unit.Position)
		arrow:MoveTo(otherPosition)
		arrow:Destroy()

	The model is `Shared.Assets.VFX.IndicatorArrow`: a downward arrow, built in the
	place (`Shared.Assets` is not synced by Rojo) and already configured there:
	anchored, welded parts with no collision, query, or touch.

	**Two kinds of arrow.** `Point` hangs over the target, spinning and bobbing.
	`Guide` lies flat beside something that moves (the player) and points from it
	towards the target, nudging forward; it hides once that thing is close enough
	(`Guide.HideWithin`).

	**Height is measured, not assumed.** The controller measures, once, the distance
	from the model's pivot to its bottom tip, and that measurement is what makes
	`Height` mean "gap between the tip and the target" instead of "gap to a pivot that
	happens to be somewhere". Today the pivot is at the tip and the whole arrow sits
	above it; tomorrow someone sets a `PrimaryPart` (which moves the pivot to the
	middle of the chosen part) or drags the pivot in Studio, and the arrow still
	points at the same place.

	The arrow **spins** around its own axis and **bobs** on a sine wave. Each one
	starts at a different phase: two arrows on screen bobbing in sync look like one
	thing blinking, and out of sync they look like two.

	**One connection for all.** The animation loop starts when the first arrow
	appears and stops when the last one leaves: there is no `RenderStepped` per
	arrow, and none running idle with an empty screen.

	**The template is checked, not repaired.** The properties an indicator arrow
	needs (anchored, no collision, no query, no touch) are already on the model; the
	controller rewrites them **once** on a template kept outside the tree, because a
	model coming back from Studio without them would drop the arrow to the ground or
	put it in an aiming `Raycast`, and ensuring it costs four writes per session, not
	four per arrow.

	It lives in `common/` because both places have the model, and both have things
	to point at.

	See docs/common/ui-guidance.md.
]]

local ArrowController = {
	Controllers = {}
}

-- The prepared template, outside the tree. Nil until the first arrow.
ArrowController.Template = nil :: Model?

-- The distance from the template's pivot to its bottom tip, measured once. See
-- `measureBottom`.
ArrowController.PivotToBottom = 0

ArrowController.Container = nil :: Folder?

-- The live arrows. This list is what starts and stops the animation loop.
ArrowController.Arrows = {}

ArrowController.Connection = nil :: RBXScriptConnection?

-- One phase per arrow, so they do not bob together.
ArrowController.Spawned = 0

ArrowController.Warned = false

--[[ HANDLE ]]

--[=[
	An arrow in the world. The caller holds this and dismisses it when no longer
	needed.
]=]
local Arrow = {}
Arrow.__index = Arrow

export type Options = {
	-- Gap between the arrow's tip and the target, in studs. For a guide: studs
	-- above the origin.
	Height : number?,

	-- Turns per second. Ignored by a guide.
	Spin : number?,

	-- Studs up and down, and cycles per second. For a guide: the push towards
	-- the target.
	Amplitude : number?,
	BobSpeed : number?,

	-- Size on top of the authored one.
	Scale : number?,

	-- Guide only: studs from the origin to the tip, and how close the origin gets
	-- before the arrow hides.
	Distance : number?,
	HideWithin : number?,
}

export type Arrow = typeof(setmetatable(
	{} :: {
		Model : Model,
		Target : Vector3,
		Options : Options,
		PivotToBottom : number,
		Phase : number,
		Alive : boolean,
		Origin : (() -> Vector3?)?,
		Parts : { BasePart },
		Hidden : boolean,
	},
	Arrow
))

--[=[
	Sends the arrow somewhere else. It is what an arrow following something calls at
	every step: the animation continues where it was, without restarting the spin.
]=]
function Arrow:MoveTo(position : Vector3) : Arrow
	if self.Alive then
		self.Target = position
	end

	return self
end

function Arrow:GetPosition() : Vector3
	return self.Target
end

function Arrow:IsAlive() : boolean
	return self.Alive
end

function Arrow:Destroy()
	if not self.Alive then return end

	self.Alive = false
	ArrowController:forget(self)

	self.Model:Destroy()
end

--[[ INTERNAL ]]

--[=[
	The original model, if this place has it.

	The warning happens only once: an arrow requested in a loop must not turn into a
	thousand output lines because a model is missing.
]=]
function ArrowController:source() : Model?
	local current : Instance = Shared

	for _, name in Config.Asset.Path do
		local found = current:FindFirstChild(name)
		if not found then
			self:warnMissing()

			return nil
		end

		current = found
	end

	local model = current:FindFirstChild(Config.Asset.Name)
	if not model or not model:IsA("Model") then
		self:warnMissing()

		return nil
	end

	return model
end

function ArrowController:warnMissing()
	if self.Warned then return end

	self.Warned = true
	log:StudioWarn(`could not find the model "{Config.Asset.Name}" in Shared.{table.concat(Config.Asset.Path, ".")}.`)
end

--[=[
	The template: a checked copy, kept outside the tree.

	The model already comes with all of this set correctly. The rewrite stays here
	because it is the difference between "the arrow works" and "the arrow falls to
	the ground": the model is authored in Studio, outside git, and a new copy that
	arrives unanchored or with collision becomes a runtime bug: a loose part falling,
	the arrow showing up in an aiming `Raycast`, a trap's `Touched` firing for
	nothing.

	`pivotToBottom` is the measurement that makes the config's `Height` mean what it
	says: the vertical distance from the pivot to the bottom tip, whatever it is.
]=]
function ArrowController:template() : Model?
	local template = self.Template
	if template then
		return template
	end

	local source = self:source()
	if not source then
		return nil
	end

	template = source:Clone()

	for _, descendant in template:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end

	self.Template = template
	self.PivotToBottom = self:measureBottom(template)

	return template
end

--[=[
	How far the model's pivot is above its bottom tip.

	Today it is **negative**: the pivot was left at the tip and the whole arrow sits
	above it, so the tip is about one stud *above* the pivot. Setting a
	`PrimaryPart` would change that at once (the pivot would become the center of the
	chosen part, six studs above the tip), which is exactly why this number is
	measured and not written in the config.

	Measured with the model at rest, unrotated: the arrow only spins around its own Y
	axis, and a Y spin does not change height.
]=]
function ArrowController:measureBottom(model : Model) : number
	local center, size = model:GetBoundingBox()

	return model:GetPivot().Position.Y - (center.Position.Y - size.Y / 2)
end

--[=[
	The folder where arrows live, created with the first one.

	Outside `Workspace.Map`, which `MapService` swaps between matches: an arrow hung
	there would vanish mid-pointing without anyone asking.
]=]
function ArrowController:container() : Folder
	local container = self.Container
	if container and container.Parent then
		return container
	end

	local existing = workspace:FindFirstChild(Config.Container)
	if existing and existing:IsA("Folder") then
		self.Container = existing

		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = Config.Container
	folder.Parent = workspace

	self.Container = folder

	return folder
end

--[=[
	Shows or hides an arrow without destroying it, through
	`LocalTransparencyModifier` so the authored transparency is left alone.
]=]
function ArrowController:setHidden(arrow : Arrow, hidden : boolean)
	if arrow.Hidden == hidden then return end

	arrow.Hidden = hidden

	for _, part in arrow.Parts do
		part.LocalTransparencyModifier = if hidden then 1 else 0
	end
end

--[=[
	Places a guide arrow: flat, a few studs from the origin, its tip towards the
	target, nudging back and forth. Only the horizontal direction counts, so the
	arrow stays level when the target is higher or lower than the player.

	The tip lands on the computed spot the same way `place` does it: the pivot is
	offset by the template's measurement, now along the pointing direction.
]=]
function ArrowController:placeGuide(arrow : Arrow, clock : number)
	local guide = Config.Guide
	local options = arrow.Options

	local origin = arrow.Origin and arrow.Origin()
	local flat = origin and Vector3.new(arrow.Target.X - origin.X, 0, arrow.Target.Z - origin.Z)
	local hideWithin = options.HideWithin or guide.HideWithin

	if not origin or not flat or flat.Magnitude <= hideWithin then
		self:setHidden(arrow, true)
		return
	end

	self:setHidden(arrow, false)

	local direction = flat.Unit
	local distance = options.Distance or guide.Distance
	local height = options.Height or guide.Height
	local amplitude = options.Amplitude or guide.Push.Amplitude
	local speed = options.BobSpeed or guide.Push.Speed

	local push = math.sin((clock + arrow.Phase) * speed * TAU) * amplitude

	local tip = origin + direction * (distance + push) + Vector3.new(0, height, 0)
	local pivot = tip - direction * arrow.PivotToBottom

	arrow.Model:PivotTo(CFrame.lookAt(pivot, pivot + direction) * LAY_FLAT)
end

--[=[
	Places an arrow where it must be **at this instant**.

	`PivotTo` because the model has no `PrimaryPart`, and it does not need one: the
	pivot is moved to where the **tip** must be, using the template's measurement.
	That is what makes `Height` mean "this gap between the tip and the target", in
	studs, wherever the pivot is.
]=]
function ArrowController:place(arrow : Arrow, clock : number)
	if arrow.Origin then
		self:placeGuide(arrow, clock)
		return
	end

	local options = arrow.Options
	local motion = Config.Motion

	local height = options.Height or motion.Height
	local amplitude = options.Amplitude or motion.Bob.Amplitude
	local bobSpeed = options.BobSpeed or motion.Bob.Speed
	local spin = options.Spin or motion.Spin

	local time = clock + arrow.Phase
	local bob = math.sin(time * bobSpeed * TAU) * amplitude

	arrow.Model:PivotTo(
		CFrame.new(arrow.Target + Vector3.new(0, height + bob + arrow.PivotToBottom, 0))
			* CFrame.Angles(0, time * spin * TAU, 0)
	)
end

--[=[
	Starts the animation loop, if it is not running yet.
]=]
function ArrowController:play()
	if self.Connection then return end

	self.Connection = RunService.RenderStepped:Connect(function()
		local clock = os.clock()

		for arrow in self.Arrows do
			self:place(arrow, clock)
		end
	end)
end

--[=[
	Removes the arrow from the list and stops the loop when the last one leaves. A
	`RenderStepped` running for a screen with no arrows is the kind of thing nobody
	sees and everybody pays for.
]=]
function ArrowController:forget(arrow : Arrow)
	self.Arrows[arrow] = nil

	if next(self.Arrows) then return end

	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end
end

--[=[
	Builds an arrow of either kind and puts it on screen. `origin` makes it a
	guide; without it, it hangs over the target.
]=]
function ArrowController:spawn(position : Vector3, options : Options?, origin : (() -> Vector3?)?, defaultScale : number) : Arrow?
	local template = self:template()
	if not template then
		return nil
	end

	local model = template:Clone()

	local scale = (options and options.Scale) or defaultScale
	if scale ~= 1 then
		model:ScaleTo(scale)
	end

	-- The template's measurement applies to the template's size: a smaller arrow has
	-- its tip closer to the pivot, in the same proportion.
	local pivotToBottom = self.PivotToBottom * scale

	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	self.Spawned += 1

	local arrow = setmetatable({
		Model = model,
		Target = position,
		Options = options or {},
		PivotToBottom = pivotToBottom,

		-- Half a turn of offset between one arrow and the next: two bobbing together
		-- look like one thing blinking.
		Phase = self.Spawned * 0.5,

		Alive = true,
		Origin = origin,
		Parts = parts,
		Hidden = false,
	}, Arrow)

	-- Positioned before entering the screen: without this it appears where the model
	-- was saved, and only on the next frame jumps to the target.
	self:place(arrow, os.clock())
	model.Parent = self:container()

	self.Arrows[arrow] = true
	self:play()

	return arrow
end

--[[ API ]]

--[=[
	Points at a world position. Returns the arrow, or `nil` if the model does not
	exist in this place.

	Each call is a new arrow: pointing at two places at once means asking for two. To
	move an existing one, `arrow:MoveTo(otherPosition)`.
]=]
function ArrowController:Point(position : Vector3, options : Options?) : Arrow?
	return self:spawn(position, options, nil, Config.Scale)
end

--[=[
	A guide arrow: lies flat next to `origin` (read every frame, so it follows the
	player) and points towards `position`. `origin` returning `nil` (no character
	yet) hides the arrow until it returns a position again.

		local arrow = Arrow:Guide(function()
			local root = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
			return root and root.Position
		end, portal.Position)
]=]
function ArrowController:Guide(origin : () -> Vector3?, position : Vector3, options : Options?) : Arrow?
	return self:spawn(position, options, origin, Config.Guide.Scale)
end

--[=[
	Clears every arrow at once. It is what a round change or the end of a tutorial
	calls without needing to track who pointed at what.
]=]
function ArrowController:ClearAll()
	for arrow in self.Arrows do
		arrow.Alive = false
		arrow.Model:Destroy()
	end

	table.clear(self.Arrows)

	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end
end

function ArrowController:Count() : number
	local count = 0

	for _ in self.Arrows do
		count += 1
	end

	return count
end

--[[ LIFECYCLE ]]

function ArrowController:construct()
	-- The server points by position; without a position, it clears. A single event for
	-- both cases avoids a second identifier to declare and maintain.
	Framework:Listen("ArrowPoint", function(position : any, options : any)
		if typeof(position) ~= "Vector3" then
			self:ClearAll()

			return
		end

		self:ClearAll()
		self:Point(position, if type(options) == "table" then options else nil)
	end)
end

function ArrowController:start()
end

function ArrowController:init()
	self:construct()
end

return ArrowController