local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Me = require(Vendor.Me)

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Util.UIUtil)
local Log = require(Util:WaitForChild("Log"))

local LevelConfig = SharedConfig.LevelConfig

local Framework = Me.new()
local log = Log.new("ResultController")

--[[
	The end-of-match screen.

	It enters through `RoundReward`, the only event the server fires on both outcomes
	(victory and defeat) already carrying the result data.

	The whole entrance choreography lives in `:playRevealAnimation()`. Code that needs
	to show the screen calls `:Show(info)` and touches no tween; changing rhythm, order,
	or easing means editing only the constants here and that method.

		StarterGui.ResultScreen
		├── BackgroundFrame         full-screen black Frame (the darkening)
		└── MainScreen              the panel's ImageLabel
		    ├── ViewportFrame       the MVP in 3D
		    │   └── WorldModel      where the character clone goes
		    ├── MVPText             TextLabel "MVP: <name>"
		    ├── RewardTitle         TextLabel "REWARDS": fades in
		    ├── RewardsContainer    Frame with ClipsDescendants and UIListLayout
		    │   ├── ShardRewardWrapper.ShardAmount   slides into the frame
		    │   └── CoinsRewardWrapper.CoinAmount    same, REWARD_STAGGER later
		    ├── ExpContainer        the XP bar's Frame
		    │   └── Bar             Size.X.Scale from BAR_MIN (0%) to BAR_MAX (100%)
		    ├── ExpAmount           TextLabel "XP/next level"
		    ├── ExpOrnament         decorative ImageLabel, enters with ExpContainer
		    ├── PlayAgain           ImageButton
		    └── Lobby               ImageButton

	Everything inside MainScreen starts with `Visible = false` in the authored GUI: the
	reveal turns each piece on at the right time. The old panel (`ResultBackground`) is
	not used; if it is still in the tree, it is only kept disabled.

	See docs/game/rewards.md.
]]

-- Background darkening.
local BACKDROP_TRANSPARENCY = 0.4
local BACKDROP_TIME = 0.4

-- Panel and fades.
local PANEL_DELAY = 0.75      -- wait between the backdrop and the panel
local ELEMENT_TIME = 0.35     -- duration of each fade
local ELEMENT_STAGGER = 0.3   -- interval between the start of one fade and the next

-- Rewards: each label slides in from REWARD_SLIDE_FROM to the authored
-- position (0 -> 0.5 in X.Scale, with today's art).
local REWARD_SLIDE_FROM = 0
local REWARD_SLIDE_TIME = 0.4
local REWARD_STAGGER = 0.4    -- from the start of one wrapper to the start of the next
local REWARD_DELAY = 0.15     -- wait between the title and the first wrapper

-- XP bar.
local EXP_DELAY = 0.35
local EXP_FILL_TIME = 1.1
local BAR_MIN = 0.05          -- 0% progress
local BAR_MAX = 1             -- 100%

local EASING_STYLE = Enum.EasingStyle.Quad
local EASING_DIRECTION = Enum.EasingDirection.Out

--[[ names in the tree ]]

local SCREEN_NAME = "ResultScreen"
local PANEL_NAME = "MainScreen"
local LEGACY_PANEL_NAME = "ResultBackground"
local BACKDROP_NAME = "BackgroundFrame"

local TITLE_NAME = "RewardTitle"
local REWARDS_NAME = "RewardsContainer"
local EXP_NAME = "ExpContainer"
local EXP_TEXT_NAME = "ExpAmount"
local EXP_ORNAMENT_NAME = "ExpOrnament"
local BAR_NAME = "Bar"

local VIEWPORT_NAME = "ViewportFrame"
local WORLD_MODEL_NAME = "WorldModel"
local MVP_TEXT_NAME = "MVPText"
local MVP_MODEL_NAME = "MVPCharacter"

local PLAY_AGAIN_NAME = "PlayAgain"
local LOBBY_NAME = "Lobby"
local BUTTON_TEXT_NAME = "TextLabel"

-- Which `info.rewards` key each wrapper's number comes from. A wrapper not in the
-- list still enters the animation, it just has no number to write.
local REWARD_KEYS = {
	ShardRewardWrapper = "shards",
	CoinsRewardWrapper = "coins",
}

-- MVP framing in the ViewportFrame.
local VIEWPORT_FOV = 30            -- narrow FOV: less lens distortion in the portrait
local VIEWPORT_PADDING = 1.12      -- margin around the character
local VIEWPORT_YAW = 15            -- degrees of turn; 0 is facing front, positive turns the shoulder
local VIEWPORT_HEIGHT_BIAS = 0     -- fraction of the height; raises the camera target and lowers the body in the frame

local LEAVING_TEXT = "LEAVING..."
local LOBBY_TEXT = "BACK TO LOBBY"
local PLAY_AGAIN_TEXT = "PLAY AGAIN (%d/%d)"
local MAX_EXP_TEXT = "MAX"
local MVP_TEXT = "MVP: %s"
local MVP_EMPTY_TEXT = "MVP: —"

-- Transparency properties per class. Only what is here enters the
-- fades; UICorner and UIAspectRatioConstraint stay out because they have nothing
-- to animate.
local TRANSPARENCY_PROPERTIES = {
	Frame = { "BackgroundTransparency" },
	ScrollingFrame = { "BackgroundTransparency" },
	CanvasGroup = { "BackgroundTransparency", "GroupTransparency" },
	ViewportFrame = { "BackgroundTransparency", "ImageTransparency" },
	ImageLabel = { "BackgroundTransparency", "ImageTransparency" },
	ImageButton = { "BackgroundTransparency", "ImageTransparency" },
	TextLabel = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" },
	TextButton = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" },
	TextBox = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" },
	UIStroke = { "Transparency" },
}

local ResultController = {
	Controllers = {
		UnitPlacementController = {},
		DataController = {},

		-- The one that knows whether this match is the tutorial. See `bindButtons`.
		TutorialStepController = {},
	},
	connections = {},
	tweens = {},
}

-- Authored transparency and position values, per instance. Weak keys
-- because ResultScreen has ResetOnSpawn = true: the ScreenGui is recreated on every
-- respawn and the old instances need to be collectable.
ResultController.snapshots = setmetatable({}, { __mode = "k" })
ResultController.positions = setmetatable({}, { __mode = "k" })

local function tweenInfo(duration : number)
	return TweenInfo.new(duration, EASING_STYLE, EASING_DIRECTION)
end

--[[ instance resolution ]]

function ResultController:getScreen()
	-- Resolved at show time, not stored in init, because the ScreenGui
	-- starts from scratch on every respawn.
	local screen = PlayerGui:FindFirstChild(SCREEN_NAME)
	if not screen or not screen:IsA("ScreenGui") then
		log:StudioWarn(`StarterGui.{SCREEN_NAME} not found in PlayerGui.`)
		return nil
	end
	return screen
end

function ResultController:getPanel()
	local screen = PlayerGui:FindFirstChild(SCREEN_NAME)
	local panel = screen and screen:FindFirstChild(PANEL_NAME)
	return panel
end

function ResultController:setInterfaceEnabled(enabled : boolean)
	local interface = PlayerGui:FindFirstChild("Interface")
	if interface and interface:IsA("ScreenGui") then
		interface.Enabled = enabled
	end
end

--[[ transparency ]]

-- Stores (once per instance) the authored transparency values. They are
-- the fade targets: an element born with ImageTransparency 0.47 must
-- return to 0.47, not to 0.
function ResultController:snapshot(instance : Instance)
	local properties = TRANSPARENCY_PROPERTIES[instance.ClassName]
	if not properties then return nil end

	local cached = self.snapshots[instance]
	if cached then return cached end

	local values = {}
	for _, property in properties do
		values[property] = (instance :: any)[property]
	end

	self.snapshots[instance] = values
	return values
end

-- The subtree of `root`, itself included, in tree order.
function ResultController:collectTargets(root : Instance)
	local list = {}

	local function visit(current : Instance)
		local values = self:snapshot(current)
		if values then
			table.insert(list, { instance = current, values = values })
		end
		for _, child in current:GetChildren() do
			visit(child)
		end
	end

	visit(root)
	return list
end

function ResultController:setTransparent(target)
	local instance = target.instance :: any
	for property, _ in target.values do
		instance[property] = 1
	end
end

--[=[
	Every tween on the screen goes through here: a new `Show` cancels whatever was
	still running from the previous one before repositioning the pieces, or the old
	tween keeps writing over the new reveal's initial state.
]=]
function ResultController:playTween(instance : Instance, duration : number, goal)
	local tween = TweenService:Create(instance, tweenInfo(duration), goal)

	table.insert(self.tweens, tween)
	tween:Play()

	return tween
end

function ResultController:cancelTweens()
	for _, tween in self.tweens do
		pcall(function()
			tween:Cancel()
		end)
	end

	table.clear(self.tweens)
end

function ResultController:fadeIn(target, duration : number)
	local goal = {}
	for property, value in target.values do
		goal[property] = value
	end
	self:playTween(target.instance, duration, goal)
end

--[=[
	Prepares a group to enter: stores the authored values, sets everything to
	transparency 1, and turns `Visible` off. Returns the targets for the fade.
]=]
function ResultController:prepareGroup(root : Instance?)
	if not root then return nil end

	local targets = self:collectTargets(root)
	for _, target in targets do
		self:setTransparent(target)
	end

	if root:IsA("GuiObject") then
		root.Visible = false
	end

	return { root = root, targets = targets }
end

--[=[
	Turns the group on and runs its whole fade at once. The stagger is between groups,
	not element by element: each group enters together.
]=]
function ResultController:revealGroup(group, duration : number?)
	if not group then return end

	if group.root:IsA("GuiObject") then
		group.root.Visible = true
	end

	for _, target in group.targets do
		self:fadeIn(target, duration or ELEMENT_TIME)
	end
end

--[[ rewards ]]

--[=[
	Writes the wrappers' numbers and returns, in UIListLayout order, the labels that
	will slide. A wrapper with a zero reward is left out: in an early defeat shards are
	0, and a "0" row only takes space; the layout closes the gap.
]=]
function ResultController:collectRewardWrappers(container : Instance, info)
	local rewards = info.rewards or {}
	local wrappers = {}

	for index, child in container:GetChildren() do
		if not child:IsA("GuiObject") then continue end

		local key = REWARD_KEYS[child.Name]
		local amount = key and tonumber(rewards[key]) or nil

		if key and (amount or 0) <= 0 then
			child.Visible = false
			continue
		end

		-- The label is the wrapper's only GuiObject child; it is the one that slides.
		local label = nil
		for _, candidate in child:GetChildren() do
			if candidate:IsA("GuiObject") then
				label = candidate
				break
			end
		end

		if not label then continue end

		if amount then
			for _, text in label:GetDescendants() do
				if text:IsA("TextLabel") then
					text.Text = UIUtil.formatCommas(amount)
					break
				end
			end
		end

		child.Visible = true
		table.insert(wrappers, {
			label = label,
			order = child.LayoutOrder,
			index = index,
		})
	end

	table.sort(wrappers, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.index < b.index
	end)

	return wrappers
end

--[=[
	Sends the label to the start of the slide. The authored position is the target, so
	it is stored before any write; it is what `slideIn` restores.
]=]
function ResultController:setSlideStart(label : GuiObject)
	local original = self.positions[label]
	if not original then
		original = label.Position
		self.positions[label] = original
	end

	label.Position = UDim2.new(REWARD_SLIDE_FROM, original.X.Offset, original.Y.Scale, original.Y.Offset)
end

function ResultController:slideIn(label : GuiObject)
	local original = self.positions[label]
	if not original then return end

	self:playTween(label, REWARD_SLIDE_TIME, { Position = original })
end

--[[ XP bar ]]

--[=[
	The profile's accumulated XP, straight from the replica. `nil` until it arrives.
]=]
function ResultController:getTotalXP() : number?
	local dataController = self.Controllers.DataController
	if not dataController or not dataController.GetReplica then return nil end

	local ok, replica = pcall(function()
		return dataController:GetReplica()
	end)

	if not ok or not replica then return nil end

	local data = replica.Data
	local stats = typeof(data) == "table" and data.Stats or nil

	return typeof(stats) == "table" and tonumber(stats.XP) or nil
end

function ResultController:applyExpState(bar : GuiObject, label : TextLabel?, totalXP : number)
	local state = LevelConfig:Resolve(totalXP)
	local size = bar.Size

	bar.Size = UDim2.new(BAR_MIN + (BAR_MAX - BAR_MIN) * state.Progress, size.X.Offset, size.Y.Scale, size.Y.Offset)

	if label then
		label.Text = if state.IsMax
			then MAX_EXP_TEXT
			else `{UIUtil.formatCommas(state.XP)}/{UIUtil.formatCommas(state.Required)}`
	end
end

--[=[
	Fills the bar from the XP the player had before the match to what they have now.

	The starting point is derived: when the animation gets here the replica has
	already come in with the sum (the server credits before firing `RoundReward`, and
	the bar only enters after the title and rewards), so "before" is the total minus
	the match gain. Since each frame re-resolves the total through `LevelConfig`,
	leveling up mid-fill comes for free: the bar reaches 100%, returns to 0%, and
	continues, even more than once.
]=]
function ResultController:playExpAnimation(container : Instance, label : TextLabel?, info)
	local bar = container:FindFirstChild(BAR_NAME)
	if not bar or not bar:IsA("GuiObject") then
		log:StudioWarn(`{PANEL_NAME}.{EXP_NAME}.{BAR_NAME} not found.`)
		return
	end

	-- Resets the bar before anything that may yield: the replica is only slow if it
	-- has not arrived yet, and by then the container is already on; without this it
	-- would appear at the size left over from the previous round.
	local size = bar.Size
	bar.Size = UDim2.new(BAR_MIN, size.X.Offset, size.Y.Scale, size.Y.Offset)

	local gained = math.max(0, tonumber((info.rewards or {}).xp) or 0)
	local total = self:getTotalXP()

	-- Without a replica, the only reliable number is the match gain: the bar rises from
	-- zero to it instead of faking a level.
	local finish = total or gained
	local start = math.max(0, finish - gained)

	self:applyExpState(bar, label, start)

	if finish <= start then return end

	local began = os.clock()

	while true do
		local alpha = math.clamp((os.clock() - began) / EXP_FILL_TIME, 0, 1)
		local eased = TweenService:GetValue(alpha, EASING_STYLE, EASING_DIRECTION)

		self:applyExpState(bar, label, start + (finish - start) * eased)

		if alpha >= 1 then break end
		RunService.Heartbeat:Wait()
	end
end

--[[ mvp ]]

--[=[
	Why the character is copied, not referenced.

	A ViewportFrame renders only its own descendants, and an Instance has a single
	Parent: there is no pointing at the live character from here; the only option is
	moving the real character into the WorldModel, which would take it out of the world
	(and, being another player's character, would still fight the server's
	replication, which puts it back). So the copy is mandatory.

	What can be avoided is coupling, and that is what these functions do: the clone
	goes in with no scripts, no sounds, its root anchored, and playing its own idle.
	Once built it never looks at the original character again: nothing syncs it frame
	by frame with the world.
]=]
function ResultController:getMVPCharacter(mvp) : Model?
	if not mvp then return nil end

	local userId = tonumber(mvp.userId)

	for _, player in Players:GetPlayers() do
		local matches = if userId then player.UserId == userId else player.Name == mvp.name
		if matches then
			return player.Character
		end
	end

	return nil
end

-- The idle comes from the character's own `Animate`: it knows whether the rig is R6
-- or R15, so no animation id needs to be written here.
function ResultController:getIdleAnimationId(character : Model) : string?
	local animate = character:FindFirstChild("Animate")
	local idle = animate and animate:FindFirstChild("idle")
	if not idle then return nil end

	local animation = idle:FindFirstChild("Animation1") or idle:FindFirstChildWhichIsA("Animation")
	if animation and animation:IsA("Animation") and animation.AnimationId ~= "" then
		return animation.AnimationId
	end

	return nil
end

--[=[
	Strips from the clone everything that would only cause trouble inside a ScreenGui:
	scripts (which would actually run, being in PlayerGui), sounds, effects,
	nameplates. The rig remains, and only the root is anchored: anchoring the rest
	would lock the Motor6Ds and the animation with them.
]=]
function ResultController:sanitizeMVPModel(model : Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BaseScript")
			or descendant:IsA("Sound")
			or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("Fire")
			or descendant:IsA("Smoke")
			or descendant:IsA("Sparkles")
			or descendant:IsA("LayerCollector")
			or descendant:IsA("Highlight")
			or descendant:IsA("ForceField")
		then
			descendant:Destroy()
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local any = humanoid :: any
		pcall(function()
			any.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end)
		pcall(function()
			any.EvaluateStateMachine = false
		end)
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
end

--[=[
	Copies the character, working around `Archivable`.

	The engine marks the player's character `Archivable = false` (the avatar does not
	get copied around), and `Clone` returns nil in that case, leaving the frame empty.
	`Clone` also skips marked descendants, so the flag is turned on on the model and on
	any descendant with it off, and restored right after: the window is a single line
	and only exists on this client.
]=]
function ResultController:cloneCharacter(character : Model) : Model?
	local restore = {}

	if not character.Archivable then
		character.Archivable = true
		table.insert(restore, character)
	end

	for _, descendant in character:GetDescendants() do
		if not descendant.Archivable then
			descendant.Archivable = true
			table.insert(restore, descendant)
		end
	end

	local ok, clone = pcall(function()
		return character:Clone()
	end)

	for _, instance in restore do
		instance.Archivable = false
	end

	if not ok or not clone then
		log:StudioWarn(`could not copy the MVP character: {tostring(clone)}`)
		return nil
	end

	return clone
end

--[=[
	Frames the whole character in the frame the GUI has. Recomputed after the panel
	appears because `AbsoluteSize` is only valid once the GUI has rendered once; before
	that it is zero and the aspect would come out wrong.
]=]
function ResultController:frameMVPCamera()
	local viewport = self.mvpViewport
	local model = self.mvpModel
	local camera = self.mvpCamera

	if not viewport or not camera or not model or not model.Parent then return end

	local bounds, size = model:GetBoundingBox()

	local absolute = viewport.AbsoluteSize
	local aspect = if absolute.Y > 0 then absolute.X / absolute.Y else 1

	local fit = math.max(size.Y, size.X / math.max(aspect, 0.01))
	local distance = (fit * 0.5 * VIEWPORT_PADDING) / math.tan(math.rad(VIEWPORT_FOV * 0.5)) + size.Z * 0.5
	local focus = bounds.Position + Vector3.new(0, size.Y * VIEWPORT_HEIGHT_BIAS, 0)

	camera.FieldOfView = VIEWPORT_FOV
	camera.CFrame = CFrame.lookAt(focus + Vector3.new(0, 0, distance), focus)
end

function ResultController:clearMVPModel()
	if self.mvpStep then
		self.mvpStep:Disconnect()
		self.mvpStep = nil
	end

	if self.mvpModel then
		self.mvpModel:Destroy()
		self.mvpModel = nil
	end
end

--[=[
	Writes the MVP's name and builds their portrait. Returns `true` when the
	ViewportFrame has someone to show: without a character (the MVP left at the end of
	the match, or is respawning) the frame does not enter the reveal, instead of
	appearing empty.
]=]
function ResultController:populateMVP(panel : Instance, info) : boolean
	local mvp = info.mvp

	local label = panel:FindFirstChild(MVP_TEXT_NAME)
	if label and label:IsA("TextLabel") then
		label.Text = if mvp and mvp.name then string.format(MVP_TEXT, mvp.name) else MVP_EMPTY_TEXT
	end

	self:clearMVPModel()

	local viewport = panel:FindFirstChild(VIEWPORT_NAME)
	if not viewport or not viewport:IsA("ViewportFrame") then return false end

	self.mvpViewport = viewport

	local world = viewport:FindFirstChildOfClass("WorldModel")
	if not world then
		world = Instance.new("WorldModel")
		world.Name = WORLD_MODEL_NAME
		world.Parent = viewport
	end

	local camera = viewport:FindFirstChildOfClass("Camera")
	if not camera then
		camera = Instance.new("Camera")
		camera.Parent = viewport
	end

	viewport.CurrentCamera = camera
	self.mvpCamera = camera

	local character = self:getMVPCharacter(mvp)
	if not character then return false end

	local animationId = self:getIdleAnimationId(character)

	local clone = self:cloneCharacter(character)
	if not clone then return false end

	clone.Name = MVP_MODEL_NAME
	self:sanitizeMVPModel(clone)

	-- Identity faces -Z, so 180 degrees turns the character to face the camera;
	-- VIEWPORT_YAW is only seasoning for the angle.
	clone:PivotTo(CFrame.Angles(0, math.rad(180 + VIEWPORT_YAW), 0))
	clone.Parent = world

	self.mvpModel = clone

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")

	if animationId and animator then
		local animation = Instance.new("Animation")
		animation.AnimationId = animationId
		animation.Parent = animator

		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)

		if ok and track then
			track.Looped = true
			track:Play(0)

			-- An Animator outside the Workspace does not advance on its own:
			-- `StepAnimations` advances it. Step zero already applies the idle's first pose, so
			-- even without the loop the portrait stands in a standing pose, not the frozen pose
			-- from the instant the round ended.
			pcall(function()
				animator:StepAnimations(0)
			end)

			self.mvpStep = RunService.RenderStepped:Connect(function(delta)
				if not clone.Parent then return end
				animator:StepAnimations(delta)
			end)
		end
	end

	self:frameMVPCamera()

	return true
end

--[[ buttons ]]

function ResultController:findButton(name : string)
	local panel = self:getPanel()
	local button = panel and panel:FindFirstChild(name)
	return button and button:IsA("GuiButton") and button or nil
end

function ResultController:setButtonText(name : string, text : string)
	local button = self:findButton(name)
	local label = button and button:FindFirstChild(BUTTON_TEXT_NAME)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

function ResultController:setLobbyButtonText(text : string)
	self:setButtonText(LOBBY_NAME, text)
end

-- Vote counter on the play-again button itself.
function ResultController:applyPlayAgainState()
	local state = self.playAgainState
	if not state then return end

	self:setButtonText(PLAY_AGAIN_NAME, string.format(PLAY_AGAIN_TEXT, state.votes or 0, state.total or 0))
end

--[=[
	Locks (or unlocks) a button on the screen.

	`Active = false` is what actually refuses the click; the rest is so it **looks**
	locked instead of broken: a button that lights up on hover and does not respond is
	worse than a dimmed one.
]=]
function ResultController:setButtonEnabled(button : GuiButton, enabled : boolean)
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.Selectable = enabled
end

-- Reconnected on every Show because ResultScreen is recreated on respawn.
function ResultController:bindButtons()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	--[[
		The tutorial is not played twice: its match is designed to be won once and end in
		the Lobby, where the second half of the script waits. "PLAY AGAIN" stays locked,
		and the tutorial step lights "BACK TO LOBBY" next to it; that is why the button
		stays on screen instead of vanishing: it shows there is a path and that today it
		is not that one.
	]]
	local tutorial = self.Controllers.TutorialStepController
	local isTutorial = tutorial ~= nil and tutorial:IsTutorial()

	local playAgain = self:findButton(PLAY_AGAIN_NAME)
	if playAgain then
		self:setButtonEnabled(playAgain, not isTutorial)

		if not isTutorial then
			table.insert(self.connections, playAgain.MouseButton1Click:Connect(function()
				Framework:Fire("VotePlayAgain")
			end))
		end
	end

	local lobby = self:findButton(LOBBY_NAME)
	if lobby then
		table.insert(self.connections, lobby.MouseButton1Click:Connect(function()
			if self.leaving then return end
			self.leaving = true
			self:setLobbyButtonText(LEAVING_TEXT)
			Framework:Fire("RequestLobbyTeleport")
		end))
	end
end

--[[ animation ]]

--[[
	The single entry point for the screen. The sequence:

	  1. everything hidden, with the ScreenGui still disabled (no flash)
	  2. BackgroundFrame  1 -> BACKDROP_TRANSPARENCY
	  3. PANEL_DELAY wait
	  4. MainScreen       1 -> authored value
	  5. RewardTitle, MVPText, and the MVP ViewportFrame fade in together
	  6. RewardsContainer turns on and each label slides from inside its wrapper, one
	     every REWARD_STAGGER
	  7. ExpContainer, ExpAmount, and ExpOrnament turn on and the bar fills from the
	     previous XP to the current one
	  8. PlayAgain and Lobby fade in

	Changing the rhythm, easing, or order? It is here and in the constants at the top;
	no other part of the code knows these tweens.
]]
function ResultController:playRevealAnimation(screen : ScreenGui, info)
	if self.revealThread then
		pcall(task.cancel, self.revealThread)
		self.revealThread = nil
	end

	self:cancelTweens()

	local backdrop = screen:FindFirstChild(BACKDROP_NAME)
	local panel = screen:FindFirstChild(PANEL_NAME)

	if not panel then
		log:StudioWarn(`{SCREEN_NAME}.{PANEL_NAME} not found.`)
	end

	-- Before the snapshot and before the GUI turns on: the panel enters already with the result's art.
	self:applyPanelImage(panel, info.won ~= false)

	-- The old screen takes part in nothing; if it still exists, it stays out of the way.
	local legacy = screen:FindFirstChild(LEGACY_PANEL_NAME)
	if legacy and legacy:IsA("GuiObject") then
		legacy.Visible = false
	end

	-- The backdrop does not use a snapshot: its target is the constant, not the authored value.
	local backdropTarget = nil
	if backdrop and backdrop:IsA("GuiObject") then
		backdropTarget = {
			instance = backdrop,
			values = { BackgroundTransparency = BACKDROP_TRANSPARENCY },
		}
	end

	local panelValues = panel and self:snapshot(panel)
	local panelTarget = panelValues and { instance = panel, values = panelValues } or nil

	local title = panel and panel:FindFirstChild(TITLE_NAME)
	local mvpText = panel and panel:FindFirstChild(MVP_TEXT_NAME)
	local viewport = panel and panel:FindFirstChild(VIEWPORT_NAME)
	local rewards = panel and panel:FindFirstChild(REWARDS_NAME)
	local exp = panel and panel:FindFirstChild(EXP_NAME)
	local expText = panel and panel:FindFirstChild(EXP_TEXT_NAME)
	local playAgain = panel and panel:FindFirstChild(PLAY_AGAIN_NAME)
	local lobby = panel and panel:FindFirstChild(LOBBY_NAME)

	-- Step 1, synchronous: nothing may appear on the frame the GUI turns on.
	if backdropTarget then
		self:setTransparent(backdropTarget)
		backdropTarget.instance.Visible = false
	end
	if panelTarget then
		self:setTransparent(panelTarget)
		if panel:IsA("GuiObject") then
			panel.Visible = false
		end
	end

	local titleGroup = self:prepareGroup(title)
	local mvpTextGroup = self:prepareGroup(mvpText)

	-- The portrait is built before the GUI turns on, so it enters with the fade instead
	-- of popping in later. With no MVP to show, the frame just stays out of the reveal.
	local viewportGroup = nil
	if panel and self:populateMVP(panel, info) then
		viewportGroup = self:prepareGroup(viewport)
	elseif viewport and viewport:IsA("GuiObject") then
		viewport.Visible = false
	end

	local expGroup = self:prepareGroup(exp)
	local expTextGroup = self:prepareGroup(expText)
	local expOrnamentGroup = self:prepareGroup(panel and panel:FindFirstChild(EXP_ORNAMENT_NAME))
	local playAgainGroup = self:prepareGroup(playAgain)
	local lobbyGroup = self:prepareGroup(lobby)

	local wrappers = {}
	if rewards then
		if rewards:IsA("GuiObject") then
			rewards.Visible = false
		end

		wrappers = self:collectRewardWrappers(rewards, info)
		for _, wrapper in wrappers do
			self:setSlideStart(wrapper.label)
		end
	end

	screen.Enabled = true

	self.revealThread = task.spawn(function()
		if backdropTarget then
			backdropTarget.instance.Visible = true
			self:fadeIn(backdropTarget, BACKDROP_TIME)
		end

		task.wait(PANEL_DELAY)

		if panelTarget then
			if panel:IsA("GuiObject") then
				panel.Visible = true
			end
			self:fadeIn(panelTarget, ELEMENT_TIME)
		end

		task.wait(ELEMENT_STAGGER)
		self:revealGroup(titleGroup)
		self:revealGroup(mvpTextGroup)
		self:revealGroup(viewportGroup)

		-- Now the GUI has rendered: the frame's AbsoluteSize is valid, and the framing
		-- can be redone with the real aspect.
		self:frameMVPCamera()

		task.wait(ELEMENT_TIME + REWARD_DELAY)

		if rewards and rewards:IsA("GuiObject") then
			rewards.Visible = true
		end

		for index, wrapper in wrappers do
			if index > 1 then
				task.wait(REWARD_STAGGER)
			end
			self:slideIn(wrapper.label)
		end

		task.wait(REWARD_SLIDE_TIME + EXP_DELAY)

		self:revealGroup(expGroup)
		self:revealGroup(expTextGroup)
		self:revealGroup(expOrnamentGroup)

		if exp then
			self:playExpAnimation(exp, expText and expText:IsA("TextLabel") and expText or nil, info)
		end

		self:revealGroup(playAgainGroup)
		task.wait(ELEMENT_STAGGER)
		self:revealGroup(lobbyGroup)

		self.revealThread = nil
	end)
end

-- The panel's art on defeat. Victory's is the one authored in Studio.
local DEFEAT_PANEL_IMAGE = "rbxassetid://132074829939960"
local AUTHORED_IMAGE_ATTRIBUTE = "AuthoredImage"

--[=[
	Swaps `MainScreen`'s art by the result: defeat uses `DEFEAT_PANEL_IMAGE`, victory the
	authored one.

	The authored one is stored in an attribute on the panel itself the first time the
	screen opens. The same ScreenGui copy survives a "play again" without a respawn,
	and a victory after a defeat needs somewhere to return to.
]=]
function ResultController:applyPanelImage(panel : Instance?, won : boolean)
	if not panel or not panel:IsA("ImageLabel") then return end

	local authored = panel:GetAttribute(AUTHORED_IMAGE_ATTRIBUTE)
	if typeof(authored) ~= "string" then
		authored = panel.Image
		panel:SetAttribute(AUTHORED_IMAGE_ATTRIBUTE, authored)
	end

	panel.Image = if won then authored else DEFEAT_PANEL_IMAGE
end

--[[ API ]]

function ResultController:Show(info)
	local screen = self:getScreen()
	if not screen then return end

	info = info or {}
	self.leaving = false
	self.showing = true

	-- No placement ghost or selection ring over the screen.
	local placement = self.Controllers.UnitPlacementController
	if placement and placement.clearInteraction then
		placement:clearInteraction()
	end

	self:setInterfaceEnabled(false)
	self:bindButtons()

	-- The vote state may have arrived before RoundReward: the order between the
	-- two events is not guaranteed, so we reapply the last one received.
	self:applyPlayAgainState()
	self:setLobbyButtonText(LOBBY_TEXT)

	self:playRevealAnimation(screen, info)
end

function ResultController:Hide()
	if self.revealThread then
		pcall(task.cancel, self.revealThread)
		self.revealThread = nil
	end

	self:cancelTweens()
	self:clearMVPModel()

	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	self.leaving = false
	self.showing = false
	self.playAgainState = nil

	local screen = PlayerGui:FindFirstChild(SCREEN_NAME)
	if screen then
		screen.Enabled = false
	end

	self:setInterfaceEnabled(true)
end

--[=[
	Every new copy of the ScreenGui starts disabled.

	ResultScreen has `ResetOnSpawn`, so on every respawn the engine hands back a copy
	with the authored state, and it only takes someone leaving `MainScreen.Visible` on
	in Studio (to look at the art, for example) for the panel to appear over the match
	until the round ends. Disabling the copy on arrival frees the screen from that
	dependency: `Show` shows it, and nothing else does.
]=]
function ResultController:watchScreen()
	local function hide(child : Instance)
		if self.showing then return end
		if child:IsA("ScreenGui") and child.Name == SCREEN_NAME then
			child.Enabled = false
		end
	end

	PlayerGui.ChildAdded:Connect(hide)

	for _, child in PlayerGui:GetChildren() do
		hide(child)
	end
end

function ResultController:construct()
	self:watchScreen()

	Framework:Listen("RoundReward", function(info)
		self:Show(info)
	end)

	Framework:Listen("PlayAgainState", function(state)
		self.playAgainState = state
		self:applyPlayAgainState()
	end)

	-- The round restarted: the screen leaves and the HUD returns.
	Framework:Listen("RoundRestarted", function()
		self:Hide()
	end)

	Framework:Listen("LobbyTeleportFailed", function()
		self.leaving = false
		self:setLobbyButtonText(LOBBY_TEXT)
	end)
end

function ResultController:start()
end

function ResultController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return ResultController
