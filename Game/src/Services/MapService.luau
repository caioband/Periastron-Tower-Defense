local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Assets = Shared:WaitForChild("Assets")
local Maps = Assets:WaitForChild("Maps")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local ExampleService = {
	Services = {}
}

function ExampleService:LoadMap(Name : string)
	local MapInstance = Maps:FindFirstChild(Name)
	if not MapInstance then return end

	self.CurrentMapName = Name

	local MapContent = MapInstance:FindFirstChild("Content")
	if MapContent then
		local Map = MapContent:FindFirstChild("Map")
		local Clone = Map:Clone()
		Clone.Parent = workspace
	end

	local Spawn = MapInstance:FindFirstChild("SpawnLocation")
	if Spawn then
		local SpawnClone = Spawn:Clone()
		SpawnClone.Enabled = true
		SpawnClone.Parent = workspace
	end

	local Nodes = MapInstance:FindFirstChild("Nodes")
	if Nodes then
		for _, Part : BasePart in Nodes:GetChildren() do
			local Clone = Part:Clone()
			Clone.Transparency = self.Debug and 0.5 or 1
			Clone.Parent = workspace.PathScriptable.Nodes
		end
	end

	local Lighting = MapInstance:FindFirstChild("Lighting")
	if Lighting then

		for _, Inst in game.Lighting:GetChildren() do
			Inst:Destroy()
		end

		for _, Instance in Lighting:GetChildren() do
			local Clone = Instance:Clone()
			Clone.Parent = game.Lighting
		end
	end


end

function ExampleService:construct()
	Framework:Listen("RequestMapMusic", function(player : Player)
	--	if not self.CurrentMapName then return end
		Framework:Fire("PlayMapMusic", player, self.CurrentMapName)
	end)
end

function ExampleService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function ExampleService:init()

	Framework:Listen("PlayMapMusic", function() end)

	self:LoadMap("Snowy")
end

return ExampleService
