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
local Environment = require(Shared.Util.Environment)

local CmdrConfig = ServerConfig.Cmdr

local Framework = Me.new()

-- In QA every player is a tester and runs `CmdrConfig.QA_COMMANDS`.
local IS_QA = Environment.IsQA()

local CmdrService = {
	Packages = {
		Cmdr = Cmdr,
	},
}

--[=[
	The player's rank in a group, or 0.

	`GetRankInGroup` is a web call: it fails, and failing must not become an error in
	the middle of the permission check. An unknown rank is simply "not an admin this
	way", and the other paths still apply.
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
		The place owner, which can be a person or a group.

		The group branch is not a detail: **this place belongs to a group**, and then
		`game.CreatorId` is the group id, never a player's. Comparing one with the other
		never matched, and since `ALLOW_IN_STUDIO` only applies in Studio, the result
		was a console that worked in testing and not in the live game.
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

--[=[
	Whether the player may run this specific command: admins run everything, and in
	QA every player runs `QA_COMMANDS`. Otherwise only what `COMMAND_PERMISSIONS`
	allows for their role.
]=]
function CmdrService:CanRun(Player : Player?, commandName : string) : boolean
	if self:IsAdmin(Player) then
		return true
	end

	if IS_QA and CmdrConfig.QA_COMMANDS[commandName] then
		return true
	end

	local rule = CmdrConfig.COMMAND_PERMISSIONS[commandName]

	return rule ~= nil and rankInGroup(Player :: Player, rule.groupId) >= rule.minRank
end

--[=[
	The names of the commands the player may run. Admins get all of them.

	The client uses the list to open the console (empty list = no console) and to
	remove from `help` and autocomplete what it cannot run.
]=]
function CmdrService:GetAccessibleCommands(Player : Player) : { string }
	if self:IsAdmin(Player) then
		return Cmdr.Registry:GetCommandNames()
	end

	-- A set first: a command can be in both `QA_COMMANDS` and `COMMAND_PERMISSIONS`.
	local allowed : { [string]: boolean } = {}

	if IS_QA then
		for commandName in CmdrConfig.QA_COMMANDS do
			allowed[commandName] = true
		end
	end

	for commandName, rule in CmdrConfig.COMMAND_PERMISSIONS do
		if not allowed[commandName] and rankInGroup(Player, rule.groupId) >= rule.minRank then
			allowed[commandName] = true
		end
	end

	-- Only what is registered in this place: `roundcash` does not exist in the Lobby.
	local commandNames = {}

	for commandName in allowed do
		if Cmdr.Registry:GetCommand(commandName) then
			table.insert(commandNames, commandName)
		end
	end

	return commandNames
end

function CmdrService:construct()
	local definitions = ServerScriptService:WaitForChild("CmdrDefinitions")

	-- Types first: commands reference them by name.
	Cmdr.Registry:RegisterTypesIn(definitions:WaitForChild("Types"))
	Cmdr.Registry:RegisterCommandsIn(definitions:WaitForChild("Commands"))
	Cmdr:RegisterDefaultCommands(CmdrConfig.DEFAULT_COMMAND_GROUPS)

	Cmdr.Registry:RegisterHook("BeforeRun", function(context)
		if not self:CanRun(context.Executor, context.Name) then
			return "You do not have permission to run commands."
		end

		return nil
	end)

	--[=[
		CmdrController asks here instead of reading the admin list, which is no
		longer replicated. The answer only decides what the console shows; the
		BeforeRun above is still what actually authorizes each command.
	]=]
	Framework:Listen("RequestCmdrAccess", function(player : Player)
		Framework:Fire("CmdrAccess", player, self:GetAccessibleCommands(player))
	end)
end

function CmdrService:init()
	-- The client connects to "CmdrAccess" right in its init, but the server would only
	-- create the event when answering, and then Warp complains it "is taking too
	-- long to retrieve". Declare it here, as other services do with the events
	-- only the server fires.
	Framework:Listen("CmdrAccess", function() end)

	self:construct()
end

function CmdrService:start()

end

return CmdrService
