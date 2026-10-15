local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)
local Observers = require(Vendor.Observers)
local Signal = require(Packages.Signal)

local MapConfig = SharedConfig.MapConfig
local PortalConfig = SharedConfig.PortalConfig

local Framework = Me.new()
local log = Log.new("PortalService")

--[[ CONSTANTS ]]
local MAP_FOLDER_NAME = "Map"

local MAP_IMAGE_NAME = "MapImage"
local PLAYER_COUNT_NAME = "PlayerCount"
local TIMER_NAME = "Timer"

--[=[
	Owner of the lobby portals.

	A portal is free until somebody picks a map on it. From there it holds a group:
	its PlayerGate turns solid, its billboard turns on, and a countdown runs until the
	group leaves. Everything a client can ask for is checked here -- the client only
	reports which portal it is standing at.

	What each client reads back comes as attributes on the Portal model (Occupied,
	MemberCount, MaxPlayers, MapName, Launching), so a player walking up to a portal
	knows whether to open the map panel or to join what is already there without
	asking the server first.

	**Tutorial groups.** A player with the tutorial pending (`TutorialService`) opens a
	solo group, nobody can join it, and its teleport carries `Tutorial = true`: that
	flag is what makes the Game place run the tutorial script on the chosen map.
]=]
local PortalService = {
	Services = {
		-- Where the profile's wins come from, which is what unlocks a map.
		DataService = {},

		-- Whether the group opener is mid-tutorial.
		TutorialService = {},
	},

	Signals = {
		-- (portal : Model, members : { Player }, mapName : string)
		GroupLaunched = Signal.new(),
	},
}

--[[ INTERNAL ]]

function PortalService:_readPortal(model : Model, id : number)
	local enter = model:FindFirstChild(PortalConfig.ENTER_NAME)
	local exit = model:FindFirstChild(PortalConfig.EXIT_NAME)
	local gate = model:FindFirstChild(PortalConfig.GATE_NAME)
	local billboardPart = model:FindFirstChild(PortalConfig.BILLBOARD_NAME)
	local billboard = billboardPart and billboardPart:FindFirstChildWhichIsA("BillboardGui")

	if not enter or not enter:IsA("BasePart") or not exit or not exit:IsA("BasePart") then
		log:StudioWarn(`portal {id} has no {PortalConfig.ENTER_NAME}/{PortalConfig.EXIT_NAME} part.`)
		return nil
	end

	if not gate or not billboard then
		log:StudioWarn(`portal {id} has no {PortalConfig.GATE_NAME} or no BillboardGui.`)
		return nil
	end

	local gateParts = {}
	for _, descendant in gate:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(gateParts, descendant)
		end
	end

	model:SetAttribute("PortalId", id)

	return {
		Id = id,
		Model = model,
		Enter = enter,
		Exit = exit,
		GateParts = gateParts,
		Billboard = billboard,
		MapImage = billboard:FindFirstChild(MAP_IMAGE_NAME),
		PlayerCountLabel = billboard:FindFirstChild(PLAYER_COUNT_NAME),
		TimerLabel = billboard:FindFirstChild(TIMER_NAME),
		Group = nil,
	}
end

function PortalService:_setGate(portal, solid : boolean)
	for _, part in portal.GateParts do
		part.CanCollide = solid
	end
end

function PortalService:_publish(portal)
	local group = portal.Group
	local model = portal.Model

	model:SetAttribute("Occupied", group ~= nil)
	model:SetAttribute("MemberCount", group and #group.Members or 0)
	model:SetAttribute("MaxPlayers", group and group.MaxPlayers or 0)
	model:SetAttribute("MapName", group and group.Map or "")
	model:SetAttribute("Launching", group ~= nil and group.Launching == true)
end

function PortalService:_updateBillboard(portal)
	local group = portal.Group
	if not group then
		return
	end

	if portal.PlayerCountLabel and portal.PlayerCountLabel:IsA("TextLabel") then
		portal.PlayerCountLabel.Text = `{#group.Members}/{group.MaxPlayers}`
	end

	if portal.MapImage and portal.MapImage:IsA("ImageLabel") then
		portal.MapImage.Image = MapConfig.getImage(group.Map)
	end
end

function PortalService:_place(player : Player, cframe : CFrame, index : number)
	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end

	local step = math.floor(index / 2) * PortalConfig.MEMBER_SPACING
	local lateral = index % 2 == 0 and step or -step

	character:PivotTo(cframe * CFrame.new(lateral, 0, 0))
end

function PortalService:_notify(player : Player, portal)
	Framework:Fire("PortalGroupChanged", player, portal and portal.Id or 0, portal and portal.Group.Map or "")
end

function PortalService:_resetPortal(portal)
	portal.Group = nil

	self:_setGate(portal, false)
	portal.Billboard.Enabled = false

	self:_publish(portal)
end

function PortalService:_onMembersChanged(portal)
	local group = portal.Group
	local now = os.clock()
	local isFull = #group.Members >= group.MaxPlayers

	if isFull and not group.FullSince then
		group.SavedRemaining = math.max(group.Deadline - now, 0)
		group.FullSince = now
		group.Deadline = now + math.min(PortalConfig.FULL_COUNTDOWN, group.SavedRemaining)
	elseif not isFull and group.FullSince then
		local spentFull = now - group.FullSince

		group.Deadline = now + math.max(group.SavedRemaining - spentFull, 0)
		group.SavedRemaining = nil
		group.FullSince = nil
	end

	self:_updateBillboard(portal)
	self:_publish(portal)
end

function PortalService:_abortLaunch(portal, group, reason : string?)
	if portal.Group ~= group then
		return
	end

	if reason then
		log:Warn(`portal {portal.Id} could not send its group away ({reason}); putting them back.`)
	end

	for index, member in group.Members do
		if member.Parent then
			self:_place(member, portal.Exit.CFrame, index)
			self:_notify(member, nil)
		end
	end

	self:_resetPortal(portal)
end

function PortalService:_teleportGroup(portal, group)
	local members = {}
	local userIds = {}

	for _, member in group.Members do
		if member.Parent then
			table.insert(members, member)
			table.insert(userIds, member.UserId)
		end
	end

	if #members == 0 then
		self:_abortLaunch(portal, group, "nobody left in the group")
		return
	end

	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true
	options:SetTeleportData({
		Map = group.Map,
		Players = userIds,
		MaxPlayers = group.MaxPlayers,
		Tutorial = group.Tutorial == true or nil,
	})

	local success, result = pcall(function()
		return TeleportService:TeleportAsync(Environment.GetPlaceId("Game"), members, options)
	end)

	if not success then
		self:_abortLaunch(portal, group, tostring(result))
	end
end

function PortalService:_launch(portal)
	local group = portal.Group
	group.Launching = true

	local members = table.clone(group.Members)

	self:_publish(portal)

	for _, member in members do
		Framework:Fire("PlayPortalCutscene", member, portal.Id)
	end

	self.Signals.GroupLaunched:Fire(portal.Model, members, group.Map)

	task.delay(PortalConfig.TELEPORT_DELAY, function()
		if portal.Group ~= group then
			return
		end

		self:_teleportGroup(portal, group)
	end)

	task.delay(PortalConfig.LAUNCH_RESET, function()
		self:_abortLaunch(portal, group, "the teleport never took")
	end)
end

function PortalService:_step()
	local now = os.clock()

	for _, portal in self.Portals do
		local group = portal.Group
		if not group or group.Launching then
			continue
		end

		local remaining = math.max(group.Deadline - now, 0)
		local shown = math.ceil(remaining)

		if shown ~= group.Shown then
			group.Shown = shown

			if portal.TimerLabel and portal.TimerLabel:IsA("TextLabel") then
				portal.TimerLabel.Text = tostring(shown)
			end
		end

		if remaining <= 0 then
			self:_launch(portal)
		end
	end
end

function PortalService:_resolveRequest(player : Player, portalId : number?)
	if typeof(portalId) ~= "number" then
		return nil
	end

	local portal = self.Portals[portalId]
	if not portal then
		return nil
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if not root then
		return nil
	end

	local reach = PortalConfig.PROXIMITY_RADIUS * PortalConfig.REQUEST_TOLERANCE
	if (root.Position - portal.Enter.Position).Magnitude > reach then
		return nil
	end

	return portal
end

--- Whether this player's group is the tutorial match.
function PortalService:_isTutorial(player : Player) : boolean
	local tutorialService = self.Services.TutorialService

	return tutorialService ~= nil and tutorialService.IsPending ~= nil and tutorialService:IsPending(player)
end

--[[ EXTERNAL ]]

function PortalService:GetPortalOf(player : Player)
	for _, portal in self.Portals do
		local group = portal.Group
		if group and table.find(group.Members, player) then
			return portal
		end
	end

	return nil
end

function PortalService:_winsOf(player : Player) : number
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	if not entry then
		return 0
	end

	local stats = entry.Profile.Data.Stats

	return typeof(stats) == "table" and math.floor(tonumber(stats.Wins) or 0) or 0
end

function PortalService:CreateGroup(player : Player, portalId : number, mapName : string, maxPlayers : number?) : boolean
	if self:GetPortalOf(player) then
		return false
	end

	local portal = self:_resolveRequest(player, portalId)
	if not portal or portal.Group then
		return false
	end

	local resolvedMap = MapConfig.resolveMap(mapName)
	if not resolvedMap then
		log:StudioWarn(`{player.Name} asked for map {tostring(mapName)}, which does not exist.`)
		return false
	end

	if not MapConfig.isUnlocked(resolvedMap, self:_winsOf(player)) then
		log:StudioWarn(string.format(
			"%s asked for map %s, which needs %d wins.",
			player.Name, resolvedMap, MapConfig.getWinsRequired(resolvedMap)))
		return false
	end

	local tutorial = self:_isTutorial(player)

	local requested = typeof(maxPlayers) == "number" and math.floor(maxPlayers) or PortalConfig.MIN_PLAYERS
	local clamped = if tutorial
		then 1
		else math.clamp(requested, PortalConfig.MIN_PLAYERS, PortalConfig.MAX_PLAYERS)

	portal.Group = {
		Owner = player,
		Map = resolvedMap,
		MaxPlayers = clamped,
		Members = { player },
		Deadline = os.clock() + PortalConfig.COUNTDOWN,
		Shown = nil,
		SavedRemaining = nil,
		FullSince = nil,
		Launching = false,
		Tutorial = tutorial,
	}

	self:_setGate(portal, true)
	portal.Billboard.Enabled = true

	self:_place(player, portal.Enter.CFrame, 1)
	self:_onMembersChanged(portal)
	self:_notify(player, portal)

	if tutorial then
		self.Services.TutorialService:NoteGroupCreated(player)
	end

	return true
end

function PortalService:JoinGroup(player : Player, portalId : number) : boolean
	if self:GetPortalOf(player) then
		return false
	end

	local portal = self:_resolveRequest(player, portalId)
	local group = portal and portal.Group
	if not group or group.Launching or group.Tutorial or #group.Members >= group.MaxPlayers then
		return false
	end

	table.insert(group.Members, player)

	self:_place(player, portal.Enter.CFrame, #group.Members)
	self:_onMembersChanged(portal)
	self:_notify(player, portal)

	return true
end

function PortalService:LeaveGroup(player : Player) : boolean
	local portal = self:GetPortalOf(player)
	if not portal then
		return false
	end

	local group = portal.Group
	if group.Launching then
		return false
	end

	table.remove(group.Members, table.find(group.Members, player))

	self:_place(player, portal.Exit.CFrame, 1)
	self:_notify(player, nil)

	if #group.Members == 0 then
		self:_resetPortal(portal)
		return true
	end

	self:_onMembersChanged(portal)
	return true
end

function PortalService:_onCharacterAdded(player : Player, character : Model)
	local portal = self:GetPortalOf(player)
	if not portal then
		return
	end

	if not character.PrimaryPart and not character:WaitForChild("HumanoidRootPart", 5) then
		return
	end

	portal = self:GetPortalOf(player)
	if not portal then
		return
	end

	local index = table.find(portal.Group.Members, player) or 1
	self:_place(player, portal.Enter.CFrame, index)
end

function PortalService:construct()
	local map = workspace:WaitForChild(MAP_FOLDER_NAME)
	local portals = map:WaitForChild(PortalConfig.PORTALS_FOLDER)

	self.Portals = {}

	for _, model in portals:GetChildren() do
		if not model:IsA("Model") then
			continue
		end

		local portal = self:_readPortal(model, #self.Portals + 1)
		if portal then
			table.insert(self.Portals, portal)
			self:_resetPortal(portal)
		end
	end

	Framework:Listen("RequestCreateGroup", function(player : Player, portalId : number, mapName : string, maxPlayers : number)
		self:CreateGroup(player, portalId, mapName, maxPlayers)
	end)

	Framework:Listen("RequestJoinGroup", function(player : Player, portalId : number)
		self:JoinGroup(player, portalId)
	end)

	Framework:Listen("RequestLeaveGroup", function(player : Player)
		self:LeaveGroup(player)
	end)

	self.Maid:GiveTask(Observers.observePlayer(function(player : Player)
		local connection = player.CharacterAdded:Connect(function(character)
			self:_onCharacterAdded(player, character)
		end)

		return function()
			connection:Disconnect()
			self:LeaveGroup(player)
		end
	end))

	self.Maid:GiveTask(TeleportService.TeleportInitFailed:Connect(function(player : Player, result : Enum.TeleportResult, message : string)
		local portal = self:GetPortalOf(player)
		if not portal then
			return
		end

		self:_abortLaunch(portal, portal.Group, `{result.Name}: {message}`)
	end))

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function()
		self:_step()
	end))
end

function PortalService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function PortalService:init()
	self.Maid = Maid.new()
	self.Portals = {}

	Framework:Listen("PortalGroupChanged", function() end)
	Framework:Listen("PlayPortalCutscene", function() end)
end

return PortalService