--!native
--!optimize 2

local GAME_VERSION = "1.0.0"

--[[
	@raiarxyzdev
	The package "Me" is a highly modulized module loader which plugs in networking from the get go,
	leaving you with the only need to use this module for your entirety of the game.

	This module at the moment does not support remotefunctions as i belive its unneccessary.
	Just fire a event to server which fires it back or use replica if u need data on module.
--]]

--[[ SERVICES --]]
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")

--[[ VARIABLES --]]
-- Me lives inside the Vendor folder itself (ReplicatedStorage.Shared.Vendor).
local Vendor = script.Parent

--[[ PACKAGES --]]
local Warp = require(Vendor.Warp)
local Maid = require(Vendor.Maid)

--[[ API --]]
local Me = {}
local DebugDisabled = true
local StoredFrameworks = {}
Me.__index = Me

--[[ INTERNAL API --]]
local function CreateEventKey(name : string)
	local isServer = RunService:IsServer()
	if isServer then
		return Warp.Server(name)
	end

	return Warp.Client(name)
end

--[[ EXTERNAL API --]]

function Me:GetVersion()
	return GAME_VERSION
end

function Me:Debug(source: string, message: string, level: number?, Ignore : boolean)
	if DebugDisabled == true and not Ignore then return end
	local verbosity = level or 1
	local timestamp = os.date("%X")

	if Ignore then
		print(`[{source}]: {message}`)
		return
	end
	print(`[{timestamp}] [{source}]: {message}`)
end

function Me:Listen(event : string, callback : (...any) -> (any))
	if not self.Events[event] then
		local createdEventInstance = CreateEventKey(event)
		self.Events[event] = createdEventInstance
	end

	local eventInstance = self.Events[event] :: typeof(Warp.Server("a"))


	return eventInstance:Connect(function(...)
		if callback and typeof(callback) == "function" then
			callback(...)
		end
	end)
end

function Me:Fire(event : string, ...)
	if not self.Events[event] then
		local createdEventInstance = CreateEventKey(event)
		self.Events[event] = createdEventInstance
	end

	local eventInstance = self.Events[event] :: typeof(Warp.Server("a"))


	eventInstance:Fire(true, ...)
end

function Me:Get(name : string, isComponent : boolean?, isYieldingEnabled : boolean)
	if isComponent then

		if not self.Components[name] then
			if not isYieldingEnabled then
				return
			end

			while not self.Components[name] do
				task.wait()
			end
		end

		return self.Components[name] :: any
	end

	if not self.Loaded[name] then
		if not isYieldingEnabled then
			return
		end

		while not self.Loaded[name] do
			task.wait()
		end
	end

	return self.Loaded[name] :: any
end

function Me:GetClass(name : string, isYieldingEnabled : boolean)

	if not self.Classes[name] then
		if not isYieldingEnabled then
			return
		end

		while not self.Classes[name] do
			task.wait()
		end
	end

	return self.Classes[name] :: any
end

function Me:Load()
	local IsServer = self.IsServer :: boolean

	local Folder: Folder
	if IsServer then
		Folder = ServerScriptService.Services
	end

	if not IsServer then
		local Player = Players.LocalPlayer
		local PlayerScripts = Player.PlayerScripts
		local ClientScript = PlayerScripts:WaitForChild("Client")
		Folder = ClientScript.Controllers
	end

	local Contents = Folder:GetDescendants() :: any
	for _, Code : ModuleScript in Contents do
		if Code:IsA("ModuleScript") then
			local requiredCode = require(Code) :: any

			if typeof(requiredCode) == "function" then continue end

			if requiredCode["init"] then
				task.spawn(requiredCode["init"], requiredCode)
			end

			self.Loaded[Code.Name] = requiredCode
		end
	end

	for _, Code in self.Loaded do
		if Code.start then
			task.spawn(Code.start, Code)
		end
	end

	if IsServer then
		self._Bridge = Warp.Server("Bridge")
	else
		self._Bridge = Warp.Client("Bridge")
	end

	self:Debug(script.Name, "Loaded Code.")
end

function Me:LoadClasses()
	local IsServer = self.IsServer :: boolean

	local Folder: Folder
	if IsServer then
		Folder = ServerScriptService.Framework.Classes
	end

	if not IsServer then
		Folder = ReplicatedFirst.Classes
	end

	local Contents = Folder:GetDescendants() :: any
	for _, Code : ModuleScript in Contents do
		if Code:IsA("ModuleScript") then
			local requiredCode = require(Code) :: any

			self.Classes[Code.Name] = requiredCode
		end
	end

	self:Debug(script.Name, "Loaded Classes.")
end

function Me.new()

	local CustomClientKey = string.format("Framework_%s", RunService:IsServer() and "Server" or "Client")
	if StoredFrameworks[CustomClientKey] then
		return StoredFrameworks[CustomClientKey]
	end

	local template = {
		Loaded = {},
		Components = {},
		IsServer = RunService:IsServer(),
		Events = {},
		Classes = {}
	}

	local self = setmetatable(template, Me)
	StoredFrameworks[CustomClientKey] = self
	self:Load()
	return self
end

return Me
