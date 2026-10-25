-- HALLOWEEN EVENT OFF: the whole module is commented out below.
-- To bring it back, delete this header, the opening `--[==[` and the closing
-- `]==]` + `return {}` at the end of the file.

--[==[
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Util.UIUtil)

local Framework = Me.new()

local PumpkinConfig = SharedConfig.PumpkinConfig
local EventConfig = SharedConfig.EventCurrencyConfig

--[[ CONSTANTS ]]
local INTERFACE_NAME = "Interface"
local COUNTER_NAME = "EventCounter"
local COUNTER_TEXT_NAME = "TextLabel"
local POPUP_NAME = "PumpkinPopup"
local FOLDER_NAME = "EventPumpkins"

local WAIT_TIMEOUT = 10
local RETRY_TIME = 1
local VERTICAL_REACH = 10
local FADE_TIME = 0.3
local LIFT = 3

--[=[
	Shows the player's event currency in `Interface.EventCounter.TextLabel`, spawns this
	player's copy of every pumpkin the server drops (bounce, then bob and spin), asks the
	server to collect it when the character walks into it, and pops "+x" under the
	counter when it pays.
]=]
local PumpkinController = {
	Controllers = {
		DataController = {},
	},
}

--[[ INTERNAL ]]

local function eachPart(root : Instance, callback : (BasePart) -> ())
	if root:IsA("BasePart") then
		callback(root)
	end

	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			callback(descendant)
		end
	end
end

local function heightOf(root : Instance) : number
	if root:IsA("BasePart") then
		return root.Size.Y
	elseif root:IsA("Model") then
		return root:GetExtentsSize().Y
	end

	return 2
end

function PumpkinController:_getAmount() : number
	local replica = self.Replica
	local stats = replica and replica.Data and replica.Data.Stats
	if not stats then
		return 0
	end

	if (tonumber(stats[EventConfig.SeasonKey]) or 0) < EventConfig.Season then
		return 0
	end

	return tonumber(stats[EventConfig.StatKey]) or 0
end

function PumpkinController:_getCounter() : (GuiObject?, TextLabel?)
	local counter = self.Counter
	if not counter or not counter.Parent then
		local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
		local interface = playerGui and playerGui:FindFirstChild(INTERFACE_NAME)
		counter = interface and interface:FindFirstChild(COUNTER_NAME)
		self.Counter = counter
	end

	local label = counter and counter:FindFirstChild(COUNTER_TEXT_NAME)

	return counter, if label and label:IsA("TextLabel") then label else nil
end

function PumpkinController:_refreshCounter()
	local counter, label = self:_getCounter()

	if counter and counter:IsA("GuiObject") then
		counter.Visible = EventConfig.Enabled
	end

	if label then
		label.Text = UIUtil.formatCommas(self:_getAmount())
	end
end

function PumpkinController:_popup(amount : number)
	local counter, label = self:_getCounter()
	if not counter or not label then
		return
	end

	local popup = label:Clone()
	popup.Name = POPUP_NAME
	popup.Text = `+{UIUtil.formatCommas(amount)}`
	popup.AnchorPoint = Vector2.new(0.5, 0)
	popup.Position = UDim2.new(0.5, 0, 1, 0)
	popup.ZIndex = label.ZIndex + 1
	popup.Parent = counter

	local info = TweenInfo.new(PumpkinConfig.PopupTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(popup, info, {
		Position = UDim2.new(0.5, 0, 1.6, 0),
		TextTransparency = 1,
	}):Play()

	local stroke = popup:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, info, { Transparency = 1 }):Play()
	end

	task.delay(PumpkinConfig.PopupTime, function()
		popup:Destroy()
	end)
end

function PumpkinController:_ground(position : Vector3) : Vector3
	local exclude = { self.Folder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude

	local result = workspace:Raycast(position + Vector3.new(0, 3, 0), Vector3.new(0, -12, 0), params)

	return if result then result.Position else position
end

function PumpkinController:_spawn(data)
	if typeof(data) ~= "table" or self.Drops[data.Id] or not self.Template then
		return
	end

	local model = self.Template:Clone()
	eachPart(model, function(part)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end)

	local ground = self:_ground(Vector3.new(data.X, data.Y, data.Z))
	local rest = ground + Vector3.new(0, heightOf(model) / 2 + PumpkinConfig.HoverHeight, 0)

	model:PivotTo(CFrame.new(rest))
	model.Parent = self.Folder

	self.Drops[data.Id] = {
		Id = data.Id,
		Amount = data.Amount,
		Model = model,
		Rest = rest,
		Spawned = os.clock(),
		Angle = math.random() * math.pi * 2,
		RequestedAt = nil,
	}
end

function PumpkinController:_remove(id : number, popupAmount : number?)
	local drop = self.Drops[id]

	if drop then
		self.Drops[id] = nil

		local model = drop.Model
		local info = TweenInfo.new(FADE_TIME)

		eachPart(model, function(part)
			TweenService:Create(part, info, { Transparency = 1 }):Play()
		end)

		local start = model:GetPivot()
		task.spawn(function()
			local began = os.clock()

			while model.Parent and os.clock() - began < FADE_TIME do
				local alpha = (os.clock() - began) / FADE_TIME
				model:PivotTo(start + Vector3.new(0, LIFT * alpha, 0))
				RunService.Heartbeat:Wait()
			end

			model:Destroy()
		end)
	end

	if popupAmount and popupAmount > 0 then
		self:_popup(popupAmount)
	end
end

function PumpkinController:_step()
	local now = os.clock()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	for id, drop in self.Drops do
		local age = now - drop.Spawned
		local offset

		if age < PumpkinConfig.BounceTime then
			local t = age / PumpkinConfig.BounceTime
			offset = PumpkinConfig.BounceHeight * math.abs(math.sin(t * math.pi * 2.5)) * (1 - t)
		else
			offset = math.sin((age - PumpkinConfig.BounceTime) * PumpkinConfig.BobSpeed) * PumpkinConfig.BobHeight
		end

		local spin = drop.Angle + math.rad(age * PumpkinConfig.SpinSpeed)
		drop.Model:PivotTo(CFrame.new(drop.Rest + Vector3.new(0, offset, 0)) * CFrame.Angles(0, spin, 0))

		if root then
			local delta = root.Position - drop.Rest
			local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude

			if flat <= PumpkinConfig.CollectRadius and math.abs(delta.Y) <= VERTICAL_REACH then
				if not drop.RequestedAt or now - drop.RequestedAt >= RETRY_TIME then
					drop.RequestedAt = now
					Framework:Fire("CollectPumpkin", id)
				end
			end
		end
	end
end

function PumpkinController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(function(child)
		if child.Name ~= INTERFACE_NAME then
			return
		end

		self.Counter = nil
		task.spawn(function()
			child:WaitForChild(COUNTER_NAME, WAIT_TIMEOUT)
			self:_refreshCounter()
		end)
	end))

	task.spawn(function()
		local interface = playerGui:WaitForChild(INTERFACE_NAME, WAIT_TIMEOUT)
		if interface then
			interface:WaitForChild(COUNTER_NAME, WAIT_TIMEOUT)
		end
		self:_refreshCounter()
	end)
end

function PumpkinController:_watchStats()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_refreshCounter()

		local connection = replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
				return
			end

			self:_refreshCounter()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ LIFECYCLE ]]

function PumpkinController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace
	self.Folder = folder
	self.Maid:GiveTask(folder)

	task.spawn(function()
		local bricks = Shared:WaitForChild("Assets"):WaitForChild("Bricks")
		self.Template = bricks:WaitForChild("Pumpkin")
	end)

	Framework:Listen("PumpkinDropped", function(data)
		self:_spawn(data)
	end)

	Framework:Listen("PumpkinCollected", function(id, amount)
		self:_remove(id, amount)
	end)

	Framework:Listen("PumpkinRemoved", function(id, awarded, amount)
		self:_remove(id, if awarded then amount else nil)
	end)

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function()
		self:_step()
	end))

	self:_observeUI()
	self:_watchStats()
end

function PumpkinController:init()
	self.Maid = Maid.new()
	self.Drops = {}
	self.Counter = nil
	self.Template = nil
end

return PumpkinController
]==]

return {}
