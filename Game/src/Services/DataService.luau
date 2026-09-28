local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local ServerVendor = ServerScriptService:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local ProfileStore = require(ServerVendor.ProfileStore)
local Replica = require(ServerVendor.ReplicaServer)

local Framework = Me.new()
local log = Log.new("DataService")

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

--[=[
	The profile was taken by another server (or the session dropped) with the player
	still here. From now on nothing they did would be saved (the profile no longer
	belongs to this server), so they are removed, with a message to rejoin.

	What usually takes it is `ProfileEditService`'s short session (an admin command on
	a player who just joined) or the player joining another server before this one
	released the profile.
]=]
local SESSION_LOST_MESSAGE = "Your data was opened somewhere else. Please rejoin."

-- How long `CreatePlayer` waits for `ProfileEditService`'s short session to release
-- the key before trying anyway.
local OFFLINE_SESSION_WAIT = 20

function DataService:construct()
	self.Profiles = {}

	-- `{ [UserId] = true }` while `ProfileEditService` holds the profile of someone
	-- who is not on the server. See `CreatePlayer`.
	self.OfflineSessions = {}
	self.BeforeRelease = self.BeforeRelease or {}
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

	--[[
		ProfileStore refuses to open the same key twice on the same server: if an admin
		command has this player's profile open in a short session, wait for it to close
		(a matter of seconds).
	]]
	local deadline = os.clock() + OFFLINE_SESSION_WAIT
	while self.OfflineSessions[Player.UserId] and os.clock() < deadline do
		task.wait(0.1)
	end

	local Session = self.Packages.ProfileManager:StartSessionAsync(profileKey) :: typeof(ProfileStore.New():StartSessionAsync())

	-- Left while the profile loaded: release immediately, or the session stays stuck
	-- until the server closes and the player cannot join another.
	if Session ~= nil and Player.Parent ~= Players then
		Session:EndSession()
		return
	end

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

		ReplicaProfile:Replicate()
		ReplicaProfile:FireAllClients()

		local entry = {
			Profile = ReplicaProfile,
			Session = Session,

			-- `true` when `Destroy` is what closes it (normal leave), so `OnSessionEnd`
			-- does not mistake it for a taken profile.
			Releasing = false,
		}
		self.Profiles[Player] = entry

		Session.OnSessionEnd:Connect(function()
			if entry.Releasing or self.Profiles[Player] ~= entry then
				return
			end

			-- On shutdown ProfileStore itself closes every session; then `BindToClose`
			-- releases the player, with the leave callbacks running.
			if ProfileStore.IsClosing then
				return
			end

			log:Warn(string.format("the session for %s ended while they were in the server; kicking.", Player.Name))

			self.Profiles[Player] = nil
			entry.Profile:Destroy()
			Player:Kick(SESSION_LOST_MESSAGE)
		end)

		--[[
			Admin edits arriving by message (`ProfileEditService`): those waiting on the
			profile and those that arrive while it is open. `Get` waits because the
			service may not be up yet on the first batch.
		]]
		Session:MessageHandler(function(message, processed)
			local editor = Framework:Get("ProfileEditService", false, true)
			if self.Profiles[Player] == entry then
				editor:ApplyMessageToPlayer(Player, message, processed)
			end
		end)

		log:Debug("profile loaded for", Player.Name)
		self.Signals.PlayerDataLoaded:Fire(Player)
	end
end


function DataService:Get(Player : Player, callbackFunc)
	if self.Profiles[Player] then
		callbackFunc(self.Profiles[Player].Profile.Data)
		return
	end

	local waitConnection
	waitConnection = self.Signals.PlayerDataLoaded:Connect(function(player)
		if player == Player then
			waitConnection:Disconnect()
			waitConnection = nil
			callbackFunc(self.Profiles[Player].Profile.Data)
		end
	end)

	task.delay(ServerConfig.Data.MAX_DATA_TIME_OUT, function()
		if waitConnection ~= nil then
			waitConnection:Disconnect()
			waitConnection = nil
		end
	end)
end

--[=[
	Registers something to happen with the profile still open, right before the
	session closes: for example, crediting the reward of a player who leaves
	mid-round.

	Every exit path goes through `Destroy`: the `PlayerRemoving` of a player who
	leaves and the server shutdown's `BindToClose`. Registering here covers both at
	once and, above all, does not depend on the order in which services connected
	their own `PlayerRemoving`: a credit made after `EndSession` would be written to
	an already closed profile and lost.

	`order` (0 by default) is for code that needs to **read** the profile after
	everyone else that still writes to it: they run lowest to highest, in
	registration order within the same number. `LeaderboardService` uses 1 to get the
	profile with the leave reward and final time already in; without it, the order
	would depend on which service started first.
]=]
function DataService:OnBeforeRelease(callback : (Player) -> (), order : number?)
	if not self.BeforeRelease then
		self.BeforeRelease = {}
	end

	table.insert(self.BeforeRelease, {
		Callback = callback,
		Order = order or 0,
		Index = #self.BeforeRelease + 1,
	})

	table.sort(self.BeforeRelease, function(a, b)
		if a.Order ~= b.Order then
			return a.Order < b.Order
		end

		return a.Index < b.Index
	end)
end

function DataService:Destroy(Player : Player)
	local entry = self.Profiles[Player]
	if not entry then return end

	-- One pcall per callback: an error in any of them must not stop the session from
	-- closing, or the profile stays stuck and the player cannot join another server.
	for _, hook in self.BeforeRelease or {} do
		local ok, err = pcall(hook.Callback, Player)
		if not ok then
			log:Warn(string.format("leave callback failed for %s: %s", Player.Name, tostring(err)))
		end
	end

	entry.Releasing = true
	entry.Session:EndSession()
	entry.Profile:Destroy()
	self.Profiles[Player] = nil
end

function DataService:Update(Player : Player, Key : string, callbackFunc)
	if not self.Profiles[Player] then
		log:Warn(string.format("attempted to update data for %s, but the profile is not loaded.", Player.Name))
		return
	end

	local replicaProfile = self.Profiles[Player].Profile
	local currentData = replicaProfile.Data[Key]

	local editedData = callbackFunc(currentData)
	if editedData == nil then
		log:Warn(string.format("update callback for %s returned nil; keeping the existing data.", Key))
		return currentData
	end

	replicaProfile:Set({Key}, editedData)
	return editedData
end

function DataService:Save(Player : Player)
	local entry = self.Profiles[Player]
	if not entry then return false end
	local ok = pcall(function()
		entry.Session:Save()
	end)
	return ok
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
		Player:AddTag("ClientReady")
	end)
end

function DataService:start()

end

return DataService
