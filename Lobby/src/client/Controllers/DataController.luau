local ReplicatedStorage = game.ReplicatedStorage

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Signal = require(Packages.Signal)
local Promise = require(Packages.Promise)

-- Replica Controller
local ReplicaController = require(Vendor.ReplicaClient)

-- Services
local Players = game:GetService("Players")

-- Replica Data
local playerReplicas = {}

local DataController = {}
DataController.ReplicaLoaded = Signal.new()

--[=[
	FetchReplica function:
 	Asynchronously fetches the replica associated with a specific player using a Promise.
 	Returns a Promise that resolves with the player's replica when it is loaded.
]=]
local function FetchReplica(self, player)
	return Promise.new(function(resolve)
		local connection;
		connection = self.ReplicaLoaded:Connect(function(loadedPlayer, loadedReplica)
			if (player == loadedPlayer) then
				connection:Disconnect()
				resolve(loadedReplica)
			end
		end)
	end)
end

--[=[
	DataController:GetReplica function:
	Gets the replica associated with the passed player or the default player (Knit.Player / LocalPlayer).
	If the replica is not available, it uses FetchReplica to load the replica asynchronously.
]=]
function DataController:GetReplica(passedPlayer)
	local player = passedPlayer or Players.LocalPlayer
	local playerReplica = playerReplicas[player]
	if (not playerReplica) then
		local state, playerReplica = FetchReplica(self, player):await()
		return playerReplica
	end

	return playerReplica
end

function DataController:GetData(dataToGet: string)
	local Replica = DataController:GetReplica()
	local Data = Replica.Data

	return Data[dataToGet]
end

function DataController:OnConnectChange(tableString: string, func, target)
	if (target == nil) then target = Players.LocalPlayer end
	local Replica = DataController:GetReplica(target)

	local conn = Replica:OnSet(tableString, func)
	return conn
end

function DataController.init()
	ReplicaController.OnNew("PlayerData", function(replica)

		local player = replica.Tags.Player
		if (player) then
			playerReplicas[player] = replica
			DataController.ReplicaLoaded:Fire(player, replica)
			print("test")
			if player == Players.LocalPlayer then
				--self.LoadingController:DataLoaded()

			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerReplicas[player] = nil;
	end)

	ReplicaController.RequestData()
end

return DataController
