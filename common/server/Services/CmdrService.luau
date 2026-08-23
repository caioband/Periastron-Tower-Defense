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
	O rank do jogador num grupo, ou 0.

	`GetRankInGroup` e uma chamada web: ela falha, e falhar nao pode virar erro no
	meio da checagem de permissao -- rank desconhecido e simplesmente "nao e admin
	por aqui", e os outros caminhos continuam valendo.
]=]
local function rankInGroup(Player : Player, groupId : number) : number
	local success, rank = pcall(function()
		return Player:GetRankInGroup(groupId)
	end)

	return (success and rank) or 0
end

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

	--[[
		O dono da place, que pode ser uma pessoa ou um grupo.

		O ramo do grupo nao e detalhe: **esta place pertence a um grupo**, e ai o
		`game.CreatorId` e o id do grupo, nunca o de um jogador. Comparar um com o
		outro nunca dava certo, e como o `ALLOW_IN_STUDIO` so vale no Studio, o
		resultado era o console funcionar no teste e nao funcionar em jogo.
	]]
	if game.CreatorType == Enum.CreatorType.User then
		if Player.UserId == game.CreatorId then
			return true
		end
	elseif game.CreatorType == Enum.CreatorType.Group then
		if rankInGroup(Player, game.CreatorId) >= CmdrConfig.CREATOR_GROUP_MIN_RANK then
			return true
		end
	end

	if CmdrConfig.GROUP_ID and rankInGroup(Player, CmdrConfig.GROUP_ID) >= CmdrConfig.GROUP_MIN_RANK then
		return true
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
