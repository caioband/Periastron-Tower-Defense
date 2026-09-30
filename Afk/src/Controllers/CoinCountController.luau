local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Keeps `ScreenGui.CoinCount.CoinAmountText` showing the player's coins
	(`Data.Stats.Cash`).

	The value comes from the profile's replica, so it is whatever the server saved:
	`AfkAreaService` (or anything else that goes through `DataService:Update`)
	changes the profile, the replica notifies the client, and the label follows
	with nothing to fire by hand.

	`ScreenGui` has `ResetOnSpawn`, so on every respawn Roblox throws the label away
	and puts a fresh copy from `StarterGui` in its place, with the placeholder text.
	That is why the label is *observed* (bound again each time one appears) instead of
	found once.
]]

local COUNTER_NAME = "CoinCount"
local LABEL_NAME = "CoinAmountText"

local CoinCountController = {
	-- The live label, `nil` while the GUI is being rebuilt.
	Label = nil,

	-- Last coin amount read from the replica, `nil` until the profile arrives.
	Cash = nil,
}

--[[ INTERNAL ]]

--- `12500` -> `"12,500"`.
local function formatCoins(amount : number) : string
	local text = tostring(math.floor(amount))
	local replaced

	repeat
		text, replaced = string.gsub(text, "^(-?%d+)(%d%d%d)", "%1,%2")
	until replaced == 0

	return text
end

local function readCash(replica) : number
	local stats = replica.Data.Stats

	return (stats and tonumber(stats.Cash)) or 0
end

function CoinCountController:_render()
	local label = self.Label
	if label then
		label.Text = formatCoins(self.Cash or 0)
	end
end

function CoinCountController:_bindLabel(label : TextLabel)
	self.Label = label
	self:_render()

	label.Destroying:Once(function()
		if self.Label == label then
			self.Label = nil
		end
	end)
end

function CoinCountController:_observeGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function consider(instance : Instance)
		if instance.Name == LABEL_NAME and instance:IsA("TextLabel") and instance.Parent and instance.Parent.Name == COUNTER_NAME then
			self:_bindLabel(instance)
		end
	end

	playerGui.DescendantAdded:Connect(consider)

	for _, descendant in playerGui:GetDescendants() do
		consider(descendant)
	end
end

function CoinCountController:_observeCoins()
	--[[
		Resolved here and not in `init`: `Me` spawns every `init` and then every `start`
		without waiting for the `init`s that yield, so a controller fetched in `init` can
		still be a placeholder by the time `start` runs. By `start` everything is loaded.
	]]
	local dataController = Framework:Get("DataController", false, true)

	-- Yields until the profile's replica reaches this client.
	local replica = dataController:GetReplica()

	self.Cash = readCash(replica)
	self:_render()

	--[[
		`OnChange` and not `OnSet({ "Stats", "Cash" })`: `DataService:Update` writes the
		whole `Stats` table, and `OnSet` only fires for the exact path that was set.
		Listening to every change and rereading `Cash` works however it was written.
	]]
	replica:OnChange(function(_action, path)
		if path[1] ~= nil and path[1] ~= "Stats" then return end

		local cash = readCash(replica)
		if cash == self.Cash then return end

		self.Cash = cash
		self:_render()
	end)
end

--[[ LIFECYCLE ]]

function CoinCountController:construct()
	self:_observeGui()
	self:_observeCoins()
end

function CoinCountController:start()
	self:construct()
end

function CoinCountController:init()
end

return CoinCountController
