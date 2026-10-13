local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)

local RuneConfig = SharedConfig.RuneConfig

local Framework = Me.new()
local log = Log.new("BackpackRunesController")

--[[ CONSTANTS ]]

--[=[
	The UI path: `backpackui.Frame.Backpack.ActiveRunes`, a list with one authored
	`RuneActiveWrapper`, the **template**: hidden, and cloned once per active rune
	(the text goes on its `Rune` label).

	`backpackui.Frame.Backpack.ActiveRunesTitle` is the toggle text: "> Show Active
	Runes" while the list is hidden, "V Active Runes" while it is shown. Clicking or
	tapping it flips between the two. The list starts hidden, like the pity list on
	the other side.
]=]
local GUI = {
	ScreenGui = "backpackui",
	Wrapper = "Frame",
	Panel = "Backpack",
	List = "ActiveRunes",
	Title = "ActiveRunesTitle",
	Template = "RuneActiveWrapper",
	Text = "Rune",
}

local WAIT_TIMEOUT = 10

-- The toggle text: collapsed, then expanded.
local TEXT_COLLAPSED = "> Show Active Runes"
local TEXT_EXPANDED = "V Active Runes"

-- How often the countdown is rewritten while the list is shown.
local COUNTDOWN_INTERVAL = 1

--[=[
	The backpack's active rune list: every running rune, its tier and the time left,
	the same rows as the rune shop's `ActiveRunes` (`SHARD II · 24:13`).

	**The countdown runs here.** The server only writes the time left every 30
	seconds (see `RuneService`), so the list counts down from the last write it
	received (`Baseline`). A rune that reaches zero leaves the list on the spot.

	**This controller decides nothing**: it only reads `Data.Runes` from the replica.
]=]
local BackpackRunesController = {
	Controllers = {
		DataController = {},
		-- The panel opening redraws the list and closing collapses it. See `construct`.
		CrateUIController = {},
	},
}

--[[ INTERNAL ]]

--[=[
	The rune's record as of now: the replica's time left minus what passed since the
	replica last wrote `Runes`. Nil when it is not active.
]=]
function BackpackRunesController:_activeEntry(id : string) : { Tier : number, Remaining : number }?
	local replica = self.Replica
	local entry = RuneConfig.entryOf(replica and replica.Data.Runes, id)

	if not entry then
		return nil
	end

	entry.Remaining -= os.clock() - self.Baseline

	return if entry.Remaining > 0 then entry else nil
end

--[=[
	Rebuilds the rows: one per active rune, in catalog order, or a single
	`RuneConfig.EMPTY_TEXT` row when there is none. The labels are kept so the
	countdown only rewrites text (`_tick`).
]=]
function BackpackRunesController:_render()
	self.ListMaid:DoCleaning()
	self.Labels = {}

	local list, template = self.List, self.Template
	if not list or not template then
		return
	end

	local function addRow(order : number) : TextLabel?
		local row = template:Clone()
		row.Name = "ActiveRune"
		row.LayoutOrder = order
		row.Visible = true
		row.Parent = list
		self.ListMaid:GiveTask(row)

		local label = row:FindFirstChild(GUI.Text, true)
		return if label and label:IsA("TextLabel") then label else nil
	end

	for index, rune in RuneConfig.Runes do
		if not self:_activeEntry(rune.Id) then
			continue
		end

		local label = addRow(index)
		if label then
			self.Labels[rune.Id] = label
		end
	end

	if next(self.Labels) == nil then
		local label = addRow(0)
		if label then
			label.Text = RuneConfig.EMPTY_TEXT
		end
	end

	self:_tick()
end

--[=[
	Rewrites the time left on each row. A rune that just ran out redraws the list,
	which drops it.
]=]
function BackpackRunesController:_tick()
	for id, label in self.Labels do
		local rune = RuneConfig.Get(id)
		local entry = self:_activeEntry(id)

		if not entry or not rune then
			self:_render()
			return
		end

		label.Text = string.format(
			RuneConfig.ACTIVE_FORMAT,
			rune.DisplayName,
			RuneConfig.tierName(entry.Tier),
			RuneConfig.formatCountdown(entry.Remaining)
		)
	end
end

function BackpackRunesController:_isShown() : boolean
	local list = self.List
	return list ~= nil and list.Parent ~= nil and list.Visible
end

--- Shows or hides the list and writes the matching toggle text.
function BackpackRunesController:_setOpen(isOpen : boolean)
	local list, title = self.List, self.Title

	if list then
		list.Visible = isOpen
	end

	if title and title:IsA("TextLabel") then
		title.Text = if isOpen then TEXT_EXPANDED else TEXT_COLLAPSED
	end

	if isOpen then
		self:_render()
	end
end

--[=[
	Makes the toggle text clickable. The title is a plain `TextLabel`, so it is made
	`Active` to receive clicks and taps, and lifted above its siblings so nothing
	sits on top of it.
]=]
function BackpackRunesController:_bindToggle(title : Instance?, list : GuiObject)
	if not title or not title:IsA("GuiObject") then
		log:StudioWarn(`could not find {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.Title}.`)
		return
	end

	self.Title = title

	title.Visible = true
	title.Active = true
	title.ZIndex = math.max(title.ZIndex, 10)

	self:_setOpen(false)

	self.UiMaid:GiveTask(title.InputBegan:Connect(function(input : InputObject)
		local inputType = input.UserInputType
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			return
		end

		self:_setOpen(not list.Visible)
	end))
end

--[=[
	Binds to a `backpackui` copy. It has `ResetOnSpawn`, so this runs again for every
	copy the engine parents into `PlayerGui`, and the old rows go with the old copy.
]=]
function BackpackRunesController:_bindUI(screenGui : ScreenGui)
	self.UiMaid:DoCleaning()
	self.ListMaid:DoCleaning()
	self.Labels = {}
	self.List = nil
	self.Title = nil
	self.Template = nil
	self.Screen = screenGui

	local wrapper = screenGui:WaitForChild(GUI.Wrapper, WAIT_TIMEOUT)
	local panel = wrapper and wrapper:WaitForChild(GUI.Panel, WAIT_TIMEOUT)
	local list = panel and panel:WaitForChild(GUI.List, WAIT_TIMEOUT)
	local template = list and list:WaitForChild(GUI.Template, WAIT_TIMEOUT)

	-- A newer copy arrived while this one was waiting: that copy's bind owns the list.
	if self.Screen ~= screenGui then
		return
	end

	if not template or not template:IsA("GuiObject") then
		log:StudioWarn(`could not find {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.List}.{GUI.Template}.`)
		return
	end

	template.Visible = false

	self.List = list
	self.Template = template

	-- The list starts hidden; the toggle text shows it.
	self:_bindToggle(panel:FindFirstChild(GUI.Title), list)
end

function BackpackRunesController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == GUI.ScreenGui then
			self:_bindUI(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[=[
	Follows the replica's `Runes`. Every write restarts the local countdown from the
	time left the server just wrote.
]=]
function BackpackRunesController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica
		self.Baseline = os.clock()

		if self:_isShown() then
			self:_render()
		end

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= "Runes" then
				return
			end

			self.Baseline = os.clock()

			if self:_isShown() then
				self:_render()
			end
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

function BackpackRunesController:_watchCountdown()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.CountdownClock += deltaTime

		if self.CountdownClock < COUNTDOWN_INTERVAL then
			return
		end

		self.CountdownClock = 0

		-- Nobody reads the list while it is hidden; showing it redraws it.
		if self:_isShown() then
			self:_tick()
		end
	end))
end

--[[ EXTERNAL ]]

function BackpackRunesController:construct()
	self:_observeUI()
	self:_watchProfile()
	self:_watchCountdown()

	-- Opening the panel redraws a shown list; closing it collapses the list again, so
	-- it always reopens collapsed like the pity list.
	local crateUI = self.Controllers.CrateUIController
	if crateUI and crateUI.Signals and crateUI.Signals.OpenChanged then
		local connection = crateUI.Signals.OpenChanged:Connect(function(isOpen : boolean)
			if isOpen then
				if self:_isShown() then
					self:_render()
				end
			else
				self:_setOpen(false)
			end
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end
end

function BackpackRunesController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function BackpackRunesController:init()
	self.Maid = Maid.new()

	-- The title's click, per copy of `backpackui`.
	self.UiMaid = Maid.new()
	self.Maid:GiveTask(self.UiMaid)

	-- The cloned rows, rebuilt by `_render`.
	self.ListMaid = Maid.new()
	self.Maid:GiveTask(self.ListMaid)

	self.Replica = nil

	-- `os.clock()` of the replica's last `Runes` write: the local countdown's zero.
	self.Baseline = os.clock()

	-- The `backpackui` copy being bound: an older bind still waiting gives up.
	self.Screen = nil
	self.List = nil
	self.Title = nil
	self.Template = nil

	-- [Id] = the row's label, rewritten by `_tick`.
	self.Labels = {}

	self.CountdownClock = 0
end

return BackpackRunesController