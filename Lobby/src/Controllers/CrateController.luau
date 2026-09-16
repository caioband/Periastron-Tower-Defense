local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Utils.UIUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local CrateConfig = SharedConfig.CrateConfig

local Framework = Me.new()

--[[ CONSTANTS ]]
local CRATE_UI_NAME = "crateui"
local ENTRY_NAME_PREFIX = "Crate_"
local TEMPLATE_NAME = "cratetemplate"

-- Crates the player does not own are hidden. Set to false to always show every rarity.
local HIDE_EMPTY_CRATES = true

-- Horizontal gap between entries, as a fraction of one entry's width.
-- Only used when CrateWrapper has no UIListLayout / UIGridLayout of its own.
local ENTRY_PADDING_SCALE = 0.1

local GAIN_POP_SCALE = 1.15
local GAIN_POP_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GAIN_RETURN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- The server is the one that spends the crate; this only stops a burst of requests
-- from going out while the first one is still in flight.
local REQUEST_COOLDOWN = 0.5

local CrateController = {
	Controllers = {
		DataController = {},
	},

	Signals = {
		-- (rarity : string, gained : number, total : number)
		CrateGained = Signal.new(),
	},
}

--[[ INTERNAL ]]

local function getCratesFromData(data) : { [string]: number }
	local inventory = data and data.Inventory
	local crates = inventory and inventory.Crates

	return crates or CrateConfig.createEmptyCrates()
end

--[=[
	Rebuilds one entry per rarity inside CrateWrapper, using cratetemplate as the
	source. The template itself is kept hidden so the designer can keep editing it.
]=]
function CrateController:_buildEntries(wrapper : Instance, template : ImageButton)
	self.Entries = {}

	for _, rarity in CrateConfig.getOrderedRarities() do
		local entry = template:Clone()
		entry.Name = ENTRY_NAME_PREFIX .. rarity
		entry.Visible = false
		entry.LayoutOrder = CrateConfig.CRATES[rarity].Order or 0

		local scale = Instance.new("UIScale")
		scale.Name = "CrateScale"
		scale.Parent = entry

		-- cratetemplate is an ImageButton: each entry is what the player clicks to open
		-- that rarity.
		if entry:IsA("GuiButton") then
			self.UiMaid:GiveTask(entry.Activated:Connect(function()
				self:RequestOpen(rarity)
			end))
		end

		entry.Parent = wrapper

		self.Entries[rarity] = entry
		self.UiMaid:GiveTask(entry)
	end
end

function CrateController:_playGainEffect(entry : Instance)
	local scale = entry:FindFirstChild("CrateScale")
	if not scale then
		return
	end

	local popTween = TweenService:Create(scale, GAIN_POP_INFO, { Scale = GAIN_POP_SCALE })
	popTween.Completed:Once(function()
		if scale.Parent then
			TweenService:Create(scale, GAIN_RETURN_INFO, { Scale = 1 }):Play()
		end
	end)
	popTween:Play()
end

--[=[
	Writes the crate amounts into the UI. Entries gained since the last refresh get
	a small pop, and CrateGained fires for anything the player just received.
]=]
function CrateController:_render(crates : { [string]: number })
	if not self.Entries then
		return
	end

	local wrapper = self.Wrapper
	if not wrapper or not wrapper.Parent then
		return
	end

	-- Respect a layout the designer added to CrateWrapper; otherwise lay the entries
	-- out ourselves so they read as a row, like the scrolling frame's list layout does.
	local hasLayout = wrapper:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
	local visibleIndex = 0

	for _, rarity in CrateConfig.getOrderedRarities() do
		local entry = self.Entries[rarity]
		local info = CrateConfig.CRATES[rarity]
		if not entry or not info then
			continue
		end

		local amount = crates[rarity] or 0
		local previousAmount = self.Cache[rarity]

		local shouldShow = (not HIDE_EMPTY_CRATES) or amount > 0
		entry.Visible = shouldShow

		if shouldShow then
			visibleIndex += 1

			if not hasLayout then
				entry.Position = UDim2.fromScale((visibleIndex - 1) * (1 + ENTRY_PADDING_SCALE), 0)
			end

			local nameLabel = entry:FindFirstChild("cratename")
			if nameLabel and nameLabel:IsA("TextLabel") then
				nameLabel.Text = info.DisplayName or rarity
			end

			local amountLabel = entry:FindFirstChild("crateamount")
			if amountLabel and amountLabel:IsA("TextLabel") then
				amountLabel.Text = string.format("%sx", UIUtil.formatAbbreviated(amount))
			end

			local imageLabel = entry:FindFirstChild("crateimg")
			if imageLabel and imageLabel:IsA("ImageLabel") and info.Image and info.Image ~= "" then
				imageLabel.Image = info.Image
			end
		end

		-- previousAmount is nil on the very first render, so joining with crates
		-- already in the profile does not fire as a "gain".
		if previousAmount ~= nil and amount > previousAmount then
			if shouldShow then
				self:_playGainEffect(entry)
			end

			self.Signals.CrateGained:Fire(rarity, amount - previousAmount, amount)
		end

		self.Cache[rarity] = amount
	end
end

--[=[
	Binds to a crateui instance. crateui has ResetOnSpawn enabled, so this runs again
	for every fresh copy the engine parents into PlayerGui.
]=]
function CrateController:_bindUI(screenGui : ScreenGui)
	self.UiMaid:DoCleaning()
	self.Entries = nil
	self.Wrapper = nil

	local rectangle = screenGui:WaitForChild("Rectangle", 10)
	local scroll = rectangle and rectangle:WaitForChild("scrollcrates", 10)
	local wrapper = scroll and scroll:WaitForChild("CrateWrapper", 10)
	local template = wrapper and wrapper:WaitForChild(TEMPLATE_NAME, 10)

	if not template then
		warn(`[CrateController]: Could not find {CRATE_UI_NAME}.Rectangle.scrollcrates.CrateWrapper.{TEMPLATE_NAME}`)
		return
	end

	template.Visible = false

	self.Wrapper = wrapper
	self:_buildEntries(wrapper, template)

	-- Force a full repaint for the new UI instances.
	table.clear(self.Cache)
	self:_render(self:GetCrates())
end

function CrateController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child.Name ~= CRATE_UI_NAME or not child:IsA("ScreenGui") then
			return
		end

		self:_bindUI(child)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	local existing = playerGui:FindFirstChild(CRATE_UI_NAME)
	if existing then
		task.spawn(onChild, existing)
	end
end

--[[ EXTERNAL ]]

--[=[
	Current crate amounts of the local player, straight from the replica.
]=]
function CrateController:GetCrates() : { [string]: number }
	local DataController = self.Controllers.DataController
	local replica = DataController:GetReplica()

	return getCratesFromData(replica and replica.Data)
end

--[=[
	Asks the server to open one crate of a rarity.

	The Backpack panel stays open on purpose: the player can keep opening crates
	from it without reopening the panel after every unboxing.

	The amount check here is only to keep the UI from firing pointless requests -- the
	server reads the profile and is what actually spends the crate.
]=]
function CrateController:RequestOpen(rarity : string) : boolean
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		return false
	end

	if self:GetCrateAmount(resolvedRarity) <= 0 then
		return false
	end

	local now = os.clock()
	if now - self.LastRequest < REQUEST_COOLDOWN then
		return false
	end

	self.LastRequest = now

	Framework:Fire("RequestOpenCrate", resolvedRarity)

	return true
end

function CrateController:GetCrateAmount(rarity : string) : number
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		return 0
	end

	return self:GetCrates()[resolvedRarity] or 0
end

function CrateController:construct()
	local DataController = self.Controllers.DataController
	local replica = DataController:GetReplica()

	-- DataService writes the whole Inventory key, but listen through OnChange so any
	-- deeper write (Inventory.Crates, ...) refreshes the UI too.
	local connection = replica:OnChange(function(_action, path)
		if path[1] ~= nil and path[1] ~= "Inventory" then
			return
		end

		self:_render(getCratesFromData(replica.Data))
	end)

	self.Maid:GiveTask(function()
		connection:Disconnect()
	end)

	self:_observeUI()
end

function CrateController:start()

end

function CrateController:init()
	self.Maid = Maid.new()
	self.UiMaid = Maid.new()
	self.Maid:GiveTask(self.UiMaid)

	self.Cache = {}
	self.Entries = nil
	self.Wrapper = nil
	self.LastRequest = 0

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CrateController
