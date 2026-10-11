local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local SharedConfig = require(Configs.SharedConfig)

local DeckConfig = SharedConfig.DeckConfig
local GamepassConfig = require(Configs.SharedConfig.GamepassConfig)

local Framework = Me.new()
local log = Log.new("DeckInfoController")

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"
local CARD_UI_NAME = "CardUI"
local INFO_NAME = "Info"

local WAIT_TIMEOUT = 10

--[=[
	Hides `HUD.CardUI.Info` ("LEVEL 25 UNLOCKS +5 EXTRA CARDS!") once the promise no
	longer applies: the player reached `DeckConfig.LEVEL_CARD_BONUS_LEVEL`, or owns the
	pass that grants the same +5 early.

	The rule reads the same two sources `DeckConfig.cardBonusFor` does, so the label goes
	away exactly when the deck cap goes up, and changing the level in `DeckConfig` moves
	both together.

	It watches `Stats` (XP, where the level comes from) and `Gamepasses` on the replica,
	so leveling up or buying the pass with the deck open hides it on the spot. `HUD` is
	`ResetOnSpawn`, so every new copy is bound again.
]=]
local DeckInfoController = {
	Controllers = {
		DataController = {},
	},
}

--[[ INTERNAL ]]

function DeckInfoController:_shouldHide() : boolean
	local replica = self.Replica
	local profile = replica and replica.Data

	if typeof(profile) ~= "table" then
		return false
	end

	if DeckConfig.levelOf(profile) >= DeckConfig.LEVEL_CARD_BONUS_LEVEL then
		return true
	end

	return GamepassConfig.cardBonus(profile) > 0
end

function DeckInfoController:_apply()
	local info = self.Info
	if not info or not info.Parent then
		return
	end

	info.Visible = not self:_shouldHide()
end

function DeckInfoController:_bindHud(screenGui : ScreenGui)
	local cardUI = screenGui:WaitForChild(CARD_UI_NAME, WAIT_TIMEOUT)
	local info = cardUI and cardUI:WaitForChild(INFO_NAME, WAIT_TIMEOUT)

	if not info or not info:IsA("GuiObject") then
		log:StudioWarnOnce("missing", `could not find {HUD_UI_NAME}.{CARD_UI_NAME}.{INFO_NAME}.`)
		return
	end

	self.Info = info
	self:_apply()
end

function DeckInfoController:_observeUI()
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

function DeckInfoController:_watchData()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_apply()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]

			if key == nil or key == "Stats" or key == "Gamepasses" then
				self:_apply()
			end
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

function DeckInfoController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_watchData()
	self:_observeUI()
end

function DeckInfoController:init()
	self.Maid = Maid.new()

	self.Replica = nil
	self.Info = nil
end

return DeckInfoController