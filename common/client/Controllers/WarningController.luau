local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("WarningController")

local WarningConfig = SharedConfig.WarningConfig
local Config = WarningConfig.Label

--[[
	The big warning in the middle of the screen: `Interface.WeatherWarning`.

	This controller is the **only** one that touches the label. Anything with
	something to announce sends the finished sentence:

		local Warning = Framework:Get("WarningController")

		Warning:Show("WARNING! FOG COMING IN 3 ROUNDS", {
			Priority = WarningConfig.Priority.Weather,
		})

	The text slides down from above to the authored position while the text and
	UIStroke transparency goes from 1 to 0: it looks like the sentence is forming in
	place. After `Hold` seconds it slides back up and disappears.

	The whole animation is built from the position the designer left in StarterGui:
	that is the destination, and the start is it minus `SlideOffset`. So moving the
	label in Studio requires no change here.

	**Priority.** A new warning beats the one on screen when its priority ties or
	wins: an owner's second warning is always more current than its first. A
	lower-priority warning is refused (`Show` returns `false`) instead of queued:
	when the server restart is on screen, wave 8's weather is not news.

	It lives in `common/` because both places show warnings.

	See docs/common/screen-warnings.md.
]]

local WarningController = {
	Controllers = {}
}

WarningController.Label = nil :: TextLabel?
WarningController.BasePosition = nil :: UDim2?
WarningController.Token = 0

-- Priority of the warning on screen. Zero means the screen is free.
WarningController.Priority = 0

WarningController.Warned = false

--[[ INTERNAL ]]

--[=[
	The warning's TextLabel, the first time it is needed.

	Resolved late and cached afterward: the Interface may not have replicated when
	the controller loads, and a `WaitForChild` in `init` would hold up the client
	boot for a label that only shows around wave 4.
]=]
function WarningController:getLabel() : TextLabel?
	local label = self.Label
	if label and label.Parent then
		return label
	end

	local interface = PlayerGui:FindFirstChild("Interface")
	local found = interface and interface:FindFirstChild(Config.Name)
	if not found or not found:IsA("TextLabel") then
		return nil
	end

	self.Label = found
	self.BasePosition = found.Position

	return found
end

--[=[
	Text and stroke transparency at once.

	The stroke goes along on purpose: fading in only the text would leave a solid
	outline behind an invisible letter, exactly the opposite of the intended effect.
]=]
function WarningController:tweenTo(label : TextLabel, position : UDim2, transparency : number, time : number)
	local info = TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	TweenService:Create(label, info, {
		Position = position,
		TextTransparency = transparency,
	}):Play()

	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		TweenService:Create(stroke, info, { Transparency = transparency }):Play()
	end
end

--[=[
	Noise when the label does not show up.

	A place with no `Interface` at all (the Lobby, today) has no on-screen warning by
	design: it is not a mistake, and a warning there would only teach people to
	ignore warnings. An `Interface` **without** the label is a mistake, and that
	deserves noise: once, so a recurring warning (the restart one) does not become
	spam.
]=]
function WarningController:warnMissing()
	if self.Warned then return end
	if not PlayerGui:FindFirstChild("Interface") then return end

	self.Warned = true
	log:StudioWarn(`could not find the TextLabel "{Config.Name}" in PlayerGui.Interface.`)
end

--[[ API ]]

export type ShowOptions = {
	Priority : number?,
	Hold : number?,
}

--[=[
	Puts a sentence on screen.

	Returns `false` when the warning was refused: a label that does not exist yet in
	this place, or a lower priority than the warning on screen.
]=]
function WarningController:Show(text : string, options : ShowOptions?) : boolean
	local priority = (options and options.Priority) or 0
	if priority < self.Priority then
		return false
	end

	local label = self:getLabel()
	if not label then
		self:warnMissing()
		return false
	end

	label.Text = text

	local basePosition = self.BasePosition or label.Position
	local hiddenPosition = UDim2.new(
		basePosition.X.Scale,
		basePosition.X.Offset,
		basePosition.Y.Scale - Config.SlideOffset,
		basePosition.Y.Offset
	)

	-- One token per warning: the exit's `task.delay` only applies if nobody asked for
	-- another warning in between, or it would erase the text that just came in.
	self.Token += 1
	local token = self.Token
	self.Priority = priority

	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	label.Position = hiddenPosition
	label.TextTransparency = 1
	if stroke then
		stroke.Transparency = 1
	end
	label.Visible = true

	self:tweenTo(label, basePosition, 0, Config.FadeIn)

	local hold = (options and options.Hold) or Config.Hold

	task.delay(Config.FadeIn + hold, function()
		if self.Token ~= token then return end
		if not label.Parent then return end

		self:tweenTo(label, hiddenPosition, 1, Config.FadeOut)

		task.delay(Config.FadeOut, function()
			if self.Token ~= token then return end
			if not label.Parent then return end

			label.Visible = false
			label.Position = basePosition
			self.Priority = 0
		end)
	end)

	return true
end

--[=[
	Hides the warning immediately, without animation. That is what a round restart
	needs: the previous round's warning must not stay on screen.

	`maxPriority` is "clear only what is mine": passing its own priority, the caller
	does not erase a warning more important than its own. With no argument, it clears
	whatever is there.
]=]
function WarningController:Hide(maxPriority : number?)
	if maxPriority and self.Priority > maxPriority then return end

	self.Token += 1
	self.Priority = 0

	local label = self.Label
	if not label or not label.Parent then return end

	label.Visible = false
	if self.BasePosition then
		label.Position = self.BasePosition
	end
end

--[[ LIFECYCLE ]]

function WarningController:start()
end

function WarningController:init()
end

return WarningController
