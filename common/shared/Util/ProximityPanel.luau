local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

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

	**Walk-in lock.** `LockWalkIn(reason, allow)` stops walking into a radius from
	opening any panel whose `Name` is not in `allow` (the tutorial uses it so a new
	player cannot wander into a shop and softlock the script). Crossings are still
	tracked while locked, so lifting the lock while standing inside a radius does
	not pop the panel open; the player has to leave and come back. Leaving still
	closes. `Open`, `Toggle` and `EnterRange` are not affected: those come from
	buttons, and the tutorial gates buttons through `ButtonGateController`. Several
	reasons may hold a lock at once; a panel opens on walk-in only when every
	active lock allows it.

	**No map spot works too.** A panel with no place in the world (the Robux shop,
	only a HUD button; the settings panel, only a TopbarPlus icon) has no
	`GetReference`: distance is never measured, and it lives on
	`Open`/`Close`/`Toggle` and the X. Everything else stays the same.

	**The outer frame (`Wrapper`) comes and goes**, not the ScreenGui: `ShopUI` holds
	several shops, and each lights its own frame. `CanDisable` is the other side:
	while it returns false, closing hides only the frame and leaves the ScreenGui to
	the neighbor.

	**A new copy starts hidden and gives the screen back.** Dying with the panel
	open brings a new ScreenGui and resets state here; without giving back, the hide
	request would stay with the panel closed and the player would respawn without a
	HUD and with a blurred background.

	Cascade exists only in the Lobby place, so it is looked up the first time a panel
	binds, not at the top of the file: the Game also mounts this module and has no
	runtime. There, a panel that asks for an `Animation` gets a plain scale tween on
	its frame instead (the settings panel, which lives in every place).

	**The ScreenGui may live in a folder** (`Folder`): `SharedUIs` is a folder that
	StarterGui copies whole, and a screen inside it is not a direct child of
	`PlayerGui`. See docs/common/proximity-panel.md.
]]

local CHARACTER_ROOT = "HumanoidRootPart"
local CASCADE_RUNTIME = "CascadeRuntimeEngine"
local CLOSE_BUTTON_NAME = "Close"
local WAIT_TIMEOUT = 10

-- The background blur: the shared `UIBlur` (`LightingUtil.GetUIBlur`), the same as
-- `UILibraryController`'s. Two blurs would add up and double the background blur.
local BLUR_SIZE = 24
local BLUR_FALLBACK_TIME = 0.25
local BLUR_EASING_STYLE = Enum.EasingStyle.Quad
local BLUR_EASING_DIRECTION = Enum.EasingDirection.Out

local DEFAULT_INTERVAL = 0.2

-- The scale tween used in place of the Cascade animation where the place has no
-- Cascade. It grows the whole frame (`Wrapper`), not only the art, so an X authored
-- next to the art grows with it.
local FALLBACK_OPEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FALLBACK_CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FALLBACK_SCALE_NAME = "PanelScale"

export type Options = {
	-- The name shown in warnings. Also the name the walk-in lock's allow list matches.
	Name : string,

	-- `PlayerGui.<Folder?>.<ScreenGui>.<Wrapper>.<Panel>`. `Panel` is the art the
	-- animation writes to (`UIScale/Scale` and `ImageTransparency`). `Folder` is only
	-- for a ScreenGui that lives inside a folder (`SharedUIs`).
	Folder : string?,
	ScreenGui : string,
	Wrapper : string,
	Panel : string,

	-- The Cascade animation name. Without it the panel only turns on and off. In a
	-- place without Cascade it becomes the fallback scale tween.
	Animation : string?,

	-- The request name for `InterfaceController`. Unique per panel: sharing the name
	-- would let one panel give back the screen another requested.
	HideReason : string,

	-- Other ScreenGuis that stay on screen while the panel is open, besides its own
	-- (the TopbarPlus bar, when the panel opens from an icon there).
	Except : { string }?,

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

-- nil until looked up; false when the place has no Cascade.
local AnimationService : any = nil

-- [reason] = { [panelName] = true }: the panels each active lock still lets open on walk-in.
local WalkInLocks : { [string] : { [string] : boolean } } = {}

-- Every live panel, so a new lock can close the ones it forbids.
local LivePanels = setmetatable({}, { __mode = "k" })

--[=[
	The Cascade runtime, or nil in a place without one.

	The lookup waits for the game to load: only then has everything the place ships
	in ReplicatedStorage arrived, and "not found" means "this place has no Cascade"
	instead of "not replicated yet".
]=]
local function getAnimationService() : any?
	if AnimationService == nil then
		if not game:IsLoaded() then
			game.Loaded:Wait()
		end

		local runtime = ReplicatedStorage:FindFirstChild(CASCADE_RUNTIME)
		AnimationService = if runtime then require(runtime:WaitForChild("AnimationService")) else false
	end

	return AnimationService or nil
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

	-- What the hide request leaves on screen: the panel's own ScreenGui, plus `Except`.
	self.Except = { options.ScreenGui }
	for _, name in options.Except or {} do
		table.insert(self.Except, name)
	end

	self.ScreenGui = nil
	self.Wrapper = nil
	self.Panel = nil
	self.Track = nil

	-- The fallback when there is no Cascade: the frame's `UIScale` and its tween.
	self.Scale = nil
	self.ScaleTween = nil

	self.IsOpenState = false
	self.InRange = false
	self.ProximityClock = 0

	LivePanels[self] = true

	return self
end

--[[ WALK-IN LOCK ]]

--- Whether walking into this panel's radius may open it right now.
function ProximityPanel.IsWalkInAllowed(name : string) : boolean
	for _, allow in WalkInLocks do
		if not allow[name] then
			return false
		end
	end

	return true
end

--- Whether any walk-in lock is active.
function ProximityPanel.IsWalkInLocked() : boolean
	return next(WalkInLocks) ~= nil
end

--[=[
	Stops walk-in opening for every panel not named in `allow`, under `reason`.
	Calling again with the same reason replaces its allow list. Walk-in panels that
	are open and now forbidden close.
]=]
function ProximityPanel.LockWalkIn(reason : string, allow : { string }?)
	local set = {}
	for _, name in allow or {} do
		set[name] = true
	end

	WalkInLocks[reason] = set

	for panel in LivePanels do
		if panel.Options.GetReference and panel:IsOpen() and not ProximityPanel.IsWalkInAllowed(panel.Options.Name) then
			panel:Close()
		end
	end
end

--- Lifts the lock held under `reason`. Other reasons' locks stay.
function ProximityPanel.UnlockWalkIn(reason : string)
	WalkInLocks[reason] = nil
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

--[=[
	The fallback for a place without Cascade: the frame grows from nothing on open and
	shrinks back on close. Each tween starts from wherever the last one got, so closing
	mid-open does not jump; the frame leaves only when a closing tween finishes.
]=]
function ProximityPanel:_playScale(open : boolean)
	local scale = self.Scale
	if not scale then
		return
	end

	if self.ScaleTween then
		self.ScaleTween:Cancel()
	end

	local tween = TweenService:Create(scale, if open then FALLBACK_OPEN_INFO else FALLBACK_CLOSE_INFO, {
		Scale = if open then 1 else 0,
	})

	tween.Completed:Connect(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed or open or self.IsOpenState then
			return
		end

		if self.ScreenGui and self.ScreenGui.Parent then
			self:_hide()
		end
	end)

	self.ScaleTween = tween
	tween:Play()
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
	self.Scale = nil
	self.ScaleTween = nil

	local animationService = if options.Animation then getAnimationService() else nil

	if options.Animation and not animationService then
		-- No Cascade in this place: the frame's own `UIScale`, or one made for it.
		local scale = wrapper:FindFirstChildWhichIsA("UIScale")
		if not scale then
			scale = Instance.new("UIScale")
			scale.Name = FALLBACK_SCALE_NAME
			scale.Parent = wrapper
		end

		scale.Scale = 0
		self.Scale = scale

		self.BindMaid:GiveTask(function()
			if self.ScaleTween then
				self.ScaleTween:Cancel()
				self.ScaleTween = nil
			end
		end)
	elseif animationService then
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

		self.Track = animationService.CreateTrack(panel, options.Animation)

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
		if ProximityPanel.IsWalkInAllowed(self.Options.Name) then
			self:Open()
		end
	else
		self:Close()
	end
end

--[[ API ]]

--[=[
	Binds every copy of the ScreenGui that shows up in `container`. The connection
	goes to `maid`, which is the panel's own for `PlayerGui` and the folder's for a
	`Folder`.
]=]
function ProximityPanel:_watchScreens(container : Instance, maid : any)
	local screenName = self.Options.ScreenGui

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == screenName then
			self:_bind(child)
		end
	end

	maid:GiveTask(container.ChildAdded:Connect(onChild))

	for _, child in container:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[=[
	For a ScreenGui inside a folder: follows each copy of the folder in `PlayerGui`
	and, inside it, the ScreenGui. Each folder has its own maid, cleaned when the
	folder leaves, so a folder StarterGui copies again does not leave a connection
	behind on the old one.
]=]
function ProximityPanel:_watchFolders(playerGui : Instance)
	local folderName = self.Options.Folder

	-- [folder] = Maid
	local folders = {}

	local function onChild(child : Instance)
		if child.Name ~= folderName or child:IsA("LayerCollector") or folders[child] then
			return
		end

		local maid = Maid.new()
		folders[child] = maid

		self:_watchScreens(child, maid)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))
	self.Maid:GiveTask(playerGui.ChildRemoved:Connect(function(child : Instance)
		local maid = folders[child]
		if maid then
			folders[child] = nil
			maid:DoCleaning()
		end
	end))

	self.Maid:GiveTask(function()
		for _, maid in folders do
			maid:DoCleaning()
		end

		table.clear(folders)
	end)

	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
end

--- Starts following `PlayerGui` and the distance. Call once, in `construct`.
function ProximityPanel:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	if self.Options.Folder then
		self:_watchFolders(playerGui)
	else
		self:_watchScreens(playerGui, self.Maid)
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
		ScreenGui, or the request would hide the panel it is opening, plus whatever
		the controller asked to keep.
	]]
	local interface = self.Options.InterfaceController
	if interface then
		interface:Hide(self.Options.HideReason, { Except = self.Except })
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
	elseif self.Scale then
		self:_playScale(true)
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
	elseif self.Scale then
		-- The same, when the shrinking tween ends (see `_playScale`).
		self:_playScale(false)
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
	LivePanels[self] = nil
	self.Maid:DoCleaning()
end

return ProximityPanel