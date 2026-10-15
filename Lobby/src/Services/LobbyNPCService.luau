local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("LobbyNPCService")

local Config = SharedConfig.LobbyNPCConfig
local SERVER = Config.Server

local LobbyNPCService = {
	Building = {},
}

local descriptionCache = {}
local cacheCount = 0

local function shuffle(list : { any }, rng : Random) : { any }
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

function LobbyNPCService:_getDescription(userId : number) : HumanoidDescription?
	local cached = descriptionCache[userId]
	if cached then
		return cached:Clone()
	end

	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(userId)
	end)

	if not ok or not description then
		return nil
	end

	if cacheCount >= SERVER.DescriptionCacheSize then
		for _, entry in descriptionCache do
			entry:Destroy()
		end
		table.clear(descriptionCache)
		cacheCount = 0
	end

	descriptionCache[userId] = description
	cacheCount += 1

	return description:Clone()
end

function LobbyNPCService:_buildModel(userId : number, displayName : string, username : string, kind : string, staffKey : string?) : Model?
	local model

	local description = self:_getDescription(userId)
	if description then
		local ok, result = pcall(function()
			return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
		end)

		if ok and result then
			model = result
		end

		description:Destroy()
	end

	if not model then
		if not self.Template then
			return nil
		end
		model = self.Template:Clone()
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		model:Destroy()
		return nil
	end

	humanoid.DisplayName = displayName
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.NameDisplayDistance = Config.Display.NameDistance
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	model.Name = username
	model.PrimaryPart = root
	model:SetAttribute("UserId", userId)
	model:SetAttribute("DisplayName", displayName)
	model:SetAttribute("Kind", kind)
	if staffKey then
		model:SetAttribute("StaffKey", staffKey)
	end

	return model
end

function LobbyNPCService:_setupCollisionGroups()
	local groups = Config.CollisionGroups

	local ok, err = pcall(function()
		for _, name in { groups.NPC, groups.Player } do
			if not PhysicsService:IsCollisionGroupRegistered(name) then
				PhysicsService:RegisterCollisionGroup(name)
			end
		end

		PhysicsService:CollisionGroupSetCollidable(groups.NPC, groups.Player, false)
		PhysicsService:CollisionGroupSetCollidable(groups.NPC, groups.NPC, false)
	end)

	if not ok then
		log:Warn(`collision groups not set up: {err}`)
	end
end

function LobbyNPCService:_setupFolders()
	local folder = ReplicatedStorage:FindFirstChild(SERVER.SharedFolder)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = SERVER.SharedFolder
		folder.Parent = ReplicatedStorage
	end

	local staff = folder:FindFirstChild(SERVER.StaffFolder)
	if not staff then
		staff = Instance.new("Folder")
		staff.Name = SERVER.StaffFolder
		staff.Parent = folder
	end

	local template = folder:FindFirstChild(SERVER.TemplateName)
	local authored = workspace:FindFirstChild(SERVER.WorkspaceTemplate)

	if not template and authored and authored:IsA("Model") then
		authored.Name = SERVER.TemplateName
		authored.Parent = folder
		template = authored
	elseif authored and authored:IsA("Model") then
		authored:Destroy()
	end

	self.Folder = folder
	self.StaffFolder = staff
	self.Template = template

	if not template then
		log:StudioWarn(`no {SERVER.WorkspaceTemplate} rig in Workspace; failed avatars are skipped and prompts use defaults.`)
	end
end

function LobbyNPCService:_buildStaff()
	for _, entry in Config.Staff do
		if self.StaffFolder:FindFirstChild(entry.Key) then
			continue
		end

		local model = self:_buildModel(entry.UserId, entry.DisplayName, entry.Key, "Staff", entry.Key)
		if model then
			model.Parent = self.StaffFolder
		else
			log:Warn(`could not build staff NPC {entry.Key}.`)
		end

		task.wait(SERVER.BuildInterval)
	end
end

function LobbyNPCService:_friendsOf(player : Player) : { any }
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)

	if not ok or not pages then
		return {}
	end

	local friends = {}

	while true do
		for _, item in pages:GetCurrentPage() do
			table.insert(friends, item)
		end

		if pages.IsFinished or #friends >= SERVER.MaxFriendsScanned then
			break
		end

		local advanced = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)

		if not advanced then
			break
		end
	end

	return friends
end

function LobbyNPCService:_playerFolder(player : Player) : Folder?
	local playerGui = player:WaitForChild("PlayerGui", 30)
	if not playerGui then
		return nil
	end

	local folder = playerGui:FindFirstChild(SERVER.PlayerFolder)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = SERVER.PlayerFolder
		folder.Parent = playerGui
	end

	return folder
end

function LobbyNPCService:_buildFor(player : Player)
	if self.Building[player] then
		return
	end
	self.Building[player] = true

	local folder = self:_playerFolder(player)
	if not folder then
		self.Building[player] = nil
		return
	end

	local rng = Random.new()
	local target = rng:NextInteger(Config.FriendCount.Min, Config.FriendCount.Max)

	local excluded = { [player.UserId] = true }
	for _, entry in Config.Staff do
		excluded[entry.UserId] = true
	end

	local made = 0

	for _, friend in shuffle(self:_friendsOf(player), rng) do
		if made >= target or not player.Parent then
			break
		end

		if excluded[friend.Id] then
			continue
		end
		excluded[friend.Id] = true

		local model = self:_buildModel(friend.Id, friend.DisplayName or friend.Username, friend.Username, "Friend", nil)
		if model then
			model.Parent = folder
			made += 1
		end

		task.wait(SERVER.BuildInterval)
	end

	for _, userId in shuffle(table.clone(Config.FallbackUserIds), rng) do
		if made >= target or not player.Parent then
			break
		end

		if excluded[userId] then
			continue
		end
		excluded[userId] = true

		local okName, username = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)

		if okName and username then
			local model = self:_buildModel(userId, username, username, "Fallback", nil)
			if model then
				model.Parent = folder
				made += 1
			end
		end

		task.wait(SERVER.BuildInterval)
	end

	folder:SetAttribute("Ready", true)
	self.Building[player] = nil
end

function LobbyNPCService:construct()
	self:_setupCollisionGroups()
	self:_setupFolders()

	task.spawn(function()
		self:_buildStaff()
		self.StaffFolder:SetAttribute("Ready", true)
	end)

	Players.PlayerAdded:Connect(function(player : Player)
		self:_buildFor(player)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_buildFor(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player : Player)
		self.Building[player] = nil
	end)
end

function LobbyNPCService:start()
	self:construct()
end

function LobbyNPCService:init()
end

return LobbyNPCService