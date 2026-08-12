local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local ServerConfig = require(Configs.Server)

local Me = require(Vendor.Me)

local CmdrConfig = ServerConfig.Cmdr

local Framework = Me.new()

local CmdrController = {
	Controllers = {},
}

--[=[
	Cosmetic only -- the console is hidden for regular players, but permission is
	always enforced again by CmdrService's BeforeRun hook.
]=]
local function isLocalPlayerAdmin() : boolean
	local Player = Players.LocalPlayer

	if CmdrConfig.ALLOW_IN_STUDIO and RunService:IsStudio() then
		return true
	end

	if CmdrConfig.ADMIN_USER_IDS[Player.UserId] then
		return true
	end

	if game.CreatorType == Enum.CreatorType.User and Player.UserId == game.CreatorId then
		return true
	end

	if CmdrConfig.GROUP_ID then
		local success, rank = pcall(function()
			return Player:GetRankInGroup(CmdrConfig.GROUP_ID)
		end)

		if success and rank >= CmdrConfig.GROUP_MIN_RANK then
			return true
		end
	end

	return false
end

function CmdrController:construct()
	local Cmdr = require(ReplicatedStorage:WaitForChild("CmdrClient")) :: any
	self.Cmdr = Cmdr

	Cmdr:SetActivationKeys(CmdrConfig.ACTIVATION_KEYS)
	Cmdr:SetPlaceName(CmdrConfig.PLACE_NAME)
	Cmdr:SetEnabled(isLocalPlayerAdmin())
end

function CmdrController:start()

end

function CmdrController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CmdrController
