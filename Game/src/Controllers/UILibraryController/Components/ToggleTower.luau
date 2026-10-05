local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local Interface = PlayerGui:WaitForChild("Interface", 500)
local CardUpgrade = Interface:WaitForChild("CardUpgrade")

--[=[
	The card does not slide in from off screen: it grows in place.

	A position animation would fight the drag mechanic just below: if the card were
	born off screen and returned to a fixed point, the spot the player chose with their
	finger would be undone every time they switched units. Scaling from its own point,
	the card appears wherever it is.

	The `UIScale` comes from StarterGui; if it ever goes missing there, a new one is
	created here so the module does not break.

	See docs/game/upgrade-card.md.
]=]
local CardScale = CardUpgrade:FindFirstChildOfClass("UIScale")
if not CardScale then
	CardScale = Instance.new("UIScale")
	CardScale.Parent = CardUpgrade
end

-- The "open" size is the one the designer left in Studio, read before any
-- animation touches the value.
local SHOWN_SCALE : number = CardScale.Scale > 0 and CardScale.Scale or 1
CardScale.Scale = 0

--[[
	Elastic on both sides, but in opposite directions: opening, the overshoot happens at
	the end (the card goes a little past its size and settles); closing, at the start (it
	stretches once and vanishes). Closing is shorter because nobody wants to wait for the
	animation of the card they just used.

	Elastic never takes the scale below zero: the excess is always toward the side the
	animation is leaving.
]]
local SHOW_TWEEN = TweenInfo.new(0.55, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Elastic, Enum.EasingDirection.In)

local scaleTween : Tween? = nil

--[=[
	Takes the card's scale to `target`. The optional `from` restarts the animation from
	zero: that is what gives the "pop" every time a unit is selected, even if the card was
	already on screen because of the previous unit.

	The previous animation is canceled, and `Cancel` makes `Completed` arrive as
	`Cancelled`: that is why the `onComplete` of a close interrupted midway does not hide
	the card a new selection just opened.
]=]
local function playScale(from : number?, target : number, tweenInfo : TweenInfo, onComplete : (() -> ())?)
	if scaleTween then
		scaleTween:Cancel()
		scaleTween = nil
	end

	if from then
		CardScale.Scale = from
	end

	local tween = TweenService:Create(CardScale, tweenInfo, { Scale = target })
	scaleTween = tween

	tween.Completed:Connect(function(state)
		if scaleTween == tween then
			scaleTween = nil
		end

		if state == Enum.PlaybackState.Completed and onComplete then
			onComplete()
		end
	end)

	tween:Play()
end

--[[
	Dragging the card.

	The player grabs the card anywhere (background, text, or the buttons themselves) and
	drops it wherever they want, with mouse or finger. The chosen spot is stored here in
	`cachedPosition` and holds for the rest of the session: every unit they select
	afterward opens the card in the same place.

	The cache stores the position in scale, not pixels: that way the card stays in the
	same corner of the screen if the window resizes or the device rotates.
]]
local cachedPosition : UDim2 = CardUpgrade.Position

-- How far the pointer must move for it to become a drag. Below that it is a
-- click: no finger stays perfectly still, and the SELL button must not fail
-- because the touch slid two pixels.
local DRAG_THRESHOLD = 6

-- After dropping the card, the click that ended the drag still reaches the buttons.
-- This short window swallows that click: dragging the card by SELL must not
-- sell the unit.
local CLICK_BLOCK_TIME = 0.15

local dragInput : InputObject? = nil
local dragStart : Vector2? = nil
local dragOrigin : Vector2? = nil
local dragMoved = false
local clickBlockedUntil = 0

local function isClickSuppressed() : boolean
	return dragMoved or os.clock() < clickBlockedUntil
end

--[=[
	The rectangle the card can move in: the ScreenGui itself.
]=]
local function getParentRect() : (Vector2?, Vector2?)
	local parent = CardUpgrade.Parent
	if not parent or not parent:IsA("GuiBase2d") then
		return nil, nil
	end

	local gui = parent :: GuiBase2d
	return gui.AbsolutePosition, gui.AbsoluteSize
end

--[=[
	Moves the card following the pointer, without letting it leave the screen.

	The math is all in pixels (`AbsolutePosition` is already the card's top corner,
	because `AnchorPoint` is 0,0) and only at the end becomes scale, the format the cache
	stores.
]=]
local function moveCardTo(pointer : Vector2)
	if not dragStart or not dragOrigin then return end

	local parentPosition, parentSize = getParentRect()
	if not parentPosition or not parentSize then return end
	if parentSize.X <= 0 or parentSize.Y <= 0 then return end

	local cardSize = CardUpgrade.AbsoluteSize
	local maxX = math.max(parentSize.X - cardSize.X, 0)
	local maxY = math.max(parentSize.Y - cardSize.Y, 0)

	local delta = pointer - dragStart
	local x = math.clamp(dragOrigin.X + delta.X, 0, maxX)
	local y = math.clamp(dragOrigin.Y + delta.Y, 0, maxY)

	CardUpgrade.Position = UDim2.fromScale(x / parentSize.X, y / parentSize.Y)
end

local function beginDrag(input : InputObject)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end

	local parentPosition = getParentRect()
	if not parentPosition then return end

	dragInput = input
	dragStart = Vector2.new(input.Position.X, input.Position.Y)
	dragOrigin = CardUpgrade.AbsolutePosition - parentPosition
	dragMoved = false
end

local function endDrag()
	if not dragInput then return end

	dragInput = nil
	dragStart = nil
	dragOrigin = nil

	if dragMoved then
		cachedPosition = CardUpgrade.Position
		clickBlockedUntil = os.clock() + CLICK_BLOCK_TIME
	end

	dragMoved = false
end

--[=[
	Hooks the drag start onto a piece of the card.

	The buttons are included: they swallow input before it reaches the card, and without
	this much of the card's area would not be grabbable. `DRAG_THRESHOLD` separates click
	from drag.
]=]
local function attachDragSource(instance : Instance)
	if not instance:IsA("GuiObject") then return end
	instance.InputBegan:Connect(beginDrag)
end

-- An `ImageLabel` only receives input with `Active` on. As a bonus, it makes the
-- card swallow the click: pressing it no longer leaks to the world behind, which is
-- what deselected the unit mid-drag.
CardUpgrade.Active = true
attachDragSource(CardUpgrade)

for _, descendant in CardUpgrade:GetDescendants() do
	if descendant:IsA("GuiButton") then
		attachDragSource(descendant)
	end
end

CardUpgrade.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("GuiButton") then
		attachDragSource(descendant)
	end
end)

--[[
	Drag movement and end are listened to on `UserInputService`, not the card: the finger
	(or mouse) leaves the card all the time while dragging, and the card's own events
	would stop arriving exactly then.

	On touch, the input object is the same from start to end: comparing by identity is
	what keeps a second finger on the screen from hijacking the drag. With a mouse,
	movement arrives as `MouseMovement`, a different object from the button holding the
	card.
]]
UserInputService.InputChanged:Connect(function(input)
	if not dragInput or not dragStart then return end

	local isDragMove = input == dragInput
		or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement)

	if not isDragMove then return end

	local pointer = Vector2.new(input.Position.X, input.Position.Y)
	if not dragMoved and (pointer - dragStart).Magnitude < DRAG_THRESHOLD then return end

	dragMoved = true
	moveCardTo(pointer)
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragInput then return end

	-- On touch, only the finger itself ends the drag: another finger leaving the screen
	-- must not drop the card midway. With a mouse, a matching type is enough, because the
	-- button that releases is always the one that pressed.
	local endsDrag = input == dragInput
		or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1)

	if endsDrag then
		endDrag()
	end
end)

-- Alt-tab mid-drag: the button's `InputEnded` never arrives, and without this the
-- card would stay stuck to the pointer when the player came back.
UserInputService.WindowFocusReleased:Connect(endDrag)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local ClassConfig = SharedConfig.ClassConfig
local CardConfig = SharedConfig.CardConfig
local UIUtil = require(Utils.UIUtil)
local PointerUtil = require(Utils.PointerUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

local module = {}
module.currentUnit = nil

-- Are the upgrade and sell buttons locked (tutorial match)? Written by
-- `refreshTutorialLock` and read by both buttons' text and by the next-level
-- preview.
module.tutorialLocked = false

--[[
	The card's keyboard shortcuts, and what is written on each one's button.

	The bracketed suffix format is what the card already had drawn in StarterGui
	("First [V]"): the useful text first, the key at the end. All three letters are free:
	the only shortcut the game already had nearby is `R`, which rotates the ghost during
	placement.
]]
local KEYBINDS = {
	Upgrade = Enum.KeyCode.E,
	Priority = Enum.KeyCode.V,
	Sell = Enum.KeyCode.X,
}

--[=[
	`text` with the shortcut key at the end: "SELL $250" becomes "SELL $250 [X]".

	Off PC it returns the raw text. Mobile and console have no key to press, and the
	card's labels are all `TextScaled` on a short button: four shortcut characters nobody
	can use would come out of the size of exactly the number worth reading.

	The keyboard listener below does not depend on this check: someone who happens to
	have a keyboard attached to a touch device can still use the shortcut, they just do
	not see the hint on screen.
]=]
local function withBind(text : string, keyCode : Enum.KeyCode) : string
	if not PointerUtil.isPC() then
		return text
	end

	return string.format("%s [%s]", text, keyCode.Name)
end

--[=[
	A number with at most `decimals` places and no trailing zeros: 12.00 -> "12",
	0.75 -> "0.75". It only touches the decimal part, so 100 stays "100".
]=]
local function formatNumber(value : number, decimals : number?) : string
	local text = string.format("%." .. (decimals or 0) .. "f", value)

	if text:find("%.") then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end

	return text
end

--[=[
	Card stats are small numbers (damage, range); above a thousand it is better to
	abbreviate than to show the decimal place.
]=]
local function formatStat(value : number) : string
	if value >= 1000 then
		return UIUtil.formatAbbreviated(math.floor(value + 0.5))
	end

	return formatNumber(value, 1)
end

--[=[
	Each stat label on the card has a smaller sibling just below it, left in StarterGui,
	which shows the value the unit will have after the next upgrade. The order here is
	{existing label, its preview}.
]=]
local PREVIEW_LABELS = {
	{ stat = "DamagePerSecond", preview = "DamagePerSecondUpgrade" },
	{ stat = "AttackSpeed", preview = "CooldownUpgrade" },
	{ stat = "Range", preview = "RangeUpgrade" },
}

local function getPreviewLabel(entry) : TextLabel?
	local stat = CardUpgrade:FindFirstChild(entry.stat)
	return stat and stat:FindFirstChild(entry.preview)
end

local function hidePreviewLabels()
	for _, entry in PREVIEW_LABELS do
		local label = getPreviewLabel(entry)
		if label then
			label.Visible = false
		end
	end
end

--[=[
	Is today's match the tutorial?

	In the tutorial a placed tower is not upgraded **nor sold**: the script teaches
	placing, buying, using a card, and speeding up, and the match money is counted for
	the deck: spending on an upgrade along the way reaches the wrap-up step with nothing
	to buy the other towers with, and selling wave 1's Slingshot undoes the step the
	script just counted as done.

	`TutorialMatchService`, on the server, does the real refusing (`CanUpgrade` and
	`CanSell`); only what the player sees comes from here: locked buttons and silent keys.

	Without the controller in hand the answer is no: a regular match is the usual case,
	and locking the upgrade of someone not in the tutorial would be the costlier mistake
	of the two.
]=]
local function inTutorial() : boolean
	local tutorial = Framework:Get("TutorialStepController", false, false)

	return tutorial ~= nil and tutorial:IsTutorial() == true
end

--[[
	Weather enters the card's combat numbers.

	It is the same reason as the range circle on the ground: during fog the unit looks for
	targets in a smaller radius, and a card still showing the dry range would be lying
	about the unit the player is looking at. `UnitPlacementController` redraws the card
	on a weather change.
]]
local function getWeather()
	local weatherController = Framework:Get("WeatherController", false, false)
	return weatherController and weatherController:GetCurrent() or nil
end

--- Whoever is under no card. See `getCards`.
local NO_CARDS = { Damage = 1, AttackSpeed = 1, Range = 1, Income = 1 }

--[=[
	What round cards are doing to **this** unit.

	The same reason as weather just above, and the same reason as the range circle on
	the ground: a staff ring drawn over the tower changes its damage, attack speed, and
	range, and a card still showing the table numbers would be lying about the unit the
	player is looking at. `CardModifierController` redraws the card when a card is used.

	The math is the **same** as the server's (the shared `CardModifier`), not a second one
	that could diverge. The `unitId` comes from the unit's class, and it is what makes a
	single-target card (Bloxiade on one tower) show on that tower's card and no other.

	Without the controller in hand, or with the unit outside the Workspace, everything is
	1: the card shows the table number, which is what it always showed.
]=]
local function getCards(unitModel : Model?)
	local controller = Framework:Get("CardModifierController", false, false)
	if not controller or not unitModel or not unitModel.Parent then
		return NO_CARDS
	end

	local placement = Framework:Get("UnitPlacementController", false, false)
	local classes = placement and placement.createdClasses
	local class = classes and classes[unitModel]

	local unitId = class and class.unitId or nil
	local position = unitModel:GetPivot().Position
	local unitName = unitModel.Name

	return {
		Damage = controller:Multiplier("Damage", unitName, position, unitId),
		AttackSpeed = controller:Multiplier("AttackSpeed", unitName, position, unitId),
		Range = controller:Multiplier("Range", unitName, position, unitId),
		Income = controller:Multiplier("Income", unitName, position, unitId),
	}
end

--[=[
	Damage per hit, or income when the unit is a Farm, which does not attack. The same
	math for the current level and for the next-level preview.

	The text says "PER WAVE" and not "INCOME" because the frequency is the part the player
	needs to know to decide whether the farm pays for itself: income drops at the end of
	each wave, not at the end of the round.
]=]
local function formatDamageOrIncome(unitName : string, level : number, weather, cards) : string
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local unitStats = SharedConfig.UnitStats[unitName]
	local farm = unitStats and unitStats.Farm
	cards = cards or NO_CARDS

	if farm then
		-- `GetIncome` returns the raw number; the card comes in here and there is a single
		-- rounding, the same as `payFarmUnits`. See the getter's comment.
		local income = math.floor(upgradeConfig:GetIncome(unitName, level) * cards.Income + 0.5)

		return "$" .. UIUtil.formatAbbreviated(income) .. " PER WAVE"
	end

	-- A slow aura deals no damage: the line shows how much slower its ring makes enemies.
	if unitStats and unitStats.SlowAura then
		return formatNumber(upgradeConfig:GetAuraSlow(unitName, level) * 100, 2) .. "% SLOW"
	end

	--[[
		Built from base damage instead of multiplying `GetDamage`, so the rounding is the
		**same** as the server's: it rounds once, at the end (`UnitService:getDamage`), and
		rounding twice would leave the card one point above or below what hits the enemy.
	]]
	local damage = math.floor((unitStats and unitStats.Damage or 0)
		* upgradeConfig:GetDamageMultiplier(unitName, level, weather)
		* cards.Damage + 0.5)

	return formatStat(damage) .. " DMG"
end

--[=[
	Cooldown between attacks, or the aura bonus when the unit is a Farm.

	The same idea as the label above: a farm does not attack, so its cooldown is a
	meaningless number, and the line is reused for what actually matters on that unit.
	The next-level preview comes from the same function, with `level + 1`.

	"PER UNIT" is in the text because the bonus is not a value the farm pays: it is a
	percentage on top of what EACH unit inside the radius already earns from damage and
	kills. A farm in an empty corner yields no bonus, and without that written the player
	would read "15%" as something coming from the farm itself.

	A farm without an aura (a new farm that only pays income) still falls back to
	cooldown: there is no bonus to show.
]=]
local function formatCooldownOrBonus(unitName : string, level : number, weather, cards) : string
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local bonus = upgradeConfig:GetAuraBonus(unitName, level)
	cards = cards or NO_CARDS

	if bonus > 0 then
		return formatNumber(bonus * 100, 1) .. "% PER UNIT BONUS"
	end

	-- A slow aura has no cycle: its cooldown is inert, so the line says what it does.
	local unitStats = SharedConfig.UnitStats[unitName]
	if unitStats and unitStats.SlowAura then
		return "SLOWS IN RANGE"
	end

	-- Attack speed goes in as a division, like weather: 1.15 is "hits 15% faster",
	-- that is, the same cycle in 1/1.15 of the time.
	local cooldown = upgradeConfig:GetCooldown(unitName, level, weather)
	if cards.AttackSpeed > 0 then
		cooldown /= cards.AttackSpeed
	end

	return formatNumber(cooldown, 2) .. " COOLDOWN"
end

--[=[
	Roblox's mobile jump button, if it is on screen. `TouchGui` only exists on touch
	devices and is recreated on every respawn, which is why it is looked up at the
	moment and never cached.
]=]
local function findJumpButton() : GuiObject?
	local touchGui = PlayerGui:FindFirstChild("TouchGui")
	local controlFrame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local button = controlFrame and controlFrame:FindFirstChild("JumpButton")

	return button and button:IsA("GuiObject") and button or nil
end

function module:create(unitModel, ...)
	if self.maid then
		self.maid:Destroy()
		self.maid = nil
	end

	self.maid = Maid.new()
	self.currentUnit = unitModel

	--[[
		The card's three actions, each in its own function.

		The click and the keyboard shortcut call the same function, so there is no second
		copy of the rules to drift from the first: the upgrade's level cap applies to both
		through the same `if`.

		The drag lock (`isClickSuppressed`) stays out of them on purpose: it exists to
		swallow the click that ends a drag, and someone who pressed a key dragged no card.
	]]
	local function doSell()
		if not unitModel then return end

		-- The tutorial tower cannot be sold (see `inTutorial`), along the same path as
		-- the upgrade: button locked, key refused by `isButtonActive`, and this
		-- check as the final lock.
		if inTutorial() then return end

		local unitId = unitModel:GetAttribute("UnitID")
		Framework:Fire("SellUnit", unitId)
		self:destroy()
	end

	local function doUpgrade()
		if not unitModel then return end

		-- The tutorial does not sell upgrades (see `inTutorial`). The button is already
		-- locked and the key already refused by `isButtonActive`; this closes the path, so
		-- no new shortcut bypasses the rule by accident.
		if inTutorial() then return end

		local level = unitModel:GetAttribute("Upgrades") or 0
		if SharedConfig.UnitUpgradeConfig:IsMaxed(level) then return end

		local unitId = unitModel:GetAttribute("UnitID")
		Framework:Fire("UpgradeUnit", unitId)
	end

	local function doPriority()
		if not unitModel then return end

		local unitId = unitModel:GetAttribute("UnitID")
		if not unitId then return end

		Framework:Fire("SetUnitPriority", unitId, TargetPriority.Next(unitModel:GetAttribute("TargetPriority")))
	end

	local sellButton = CardUpgrade:FindFirstChild("Sell")
	if sellButton and self.sellConnection then
		self.sellConnection:Disconnect()
		self.sellConnection = nil
	end

	if sellButton and unitModel then
		-- `Activated` and not `MouseButton1Up`: on touch, if the finger slides off the
		-- button before releasing, MouseButton1Up does not arrive and the sale is lost.
		self.sellConnection = sellButton.Activated:Connect(function()
			-- Someone who just dragged the card by the button did not mean to sell anything.
			if isClickSuppressed() then return end

			doSell()
		end)
		self.maid:GiveTask(function()
			if self.sellConnection then
				self.sellConnection:Disconnect()
				self.sellConnection = nil
			end
		end)
	end

	local upgradeButton = CardUpgrade:FindFirstChild("UpgradeCost")
	if self.upgradeConnection then
		self.upgradeConnection:Disconnect()
		self.upgradeConnection = nil
	end

	if upgradeButton and unitModel then
		self.upgradeConnection = upgradeButton.Activated:Connect(function()
			if isClickSuppressed() then return end

			doUpgrade()
		end)
		self.maid:GiveTask(function()
			if self.upgradeConnection then
				self.upgradeConnection:Disconnect()
				self.upgradeConnection = nil
			end
		end)
	end

	--[[
		Next-level preview.

		On PC it only appears with the mouse over the upgrade cost: the player sees what
		the money buys before spending, and the card stays clean the rest of the time. On
		mobile there is no "hovering" (the finger is either pressing or off the screen), so
		there the numbers are always visible.
	]]
	self.previewHovered = false

	if upgradeButton and not PointerUtil.isTouchOnly() then
		self.maid:GiveTask(upgradeButton.MouseEnter:Connect(function()
			self.previewHovered = true
			self:refreshPreview()
		end))
		self.maid:GiveTask(upgradeButton.MouseLeave:Connect(function()
			self.previewHovered = false
			self:refreshPreview()
		end))
	end

	local priorityButton = CardUpgrade:FindFirstChild("Priority")
	if self.priorityConnection then
		self.priorityConnection:Disconnect()
		self.priorityConnection = nil
	end

	if priorityButton and unitModel then
		--[[
			A click moves one step in the `TargetPriority` cycle. What goes to the server is
			the target mode, not "the next one": the button reads the attribute's state,
			which is what the server last confirmed, so two clicks in a row do not trample
			each other.

			The button text does not change here: it changes when the confirmation comes
			back and touches the attribute. That way the card never shows a priority the
			server refused (another player's unit, for example).
		]]
		self.priorityConnection = priorityButton.Activated:Connect(function()
			if isClickSuppressed() then return end

			doPriority()
		end)
		self.maid:GiveTask(function()
			if self.priorityConnection then
				self.priorityConnection:Disconnect()
				self.priorityConnection = nil
			end
		end)
	end

	--[[
		The shortcuts. A single listener for all three, bound to the maid: they are born
		and die with the card, and a key must not outlive the card that announced it.

		What enables each key is the button's own `Visible`, not a copy of its rules:
		that is where "only the owner sells and upgrades" (`refreshOwnership`) and "Farms
		have no priority" (`refreshPriority`) already live. That way the key never does
		what the button next to it would not, including when the button is off screen.

		`gameProcessed` cuts what Roblox's interface already consumed: typing an "x" in chat
		must not sell the selected unit.
	]]
	local function isButtonActive(button : Instance?) : boolean
		--[[
			`Active` goes in along with `Visible` for the same reason `Visible` was here:
			the key must never do what the button next to it would not. A locked button (the
			upgrade in the tutorial; see `refreshOwnership`) refuses the click through
			`Active = false`, and without this line the shortcut would be its back door.
		]]
		return CardUpgrade.Visible
			and button ~= nil
			and button:IsA("GuiObject")
			and button.Visible
			and button.Active
	end

	self.maid:GiveTask(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

		if input.KeyCode == KEYBINDS.Upgrade then
			if isButtonActive(upgradeButton) then doUpgrade() end
		elseif input.KeyCode == KEYBINDS.Priority then
			if isButtonActive(priorityButton) then doPriority() end
		elseif input.KeyCode == KEYBINDS.Sell then
			if isButtonActive(sellButton) then doSell() end
		end
	end))

	if unitModel then
		-- An upgrade changes damage/range/cooldown and the next level's cost; total damage
		-- arrives in batches from the server a few times per second.
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("Upgrades"):Connect(function()
			self:refresh()
		end))
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("TargetPriority"):Connect(function()
			self:refreshPriority()
		end))
		self.maid:GiveTask(unitModel:GetAttributeChangedSignal("DamageDone"):Connect(function()
			self:refreshDamageDone()
		end))
	end

	self:refresh()

	--[[
		The card opens where the player left it last time, or where the layout put it if
		they never dragged anything.

		The position is only rewritten when nobody is holding the card: switching units
		mid-drag must not yank the card from the finger.
	]]
	if not dragInput then
		CardUpgrade.Position = cachedPosition
	end

	CardUpgrade.Visible = true
	playScale(0, SHOWN_SCALE, SHOW_TWEEN)

	self:setJumpButtonHidden(true)
end

--[=[
	Takes the jump button off screen while the card is open, and restores it afterward.

	On mobile the card opens right over the corner where Roblox draws the jump button:
	the two compete for the same finger, and a player about to press SELL jumps. Touch
	only: on PC the button does not even exist.

	It is not `controls:Disable()`: that would take the thumbstick too, and the player can
	still walk with the card open. Only the button goes.

	Hiding is watched because `TouchGui` is not ours: Roblox's TouchJump module rewrites
	`Visible` on its own (on respawn, on sitting, on being able to jump again) and a
	respawn replaces the button with a new one. While the card is open, any jump button
	that appears is hidden again, and what TouchJump wanted in the meantime is what gets
	restored at the end, so a button Roblox had hidden on purpose does not light up.
]=]
function module:setJumpButtonHidden(hidden : boolean)
	if self.jumpMaid then
		self.jumpMaid:Destroy()
		self.jumpMaid = nil
	end

	if not hidden or not PointerUtil.isTouchOnly() then return end

	local maid = Maid.new()
	self.jumpMaid = maid

	local active = true
	local wanted = true

	local function hide(button : GuiObject)
		wanted = button.Visible
		button.Visible = false

		maid:GiveTask(button:GetPropertyChangedSignal("Visible"):Connect(function()
			if not active or not button.Visible then return end
			wanted = true
			button.Visible = false
		end))
	end

	local button = findJumpButton()
	if button then
		hide(button)
	end

	maid:GiveTask(PlayerGui.DescendantAdded:Connect(function(descendant)
		if not active or descendant.Name ~= "JumpButton" then return end
		if descendant ~= findJumpButton() then return end

		hide(descendant)
	end))

	-- First turn off the watcher, then restore: that way the restoration does not land
	-- on the observer itself and hide the button again.
	maid:GiveTask(function()
		active = false

		local current = findJumpButton()
		if current then
			current.Visible = wanted
		end
	end)
end

--[=[
	The card's class icon: `Melee`, `Ranged`, `Magic`, `Fire`, `Ice`, or `Electric`, by
	the class the unit declares in `UnitStats`.

	A unit with no class (or a class with no art yet) hides the label instead of showing
	an empty square, and it comes back on its own on the next unit that has one.

	`FindFirstChild` because `ClassIcon` is recent in StarterGui: without it the whole card
	still works, just without the icon.
]=]
local function applyClassIcon(unitName : string?)
	local icon = CardUpgrade:FindFirstChild("ClassIcon")
	if not icon or not icon:IsA("ImageLabel") then return end

	local image = ClassConfig.GetIcon(unitName)

	icon.Image = image or ""
	icon.Visible = image ~= nil
end

--[[
	The art `Info` came authored with, read once and before any swap.

	It is the default a unit without its own portrait returns to. Without storing it, the
	card would open with the **previous** unit's face, which is a worse mistake than a
	generic frame, because it looks right.
]]
local INFO_DEFAULT_ICON : string? = (function()
	local info = CardUpgrade:FindFirstChild("Info")

	return info and info:IsA("ImageLabel") and info.Image or nil
end)()

--[=[
	The unit's portrait on the card: `Info`, the frame holding the name and level.

	Unlike `ClassIcon`, it **does not hide** when the unit has no art of its own: the name
	and level live inside it, and hiding the frame would take both along. It returns to
	the authored art, the generic frame.

	`FindFirstChild` for the same reason as `applyClassIcon`: without `Info` in StarterGui
	the whole card still works, just without the portrait.
]=]
local function applyUnitIcon(unitName : string?)
	local info = CardUpgrade:FindFirstChild("Info")
	if not info or not info:IsA("ImageLabel") then return end

	info.Image = CardConfig.GetIcon(unitName) or INFO_DEFAULT_ICON or ""
end

--[=[
	Does the selected unit belong to this player?

	It comes from the `Owned` attribute, which `UnitPlacementController` writes on the
	model when replicating the unit. Reading from the model is the same path as level and
	priority: the card does not need to ask any controller who the owner is.

	Without the attribute the answer is no, on purpose: a card that opens without knowing
	whose unit it is should show what anyone can do, not the owner's buttons.
]=]
local function isOwnedByMe(unitModel : Instance?) : boolean
	return unitModel ~= nil and unitModel:GetAttribute("Owned") == true
end

--[=[
	The buttons only the unit's owner can press.

	Selling, upgrading, and changing priority are refused on the server when they come
	from a non-owner (`UnitService`), so hiding them is not what protects the match: what
	they did was promise an action that would never happen. The card of someone else's
	unit still opens in full: name, level, stats, and damage dealt are exactly what is
	worth looking at on another player's unit.

	`Priority` is not included because it already has its own rule on top of this one
	(Farms target nobody); `refreshPriority` handles it.
]=]
function module:refreshOwnership()
	local owned = isOwnedByMe(self.currentUnit)

	for _, name in { "Sell", "UpgradeCost" } do
		local button = CardUpgrade:FindFirstChild(name)
		if button and button:IsA("GuiObject") then
			button.Visible = owned
		end
	end

	self:refreshTutorialLock()
end

--[=[
	Locks what the tutorial match does not allow with the tower on the ground:
	**upgrading and selling**.

	Both buttons stay on screen, not off it: the player needs to **see** that upgrading
	and selling exist (the card is where they will look for both in their first real
	match), they just cannot do them here (see `inTutorial`).

	`Active = false` is what the rest of the game uses to refuse clicks (see
	`ResultController` and the difficulty lock), and it comes along, but what closes the
	door here is `Interactable`: the card's buttons have `InputSink` on `Activate`, and
	changing `Active` does **not** change `InputSink`. `AutoButtonColor` and `Selectable`
	are so the button looks locked instead of broken.

	The keys drop along through `isButtonActive`, which reads the button's own `Active`,
	and `doUpgrade`/`doSell` still check on their own: three doors for the same rule,
	because none of them belongs to our UI alone.

	`Priority` stays out: changing the tower's target costs nothing, undoes no step, and
	is exactly the kind of thing one learns by playing around.

	Outside the tutorial this returns the buttons to normal every time, not only when
	something changes: the card is a single one for the whole game, and an `Active`
	forgotten at `false` would outlive the tutorial match.
]=]
function module:refreshTutorialLock()
	local locked = inTutorial()

	self.tutorialLocked = locked

	for _, name in { "UpgradeCost", "Sell" } do
		local button = CardUpgrade:FindFirstChild(name)
		if not button or not button:IsA("GuiObject") then
			continue
		end

		button.Active = not locked
		button.Selectable = not locked

		if button:IsA("GuiButton") then
			button.AutoButtonColor = not locked
			button.Interactable = not locked
		end
	end
end

--[=[
	Fills the whole card with the selected unit's data. Each label keeps the suffix the
	designer left in StarterGui; only the number is swapped.
]=]
function module:refresh()
	local unitModel = self.currentUnit

	self:refreshOwnership()

	local upgradeLabel = CardUpgrade.UpgradeCost:FindFirstChild("TextLabel")
	local sellLabel = CardUpgrade.Sell:FindFirstChild("TextLabel")

	if not unitModel or not unitModel.Parent then
		if upgradeLabel then upgradeLabel.Text = "" end
		if sellLabel then sellLabel.Text = "SELL" end
		applyClassIcon(nil)
		applyUnitIcon(nil)
		return
	end

	local unitName = unitModel.Name
	local level = unitModel:GetAttribute("Upgrades") or 0
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local weather = getWeather()

	CardUpgrade.Info.UnitName.Text = unitName
	CardUpgrade.Info.UnitLevel.Text = "LVL." .. level
	applyClassIcon(unitName)
	applyUnitIcon(unitName)

	-- At max level the shortcut is not shown: the key does nothing there, and announcing
	-- one that does not respond is worse than announcing none.
	if upgradeLabel then
		if upgradeConfig:IsMaxed(level) then
			upgradeLabel.Text = "MAX"
		else
			local cost = "$" .. UIUtil.formatAbbreviated(upgradeConfig:GetCost(unitName, level))

			-- A locked button does not announce a shortcut, for the same reason as max level:
			-- the key does nothing there, and inviting to one that does not respond is worse
			-- than inviting to none.
			upgradeLabel.Text = if self.tutorialLocked then cost else withBind(cost, KEYBINDS.Upgrade)
		end
	end

	-- The same math as the server's `SellUnit`: part of what was invested comes back.
	if sellLabel then
		local invested = upgradeConfig:GetInvested(unitName, level)
		local refund = math.floor(invested * SharedConfig.SellRefundRatio)
		local text = "SELL $" .. UIUtil.formatAbbreviated(refund)

		-- A locked button does not announce a shortcut, like the upgrade just above.
		sellLabel.Text = if self.tutorialLocked then text else withBind(text, KEYBINDS.Sell)
	end

	--[[
		The `DamagePerSecond` label shows damage per hit, not DPS: the number that matters
		when buying an upgrade is what hits the enemy per strike; the cooldown is right
		below on the card itself, for anyone who wants the per-second math.

		Farms do not attack: in place of damage, income per wave.
	]]
	local cards = getCards(self.currentUnit)

	CardUpgrade.DamagePerSecond.Text = formatDamageOrIncome(unitName, level, weather, cards)

	CardUpgrade.AttackSpeed.Text = formatCooldownOrBonus(unitName, level, weather, cards)
	CardUpgrade.Range.Text = formatStat(upgradeConfig:GetRange(unitName, level, weather) * cards.Range) .. " RANGE"

	self:refreshPreview()
	self:refreshPriority()
	self:refreshDamageDone()
end

--[=[
	Writes into the previews what the unit becomes after the next upgrade: the same
	getters as the card, just with `level + 1`, so the preview's damage, cooldown, and
	range come from the same math the server uses in combat (weather included).

	At max level the previews hide, even on mobile: there is no next value to show, and
	the cost next to it already says "MAX".
]=]
function module:refreshPreview()
	local unitModel = self.currentUnit
	local upgradeConfig = SharedConfig.UnitUpgradeConfig
	local level = unitModel and unitModel:GetAttribute("Upgrades") or 0

	local shouldShow = self.previewHovered or PointerUtil.isTouchOnly()
	if not unitModel or not unitModel.Parent or upgradeConfig:IsMaxed(level) then
		shouldShow = false
	end

	--[[
		Someone else's unit shows no preview at all. On PC this already happened on its own
		(with no upgrade button on screen there is nothing to hover), but on mobile the
		preview appears without hover, and there would be next-level numbers next to an
		upgrade that is no longer on the card.
	]]
	if not isOwnedByMe(unitModel) then
		shouldShow = false
	end

	-- A locked upgrade has no next level to promise: in the tutorial the preview
	-- would be an ad for a button that does not respond.
	if self.tutorialLocked then
		shouldShow = false
	end

	if not shouldShow then
		hidePreviewLabels()
		return
	end

	local unitName = unitModel.Name
	local weather = getWeather()
	local nextLevel = level + 1

	local cards = getCards(unitModel)

	local texts = {
		DamagePerSecondUpgrade = formatDamageOrIncome(unitName, nextLevel, weather, cards),
		CooldownUpgrade = formatCooldownOrBonus(unitName, nextLevel, weather, cards),
		RangeUpgrade = formatStat(upgradeConfig:GetRange(unitName, nextLevel, weather) * cards.Range) .. " RANGE",
	}

	for _, entry in PREVIEW_LABELS do
		local label = getPreviewLabel(entry)
		if label then
			label.Text = texts[entry.preview]
			label.Visible = true
		end
	end
end

--[=[
	Writes on the button the target priority the unit is using. It comes from the model's
	attribute, which is what the server sent: the button never guesses.
]=]
function module:refreshPriority()
	local button = CardUpgrade:FindFirstChild("Priority")
	local label = button and button:FindFirstChild("TextLabel")
	if not label then return end

	local unitModel = self.currentUnit
	if not unitModel or not unitModel.Parent then return end

	--[[
		Two reasons for the button to leave the screen, and both hold at once: Farms and
		slow auras target nobody, and the server refuses priority changes on someone
		else's unit (see `refreshOwnership`).
	]]
	local unitStats = SharedConfig.UnitStats[unitModel.Name]
	button.Visible = isOwnedByMe(unitModel) and not (unitStats and (unitStats.Farm or unitStats.SlowAura))

	label.Text = withBind(TargetPriority.Label(unitModel:GetAttribute("TargetPriority")), KEYBINDS.Priority)
end

function module:refreshDamageDone()
	local unitModel = self.currentUnit
	if not unitModel or not unitModel.Parent then return end

	local total = math.floor((unitModel:GetAttribute("DamageDone") or 0) + 0.5)
	CardUpgrade.DmgDone.Text = UIUtil.formatAbbreviated(total) .. " DMG DONE"
end

function module:destroy()
	self.currentUnit = nil
	self.previewHovered = false
	hidePreviewLabels()
	if self.maid then
		self.maid:Destroy()
	end

	self.maid = nil

	-- The card only leaves the screen when the shrink animation ends. If a new unit
	-- is selected in the meantime, `create`'s `playScale` cancels this tween and
	-- this `Visible = false` never happens.
	playScale(nil, 0, HIDE_TWEEN, function()
		CardUpgrade.Visible = false
		self:setJumpButtonHidden(false)
	end)
end

return module
