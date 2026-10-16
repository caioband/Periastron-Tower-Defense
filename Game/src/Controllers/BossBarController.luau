local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local MobConfig = SharedConfig.Mob

--[[
	The boss health bar: top middle of the screen, right under the wave counter,
	while a boss is on the map.

	It reads what `MobController` already keeps for every enemy (`SpawnedMobs` for
	the model, `MobHealth` for current and max health), so it needs no event of its
	own and shows exactly what the bar over the boss's head shows. A boss is any
	entity with `Boss = true` in `SharedConfig.Mob`; with two on the map, the one
	with the most health left is the one shown.

	The screen is built here, in code, with the same insets as `Interface`
	(`CoreUISafeInsets`), so its scale positions line up with the wave counter on
	every device.
]]

local GUI_NAME = "BossBar"
local DISPLAY_ORDER = 1

local FONT = Font.new("rbxasset://fonts/families/PressStart2P.json")

-- Under `Interface.WaveCounter`, which is centred at 8% of the screen height and 9% tall.
local BAR_POSITION = UDim2.fromScale(0.5, 0.135)
local BAR_SIZE = UDim2.fromScale(0.28, 0.065)

local TRACK_COLOR = Color3.fromRGB(35, 20, 25)
local FILL_COLOR = Color3.fromRGB(220, 45, 55)
local FILL_DARK = Color3.fromRGB(150, 20, 35)
local DAMAGE_COLOR = Color3.fromRGB(255, 225, 120)
local STROKE_COLOR = Color3.fromRGB(0, 0, 0)

local POLL_INTERVAL = 0.1

local FILL_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DAMAGE_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.25)
local SHOW_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local BossBarController = {
	Controllers = {
		MobController = {},
	},
}

BossBarController.Gui = nil :: ScreenGui?
BossBarController.Bar = nil :: Frame?
BossBarController.Fill = nil :: Frame?
BossBarController.Damage = nil :: Frame?
BossBarController.NameLabel = nil :: TextLabel?
BossBarController.HealthLabel = nil :: TextLabel?
BossBarController.Scale = nil :: UIScale?

BossBarController.BossId = nil :: string?
BossBarController.Ratio = 1

--[[ INTERNAL ]]

local function create(className : string, properties : { [string] : any }, parent : Instance?) : any
	local instance = Instance.new(className)

	for property, value in properties do
		(instance :: any)[property] = value
	end

	if parent then
		instance.Parent = parent
	end

	return instance
end

--- "AstralSentinel" -> "ASTRAL SENTINEL", unless the entity declares its own name.
local function displayName(entityName : string) : string
	local entity = MobConfig.Entities and MobConfig.Entities[entityName]
	local name = entity and entity.DisplayName or string.gsub(entityName, "(%l)(%u)", "%1 %2")

	return string.upper(name)
end

local function isBoss(entityName : string) : boolean
	if MobConfig.IsBoss then
		return MobConfig.IsBoss(entityName) == true
	end

	local entity = MobConfig.Entities and MobConfig.Entities[entityName]

	return entity ~= nil and entity.Boss == true
end

local function formatHealth(value : number) : string
	return tostring(math.max(0, math.ceil(value)))
end

function BossBarController:build()
	if self.Gui and self.Gui.Parent then return end

	local gui = create("ScreenGui", {
		Name = GUI_NAME,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = DISPLAY_ORDER,
		Enabled = true,
	}, PlayerGui)

	local bar = create("Frame", {
		Name = "Bar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = BAR_POSITION,
		Size = BAR_SIZE,
		BackgroundTransparency = 1,
		Visible = false,
	}, gui)

	self.Scale = create("UIScale", { Scale = 1 }, bar)

	local nameLabel = create("TextLabel", {
		Name = "BossName",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(1, 0.4),
		BackgroundTransparency = 1,
		FontFace = FONT,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
	}, bar)

	create("UIStroke", {
		Color = STROKE_COLOR,
		Thickness = 0.08,
		StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
	}, nameLabel)

	local track = create("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 0.52),
		BackgroundColor3 = TRACK_COLOR,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, bar)

	create("UIStroke", {
		Color = STROKE_COLOR,
		Thickness = 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, track)

	local damage = create("Frame", {
		Name = "Damage",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = DAMAGE_COLOR,
		BorderSizePixel = 0,
	}, track)

	local fill = create("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, track)

	create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(FILL_COLOR, FILL_DARK),
	}, fill)

	local healthLabel = create("TextLabel", {
		Name = "Health",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.96, 0.7),
		BackgroundTransparency = 1,
		FontFace = FONT,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
		ZIndex = 3,
	}, track)

	create("UIStroke", {
		Color = STROKE_COLOR,
		Thickness = 0.1,
		StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
	}, healthLabel)

	self.Gui = gui
	self.Bar = bar
	self.Fill = fill
	self.Damage = damage
	self.NameLabel = nameLabel
	self.HealthLabel = healthLabel
end

--- The boss on the map with the most health left: its id, name, and health record.
function BossBarController:findBoss() : (string?, string?, any)
	local mobs = self.Controllers.MobController
	local spawned = mobs and mobs.SpawnedMobs
	local health = mobs and mobs.MobHealth
	if not spawned or not health then return nil, nil, nil end

	local bestId, bestName, bestData = nil, nil, nil

	for mobId, model in spawned do
		if typeof(model) ~= "Instance" or not model.Parent then continue end
		if not isBoss(model.Name) then continue end

		local data = health[mobId]
		if not data or (data.current or 0) <= 0 then continue end

		if not bestData or data.current > bestData.current then
			bestId, bestName, bestData = mobId, model.Name, data
		end
	end

	return bestId, bestName, bestData
end

function BossBarController:setVisible(visible : boolean)
	local bar = self.Bar
	if not bar or bar.Visible == visible then return end

	bar.Visible = visible

	if visible and self.Scale then
		self.Scale.Scale = 0.6
		TweenService:Create(self.Scale, SHOW_INFO, { Scale = 1 }):Play()
	end
end

function BossBarController:setRatio(ratio : number, instant : boolean)
	ratio = math.clamp(ratio, 0, 1)

	local fill, damage = self.Fill, self.Damage
	if not fill or not damage then return end

	local goal = UDim2.fromScale(ratio, 1)

	if instant then
		fill.Size = goal
		damage.Size = goal
	elseif ratio ~= self.Ratio then
		TweenService:Create(fill, FILL_INFO, { Size = goal }):Play()

		-- The pale strip trails behind the red, so a hit reads as a chunk coming off.
		TweenService:Create(damage, DAMAGE_INFO, { Size = goal }):Play()
	end

	self.Ratio = ratio
end

function BossBarController:refresh()
	local bossId, bossName, data = self:findBoss()

	if not bossId or not data then
		self.BossId = nil
		self:setVisible(false)

		return
	end

	local max = math.max(1, data.max or data.current or 1)
	local current = math.clamp(data.current or 0, 0, max)
	local isNew = bossId ~= self.BossId

	self.BossId = bossId

	if self.NameLabel then
		self.NameLabel.Text = displayName(bossName :: string)
	end

	if self.HealthLabel then
		self.HealthLabel.Text = `{formatHealth(current)} / {formatHealth(max)}`
	end

	self:setRatio(current / max, isNew)
	self:setVisible(true)
end

--[[ LIFECYCLE ]]

function BossBarController:construct()
	self:build()

	local elapsed = 0

	RunService.Heartbeat:Connect(function(dt : number)
		elapsed += dt
		if elapsed < POLL_INTERVAL then return end
		elapsed = 0

		self:refresh()
	end)
end

function BossBarController:start()
end

function BossBarController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return BossBarController