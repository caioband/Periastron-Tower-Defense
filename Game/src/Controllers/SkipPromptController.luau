local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("SkipPromptController")

local SkipConfig = SharedConfig.SkipConfig

local INTERFACE_NAME = "Interface"
local WAIT_TIMEOUT = 60

local TWEEN_STYLE = Enum.EasingStyle.Quad
local TWEEN_DIRECTION = Enum.EasingDirection.Out

--[=[
	The skip-wave prompt: `Interface.SkipPrompt`.

	`SkipService` decides when it appears; only the screen lives here. The server
	sends `SkipState` on every change (votes, how many are missing, whether this
	player already voted) and the prompt comes in or leaves according to `active`.

	**The animation is `WeatherWarning`'s**: the prompt slides down from `SlideOffset`
	above its authored spot while transparency goes from 1 to the authored value. It
	goes to the authored value, not zero, because the prompt has a transparent
	background, a 20% shadow, and an opaque image on the same branch: animating
	everything to zero would paint a solid box behind the art. The values are read
	once, at bind, before any animation, so repainting in Studio is enough.

	**Cancel hides, but does not vote against.** The click removes the vote of a
	player who had voted and hides the prompt only for them, until the next vote:
	each opening comes with a new `token` from the server, and a token this client has
	not dismissed shows up again normally.

	See docs/game/skip-wave.md.
]=]
local SkipPromptController = {}

--[[ INTERNAL ]]

--[=[
	Every (instance, transparency property) pair in the prompt, with the value the
	designer left. It is the list the animation walks in both directions.

	`GuiObject.Transparency` is left out on purpose: it is an alias of
	`BackgroundTransparency`, and animating both would leave two tweens fighting over
	the same property.
]=]
function SkipPromptController:_collectFades(root : Instance)
	local fades = {}

	local function add(instance : Instance, property : string)
		table.insert(fades, {
			Instance = instance,
			Property = property,
			Target = (instance :: any)[property],
		})
	end

	local function collect(instance : Instance)
		if instance:IsA("GuiObject") then
			add(instance, "BackgroundTransparency")

			if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
				add(instance, "TextTransparency")
				add(instance, "TextStrokeTransparency")
			end

			if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
				add(instance, "ImageTransparency")
			end
		elseif instance:IsA("UIStroke") or instance:IsA("UIShadow") then
			add(instance, "Transparency")
		end
	end

	collect(root)
	for _, descendant in root:GetDescendants() do
		collect(descendant)
	end

	return fades
end

--[=[
	The transparency of everything at once. `progress` is 0 for hidden and 1 for the
	prompt as the designer painted it.

	No tween when `time` is nil: that is how the initial state is set up, before the
	entrance animation.
]=]
function SkipPromptController:_applyFade(progress : number, time : number?)
	local info = time and TweenInfo.new(time, TWEEN_STYLE, TWEEN_DIRECTION)

	for _, fade in self.Fades do
		local instance = fade.Instance :: any
		if not instance.Parent then continue end

		local value = 1 + (fade.Target - 1) * progress
		local tweened = false

		-- A property TweenService refuses (a new UI class that does not animate yet)
		-- jumps straight to the value instead of breaking the others' animation. It is
		-- marked in the list so it is not retried every screen frame.
		if info and not fade.NoTween then
			tweened = pcall(function()
				TweenService:Create(instance, info, { [fade.Property] = value }):Play()
			end)

			fade.NoTween = not tweened
		end

		if not tweened then
			instance[fade.Property] = value
		end
	end
end

function SkipPromptController:_hiddenPosition() : UDim2
	local base = self.BasePosition

	return UDim2.new(
		base.X.Scale,
		base.X.Offset,
		base.Y.Scale - SkipConfig.SlideOffset,
		base.Y.Offset
	)
end

function SkipPromptController:_show()
	local prompt = self.Prompt
	if not prompt or self.Shown then return end

	self.Shown = true
	self.AnimToken += 1

	-- The children come disabled from Studio (the whole prompt starts hidden); the
	-- transparency does the entrance, so here they only need to exist on
	-- screen.
	for _, descendant in prompt:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.Visible = true
		end
	end

	prompt.Position = self:_hiddenPosition()
	self:_applyFade(0)
	prompt.Visible = true

	TweenService:Create(prompt, TweenInfo.new(SkipConfig.FadeIn, TWEEN_STYLE, TWEEN_DIRECTION), {
		Position = self.BasePosition,
	}):Play()

	self:_applyFade(1, SkipConfig.FadeIn)
end

function SkipPromptController:_hide()
	local prompt = self.Prompt
	if not prompt or not self.Shown then return end

	self.Shown = false
	self.AnimToken += 1
	local token = self.AnimToken

	TweenService:Create(prompt, TweenInfo.new(SkipConfig.FadeOut, TWEEN_STYLE, TWEEN_DIRECTION), {
		Position = self:_hiddenPosition(),
	}):Play()

	self:_applyFade(0, SkipConfig.FadeOut)

	task.delay(SkipConfig.FadeOut, function()
		-- A `_show` during the exit wins: the prompt on screen now is its prompt, and
		-- disabling here would erase a new vote.
		if self.AnimToken ~= token then return end
		if not prompt.Parent then return end

		prompt.Visible = false
		prompt.Position = self.BasePosition
	end)
end

function SkipPromptController:_updateCount()
	local state = self.State
	local label = self.CountLabel
	if not state or not label then return end

	label.Text = string.format(SkipConfig.CountText, state.votes or 0, state.required or 0)
end

--[=[
	The latest state from the server, on screen.

	The prompt only appears if the player has not dismissed **this** vote: the
	`token` changes on every opening, so Cancel applies to the vote it was clicked in
	and not to the next ones.
]=]
function SkipPromptController:_apply()
	local state = self.State
	if not state or not self.Prompt then return end

	self:_updateCount()

	if state.active and self.DismissedToken ~= state.token then
		self:_show()
	else
		self:_hide()
	end
end

function SkipPromptController:_bind() : boolean
	local interface = PlayerGui:WaitForChild(INTERFACE_NAME, WAIT_TIMEOUT)
	local prompt = interface and interface:WaitForChild(SkipConfig.Name, WAIT_TIMEOUT)

	if not prompt or not prompt:IsA("GuiObject") then
		log:StudioWarn(`could not find {INTERFACE_NAME}.{SkipConfig.Name}.`)
		return false
	end

	self.Prompt = prompt
	self.BasePosition = prompt.Position
	self.Fades = self:_collectFades(prompt)
	self.CountLabel = prompt:FindFirstChild(SkipConfig.CountName)

	prompt.Visible = false

	local confirm = prompt:FindFirstChild(SkipConfig.ConfirmName)
	if confirm and confirm:IsA("GuiButton") then
		confirm.MouseButton1Click:Connect(function()
			Framework:Fire("VoteSkip", true)
		end)
	end

	local cancel = prompt:FindFirstChild(SkipConfig.CancelName)
	if cancel and cancel:IsA("GuiButton") then
		cancel.MouseButton1Click:Connect(function()
			self.DismissedToken = self.State and self.State.token
			Framework:Fire("VoteSkip", false)
			self:_hide()
		end)
	end

	return true
end

--[[ LIFECYCLE ]]

function SkipPromptController:construct()
	--[[
		`Listen` goes in before `_bind` because the bind waits for the Interface to
		replicate: a state arriving during that wait would be lost, and the prompt would
		only reappear on the next vote change.
	]]
	Framework:Listen("SkipState", function(state)
		if typeof(state) ~= "table" then return end

		self.State = state
		self:_apply()
	end)

	task.spawn(function()
		if not self:_bind() then
			return
		end

		-- The state that was already live when this client loaded. A player joining in the
		-- middle of an open vote needs to see it; `SkipState` only goes out on its own
		-- when something changes.
		Framework:Fire("RequestSkipState")

		self:_apply()
	end)
end

function SkipPromptController:start()
end

function SkipPromptController:init()
	self.Shown = false
	self.AnimToken = 0
	self.DismissedToken = nil
	self.State = nil
	self.Fades = {}

	self:construct()
end

return SkipPromptController
