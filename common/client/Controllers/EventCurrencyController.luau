local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Util.UIUtil)

local Framework = Me.new()

local Config = SharedConfig.EventCurrencyConfig

--[[ CONSTANTS ]]
-- Matches HUD.HUDMiddle.EventCurrency / EventAmountText. Any GUI in PlayerGui with these
-- names is picked up, so the counter can go in the HUD, a shop, or both.
local CONTAINER_NAME = "EventCurrency"
local TEXT_NAME = "EventAmountText"

--[=[
	Shows `Stats.EventCurrency` in every `EventAmountText` label, and hides every
	`EventCurrency` container while the event is off (`Enabled = false`).
]=]
local EventCurrencyController = {
	Controllers = {
		DataController = {},
	},
}

--[[ INTERNAL ]]

function EventCurrencyController:_isText(instance : Instance) : boolean
	return instance.Name == TEXT_NAME and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
end

function EventCurrencyController:_isContainer(instance : Instance) : boolean
	return instance.Name == CONTAINER_NAME and instance:IsA("GuiObject")
end

function EventCurrencyController:_apply(instance : Instance)
	if self:_isText(instance) then
		(instance :: TextLabel).Text = UIUtil.formatCommas(self:GetAmount())
	elseif self:_isContainer(instance) then
		(instance :: GuiObject).Visible = Config.Enabled
	end
end

function EventCurrencyController:_refresh()
	for instance in self.Tracked do
		if instance.Parent then
			self:_apply(instance)
		else
			self.Tracked[instance] = nil
		end
	end
end

function EventCurrencyController:_track(instance : Instance)
	if self:_isText(instance) or self:_isContainer(instance) then
		self.Tracked[instance] = true
		self:_apply(instance)
	end
end

function EventCurrencyController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Maid:GiveTask(playerGui.DescendantAdded:Connect(function(instance)
		self:_track(instance)
	end))

	self.Maid:GiveTask(playerGui.DescendantRemoving:Connect(function(instance)
		self.Tracked[instance] = nil
	end))

	for _, instance in playerGui:GetDescendants() do
		self:_track(instance)
	end
end

function EventCurrencyController:_watchStats()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_refresh()

		local connection = replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
				return
			end

			self:_refresh()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

--[=[
	The local player's balance. 0 while the replica has not arrived, and 0 when the
	profile still carries an older season (the server wipes it on load).
]=]
function EventCurrencyController:GetAmount() : number
	local replica = self.Replica
	local stats = replica and replica.Data and replica.Data.Stats
	if not stats then
		return 0
	end

	if (tonumber(stats[Config.SeasonKey]) or 0) < Config.Season then
		return 0
	end

	return tonumber(stats[Config.StatKey]) or 0
end

function EventCurrencyController:IsEnabled() : boolean
	return Config.Enabled
end

function EventCurrencyController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()
	self:_watchStats()
end

function EventCurrencyController:init()
	self.Maid = Maid.new()
	self.Tracked = {}
end

return EventCurrencyController