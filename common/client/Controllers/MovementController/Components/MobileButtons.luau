local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Run = require(script.Parent.Run)
local Dash = require(script.Parent.Dash)

local Player = Players.LocalPlayer

--[=[
	The mobile run and dash buttons, drawn in the same language as Roblox's jump
	button: a translucent dark circle with a white border, in the right corner,
	within reach of the same thumb.

	**Everything comes from the jump button.** The size is a fraction of its size,
	and the position is measured from its center, so when Roblox changes the jump
	button from 70 to 120 pixels on a larger screen, both grow and move apart with
	it. It also decides whether the buttons appear: with no jump button on screen
	there is no touch control (PC, gamepad), or someone removed it on purpose (Game's
	upgrade card hides it), and in both cases run and dash go too.

	**Collide with nothing.** The spot is not fixed: there is a list of slots around
	the jump button (left, above, diagonal, and a second row of each), and each button
	takes the first free one. Free is measured on the real screen, with
	`GetGuiObjectsAtPosition` over a grid of points in the slot: it works for any UI in
	both places, including ones that do not exist yet, with no list of names to
	maintain. A panel opening over a slot pushes the button to the next one; with no
	free slot the button hides until space opens up.

	`GetGuiObjectsAtPosition` returns even hidden objects and empty frames that only
	organize layout, so each result goes through `isShown` and `hasContent`: only
	what is actually on screen and draws something counts. The three ScreenGuis with
	different insets do not throw off the math: all their `AbsolutePosition`s already
	come out in the same space (the inset goes into the ScreenGui's own), and that is
	the space `GetGuiObjectsAtPosition` answers in.

	---

	**The cluster is not only for movement.** Run and dash are two tenants among
	others: any controller registers a button here with `:register(name, config)` and
	removes it with `:unregister(name)`. Besides `MovementController`,
	`UnitPlacementController` does this today: `ROTATE` and `LOCK` appear next to the
	other two while a unit is in hand on mobile.

	The reason they live here, and not in a GUI of their own, is the slot solver:
	four circles around the same thumb must share the six slots without overlapping
	or falling under the HUD, and that is a single computation. Two independent GUIs
	would each solve on their own and collide on screen.

	Since `Me` registers **every** ModuleScript under `Controllers`, this is reached
	through `Framework:Get("MobileButtons")` from anywhere in both places.

	See docs/common/controls.md.
]=]
local module = {}

--[[ CONSTANTS ]]
local GUI_NAME = "MovementButtons"

-- Fractions of the jump button's size.
local BUTTON_SCALE = 0.78
local GAP_SCALE = 0.12
local MIN_GAP = 6

-- Extra margin around the slot when measuring collision, in pixels.
local COLLISION_MARGIN = 4

-- Points per side of the grid that measures each slot (GRID x GRID).
local GRID = 4

-- How often the position is rechecked. With no slot, the search is spaced out more.
local CHECK_INTERVAL = 0.25
local HIDDEN_CHECK_INTERVAL = 0.5

local FONT = Font.new("rbxassetid://12187371840", Enum.FontWeight.Bold, Enum.FontStyle.Normal)

local IDLE_COLOR = Color3.fromRGB(255, 255, 255)
local ACTIVE_COLOR = Color3.fromRGB(255, 200, 60)

--[[ STATE ]]
local gui : ScreenGui? = nil
local buttons = {}

-- The movement ones (Run.Changed), released by `stop`.
local connections = {}

-- The cluster ones (the layout loop), released when the last button leaves.
local loopConnections = {}

-- Declared here because `register` calls them before they are defined.
local ensureLoop, stopLoop

--[[ HELPERS ]]

local function getPlayerGui() : PlayerGui?
	return Player:FindFirstChildOfClass("PlayerGui")
end

local function findJumpButton() : GuiObject?
	local playerGui = getPlayerGui()
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	local controlFrame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local button = controlFrame and controlFrame:FindFirstChild("JumpButton")

	return button and button:IsA("GuiObject") and button or nil
end

-- Whether the object is actually on screen: it and all its parents visible, inside
-- an enabled ScreenGui.
local function isShown(object : Instance) : boolean
	local node = object
	while node do
		if node:IsA("GuiObject") then
			if not node.Visible then return false end
			if node:IsA("CanvasGroup") and node.GroupTransparency >= 0.95 then return false end
		elseif node:IsA("LayerCollector") then
			return node.Enabled and node:IsA("ScreenGui")
		else
			return false
		end
		node = node.Parent
	end

	return false
end

-- Whether the object draws something: an empty layout frame takes no space.
local function hasContent(object : GuiObject) : boolean
	if object.BackgroundTransparency < 0.95 then return true end

	if object:IsA("ImageLabel") or object:IsA("ImageButton") then
		if object.Image ~= "" and object.ImageTransparency < 0.95 then return true end
	elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
		if object.Text ~= "" and object.TextTransparency < 0.95 then return true end
	elseif object:IsA("ViewportFrame") or object:IsA("VideoFrame") then
		return true
	end

	return false
end

local function makeCircle(parent : Instance, name : string, zIndex : number) : Frame
	local circle = Instance.new("Frame")
	circle.Name = name
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromScale(1, 1)
	circle.BorderSizePixel = 0
	circle.ZIndex = zIndex
	circle.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = circle

	return circle
end

local function createButton(name : string, text : string) : TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Visible = false
	button.Selectable = false

	local scale = Instance.new("UIScale")
	scale.Parent = button

	local circle = makeCircle(button, "Circle", 1)
	circle.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	circle.BackgroundTransparency = 0.55

	local stroke = Instance.new("UIStroke")
	stroke.Color = IDLE_COLOR
	stroke.Transparency = 0.35
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = circle

	-- The dash recharge: a dark veil that goes down as the cooldown ends.
	local cooldown = makeCircle(button, "Cooldown", 2)
	cooldown.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	cooldown.BackgroundTransparency = 0
	cooldown.Visible = false

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Parent = cooldown

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.72, 0.34)
	label.FontFace = FONT
	label.Text = text
	label.TextColor3 = IDLE_COLOR
	label.TextScaled = true
	label.ZIndex = 3
	label.Parent = button

	-- The press responds on touch, not on release: that is what the jump button does,
	-- and a dash that only fires when the finger lifts arrives late.
	button.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if input.UserInputState ~= Enum.UserInputState.Begin then return end

		scale.Scale = 0.9
		local action = buttons[name] and buttons[name].action
		if action then
			action()
		end
	end)

	button.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		scale.Scale = 1
	end)

	return button
end

local function ensureGui() : ScreenGui?
	if gui and gui.Parent then return gui end

	local playerGui = getPlayerGui()
	if not playerGui then return nil end

	gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.Enabled = false

	gui.Parent = playerGui

	return gui
end

--[=[
	The "this button is on" highlight: the same color and weight the lit `RUN` always
	had, now available to any registration.

	`RUN` (running) and `LOCK` (ghost locked) use it today. They are the cluster's two
	state buttons; `DASH` and `ROTATE` fire and return.
]=]
function module:setActive(name : string, active : boolean)
	local entry = buttons[name]
	if not entry then return end

	local button = entry.instance
	local color = active and ACTIVE_COLOR or IDLE_COLOR

	button.Circle.BackgroundTransparency = active and 0.3 or 0.55
	button.Circle.UIStroke.Color = color
	button.Circle.UIStroke.Transparency = active and 0 or 0.35
	button.Label.TextColor3 = color
end

local lastCooldown = -1
local function updateDashCooldown()
	local entry = buttons.Dash
	if not entry or not entry.instance.Parent then return end

	local alpha = Dash:getCooldownAlpha()
	if math.abs(alpha - lastCooldown) < 0.01 and not (alpha == 0 and lastCooldown ~= 0) then return end
	lastCooldown = alpha

	local veil = entry.instance.Cooldown
	if alpha <= 0 then
		veil.Visible = false
		return
	end

	-- The veil covers, from the top down, the fraction still left.
	local cut = math.clamp(alpha, 0.002, 0.998)
	veil.UIGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(cut, 0.45),
		NumberSequenceKeypoint.new(math.min(1, cut + 0.001), 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	veil.Visible = true
end

--[[ LAYOUT ]]

-- The buttons are circles: two of them touch by the distance between centers, not
-- by their boxes; the diagonal slot would never fit if they were squares.
local function circlesTouch(a : Vector2, aSize : number, b : Vector2, bSize : number, gap : number) : boolean
	return (a - b).Magnitude < (aSize + bSize) / 2 + gap
end

local function makeRect(center : Vector2, size : number, margin : number)
	local half = size / 2 + margin
	return { min = center - Vector2.new(half, half), max = center + Vector2.new(half, half), center = center }
end

--[=[
	Whether nothing on screen draws inside the slot. `memo` keeps each object's
	verdict during a search: the same frame shows up at several grid points.
]=]
local function isAreaFree(rect, memo) : boolean
	local playerGui = getPlayerGui()
	if not playerGui or not gui then return false end

	-- Off screen is not a slot.
	local screenMin = gui.AbsolutePosition
	local screenMax = screenMin + gui.AbsoluteSize
	if rect.min.X < screenMin.X or rect.min.Y < screenMin.Y or rect.max.X > screenMax.X or rect.max.Y > screenMax.Y then
		return false
	end

	local touchGui = playerGui:FindFirstChild("TouchGui")
	local size = rect.max - rect.min

	for ix = 0, GRID - 1 do
		for iy = 0, GRID - 1 do
			local point = rect.min + Vector2.new(size.X * (ix + 0.5) / GRID, size.Y * (iy + 0.5) / GRID)

			for _, object in playerGui:GetGuiObjectsAtPosition(point.X, point.Y) do
				local verdict = memo[object]
				if verdict == nil then
					verdict = not object:IsDescendantOf(gui)
						and not (touchGui and object:IsDescendantOf(touchGui))
						and object.AbsoluteSize.X > 0 and object.AbsoluteSize.Y > 0
						and isShown(object)
						and hasContent(object)
					memo[object] = verdict
				end

				if verdict then return false end
			end
		end
	end

	return true
end

--[[
	The slots around the jump button, in each button's order of preference.

	Each registration brings its own; this is the order for those that do not. The
	lists of today's four buttons start at different slots on purpose, so the common
	case resolves without the solver having to break any tie.
]]
local DEFAULT_SLOT_ORDER = { "Left", "Up", "Diagonal", "FarLeft", "FarUp", "LeftUp" }

local function buildSlots(jumpCenter : Vector2, jumpSize : number, size : number, gap : number)
	local reach = jumpSize / 2 + gap + size / 2
	local step = size + gap
	local diagonal = reach * math.sqrt(0.5)

	return {
		Left = jumpCenter + Vector2.new(-reach, 0),
		Up = jumpCenter + Vector2.new(0, -reach),
		Diagonal = jumpCenter + Vector2.new(-diagonal, -diagonal),
		FarLeft = jumpCenter + Vector2.new(-reach - step, 0),
		FarUp = jumpCenter + Vector2.new(0, -reach - step),
		LeftUp = jumpCenter + Vector2.new(-reach, -step),
	}
end

local layout = {
	key = nil,
	placed = {}, -- [name] = center on screen
	size = 0,
	gap = 0,
}

local function hideAll()
	for _, entry in buttons do
		entry.instance.Visible = false
	end
	table.clear(layout.placed)
end

local function applyPlacement(name : string, center : Vector2?)
	local entry = buttons[name]
	if not entry or not gui then return end

	local button = entry.instance
	if not center then
		button.Visible = false
		layout.placed[name] = nil
		return
	end

	local local_ = center - gui.AbsolutePosition
	button.Size = UDim2.fromOffset(layout.size, layout.size)
	button.Position = UDim2.fromOffset(math.round(local_.X), math.round(local_.Y))
	button.Circle.UIStroke.Thickness = math.max(2, math.round(layout.size * 0.04))
	button.Visible = true

	layout.placed[name] = center
end

--[=[
	Distributes the registered buttons over the free slots.

	Depth-first search, not greedy. The difference shows exactly in the tight case:
	the first slot in dash's list may be the only one that works for `RUN`, and a
	greedy loop would take it and leave the other button off screen. The search gives
	up that slot and tries the next when that yields **more** buttons on screen.

	Each level also has the branch of **not** placing that button, which allows a
	partial solution when the HUD leaves no room for all. Since the best is only
	replaced by a strictly larger one, the first solution found with that count wins,
	and it is the one that respects the priority order and each button's slot list.

	The space is tiny (six slots, a handful of buttons) and `free` is memoized, so the
	whole computation costs less than the screen measurement that feeds it.
]=]
local function solve(jumpCenter : Vector2, jumpSize : number, slots, order : { string })
	local memo = {}
	local freeCache = {}

	local function free(slotName : string) : boolean
		local cached = freeCache[slotName]
		if cached ~= nil then return cached end

		local center = slots[slotName]
		local result = not circlesTouch(center, layout.size, jumpCenter, jumpSize, layout.gap / 2)
			and isAreaFree(makeRect(center, layout.size, COLLISION_MARGIN), memo)
		freeCache[slotName] = result
		return result
	end

	local taken = {}        -- [slot] = name
	local chosen = {}       -- [name] = slot
	local best, bestCount = nil, -1

	local function conflicts(slotName : string) : boolean
		for otherSlot in taken do
			if circlesTouch(slots[slotName], layout.size, slots[otherSlot], layout.size, layout.gap / 2) then
				return true
			end
		end
		return false
	end

	local function search(index : number, placed : number)
		-- All fit: there is nothing better to look for.
		if bestCount == #order then return end

		if index > #order then
			if placed > bestCount then
				best, bestCount = table.clone(chosen), placed
			end
			return
		end

		local name = order[index]
		local entry = buttons[name]
		local preference = (entry and entry.slots) or DEFAULT_SLOT_ORDER

		for _, slotName in preference do
			if slots[slotName] and not taken[slotName] and free(slotName) and not conflicts(slotName) then
				taken[slotName] = name
				chosen[name] = slotName

				search(index + 1, placed + 1)

				taken[slotName] = nil
				chosen[name] = nil

				if bestCount == #order then return end
			end
		end

		-- This one stays out; maybe the ones below fit.
		search(index + 1, placed)
	end

	search(1, 0)

	return best or {}
end

--- The registered names, most important first. Ties fall back to the name, so the
--- order does not depend on iterating a keyed table.
local function registeredOrder() : { string }
	local order = {}
	for name in buttons do
		table.insert(order, name)
	end

	table.sort(order, function(a, b)
		local pa, pb = buttons[a].priority, buttons[b].priority
		if pa ~= pb then return pa < pb end
		return a < b
	end)

	return order
end

local function refreshLayout(force : boolean?)
	if not gui then return end

	local order = registeredOrder()

	local jump = findJumpButton()
	if #order == 0 or not jump or not isShown(jump) then
		gui.Enabled = false
		hideAll()
		layout.key = nil
		return
	end

	gui.Enabled = true

	local jumpSize = math.min(jump.AbsoluteSize.X, jump.AbsoluteSize.Y)
	local jumpCenter = jump.AbsolutePosition + jump.AbsoluteSize / 2
	local key = `{math.round(jumpCenter.X)}:{math.round(jumpCenter.Y)}:{jumpSize}:{gui.AbsoluteSize.X}:{gui.AbsoluteSize.Y}:{#order}`

	layout.size = math.round(jumpSize * BUTTON_SCALE)
	layout.gap = math.max(MIN_GAP, math.round(jumpSize * GAP_SCALE))

	--[[
		Nothing changed size and everyone is on screen: if the current slots are still
		free, everything stays put, without a button jumping around for nothing.

		The count goes into the key because registering or removing a button changes
		the problem even with the same screen; without it, `ROTATE` coming in would not
		redistribute anything.
	]]
	local allPlaced = true
	for _, name in order do
		if not layout.placed[name] then
			allPlaced = false
			break
		end
	end

	if not force and key == layout.key and allPlaced then
		local memo = {}
		local stillFree = true
		for _, center in layout.placed do
			if not isAreaFree(makeRect(center, layout.size, COLLISION_MARGIN), memo) then
				stillFree = false
				break
			end
		end
		if stillFree then return end
	end

	layout.key = key

	local slots = buildSlots(jumpCenter, jumpSize, layout.size, layout.gap)
	local assignment = solve(jumpCenter, jumpSize, slots, order)

	for _, name in order do
		local slotName = assignment[name]
		applyPlacement(name, slotName and slots[slotName] or nil)
	end
end

--[[ REGISTRATION ]]

--[=[
	Puts a button in the cluster.

	`config`:
	  - `Text`        label, in uppercase (`DASH`, `LOCK`)
	  - `OnActivate`  called on **touch**, not on release
	  - `Priority`    lower picks a slot first
	  - `Slots`       slot preference order; without it, the default
	  - `OnHeartbeat` optional, per frame, for buttons that draw continuous state

	Registering the same name twice replaces the previous one, which makes `register`
	safe to repeat in a `begin` that runs on every respawn.
]=]
function module:register(name : string, config)
	if not UserInputService.TouchEnabled then return end
	if not ensureGui() then return end

	self:unregister(name)

	local instance = createButton(name, config.Text or name:upper())
	instance.Parent = gui

	buttons[name] = {
		instance = instance,
		action = config.OnActivate,
		priority = config.Priority or 100,
		slots = config.Slots,
		heartbeat = config.OnHeartbeat,
	}

	ensureLoop()
	refreshLayout(true)
end

function module:unregister(name : string)
	local entry = buttons[name]
	if not entry then return end

	buttons[name] = nil
	layout.placed[name] = nil
	entry.instance:Destroy()

	--[[
		Leaves the screen **and** gives back the slot. Without `force` the shortcut
		above would see the changed key and redistribute anyway, but for a side reason;
		here it is explicit because removing a button is exactly when the others may
		move up to a better slot.
	]]
	refreshLayout(true)

	if next(buttons) == nil then
		stopLoop()
		if gui then gui.Enabled = false end
	end
end

--[[ LIFECYCLE ]]

--[=[
	The cluster loop: it belongs to the cluster, not to whoever registered.

	While any button is registered it re-measures the screen every so often: that
	is what makes a button move away from a panel that opened over its slot. It
	starts on the first registration and stops on the last.
]=]
function ensureLoop()
	if loopConnections[1] then return end

	local elapsed = math.huge
	table.insert(loopConnections, RunService.Heartbeat:Connect(function(dt)
		for _, entry in buttons do
			if entry.heartbeat then
				entry.heartbeat()
			end
		end

		elapsed += dt

		local everyonePlaced = true
		for name in buttons do
			if not layout.placed[name] then
				everyonePlaced = false
				break
			end
		end

		if elapsed < (everyonePlaced and CHECK_INTERVAL or HIDDEN_CHECK_INTERVAL) then return end
		elapsed = 0

		refreshLayout()
	end))

	-- Rotating the screen or changing the jump button's size triggers the search right away.
	if gui then
		table.insert(loopConnections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			refreshLayout(true)
		end))
	end
end

function stopLoop()
	for _, connection in loopConnections do
		connection:Disconnect()
	end
	table.clear(loopConnections)
end

--[=[
	The two movement buttons come in here, not through the outside `register`,
	because they are the only ones that depend on the character: they are born and
	die with it.
]=]
function module:begin(character)
	-- A device without touch never has a jump button; there is nothing to build.
	if not UserInputService.TouchEnabled then return end

	self:stop()

	self:register("Dash", {
		Text = "DASH",
		Priority = 1,
		Slots = { "Left", "Up", "Diagonal", "FarLeft", "FarUp", "LeftUp" },
		OnActivate = function() Dash:tryDash() end,
		OnHeartbeat = updateDashCooldown,
	})

	self:register("Run", {
		Text = "RUN",
		Priority = 2,
		Slots = { "Up", "Diagonal", "Left", "FarUp", "LeftUp", "FarLeft" },
		OnActivate = function() Run:toggle() end,
	})

	self:setActive("Run", Run.isRunning)
	table.insert(connections, Run.Changed.Event:Connect(function(running)
		self:setActive("Run", running)
	end))
end

--[=[
	Removes movement from the cluster. What other controllers registered **stays**: a
	respawn mid-placement must not take `ROTATE` with it.
]=]
function module:stop()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	self:unregister("Dash")
	self:unregister("Run")

	lastCooldown = -1
end

return module
