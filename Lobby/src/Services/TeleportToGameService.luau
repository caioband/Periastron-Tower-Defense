local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Observers = require(Vendor.Observers)

local Framework = Me.new()

local ExampleService = {
	Services = {}
}

function ExampleService:construct()
	Observers.observePlayer(function(player)
		local function attempt()
			local success, result = pcall(function()
				game:GetService("TeleportService"):Teleport(109030368179494, player)
			end)

			return success
		end

		for i = 1, 3 do
			local success = attempt()
			if success then break end
			task.wait()
		end
	end)
end

function ExampleService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function ExampleService:init()

end

return ExampleService
