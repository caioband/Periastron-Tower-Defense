local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

--[[ CONSTANTS ]]

-- A ScreenGui with this attribute is never hidden. It is for the GUI that only
-- exists while everything else is hidden: the portal's white flash, which is born
-- mid-cutscene and is what covers the teleport.
local IGNORE_ATTRIBUTE = "IgnoreInterfaceHide"

--[[
	Decides what stays on screen.

	Each UI owner keeps turning its own `ScreenGui` on and off as always; what goes
	through here is "hide everything else": the maps panel wants the screen to
	itself, the cutscene wants a clean screen. They are **named requests**
	(`Hide("Cutscene")`), not a global switch, because the two overlap: the panel
	may be open when the scene starts, and each one leaves in its own way.

	A GUI stays hidden while **any** request hides it, and returns to what its owner
	wanted when the last one leaves. "What the owner wanted" is read live: if someone
	turns on a hidden GUI during a request, the value is stored and it stays off, and
	when the request leaves it is that new value that returns, not the old one.

	What we write ourselves never enters that count: see `_write`, which is where the
	echo of our own write is separated from the GUI's owner.

		InterfaceController:Hide("ChooseMaps", { Except = { "ChooseMaps" } })
		InterfaceController:Show("ChooseMaps")

	`HideCore` also takes Roblox's own interface (chat, player list, backpack, and
	the top bar), which the cutscene needs and the panel does not.

	See docs/common/interface-visibility.md.
]]
local InterfaceController = {
	Controllers = {},
}

--[[ INTERNAL ]]

--[=[
	Writes to a GUI's `Enabled` while marking the notification that write will
	produce, so it does not come back as if the GUI's owner were changing it.

	It is a count, not a flag set and cleared around the write: a property's
	`Changed` arrives at the end of the frame (`SignalBehavior.Deferred`, the
	default), long after the flag would have been cleared. With a flag, the `false`
	we forced would be stored as the state the owner wanted, and there would be
	nothing to return to.

	A write that changes nothing produces no notification, so it does not count
	either.
]=]
function InterfaceController:_write(screenGui : LayerCollector, enabled : boolean)
	local entry = self.Tracked[screenGui]
	if not entry or screenGui.Enabled == enabled then
		return
	end

	entry.Pending += 1
	screenGui.Enabled = enabled
end

--[=[
	Whether any active request hides this GUI. A request hides everything not in its
	`Except`.
]=]
function InterfaceController:_shouldHide(screenGui : LayerCollector) : boolean
	if screenGui:GetAttribute(IGNORE_ATTRIBUTE) == true then
		return false
	end

	for _, request in self.Requests do
		if not (request.Except and request.Except[screenGui.Name]) then
			return true
		end
	end

	return false
end

function InterfaceController:_apply(screenGui : LayerCollector)
	local entry = self.Tracked[screenGui]
	if not entry then
		return
	end

	if self:_shouldHide(screenGui) then
		self:_write(screenGui, false)
	else
		self:_write(screenGui, entry.Desired)
	end
end

function InterfaceController:_applyAll()
	for screenGui, _ in self.Tracked do
		self:_apply(screenGui)
	end
end

--[=[
	Whether any active request also asks for Roblox's interface.
]=]
function InterfaceController:_wantsCoreHidden() : boolean
	for _, request in self.Requests do
		if request.HideCore then
			return true
		end
	end

	return false
end

--[=[
	Turns Roblox's own interface on and off. The previous state is stored per type
	the first time it leaves: the backpack, for example, already comes disabled by
	Satchel, and turning it back on would bring the stock backpack back over Satchel's.
]=]
function InterfaceController:_applyCore()
	local hide = self:_wantsCoreHidden()
	if hide == self.CoreHidden then
		return
	end

	self.CoreHidden = hide

	if hide then
		if not self.CoreStates then
			self.CoreStates = {}

			for _, coreType in Enum.CoreGuiType:GetEnumItems() do
				if coreType ~= Enum.CoreGuiType.All then
					self.CoreStates[coreType] = StarterGui:GetCoreGuiEnabled(coreType)
				end
			end
		end

		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	elseif self.CoreStates then
		for coreType, enabled in self.CoreStates do
			StarterGui:SetCoreGuiEnabled(coreType, enabled)
		end
	end

	-- The top bar is not a CoreGuiType: it goes away through SetCore, which may not exist yet.
	pcall(function()
		StarterGui:SetCore("TopbarEnabled", not hide)
	end)
end

--[=[
	Starts tracking a GUI. `Desired` starts from the value it had on arrival and is
	rewritten every time someone other than us changes its `Enabled`.
]=]
function InterfaceController:_track(screenGui : LayerCollector)
	if self.Tracked[screenGui] then
		return
	end

	local entry = { Desired = screenGui.Enabled, Pending = 0 }
	self.Tracked[screenGui] = entry

	-- The connection dies with the GUI, not with the controller: ScreenGuis with
	-- `ResetOnSpawn` are rebuilt on every respawn, and keeping them all in the Maid would
	-- leave one connection behind per character life.
	entry.Connection = screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		-- Notification of our own write: one per `_write`, in the order they went out.
		if entry.Pending > 0 then
			entry.Pending -= 1
			return
		end

		entry.Desired = screenGui.Enabled
		self:_apply(screenGui)
	end)

	self:_apply(screenGui)
end

function InterfaceController:_untrack(screenGui : Instance)
	local entry = self.Tracked[screenGui]
	if not entry then
		return
	end

	entry.Connection:Disconnect()

	self.Tracked[screenGui] = nil
end

function InterfaceController:_observeGuis()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("LayerCollector") then
			self:_track(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))
	self.Maid:GiveTask(playerGui.ChildRemoved:Connect(function(child : Instance)
		self:_untrack(child)
	end))

	self.Maid:GiveTask(function()
		for screenGui, _ in self.Tracked do
			self:_untrack(screenGui)
		end
	end)

	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
end

--[[ EXTERNAL ]]

--[=[
	Turns a GUI on or off **as its owner**, without depending on the notification
	that arrives at the end of the frame.

	`Desired` is normally discovered by listening to each GUI's `Enabled`, and that
	notification is `Deferred`: between the owner's write and its arrival, the value
	stored here is still the old one. Any `Hide`/`Show` that lands in that window
	(and `_applyAll` sweeps every GUI) reapplies the old value on top of what the
	owner just wrote.

	For almost every GUI that never happens: it changes on its own, far from any
	request. For one that changes **together** with a request it is the normal case,
	not the exception: the portal's leave button turns on at the same instant the
	countdown hides the Lobby, and writing directly to its `Enabled` meant watching
	the request turn it back off in the same frame.

	Here `Desired` is written immediately, so there is no window. Callers do not need
	to worry about order.

	A GUI this controller does not track yet gets the direct write: the `_track` that
	comes later reads exactly that value as what the owner wanted.
]=]
function InterfaceController:SetEnabled(screenGui : LayerCollector, enabled : boolean)
	local entry = self.Tracked[screenGui]
	if not entry then
		screenGui.Enabled = enabled
		return
	end

	entry.Desired = enabled
	self:_apply(screenGui)
end

--[=[
	Hides GUIs until the `Show` with the same `reason`. Asking twice with the same
	name only replaces the options; it does not stack, so a `Show` always undoes it.

	- `Except`: names of `ScreenGui`s this request leaves alone.
	- `HideCore`: also takes chat, player list, backpack, and top bar.
]=]
function InterfaceController:Hide(reason : string, options : { Except : { string }?, HideCore : boolean? }?)
	local except = nil

	if options and options.Except then
		except = {}
		for _, name in options.Except do
			except[name] = true
		end
	end

	self.Requests[reason] = {
		Except = except,
		HideCore = options and options.HideCore == true,
	}

	self:_applyAll()
	self:_applyCore()
end

--[=[
	Undoes this `reason`'s request. GUIs no other request hides return to what their
	owner wanted.
]=]
function InterfaceController:Show(reason : string)
	if not self.Requests[reason] then
		return
	end

	self.Requests[reason] = nil

	self:_applyAll()
	self:_applyCore()
end

--[=[
	Whether any request is active, or whether one with this name is.
]=]
function InterfaceController:IsHidden(reason : string?) : boolean
	if reason then
		return self.Requests[reason] ~= nil
	end

	return next(self.Requests) ~= nil
end

function InterfaceController:construct()
	self:_observeGuis()
end

function InterfaceController:start()

end

function InterfaceController:init()
	self.Maid = Maid.new()

	self.Requests = {}
	self.Tracked = {}
	self.CoreHidden = false
	self.CoreStates = nil

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return InterfaceController
