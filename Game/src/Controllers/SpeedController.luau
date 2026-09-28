local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Me = require(Vendor.Me)
local Framework = Me.new()

local SpeedConfig = SharedConfig.SpeedConfig
local GamepassConfig = SharedConfig.GamepassConfig

--[[
	The click "pop", the same as the Lobby HUD buttons (`HUDButtonController`): shrinks
	while the button is pressed and returns with an overshoot on release, with
	`UIClick` playing on the return.
]]
local PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local PRESS_SCALE = 0.9

local CLICK_SOUND = "UIClick"

--[[
	The expansion. Each option takes a "slot" starting from the original, and a slot is
	the button's rendered width times EXPAND_SPACING, measured at the moment, not from
	the authored `Size`, because the button's UIAspectRatioConstraint rules the final
	size.
]]
local EXPAND_DIRECTION = 1     -- 1 opens to the right, -1 to the left
local EXPAND_SPACING = 1.2     -- button width + gap, per slot
local EXPAND_FROM_SCALE = 0.4  -- the size the clone starts at, on top of the original

local EXPAND_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local COLLAPSE_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local EXPAND_STAGGER = 0.04    -- delay per slot, so the options come out in a cascade

local OPTION_NAME = "SpeedOption"

--[[
	The lock for a step that needs a gamepass: a black veil over the option and the
	padlock in the middle of it. Both are created inside the button itself, so they
	follow position, size, and the opening animation with nothing extra.
]]
local LOCK_NAME = "Lock"
local LOCK_COLOR = Color3.new(0, 0, 0)
local LOCK_TRANSPARENCY = 0.5
local LOCK_ICON = "rbxassetid://133112084847088"
local LOCK_ICON_SCALE = 1

-- The step the option represents, to find the lock again after the purchase.
local STEP_ATTRIBUTE = "StepIndex"

--[[
	The match speed button (`Interface.Speed`).

	A click opens the options instead of changing speed: the button clones itself once
	per remaining `SpeedConfig` step, each clone with its step's art, and the clones
	slide out from behind the original on the X axis. Clicking one asks for that speed
	and closes; clicking the original (the current step's option) only closes.

	The button's art only changes when the server confirms. That is deliberate: speed
	belongs to the room, and swapping the image right away would show 1.5x to whoever
	clicked while the others are still at 1x; another player's click also changes this
	button's art, which only works if the single source is `GameSpeedChanged`.

	Besides the art, each confirmation adjusts the local `GameClock`. It is what makes
	the enemy model walk faster on screen (`MobController`) at the same pace as the
	distance the server is adding; without it, the server would deliver the enemy to
	the base with the model still halfway down the path.

	See docs/game/match-speed.md.
]]

local SpeedController = {
	Controllers = {
		MusicController = {},
		DataController = {},
	},
}

SpeedController.Index = SpeedConfig.DEFAULT_INDEX

-- The scale imposed from outside the button, when there is one. See `applyOverride`.
SpeedController.Override = nil

-- The options open now (the clones), from slot 1 on.
SpeedController.options = {}

-- One scale tween per UIScale. Weak keys because options are destroyed on close
-- and their UIScale goes with them.
SpeedController.scaleTweens = setmetatable({}, { __mode = "k" })

--[[
	The passes bought this session, by key.

	A bridge between `PromptGamePassPurchaseFinished` and the profile: the server
	recalibrates `Gamepasses` on the same purchase, but that goes around the network,
	and before it comes back the player has already clicked again, which would bring a
	second prompt for a pass they just bought. The profile still rules; this only
	covers the trip.
]]
SpeedController.purchased = {}

--[[ INTERNAL ]]

--[=[
	A button's scale, one tween at a time.

	The previous one is canceled instead of left running: pressing again before the
	return ends would leave two tweens writing the same property, and the button would
	stop at a size that is neither pressed nor normal. Per UIScale, not one for the
	whole controller, because there are several buttons at once: the original and the
	open options.
]=]
function SpeedController:tweenScale(uiScale : UIScale?, scale : number, info : TweenInfo)
	if not uiScale then return end

	local previous = self.scaleTweens[uiScale]
	if previous then
		previous:Cancel()
	end

	local tween = TweenService:Create(uiScale, info, { Scale = scale })
	self.scaleTweens[uiScale] = tween
	tween:Play()

	return tween
end

--- The button's UIScale, created the first time: `Interface.Speed` does not ship one.
function SpeedController:getScale(button : GuiButton) : UIScale
	local uiScale = button:FindFirstChildWhichIsA("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = button
	end

	return uiScale
end

--[=[
	Hooks up the click pop. The `UIScale` is created if the button does not ship one:
	today's `Interface.Speed` does not.

	`MouseButton1Down`/`Up`, not `Activated`: `MouseButton1Click` just below still
	changes the speed, and the animation must not consume its click.
]=]
function SpeedController:bindClickPop(button : GuiButton)
	local uiScale = self:getScale(button)

	button.MouseButton1Down:Connect(function()
		self:tweenScale(uiScale, PRESS_SCALE, PRESS_INFO)
	end)

	button.MouseButton1Up:Connect(function()
		self:tweenScale(uiScale, 1, RELEASE_INFO)

		local music = self.Controllers.MusicController
		if music then
			music:PlaySFX(CLICK_SOUND)
		end
	end)

	-- Releasing the click outside the button does not fire its `MouseButton1Up`, and the
	-- scale would stay stuck pressed.
	button.MouseLeave:Connect(function()
		self:tweenScale(uiScale, 1, RELEASE_INFO)
	end)
end

--[=[
	The scale the local clock should be at: the one imposed from outside the button
	(the Time Acceleration card) if there is one; otherwise the room's step.
]=]
function SpeedController:effectiveScale() : number
	return self.Override or SpeedConfig.GetScale(self.Index)
end

--- Applies the step the server sent: local clock and button art.
function SpeedController:apply(index : number)
	if not SpeedConfig.IsValid(index) then return end

	self.Index = index
	GameClock.SetScale(self:effectiveScale())

	if self.button then
		self.button.Image = SpeedConfig.GetImage(index)
	end

	-- The step changed (it may have been another player): the open options belong to
	-- the previous step, so they close instead of lying.
	self:collapse()
end

--[=[
	The scale imposed from outside the button. Only the clock changes: the art stays
	the step the room chose, because the card's 3x is not a step and has no image, and
	the button still serves to go back to 1x afterward.
]=]
function SpeedController:applyOverride(scale : number?)
	self.Override = if typeof(scale) == "number" then scale else nil

	GameClock.SetScale(self:effectiveScale())
end

--[[ GAMEPASS ]]

--- The replicated profile, or nil until it arrives.
function SpeedController:profile()
	local replica = self.replica

	return replica and replica.Data or nil
end

--[=[
	Holds the replica for the click's queries.

	Stored up front, not requested at the moment: `GetReplica` yields until the
	profile arrives, and yielding inside the click would delay opening the menu. With
	no replica yet, `isUnlocked` answers "locked", which is the safe side.
]=]
function SpeedController:watchProfile()
	task.spawn(function()
		local dataController = self.Controllers.DataController
		if not dataController then return end

		self.replica = dataController:GetReplica()
	end)
end

--[=[
	Whether the step is unlocked for this player.

	A step without `Gamepass` in the config belongs to everyone. With a pass, what the
	profile declares applies, and a profile that has not arrived counts as "does not
	have it", like the rest of the game (`GamepassConfig.ownedOf`): the lock shows, and
	the click becomes the prompt.
]=]
function SpeedController:isUnlocked(stepIndex : number?) : boolean
	local key = SpeedConfig.GetGamepass(stepIndex)
	if not key then return true end

	if self.purchased[key] then return true end

	return GamepassConfig.owns(self:profile(), key)
end

--[=[
	The veil and padlock over a locked option.

	The veil is a plain `Frame`, not a button: a `Frame` does not sink input, so the
	click passes through to the option's `MouseButton1Click` underneath, which decides
	between choosing the speed and opening the prompt.
]=]
function SpeedController:createLock(option : GuiButton)
	local veil = Instance.new("Frame")
	veil.Name = LOCK_NAME
	veil.AnchorPoint = Vector2.new(0.5, 0.5)
	veil.Position = UDim2.fromScale(0.5, 0.5)
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = LOCK_COLOR
	veil.BackgroundTransparency = LOCK_TRANSPARENCY
	veil.BorderSizePixel = 0
	veil.ZIndex = option.ZIndex + 1

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(LOCK_ICON_SCALE, LOCK_ICON_SCALE)
	icon.BackgroundTransparency = 1
	icon.Image = LOCK_ICON
	icon.ZIndex = veil.ZIndex + 1
	icon.Parent = veil

	veil.Parent = option

	return veil
end

--[=[
	A click on an option. Locked, it opens the pass prompt and the menu stays open: a
	buyer sees the lock drop and chooses on the next click, without opening everything
	again. Unlocked, it chooses the speed and closes.
]=]
function SpeedController:choose(stepIndex : number)
	if self:isUnlocked(stepIndex) then
		self:select(stepIndex)
		return
	end

	local key = SpeedConfig.GetGamepass(stepIndex)
	local pass = key and GamepassConfig.PASSES[key]

	if not pass then return end

	MarketplaceService:PromptGamePassPurchase(Player, pass.Id)
end

--[=[
	Just bought: that step's lock drops immediately, without waiting for the profile to
	go around through the server (`MonetizationService` recalibrates, on the same event
	over there).
]=]
function SpeedController:bindPurchaseFinished()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player : Player, gamePassId : number, purchased : boolean)
		if player ~= Player or not purchased then return end

		local key = GamepassConfig.keyOfId(gamePassId)
		if not key then return end

		self.purchased[key] = true

		for _, option in self.options do
			if SpeedConfig.GetGamepass(option:GetAttribute(STEP_ATTRIBUTE)) ~= key then continue end

			local lock = option:FindFirstChild(LOCK_NAME)
			if lock then
				lock:Destroy()
			end
		end
	end)
end

--[[ EXPANSION ]]

--[=[
	A slot's offset, in X-axis scale.

	Measured by the button's `AbsoluteSize` and not the authored `Size`: the
	UIAspectRatioConstraint may have given the button a different width from the one
	written there, and the options must follow the real width. Before the first
	render `AbsoluteSize` is zero, and then the authored value is the best estimate
	there is.
]=]
function SpeedController:slotOffset() : number
	local button = self.button
	local parent = button and button.Parent

	if not button or not parent then return 0 end

	local width = button.AbsoluteSize.X
	local available = (parent :: any).AbsoluteSize.X

	local ratio = if width > 0 and available > 0
		then width / available
		else button.Size.X.Scale

	return ratio * EXPAND_SPACING * EXPAND_DIRECTION
end

--[=[
	An option: a clone of the button itself with the step's art, starting on top of
	the original and moving to its slot.

	Cloning the button (instead of building one from scratch) is what keeps the options
	identical to the original for free: size, aspect, ZIndex, whatever the art gains
	later. The only thing to undo on the clone is the animation state that came along:
	the UIScale may have been copied mid-"pop" of the click that just opened the menu.
]=]
function SpeedController:createOption(stepIndex : number, slot : number)
	local button = self.button
	local parent = button and button.Parent
	if not button or not parent then return nil end

	local option = button:Clone()
	option.Name = OPTION_NAME
	option.Image = SpeedConfig.GetImage(stepIndex)
	option.Visible = true
	option.Position = button.Position
	option:SetAttribute(STEP_ATTRIBUTE, stepIndex)

	local uiScale = self:getScale(option)
	uiScale.Scale = EXPAND_FROM_SCALE

	option.Parent = parent

	if not self:isUnlocked(stepIndex) then
		self:createLock(option)
	end

	self:bindClickPop(option)

	option.MouseButton1Click:Connect(function()
		self:choose(stepIndex)
	end)

	-- The delay lives in the TweenInfo itself: a cascade with no thread hanging around
	-- that would have to be canceled if the menu closed mid-opening.
	local delay = EXPAND_STAGGER * (slot - 1)
	local moveInfo = TweenInfo.new(
		EXPAND_INFO.Time,
		EXPAND_INFO.EasingStyle,
		EXPAND_INFO.EasingDirection,
		0,
		false,
		delay
	)

	local target = button.Position + UDim2.fromScale(self:slotOffset() * slot, 0)

	TweenService:Create(option, moveInfo, { Position = target }):Play()
	self:tweenScale(uiScale, 1, moveInfo)

	return option
end

--[=[
	Opens the options: one clone per step that is not the current one, in
	`SpeedConfig` order. The original stays where it is and remains the option for the
	step in use.
]=]
function SpeedController:expand()
	if self.expanded or not self.button then return end

	self.expanded = true

	local slot = 0
	for stepIndex, _ in SpeedConfig.Steps do
		if stepIndex == self.Index then continue end

		slot += 1

		local option = self:createOption(stepIndex, slot)
		if option then
			table.insert(self.options, option)
		end
	end
end

--- Closes the options: they go back behind the original and disappear.
function SpeedController:collapse()
	if not self.expanded then return end

	self.expanded = false

	local origin = self.button and self.button.Position or UDim2.new()

	for _, option in self.options do
		-- Out of the way immediately: the click that closed must not land again on an
		-- option that is still shrinking.
		option.Interactable = false

		local tween = TweenService:Create(option, COLLAPSE_INFO, { Position = origin })
		tween.Completed:Connect(function()
			option:Destroy()
		end)
		tween:Play()

		self:tweenScale(self:getScale(option), EXPAND_FROM_SCALE, COLLAPSE_INFO)
	end

	table.clear(self.options)
end

--- The chosen option: closes the menu and asks for the speed, if it changed.
function SpeedController:select(stepIndex : number)
	self:collapse()

	if stepIndex == self.Index then return end

	Framework:Fire("SetGameSpeed", stepIndex)
end

--[=[
	Closes the menu when the player clicks in the world (placing a unit, turning the
	camera) instead of leaving the options open behind the game.

	`processed` true means the click landed on some GUI; then the menu stays, because
	one of those clicks may be exactly one of the options, which resolves itself in its
	own `MouseButton1Click`.
]=]
function SpeedController:bindOutsideClick()
	UserInputService.InputBegan:Connect(function(input : InputObject, processed : boolean)
		if not self.expanded or processed then return end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		self:collapse()
	end)
end

--[[ API ]]

--[=[
	The `Interface.Speed` button, once it has been found on screen.
]=]
function SpeedController:GetButton() : GuiButton?
	return self.button
end

--- The options open now. An empty list with the menu closed.
function SpeedController:GetOptions() : { GuiButton }
	return self.options
end

--[=[
	A step's option, or `nil` when the menu is closed (or when the requested step is
	the one already in use: that one gets no clone, the button itself is it).

	Callers are those that need to point at or unlock **one** of the options from
	outside: today, the tutorial step that asks to speed up the match, which highlights
	the step it wants and leaves only it clickable. Without this, the only way would be
	to look for the clone by name on screen, a name that is an internal detail of this
	controller.
]=]
function SpeedController:GetOption(stepIndex : number?) : GuiButton?
	if not stepIndex then return nil end

	for _, option in self.options do
		if option:GetAttribute(STEP_ATTRIBUTE) == stepIndex then
			return option
		end
	end

	return nil
end

--- Is the options menu open?
function SpeedController:IsExpanded() : boolean
	return self.expanded == true
end

--[[ LIFECYCLE ]]

function SpeedController:construct()
	Framework:Listen("GameSpeedChanged", function(index : number)
		self:apply(index)
	end)

	Framework:Listen("GameSpeedOverride", function(scale : number?)
		self:applyOverride(scale)
	end)

	local Interface = PlayerGui:WaitForChild("Interface", 60)
	if not Interface then return end

	self.button = Interface:WaitForChild("Speed", 60)
	if not self.button then return end

	-- The authored art is 1x's, but the button may be created in the middle of an
	-- already sped-up match: it draws what this client knows and asks for the rest.
	self.button.Image = SpeedConfig.GetImage(self.Index)

	self:bindClickPop(self.button)

	-- Closed, the click opens the options; open, the original is the current step's
	-- option, and clicking it only closes.
	self.button.MouseButton1Click:Connect(function()
		if self.expanded then
			self:select(self.Index)
		else
			self:expand()
		end
	end)

	self:bindOutsideClick()
	self:bindPurchaseFinished()

	Framework:Fire("RequestGameSpeed")
end

function SpeedController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	-- After the Get: construct runs in init, when the controllers have not been
	-- resolved yet.
	self:watchProfile()
end

function SpeedController:init()
	self:construct()
end

return SpeedController
