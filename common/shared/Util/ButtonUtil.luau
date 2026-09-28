local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)

--[[
	A shop button's weight: it grows with the pointer over it and sinks while
	pressed, on the `UIScale` authored inside it.

	It lives here because **both** Lobby shops (crates and cards) have the same
	buy button, and it must feel the same. A second copy of the timings and curves
	would give two buttons that look alike and do not feel alike.

	Timings and curves match the HUD buttons (see `HUDButtonController`): a
	circular entrance, and a `Back` return that overshoots slightly, which makes
	the button feel weighted instead of just resizing.
]]
local ButtonUtil = {}

--[=[
	The press is softer than the HUD's `0.9` on purpose. There the button is a
	small square icon; in the shops it is a wide bar, and the same factor would
	move both edges much farther, so the bar would seem to jump instead of sink.
]=]
ButtonUtil.HOVER_SCALE = 1.05
ButtonUtil.PRESS_SCALE = 0.93

ButtonUtil.HOVER_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
ButtonUtil.PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
ButtonUtil.RELEASE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

--[=[
	Moves the `UIScale` to the size the button's state asks for, canceling the
	previous tween.

	The target comes from the whole state, not the latest event: pressed beats
	hovered, which beats idle. Otherwise, releasing the click with the mouse still
	over it would return to normal size instead of hover size, and the next mouse
	exit would have nothing to undo.

	`Tween:Cancel()` stops the tween without restoring the property; the scale
	stays where it got and the new tween starts from there, so animations chain
	instead of jumping.
]=]
local function applyScale(maid, scale : UIScale, state, style)
	maid:DoCleaning()

	local target, info

	if state.Pressed then
		target, info = style.PressScale, style.PressInfo
	elseif state.Hovered then
		target, info = style.HoverScale, style.HoverInfo
	else
		target, info = 1, style.ReleaseInfo
	end

	local tween = TweenService:Create(scale, info, { Scale = target })

	maid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
end

--[=[
	Wires a button's grow and sink. `maid` undoes everything (the container's or
	card's bind maid, so a new `_render` disconnects leftovers and cancels any
	tween in progress).

	Without an authored `UIScale` inside the button there is nothing to animate and
	the function does nothing: the button stays clickable.

	Press and release are `InputBegan`/`InputEnded`, not `MouseButton1Down/Up`,
	because the shop is played on phones too: filtering `MouseButton1` **and**
	`Touch`, the same pair covers clicks and taps. Neither consumes input, so the
	`Activated` that buys still fires.

	Two things the pair alone does not cover:

	* **Releasing outside the button.** Dragging out and releasing there does not
	  fire this `InputEnded`, and the scale would stay pressed forever, so
	  `MouseLeave` also undoes the press.
	* **Touch has no hover.** Roblox sends `MouseEnter` on touch as if it were a
	  mouse, so lifting the finger would return the button to hover size for a
	  frame before `MouseLeave` arrives. A finished touch clears both states.
]=]
function ButtonUtil.bindFeedback(button : GuiButton, maid, options : { [string] : any }?)
	local scale = button:FindFirstChildWhichIsA("UIScale")
	if not scale then
		return
	end

	options = options or {}

	local style = {
		HoverScale = options.HoverScale or ButtonUtil.HOVER_SCALE,
		PressScale = options.PressScale or ButtonUtil.PRESS_SCALE,
		HoverInfo = options.HoverInfo or ButtonUtil.HOVER_INFO,
		PressInfo = options.PressInfo or ButtonUtil.PRESS_INFO,
		ReleaseInfo = options.ReleaseInfo or ButtonUtil.RELEASE_INFO,
	}

	local state = { Hovered = false, Pressed = false }

	local tweenMaid = Maid.new()
	maid:GiveTask(tweenMaid)

	local function refresh()
		applyScale(tweenMaid, scale, state, style)
	end

	maid:GiveTask(button.MouseEnter:Connect(function()
		state.Hovered = true
		refresh()
	end))

	maid:GiveTask(button.MouseLeave:Connect(function()
		state.Hovered = false
		state.Pressed = false
		refresh()
	end))

	maid:GiveTask(button.InputBegan:Connect(function(input : InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		state.Pressed = true
		refresh()
	end))

	maid:GiveTask(button.InputEnded:Connect(function(input : InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		state.Pressed = false

		if input.UserInputType == Enum.UserInputType.Touch then
			state.Hovered = false
		end

		refresh()
	end))

	-- The authored scale is the idle one. A button left large because the panel closed
	-- with the mouse over it returns to normal on the next bind.
	scale.Scale = 1
end

return ButtonUtil
