local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

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

	--[=[
		O CmdrController pergunta aqui em vez de ler a lista de admins, que nao e
		mais replicada. A resposta so decide se o console aparece -- o BeforeRun
		acima continua sendo quem de fato autoriza cada comando.
	]=]
	Framework:Listen("RequestCmdrAccess", function(player : Player)
		Framework:Fire("CmdrAccess", player, self:IsAdmin(player))
	end)
end

function CmdrService:init()
	-- O cliente conecta em "CmdrAccess" logo no init dele, mas o servidor so criaria
	-- esse evento na hora de responder -- ai o Warp reclama que ele "is taking too
	-- long to retrieve". Declarar aqui, como os outros services fazem com os eventos
	-- que so o servidor dispara.
	Framework:Listen("CmdrAccess", function() end)

	self:construct()
end

function CmdrService:start()

end

return CmdrService
