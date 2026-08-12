local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local ServerVendor = ServerScriptService:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(Configs.Server)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Shared.Me)
local Signal = require(Packages.Signal)

local ProfileStore = require(ServerVendor.ProfileStore)
local Replica = require(ServerVendor.ReplicaServer)

local Framework = Me.new()

local DataService = {
	Signals = {
		PlayerDataLoaded = Signal.new()
	}
}

local function copyTemplateValue(value)
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, childValue in value do
		copy[key] = copyTemplateValue(childValue)
	end

	return copy
end

local function reconcileTemplate(data, template)
	for key, templateValue in template do
		if data[key] == nil then
			data[key] = copyTemplateValue(templateValue)
		elseif typeof(data[key]) == "table" and typeof(templateValue) == "table" then
			reconcileTemplate(data[key], templateValue)
		end
	end
end

function DataService:construct()
	self.Profiles = {}
	self.Packages = {
		ReplicaToken = Replica.Token("PlayerData"),
		ProfileManager = ProfileStore.New(
			ServerConfig.Data.PROFILE_KEY,
			ServerConfig.Data.Template
		)
	}
	return true
end

function DataService:CreatePlayer(Player : Player)
	local profileKey = "Player_" .. Player.UserId
	local Session = self.Packages.ProfileManager:StartSessionAsync(profileKey) :: typeof(ProfileStore.New():StartSessionAsync())

	if Session ~= nil then
		reconcileTemplate(Session.Data, ServerConfig.Data.Template)

		local ReplicaProfile = Replica.New({
			Token = self.Packages.ReplicaToken,
			Player = Player,
			Data = Session.Data,
			Tags = {
				Player = Player
			},
		})

	--	ReplicaProfile:Subscribe(Player)
		ReplicaProfile:Replicate()
		ReplicaProfile:FireAllClients()

		self.Profiles[Player] = {
			Profile = ReplicaProfile,
			Session = Session
		}

		print("Player User data has been loaded", self.Profiles[Player])
		self.Signals.PlayerDataLoaded:Fire(Player)
	end
end


local function awaitPlayerTag(player: Player, tagName: string): boolean
	if CollectionService:HasTag(player, tagName) then return true end

	local signal = CollectionService:GetInstanceAddedSignal(tagName)
	local thread = coroutine.running()

	local connection
	connection = signal:Connect(function(instance)
		if instance == player then
			connection:Disconnect()
			task.spawn(thread, true)
		end
	end)
	task.delay(ServerConfig.Data.MAX_DATA_TIME_OUT, function()
		if connection and connection.Connected then
			connection:Disconnect()
			task.spawn(thread, false)
		end
	end)

	return coroutine.yield()
end

function DataService:Get(Player : Player, callbackFunc)
	if self.Profiles[Player] then
		task.spawn(function()
			local success = awaitPlayerTag(Player, "Loaded")
			if success and self.Profiles[Player] then
				callbackFunc(self.Profiles[Player].Profile.Data)
			end
		end)
		return
	end

	local waitConnection
	waitConnection = self.Signals.PlayerDataLoaded:Connect(function(player)
		if player == Player then
			waitConnection:Disconnect()
			waitConnection = nil

			local success = awaitPlayerTag(Player, "Loaded")
			if success and self.Profiles[Player] then
				callbackFunc(self.Profiles[Player].Profile.Data)
			end
		end
	end)

	task.delay(ServerConfig.Data.MAX_DATA_TIME_OUT, function()
		if waitConnection ~= nil then
			waitConnection:Disconnect()
			waitConnection = nil
		end
	end)
end

function DataService:Destroy(Player : Player)
	if self.Profiles[Player] then
		self.Profiles[Player].Session:EndSession()
		self.Profiles[Player].Profile:Destroy()
		self.Profiles[Player] = nil
	end
end

function DataService:Update(Player : Player, Key : string, callbackFunc)
	if not self.Profiles[Player] then
		warn(string.format("Attempted to update data for %s, but profile is not loaded!", Player.Name))
		return
	end

	local replicaProfile = self.Profiles[Player].Profile
	local currentData = replicaProfile.Data[Key]

	local editedData = callbackFunc(currentData)
	if editedData == nil then
		warn(string.format("Update callback for %s returned nil; keeping existing data.", Key))
		return currentData
	end

	replicaProfile:Set({Key}, editedData)
	return editedData
end

function DataService:init()
	self:construct()

	local serverMaid = Maid.new()
	for _, player in Players:GetPlayers() do
		self:CreatePlayer(player)
	end

	serverMaid:GiveTask(Players.PlayerAdded:Connect(function(player)
		self:CreatePlayer(player)
	end))

	serverMaid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:Destroy(player)
	end))

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			task.spawn(function()
				self:Destroy(player)
			end)
		end
		task.wait(2)
		serverMaid:DoCleaning()
	end)

	Framework:Listen("Loaded", function(Player : Player)
		Player:AddTag("Loaded")
	end)
end

function DataService:start()

end

return DataService
