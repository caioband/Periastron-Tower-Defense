--[=[
	The player's pointer, without assuming a mouse exists.

	`UserInputService:GetMouseLocation()` and `Enum.UserInputType.MouseButton1` do
	nothing useful on a phone: there is no mouse to follow, and a touch arrives as
	`Enum.UserInputType.Touch`, so a click never happened.

	Here both devices sit behind the same API:
	  - `getScreenPosition()` returns the mouse on PC and the last touch on a phone;
	  - `onPointerAction()` calls back on a click (PC) or a short tap (phone),
	    always with the screen position.

	Client module: `UserInputService` does not exist on the server, so every access
	goes through a `RunService:IsClient()` guard. See docs/common/controls.md.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UserInputService = RunService:IsClient() and game:GetService("UserInputService") or nil
local GuiService = RunService:IsClient() and game:GetService("GuiService") or nil

local PointerUtil = {}

--[[
	`InputObject.Position` and `Camera:ViewportPointToRay` do not measure height
	from the same place.

	An input position is in GUI space, which starts below the Roblox top bar. The
	camera ray starts at the real top of the window (3D is drawn behind the bar
	too). Between them is the GuiInset, about 36 px vertically, which is why a tap
	landed near but not on the finger. `GetMouseLocation()` is already in ray space,
	which is why the mouse was always exact.

	Instead of adding 36 by hand (it changes with the bar hidden, full screen, and
	between devices), the difference is measured: a zero-size frame in a ScreenGui
	with `IgnoreGuiInset` sits, by definition, at the top corner of the whole
	window. Wherever Roblox says it is, that is the origin of ray space, and
	subtracting it from an input position gives the right coordinate regardless of
	the engine's current convention.
]]
local viewportOrigin : Frame? = nil

local function getViewportOriginOffset() : Vector2
	if not UserInputService then return Vector2.zero end

	if not viewportOrigin or not viewportOrigin.Parent then
		local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then return Vector2.zero end

		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "PointerViewportOrigin"
		screenGui.IgnoreGuiInset = true
		screenGui.ResetOnSpawn = false
		screenGui.DisplayOrder = -1000

		local marker = Instance.new("Frame")
		marker.Name = "Origin"
		marker.Size = UDim2.fromOffset(0, 0)
		marker.Position = UDim2.fromOffset(0, 0)
		marker.BackgroundTransparency = 1
		marker.BorderSizePixel = 0
		-- It intercepts nothing: it is a ruler, not an interface element.
		marker.Active = false
		marker.Parent = screenGui

		screenGui.Parent = playerGui
		viewportOrigin = marker
	end

	return viewportOrigin.AbsolutePosition
end

--[=[
	Converts an `InputObject` position to the coordinate the camera ray expects.
	Without it, a tap aims above where the finger touched.
]=]
local function toViewportPoint(position : Vector2) : Vector2
	return position - getViewportOriginOffset()
end

--[=[
	An `InputObject` position in the space the camera ray expects.

	Public because not everyone consumes touches through `onPointerAction`: mobile
	placement listens to raw touches through `ContextActionService` (it needs the
	drag, not just the tap) and needs the same conversion.

	Careful mixing the two spaces: `Camera:WorldToViewportPoint` answers in **this**
	space, and `PlayerGui:GetGuiObjectsAtPosition` answers in the **other** one, GUI
	space, which is `InputObject.Position` before this conversion.
]=]
function PointerUtil.toViewportPoint(position : Vector2) : Vector2
	return toViewportPoint(position)
end

--[[
	A touch only becomes an "action" if the finger barely moved and lifted quickly.
	Dragging is how a phone player turns the camera, and a drag must not become a
	world click, or the unit would jump every time they looked around.
]]
local TAP_MAX_MOVEMENT = 20
local TAP_MAX_DURATION = 0.6

local lastTouchPosition : Vector2? = nil

local function trackTouch(input : InputObject)
	if input.UserInputType ~= Enum.UserInputType.Touch then return end
	lastTouchPosition = toViewportPoint(Vector2.new(input.Position.X, input.Position.Y))
end

if UserInputService then
	-- The ruler is built here, at client boot, not on the first touch: a new frame
	-- only gets an AbsolutePosition after the interface is drawn, and on that frame
	-- the measurement would come out zero.
	getViewportOriginOffset()

	-- No `gameProcessedEvent` filter: this is only "where the finger is", and whoever
	-- consumes the position decides whether the touch counted.
	UserInputService.InputBegan:Connect(trackTouch)
	UserInputService.InputChanged:Connect(trackTouch)
end

--[=[
	True on a touch-only device.

	A touchscreen PC still counts as a PC: its mouse works and is what the player
	holds, so there is no reason to swap the interface under them.
]=]
function PointerUtil.isTouchOnly() : boolean
	if not UserInputService then return false end
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

--[=[
	True only on a PC: a real keyboard and mouse, not a console.

	This decides whether a keyboard shortcut is worth showing, which is why it tests
	the positive side. `not isTouchOnly()` does not work: a console has neither
	touch nor mouse, so it answers "not touch only", and a gamepad player would read
	an "[E]" they cannot press.

	A tablet with a Bluetooth keyboard is left out too: the key would work, but that
	device's interface is the touch one.
]=]
function PointerUtil.isPC() : boolean
	if not UserInputService then return false end
	if GuiService and GuiService:IsTenFootInterface() then return false end

	return UserInputService.KeyboardEnabled and UserInputService.MouseEnabled
end

--[=[
	Where the pointer is on screen, in the coordinate `Camera:ViewportPointToRay`
	expects.

	On a phone it returns `nil` until the player has touched the screen once: before
	the first touch there is no "where the finger is", and the caller must decide
	what to do instead of aiming at (0,0), a valid raycast in the wrong place.
]=]
function PointerUtil.getScreenPosition() : Vector2?
	if not UserInputService then return nil end

	if UserInputService.MouseEnabled then
		return UserInputService:GetMouseLocation()
	end

	return lastTouchPosition
end

--[=[
	Calls `callback(screenPosition)` when the player points at the world.

	On PC it is the left button going down, and the position comes from
	`GetMouseLocation()`, not `input.Position`, to keep the coordinate the rest of
	the code already used.

	On a phone it is a short, still tap, measured by TAP_MAX_MOVEMENT and
	TAP_MAX_DURATION. Dragging calls nothing, so the player can still turn the
	camera with a unit in hand.

	Input the interface already consumed is ignored in both cases, so pressing a HUD
	button does not also trigger what is in the world behind it.

	Returns the function that disconnects everything, ready for a Maid.
]=]
function PointerUtil.onPointerAction(callback : (Vector2) -> ()) : () -> ()
	if not UserInputService then
		return function() end
	end

	local connections = {}
	local touchStartPosition : Vector2? = nil
	local touchStartClock = 0

	table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			callback(UserInputService:GetMouseLocation())
		elseif input.UserInputType == Enum.UserInputType.Touch then
			touchStartPosition = toViewportPoint(Vector2.new(input.Position.X, input.Position.Y))
			touchStartClock = os.clock()
		end
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input, processed)
		if input.UserInputType ~= Enum.UserInputType.Touch then return end

		-- Cleared before any exit: a touch that did not become an action must not leave
		-- its start position behind for the next one.
		local startPosition = touchStartPosition
		touchStartPosition = nil

		if processed or not startPosition then return end
		if os.clock() - touchStartClock > TAP_MAX_DURATION then return end

		local endPosition = toViewportPoint(Vector2.new(input.Position.X, input.Position.Y))
		if (endPosition - startPosition).Magnitude > TAP_MAX_MOVEMENT then return end

		callback(endPosition)
	end))

	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
end

return PointerUtil
