local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local PhysicsService = game:GetService("PhysicsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Util:WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)

local Config = SharedConfig.LobbyNPCConfig
local SERVER = Config.Server
local MOVE = Config.Movement
local TALK = Config.Interaction

local Framework = Me.new()
local log = Log.new("LobbyNPCController")

local LocalPlayer = Players.LocalPlayer

local BubbleAssets = Shared:WaitForChild("Assets"):WaitForChild("UI"):WaitForChild("Bubbles")
local BUBBLE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local CONTAINER_NAME = "LobbyNPCs"
local NODE_TIMEOUT = 20
local TICK = 0.1

local rng = Random.new()

local LobbyNPCController = {
	Controllers = {
		DialogController = {},
	},
}

--[[ HELPERS ]]

local function groupRegistered(name : string) : boolean
	local ok, registered = pcall(function()
		return PhysicsService:IsCollisionGroupRegistered(name)
	end)
	return ok and registered
end

local function setGroup(model : Instance, group : string)
	if not groupRegistered(group) then
		return
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = group
		end
	end
end

local function flat(vector : Vector3) : Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function randomOffset() : Vector3
	local angle = rng:NextNumber(0, math.pi * 2)
	local spread = rng:NextNumber(0, MOVE.Spread)
	return Vector3.new(math.cos(angle) * spread, 0, math.sin(angle) * spread)
end

--[[ BUBBLE ]]

local function createBubble(head : BasePart)
	local sections = {}

	for i = 1, 3 do
		local asset = BubbleAssets:FindFirstChild("Section" .. i)
		local billboard = asset and asset:FindFirstChildOfClass("BillboardGui")

		if billboard then
			local clone = billboard:Clone()
			clone.Size = UDim2.fromScale(0, 0)
			clone.Enabled = false
			clone.StudsOffset = Config.Bubble.Offset
			clone.Parent = head
			table.insert(sections, clone)
		end
	end

	local bubble = { Running = false, Token = nil }

	function bubble:Start()
		if self.Running or #sections == 0 then
			return
		end

		self.Running = true
		local token = {}
		self.Token = token

		task.spawn(function()
			while self.Token == token do
				for i = 1, #sections do
					if self.Token ~= token then
						break
					end

					for _, section in sections do
						section.Enabled = false
						section.Size = UDim2.fromScale(0, 0)
					end

					local section = sections[i]
					section.Enabled = true
					TweenService:Create(section, BUBBLE_TWEEN, { Size = UDim2.fromScale(1, 1) }):Play()

					local started = os.clock()
					while self.Token == token and os.clock() - started < Config.Bubble.Interval do
						task.wait(0.05)
					end
				end
			end
		end)
	end

	function bubble:Stop()
		self.Running = false
		self.Token = nil

		for _, section in sections do
			section.Enabled = false
			section.Size = UDim2.fromScale(0, 0)
		end
	end

	function bubble:Destroy()
		self:Stop()
		for _, section in sections do
			section:Destroy()
		end
		table.clear(sections)
	end

	return bubble
end

--[[ NODES ]]

local function connect(a, b)
	if a == b then
		return
	end

	if not table.find(a.Neighbors, b) then
		table.insert(a.Neighbors, b)
	end

	if not table.find(b.Neighbors, a) then
		table.insert(b.Neighbors, a)
	end
end

function LobbyNPCController:_buildGraph() : boolean
	local byPart = {}
	local list = {}

	for _, folderName in Config.NodeFolders do
		local folder = workspace:WaitForChild(folderName, NODE_TIMEOUT)
		if not folder then
			log:StudioWarn(`no {folderName} in Workspace.`)
			continue
		end

		for _, part in folder:GetChildren() do
			if part:IsA("BasePart") then
				local node = { Part = part, Position = part.Position, Neighbors = {} }
				byPart[part] = node
				table.insert(list, node)
			end
		end
	end

	for part, node in byPart do
		for _, valueName in { "Next", "Link" } do
			local value = part:FindFirstChild(valueName)
			if value and value:IsA("ObjectValue") and byPart[value.Value] then
				connect(node, byPart[value.Value])
			end
		end
	end

	self.Nodes = list
	return #list > 0
end

function LobbyNPCController:_route(from, to) : { any }?
	if from == to then
		return nil
	end

	local previous = { [from] = from }
	local queue = { from }
	local head = 1

	while head <= #queue do
		local current = queue[head]
		head += 1

		if current == to then
			break
		end

		for _, neighbor in current.Neighbors do
			if not previous[neighbor] then
				previous[neighbor] = current
				table.insert(queue, neighbor)
			end
		end
	end

	if not previous[to] then
		return nil
	end

	local path = {}
	local step = to

	while step ~= from do
		table.insert(path, 1, step)
		step = previous[step]
	end

	return path
end

function LobbyNPCController:_newRoute(npc)
	for _ = 1, 10 do
		local destination = self.Nodes[rng:NextInteger(1, #self.Nodes)]
		local path = self:_route(npc.Node, destination)

		if path and #path >= MOVE.MinRouteNodes then
			npc.Route = path
			npc.RouteIndex = 1
			return
		end
	end

	local fallback = npc.Node.Neighbors[rng:NextInteger(1, math.max(#npc.Node.Neighbors, 1))]
	npc.Route = { fallback or npc.Node }
	npc.RouteIndex = 1
end

--[[ ANIMATION ]]

function LobbyNPCController:_setAnimation(npc, name : string, speed : number?)
	local tracks = npc.Tracks
	local fade = Config.Animations.FadeTime

	if npc.Animation ~= name then
		for trackName, track in tracks do
			if trackName ~= name and track.IsPlaying then
				track:Stop(fade)
			end
		end

		local track = tracks[name]
		if track and not track.IsPlaying then
			track:Play(fade)
		end

		npc.Animation = name
	end

	if name == "Walk" and speed and tracks.Walk then
		tracks.Walk:AdjustSpeed(math.clamp(speed / Config.Animations.WalkReferenceSpeed, 0.5, 1.5))
	end
end

--[[ STATE ]]

function LobbyNPCController:_notice(npc)
	if npc.State ~= "Walking" then
		return
	end

	npc.State = "Noticed"
	npc.ReleaseAt = nil
	npc.Humanoid.AutoRotate = false
	npc.Humanoid:MoveTo(npc.Root.Position)
	self:_setAnimation(npc, "Idle")

	if not self.Talking then
		npc.Bubble:Start()
	end
end

function LobbyNPCController:_release(npc)
	npc.State = "Walking"
	npc.ReleaseAt = nil
	npc.Humanoid.AutoRotate = true
	npc.Bubble:Stop()
end

function LobbyNPCController:_linesFor(npc) : { any }
	if npc.Lines then
		return npc.Lines
	end

	if npc.Kind == "Friend" and Config.FriendLines and #Config.FriendLines > 0 then
		local pool = table.clone(Config.Lines)
		for _, conversation in Config.FriendLines do
			table.insert(pool, conversation)
		end
		return pool
	end

	return Config.Lines
end

function LobbyNPCController:_talk(npc)
	local dialog = self.Controllers.DialogController
	if self.Talking or not dialog or dialog:IsOpen() then
		return
	end

	self.Talking = npc
	npc.State = "Talking"
	npc.Bubble:Stop()

	for _, other in self.NPCs do
		if other.Prompt then
			other.Prompt.Enabled = false
		end
	end

	local pool = self:_linesFor(npc)
	local conversation = pool[rng:NextInteger(1, #pool)]
	local prefix = `[color={Config.Display.NameColor}]{npc.DisplayName}:[/color] `

	local lines = {}
	for _, line in conversation do
		local text = string.gsub(line, "{player}", LocalPlayer.DisplayName)
		table.insert(lines, prefix .. text)
	end

	local function finish()
		if self.Talking ~= npc then
			return
		end

		self.Talking = nil

		for _, other in self.NPCs do
			if other.Prompt then
				other.Prompt.Enabled = true
			end
		end

		if npc.Alive then
			npc.State = "Walking"
			self:_notice(npc)
		end
	end

	task.delay(TALK.TalkDelay, function()
		local unsubscribe
		unsubscribe = dialog:OnClosed(function()
			if unsubscribe then
				unsubscribe()
			end
			finish()
		end)

		local played = dialog:Play(lines, { Blur = Config.Dialog.Blur })
		if not played then
			if unsubscribe then
				unsubscribe()
			end
			finish()
		end
	end)
end

--[[ MOVEMENT ]]

function LobbyNPCController:_walkTo(npc, node) : boolean
	local goal = node.Position + npc.Offset
	local humanoid = npc.Humanoid
	local distance = flat(goal - npc.Root.Position).Magnitude
	local deadline = os.clock() + distance / math.max(MOVE.WalkSpeed, 1) * 2 + 3
	local lastIssue = 0

	while npc.Alive and npc.State == "Walking" do
		if flat(goal - npc.Root.Position).Magnitude <= MOVE.ArriveDistance then
			return true
		end

		if os.clock() > deadline then
			local look = flat(npc.Root.CFrame.LookVector)
			local position = goal + Vector3.new(0, 3, 0)
			npc.Model:PivotTo(CFrame.lookAt(position, position + (if look.Magnitude > 0 then look else Vector3.zAxis)))
			return true
		end

		if os.clock() - lastIssue >= MOVE.ReissueInterval then
			humanoid:MoveTo(goal)
			lastIssue = os.clock()
		end

		task.wait(TICK)
	end

	return false
end

function LobbyNPCController:_pause(npc)
	npc.Humanoid:MoveTo(npc.Root.Position)
	local resumeAt = os.clock() + rng:NextNumber(MOVE.PauseTime.Min, MOVE.PauseTime.Max)

	while npc.Alive and os.clock() < resumeAt do
		task.wait(TICK)
	end
end

function LobbyNPCController:_run(npc)
	while npc.Alive do
		if npc.State ~= "Walking" then
			task.wait(TICK)
			continue
		end

		if not npc.Route or npc.RouteIndex > #npc.Route then
			self:_newRoute(npc)
		end

		local target = npc.Route[npc.RouteIndex]

		if not self:_walkTo(npc, target) then
			continue
		end

		npc.Node = target
		npc.RouteIndex += 1
		npc.Offset = randomOffset()

		local arrived = npc.RouteIndex > #npc.Route
		local chance = if arrived then MOVE.DestinationPauseChance else MOVE.IntermediatePauseChance

		if rng:NextNumber() < chance then
			self:_pause(npc)
		end
	end
end

--[[ SPAWNING ]]

function LobbyNPCController:_promptTemplate() : ProximityPrompt?
	local folder = ReplicatedStorage:FindFirstChild(SERVER.SharedFolder)
	local template = folder and folder:FindFirstChild(SERVER.TemplateName)
	return template and template:FindFirstChildWhichIsA("ProximityPrompt", true) or nil
end

function LobbyNPCController:_staffLines(key : string?)
	if not key then
		return nil
	end

	for _, entry in Config.Staff do
		if entry.Key == key then
			return entry.Lines
		end
	end

	return nil
end

function LobbyNPCController:_spawn(template : Model)
	if self.Spawned[template] or not self.Container then
		return
	end
	self.Spawned[template] = true

	local model = template:Clone()
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	local head = model:FindFirstChild("Head")

	if not humanoid or not root or not head then
		model:Destroy()
		return
	end

	self.SpawnIndex += 1
	local startNode = self.SpawnOrder[((self.SpawnIndex - 1) % #self.SpawnOrder) + 1]

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end

	humanoid.WalkSpeed = MOVE.WalkSpeed
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	setGroup(model, Config.CollisionGroups.NPC)

	model:PivotTo(CFrame.new(startNode.Position + Vector3.new(0, 3, 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0))
	model.Parent = self.Container

	local idleAnimation = Instance.new("Animation")
	idleAnimation.AnimationId = Config.Animations.Idle

	local walkAnimation = Instance.new("Animation")
	walkAnimation.AnimationId = Config.Animations.Walk

	local idleTrack = animator:LoadAnimation(idleAnimation)
	idleTrack.Looped = true
	idleTrack.Priority = Enum.AnimationPriority.Idle

	local walkTrack = animator:LoadAnimation(walkAnimation)
	walkTrack.Looped = true
	walkTrack.Priority = Enum.AnimationPriority.Movement

	local displayName = model:GetAttribute("DisplayName") or humanoid.DisplayName

	local prompt
	local promptTemplate = self:_promptTemplate()
	if promptTemplate then
		prompt = promptTemplate:Clone()
	else
		prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = TALK.PromptText
		prompt.KeyboardKeyCode = TALK.PromptKey
		prompt.HoldDuration = 0
		prompt.RequiresLineOfSight = false
	end
	prompt.ObjectText = displayName
	prompt.MaxActivationDistance = TALK.NoticeRadius
	prompt.Enabled = self.Talking == nil
	prompt.Parent = root

	local npc = {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Prompt = prompt,
		Bubble = createBubble(head),
		Tracks = { Idle = idleTrack, Walk = walkTrack },
		Animation = nil,
		DisplayName = displayName,
		Kind = model:GetAttribute("Kind"),
		Lines = self:_staffLines(model:GetAttribute("StaffKey")),
		Node = startNode,
		Route = nil,
		RouteIndex = 1,
		Offset = randomOffset(),
		State = "Walking",
		ReleaseAt = nil,
		Alive = true,
	}

	self:_setAnimation(npc, "Idle")

	self.Maid:GiveTask(humanoid.Running:Connect(function(speed : number)
		if npc.State == "Walking" and speed > 0.5 then
			self:_setAnimation(npc, "Walk", speed)
		else
			self:_setAnimation(npc, "Idle")
		end
	end))

	self.Maid:GiveTask(prompt.Triggered:Connect(function()
		self:_talk(npc)
	end))

	self.Maid:GiveTask(model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			npc.Alive = false
			npc.Bubble:Destroy()
			local index = table.find(self.NPCs, npc)
			if index then
				table.remove(self.NPCs, index)
			end
		end
	end))

	table.insert(self.NPCs, npc)

	task.spawn(function()
		self:_run(npc)
	end)
end

function LobbyNPCController:_watchFolder(folder : Instance)
	local function onChild(child : Instance)
		if child:IsA("Model") then
			self:_spawn(child)
		end
	end

	self.Maid:GiveTask(folder.ChildAdded:Connect(onChild))

	for _, child in folder:GetChildren() do
		task.spawn(onChild, child)
	end
end

function LobbyNPCController:_watchSources()
	task.spawn(function()
		local shared = ReplicatedStorage:WaitForChild(SERVER.SharedFolder, 60)
		local staff = shared and shared:WaitForChild(SERVER.StaffFolder, 60)
		if staff then
			self:_watchFolder(staff)
		end
	end)

	task.spawn(function()
		local playerGui = LocalPlayer:WaitForChild("PlayerGui")
		local folder = playerGui:WaitForChild(SERVER.PlayerFolder, 60)
		if folder then
			self:_watchFolder(folder)
		end
	end)
end

--[[ PLAYER ]]

function LobbyNPCController:_watchCharacter()
	local group = Config.CollisionGroups.Player

	local function onCharacter(character : Model)
		setGroup(character, group)

		self.Maid:GiveTask(character.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") and groupRegistered(group) then
				descendant.CollisionGroup = group
			end
		end))
	end

	self.Maid:GiveTask(LocalPlayer.CharacterAdded:Connect(onCharacter))

	if LocalPlayer.Character then
		task.spawn(onCharacter, LocalPlayer.Character)
	end
end

function LobbyNPCController:_step(deltaTime : number)
	local character = LocalPlayer.Character
	local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
	local now = os.clock()
	local alpha = 1 - math.exp(-TALK.TurnSpeed * deltaTime)

	for _, npc in self.NPCs do
		if not npc.Alive or not npc.Root.Parent then
			continue
		end

		local distance = if playerRoot then flat(playerRoot.Position - npc.Root.Position).Magnitude else math.huge

		if npc.State == "Walking" then
			if distance <= TALK.NoticeRadius then
				self:_notice(npc)
			end
		elseif npc.State == "Noticed" then
			if distance > TALK.ReleaseRadius then
				npc.ReleaseAt = npc.ReleaseAt or (now + TALK.ResumeDelay)
				if now >= npc.ReleaseAt then
					self:_release(npc)
				end
			else
				npc.ReleaseAt = nil
			end
		end

		if playerRoot and (npc.State == "Noticed" or npc.State == "Talking") then
			local position = npc.Root.Position
			local target = Vector3.new(playerRoot.Position.X, position.Y, playerRoot.Position.Z)

			if flat(target - position).Magnitude > 0.1 then
				npc.Root.CFrame = npc.Root.CFrame:Lerp(CFrame.lookAt(position, target), alpha)
			end
		end
	end
end

--[[ LIFECYCLE ]]

function LobbyNPCController:construct()
	if not self:_buildGraph() then
		log:StudioWarn("no NPC nodes found; lobby NPCs disabled.")
		return
	end

	local order = table.clone(self.Nodes)
	for i = #order, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	self.SpawnOrder = order

	local container = workspace:FindFirstChild(CONTAINER_NAME)
	if not container then
		container = Instance.new("Folder")
		container.Name = CONTAINER_NAME
		container.Parent = workspace
	end
	self.Container = container

	self:_watchCharacter()
	self:_watchSources()

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self:_step(deltaTime)
	end))
end

function LobbyNPCController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	task.spawn(function()
		self:construct()
	end)
end

function LobbyNPCController:init()
	self.Maid = Maid.new()
	self.NPCs = {}
	self.Nodes = {}
	self.SpawnOrder = {}
	self.SpawnIndex = 0
	self.Spawned = {}
	self.Container = nil
	self.Talking = nil
end

return LobbyNPCController