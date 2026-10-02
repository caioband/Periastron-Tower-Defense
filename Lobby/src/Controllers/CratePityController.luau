local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)

local CrateConfig = SharedConfig.CrateConfig
local RarityConfig = SharedConfig.RarityConfig

local Framework = Me.new()
local log = Log.new("CratePityController")

--[[ CONSTANTS ]]

--[=[
	The UI path: `crateui.Frame.Rectangle.Pity`, a list with one authored
	`RarityContainer`, the **template**: hidden, and cloned once per rarity with a
	guarantee.
]=]
local GUI = {
	ScreenGui = "crateui",
	Wrapper = "Frame",
	Panel = "Rectangle",
	List = "Pity",
	Template = "RarityContainer",

	RarityName = "RarityName",
	Bar = "ProgressBar",
	Progress = "Progress",
}

local WAIT_TIMEOUT = 10

local BAR_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[=[
	The backpack's pity list: how close each guaranteed rarity is to coming out.

	One row per rarity in `CrateConfig.PITY_RARITIES`, rarest on top, reading
	`count/limit`. The count is shared by every crate, so the row is the whole story.
	The counts come from the profile replica (`Data.Pity`) and the limits from
	`CrateConfig.PITY_THRESHOLDS`.

	**This controller decides nothing**: `CrateService` counts and guarantees, and the
	bar is only a reading of the same profile.
]=]
local CratePityController = {
	Controllers = {
		DataController = {},
		-- The panel opening redraws the list. See `construct`.
		CrateUIController = {},
	},
}

--[[ INTERNAL ]]

--- The rarities with a guarantee, rarest first.
local function orderedRarities() : { string }
	local rarities = {}
	for _, rarity in CrateConfig.PITY_RARITIES do
		if CrateConfig.getPityThreshold(rarity) then
			table.insert(rarities, rarity)
		end
	end

	table.sort(rarities, function(a, b)
		return (RarityConfig.getOrder(a) or 0) > (RarityConfig.getOrder(b) or 0)
	end)

	return rarities
end

--[=[
	Creates the rows, once per copy of `crateui`. Each row is painted with its rarity's
	color: the bar's fill and the name.
]=]
function CratePityController:_buildRows()
	local list, template = self.List, self.Template
	if not list or not template or self.Rows then
		return
	end

	self.Rows = {}

	for index, rarity in orderedRarities() do
		local row = template:Clone()
		row.Name = rarity
		row.LayoutOrder = index
		row.Visible = true

		local color = RarityConfig.getColor(rarity)

		local nameLabel = row:FindFirstChild(GUI.RarityName)
		if nameLabel and nameLabel:IsA("TextLabel") then
			local tier = RarityConfig.TIERS[rarity]
			nameLabel.Text = tier and tier.DisplayName or rarity
			if color then
				nameLabel.TextColor3 = color
			end
		end

		local bar = row:FindFirstChild(GUI.Bar)
		if bar and bar:IsA("GuiObject") then
			if color then
				bar.BackgroundColor3 = color
			end
			bar.Size = UDim2.new(0, 0, bar.Size.Y.Scale, bar.Size.Y.Offset)
		end

		row.Parent = list
		self.RowMaid:GiveTask(row)

		self.Rows[rarity] = {
			Bar = bar,
			Progress = row:FindFirstChild(GUI.Progress),
		}
	end
end

--- Writes each row's count and fills its bar, from the profile's current counts.
function CratePityController:_render()
	self:_buildRows()

	local rows, replica = self.Rows, self.Replica
	if not rows or not replica then
		return
	end

	local counts = CrateConfig.readPity(replica.Data.Pity)

	for rarity, row in rows do
		local threshold = CrateConfig.getPityThreshold(rarity)
		if not threshold then
			continue
		end

		-- At the limit, the next opening is the guaranteed one.
		local count = math.clamp(counts[rarity] or 0, 0, threshold)

		if row.Progress and row.Progress:IsA("TextLabel") then
			row.Progress.Text = `{count}/{threshold}`
		end

		local bar = row.Bar
		if bar and bar.Parent then
			local goal = UDim2.new(count / threshold, 0, bar.Size.Y.Scale, bar.Size.Y.Offset)
			TweenService:Create(bar, BAR_INFO, { Size = goal }):Play()
		end
	end
end

--[=[
	Binds to a `crateui` copy. It has `ResetOnSpawn`, so this runs again for every copy
	the engine parents into `PlayerGui`, and the old rows go with the old copy.
]=]
function CratePityController:_bindUI(screenGui : ScreenGui)
	self.RowMaid:DoCleaning()
	self.Rows = nil
	self.List = nil
	self.Template = nil
	self.Screen = screenGui

	local wrapper = screenGui:WaitForChild(GUI.Wrapper, WAIT_TIMEOUT)
	local panel = wrapper and wrapper:WaitForChild(GUI.Panel, WAIT_TIMEOUT)
	local list = panel and panel:WaitForChild(GUI.List, WAIT_TIMEOUT)
	local template = list and list:WaitForChild(GUI.Template, WAIT_TIMEOUT)

	--[[
		A newer copy arrived while this one was waiting (the first spawn can swap
		`crateui` right after join): that copy's bind owns the list now. Going on would
		build the rows into the discarded copy, and the one on screen would keep the
		template until the next profile change.
	]]
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

	self:_render()
end

function CratePityController:_observeUI()
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
	Follows the profile: every opening moves the counts (`CrateService:_recordPity`
	rewrites the whole `Pity` key), and the bars follow.
]=]
function CratePityController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= "Pity" then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

function CratePityController:construct()
	self:_observeUI()
	self:_watchProfile()

	-- Redrawn on every opening as well: whatever the player sees is the profile right
	-- now, even if some change slipped by while the panel was closed.
	local crateUI = self.Controllers.CrateUIController
	if crateUI and crateUI.Signals and crateUI.Signals.OpenChanged then
		local connection = crateUI.Signals.OpenChanged:Connect(function(isOpen : boolean)
			if isOpen then
				self:_render()
			end
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end
end

function CratePityController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function CratePityController:init()
	self.Maid = Maid.new()

	-- The cloned rows, per copy of `crateui`.
	self.RowMaid = Maid.new()
	self.Maid:GiveTask(self.RowMaid)

	self.Replica = nil

	-- The `crateui` copy being bound: an older bind still waiting gives up.
	self.Screen = nil
	self.List = nil
	self.Template = nil

	-- [rarity] = { Bar, Progress }
	self.Rows = nil
end

return CratePityController
