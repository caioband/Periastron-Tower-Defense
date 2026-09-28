local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Signal = require(Packages.Signal)
local LightingUtil = require(script.Parent.LightingUtil)
local Log = require(script.Parent.Log)

--[[
	A Lobby panel that opens when the player reaches a spot on the map and closes
	when they leave: the crate shop, the card shop, and the contracts board.

	This module holds **only** the shared behavior (proximity, the Cascade
	`OpenShop`, the background blur, the screen request to `InterfaceController`,
	the X, and `ResetOnSpawn` care). What the panel shows belongs to its controller,
	through hooks:

	  - `OnBind(screenGui, wrapper, panel, maid)`: each new copy of the ScreenGui.
	    `maid` is cleaned on the next bind, so content connections go there.
	  - `BeforeOpen()`: right before the panel enters, already visible.

	**Proximity: only crossing acts.** Entering the radius opens and leaving closes;
	closing with the X while standing there does not reopen on the next tick. The
	panel returns when the player leaves and enters again. `EnterRange` is for code
	that brings the player there from outside (the HUD teleport): it marks the entry
	and opens, or the exit would never happen and the panel would stay on screen.

	**No map spot works too.** A panel with no place in the world (the Robux shop,
	only a HUD button) has no `GetReference`: distance is never measured, and it
	lives on `Open`/`Close`/`Toggle` and the X. Everything else stays the same.

	**The outer frame (`Wrapper`) comes and goes**, not the ScreenGui: `ShopUI` holds
	several shops, and each lights its own frame. `CanDisable` is the other side:
	while it returns false, closing hides only the frame and leaves the ScreenGui to
	the neighbor.

	**A new copy starts hidden and gives the screen back.** Dying with the panel
	open brings a new ScreenGui and resets state here; without giving back, the hide
	request would stay with the panel closed and the player would respawn without a
	HUD and with a blurred background.

	Cascade exists only in the Lobby place, so it is looked up the first time a panel
	opens, not at the top of the file: the Game also mounts this module and has no
	runtime. See docs/common/proximity-panel.md.
]]

local CHARACTER_ROOT = "HumanoidRootPart"
local CLOSE_BUTTON_NAME = "Close"
local WAIT_TIMEOUT = 10

-- The background blur: the shared `UIBlur` (`LightingUtil.GetUIBlur`), the same as
-- `UILibraryController`'s. Two blurs would add up and double the background blur.
local BLUR_SIZE = 24
local BLUR_FALLBACK_TIME = 0.25
local BLUR_EASING_STYLE = Enum.EasingStyle.Quad
local BLUR_EASING_DIRECTION = Enum.EasingDirection.Out

local DEFAULT_INTERVAL = 0.2

export type Options = {
	-- The name shown in warnings.
	Name : string,

	-- `PlayerGui.<ScreenGui>.<Wrapper>.<Panel>`. `Panel` is the art the animation
	-- writes to (`UIScale/Scale` and `ImageTransparency`).
	ScreenGui : string,
	Wrapper : string,
	Panel : string,

	-- The Cascade animation name. Without it the panel only turns on and off.
	Animation : string?,

	-- The request name for `InterfaceController`. Unique per panel: sharing the name
	-- would let one panel give back the screen another requested.
	HideReason : string,

	-- The radius center, reread on every measurement (the map may swap the part).
	-- Absent means "no place in the world": nothing is measured, it only opens by hand.
	GetReference : (() -> Vector3?)?,
	Radius : number?,
	Interval : number?,

	InterfaceController : any?,

	-- Whether the ScreenGui may be disabled on close. Only needed when it is shared.
	CanDisable : (() -> boolean)?,

	OnBind : ((screenGui : ScreenGui, wrapper : GuiObject, panel : GuiObject, maid : any) -> ())?,
	BeforeOpen : (() -> ())?,
}

local ProximityPanel = {}
ProximityPanel.__index = ProximityPanel

local AnimationService = nil

local function getAnimationService()
	if AnimationService == nil then
		local runtime = ReplicatedStorage:WaitForChild("CascadeRuntimeEngine")
		AnimationService = require(runtime:WaitForChild("AnimationService"))
	end

	return AnimationService
end

function ProximityPanel.new(options : Options)
	local self = setmetatable({}, ProximityPanel)

	self.Options = options

	self.Maid = Maid.new()

	-- The current ScreenGui copy's bind. Cleaned on each new copy.
	self.BindMaid = Maid.new()

	-- The blur tween lives outside the bind: it belongs to Lighting, not the ScreenGui.
	self.BlurMaid = Maid.new()

	self.Maid:GiveTask(self.BindMaid)
	self.Maid:GiveTask(self.BlurMaid)

	self.Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),
	}

	self.ScreenGui = nil
	self.Wrapper = nil
	self.Panel = nil
	self.Track = nil

	self.IsOpenState = false
	self.InRange = false
	self.ProximityClock = 0

	return self
end

--[[ INTERNAL ]]

--[=[
	Turns the ScreenGui on and off, always through `InterfaceController` when it
	exists: it keeps what each GUI's owner wanted, and writing `Enabled` directly
	during a request would make the right value be read too late.
]=]
function ProximityPanel:_setEnabled(enabled : boolean)
	local screenGui = self.ScreenGui
	if not screenGui or not screenGui.Parent then
		return
	end

	if not enabled and self.Options.CanDisable and not self.Options.CanDisable() then
		return
	end

	local interface = self.Options.InterfaceController
	if interface then
		interface:SetEnabled(screenGui, enabled)
	else
		screenGui.Enabled = enabled
	end
end

--- The end of closing: the frame hides, and the ScreenGui goes with it if allowed.
function ProximityPanel:_hide()
	if self.Wrapper and self.Wrapper.Parent then
		self.Wrapper.Visible = false
	end

	self:_setEnabled(false)
end

--[=[
	The blur rises on open and falls on close, over the animation's own duration, so
	retiming `OpenShop` in the plugin moves the blur too. One tween at a time:
	closing mid-open falls from where the rise got to.
]=]
function ProximityPanel:_playBlur(open : boolean)
	self.BlurMaid:DoCleaning()

	local duration = (self.Track and self.Track.Duration) or BLUR_FALLBACK_TIME
	local info = TweenInfo.new(duration, BLUR_EASING_STYLE, BLUR_EASING_DIRECTION)

	local tween = LightingUtil.TweenUIBlur(if open then BLUR_SIZE else 0, info)
	if not tween then
		return
	end

	self.BlurMaid:GiveTask(function()
		tween:Cancel()
	end)
end

--- Gives the screen back: the rest of the UI returns and the blur leaves. Idempotent.
function ProximityPanel:_releaseScreen()
	local interface = self.Options.InterfaceController
	if interface then
		interface:Show(self.Options.HideReason)
	end

	self:_playBlur(false)
end

--[=[
	The track is created once per copy and kept: opening and closing reverse the same
	animation, so closing mid-open continues from where the panel got instead of
	jumping.
]=]
function ProximityPanel:_playTrack(reverse : boolean)
	local track = self.Track
	if not track then
		return
	end

	if track.State ~= "Playing" then
		track:Scrub(reverse and track.Duration or 0)
	end

	track:SetSpeed(reverse and -1 or 1)
	track:Play()
end

function ProximityPanel:_bind(screenGui : ScreenGui)
	local options = self.Options

	local wrapper = screenGui:WaitForChild(options.Wrapper, WAIT_TIMEOUT)
	local panel = wrapper and wrapper:WaitForChild(options.Panel, WAIT_TIMEOUT)

	if not wrapper or not panel then
		Log.new(options.Name):StudioWarn(`could not find {options.ScreenGui}.{options.Wrapper}.{options.Panel}.`)
		return
	end

	self.BindMaid:DoCleaning()

	self.ScreenGui = screenGui
	self.Wrapper = wrapper
	self.Panel = panel

	wrapper.Visible = false
	panel.Visible = true

	--[[
		The X, if the designer authored one. Searched in depth from the frame, not the
		ScreenGui: in `ShopUI` that would reach the neighboring shop's X.
	]]
	local closeButton = wrapper:FindFirstChild(CLOSE_BUTTON_NAME, true)
	if closeButton and closeButton:IsA("GuiButton") then
		self.BindMaid:GiveTask(closeButton.Activated:Connect(function()
			self:Close()
		end))
	end

	self.Track = nil

	if options.Animation then
		--[[
			`OpenShop` writes `UIScale/Scale`. A panel without an authored `UIScale`
			would appear by fading, without growing; creating one is harmless for
			panels that have their own, because the animation finds the authored one
			first.
		]]
		if not panel:FindFirstChildWhichIsA("UIScale") then
			local scale = Instance.new("UIScale")
			scale.Name = "PanelScale"
			scale.Parent = panel
		end

		self.Track = getAnimationService().CreateTrack(panel, options.Animation)

		if self.Track then
			local connection = self.Track.Completed:Connect(function()
				-- Only the closing pass ends with the panel off screen.
				if not self.IsOpenState and screenGui.Parent then
					self:_hide()
				end
			end)

			self.BindMaid:GiveTask(function()
				connection.Disconnect()
			end)
		end
	end

	self.IsOpenState = false
	self:_hide()
	self:_releaseScreen()

	-- A new copy means a respawn: the player may still be standing on the spot, and
	-- the next measurement must open the new panel.
	self.InRange = false

	if options.OnBind then
		options.OnBind(screenGui, wrapper, panel, self.BindMaid)
	end
end

function ProximityPanel:_updateProximity()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)
	local position = root and self.Options.GetReference and self.Options.GetReference()

	local inRange = false
	if position and root then
		inRange = (root.Position - position).Magnitude <= (self.Options.Radius or 0)
	end

	if inRange == self.InRange then
		return
	end

	self.InRange = inRange

	if inRange then
		self:Open()
	else
		self:Close()
	end
end

--[[ API ]]

--- Starts following `PlayerGui` and the distance. Call once, in `construct`.
function ProximityPanel:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenName = self.Options.ScreenGui

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == screenName then
			self:_bind(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end

	-- A panel with no map spot measures nothing: without this, Heartbeat would run
	-- every frame only to find there is nothing to measure.
	if not self.Options.GetReference then
		return
	end

	local interval = self.Options.Interval or DEFAULT_INTERVAL

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.ProximityClock += deltaTime

		if self.ProximityClock < interval then
			return
		end

		self.ProximityClock = 0
		self:_updateProximity()
	end))
end

function ProximityPanel:IsOpen() : boolean
	return self.IsOpenState == true
end

function ProximityPanel:Open()
	if not self.ScreenGui or not self.ScreenGui.Parent or self.IsOpenState then
		return
	end

	self.IsOpenState = true

	--[[
		The panel is the only thing on screen while open. `Except` is its own
		ScreenGui, or the request would hide the panel it is opening.
	]]
	local interface = self.Options.InterfaceController
	if interface then
		interface:Hide(self.Options.HideReason, { Except = { self.Options.ScreenGui } })
	end

	--[[
		Through `_setEnabled`, not `Enabled` directly: the `Enabled` signal arrives at
		the end of the frame, and the panel turns on in the **same** instant the
		request sweeps the GUIs. Writing directly, the request would read the previous
		`false` as what the owner wanted.
	]]
	self:_setEnabled(true)

	-- The frame turns on **before** the animation, or it would run with the panel off
	-- screen and the panel would appear fully formed at the end.
	if self.Wrapper and self.Wrapper.Parent then
		self.Wrapper.Visible = true
	end

	if self.Options.BeforeOpen then
		self.Options.BeforeOpen()
	end

	if self.Track then
		self:_playTrack(false)
	end

	self:_playBlur(true)

	self.Signals.OpenChanged:Fire(true)
end

function ProximityPanel:Close()
	if not self.ScreenGui or not self.IsOpenState then
		return
	end

	self.IsOpenState = false

	-- Given back at the start of closing: the rest of the UI returns **behind** the
	-- panel instead of appearing all at once after it leaves.
	self:_releaseScreen()

	if self.Track then
		-- The panel leaves when the reversed animation ends (see `_bind`).
		self:_playTrack(true)
	else
		self:_hide()
	end

	self.Signals.OpenChanged:Fire(false)
end

function ProximityPanel:Toggle()
	if self.IsOpenState then
		self:Close()
	else
		self:Open()
	end
end

--[=[
	For code that puts the player on the spot without walking (the HUD teleport):
	marks the entry and opens. Without the mark, the exit crossing would never
	happen and the panel would stay on screen however far they walked.
]=]
function ProximityPanel:EnterRange()
	self.InRange = true
	self:Open()
end

function ProximityPanel:Destroy()
	self.Maid:DoCleaning()
end

return ProximityPanel
