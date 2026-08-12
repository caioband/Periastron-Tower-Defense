local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local ServerConfig = require(Configs.Server)

local Me = require(Vendor.Me)
local Cmdr = require(Packages:WaitForChild("Cmdr"))

local CmdrConfig = ServerConfig.Cmdr

local Framework = Me.new()

local CmdrService = {
	Packages = {
		Cmdr = Cmdr,
	},
}

--[=[
	Every command runs through this check server side, so the client never decides
	whether it is allowed to run something.
]=]
function CmdrService:IsAdmin(Player : Player?) : boolean
	if Player == nil then
		-- Server initiated command (Cmdr:Run from our own code).
		return true
	end

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

function CmdrService:construct()
	local definitions = ServerScriptService:WaitForChild("CmdrDefinitions")

	-- Types first: commands reference them by name.
	Cmdr.Registry:RegisterTypesIn(definitions:WaitForChild("Types"))
	Cmdr.Registry:RegisterCommandsIn(definitions:WaitForChild("Commands"))
	Cmdr:RegisterDefaultCommands(CmdrConfig.DEFAULT_COMMAND_GROUPS)

	Cmdr.Registry:RegisterHook("BeforeRun", function(context)
		if not self:IsAdmin(context.Executor) then
			return "You do not have permission to run commands."
		end

		return nil
	end)
end

function CmdrService:init()
	self:construct()
end

function CmdrService:start()

end

return CmdrService
