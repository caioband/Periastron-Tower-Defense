local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("HUDButtonController")

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"

local WAIT_TIMEOUT = 10

--[=[
	The two HUD columns and where hover pushes each one's button. With AnchorPoint 0.5
	inside the wrapper (and `X.Scale = 0.5` at rest), 0.3 is a fifth of the width to the
	side; Y and the offsets stay as they are.

	Both columns have the same structure, and only the direction changes: the right one
	slides left (0.3) and the left one mirrors it (0.7): the button always moves
	**inward** on the screen, not past the edge.
]=]
local HUD_FRAMES = {
	{ Name = "HUDFrame", HoverX = 0.3 },
	{ Name = "HUDLeft", HoverX = 0.7 },
}

local SLIDE_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local PRESS_SCALE = 0.9

local HOVER_SOUND = "UIHover"
local CLICK_SOUND = "UIClick"

--[=[
	The feedback for the buttons in the `StarterGui.HUD` columns (`HUDFrame` on the right
	and `HUDLeft` on the left): the button slides out of the column when the mouse enters,
	returns when it leaves, and shrinks while pressed.

	Only the visual part and the sound live here. Each panel's controller still opens the
	shop, the backpack, and the deck, through the same button's `Activated`, which is why
	the click animation is `MouseButton1Down`/`Up`, which consumes nobody's click.

	It picks up any `GuiButton` inside each column, at any depth: each button today is
	inside a `Wrapper`, and a new button joins the animation just by being born there. The
	HUD has `ResetOnSpawn` on, so the bind runs again for every new copy the engine puts
	in PlayerGui.

	See docs/lobby/hud.md.
]=]
local HUDButtonController = {
	Controllers = {
		MusicController = {},
	},
}

--[[ INTERNAL ]]

function HUDButtonController:_playSound(name : string)
	local music = self.Controllers.MusicController

	if music then
		music:PlaySFX(name)
	end
end

--[=[
	Plays a tween and leaves cancellation to the button's own maid: hover and click touch
	different things (position and scale), but both die together when the HUD is
	replaced.
]=]
function HUDButtonController:_tween(maid, object : Instance, info : TweenInfo, goal : { [string]: any })
	local tween = TweenService:Create(object, info, goal)

	maid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
end

function HUDButtonController:_bindButton(button : GuiButton, hoverX : number)
	if self.Bound[button] then
		return
	end

	local scale = button:FindFirstChildWhichIsA("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = button
	end

	-- The authored position is read once, before any tween: it is where
	-- MouseLeave returns to.
	local home = button.Position
	local hovered = UDim2.new(hoverX, home.X.Offset, home.Y.Scale, home.Y.Offset)

	local maid = Maid.new()
	self.Bound[button] = maid
	self.HudMaid:GiveTask(maid)

	local slideMaid = Maid.new()
	local scaleMaid = Maid.new()

	maid:GiveTask(slideMaid)
	maid:GiveTask(scaleMaid)

	maid:GiveTask(button.MouseEnter:Connect(function()
		slideMaid:DoCleaning()
		self:_tween(slideMaid, button, SLIDE_INFO, { Position = hovered })

		self:_playSound(HOVER_SOUND)
	end))

	maid:GiveTask(button.MouseLeave:Connect(function()
		slideMaid:DoCleaning()
		self:_tween(slideMaid, button, SLIDE_INFO, { Position = home })

		-- Releasing the click outside the button does not fire its `MouseButton1Up`, and the
		-- scale would stay stuck pressed.
		scaleMaid:DoCleaning()
		self:_tween(scaleMaid, scale, RELEASE_INFO, { Scale = 1 })
	end))

	maid:GiveTask(button.MouseButton1Down:Connect(function()
		scaleMaid:DoCleaning()
		self:_tween(scaleMaid, scale, PRESS_INFO, { Scale = PRESS_SCALE })
	end))

	maid:GiveTask(button.MouseButton1Up:Connect(function()
		scaleMaid:DoCleaning()
		self:_tween(scaleMaid, scale, RELEASE_INFO, { Scale = 1 })

		self:_playSound(CLICK_SOUND)
	end))

	maid:GiveTask(function()
		self.Bound[button] = nil
	end)
end

--[=[
	Hooks up a column. `DescendantAdded` stays connected because the GUI arrives in
	pieces: sweeping once would only catch the buttons already replicated.
]=]
function HUDButtonController:_bindFrame(hudFrame : Instance, hoverX : number)
	self.HudMaid:GiveTask(hudFrame.DescendantAdded:Connect(function(descendant : Instance)
		if descendant:IsA("GuiButton") then
			self:_bindButton(descendant, hoverX)
		end
	end))

	for _, descendant in hudFrame:GetDescendants() do
		if descendant:IsA("GuiButton") then
			self:_bindButton(descendant, hoverX)
		end
	end
end

--[=[
	Binds to a copy of the HUD: both columns, each with its direction. A column that does
	not exist in that copy is just left out; the others keep animating.
]=]
function HUDButtonController:_bindHud(screenGui : ScreenGui)
	self.HudMaid:DoCleaning()
	self.Bound = {}

	for _, column in HUD_FRAMES do
		local hudFrame = screenGui:WaitForChild(column.Name, WAIT_TIMEOUT)

		if hudFrame then
			self:_bindFrame(hudFrame, column.HoverX)
		elseif not self.Warned[column.Name] then
			self.Warned[column.Name] = true
			log:StudioWarn(`could not find {HUD_UI_NAME}.{column.Name}.`)
		end
	end
end

function HUDButtonController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

function HUDButtonController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()
end

function HUDButtonController:init()
	self.Maid = Maid.new()
	self.HudMaid = Maid.new()
	self.Bound = {}

	-- The missing-column warning is per name, not per HUD copy: the HUD is born again
	-- on every respawn, and the output would fill up.
	self.Warned = {}

	self.Maid:GiveTask(self.HudMaid)
end

return HUDButtonController
