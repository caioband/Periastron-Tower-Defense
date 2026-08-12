local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Shared.Me)

local Framework = Me.new()

local ExampleController = {
	Controllers = {}
}

function ExampleController:construct()

end

function ExampleController:start()

end

function ExampleController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

return ExampleController
