--[[
	A model spinning in a `ViewportFrame`, playing one looped animation: the Index's
	unit and enemy displays (item buttons and the preview).

	The model is a clone, inside a `WorldModel` (without it a viewport does not
	animate), with its own `Camera` framed to fit it. It spins around its own pivot
	through `Step`, which the controller calls only for what is on screen, and its
	animation plays only while `SetActive(true)`: with ~40 enemies on a page, an
	animator running behind a closed panel is pure cost.

	**Silhouette** is the undiscovered look: every part black, and everything that
	would paint over the color (mesh textures, decals, surface appearances, clothing)
	removed or blackened. Done on the clone, so the asset is untouched.
]]

local IndexModelView = {}
IndexModelView.__index = IndexModelView

--[[ CONSTANTS ]]

local SILHOUETTE_COLOR = Color3.new(0, 0, 0)

-- Radians per second.
local SPIN_SPEED = math.rad(45)

local FIELD_OF_VIEW = 30

-- Room around the model, as a fraction of the distance that fits it exactly.
local FRAME_PADDING = 1.1

--[[
	The light comes from the camera's side. The viewport's default direction lights
	the faces pointing away from a camera on the model's front, so the side the
	player sees would get only the ambient light.
]]
local LIGHT_DIRECTION = Vector3.new(-0.5, -1, 1)

-- The camera looks slightly down at the model, as a fraction of its height.
local CAMERA_RISE = 0.15

-- What a viewport cannot render, or what would only add cost there.
local STRIPPED_CLASSES = {
	"BaseScript",
	"LayerCollector",
	"ParticleEmitter",
	"Trail",
	"Beam",
	"Light",
	"Fire",
	"Smoke",
	"Sparkles",
	"Sound",
}

--[[ INTERNAL ]]

local function strip(model : Model)
	for _, descendant in model:GetDescendants() do
		for _, className in STRIPPED_CLASSES do
			if descendant:IsA(className) then
				descendant:Destroy()
				break
			end
		end
	end
end

local function blacken(model : Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Color = SILHOUETTE_COLOR
			descendant.Material = Enum.Material.SmoothPlastic
			descendant.Reflectance = 0

			if descendant:IsA("MeshPart") then
				descendant.TextureID = ""
			end
		elseif descendant:IsA("SpecialMesh") then
			descendant.TextureId = ""
			descendant.VertexColor = Vector3.zero
		elseif descendant:IsA("Decal") then
			-- `Texture` is a `Decal` too.
			descendant.Color3 = SILHOUETTE_COLOR
		elseif descendant:IsA("SurfaceAppearance") or descendant:IsA("Clothing") or descendant:IsA("ShirtGraphic") then
			descendant:Destroy()
		end
	end
end

--[=[
	The box of the visible parts, in world space, with the model's pivot at the
	origin. Invisible parts (hitboxes, the root, range markers) are left out: one of
	them would shrink the model to a dot in the corner.
]=]
local function visibleBounds(model : Model) : (Vector3, Vector3)
	local min = Vector3.new(math.huge, math.huge, math.huge)
	local max = -min

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 then
			local half = part.Size / 2

			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						local corner = part.CFrame:PointToWorldSpace(half * Vector3.new(x, y, z))
						min = min:Min(corner)
						max = max:Max(corner)
					end
				end
			end
		end
	end

	if min.X == math.huge then
		local cframe, size = model:GetBoundingBox()
		return cframe.Position - size / 2, cframe.Position + size / 2
	end

	return min, max
end

--[=[
	Loads the animation on the model's `Animator`, creating the controller and the
	animator when the asset has none (the units do not: `Unit.new` creates them in
	the match, the same way).
]=]
local function loadTrack(model : Model, animation : Animation?) : AnimationTrack?
	if not animation then return nil end

	local controller = model:FindFirstChildWhichIsA("AnimationController")
		or model:FindFirstChildWhichIsA("Humanoid")

	if not controller then
		controller = Instance.new("AnimationController")
		controller.Parent = model
	end

	local animator = controller:FindFirstChildWhichIsA("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end

	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)

	if not ok then return nil end

	track.Looped = true

	return track
end

--[[ API ]]

export type Options = {
	-- The looped animation (a unit's `Idle`, an enemy's `Walk`).
	Animation : Animation?,

	-- The undiscovered look: the model all black.
	Silhouette : boolean?,
}

--[=[
	Clones `source` into `viewport` and frames it. The viewport's previous view, if
	any, must be destroyed first: this does not clear the viewport.
]=]
function IndexModelView.new(viewport : ViewportFrame, source : Model, options : Options?)
	options = options or {}

	local self = setmetatable({}, IndexModelView)

	self.Viewport = viewport
	self.Angle = 0
	self.Active = false
	self.Connections = {}

	local world = Instance.new("WorldModel")
	world.Name = "IndexWorld"
	world.Parent = viewport
	self.World = world

	local model = source:Clone()
	strip(model)

	if options.Silhouette then
		blacken(model)
	end

	-- An anchored limb ignores its Motor6D, so only the root stays anchored, the same
	-- as `MobController` does in the match. A `WorldModel` runs no physics, so an
	-- unjointed part does not fall either.
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = part == root
		end
	end

	model:PivotTo(CFrame.new())
	model.Parent = world
	self.Model = model

	self.BoundsMin, self.BoundsMax = visibleBounds(model)

	local camera = Instance.new("Camera")
	camera.Name = "IndexCamera"
	camera.FieldOfView = FIELD_OF_VIEW
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.LightDirection = LIGHT_DIRECTION
	self.Camera = camera

	self:_frame()

	-- The viewport's aspect decides the horizontal fit, and it is zero until the
	-- panel is on screen.
	table.insert(self.Connections, viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_frame()
	end))

	self.Track = loadTrack(model, options.Animation)

	return self
end

--[=[
	Puts the camera in front of the model (its `LookVector` side), far enough for
	the whole spin to fit: the horizontal radius is the box's diagonal, because the
	model turns.
]=]
function IndexModelView:_frame()
	local min, max = self.BoundsMin, self.BoundsMax
	local size = max - min
	local center = (min + max) / 2

	local absolute = self.Viewport.AbsoluteSize
	local aspect = if absolute.Y > 0 then absolute.X / absolute.Y else 1

	local halfVertical = math.rad(FIELD_OF_VIEW / 2)
	local halfHorizontal = math.atan(math.tan(halfVertical) * aspect)

	local radius = Vector2.new(size.X, size.Z).Magnitude / 2
	local fitHeight = (size.Y / 2) / math.tan(halfVertical)
	local fitWidth = radius / math.tan(halfHorizontal)

	local distance = math.max(fitHeight, fitWidth) * FRAME_PADDING
	local position = center + Vector3.new(0, size.Y * CAMERA_RISE, -distance)

	self.Camera.CFrame = CFrame.lookAt(position, center)
end

--- Plays or pauses the animation. Paused, the model stands in its rest pose.
function IndexModelView:SetActive(active : boolean)
	if self.Active == active then return end
	self.Active = active

	local track = self.Track
	if not track then return end

	if active then
		track:Play(0)
	else
		track:Stop(0)
	end
end

--- Turns the model around its own pivot.
function IndexModelView:Step(deltaTime : number)
	local model = self.Model
	if not model or not model.Parent then return end

	self.Angle = (self.Angle + SPIN_SPEED * deltaTime) % (math.pi * 2)
	model:PivotTo(CFrame.Angles(0, self.Angle, 0))
end

function IndexModelView:Destroy()
	for _, connection in self.Connections do
		connection:Disconnect()
	end
	table.clear(self.Connections)

	if self.Track then
		self.Track:Stop(0)
		self.Track:Destroy()
		self.Track = nil
	end

	if self.World then
		self.World:Destroy()
		self.World = nil
	end

	if self.Camera then
		if self.Viewport.CurrentCamera == self.Camera then
			self.Viewport.CurrentCamera = nil
		end

		self.Camera:Destroy()
		self.Camera = nil
	end

	self.Model = nil
end

return IndexModelView
