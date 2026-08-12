local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(Configs.Server)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Shared.Me)

local Framework = Me.new()

local ExampleService = {
	Services = {}
}

function ExampleService:construct()
	Framework:Listen("TypingStatusChanged", function(player, isTyping)
		for _, otherPlayer in (Players:GetPlayers()) do
			Framework:Fire("TypingStatusBroadcast", otherPlayer, player, isTyping)
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
	Framework:Listen("TypingStatusBroadcast", function() end)
end

return ExampleService
